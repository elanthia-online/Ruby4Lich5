#!/usr/bin/env ruby
# frozen_string_literal: true

require 'json'
require_relative '../lib/ruby4lich5/promotion_plan'
require_relative '../lib/ruby4lich5/smoke_contract'
require_relative '../lib/ruby4lich5/supported_startup_policy'

abort "Usage: #{$PROGRAM_NAME} <preparation_directory> <repository> <inspect|promote>" unless ARGV.size == 3
directory, repository, mode = ARGV
begin
  raise ArgumentError, 'mode must be inspect or promote' unless %w[inspect promote].include?(mode)

  release = JSON.parse(File.read(File.join(directory, 'candidate-release.json'), encoding: 'bom|utf-8'))
  raise ArgumentError, 'candidate must be published for public recovery' unless release['isDraft'] == false

  manifest_path = File.join(directory, 'candidate/R4L5-gem-manifest.json')
  lock_path = File.join(directory, 'bundle/resolution-lock.json')
  lock = Ruby4Lich5::ResolutionLock.from_h(JSON.parse(File.read(lock_path, encoding: 'bom|utf-8')))
  Ruby4Lich5::RuntimeContract.require_promotable!(lock)
  Ruby4Lich5::SmokeContract.for_lock(lock)
  plan = Ruby4Lich5::PromotionPlan.build(
    candidate_bytes: File.binread(manifest_path), live_bytes: File.binread(File.join(directory, 'live/R4L5-gem-manifest.json')),
    candidate_tag: release.fetch('tagName'), repository: repository, assets: release.fetch('assets'), source_sha: release.fetch('targetCommitish'),
    supported_startup_policy: Ruby4Lich5::SupportedStartupPolicy.identity(lock.contract)
  )
  rollback_directory = File.join(directory, 'rollback')
  Dir.mkdir(rollback_directory) unless Dir.exist?(rollback_directory)
  File.binwrite(File.join(rollback_directory, 'R4L5-gem-manifest.json'), Ruby4Lich5::PromotionPlan.rollback_bytes(
                                                                           File.binread(File.join(directory, 'live/R4L5-gem-manifest.json')), File.binread(manifest_path)
                                                                         ))
  File.write(File.join(directory, 'promotion-plan.json'), JSON.pretty_generate(plan))
  if mode == 'promote'
    Ruby4Lich5::PromotionPlan.approve!(
      plan, candidate_digest: ENV.fetch('APPROVED_CANDIDATE_DIGEST', ''), live_digest: ENV.fetch('APPROVED_LIVE_DIGEST', ''),
      change_digest: ENV.fetch('APPROVED_CHANGE_DIGEST', '')
    )
  end
  targets = JSON.parse(File.binread(manifest_path)).fetch('targets')
  raise ArgumentError, 'this gate requires one runtime target' unless targets.size == 1

  units = targets.first.fetch('units')
  raise ArgumentError, 'candidate manifest contract differs from tested lock' unless targets.first['contract'] == lock.contract
  context = plan.merge(
    'ranged_consumer' => lock.contract.fetch('recovery_consumer'), 'lich_version' => lock.contract.fetch('lich_version'),
    'manifest_path' => 'candidate/R4L5-gem-manifest.json', 'lock_path' => 'bundle/resolution-lock.json',
    'manifest_url' => "https://github.com/#{repository}/releases/download/#{release.fetch('tagName')}/R4L5-gem-manifest.json",
    'ruby_installer_version' => lock.ruby_installer_version,
    'native_restart_required' => units.any? { |unit| unit.fetch('members').include?('gtk3') },
    'ranged_members' => Lich::RecoveryUnitPolicy.select(targets.first, lock.contract.fetch('lich_version')).flat_map { |unit| unit.fetch('members') }.uniq.sort,
    'expected_members' => units.reject { |unit| unit.key?('lich_versions') }.flat_map { |unit| unit.fetch('members') }.uniq.sort,
    'ruby_archive_digest' => JSON.parse(File.read(File.join(directory, 'bundle/gem-build-metadata.json'), encoding: 'bom|utf-8')).fetch('ruby_archive_digest')
  )
  File.write(File.join(directory, 'gate-context.json'), JSON.pretty_generate(context))
  puts JSON.pretty_generate(plan)
rescue StandardError => e
  warn "ERROR: #{e.class}: #{e.message}"
  exit 1
end
