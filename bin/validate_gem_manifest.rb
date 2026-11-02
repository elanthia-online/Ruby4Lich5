#!/usr/bin/env ruby
# frozen_string_literal: true

require 'json'
require_relative '../lib/ruby4lich5/gem_manifest_validator'

if ARGV.size != 1
  warn "Usage: #{$PROGRAM_NAME} <manifest_json_path>"
  exit 2
end

begin
  Ruby4Lich5::GemManifestValidator.validate!(JSON.parse(File.read(ARGV.first, encoding: 'bom|utf-8')))
  puts "Manifest accepted by lich-5 #{Ruby4Lich5::GemManifestValidator::CONSUMER_COMMIT} (planning only)"
rescue StandardError => e
  warn "ERROR: #{e.class}: #{e.message}"
  exit 1
end
