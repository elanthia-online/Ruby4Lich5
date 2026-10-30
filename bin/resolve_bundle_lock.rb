#!/usr/bin/env ruby
# frozen_string_literal: true

# Resolve all selected roots once, pinned to an explicit lich-5 contract.
# The original seven-argument diagnostic path remains uncontracted and is
# refused by publication. Production supplies source directory, full SHA,
# measured inventory and explicit version overrides as four extra arguments.
#
# Arguments: registry path, registry commit SHA, RubyInstaller version, GTK
# version, runtime root CSV (@registry for production), lock output, package
# list output; optionally source directory, full Lich SHA, inventory JSON path
# and overrides JSON. Subsets must include gtk3 and cannot be promoted.
# Exit 0: outputs written. Exit 1: usage, acquisition/resolution, I/O or other
# operational failure. Exit 2: invalid deterministic input, integrity failure,
# unsupported target or policy/contract validation failure.

require 'json'
require_relative '../lib/ruby4lich5/contract_planner'
require_relative '../lib/ruby4lich5/build_planner'
require_relative '../lib/ruby4lich5/closure_merger'
require_relative '../lib/ruby4lich5/curated_gem_registry'
require_relative '../lib/ruby4lich5/default_root_selection'
require_relative '../lib/ruby4lich5/msys2_bootstrap'
require_relative '../lib/ruby4lich5/msys2_package_list_artifact'
require_relative '../lib/ruby4lich5/registry_policy_gate'
require_relative '../lib/ruby4lich5/resolution_lock'
require_relative '../lib/ruby4lich5/rubygems_client'

ARG_NAMES = %i[
  registry_path registry_commit_sha ruby_installer_version ruby_gnome_version runtime_gems_csv
  lock_output_path package_list_output_path
].freeze

unless [ARG_NAMES.size, ARG_NAMES.size + 4].include?(ARGV.size)
  warn "Usage: #{$PROGRAM_NAME} #{ARG_NAMES.map { |n| "<#{n}>" }.join(' ')}"
  exit 1
end

registry_path, registry_commit_sha, ruby_installer_version, ruby_gnome_version, runtime_gems_csv,
  lock_output_path, package_list_output_path, source_directory, lich5_commit, inventory_path, overrides_json = ARGV

# Same fail-fast environment assertion as bin/derive_dynamic_msys2_packages.rb
# -- see that script's own header comment for the full mechanism note
# (Gem::Platform.local is the one check that can't be spoofed by a
# Gem.platforms mutation on a host Ruby; Gem.platforms is retained as a
# secondary consistency check).
unless Gem::Platform.local.to_s == Ruby4Lich5::DefaultRootSelection::PLATFORM &&
       Gem.platforms.map(&:to_s).include?(Ruby4Lich5::DefaultRootSelection::PLATFORM)
  warn "FATAL: this process is not a genuine bootstrapped #{Ruby4Lich5::DefaultRootSelection::PLATFORM.inspect} " \
       "Ruby -- Gem::Platform.local is #{Gem::Platform.local.to_s.inspect}, Gem.platforms is " \
       "#{Gem.platforms.map(&:to_s).inspect}. Must run under a real bootstrapped target Ruby, not a host Ruby " \
       '(mutating Gem.platforms manually is not a valid substitute -- Gem::Platform.local cannot be overridden ' \
       'the same way, which is exactly why it is checked here).'
  exit 2
end

