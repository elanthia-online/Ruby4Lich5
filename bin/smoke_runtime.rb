#!/usr/bin/env ruby
# frozen_string_literal: true

require 'json'
require_relative '../lib/ruby4lich5/runtime_smoke'

abort "Usage: #{$PROGRAM_NAME} <resolution_lock_json>" unless ARGV.size == 1
begin
  lock = Ruby4Lich5::ResolutionLock.from_h(JSON.parse(File.read(ARGV.first, encoding: 'bom|utf-8')))
  Ruby4Lich5::RuntimeSmoke.run!(lock)
  puts 'Selected runtime roots, versions and applicable GTK/image probes passed.'
rescue StandardError, LoadError => e
  warn "ERROR: #{e.class}: #{e.message}"
  exit 1
end
