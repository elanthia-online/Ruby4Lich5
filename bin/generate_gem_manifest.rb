#!/usr/bin/env ruby
# frozen_string_literal: true

# CLI entry point: builds the gem recovery manifest (docs/DECISIONS.md Phase
# 13 SS2/SS3, docs/r4l5-gem-recovery-manifest.md on lich-5) from the closure
# actually staged in the runtime bundle, and writes it as JSON. Reads
# gemspecs directly from the staged .gem files (StagedGemSpecFinder), not
# from a live Ruby's installed-gem registry -- the job this runs in has no
# such registry (it downloads only the staged files, never restores the
# build job's own installed-gem environment, which no longer exists by the
# time this runs). With native_release_tag supplied, reads native digests
# from the staged files and prepares immutable candidate URLs before upload.
# Without it, retains the legacy already-published native digest lookup.
#
# F2's "resolve once" cutover, extended (2026-07-13 audit finding): root
# names, ruby_abi, platform, and every closure member's own delivery state
# (native_self_contained/native_pass_through/pure) all come from the one
# already-resolved ResolutionLock (bin/resolve_bundle_lock.rb's own output),
# never from a separate hand-maintained CSV/dispatch-string pair.
# GemManifestGenerator itself never deserializes a lock (same
# injection-seam discipline as every other class here) -- this CLI is the
# one place that translation happens. ruby_bundled closure members are
# excluded before ever reaching the generator -- they're never staged, and
# have no delivery state the generator would recognize.
#
# <bundle_tag> is *this run's own* release tag (draft, live, or
# "-candidate") -- never assumed to be the live tag. Real bug, found in
# review 2026-07-10: hardcoding the live tag here meant a candidate run's
# manifest described its own dist/pkg's package list but pointed at a
# different run's (the live tag's) zip -- two different sets of bytes.
# Promoting an immutable candidate is a separate administrative action;
# its artifact URLs stay unchanged. Legacy URL migration uses retarget.
#
# Usage:
#   ruby bin/generate_gem_manifest.rb <lock_json_path> <repo> <bundle_tag> \
#     <bundle_filename> <bundle_sha256> <pkg_dir> <output_json_path> [native_release_tag]
#
# Exit status:
#   0 -- success, output_json_path written.
#   1 -- GemManifestGenerator::DigestValidationError (a real, deterministic
#        integrity problem -- a staged gem doesn't match RubyGems.org, or
#        RubyGems.org has nothing to check it against),
#        GemManifestGenerator::UnknownDeliveryStateError (a resolved
#        closure member's delivery state is missing/unrecognized -- a
#        lock/staging mismatch), NativeGemDigestFetcher::FetchError (a
#        native release's digest couldn't be read back),
#        InstalledGemClosure::MissingSpecError (a declared root has no
#        staged .gem file at all), or StagedGemSpecFinder::CorruptGemError
#        (a staged .gem file's own embedded metadata couldn't be read at
#        all) -- do not retry blindly; all mean something real needs
#        investigation, not a transient blip.
#   2 -- bad ARGV invocation, or ResolutionLock::ValidationError (a
#        malformed lock file).

require 'json'
require 'digest'
require_relative '../lib/ruby4lich5/gem_manifest_generator'
require_relative '../lib/ruby4lich5/native_gem_digest_fetcher'
require_relative '../lib/ruby4lich5/rubygems_client'
require_relative '../lib/ruby4lich5/installed_gem_closure'
require_relative '../lib/ruby4lich5/staged_gem_spec_finder'
require_relative '../lib/ruby4lich5/resolution_lock'
require_relative '../lib/ruby4lich5/runtime_inventory'

ARG_NAMES = %i[lock_json_path repo bundle_tag bundle_filename bundle_sha256 pkg_dir output_json_path].freeze

unless [ARG_NAMES.size, ARG_NAMES.size + 1].include?(ARGV.size)
  warn "Usage: #{$PROGRAM_NAME} #{ARG_NAMES.map { |n| "<#{n}>" }.join(' ')} [native_release_tag]"
  exit 2
