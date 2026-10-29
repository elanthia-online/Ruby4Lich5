#!/usr/bin/env ruby
# frozen_string_literal: true

# Uses already-acquired package bytes and RubyGems versions metadata; no network,
# installation or publication. Retire with Sqlite3RecoveryUpdate in effort 5.
require 'json'
require_relative '../lib/ruby4lich5/sqlite3_recovery_update'

if ARGV.size != 4
  warn "Usage: #{$PROGRAM_NAME} <input_manifest> <sqlite3_gem> <versions_json> <output_manifest>"
  exit 2
end

begin
  result = Ruby4Lich5::Sqlite3RecoveryUpdate.prepare(
    manifest: JSON.parse(File.read(ARGV[0], encoding: 'bom|utf-8')), gem_path: ARGV[1],
    versions: JSON.parse(File.read(ARGV[2], encoding: 'bom|utf-8'))
  )
  File.write(ARGV[3], JSON.pretty_generate(result) + "\n")
  puts 'Prepared sqlite3 2.10.2 recovery entry; other units and order preserved. Nothing published.'
rescue StandardError => e
  warn "ERROR: #{e.class}: #{e.message}"
  exit 1
end
