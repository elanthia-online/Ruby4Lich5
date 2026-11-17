#!/usr/bin/env ruby
# frozen_string_literal: true

# Writes the patch_fingerprints record this run's gem bundle must carry in
# gem-build-metadata.json (see Ruby4Lich5::PatchFingerprint). Run it before
# "Prepare native gems": that step may generate patches into patches/, and
# the record must describe the committed curated tree only.
#
# With a replacement plan the plan's own record is written (a reused package
# whose accepted build recorded nothing stays unrecorded); without one every
# non-Ruby-bundled closure member gets the current tree's fingerprint.
#
# Usage: record_patch_fingerprints.rb <lock> <output> [<replacement-plan>]

require 'json'
require_relative '../lib/ruby4lich5/patch_fingerprint'
require_relative '../lib/ruby4lich5/resolution_lock'
abort 'Usage: record_patch_fingerprints.rb <lock> <output> [<replacement-plan>]' unless [2, 3].include?(ARGV.length)
begin
  lock_path, output, plan_path = ARGV
  record = if plan_path
             Ruby4Lich5::PatchFingerprint.validate!(JSON.parse(File.read(plan_path)).fetch('patch_fingerprints'))
           else
             Ruby4Lich5::PatchFingerprint.current(Ruby4Lich5::ResolutionLock.from_h(JSON.parse(File.read(lock_path))))
           end
  File.write(output, JSON.pretty_generate(record) + "\n")
rescue StandardError => e
  warn "ERROR: #{e.class}: #{e.message}"
  exit 1
end