end

lock_json_path, repo, bundle_tag, bundle_filename, bundle_sha256, pkg_dir, output_json_path, native_release_tag = ARGV

begin
  lock = Ruby4Lich5::ResolutionLock.from_h(JSON.parse(File.read(lock_json_path)))
rescue JSON::ParserError, Ruby4Lich5::ResolutionLock::ValidationError => e
  warn "ERROR: #{e.class}: #{e.message}"
  exit 2
end

non_bundled_closure = Ruby4Lich5::RuntimeInventory.entries(lock.closure)
excluded_names = (lock.closure - non_bundled_closure).map { |entry| entry.fetch(:name) }
delivery_states_by_name = non_bundled_closure.each_with_object({}) do |entry, states|
  states[entry.fetch(:name)] = entry.fetch(:classification).state.to_s
end

# A requested root that itself classifies ruby_bundled (never staged, no
# artifact -- see GemManifestGenerator::ACCEPTED_DELIVERY_STATES's own doc
# comment) has no .gem file to find and no unit to build. Filtered out here,
# using the same ruby_bundled? criterion delivery_states_by_name already
# applies, before it ever reaches InstalledGemClosure (which would raise
# MissingSpecError looking for a staged file that was never going to exist)
# or GemManifestGenerator (whose own root -> unit grouping would otherwise
# raise GemUnitGrouper::ArgumentError for a root absent from the resolved
# closure).
non_bundled_names = non_bundled_closure.map { |entry| entry.fetch(:name) }
root_names = lock.requested_roots.keys & non_bundled_names

digest_fetcher = Ruby4Lich5::NativeGemDigestFetcher.new(repo: repo, platform: lock.platform)
if native_release_tag
  Ruby4Lich5::SafeToken.validate!(native_release_tag, 'native release tag')
  digest_fetcher = lambda do |name, version|
    path = File.join(pkg_dir, "#{name}-#{version}-#{lock.platform}.gem")
    raise Ruby4Lich5::NativeGemDigestFetcher::FetchError, "missing staged native gem: #{path}" unless File.file?(path)

    "sha256:#{Digest::SHA256.file(path).hexdigest}"
  end
end
closure_resolver = Ruby4Lich5::InstalledGemClosure.new(
  requested_names: root_names,
  excluded_names: excluded_names,
  find_specs: Ruby4Lich5::StagedGemSpecFinder.new(pkg_dir: pkg_dir)
)

begin
  generator = Ruby4Lich5::GemManifestGenerator.new(
    root_names: root_names,
    delivery_states_by_name: delivery_states_by_name,
    ruby_abi: lock.ruby_abi,
    platform: lock.platform,
    repo: repo,
    bundle_asset: { tag: bundle_tag, filename: bundle_filename, sha256: bundle_sha256 },
    pkg_dir: pkg_dir,
    native_digest_lookup: digest_fetcher,
    native_release_tag: native_release_tag,
    rubygems_client: Ruby4Lich5::RubygemsClient.new,
    closure_resolver: closure_resolver
  )
  manifest = generator.generate
  if lock.contract
    Ruby4Lich5::RuntimeContract.require_promotable!(lock)
    manifest.fetch('targets').first['contract'] = lock.contract
  end
rescue Ruby4Lich5::GemManifestGenerator::DigestValidationError, Ruby4Lich5::GemManifestGenerator::UnknownDeliveryStateError,
       Ruby4Lich5::NativeGemDigestFetcher::FetchError, Ruby4Lich5::InstalledGemClosure::MissingSpecError,
       Ruby4Lich5::StagedGemSpecFinder::CorruptGemError => e
  warn "ERROR: #{e.class}: #{e.message}"
  exit 1
end

File.write(output_json_path, JSON.pretty_generate(manifest))
unit_count = manifest['targets'].first['units'].size
puts "Wrote gem recovery manifest (#{unit_count} unit(s)) to #{output_json_path}"
