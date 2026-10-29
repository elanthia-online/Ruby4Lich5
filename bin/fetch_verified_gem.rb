#!/usr/bin/env ruby
# frozen_string_literal: true

require 'fileutils'
require 'digest'
require 'json'
require_relative '../lib/ruby4lich5/rubygems_client'
abort 'Usage: fetch_verified_gem.rb <name> <version> <platform> <directory> [lock.json]' unless [4, 5].include?(ARGV.length)
name, version, platform, directory, lock_path = ARGV
client = Ruby4Lich5::RubygemsClient.new
source = client.download_gem(name, version, platform: platform)
if lock_path
  lock = JSON.parse(File.read(lock_path))
  expected = lock.dig('contract', 'expected_packages', name)
  if lock.dig('contract', 'promotable') && expected && expected['platform'] == platform &&
     (expected['version'] != version || expected['sha256'] != Digest::SHA256.file(source).hexdigest)
    abort "Source package differs from the selected lich-5 lock: #{name}"
  end
end
filename = client.asset_filename(name, version, platform)
FileUtils.cp(source, File.join(directory, filename))
receipt_path = File.join(directory, 'verified-source-packages.json')
receipt = File.file?(receipt_path) ? JSON.parse(File.read(receipt_path)) : {}
receipt[filename] = { 'url' => "https://rubygems.org/downloads/#{filename}", 'sha256' => Digest::SHA256.file(source).hexdigest }
File.write(receipt_path, JSON.pretty_generate(receipt) + "\n")
