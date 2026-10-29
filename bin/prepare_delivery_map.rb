#!/usr/bin/env ruby
# frozen_string_literal: true

require 'json'
require_relative '../lib/ruby4lich5/resolution_lock'
require_relative '../lib/ruby4lich5/delivery_map'
abort 'Usage: prepare_delivery_map.rb <lock.json> <pkg_directory>' unless ARGV.length == 2
lock = Ruby4Lich5::ResolutionLock.from_h(JSON.parse(File.read(ARGV[0])))
map = Ruby4Lich5::DeliveryMap.build(lock, ARGV[1])
File.write(File.join(ARGV[1], 'delivery-map.json'), JSON.pretty_generate(map) + "\n")
