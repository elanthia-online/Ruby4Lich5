# frozen_string_literal: true

require 'ruby4lich5/curated_gem_registry'
require 'ruby4lich5/curated_gems_seed_builder'
require 'ruby4lich5/classification'
require 'ruby4lich5/ruby_bundled_gems'
require 'json'

# Provenance coverage for the real, checked-in config/curated-gems.json --
# not a full HTTP-mocked replay of bin/derive_curated_gems_seed.rb's live
# RubyGems.org resolution (that would mean recording every real .gem
# download the underlying Classifier makes for 17+ real gems, disproportionate
# to how rarely this seed is re-derived). What's checked instead: the
# recorded provenance (spec/fixtures/curated-gems-seed/inputs.json and
# .../resolved-plan.json) is internally consistent with the actual committed
# seed file, and -- real regeneration coverage, not just consistency, per
# review 2026-07-13 -- the committed seed is provably exactly what
# CuratedGemsSeedBuilder produces from the recorded resolved-plan snapshot,
# with no live network involved.
RSpec.describe 'config/curated-gems.json provenance' do
  let(:seed_path) { File.join(__dir__, '..', 'config', 'curated-gems.json') }
  let(:inputs_path) { File.join(__dir__, 'fixtures', 'curated-gems-seed', 'inputs.json') }
  let(:inputs) { JSON.parse(File.read(inputs_path)) }
  let(:registry) { Ruby4Lich5::CuratedGemRegistry.load_file(seed_path) }

  it 'loads cleanly through the real CuratedGemRegistry, schema and all' do
    expect { registry }.not_to raise_error
  end

  it "recorded provenance's root set exactly matches the seed's bundle_default: true set" do
    expect(registry.bundle_default_roots.sort).to eq(inputs.fetch('roots').keys.sort)
  end

  it 'every recorded root is approved for the recorded platform/ruby_abi' do
    inputs.fetch('roots').each_key do |root_name|
      expect(registry.approved?(root_name, inputs.fetch('platform'), inputs.fetch('ruby_abi'))).to be(true)
    end
  end

  it 'reflects the real finding this provenance records: sqlite3/ffi are native_pass_through, not self-build candidates' do
    expect(registry.self_build_packages_for('sqlite3')).to be_nil
    expect(registry.self_build_packages_for('ffi')).to be_nil
    expect(registry.classification_for('sqlite3', 'x64-mingw-ucrt', '4.0')).to eq('native_pass_through')
    expect(registry.classification_for('ffi', 'x64-mingw-ucrt', '4.0')).to eq('native_pass_through')
  end

  it 'ox and curses are still real self-build candidates, matching the recorded provenance' do
    expect(registry.self_build_packages_for('ox')).not_to be_nil
    expect(registry.self_build_packages_for('curses')).not_to be_nil
  end

  describe 'Phase 17 section 10 equivalence assertions -- real checks, not eyeballed' do
    let(:manifest_path) { File.join(__dir__, '..', 'manifest', 'R4L5-gem-manifest.json') }
    let(:manifest) { JSON.parse(File.read(manifest_path)) }

    # @return [Array<String>] every distinct gem name across every unit in
    #   the real, currently-shipped manifest's one target
    def manifest_members
      manifest.fetch('targets').flat_map { |target| target.fetch('units').flat_map { |unit| unit.fetch('members') } }.uniq
    end

    it 'every non-ruby_bundled member of the real shipped manifest has an approval: approved entry' do
      non_bundled_members = manifest_members.reject { |name| Ruby4Lich5::RubyBundledGems.bundled?(name) }

      expect(non_bundled_members).not_to be_empty # sanity: this check must exercise real names, not an empty list
      non_bundled_members.each do |name|
        expect(registry.known?(name)).to be(true), "expected #{name} (a real shipped manifest member) to be approved"
      end
    end

    it "the bundle_default: true subset exactly matches the current default *root* selection, not the full member set" do
      # Real distinction, locked in Phase 17 section 10: bundle_default is
      # about requested roots (gtk3 + the runtime-gems defaults), not every
      # transitive member a closure happens to pull in -- glib2/cairo/etc.
      # are approved (tested above) but never bundle_default: true.
      expect(registry.bundle_default_roots.sort).to eq(inputs.fetch('roots').keys.sort)
      expect(registry.bundle_default_roots).not_to include('glib2', 'cairo', 'pango', 'gio2')
    end
  end

  describe 'regeneration from recorded evidence, per review 2026-07-13' do
    # Real gap this closes: recording only root name/version pairs let a
    # spec check the committed seed for internal *consistency*, but could
    # never actually *regenerate* it -- the resolved/classified closure
    # itself (what BuildPlanner#plan_for returned for every member of every
    # root's closure) was never captured anywhere durable. This snapshot,
    # written by bin/derive_curated_gems_seed.rb in the same run that wrote
    # the committed seed, is that missing evidence.
    let(:snapshot_path) { File.join(__dir__, 'fixtures', 'curated-gems-seed', 'resolved-plan.json') }
    let(:snapshot) { JSON.parse(File.read(snapshot_path)) }

    def deserialize_classification(hash)
      Ruby4Lich5::Classification.new(
        state: hash.fetch('state').to_sym, gem_name: 'unused', gem_version: 'unused', reason: 'from recorded snapshot',
        msys2_packages: hash['msys2_packages'], platform_asset: hash['platform_asset']
      )
    end

    def deserialize_root_plans(snapshot)
      snapshot.transform_values do |plan|
        plan.map do |entry|
          { name: entry.fetch('name'), version: entry.fetch('version'),
            classification: deserialize_classification(entry.fetch('classification')),
            runtime_dependency_names: entry.fetch('runtime_dependency_names') }
        end
      end
    end

    it "every recorded root's version in inputs.json matches its own entry in the resolved-plan snapshot" do
      # Real gap, found in CodeRabbit review: the regeneration test below
      # only ever read root *names* from inputs.json (for
      # default_root_names), never cross-checked inputs.json's recorded
      # *versions* against what resolved-plan.json actually resolved --
      # confirmed directly by injecting a fake gtk3 version into inputs.json
      # and re-running the regeneration spec, which still passed. A root's
      # own entry always appears within its own plan (BuildPlanner#plan_for
      # includes the requested gem itself, last in topological order).
      inputs.fetch('roots').each do |name, recorded_version|
        root_entry = snapshot.fetch(name).find { |entry| entry.fetch('name') == name }

        expect(root_entry).not_to be_nil, "expected #{name}'s own entry within its own resolved-plan snapshot"
        expect(root_entry.fetch('version')).to eq(recorded_version)
      end
    end

    it 'regenerates the classification and MSYS2 policy from the immutable original snapshot -- no live network' do
      # Real bug, found in review 2026-07-13: an earlier version of this
      # spec read msys2_packages back out of `registry` (loaded from
      # seed_path, the very file this test asserts equality against) --
      # circular for the one thing that actually needed independent
      # verification. Confirmed directly: uniformly corrupting all 12
      # native_self_contained entries' msys2_packages to the same bogus
      # value still passed, because the corrupted value got read back out
      # and reapplied uniformly, reproducing itself. Fixed: the recipe now
      # comes from `inputs` (spec/fixtures/curated-gems-seed/inputs.json),
      # written independently by bin/derive_curated_gems_seed.rb in the
      # same run as the seed, not read from the registry under test.
      builder = Ruby4Lich5::CuratedGemsSeedBuilder.new(
        root_plans: deserialize_root_plans(snapshot), default_root_names: inputs.fetch('roots').keys,
        platform: inputs.fetch('platform'), ruby_abi: inputs.fetch('ruby_abi'),
        msys2_packages: inputs.fetch('msys2_packages')
      )

      regenerated = builder.build
      committed = JSON.parse(File.read(seed_path))
      # Later reviewed build roles and smoke declarations are not facts from
      # this historical resolution. Keep the original evidence unchanged.
      committed['gems'].transform_values! { |entry| entry.reject { |key, _value| %w[build_role build_order smoke_requires].include?(key) } }

      expect(regenerated).to eq(committed)
    end
  end
end
