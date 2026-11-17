# frozen_string_literal: true

require 'json'
require 'ruby4lich5/package_policy'
require 'ruby4lich5/gem_manifest_generator'
require 'ruby4lich5/gem_manifest_validator'
require 'ruby4lich5/gem_unit_grouper'

RSpec.describe Ruby4Lich5::PackagePolicy do
  let(:root) { File.expand_path('../..', __dir__) }
  let(:real_registry) { Ruby4Lich5::KnownNativeGems.registry }
  let(:unpatched) { ->(_name) { false } }

  def requirement(*list)
    Gem::Requirement.new(*list)
  end

  def flagged(target)
    target.fetch('units').flat_map { |unit| unit.fetch('packages') }.select { |package| package['self_build_equivalent'] == true }
                                                                    .map { |package| package.fetch('name') }.uniq.sort
  end

  # +entries+ maps a name to [build_role or nil, classification, minimum or
  # nil]; a classification may be a Hash of platform => classification.
  def registry_for(entries, platform = 'x64-mingw-ucrt')
    gems = entries.to_h do |name, (role, classification, minimum)|
      targets = (classification.is_a?(Hash) ? classification : { platform => classification }).to_h do |key, state|
        leaf = { 'expected_classification' => state }
        leaf['msys2_packages'] = ['fixture-pkg'] if state == 'native_self_contained'
        leaf['minimum'] = minimum if minimum
        [key, { '4.0' => leaf }]
      end
      entry = { 'approval' => 'approved', 'bundle_default' => true, 'targets' => targets }
      entry['build_role'] = role if role
      entry['build_order'] = 0 if role == 'gtk'
      [name, entry]
    end
    Ruby4Lich5::CuratedGemRegistry.new({ 'schema' => 2, 'gems' => gems })
  end

  def package(name, version, native: false, platform: 'x64-mingw-ucrt')
    { 'name' => name, 'version' => version, 'filename' => native ? "#{name}-#{version}-#{platform}.gem" : "#{name}-#{version}.gem",
      'sha256' => "sha256:#{Digest::SHA256.hexdigest(name + version)}" }
  end

  def unit(id, packages)
    names = packages.map { |entry| entry.fetch('name') }
    artifact = if packages.length == 1
                 { 'url' => "https://example.invalid/#{packages.first.fetch('filename')}", 'filename' => packages.first.fetch('filename'),
                   'sha256' => packages.first.fetch('sha256'), 'archive' => 'gem' }
               else
                 { 'url' => 'https://example.invalid/bundle.zip', 'filename' => 'bundle.zip', 'sha256' => "sha256:#{'b' * 64}", 'archive' => 'zip' }
               end
    { 'id' => id, 'members' => names, 'artifact' => artifact, 'packages' => packages, 'install_order' => names }
  end

  def target(units, platform: 'x64-mingw-ucrt')
    { 'ruby_abi' => '4.0', 'platform' => platform, 'units' => units }
  end

  # The live x64 manifest's dependency edges: Lich's Gemfile.lock records
  # (with requirements) for everything it locks, and the seed fixture's
  # resolved closure for the Ruby-GNOME stack, which that lock does not hold.
  def live_dependencies(manifest_target)
    resolved = JSON.parse(File.read(File.join(root, 'spec/fixtures/curated-gems-seed/resolved-plan.json'))).values.flatten
    graph = resolved.to_h { |entry| [entry.fetch('name'), entry.fetch('runtime_dependency_names').to_h { |dep| [dep, requirement] }] }
    manifest_target.fetch('contract').fetch('locked_packages').each do |name, spec|
      graph[name] = spec.fetch('dependencies').transform_values { |list| requirement(*list) }
    end
    graph
  end

  describe 'on the real registry and the live x64 manifest' do
    let(:live_bytes) { File.binread(File.join(root, 'manifest/R4L5-gem-manifest.json')) }
    let(:live) { JSON.parse(live_bytes) }
    let(:candidate) do
      document = JSON.parse(live_bytes)
      manifest_target = document.fetch('targets').first
      described_class.new(platform: 'x64-mingw-ucrt', ruby_abi: '4.0', dependencies: live_dependencies(manifest_target)).apply!(manifest_target)
      document
    end

    it 'configures no minimum anywhere, so nothing loosens until a package opts in' do
      real_registry.instance_variable_get(:@gems).each do |name, entry|
        entry.fetch('targets').each do |platform, abis|
          abis.each_key { |abi| expect(real_registry.minimum_for(name, platform, abi)).to be_nil }
        end
      end
    end

    it 'flags exactly ox and curses on x64, and nothing else changes' do
      expect(flagged(candidate.fetch('targets').first)).to eq(%w[curses ox])
      stripped = JSON.parse(JSON.generate(candidate))
      stripped.fetch('targets').first.fetch('units').each { |item| item.fetch('packages').each { |entry| entry.delete('self_build_equivalent') } }
      expect(JSON.pretty_generate(stripped)).to eq(JSON.pretty_generate(live))
      expect(Ruby4Lich5::GemManifestValidator.validate!(candidate)).to be(true)
      expect(described_class.require_eligible_flags!(candidate, previous: nil)).to be(true)
    end

    it 'writes byte-identical manifest JSON when no package minimum is configured and no package qualifies for the flag' do
      document = JSON.parse(live_bytes)
      manifest_target = document.fetch('targets').first
      described_class.new(platform: 'x64-mingw-ucrt', ruby_abi: '4.0', dependencies: live_dependencies(manifest_target),
                          patched: ->(_name) { true }).apply!(manifest_target)
      expect(JSON.pretty_generate(document)).to eq(live_bytes.gsub("\r\n", "\n"))
    end

    it 'flags ox, curses and sqlite3 on aarch64, where sqlite3 is a self-build over pure mini_portile2' do
      plan = JSON.parse(File.read(File.join(root, 'spec/fixtures/curated-gems-seed/aarch64-mingw-ucrt/resolved-plan.json')))
      entries = plan.values.flatten.uniq { |entry| entry.fetch('name') }.reject { |entry| entry.dig('classification', 'state') == 'ruby_bundled' }
      states = entries.to_h { |entry| [entry.fetch('name'), entry.dig('classification', 'state')] }
      nodes = entries.map { |entry| { name: entry.fetch('name'), version: entry.fetch('version'), runtime_dependency_names: entry.fetch('runtime_dependency_names') & states.keys } }
      roots = Ruby4Lich5::GemManifestGenerator.roots_for(plan.keys & states.keys)
      versions = nodes.to_h { |node| [node.fetch(:name), node.fetch(:version)] }
      units = Ruby4Lich5::GemUnitGrouper.new(closure_nodes: nodes, roots: roots).units.map do |group|
        packages = group.fetch(:members).map { |name| package(name, versions.fetch(name), native: states.fetch(name) != 'pure', platform: 'aarch64-mingw-ucrt') }
        unit(group.fetch(:id), packages).merge('install_order' => group.fetch(:install_order))
      end
      aarch64 = target(units, platform: 'aarch64-mingw-ucrt')
      dependencies = entries.to_h { |entry| [entry.fetch('name'), entry.fetch('runtime_dependency_names').to_h { |dep| [dep, requirement] }] }
      described_class.new(platform: 'aarch64-mingw-ucrt', ruby_abi: '4.0', dependencies: dependencies).apply!(aarch64)
      expect(flagged(aarch64)).to eq(%w[curses ox sqlite3])
      expect(described_class.validate_target!(aarch64)).to be(true)
      expect(described_class.require_eligible_flags!({ 'targets' => [aarch64] }, previous: nil)).to be(true)
    end
  end

  describe '#apply!' do
    let(:registry) do
      registry_for('ox' => ['repack', 'native_self_contained'], 'glib2' => ['gtk', 'native_self_contained'], 'sqlite3' => ['repack', { 'x64-mingw-ucrt' => 'native_pass_through', 'aarch64-mingw-ucrt' => 'native_self_contained' }],
                   'lib' => [nil, 'native_self_contained'], 'pure' => [nil, 'pure'], 'dependent' => [nil, 'pure'])
    end

    # Positional, not keywords: the dependency Hash has String keys.
    def apply(units, dependencies, options = {})
      subject = target(units)
      described_class.new(platform: 'x64-mingw-ucrt', ruby_abi: '4.0', dependencies: dependencies,
                          registry: options.fetch(:policy_registry, registry), patched: options.fetch(:patched, unpatched)).apply!(subject)
      subject
    end

    it 'flags a standalone unpatched repack self-build' do
      expect(flagged(apply([unit('ox', [package('ox', '1.0', native: true)])], 'ox' => {}))).to eq(['ox'])
    end

    it 'never flags a patched package' do
      result = apply([unit('ox', [package('ox', '1.0', native: true)])], { 'ox' => {} }, patched: ->(name) { name == 'ox' })
      expect(flagged(result)).to be_empty
    end

    it 'never flags a gtk-role package, even standing alone' do
      expect(flagged(apply([unit('glib2', [package('glib2', '1.0', native: true)])], 'glib2' => {}))).to be_empty
    end

    it 'never flags a repack package served as an upstream binary on this platform' do
      expect(flagged(apply([unit('sqlite3', [package('sqlite3', '1.0', native: true)])], 'sqlite3' => {}))).to be_empty
    end

    it 'does not flag a package another member of its unit depends on' do
      units = [unit('dependent', [package('ox', '1.0', native: true), package('dependent', '1.0')])]
      expect(flagged(apply(units, 'ox' => {}, 'dependent' => { 'ox' => requirement('>= 1') }))).to be_empty
    end

    it 'does not flag a package that depends on a native unit-mate' do
      units = [unit('ox', [package('lib', '1.0', native: true), package('ox', '1.0', native: true)])]
      expect(flagged(apply(units, 'ox' => { 'lib' => requirement }, 'lib' => {}))).to be_empty
    end

    it 'flags a package that depends only on pure unit-mates' do
      units = [unit('ox', [package('pure', '1.0'), package('ox', '1.0', native: true)])]
      expect(flagged(apply(units, 'ox' => { 'pure' => requirement }, 'pure' => {}))).to eq(['ox'])
    end

    it 'fails closed on a unit member without a locked dependency record' do
      units = [unit('ox', [package('pure', '1.0'), package('ox', '1.0', native: true)])]
      expect { apply(units, 'ox' => { 'pure' => requirement }) }.to raise_error(described_class::Error, /no locked dependency record for unit member pure/)
    end

    context 'with a configured minimum' do
      def minimum_registry(minimum)
        registry_for('pure' => [nil, 'pure', minimum], 'dependent' => [nil, 'pure'], 'other' => [nil, 'pure'])
      end

      it 'writes it on every copy of the package when it is below the version' do
        units = [unit('pure', [package('pure', '2.0')]), unit('dependent', [package('pure', '2.0'), package('dependent', '1.0')])]
        result = apply(units, { 'pure' => {}, 'dependent' => { 'pure' => requirement('~> 2.0') } }, policy_registry: minimum_registry('1.5'))
        copies = result.fetch('units').flat_map { |item| item.fetch('packages') }.select { |entry| entry['name'] == 'pure' }
        expect(copies.map { |entry| entry['minimum'] }).to eq(%w[1.5 1.5])
        expect(result.fetch('units').flat_map { |item| item.fetch('packages') }.find { |entry| entry['name'] == 'dependent' }).not_to have_key('minimum')
      end

      it 'omits it when it equals the version' do
        result = apply([unit('pure', [package('pure', '2.0')])], { 'pure' => {} }, policy_registry: minimum_registry('2.0'))
        expect(result.dig('units', 0, 'packages', 0)).not_to have_key('minimum')
      end

      it 'refuses one above the version' do
        expect { apply([unit('pure', [package('pure', '2.0')])], { 'pure' => {} }, policy_registry: minimum_registry('2.1')) }
          .to raise_error(described_class::Error, /pure minimum 2.1 is above its version 2.0/)
      end

      it 'refuses it on a package another member of its unit pins exactly' do
        units = [unit('dependent', [package('pure', '2.0'), package('dependent', '1.0')])]
        expect { apply(units, { 'pure' => {}, 'dependent' => { 'pure' => requirement('= 2.0') } }, policy_registry: minimum_registry('1.5')) }
          .to raise_error(described_class::Error, /pure minimum is refused: pinned exactly by dependent/)
      end

      it 'refuses it when any clause of the requirement pins exactly, even beside a looser one' do
        units = [unit('dependent', [package('pure', '2.0'), package('dependent', '1.0')])]
        expect { apply(units, { 'pure' => {}, 'dependent' => { 'pure' => requirement('= 2.0', '>= 1.0') } }, policy_registry: minimum_registry('1.5')) }
          .to raise_error(described_class::Error, /pure minimum is refused: pinned exactly by dependent/)
      end

      it 'keeps it under a genuine range' do
        units = [unit('dependent', [package('pure', '2.0'), package('dependent', '1.0')])]
        result = apply(units, { 'pure' => {}, 'dependent' => { 'pure' => requirement('>= 1.0', '< 3') } }, policy_registry: minimum_registry('1.5'))
        expect(result.dig('units', 0, 'packages', 0, 'minimum')).to eq('1.5')
      end
    end
  end

  describe '.validate_target!' do
    def validate(units)
      Ruby4Lich5::GemManifestValidator.validate!({ 'schema' => 1, 'targets' => [target(units)] })
    end

    def flag(entry, value = true)
      entry.merge('self_build_equivalent' => value)
    end

    it 'accepts a flagged standalone package and an explicit false' do
      expect(validate([unit('ox', [flag(package('ox', '1.0', native: true))])])).to be(true)
      expect(validate([unit('pure', [flag(package('pure', '1.0'), false)])])).to be(true)
    end

    it 'judges the document alone, never the current registry or patches/, so accepted flagged bytes stay valid' do
      expect(Ruby4Lich5::KnownNativeGems).not_to receive(:registry)
      expect(described_class).not_to receive(:default_patched)
      expect(validate([unit('glib2', [flag(package('glib2', '1.0', native: true))])])).to be(true)
    end

    it 'refuses a non-boolean flag' do
      expect { validate([unit('ox', [flag(package('ox', '1.0', native: true), 'true')])]) }
        .to raise_error(described_class::Error, /ox self_build_equivalent must be true or false, got "true"/)
    end

    it 'refuses the flag on a package another member of its unit depends on' do
      units = [unit('dependent', [flag(package('ox', '1.0', native: true)), package('dependent', '1.0')]),
               unit('ox', [flag(package('ox', '1.0', native: true))])]
      expect { validate(units) }.to raise_error(described_class::Error, /ox self_build_equivalent is refused: another member of its unit depends on it/)
    end

    it 'refuses the flag on a package that depends on a native unit-mate' do
      units = [unit('ox', [package('lib', '1.0', native: true), flag(package('ox', '1.0', native: true))])]
      expect { validate(units) }.to raise_error(described_class::Error, /ox self_build_equivalent is refused: it depends on native unit-mate\(s\) lib/)
    end

    it 'accepts the flag on a package whose unit-mates are all pure' do
      expect(validate([unit('ox', [package('pure', '1.0'), flag(package('ox', '1.0', native: true))])])).to be(true)
    end

    it 'refuses copies of one package that disagree on the flag' do
      units = [unit('ox', [flag(package('ox', '1.0', native: true))]), unit('ox-again', [package('ox', '1.0', native: true)])]
      expect { validate(units) }.to raise_error(described_class::Error, /ox copies disagree on minimum or self_build_equivalent/)
    end

    it 'accepts a canonical minimum below the version, including one written on every copy' do
      units = [unit('pure', [package('pure', '2.0').merge('minimum' => '1.5')]),
               unit('dependent', [package('pure', '2.0').merge('minimum' => '1.5'), package('dependent', '1.0')])]
      expect(validate(units)).to be(true)
    end

    it 'refuses a minimum that is not a canonical release version' do
      [' 1.5', '1.5 ', '', '1.5-1', '1.5.pre', 1.5, nil].each do |minimum|
        expect { validate([unit('pure', [package('pure', '2.0').merge('minimum' => minimum)])]) }
          .to raise_error(described_class::Error, /pure minimum .* is not a canonical release version/), minimum.inspect
      end
    end

    it 'refuses a minimum above the version' do
      expect { validate([unit('pure', [package('pure', '2.0').merge('minimum' => '2.0.1')])]) }
        .to raise_error(described_class::Error, /pure minimum 2.0.1 is above its version 2.0/)
    end

    it 'refuses a version that is not in canonical form, and accepts a canonical prerelease' do
      expect { validate([unit('pure', [package('pure', '2.0').merge('version' => ' 2.0')])]) }
        .to raise_error(described_class::Error, /pure version " 2.0" is not in canonical form/)
      expect(validate([unit('pure', [package('pure', '2.0.pre1')])])).to be(true)
    end

    it 'refuses copies of one package that disagree on the minimum' do
      units = [unit('pure', [package('pure', '2.0').merge('minimum' => '1.5')]),
               unit('dependent', [package('pure', '2.0'), package('dependent', '1.0')])]
      expect { validate(units) }.to raise_error(described_class::Error, /pure copies disagree on minimum or self_build_equivalent/)
    end

    it 'refuses two different minimums for one package name in a target' do
      units = [unit('pure', [package('pure', '2.0').merge('minimum' => '1.5')]),
               unit('dependent', [package('pure', '3.0').merge('minimum' => '1.6'), package('dependent', '1.0')])]
      expect { validate(units) }.to raise_error(described_class::Error, /pure carries more than one minimum in this target/)
    end

    it 'compares minimums by value, so 2.0 and 2.0.0 for version 2.0 are one identity' do
      units = [unit('pure', [package('pure', '2.0').merge('minimum' => '2.0')]),
               unit('dependent', [package('pure', '2.0'), package('dependent', '1.0')])]
      expect(validate(units)).to be(true)
    end
  end

  describe '.require_eligible_flags!' do
    let(:registry) do
      registry_for('ox' => ['repack', 'native_self_contained'], 'glib2' => ['gtk', 'native_self_contained'],
                   'sqlite3' => ['repack', { 'x64-mingw-ucrt' => 'native_pass_through', 'aarch64-mingw-ucrt' => 'native_self_contained' }],
                   'pure' => [nil, 'pure'])
    end

    def document(*packages, platform: 'x64-mingw-ucrt')
      { 'schema' => 1, 'targets' => [target(packages.map { |entry| unit(entry.fetch('name'), [entry]) }, platform: platform)] }
    end

    def flagged_package(name, version = '1.0', **options)
      package(name, version, native: true, **options).merge('self_build_equivalent' => true)
    end

    def check(manifest, previous: nil, patched: unpatched, policy_registry: registry)
      described_class.require_eligible_flags!(manifest, previous: previous, registry: policy_registry, patched: patched)
    end

    it 'accepts a flag on a currently eligible package with no predecessor' do
      expect(check(document(flagged_package('ox')))).to be(true)
    end

    it 'never judges an unflagged package' do
      expect(check(document(package('glib2', '1.0', native: true)), patched: ->(_name) { true })).to be(true)
    end

    it 'refuses a flag on a gtk-role, pass-through or patched package with no predecessor' do
      expect { check(document(flagged_package('glib2'))) }.to raise_error(described_class::Error, /glib2 self_build_equivalent requires an unpatched repack package/)
      expect { check(document(flagged_package('sqlite3'))) }.to raise_error(described_class::Error, /sqlite3 self_build_equivalent requires/)
      expect { check(document(flagged_package('ox')), patched: ->(name) { name == 'ox' }) }.to raise_error(described_class::Error, /ox self_build_equivalent requires/)
    end

    it 'exempts the exact bytes the predecessor already flagged, once they stop being eligible' do
      live = document(flagged_package('ox'))
      expect(check(JSON.parse(JSON.generate(live)), previous: live, patched: ->(name) { name == 'ox' })).to be(true)
    end

    it 'refuses rebuilt bytes carrying the flag, even at the same name and version' do
      live = document(flagged_package('ox'))
      rebuilt = document(flagged_package('ox').merge('sha256' => "sha256:#{'c' * 64}"))
      expect { check(rebuilt, previous: live, patched: ->(name) { name == 'ox' }) }.to raise_error(described_class::Error, /ox self_build_equivalent requires/)
    end

    it 'judges a newly added flag on unchanged bytes against current eligibility' do
      live = document(package('ox', '1.0', native: true))
      expect { check(document(flagged_package('ox')), previous: live, patched: ->(name) { name == 'ox' }) }
        .to raise_error(described_class::Error, /ox self_build_equivalent requires/)
    end

    it 'never carries a flag across targets' do
      live = document(flagged_package('ox', platform: 'aarch64-mingw-ucrt'), platform: 'aarch64-mingw-ucrt')
      candidate = document(flagged_package('ox', platform: 'aarch64-mingw-ucrt'))
      expect { check(candidate, previous: live, patched: ->(name) { name == 'ox' }) }.to raise_error(described_class::Error, /ox self_build_equivalent requires/)
    end
  end
end
