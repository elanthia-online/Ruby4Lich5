#!/usr/bin/env ruby
# frozen_string_literal: true

require_relative '../lib/ruby4lich5/verified_https'
abort 'Usage: fetch_contract_document.rb <https_url> <output_path>' unless ARGV.length == 2
bytes = Ruby4Lich5::VerifiedHttps.read(ARGV[0])
abort 'Contract document exceeds 5 MiB' if bytes.bytesize > 5 * 1024 * 1024
File.binwrite(ARGV[1], bytes)
