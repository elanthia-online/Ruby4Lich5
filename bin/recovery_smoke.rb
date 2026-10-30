#!/usr/bin/env ruby
# frozen_string_literal: true

require 'json'
require 'digest'
require_relative '../lib/ruby4lich5/recovery_consumers'
require_relative '../lib/ruby4lich5/runtime_smoke'
require_relative '../lib/ruby4lich5/verified_https'
require_relative '../lib/ruby4lich5/recovery_sequence'
require_relative '../lib/ruby4lich5/ruby_inventory'
require_relative '../lib/ruby4lich5/supported_startup_policy'

abort "Usage: #{$PROGRAM_NAME} <consumer> <context_json> <receipt_json>" unless ARGV.size == 3
key, context_path, receipt_path = ARGV
begin
  raise 'recovery acceptance requires Windows RubyInstaller' unless Gem.win_platform?

  context = JSON.parse(File.read(context_path, encoding: 'bom|utf-8'))
  consumer = Ruby4Lich5::RecoveryConsumers.entry(key, context: context)
  require consumer.fetch('absolute_path')
  lock = Ruby4Lich5::ResolutionLock.from_h(JSON.parse(File.read(File.expand_path(context.fetch('lock_path'), File.dirname(context_path)), encoding: 'bom|utf-8')))
  raise 'wrong RubyInstaller version or platform' unless RUBY_VERSION == lock.ruby_installer_version.split('-').first && Gem::Platform.local.to_s == lock.platform

  bytes = File.binread(File.expand_path(context.fetch('manifest_path'), File.dirname(context_path)))
  expected_digest = context.fetch('candidate_sha256')
  raise 'candidate manifest changed before smoke' unless "sha256:#{Digest::SHA256.hexdigest(bytes)}" == expected_digest

  manifest = JSON.parse(bytes)
  target = manifest.fetch('targets').find { |item| item['ruby_abi'] == lock.ruby_abi && item['platform'] == lock.platform }
  raise 'candidate lacks the selected runtime target' unless target

  if key == 'ranged'
    policy_digest = Ruby4Lich5::SupportedStartupPolicy.verify!(
      manifest_bytes: bytes, context: context, source_directory: File.expand_path('..', File.dirname(consumer.fetch('absolute_path')))
    )
    target = target.merge('units' => Lich::RecoveryUnitPolicy.select(target, context.fetch('lich_version')))
  else
    units = target.fetch('units').reject { |unit| unit.key?('lich_versions') }
    first_matches = units.flat_map { |unit| unit.fetch('members') }.uniq.map { |name| units.find { |unit| unit.fetch('members').include?(name) } }.uniq
    target = target.merge('units' => first_matches)
  end
  packages = target.fetch('units').flat_map { |unit| unit.fetch('packages') }
  names = target.fetch('units').flat_map { |unit| unit.fetch('members') }.uniq
  pending_path = "#{receipt_path}.pending"
  resumed = File.file?(pending_path)
  if resumed
    pending = JSON.parse(File.read(pending_path))
    unless pending['state'] == 'awaiting-restart' && pending['candidate_sha256'] == expected_digest && pending['consumer'] == key && pending['parent_pid'] != Process.pid
      raise 'invalid native recovery restart state'
    end
  else
    Ruby4Lich5::RuntimeContract.require_promotable!(lock)
    Ruby4Lich5::RubyInventory.verify!(lock.contract.fetch('ruby_inventory'))
    raise 'clean recovery runner contains preinstalled application gems' if packages.any? { |package| !Gem::Specification.find_all_by_name(package.fetch('name')).empty? }
    pending = { 'consumer' => key, 'candidate_sha256' => expected_digest, 'native_restarts' => 0 }
  end
  pending['state'] = 'preparing'
  pending['parent_pid'] = Process.pid
  File.write(pending_path, JSON.generate(pending))
  fetch = lambda do |url|
    result = Ruby4Lich5::VerifiedHttps.read(url)
    if url == context.fetch('manifest_url') && "sha256:#{Digest::SHA256.hexdigest(result)}" != expected_digest
      raise 'remote manifest changed since inspection'
    end
    result
  end
  recovery = Lich::DependencyRecovery.new(manifest_url: context.fetch('manifest_url'), temp_dir: File.dirname(receipt_path), http_get: fetch, **(key == 'ranged' ? { lich_version: context.fetch('lich_version') } : {}))
  target.fetch('units').each { |unit| recovery.send(:validate_unit!, unit) }
  while (batch = Ruby4Lich5::RecoverySequence.next_plan(recovery, names))
    # Call below consent UI, retaining real download, verification, installation,
    # GTK helper, parent-exit wait and restart. The restarted program is this probe.
    result = recovery.recover(names, plan: batch)
    raise "recovery failed: #{result.error}" unless result.success?
    if result.restart_required
      pending['state'] = 'awaiting-restart'
      pending['native_restarts'] += 1
      File.write(pending_path, JSON.generate(pending))
      exit 0
    end
    unless batch.units.flat_map { |unit| unit.fetch('packages') }.all? { |package| !Gem::Specification.find_all_by_name(package.fetch('name'), "= #{package.fetch('version')}").empty? }
      raise 'recovery returned without registering the requested package versions'
    end
  end
  restart_used = pending.fetch('native_restarts').positive?
  if Ruby4Lich5::SmokeContract.for_lock(lock).fetch('gtk') && !restart_used
    raise 'GTK recovery did not exercise its native helper and restart'
  end
  packages.each do |package|
    Gem::Specification.find_by_name(package.fetch('name'), "= #{package.fetch('version')}")
  end
  Ruby4Lich5::RuntimeSmoke.run!(lock, versions: packages.to_h { |package| [package.fetch('name'), package.fetch('version')] })
  receipt = {
    'schema' => 1, 'consumer' => key, 'consumer_commit' => consumer.fetch('commit'), 'consumer_sha256' => consumer.fetch('sha256'),
    'candidate_sha256' => expected_digest, 'change_sha256' => context.fetch('change_sha256'),
    'source_sha' => context.fetch('source_sha'), 'assets' => context.fetch('assets'),
    'ruby_installer_version' => lock.ruby_installer_version, 'ruby_archive_digest' => context.fetch('ruby_archive_digest'),
    'members' => names.sort, 'native_restart' => restart_used, 'success' => true
  }
  receipt['supported_startup_policy_sha256'] = policy_digest if key == 'ranged'
  File.write(receipt_path, JSON.pretty_generate(receipt))
rescue StandardError, LoadError => e
  File.write("#{receipt_path}.error", "#{e.class}: #{e.message}\n") if receipt_path
  warn "ERROR: #{e.class}: #{e.message}"
  exit 1
end
