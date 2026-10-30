# frozen_string_literal: true

require 'ruby4lich5/lifecycle_policy'
require 'ruby4lich5/promotion_plan'

RSpec.describe Ruby4Lich5::LifecyclePolicy do
  def unit(id, members)
    { 'id' => id, 'members' => members, 'install_order' => members,
      'packages' => members.map { |name| { 'name' => name, 'version' => '1.0', 'filename' => "#{name}-1.0.gem", 'sha256' => "sha256:#{'a' * 64}" } },
      'artifact' => { 'url' => "https://example.org/#{id}.zip", 'archive' => 'zip', 'filename' => "#{id}.zip", 'sha256' => "sha256:#{'b' * 64}" } }
  end

  let(:old_units) { [unit('gtk3-runtime', %w[gtk3 private shared]), unit('other', %w[other shared])] }
  let(:previous) { { 'schema' => 1, 'targets' => [{ 'ruby_abi' => '4.0', 'platform' => 'x64-mingw-ucrt', 'units' => old_units }] } }
  let(:current) { Marshal.load(Marshal.dump(previous)) }

  def policy(units: {}, ranges: {}, reader: nil)
    described_class.new('schema' => 1, 'units' => units, 'ranges' => ranges, 'range_reader' => reader)
  end

  it 'keeps current coverage without choosing a GTK freeze date or support floor' do
    expect(described_class.new.apply(current, previous)).to eq(previous)
    expect(JSON.parse(File.read(described_class::PATH))).to eq('schema' => 1, 'units' => {}, 'ranges' => {}, 'range_reader' => nil)
  end

  it 'carries an obsolete complete closure and artifact without rebuilding or changing its package bytes' do
    current['targets'].first['units'].reject! { |item| item['id'] == 'gtk3-runtime' }
    result = policy(units: { 'gtk3-runtime' => { 'state' => 'obsolete', 'until_date' => '2020-01-01' } }).apply(current, previous)
    retained = result.fetch('targets').first.fetch('units').first
    expect(retained.reject { |key, _| key == 'lifecycle' }).to eq(old_units.first)
    expect(retained.fetch('lifecycle')).to include('state' => 'obsolete')
    expect(result.fetch('targets').first).not_to have_key('withdrawn_members')
  end

  it 'retains obsolete service on later builds even if the policy omits its already recorded transition' do
    old_units.first['lifecycle'] = { 'state' => 'obsolete' }
    current.fetch('targets').first.fetch('units').shift
    expect(policy.apply(current, previous).fetch('targets').first.fetch('units').first).to eq(old_units.first)
  end

  it 'withdraws alternate units, preserves shared dependencies and records only orphans plus retired roots' do
    old_units << unit('alternate', %w[gtk3 private])
    current.fetch('targets').first['units'] = Marshal.load(Marshal.dump(old_units))
    rule = { 'state' => 'withdrawn', 'until_date' => '2020-01-01', 'roots' => ['gtk3'] }
    result = policy(units: { 'gtk3-runtime' => rule }).apply(current, previous)
    target = result.fetch('targets').first
    expect(target.fetch('units').map { |item| item['id'] }).to eq(['other'])
    expect(target.fetch('withdrawn_members')).to eq(%w[gtk3 private])
    expect(target.fetch('units').first.fetch('members')).to include('shared')
    rollback = described_class.rollback(previous, result)
    expect(rollback.fetch('targets').first.fetch('units').map { |item| item['id'] }).to eq(['other'])
    expect(rollback.fetch('targets').first.fetch('withdrawn_members')).to eq(%w[gtk3 private])
  end

  it 'requires an explicit reached boundary for withdrawal and never treats metadata alone as permission' do
    rule = { 'state' => 'withdrawn', 'roots' => ['gtk3'] }
    expect { policy(units: { 'gtk3-runtime' => rule }) }.to raise_error(described_class::Error, /support boundary/)
    rule['until_date'] = '2099-01-01'
    expect { policy(units: { 'gtk3-runtime' => rule }).apply(current, previous, today: Date.new(2026, 10, 29)) }.to raise_error(described_class::Error, /not been reached/)
    rule.delete('until_date')
    rule['floor_lich_version'] = '5.25.0'
    current.fetch('targets').first['contract'] = { 'lich_version' => '5.24.0' }
    expect { policy(units: { 'gtk3-runtime' => rule }).apply(current, previous) }.to raise_error(described_class::Error, /floor has not/)
    current.fetch('targets').first['contract']['lich_version'] = '5.25.0'
    expect(policy(units: { 'gtk3-runtime' => rule }).apply(current, previous).fetch('targets').first.fetch('withdrawn_members')).to eq(%w[gtk3 private])
  end

  it 'rejects invalid dates, simultaneous boundaries and unknown unit transitions' do
    expect { policy(units: { 'other' => { 'state' => 'obsolete', 'until_date' => '2026-02-31' } }) }.to raise_error(described_class::Error, /end date/)
    expect { policy(units: { 'other' => { 'state' => 'obsolete', 'until_date' => '2026-01-01', 'floor_lich_version' => '5.25' } }) }.to raise_error(described_class::Error, /lifecycle/)
    expect { policy(units: { 'unknown' => { 'state' => 'obsolete' } }).apply(current, previous) }.to raise_error(described_class::Error, /unknown lifecycle/)
  end

  it 'emits immutable legacy-first closures and selects new versions only within their reviewed ranges' do
    current.fetch('targets').first.fetch('units').first.fetch('packages').first['version'] = '2.0'
    reader = { 'release' => 'v5.24.0', 'commit' => 'c' * 40 }
    result = policy(ranges: { 'gtk3-runtime' => { 'min_inclusive' => '5.24.0' } }, reader: reader).apply(current, previous)
    target = result.fetch('targets').first
    expect(target.fetch('units').first).to eq(old_units.first)
    expect(target.fetch('units').map { |unit| unit['id'] }).to eq(%w[gtk3-runtime other gtk3-runtime-ranged other-ranged])
    expect(Lich::RecoveryUnitPolicy.select(target, '5.24').map { |unit| unit['id'] }).to eq(%w[gtk3-runtime-ranged other-ranged])
    expect(Lich::RecoveryUnitPolicy.select(target, '5.23').first.fetch('packages').first['version']).to eq('1.0')
    expect(Lich::RecoveryUnitPolicy.select(target, '5.24').first.fetch('packages').first['version']).to eq('2.0')
  end

  it 'does not permit silent removal of supported units' do
    current.fetch('targets').first['units'] = []
    expect { policy.apply(current, previous) }.to raise_error(described_class::Error, /unsupported coverage removal/)
  end
