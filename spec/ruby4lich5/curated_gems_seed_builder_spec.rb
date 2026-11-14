# frozen_string_literal: true

require 'ruby4lich5/curated_gems_seed_builder'
require 'ruby4lich5/classification'
require 'json'

RSpec.describe Ruby4Lich5::CuratedGemsSeedBuilder do
  def classification(state, **overrides)
    Ruby4Lich5::Classification.new(state: state, gem_name: 'unused', gem_version: '1.0.0', reason: 'test', **overrides)
  end

  def plan_entry(name, classification, deps: [])
    { name: name, version: '1.0.0', classification: classification, runtime_dependency_names: deps }
  end

  let(:msys2_packages) { %w[mingw-w64-ucrt-x86_64-example] }

  it 'assembles a single root closure into registry-shaped gems' do
    plan = [
      plan_entry('a-root', classification(:native_self_contained, msys2_packages: msys2_packages)),
      plan_entry('a-pure-dep', classification(:pure))
    ]
    builder = described_class.new(
      root_plans: { 'a-root' => plan }, default_root_names: ['a-root'],
      platform: 'x64-mingw-ucrt', ruby_abi: '4.0', msys2_packages: msys2_packages
    )

    result = builder.build

    expect(result).to eq(
      'schema' => 2,
      'gems'   => {
        'a-root'     => {
          'approval' => 'approved', 'bundle_default' => true,
          'targets' => { 'x64-mingw-ucrt' => { '4.0' => {
            'expected_classification' => 'native_self_contained', 'msys2_packages' => msys2_packages
          } } }
        },
        'a-pure-dep' => {
          'approval' => 'approved', 'bundle_default' => false,
          'targets' => { 'x64-mingw-ucrt' => { '4.0' => { 'expected_classification' => 'pure' } } }
        }
      }
    )
  end

  it 'only sets bundle_default: true for names in default_root_names, never a transitive dependency' do
    plan = [
      plan_entry('a-root', classification(:pure)),
      plan_entry('a-transitive-dep', classification(:pure))
    ]
    builder = described_class.new(
      root_plans: { 'a-root' => plan }, default_root_names: ['a-root'],
      platform: 'x64-mingw-ucrt', ruby_abi: '4.0', msys2_packages: msys2_packages
    )

    result = builder.build

    expect(result['gems']['a-root']['bundle_default']).to be(true)
    expect(result['gems']['a-transitive-dep']['bundle_default']).to be(false)
  end

  it 'omits msys2_packages entirely for pure and native_pass_through, matching the locked schema' do
    plan = [
      plan_entry('a-pure-gem', classification(:pure)),
      plan_entry('a-pass-through-gem', classification(:native_pass_through, platform_asset: 'asset.gem'))
    ]
    builder = described_class.new(
      root_plans: { 'root' => plan }, default_root_names: [],
      platform: 'x64-mingw-ucrt', ruby_abi: '4.0', msys2_packages: msys2_packages
    )

    result = builder.build

    expect(result['gems']['a-pure-gem']['targets']['x64-mingw-ucrt']['4.0']).not_to have_key('msys2_packages')
    expect(result['gems']['a-pass-through-gem']['targets']['x64-mingw-ucrt']['4.0']).not_to have_key('msys2_packages')
  end

  it 'skips ruby_bundled members entirely -- no registry entry at all, matching the locked schema' do
    plan = [plan_entry('a-root', classification(:pure)), plan_entry('json', classification(:ruby_bundled))]
    builder = described_class.new(
      root_plans: { 'root' => plan }, default_root_names: [],
      platform: 'x64-mingw-ucrt', ruby_abi: '4.0', msys2_packages: msys2_packages
    )

    result = builder.build

    expect(result['gems']).not_to have_key('json')
  end

  describe 'regression: output ordering must not depend on root_plans insertion order' do
    # Real bug, found in CodeRabbit review: two logically-identical
    # root_plans Hashes differing only in insertion order produced Ruby
    # Hash objects that were == but serialized to different
    # JSON.pretty_generate byte sequences (JSON serialization follows Hash
    # iteration order) -- would have broken exact reproducibility for
    # CuratedGemRegistry#content_digest and the future resolution lock.
    it 'produces byte-identical JSON.pretty_generate output regardless of root_plans insertion order' do
      plan_a = [plan_entry('root-a', classification(:pure))]
      plan_b = [plan_entry('root-b', classification(:native_self_contained, msys2_packages: msys2_packages))]

      forward = described_class.new(
        root_plans: { 'root-a' => plan_a, 'root-b' => plan_b }, default_root_names: ['root-a'],
        platform: 'x64-mingw-ucrt', ruby_abi: '4.0', msys2_packages: msys2_packages
      ).build
      reversed = described_class.new(
        root_plans: { 'root-b' => plan_b, 'root-a' => plan_a }, default_root_names: ['root-a'],
        platform: 'x64-mingw-ucrt', ruby_abi: '4.0', msys2_packages: msys2_packages
      ).build

      expect(JSON.pretty_generate(reversed)).to eq(JSON.pretty_generate(forward))
      expect(forward['gems'].keys).to eq(%w[root-a root-b]) # sorted, not insertion order
    end
  end

  it 'merges a gem reached from two different roots, keeping bundle_default: true when it is itself a default root' do
    # Real gap, found in CodeRabbit review: an earlier version of this test
    # named "shared-dep" in neither root's default_root_names, so
    # bundle_default (computed purely from name membership in
    # default_root_names -- see #merge_entry!, unrelated to which root's
    # plan an entry came from) could only ever be false here, regardless of
    # whether the merge itself preserved a true from either side. Asserting
    # false and calling that "OR" coverage proved nothing about the merge
    # path at all. Fixed: shared-dep is itself in default_root_names, so
    # it's reached as a real root/transitive-dependency merge (via both
    # root-a and root-b's plans, exercising #merge_conflicting_entry!) while
    # also demonstrably keeping bundle_default: true throughout.
    shared_pure = plan_entry('shared-dep', classification(:pure))
    root_a_plan = [plan_entry('root-a', classification(:pure)), shared_pure]
    root_b_plan = [plan_entry('root-b', classification(:pure)), shared_pure]
    builder = described_class.new(
      root_plans: { 'root-a' => root_a_plan, 'root-b' => root_b_plan },
      default_root_names: ['root-b', 'shared-dep'],
      platform: 'x64-mingw-ucrt', ruby_abi: '4.0', msys2_packages: msys2_packages
    )

    result = builder.build

    expect(result['gems'].keys).to contain_exactly('root-a', 'root-b', 'shared-dep')
    expect(result['gems']['shared-dep']['bundle_default']).to be(true)
    expect(result['gems']['root-a']['bundle_default']).to be(false)
  end

  it 'raises ConflictError when the same gem name classifies differently across two roots' do
    root_a_plan = [plan_entry('shared-dep', classification(:pure))]
    root_b_plan = [plan_entry('shared-dep', classification(:native_self_contained, msys2_packages: msys2_packages))]
    builder = described_class.new(
      root_plans: { 'root-a' => root_a_plan, 'root-b' => root_b_plan }, default_root_names: [],
      platform: 'x64-mingw-ucrt', ruby_abi: '4.0', msys2_packages: msys2_packages
    )

    expect { builder.build }.to raise_error(described_class::ConflictError, /shared-dep/)
  end

  it 'the resulting Hash validates cleanly against the real CuratedGemRegistry schema' do
    plan = [
      plan_entry('a-root', classification(:native_self_contained, msys2_packages: msys2_packages)),
      plan_entry('a-pure-dep', classification(:pure)),
      plan_entry('a-pass-through-dep', classification(:native_pass_through, platform_asset: 'asset.gem')),
      plan_entry('json', classification(:ruby_bundled))
    ]
    builder = described_class.new(
      root_plans: { 'a-root' => plan }, default_root_names: ['a-root'],
      platform: 'x64-mingw-ucrt', ruby_abi: '4.0', msys2_packages: msys2_packages
    )

    require 'ruby4lich5/curated_gem_registry'
    registry = Ruby4Lich5::CuratedGemRegistry.new(builder.build)

    expect(registry.known?('a-root')).to be(true)
    expect(registry.self_build_packages_for('a-root')).to eq(msys2_packages)
    expect(registry.self_build_packages_for('a-pass-through-dep')).to be_nil
  end

  describe '.merge_platform' do
    let(:arm) { { '4.0' => { 'expected_classification' => 'native_self_contained', 'msys2_packages' => ['mingw-w64-clang-aarch64-lib'] } } }
    let(:existing) do
      { 'schema' => 2, 'gems' => {
        'kept'     => { 'approval' => 'approved', 'bundle_default' => true,
                    'targets' => { 'x64-mingw-ucrt' => { '4.0' => { 'expected_classification' => 'pure' } }, 'aarch64-mingw-ucrt' => arm },
                    'build_role' => 'repack', 'smoke_requires' => ['kept'] },
        'arm-only' => { 'approval' => 'approved', 'bundle_default' => false, 'targets' => { 'aarch64-mingw-ucrt' => arm }, 'build_role' => 'none' },
        'dropped'  => { 'approval' => 'approved', 'bundle_default' => false, 'targets' => { 'x64-mingw-ucrt' => { '4.0' => { 'expected_classification' => 'pure' } } } }
      } }
    end
    let(:seed) do
      { 'schema' => 2, 'gems' => {
        'added' => { 'approval' => 'approved', 'bundle_default' => false, 'targets' => { 'x64-mingw-ucrt' => { '4.0' => { 'expected_classification' => 'pure' } } } },
        'kept'  => { 'approval' => 'approved', 'bundle_default' => true, 'targets' => { 'x64-mingw-ucrt' => { '4.0' => { 'expected_classification' => 'native_pass_through' } } } }
      } }
    end

    it 'replaces only the derived platform and keeps every other platform, platform-only gem and reviewed field' do
      merged = described_class.merge_platform(existing: existing, seed: seed, platform: 'x64-mingw-ucrt')
      expect(merged.fetch('gems').keys).to eq(%w[added arm-only kept])
      expect(merged.dig('gems', 'kept')).to eq(
        'approval' => 'approved', 'bundle_default' => true,
        'targets' => { 'x64-mingw-ucrt' => { '4.0' => { 'expected_classification' => 'native_pass_through' } }, 'aarch64-mingw-ucrt' => arm },
        'build_role' => 'repack', 'smoke_requires' => ['kept']
      )
      expect(merged.dig('gems', 'arm-only')).to eq(existing.dig('gems', 'arm-only'))
      expect(merged.dig('gems', 'added', 'targets').keys).to eq(['x64-mingw-ucrt'])
      expect(existing.dig('gems', 'kept', 'targets', 'x64-mingw-ucrt', '4.0', 'expected_classification')).to eq('pure')
    end

    it 'drops a gem only once no platform targets it, and starts from nothing without an existing file' do
      arm_seed = { 'schema' => 2, 'gems' => { 'arm-only' => existing.dig('gems', 'arm-only').slice('approval', 'bundle_default', 'targets') } }
      merged = described_class.merge_platform(existing: existing, seed: arm_seed, platform: 'aarch64-mingw-ucrt')
      expect(merged.fetch('gems').keys).to eq(%w[arm-only dropped kept])
      expect(merged.dig('gems', 'kept', 'targets').keys).to eq(['x64-mingw-ucrt'])
      expect(described_class.merge_platform(existing: nil, seed: seed, platform: 'x64-mingw-ucrt')).to eq(seed)
    end

    it 'rejects a seed carrying another platform' do
      expect { described_class.merge_platform(existing: existing, seed: seed, platform: 'aarch64-mingw-ucrt') }.to raise_error(ArgumentError, /only aarch64-mingw-ucrt/)
    end
  end
end
