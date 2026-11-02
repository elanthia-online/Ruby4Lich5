#!/usr/bin/env ruby
# frozen_string_literal: true

require 'json'
require_relative '../lib/ruby4lich5/installer_inventory_check'

if ARGV.size != 2
  warn "Usage: #{$PROGRAM_NAME} <accepted_manifest_json> <pkg_dir>"
  exit 2
end

begin
  Ruby4Lich5::InstallerInventoryCheck.validate!(
    manifest: JSON.parse(File.read(ARGV[0], encoding: 'bom|utf-8')), pkg_dir: ARGV[1]
  )
  puts 'Installer inventory matches accepted recovery versions; sqlite3 target ABI is present.'
rescue StandardError => e
  warn "ERROR: #{e.class}: #{e.message}"
  exit 1
end
