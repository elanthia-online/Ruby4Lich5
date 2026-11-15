#!/usr/bin/env ruby
# frozen_string_literal: true

# CLI entry point for Phase 17 SS8's dynamic MSYS2 install-list derivation
# -- the actual replacement for ruby4-bundled-gems-suite.yml's hardcoded
# `install:` list (PR F2's job to wire in; this script and PR F1's
# diagnostic workflow prove it correct in complete isolation first).
#
# **Must run under a real, bootstrapped, target-platform Ruby.** This
# script never mutates `Gem.platforms` itself; it
# only asserts, before any resolution runs, that the process it is
# actually running under already reports the target platform natively.
# Simulating the target on a host Ruby via `Gem.platforms =` was found
# live to be both load-bearing (it genuinely changes candidate filtering)
# and still incomplete (`Gem::Resolver` also ranks against
# `Gem::Platform.local`, which a mutation can't override) -- the caller
# (the diagnostic workflow) is responsible for actually downloading and
# extracting the exact resolved RubyInstaller and invoking this script
# with that `ruby.exe`, not the runner's own.
#
# Two-pass order, per SS8:
#   1. Select roots (Ruby4Lich5::DefaultRootSelection) -- gtk3 keeps its
#      special-cased version; every other root resolves via
#      RubygemsClient#latest_version. cairo is never an independent root.
#   2. Resolve + classify every root's own closure (BuildPlanner), merge
#      into one flat, deduplicated closure (ClosureMerger), build a
#      ResolutionLock, gate it against the curated-gem registry
#      (RegistryPolicyGate) -- unknown or drifted members fail the run
#      closed. Derive the MSYS2 package list from every non-ruby_bundled
#      closure member's registry entry, union the static bootstrap set
#      (Msys2Bootstrap), emit a self-validated artifact
#      (Msys2PackageListArtifact).
#
# Usage:
#   ruby bin/derive_dynamic_msys2_packages.rb <registry_path> <registry_commit_sha> <ruby_installer_version> <output_json_path>
#
# Exit status is a real contract the surrounding workflow reads, matching
# bin/prepare_native_gems.rb's own established convention:
#   0 -- success, output_json_path written.
#   1 -- possibly transient, worth retrying: ResolutionError (wraps real
#        network failures from rubygems.org), a bad ARGV invocation, or
#        any unrecognized exception.
#   2 -- deterministic, do not retry: a platform-environment assertion
#        failure, IncompleteClosureError, UnbuildableGemError,
#        ClosureMerger::ConflictError, ResolutionLock::ValidationError,
#        RegistryPolicyGate::GateFailure, CuratedGemRegistry::ValidationError,
#        or Msys2PackageListArtifact::ValidationError. All operate purely
#        on inputs already resolved (or on a real, fixed environment
#        problem) -- retrying re-runs the exact same check and gets the
#        exact same answer.

require 'json'
require_relative '../lib/ruby4lich5/build_planner'
require_relative '../lib/ruby4lich5/closure_merger'
require_relative '../lib/ruby4lich5/curated_gem_registry'
require_relative '../lib/ruby4lich5/default_root_selection'
require_relative '../lib/ruby4lich5/msys2_bootstrap'
require_relative '../lib/ruby4lich5/msys2_package_list_artifact'
require_relative '../lib/ruby4lich5/registry_policy_gate'
require_relative '../lib/ruby4lich5/resolution_lock'
require_relative '../lib/ruby4lich5/rubygems_client'

ARG_NAMES = %i[registry_path registry_commit_sha ruby_installer_version output_json_path].freeze

if ARGV.size != ARG_NAMES.size
  warn "Usage: #{$PROGRAM_NAME} #{ARG_NAMES.map { |n| "<#{n}>" }.join(' ')}"
  exit 1
end

registry_path, registry_commit_sha, ruby_installer_version, output_json_path = ARGV

# Fail-fast environment assertion -- proves this process is genuinely
# running under a real
# target-platform Ruby before trusting anything it resolves, rather than
# silently letting a wrong-platform run produce a wrong-platform package
# list.
#
# Gem::Platform.local.to_s is the primary check -- real gap, found in
# review: Gem.platforms alone is exactly the value the corrected
# bootstrap mechanism's own prose says a host Ruby can have manually
# mutated to include the target ("mutating Gem.platforms manually is not
# a valid substitute"), so checking only Gem.platforms made this guard
# bypassable by precisely the invalid setup it exists to forbid. A host
# Ruby with the target platform appended to Gem.platforms would pass the
# old check, then resolve/rank candidates under the wrong
# Gem::Platform.local anyway (Gem::Resolver ranks against
# Gem::Platform.local, which reflects the real running Ruby's build info
# and can't be overridden the same way -- see the corrected mechanism's
# own reasoning). Gem::Platform.local can't be mutated the way
# Gem.platforms can, so it is the one check that actually proves this is
# a real bootstrapped target Ruby, not a host Ruby dressed up as one.
#
# Gem.platforms is retained as a secondary consistency check -- it's the
# exact mechanism Gem::Resolver's own candidate filter
# (Gem::Platform.installable?) actually reads, verified directly against
# this project's real RubyGems source during review, so a real
# bootstrapped Ruby whose Gem.platforms was somehow *not* self-consistent
# with its own Gem::Platform.local would still be worth catching here.
unless Ruby4Lich5::DefaultRootSelection.genuine_target_ruby?
  warn "FATAL: this process is not a genuine bootstrapped #{Ruby4Lich5::DefaultRootSelection::PLATFORM.inspect} " \
       "Ruby -- Gem::Platform.local is #{Gem::Platform.local.to_s.inspect}, Gem.platforms is " \
       "#{Gem.platforms.map(&:to_s).inspect}. Must run under a real bootstrapped target Ruby, not a host Ruby " \
       '(mutating Gem.platforms manually is not a valid substitute -- Gem::Platform.local cannot be overridden ' \
       'the same way, which is exactly why it is checked here).'
  exit 2
