#!/usr/bin/env ruby
# frozen_string_literal: true

require 'json'
require 'digest'
require_relative '../lib/ruby4lich5/resolution_lock'
abort 'Usage: record_installer_contract.rb <provenance.json> <accepted_manifest.json> <lock.json>' unless ARGV.length == 3
provenance = JSON.parse(File.read(ARGV[0], encoding: 'bom|utf-8'))
manifest_bytes = File.binread(ARGV[1])
manifest = JSON.parse(manifest_bytes)
lock = Ruby4Lich5::ResolutionLock.from_h(JSON.parse(File.read(ARGV[2], encoding: 'bom|utf-8')))
Ruby4Lich5::RuntimeContract.require_promotable!(lock)
target = manifest.fetch('targets').find { |item| item['platform'] == lock.platform && item['ruby_abi'] == lock.ruby_abi }
abort 'Installer cannot attest a different accepted runtime contract' unless target && target['contract'] == lock.contract
provenance['runtime_contract_sha256'] = Lich::RuntimeGemContract.digest(lock.contract)
provenance['recovery_manifest_sha256'] = Digest::SHA256.hexdigest(manifest_bytes)
provenance['lich5_commit'] = lock.contract.fetch('lich5_commit')
File.write(ARGV[0], JSON.pretty_generate(provenance) + "\n")
