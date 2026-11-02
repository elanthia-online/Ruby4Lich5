#!/usr/bin/env ruby
# frozen_string_literal: true

require 'json'
require_relative '../lib/ruby4lich5/resolution_lock'
abort 'Usage: require_runtime_contract.rb <lock.json>' unless ARGV.length == 1
begin
  lock = Ruby4Lich5::ResolutionLock.from_h(JSON.parse(File.read(ARGV[0], encoding: 'bom|utf-8')))
  Ruby4Lich5::RuntimeContract.require_promotable!(lock)
rescue StandardError => e
  warn "Unpromotable build: #{e.message}"
  exit 2
end