begin
  ruby_abi = Ruby4Lich5::ResolutionLock.ruby_abi_for(ruby_installer_version)

  # gtk3 filtered out here -- real gap, found in review, before this had
  # a real caller: the actual workflow's own runtime-gems dispatch input
  # includes 'gtk3' by default (it is genuinely a top-level Lich runtime
  # gem, installed later alongside every other one), but
  # DefaultRootSelection.resolve_versions's own gtk3_version: parameter is
  # the *only* correct source for gtk3's version -- passing 'gtk3' through
  # runtime_gems: too would resolve it a *second* time via
  # RubygemsClient#latest_version, and {'gtk3' => gtk3_version}.merge(...)
  # would let that second, wrong resolution silently overwrite the
  # intended pinned version. Confirmed live before fixing: an
  # unfiltered pass-through produced a requested_roots['gtk3'] that
  # matched rubygems.org's current latest release, not ruby_gnome_version.
  # An empty result is valid -- a real GTK3-only dispatch (a runtime-gems
  # input naming only "gtk3"). Real gap, found in audit 2026-07-13: this
  # used to reject that case outright; DefaultRootSelection.resolve_versions
  # already handles it correctly on its own (requested_roots collapses to
  # just {'gtk3' => gtk3_version}, still a valid non-empty ResolutionLock
  # -- see ResolutionLock#validate_requested_roots!).
  #
  # 'cairo' is deliberately NOT filtered out here the way 'gtk3' is --
  # DefaultRootSelection.resolve_versions itself now rejects it explicitly
  # (ReservedRootError, below) rather than this CLI silently dropping a
  # real user/dispatch mistake.
  runtime_gems = runtime_gems_csv.split(',').map(&:strip).reject(&:empty?).reject { |name| name == 'gtk3' }

  registry = Ruby4Lich5::CuratedGemRegistry.load_file(registry_path)
  contract = nil
  if source_directory
    contract = Ruby4Lich5::RuntimeContract.new(
      source_directory: source_directory, commit: lich5_commit,
      inventory: JSON.parse(File.read(inventory_path)), registry: registry, gtk_version: ruby_gnome_version,
      overrides: JSON.parse(overrides_json), selection: runtime_gems_csv == '@registry' ? nil : runtime_gems_csv.split(',')
    )
    requested_roots = contract.roots
    closure = Ruby4Lich5::ContractPlanner.plan(contract)
    File.write("#{lock_output_path}.contract-report.json", JSON.pretty_generate(contract.report) + "\n")
    puts JSON.pretty_generate(contract.report)
  else
    requested_roots = Ruby4Lich5::DefaultRootSelection.resolve_versions(
      rubygems_client: Ruby4Lich5::RubygemsClient.new, gtk3_version: ruby_gnome_version, runtime_gems: runtime_gems
    )
    planner = Ruby4Lich5::BuildPlanner.new
    root_plans = requested_roots.to_h do |name, version|
      [name, planner.plan_for(name, version, platform: Ruby4Lich5::DefaultRootSelection::PLATFORM, ruby_abi: ruby_abi)]
    end
    closure = Ruby4Lich5::ClosureMerger.new.merge(root_plans)
  end

  lock = Ruby4Lich5::ResolutionLock.new(
    ruby_installer_version: ruby_installer_version, platform: Ruby4Lich5::DefaultRootSelection::PLATFORM,
    requested_roots: requested_roots, closure: closure,
    registry_commit_sha: registry_commit_sha, registry_content_digest: registry.content_digest, contract: contract&.data
  )

  Ruby4Lich5::RegistryPolicyGate.new(registry: registry, registry_commit_sha: registry_commit_sha).check!(lock)

  gem_specific_packages = closure
                          .reject { |entry| entry.fetch(:classification).ruby_bundled? }
                          .flat_map { |entry| registry.self_build_packages_for(entry.fetch(:name), ruby_abi: ruby_abi) || [] }

  all_packages = (Ruby4Lich5::Msys2Bootstrap::PACKAGES + gem_specific_packages).uniq.sort

  artifact = Ruby4Lich5::Msys2PackageListArtifact.new(all_packages)

  # Both writes inside the protected region -- same reasoning as
  # bin/derive_dynamic_msys2_packages.rb's own fix: a real write failure
  # here (bad output directory, permissions, full disk) must be caught
  # and formatted per this CLI's own documented contract, not leak a raw
  # exception past every rescue clause below.
  File.write("#{lock_output_path}.build-roles.json", JSON.pretty_generate('gtk' => registry.names_for_role('gtk'), 'repack' => registry.names_for_role('repack'), 'tooling' => registry.names_for_role('tooling')) + "\n")
  File.write(lock_output_path, "#{JSON.pretty_generate(lock.to_h)}\n")
  File.binwrite(package_list_output_path, artifact.to_json_bytes)
  puts "Wrote resolution lock to #{lock_output_path}"
  puts "Wrote #{artifact.packages.size} package(s) to #{package_list_output_path}"
rescue Ruby4Lich5::RubygemsClient::IntegrityError => e
  warn "ERROR: #{e.class}: #{e.message}"
  exit 2
rescue Ruby4Lich5::ClosureResolver::ResolutionError, Ruby4Lich5::RubygemsClient::RequestError => e
  warn "ERROR: #{e.class}: #{e.message}"
  exit 1
rescue JSON::ParserError, Ruby4Lich5::RuntimeContract::Error,
       Ruby4Lich5::ClosureResolver::IncompleteClosureError,
       Ruby4Lich5::BuildPlanner::UnbuildableGemError,
       Ruby4Lich5::ClosureMerger::ConflictError,
       Ruby4Lich5::CuratedGemRegistry::ValidationError,
       Ruby4Lich5::ResolutionLock::ValidationError,
       Ruby4Lich5::RegistryPolicyGate::GateFailure,
       Ruby4Lich5::Msys2PackageListArtifact::ValidationError,
       Ruby4Lich5::DefaultRootSelection::ReservedRootError => e
  warn "ERROR: #{e.class}: #{e.message}"
  exit 2
rescue StandardError => e
  warn "ERROR: #{e.class}: #{e.message}"
  exit 1
end
