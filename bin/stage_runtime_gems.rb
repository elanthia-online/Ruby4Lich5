#!/usr/bin/env ruby
# frozen_string_literal: true

# F2's runtime-staging decision layer -- turns an already-resolved
# ResolutionLock (bin/resolve_bundle_lock.rb's own output) into the one
# sealed staging input (the "resolve once" cutover):
# an ordered install manifest naming, for every non-ruby_bundled closure
# member, the exact verified local .gem artifact to install. The
# surrounding workflow's PowerShell then only ever executes that manifest
# literally (gem install <path> --local --ignore-dependencies, in the
# given order) -- it makes no delivery-role decisions of its own.
#
# Delivery role comes entirely from each member's own locked
# classification (see LockedArtifactMapBuilder's own doc comment):
# native_self_contained artifacts must already exist locally (this
# script never compiles or repacks anything -- that stays the surrounding
# workflow's own build/repack steps, driven by
# bin/prepare_native_gems_from_lock.rb's plan output); pure/
# native_pass_through artifacts are fetched here, verified against the
# lock's own recorded name/version/platform before ever entering the
# manifest.
#
# Usage:
#   ruby bin/stage_runtime_gems.rb <lock_json_path> <platform> <built_gem_paths_json_path> <output_manifest_json_path>
#
# built_gem_paths_json_path: a JSON object {"name" => "/absolute/path/to/name.gem"},
# one entry per native_self_contained closure member -- the surrounding
# workflow's own responsibility to have produced (both the fixed GTK3
# build and any repacked members) before calling this.
#
# output_manifest_json_path: a JSON array of {"name", "version", "path"}
# objects, in the lock's own dependency order (leaves first) -- the exact
# sequence the surrounding workflow should run
# `gem install <path> --local --ignore-dependencies` in.
#
# Exit status:
#   0 -- success, output_manifest_json_path written.
#   1 -- a bad ARGV invocation, a real RubygemsClient network failure
#        (worth retrying), or any other unrecognized exception.
#   2 -- deterministic, do not retry: malformed lock or built-gem-paths
#        JSON (JSON::ParserError), ResolutionLock::ValidationError (a
#        malformed lock), or LockedArtifactMapBuilder::VerificationError
#        (a locally-built or downloaded artifact doesn't actually match
#        what the lock recorded). All three operate purely on inputs
#        already on disk or already resolved.

require 'json'
require_relative '../lib/ruby4lich5/locked_artifact_map_builder'
require_relative '../lib/ruby4lich5/resolution_lock'

ARG_NAMES = %i[lock_json_path platform built_gem_paths_json_path output_manifest_json_path].freeze

if ARGV.size != ARG_NAMES.size
  warn "Usage: #{$PROGRAM_NAME} #{ARG_NAMES.map { |n| "<#{n}>" }.join(' ')}"
  exit 1
end

lock_json_path, platform, built_gem_paths_json_path, output_manifest_json_path = ARGV

begin
  lock = Ruby4Lich5::ResolutionLock.from_h(JSON.parse(File.read(lock_json_path)))
  built_gem_paths = JSON.parse(File.read(built_gem_paths_json_path))

  artifact_map = Ruby4Lich5::LockedArtifactMapBuilder.new.build(lock.closure, platform: platform, built_gem_paths: built_gem_paths)

  # The lock's own closure order (ClosureResolver#topological_sort's own
  # ordering, which ResolutionLock trusts and never re-verifies -- see
  # that class's own doc comment) is already dependency-safe: leaves
  # before the members that depend on them. Filtering out ruby_bundled
  # members here matches artifact_map's own keys exactly -- every
  # remaining name is guaranteed present in the map (LockedArtifactMapBuilder
  # raises VerificationError before returning otherwise), so #fetch is
  # safe, not a defensive guess.
  ordered_manifest = lock.closure
                         .reject { |entry| entry.fetch(:classification).ruby_bundled? }
                         .map { |entry| { 'name' => entry.fetch(:name), 'version' => entry.fetch(:version), 'path' => artifact_map.fetch(entry.fetch(:name)) } }

  # Inside the protected region -- real gap, found in audit 2026-07-13: a
  # write failure here (bad output directory, permissions, full disk)
  # previously escaped every rescue clause below, leaking a raw exception
  # instead of this CLI's own documented exit-1 error format.
  File.write(output_manifest_json_path, "#{JSON.pretty_generate(ordered_manifest)}\n")
  puts "Wrote install manifest for #{ordered_manifest.size} gem(s) to #{output_manifest_json_path}"
rescue JSON::ParserError, Ruby4Lich5::ResolutionLock::ValidationError => e
  warn "ERROR: #{e.class}: #{e.message}"
  exit 2
rescue Ruby4Lich5::LockedArtifactMapBuilder::VerificationError => e
  warn "ERROR: #{e.class}: #{e.message}"
  exit 2
rescue Ruby4Lich5::RubygemsClient::RequestError => e
  warn "ERROR: #{e.class}: #{e.message}"
  exit 1
rescue StandardError => e
  warn "ERROR: #{e.class}: #{e.message}"
  exit 1
end
