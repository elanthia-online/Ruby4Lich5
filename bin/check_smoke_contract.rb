#!/usr/bin/env ruby
# frozen_string_literal: true

require 'json'
require_relative '../lib/ruby4lich5/smoke_contract'

abort "Usage: #{$PROGRAM_NAME} <resolution_lock_json>" unless ARGV.size == 1
begin
  lock = Ruby4Lich5::ResolutionLock.from_h(JSON.parse(File.read(ARGV.first, encoding: 'bom|utf-8')))
  puts JSON.pretty_generate(Ruby4Lich5::SmokeContract.for_lock(lock))
rescue StandardError => e
  warn "ERROR: #{e.class}: #{e.message}"
  exit 1
end
