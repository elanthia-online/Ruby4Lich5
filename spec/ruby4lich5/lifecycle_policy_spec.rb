# frozen_string_literal: true

require 'ruby4lich5/lifecycle_policy'
require 'ruby4lich5/promotion_plan'
require_relative '../../vendor/lich5/runtime_gem_contract'

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

  it 'keeps a promoted withdrawal when later config omits it and the factory still produces its locked roots' do
    rule = { 'state' => 'withdrawn', 'until_date' => '2020-01-01', 'roots' => ['gtk3'] }
    withdrawn = policy(units: { 'gtk3-runtime' => rule }).apply(current, previous)
    rebuilt = Marshal.load(Marshal.dump(previous))
    later = policy.apply(rebuilt, withdrawn)
    expect(later).to eq(withdrawn)
    expect(policy.apply(rebuilt, later)).to eq(withdrawn)
    expect(described_class.rollback(previous, later).fetch('targets').first.fetch('units').map { |item| item['id'] }).to eq(['other'])
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

  def withdrawal_sequence
    target = source.fetch('targets').first
    redis = target.fetch('units').find { |unit| unit['id'] == 'redis' }
    sequel = target.fetch('units').find { |unit| unit['id'] == 'sequel' }
    pool = redis.fetch('packages').find { |package| package['name'] == 'connection_pool' }
    raise 'fixture must include redis-owned connection_pool' unless pool

    changed = Marshal.load(Marshal.dump(source))
    changed_sequel = changed.fetch('targets').first.fetch('units').find { |unit| unit['id'] == sequel['id'] }
    changed_sequel['members'] << 'connection_pool'
    changed_sequel['packages'] << pool
    changed_sequel['install_order'].unshift('connection_pool')
    policy = Ruby4Lich5::LifecyclePolicy.new('schema' => 1, 'units' => {
      'redis' => { 'state' => 'withdrawn', 'until_date' => '2020-01-01', 'roots' => ['redis'] }
    }, 'ranges' => {})
    [changed, policy.apply(changed, source)]
  end

  it 'promotes a withdrawal with a simultaneous closure change and keeps the transferred shared dependency' do
    rebuilt, candidate = withdrawal_sequence
    expect(candidate.fetch('targets').first.fetch('withdrawn_members')).to eq(%w[redis redis-client])
    expect { promote(source, candidate) }.not_to raise_error
    empty_policy = Ruby4Lich5::LifecyclePolicy.new('schema' => 1, 'units' => {}, 'ranges' => {})
    later = empty_policy.apply(rebuilt, candidate)
    expect(later.fetch('targets').first.fetch('withdrawn_members')).to eq(%w[redis redis-client])
    expect { promote(candidate, later) }.not_to raise_error
  end

  it 'retains exact historical decisions through two promotions and an empty-config rebuild' do
    _rebuilt, first = withdrawal_sequence
    removed = first.fetch('targets').first.fetch('units').reject { |unit| unit['id'] == 'webrick' }
    next_input = Marshal.load(Marshal.dump(first))
    next_input.fetch('targets').first['units'] = removed
    second = Ruby4Lich5::LifecyclePolicy.new('schema' => 1, 'units' => { 'webrick' => { 'state' => 'withdrawn', 'until_date' => '2020-01-01', 'roots' => ['webrick'] } }, 'ranges' => {}).apply(next_input, first)
    expect { promote(first, second) }.not_to raise_error
    tampered = Marshal.load(Marshal.dump(second))
    tampered.fetch('targets').first.fetch('withdrawals').delete('redis')
    expect { promote(first, tampered) }.to raise_error(ArgumentError, /recorded withdrawal decision/)
    tampered = Marshal.load(Marshal.dump(second))
    tampered.fetch('targets').first.fetch('withdrawals').fetch('redis')['roots'] = ['redis-client']
    expect { promote(first, tampered) }.to raise_error(ArgumentError, /recorded withdrawal decision/)
    expect(Ruby4Lich5::LifecyclePolicy.new('schema' => 1, 'units' => {}, 'ranges' => {}).apply(next_input, second)).to eq(second)
  end

  def real_tzinfo_lock(version)
    fixture = File.expand_path('../fixtures/lifecycle-lock-transition', __dir__)
    files = ["tzinfo-#{version}", version == '2.0.6' ? nil : 'thread_safe-0.3.6', 'tzinfo-data-1.2026.5'].compact
    metadata = files.map { |name| JSON.parse(File.read(File.join(fixture, "#{name}.json"))) }
    if version == '2.0.6'
      package = source.fetch('targets').first.fetch('units').find { |unit| unit['id'] == 'concurrent-ruby' }.fetch('packages').first
      metadata << { 'name' => 'concurrent-ruby', 'version' => package.fetch('version'), 'sha' => package.fetch('sha256').delete_prefix('sha256:'), 'dependencies' => { 'runtime' => [] } }
    end
    specs = metadata.map do |entry|
      "    #{entry.fetch('name')} (#{entry.fetch('version')})\n" + entry.fetch('dependencies').fetch('runtime').map { |dep| "      #{dep.fetch('name')} (#{dep.fetch('requirements')})\n" }.join
    end.join
    checksums = metadata.map { |entry| "  #{entry.fetch('name')} (#{entry.fetch('version')}) sha256=#{entry.fetch('sha')}\n" }.join
    lock = "GEM\n  remote: https://rubygems.org/\n  specs:\n#{specs}\nPLATFORMS\n  x64-mingw-ucrt\n\nDEPENDENCIES\n  tzinfo\n  tzinfo-data\n\nCHECKSUMS\n#{checksums}"
    reader = Lich::RuntimeGemContract.new(gemfile: "gem 'tzinfo'\ngem 'tzinfo-data'\n", lockfile: lock)
    inventory = { 'platform' => 'x64-mingw-ucrt', 'ruby_abi' => '4.0', 'gems' => {} }
    [reader, reader.resolve(inventory)]
  end

  it 'retires a demonstrated tzinfo lock orphan without changing the withdrawal decision or removing its survivor' do
    _old_reader, old_graph = real_tzinfo_lock('2.0.6')
    _new_reader, new_graph = real_tzinfo_lock('1.2.11')
    expect(old_graph.fetch('packages')).to have_key('concurrent-ruby')
    expect(new_graph.fetch('packages')).not_to have_key('concurrent-ruby')
    expect(new_graph.fetch('packages')).to have_key('thread_safe')
    # A reviewed declaration change removes the standalone concurrent-ruby
    # root, while tzinfo still shares it. No dependency edge is invented.
    input = Marshal.load(Marshal.dump(source))
    input.fetch('targets').first.fetch('units').reject! { |unit| unit['id'] == 'concurrent-ruby' }
    decision = { 'state' => 'withdrawn', 'until_date' => '2020-01-01', 'roots' => ['tzinfo-data'] }
    first = Ruby4Lich5::LifecyclePolicy.new('schema' => 1, 'units' => { 'tzinfo-data' => decision }, 'ranges' => {}).apply(input, source)
    expect { promote(source, first) }.not_to raise_error
    expect(first.fetch('targets').first.fetch('withdrawn_members')).not_to include('concurrent-ruby')
    next_input = Marshal.load(Marshal.dump(first))
    unit = next_input.fetch('targets').first.fetch('units').find { |entry| entry['id'] == 'tzinfo' }
    packages = new_graph.fetch('packages').reject { |name, _| name == 'tzinfo-data' }
    unit['members'] = packages.keys.sort
    unit['install_order'] = %w[thread_safe tzinfo]
    unit['packages'] = packages.map { |name, entry| { 'name' => name, 'version' => entry.fetch('version'), 'filename' => "#{name}-#{entry.fetch('version')}.gem", 'sha256' => "sha256:#{entry.fetch('sha256')}" } }
    unit['artifact'] = { 'url' => "https://github.com/elanthia-online/Ruby4Lich5/releases/download/#{tag}/tzinfo-transition.zip", 'archive' => 'zip', 'filename' => 'tzinfo-transition.zip', 'sha256' => "sha256:#{'a' * 64}" }
    empty = Ruby4Lich5::LifecyclePolicy.new('schema' => 1, 'units' => {}, 'ranges' => {})
    second = empty.apply(next_input, first)
    expect(second.fetch('targets').first.fetch('withdrawals')).to eq(first.fetch('targets').first.fetch('withdrawals'))
    expect(second.fetch('targets').first.fetch('withdrawn_members')).to include('concurrent-ruby', 'tzinfo-data')
    expect(second.fetch('targets').first.fetch('units').map { |entry| entry['id'] }).to include('tzinfo')
    expect { promote(first, second) }.not_to raise_error
    expect(empty.apply(second, second)).to eq(second)
    expect { promote(second, second) }.not_to raise_error
    tampered = Marshal.load(Marshal.dump(second))
    tampered.fetch('targets').first.fetch('withdrawal_members').fetch('tzinfo-data') << 'ox'
    expect { promote(first, tampered) }.to raise_error(ArgumentError, /closure history/)
    tampered = Marshal.load(Marshal.dump(second))
    tampered.fetch('targets').first.delete('withdrawal_members')
    expect { promote(first, tampered) }.to raise_error(ArgumentError, /closure history/)
  end

  it 'rejects an injected orphan history before any withdrawal has been approved' do
    candidate = Marshal.load(Marshal.dump(source))
    candidate.fetch('targets').first['withdrawal_members'] = { 'redis' => ['ox'] }
    expect { promote(source, candidate) }.to raise_error(ArgumentError, /closure history requires/)
  end

  it 'rejects an unrelated over-withdrawal and an omitted orphan after a simultaneous closure change' do
    _rebuilt, candidate = withdrawal_sequence
    tampered = Marshal.load(Marshal.dump(candidate))
    tampered.fetch('targets').first['withdrawn_members'].delete('redis-client')
    expect { promote(source, tampered) }.to raise_error(ArgumentError, /withdrawal requires|exact removed/)
    target = candidate.fetch('targets').first
    target.fetch('units').reject! { |unit| unit['id'] == 'ox' }
    target.fetch('withdrawn_members') << 'ox'
    target.fetch('withdrawn_members').sort!
    expect { promote(source, candidate) }.to raise_error(Lich::RecoveryUnitPolicy::Error, /unsupported coverage removal/)
  end
end
