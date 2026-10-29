#!/usr/bin/env ruby
# frozen_string_literal: true

require 'json'
require_relative '../lib/ruby4lich5/ruby_inventory'
require_relative '../lib/ruby4lich5/resolution_lock'
abort 'Usage: check_ruby_inventory.rb <lock.json>' unless ARGV.length == 1
lock = Ruby4Lich5::ResolutionLock.from_h(JSON.parse(File.read(ARGV[0], encoding: 'bom|utf-8')))
Ruby4Lich5::RubyInventory.verify!(lock.contract.fetch('ruby_inventory'))