end

RSpec.describe 'Lifecycle promotion guarantees' do
  let(:source) { JSON.parse(File.read(File.expand_path('../../manifest/R4L5-gem-manifest.json', __dir__))) }
  let(:tag) { 'R4L5-gem-bundle-x64-mingw-ucrt-candidate-123-1' }

  def promote(previous, candidate)
    bytes = JSON.generate(candidate)
    assets = candidate.fetch('targets').flat_map { |target| target.fetch('units') }.select { |unit| unit.dig('artifact', 'url').include?("/#{tag}/") }.to_h do |unit|
      [unit.dig('artifact', 'filename'), unit.dig('artifact', 'sha256')]
    end
    assets['R4L5-gem-manifest.json'] = Ruby4Lich5::PromotionPlan.digest(bytes)
    Ruby4Lich5::PromotionPlan.build(candidate_bytes: bytes, live_bytes: JSON.generate(previous), candidate_tag: tag,
                                    repository: 'elanthia-online/Ruby4Lich5', assets: assets.map { |name, digest| { 'name' => name, 'digest' => digest } }, source_sha: 'c' * 40)
  end

  it 'binds a withdrawal-safe rollback digest into the exact change approval' do
    policy = Ruby4Lich5::LifecyclePolicy.new('schema' => 1, 'units' => { 'ox' => { 'state' => 'withdrawn', 'until_date' => '2020-01-01', 'roots' => ['ox'] } }, 'ranges' => {}, 'range_reader' => nil)
    candidate = policy.apply(source, source)
    plan = promote(source, candidate)
    rollback = Ruby4Lich5::PromotionPlan.rollback_bytes(JSON.generate(source), JSON.generate(candidate))
    expect(plan.fetch('rollback_sha256')).to eq(Ruby4Lich5::PromotionPlan.digest(rollback))
    expect(JSON.parse(rollback).fetch('targets').first.fetch('units').flat_map { |unit| unit.fetch('members') }).not_to include('ox')
  end

  it 'never reintroduces a withdrawn package through a rollback candidate' do
    policy = Ruby4Lich5::LifecyclePolicy.new('schema' => 1, 'units' => { 'ox' => { 'state' => 'withdrawn', 'until_date' => '2020-01-01', 'roots' => ['ox'] } }, 'ranges' => {}, 'range_reader' => nil)
    withdrawn = policy.apply(source, source)
    expect { promote(withdrawn, source) }.to raise_error(ArgumentError, /cannot be reintroduced/)
    # Subsequent builds carry the tombstone and explicit decision forward.
    expect(policy.apply(withdrawn, withdrawn)).to eq(withdrawn)
    expect { promote(withdrawn, withdrawn) }.not_to raise_error
  end

  it 'requires an explicit released range reader and preserves legacy-first bytes across subsequent promotions' do
    candidate = Marshal.load(Marshal.dump(source))
    target = candidate.fetch('targets').first
    legacy = target.fetch('units').find { |unit| unit['id'] == 'ox' }
    target.fetch('units') << legacy.merge('id' => 'ox-ranged', 'lich_versions' => { 'min_inclusive' => '5.24.0' })
    expect { promote(source, candidate) }.to raise_error(ArgumentError, /released reader/)
    target['range_reader'] = { 'release' => 'v5.24.0', 'commit' => 'a' * 40 }
    expect { promote(source, candidate) }.not_to raise_error
    changed = Marshal.load(Marshal.dump(candidate))
    changed.fetch('targets').first.fetch('units').find { |unit| unit['id'] == 'ox' }.fetch('artifact')['url'] = 'https://example.test/changed.gem'
    expect { promote(candidate, changed) }.to raise_error(ArgumentError, /legacy closure changed/)
  end
end
