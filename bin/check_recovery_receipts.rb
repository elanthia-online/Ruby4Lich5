#!/usr/bin/env ruby
# frozen_string_literal: true

require 'json'
require_relative '../lib/ruby4lich5/recovery_receipts'

abort "Usage: #{$PROGRAM_NAME} <context_json> <receipt_directory>" unless ARGV.size == 2
begin
  context = JSON.parse(File.read(ARGV[0], encoding: 'bom|utf-8'))
  receipts = Ruby4Lich5::RecoveryReceipts.required_consumers(context).map { |name| JSON.parse(File.read(File.join(ARGV[1], "#{name}.json"), encoding: 'bom|utf-8')) }
  Ruby4Lich5::RecoveryReceipts.verify!(context, receipts)
  puts "#{receipts.length} exact-candidate consumer recovery receipts verified."
rescue StandardError => e
  warn "ERROR: #{e.class}: #{e.message}"
  exit 1
end