end

begin
  # Derived once, from the caller-supplied ruby_installer_version, and
  # reused for every ABI-sensitive call below -- real gap, found in
  # review: an earlier version of this CLI called BuildPlanner/the
  # registry with DefaultRootSelection::RUBY_ABI, a hardcoded '4.0'
  # constant, while only recording whatever ruby_installer_version the
  # caller actually supplied into the lock afterward. A non-4.0 input
  # (e.g. a real future 4.1.x RubyInstaller release) would resolve and
  # classify under the wrong ABI's policy while the lock claimed a
  # different one. ResolutionLock.ruby_abi_for raises ValidationError
  # (caught below, exit 2) for a malformed ruby_installer_version, so
  # this also fails closed before any resolution work starts on a bad
  # input, rather than only failing once the lock is finally built.
  ruby_abi = Ruby4Lich5::ResolutionLock.ruby_abi_for(ruby_installer_version)

  rubygems_client = Ruby4Lich5::RubygemsClient.new
  requested_roots = Ruby4Lich5::DefaultRootSelection.resolve_versions(rubygems_client: rubygems_client)

  planner = Ruby4Lich5::BuildPlanner.new
  root_plans = requested_roots.to_h do |name, version|
    [name, planner.plan_for(
      name, version, platform: Ruby4Lich5::DefaultRootSelection::PLATFORM, ruby_abi: ruby_abi
    )]
  end

  closure = Ruby4Lich5::ClosureMerger.new.merge(root_plans)

  registry = Ruby4Lich5::CuratedGemRegistry.load_file(registry_path)

  lock = Ruby4Lich5::ResolutionLock.new(
    ruby_installer_version: ruby_installer_version, platform: Ruby4Lich5::DefaultRootSelection::PLATFORM,
    requested_roots: requested_roots, closure: closure,
    registry_commit_sha: registry_commit_sha, registry_content_digest: registry.content_digest
  )

  Ruby4Lich5::RegistryPolicyGate.new(registry: registry, registry_commit_sha: registry_commit_sha).check!(lock)

  gem_specific_packages = closure
                          .reject { |entry| entry.fetch(:classification).ruby_bundled? }
                          .flat_map { |entry| registry.self_build_packages_for(entry.fetch(:name), ruby_abi: ruby_abi) || [] }

  all_packages = (Ruby4Lich5::Msys2Bootstrap::PACKAGES + gem_specific_packages).uniq.sort

  artifact = Ruby4Lich5::Msys2PackageListArtifact.new(all_packages)

  # Inside the protected region, not after `end` -- real gap, found in
  # review: an earlier version wrote the artifact after this begin/rescue
  # block closed, so a real write failure (missing output directory, no
  # permission, a full disk) propagated completely uncaught -- no
  # "ERROR: <class>: <message>" formatting, defeating the header's own
  # "any unrecognized exception" exit-1 promise (and the StandardError
  # catch-all added specifically to make that promise true) for the one
  # step that actually touches the filesystem.
  File.binwrite(output_json_path, artifact.to_json_bytes)
  puts "Wrote #{artifact.packages.size} package(s) to #{output_json_path}"
rescue Ruby4Lich5::ClosureResolver::ResolutionError, Ruby4Lich5::RubygemsClient::RequestError => e
  warn "ERROR: #{e.class}: #{e.message}"
  exit 1
rescue Ruby4Lich5::ClosureResolver::IncompleteClosureError,
       Ruby4Lich5::BuildPlanner::UnbuildableGemError,
       Ruby4Lich5::ClosureMerger::ConflictError,
       Ruby4Lich5::CuratedGemRegistry::ValidationError,
       Ruby4Lich5::ResolutionLock::ValidationError,
       Ruby4Lich5::RegistryPolicyGate::GateFailure,
       Ruby4Lich5::Msys2PackageListArtifact::ValidationError => e
  warn "ERROR: #{e.class}: #{e.message}"
  exit 2
rescue StandardError => e
  # The header comment above already documents "or any unrecognized
  # exception" as an exit-1 case -- real gap, found in review: nothing
  # actually implemented that promise. Without this, an exception outside
  # every class listed above (a real bug, not a recognized failure mode)
  # would propagate as a raw, unformatted Ruby backtrace instead of this
  # CLI's own documented "ERROR: <class>: <message>" contract, even though
  # Ruby's own default uncaught-exception behavior happens to exit 1
  # anyway -- this makes the format promise actually true, not just
  # accidentally-compatible on exit status alone.
  warn "ERROR: #{e.class}: #{e.message}"
  exit 1
end
