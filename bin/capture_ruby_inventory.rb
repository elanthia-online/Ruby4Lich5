#!/usr/bin/env ruby
# frozen_string_literal: true

require 'json'
require 'rubygems'
require_relative '../lib/ruby4lich5/ruby_inventory'
require_relative '../lib/ruby4lich5/target_platform'

abort 'Usage: capture_ruby_inventory.rb <output.json> <expected Ruby version>' unless ARGV.length == 2
abort 'Inventory requires the genuine clean target Windows RubyInstaller' unless Gem::Platform.local.to_s == Ruby4Lich5::TargetPlatform.current.name && RUBY_VERSION == ARGV[1]
File.write(ARGV[0], JSON.pretty_generate(Ruby4Lich5::RubyInventory.capture) + "\n")
