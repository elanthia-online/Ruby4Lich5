# frozen_string_literal: true

require 'ruby4lich5/replacement_plan'
require 'ruby4lich5/gem_manifest_generator'
require 'ruby4lich5/staged_gem_spec_finder'
require 'ruby4lich5/locked_artifact_map_builder'
require 'rubygems/user_interaction'
require 'tmpdir'
require 'json'

RSpec.describe Ruby4Lich5::ReplacementPlan do
  around { |example| Dir.mktmpdir { |directory| @directory = directory; example.run } }

  def node(name, version = '1.0', dependencies = {}, state: :pure)
    { name: name, version: version, runtime_dependencies: dependencies.map { |child, requirement| { name: child, requirement: Gem::Requirement.new(requirement) } },
      classification: Ruby4Lich5::Classification.new(state: state, gem_name: name, gem_version: version, reason: 'fixture',
                                                     msys2_packages: state == :native_self_contained ? ['fixture'] : nil,
                                                     platform_asset: state == :native_pass_through ? 'binary.gem' : nil) }
  end

  def lock(entries, gtk: [])
    packages = entries.to_h do |entry|
      [entry.fetch(:name), { 'version' => entry.fetch(:version), 'platform' => entry.fetch(:classification).pure? ? 'ruby' : 'x64-mingw-ucrt', 'sha256' => 'a' * 64,
                            'dependencies' => entry.fetch(:runtime_dependencies).to_h { |dep| [dep.fetch(:name), dep.fetch(:requirement).as_list] } }]
    end
    contract = { 'schema' => 2, 'windows_contract_sha256' => 'f' * 64, 'lich5_commit' => 'b' * 40, 'gemfile_sha256' => 'c' * 64, 'lock_sha256' => 'd' * 64,
                 'reader_sha256' => 'e' * 64, 'overrides' => {}, 'promotable' => true, 'ruby_installer_version' => '4.0.9-1',
                 'ruby_inventory' => { 'ruby_version' => '4.0.9', 'ruby_abi' => '4.0', 'platform' => 'x64-mingw-ucrt', 'gems' => {} },
                 'expected_packages' => packages, 'locked_packages' => packages, 'build_roles' => { 'gtk' => gtk } }
    Ruby4Lich5::ResolutionLock.new(ruby_installer_version: '4.0.9-1', platform: 'x64-mingw-ucrt',
                                   requested_roots: entries.reject { |entry| entry[:name] == 'child' }.to_h { |entry| entry.values_at(:name, :version) },
                                   closure: entries, registry_commit_sha: 'f' * 40, registry_content_digest: "sha256:#{'f' * 64}", contract: contract)
  end

  def stage(entry)
    name, version = entry.values_at(:name, :version)
    spec = Gem::Specification.new(name, version) do |item|
      item.summary = 'fixture'
      item.authors = ['fixture']
      item.files = []
      item.platform = Gem::Platform.new('x64-mingw-ucrt') unless entry.fetch(:classification).pure?
      entry.fetch(:runtime_dependencies).each { |dep| item.add_runtime_dependency(dep.fetch(:name), *dep.fetch(:requirement).as_list) }
    end
    filename = Gem::DefaultUserInteraction.use_ui(Gem::SilentUI.new) { Dir.chdir(@directory) { Gem::Package.build(spec) } }
    path = File.join(@directory, filename)
    { 'name' => name, 'version' => version, 'filename' => filename, 'sha256' => "sha256:#{Digest::SHA256.file(path).hexdigest}" }
  end

  def accepted(entries, gtk: [])
    prior = lock(entries, gtk: gtk)
    units = entries.map do |entry|
      package = stage(entry)
      { 'id' => entry.fetch(:name), 'members' => [package.fetch('name')], 'install_order' => [package.fetch('name')], 'packages' => [package],
        'artifact' => { 'url' => "https://rubygems.org/downloads/#{package.fetch('filename')}", 'archive' => 'gem',
                        'filename' => package.fetch('filename'), 'sha256' => package.fetch('sha256') } }
    end
    [prior, { 'schema' => 1, 'targets' => [{ 'ruby_abi' => '4.0', 'platform' => prior.platform, 'contract' => prior.contract, 'units' => units }] }]
  end

  def plan(entries, replacement)
    prior, manifest = accepted(entries)
    described_class.build(previous_lock: prior, lock: lock(replacement), manifest: manifest, directory: @directory, accepted_patches: nil)
  end

  it 'swaps a D1 single package without rebuilding unchanged native gems' do
    entries = [node('os'), node('ox', state: :native_self_contained)]
    result = plan(entries, [node('os', '1.1'), entries.last])
    expect(result.fetch('changed')).to eq(['os'])
    expect(result.fetch('reuse').keys).to eq(['ox'])
    expect(result.fetch('rebuild')).to be_empty
    expect(described_class.verify_staged!(result, @directory)).to be(true)
  end

  it 'accepts a flagged predecessor whose package is no longer eligible, so its replacement can be planned' do
    allow(Ruby4Lich5::PackagePolicy).to receive(:default_patched).and_return(->(name) { name == 'ox' })
    entries = [node('os'), node('ox', state: :native_self_contained)]
    prior, manifest = accepted(entries)
    manifest.fetch('targets').first.fetch('units').last.fetch('packages').first['self_build_equivalent'] = true
    result = described_class.build(previous_lock: prior, lock: lock([node('os', '1.1'), entries.last]), manifest: manifest, directory: @directory, accepted_patches: nil)
    expect(result.fetch('reuse').keys).to eq(['ox'])
  end

  it 'reassembles a multi-package closure without compiling unchanged native files' do
    entries = [node('child'), node('parent', '1.0', { 'child' => '>= 1.0' }), node('ox', state: :native_self_contained)]
    result = plan(entries, [node('child', '1.1'), entries[1], entries[2]])
    expect(result.fetch('changed')).to eq(['child'])
    expect(result.fetch('reuse').keys).to contain_exactly('parent', 'ox')
    expect(result.fetch('rebuild')).to be_empty
  end

  it 'rebuilds only the affected native build closure' do
    entries = [node('child'), node('parent', '1.0', { 'child' => '>= 1.0' }, state: :native_self_contained), node('ox', state: :native_self_contained)]
    result = plan(entries, [node('child', '1.1'), entries[1], entries[2]])
    expect(result.fetch('rebuild')).to eq(['parent'])
    expect(result.fetch('reuse').keys).to eq(['ox'])
  end

  it 'rejects accepted package drift and post-stage unrelated byte changes' do
    entries = [node('os')]
    prior, manifest = accepted(entries)
    result = described_class.build(previous_lock: prior, lock: prior, manifest: manifest, directory: @directory, accepted_patches: nil)
    File.write(File.join(@directory, 'os-1.0.gem'), 'changed bytes')
    expect { described_class.verify_staged!(result, @directory) }.to raise_error(ArgumentError, /unrelated accepted package/)
    expect { described_class.build(previous_lock: prior, lock: prior, manifest: manifest, directory: @directory, accepted_patches: nil) }.to raise_error(ArgumentError, /accepted package bytes/)
  end

  it 'stages unchanged pure and binary packages locally without a network fetch or compilation' do
    entries = [node('os'), node('binary', state: :native_pass_through)]
    prior, manifest = accepted(entries)
    result = described_class.build(previous_lock: prior, lock: prior, manifest: manifest, directory: @directory, accepted_patches: nil)
    client = instance_double(Ruby4Lich5::RubygemsClient)
    expect(client).not_to receive(:download_gem)
    paths = result.fetch('reuse').transform_values { |entry| entry.fetch('path') }
    staged = Ruby4Lich5::LockedArtifactMapBuilder.new(rubygems_client: client).build(entries, platform: prior.platform, built_gem_paths: paths)
    expect(staged.keys).to contain_exactly('os', 'binary')
  end

  describe 'curated patch fingerprints' do
    around { |example| Dir.mktmpdir { |root| @patches = root; example.run } }

    def patch(name, content)
      FileUtils.mkdir_p(File.join(@patches, name))
      File.write(File.join(@patches, name, 'fix.rb'), content)
      Ruby4Lich5::PatchFingerprint.compute(name, patches_root: @patches)
    end

    # Same locks on both sides: only the patch evidence can force a rebuild.
    def unchanged(entries, accepted_patches, gtk: [])
      prior, manifest = accepted(entries, gtk: gtk)
      described_class.build(previous_lock: prior, lock: lock(entries, gtk: gtk), manifest: manifest, directory: @directory,
                            accepted_patches: accepted_patches, patches_root: @patches)
    end

    let(:entries) { [node('os'), node('ox', state: :native_self_contained)] }

    it 'requires the accepted record to be passed explicitly' do
      prior, manifest = accepted(entries)
      expect { described_class.build(previous_lock: prior, lock: prior, manifest: manifest, directory: @directory) }
        .to raise_error(ArgumentError, /accepted_patches/)
    end

    it 'reuses a package whose recorded fingerprint equals the current tree' do
      digest = patch('ox', 'v1')
      result = unchanged(entries, { 'os' => nil, 'ox' => digest })
      expect(result.fetch('reuse').keys).to contain_exactly('os', 'ox')
      expect(result.fetch('patch_changed')).to be_empty
      expect(result.fetch('patch_fingerprints')).to eq('os' => nil, 'ox' => digest)
    end

    it 'rebuilds a package whose curated patch changed' do
      old = patch('ox', 'v1')
      patch('ox', 'v2')
      result = unchanged(entries, { 'os' => nil, 'ox' => old })
      expect(result.fetch('rebuild')).to eq(['ox'])
      expect(result.fetch('reuse').keys).to eq(['os'])
      expect(result.fetch('patch_changed')).to eq(['ox'])
      expect(result.fetch('patch_fingerprints').fetch('ox')).not_to eq(old)
    end

    it 'rebuilds a package whose curated patch was added or removed since the recorded build' do
      expect(unchanged(entries, { 'os' => nil, 'ox' => nil }).fetch('reuse').keys).to contain_exactly('os', 'ox')
      patch('ox', 'v1')
      expect(unchanged(entries, { 'os' => nil, 'ox' => nil }).fetch('rebuild')).to eq(['ox'])
      expect(unchanged(entries, { 'os' => nil }).fetch('rebuild')).to eq(['ox'])
      FileUtils.rm_rf(File.join(@patches, 'ox'))
      expect(unchanged(entries, { 'os' => nil, 'ox' => "sha256:#{'a' * 64}" }).fetch('rebuild')).to eq(['ox'])
    end

    it 'fails closed for an accepted build that recorded nothing while the package has patches' do
      patch('ox', 'v1')
      result = unchanged(entries, nil)
      expect(result.fetch('rebuild')).to eq(['ox'])
      expect(result.fetch('reuse').keys).to eq(['os'])
    end

    it 'keeps reusing an unrecorded package that has no patches, and keeps it unrecorded' do
      result = unchanged(entries, nil)
      expect(result.fetch('reuse').keys).to contain_exactly('os', 'ox')
      expect(result.fetch('rebuild')).to be_empty
      expect(result.fetch('patch_fingerprints')).to eq({})
    end

    it 'records current fingerprints for rebuilt packages after an unrecorded accepted build' do
      digest = patch('ox', 'v1')
      expect(unchanged(entries, nil).fetch('patch_fingerprints')).to eq('ox' => digest)
    end

    it 'invalidates a native parent when only its dependency patch changed' do
      closure = [node('child', state: :native_self_contained), node('parent', '1.0', { 'child' => '>= 1.0' }, state: :native_self_contained),
                 node('ox', state: :native_self_contained)]
      patch('child', 'v1')
      result = unchanged(closure, { 'child' => nil, 'parent' => nil, 'ox' => nil })
      expect(result.fetch('rebuild')).to contain_exactly('child', 'parent')
      expect(result.fetch('reuse').keys).to eq(['ox'])
    end

    it 'rebuilds the whole GTK role when one member patch changed' do
      closure = [node('glib2', state: :native_self_contained), node('gtk3', state: :native_self_contained), node('ox', state: :native_self_contained)]
      patch('glib2', 'v1')
      result = unchanged(closure, { 'glib2' => nil, 'gtk3' => nil, 'ox' => nil }, gtk: %w[glib2 gtk3])
      expect(result.fetch('rebuild')).to contain_exactly('glib2', 'gtk3')
      expect(result.fetch('reuse').keys).to eq(['ox'])
    end
  end

  describe 'bin/record_patch_fingerprints.rb' do
    script = File.expand_path('../../bin/record_patch_fingerprints.rb', __dir__)

    def record(*args)
      require 'open3'
      Open3.capture3(RbConfig.ruby, *args)
    end

    it 'records the committed tree without a plan and the plan record with one' do
      lock_path = File.join(@directory, 'lock.json')
      File.write(lock_path, JSON.generate(lock([node('os'), node('gtk3', state: :native_self_contained)]).to_h))
      output = File.join(@directory, 'out.json')
      _out, err, status = record(script, lock_path, output)
      expect(status.success?).to be(true), err
      written = JSON.parse(File.read(output))
      expect(written.keys).to eq(%w[gtk3 os])
      expect(written.fetch('gtk3')).to eq(Ruby4Lich5::PatchFingerprint.compute('gtk3'))
      expect(written.fetch('gtk3')).not_to be_nil
      expect(written.fetch('os')).to be_nil

      plan_path = File.join(@directory, 'plan.json')
      File.write(plan_path, JSON.generate('patch_fingerprints' => { 'os' => nil }))
      _out, err, status = record(script, lock_path, output, plan_path)
      expect(status.success?).to be(true), err
      expect(JSON.parse(File.read(output))).to eq('os' => nil)

      File.write(plan_path, JSON.generate('patch_fingerprints' => { 'os' => 'md5:x' }))
      expect(record(script, lock_path, output, plan_path).last.success?).to be(false)
    end
  end

  it 'preserves unrelated served artifact bytes for a D1-only swap and propagates a real shared ZIP change' do
    previous = { 'targets' => [{ 'ruby_abi' => '4.0', 'platform' => 'x64-mingw-ucrt', 'units' => [] }] }
    units = previous.fetch('targets').first.fetch('units')
    %w[parent other os].each do |name|
      units << { 'id' => name, 'members' => [name], 'install_order' => [name],
                 'packages' => [{ 'name' => name, 'version' => '1.0', 'filename' => "#{name}.gem", 'sha256' => "sha256:#{'a' * 64}" }],
                 'artifact' => { 'archive' => name == 'os' ? 'gem' : 'zip', 'url' => 'https://example.test/accepted', 'sha256' => "sha256:#{'b' * 64}" } }
    end
    current = Marshal.load(Marshal.dump(previous))
    latest = current.fetch('targets').first.fetch('units')
    latest.each { |unit| unit['artifact']['url'] = 'https://example.test/new-candidate'; unit['artifact']['sha256'] = "sha256:#{'c' * 64}" }
    latest.last.fetch('packages').first['version'] = '1.1'
    described_class.retain_artifacts!(current, previous)
    expect(latest.first(2).map { |unit| unit.fetch('artifact') }).to eq(units.first(2).map { |unit| unit.fetch('artifact') })
    expect(latest.last.dig('artifact', 'url')).to eq('https://example.test/new-candidate')
    latest.first.fetch('packages').first['version'] = '1.2'
    latest.first(2).each { |unit| unit['artifact']['sha256'] = "sha256:#{'d' * 64}" }
    described_class.retain_artifacts!(current, previous)
    expect(latest.first(2).map { |unit| unit.dig('artifact', 'sha256') }).to eq(["sha256:#{'d' * 64}"] * 2)
  end

  it 'retains an accepted artifact when only startup policy keys changed, never when the served bytes changed' do
    accepted = { 'archive' => 'gem', 'url' => 'https://example.test/accepted', 'sha256' => "sha256:#{'b' * 64}" }
    package = { 'name' => 'ox', 'version' => '1.0', 'filename' => 'ox.gem', 'sha256' => "sha256:#{'a' * 64}" }
    previous = { 'targets' => [{ 'ruby_abi' => '4.0', 'platform' => 'x64-mingw-ucrt',
                                 'units' => [{ 'id' => 'ox', 'members' => ['ox'], 'install_order' => ['ox'], 'packages' => [package], 'artifact' => accepted }] }] }
    current = Marshal.load(Marshal.dump(previous))
    unit = current.fetch('targets').first.fetch('units').first
    unit['artifact'] = accepted.merge('url' => 'https://example.test/new-candidate')
    unit.fetch('packages').first.merge!('self_build_equivalent' => true, 'minimum' => '0.9')
    described_class.retain_artifacts!(current, previous)
    expect(unit.fetch('artifact')).to eq(accepted)
    expect(unit.fetch('packages').first).to include('self_build_equivalent' => true, 'minimum' => '0.9')
    unit['artifact'] = accepted.merge('url' => 'https://example.test/new-candidate')
    unit.fetch('packages').first['sha256'] = "sha256:#{'c' * 64}"
    described_class.retain_artifacts!(current, previous)
    expect(unit.dig('artifact', 'url')).to eq('https://example.test/new-candidate')
  end

  it 'updates every shared ZIP pointer while keeping unrelated package bytes and D1 routing unchanged' do
    entries = [node('child'), node('parent', '1.0', { 'child' => '>= 1.0' }), node('other', '1.0', { 'child' => '>= 1.0' }), node('os')]
    packages = entries.map { |entry| stage(entry) }
    client = instance_double(Ruby4Lich5::RubygemsClient)
    packages.each do |package|
      allow(client).to receive(:versions).with(package.fetch('name')).and_return([
                                                                                   { 'number' => package.fetch('version'), 'platform' => 'ruby', 'sha' => package.fetch('sha256').delete_prefix('sha256:') }
                                                                                 ])
    end
    generate = lambda do |digest|
      Ruby4Lich5::GemManifestGenerator.new(root_names: %w[parent other os], delivery_states_by_name: entries.to_h { |entry| [entry[:name], 'pure'] },
                                           ruby_abi: '4.0', platform: 'x64-mingw-ucrt', repo: 'fixture/repo', pkg_dir: @directory,
                                           bundle_asset: { tag: 'candidate', filename: 'bundle.zip', sha256: digest }, native_digest_lookup: nil,
                                           rubygems_client: client,
                                           closure_resolver: Ruby4Lich5::InstalledGemClosure.new(requested_names: %w[parent other os], find_specs: Ruby4Lich5::StagedGemSpecFinder.new(pkg_dir: @directory))).generate
    end
    first = generate.call("sha256:#{'a' * 64}").fetch('targets').first.fetch('units')
    second = generate.call("sha256:#{'b' * 64}").fetch('targets').first.fetch('units')
    expect(first.flat_map { |unit| unit.fetch('packages') }).to eq(second.flat_map { |unit| unit.fetch('packages') })
    expect(second.select { |unit| unit.dig('artifact', 'archive') == 'zip' }.map { |unit| unit.dig('artifact', 'sha256') }).to eq(["sha256:#{'b' * 64}"] * 2)
    expect(first.last).to eq(second.last)
    expect(second.map { |unit| unit['id'] }).not_to include('gtk3-runtime')
  end
end
