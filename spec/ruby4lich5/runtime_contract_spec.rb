# frozen_string_literal: true

require 'tmpdir'
require 'fileutils'
require 'open3'
require 'ruby4lich5/contract_planner'
require 'ruby4lich5/resolution_lock'
require 'ruby4lich5/curated_gem_registry'
require 'ruby4lich5/ruby_inventory'

RSpec.describe Ruby4Lich5::RuntimeContract do
  let(:inventory) { { 'ruby_version' => '4.0.9', 'ruby_abi' => '4.0', 'platform' => 'x64-mingw-ucrt', 'gems' => { 'json' => { 'version' => '3.2.0', 'dependencies' => {} } } } }
  let(:registry) { instance_double(Ruby4Lich5::CuratedGemRegistry, bundle_default_roots: %w[gtk3 redis]) }
  let(:lockfile) do
    <<~LOCK
      GEM
        remote: https://rubygems.org/
        specs:
          json (3.1.0)
          redis (6.0.0)
            redis-client (>= 0)
          redis-client (0.30.1)
            json (>= 3.0)

      CHECKSUMS
        json (3.1.0) sha256=#{'a' * 64}
        redis (6.0.0) sha256=#{'b' * 64}
        redis-client (0.30.1) sha256=#{'c' * 64}
    LOCK
  end

  around do |example|
    Dir.mktmpdir do |directory|
      @source = directory
      FileUtils.mkdir_p(File.join(directory, 'lib'))
      FileUtils.cp(described_class::READER, File.join(directory, 'lib/runtime_gem_contract.rb'))
      File.write(File.join(directory, 'Gemfile'), "gem 'redis'\ngem 'json'\n")
      File.write(File.join(directory, 'Gemfile.lock'), lockfile)
      example.run
    end
  end

  before do
    allow(registry).to receive(:names_for_role).with('gtk').and_return(['gtk3'])
    allow(registry).to receive(:names_for_role).with('tooling').and_return(['pkg-config'])
    allow(registry).to receive(:classification_for).with('pkg-config', 'x64-mingw-ucrt', '4.0').and_return('pure')
  end

  def contract(**args)
    described_class.new(source_directory: @source, commit: 'd' * 40, inventory: inventory,
                        registry: registry, gtk_version: '4.3.9', **args)
  end

  def spec(name, version, dependencies = {})
    Gem::Specification.new do |item|
      item.name = name
      item.version = version
      dependencies.each { |child, requirements| item.add_runtime_dependency(child, *Array(requirements)) }
    end
  end

  def upstream(extra_dependency: false, gtk_specs: [])
    specs = [spec('gtk3', '4.3.9', 'json' => '>= 0'), spec('redis', '6.0.0', 'redis-client' => '>= 0'),
             spec('redis-client', '0.30.1', 'json' => '>= 3.0'), spec('redis-client', '99.0.0', 'json' => '>= 3.0')]
    if extra_dependency
      specs.find { |item| item.name == 'redis' }.add_runtime_dependency('unlocked')
      specs << spec('unlocked', '1.0')
    end
    unless gtk_specs.empty?
      specs.first.add_runtime_dependency('red-colors')
      specs.concat(gtk_specs)
    end
    set = Gem::Resolver::Set.new
    set.define_singleton_method(:find_all) do |request|
      specs.select { |item| request.match?(item) }.map { |item| Gem::Resolver::InstalledSpecification.new(self, item) }
    end
    set
  end

  def classifier
    result = Object.new
    result.define_singleton_method(:classify) do |name:, version:, **_args|
      Ruby4Lich5::Classification.new(state: name == 'json' ? :ruby_bundled : :pure,
                                     gem_name: name, gem_version: version, reason: 'offline fixture')
    end
    result
  end

  it 'pins every non-GTK transitive and records measured supplied differences' do
    result = contract
    expect(result.pins).to eq('redis' => '6.0.0', 'redis-client' => '0.30.1')
    expect(result.data.fetch('bundled_comparison')).to eq('json' => { 'locked' => '3.1.0', 'supplied' => '3.2.0' })
    expect(result.roots).to eq('redis' => '6.0.0', 'gtk3' => '4.3.9')
  end

  it 'uses the real RubyGems resolver with transitive filters and the supplied inventory' do
    closure = Ruby4Lich5::ContractPlanner.plan(contract, classifier: classifier, upstream: upstream)
    expect(closure.to_h { |entry| [entry[:name], entry[:version]] }).to include('redis-client' => '0.30.1', 'json' => '3.2.0')
    expect(closure.map { |entry| entry[:name] }.index('redis-client')).to be < closure.map { |entry| entry[:name] }.index('redis')
  end

  context 'terminal-table compact-index requirement ordering' do
    let(:lockfile) do
      <<~LOCK
        GEM
          remote: https://rubygems.org/
          specs:
            terminal-table (4.0.0)
              unicode-display_width (>= 1.1.1, < 4)
            unicode-display_width (3.2.0)

        CHECKSUMS
          terminal-table (4.0.0) sha256=#{'a' * 64}
          unicode-display_width (3.2.0) sha256=#{'b' * 64}
      LOCK
    end

    before do
      File.write(File.join(@source, 'Gemfile'), "gem 'terminal-table'\n")
      allow(registry).to receive(:bundle_default_roots).and_return(%w[gtk3 terminal-table])
    end

    def table_source(requirements)
      specs = [spec('gtk3', '4.3.9'), spec('terminal-table', '4.0.0', 'unicode-display_width' => requirements),
               spec('unicode-display_width', '3.2.0')]
      set = Gem::Resolver::Set.new
      set.define_singleton_method(:find_all) do |request|
        specs.select { |item| request.match?(item) }.map { |item| Gem::Resolver::InstalledSpecification.new(self, item) }
      end
      set
    end

    it 'accepts the real lock and compact-index order difference through the planner' do
      closure = Ruby4Lich5::ContractPlanner.plan(contract, classifier: classifier, upstream: table_source(['< 4', '>= 1.1.1']))
      expect(closure.find { |entry| entry[:name] == 'terminal-table' }.fetch(:version)).to eq('4.0.0')
    end

    it 'rejects a changed upper bound even when the same package version can resolve' do
      expect do
        Ruby4Lich5::ContractPlanner.plan(contract, classifier: classifier, upstream: table_source(['< 5', '>= 1.1.1']))
      end.to raise_error(described_class::Error, /dependency graph mismatch for terminal-table/)
    end
  end

  it 'emits schema 2 and keeps dev-only changes outside Windows eligibility' do
    original = contract
    Ruby4Lich5::ContractPlanner.plan(original, classifier: classifier, upstream: upstream)
    File.open(File.join(@source, 'Gemfile'), 'a') { |file| file.write("# harmless comment\ngroup :development do\n gem 'dev-tool'\nend\n") }
    changed_lock = lockfile.sub("\nCHECKSUMS", "    dev-tool (2.0)\n\nCHECKSUMS") + "  dev-tool (2.0) sha256=#{'d' * 64}\n"
    File.write(File.join(@source, 'Gemfile.lock'), changed_lock)
    changed = contract
    Ruby4Lich5::ContractPlanner.plan(changed, classifier: classifier, upstream: upstream)
    expect(changed.data.fetch('schema')).to eq(2)
    expect(changed.data.fetch('windows_contract_sha256')).to eq(original.data.fetch('windows_contract_sha256'))
    expect(changed.data.fetch('gemfile_sha256')).not_to eq(original.data.fetch('gemfile_sha256'))
    expect(changed.data.fetch('lock_sha256')).not_to eq(original.data.fetch('lock_sha256'))
  end

  it 'rejects old runtime schemas and malformed semantic digests at the lock boundary' do
    input = contract
    [{ 'schema' => 1 }, { 'windows_contract_sha256' => 'invalid' }, { 'windows_contract_sha256' => nil }].each do |bad|
      expect { described_class.validate!(input.data.merge(bad), ruby_installer_version: '4.0.9-1') }
        .to raise_error(described_class::Error, /invalid runtime contract/)
    end
  end

  it 'records reviewed GTK build tooling separately from the shipped runtime closure' do
    specs = [spec('gtk3', '4.3.9', 'pkg-config' => '>= 0'), spec('pkg-config', '1.0'),
             spec('redis', '6.0.0', 'redis-client' => '>= 0'), spec('redis-client', '0.30.1', 'json' => '>= 3.0')]
    source = Gem::Resolver::Set.new
    source.define_singleton_method(:find_all) do |request|
      specs.select { |item| request.match?(item) }.map { |item| Gem::Resolver::InstalledSpecification.new(self, item) }
    end
    input = contract
    closure = Ruby4Lich5::ContractPlanner.plan(input, classifier: classifier, upstream: source)
    expect(closure.map { |entry| entry[:name] }).not_to include('pkg-config')
    expect(input.data.dig('build_tooling', 'pkg-config', 'version')).to eq('1.0')
    expect(closure.find { |entry| entry[:name] == 'gtk3' }.fetch(:runtime_dependencies)).to be_empty
  end

  it 'rejects an unlocked transitive added by upstream metadata' do
    expect { Ruby4Lich5::ContractPlanner.plan(contract, classifier: classifier, upstream: upstream(extra_dependency: true)) }.to raise_error(described_class::Error, /dependency graph mismatch/)
  end

  it 'rejects target Ruby inventory drift' do
    inventory['ruby_version'] = '4.0.5'
    expect { contract }.to raise_error(described_class::Error, /differs from target/)
  end

  it 'rejects a source reader that differs at the selected candidate' do
    File.write(File.join(@source, 'lib/runtime_gem_contract.rb'), '# changed reader')
    expect { contract }.to raise_error(described_class::Error, /reader differs/)
  end

  it 'rejects an abbreviated candidate SHA' do
    expect do
      described_class.new(source_directory: @source, commit: 'abc1234', inventory: inventory, registry: registry, gtk_version: '4.3.9')
    end.to raise_error(described_class::Error, /full commit SHA/)
  end

  it 'requires explicit registry review when Lich adds a runtime root' do
    File.write(File.join(@source, 'Gemfile'), "gem 'redis'\ngem 'redis-client'\n")
    expect { contract }.to raise_error(described_class::Error, /registry roots differ/)
  end

  it 'reports exact lock edits and marks version override builds unpromotable' do
    result = contract(overrides: { 'redis-client' => '0.30.2' })
    expect(result.pins.fetch('redis-client')).to eq('0.30.2')
    expect(result.data.fetch('promotable')).to be(false)
    expect(result.report.fetch('required_lich5_lock_edits').join).to include('redis-client: Gemfile.lock 0.30.1 -> 0.30.2')
  end

  it 'rejects an override for an unreviewed gem' do
    expect { contract(overrides: { 'unreviewed' => '1.0' }) }.to raise_error(described_class::Error, /overrides must map locked/)
  end

  it 'marks root-subset diagnostics unpromotable' do
    expect(contract(selection: ['gtk3']).data.fetch('promotable')).to be(false)
  end

  it 'retains GTK until the later GTK-free effort' do
    expect { contract(selection: ['redis']) }.to raise_error(described_class::Error, /retain GTK/)
  end

  it 'requires reviewed GTK source provenance rather than downloading a floating tag' do
    expect do
      described_class.new(source_directory: @source, commit: 'd' * 40, inventory: inventory, registry: registry, gtk_version: '4.3.10')
    end.to raise_error(described_class::Error, /no reviewed immutable source/)
  end

  it 'persists immutable contract metadata through the existing resolution lock' do
    result = contract
    closure = Ruby4Lich5::ContractPlanner.plan(result, classifier: classifier, upstream: upstream)
    lock = Ruby4Lich5::ResolutionLock.new(ruby_installer_version: '4.0.9-1', platform: 'x64-mingw-ucrt', requested_roots: result.roots, closure: closure,
                                          registry_commit_sha: 'a' * 40, registry_content_digest: "sha256:#{'b' * 64}", contract: result.data)
    restored = Ruby4Lich5::ResolutionLock.from_h(JSON.parse(JSON.generate(lock.to_h)))
    expect(restored.to_h).to eq(lock.to_h)
    expect { restored.contract['overrides']['redis'] = '99' }.to raise_error(FrozenError)
    expect(described_class.require_promotable!(restored)).to be(true)
  end

  it 'refuses publication when an override flag is dishonestly marked promotable' do
    data = contract(overrides: { 'redis-client' => '0.30.2' }).data.merge('promotable' => true)
    expect { described_class.validate!(data, ruby_installer_version: '4.0.9-1') }.to raise_error(described_class::Error, /unpromotable/)
  end

  it 'rejects legacy diagnostic locks at the production boundary' do
    lock = double('uncontracted lock', contract: nil, ruby_installer_version: '4.0.9-1', closure: [])
    expect { described_class.require_promotable!(lock) }.to raise_error(described_class::Error, /invalid runtime contract/)
  end

  it 'compares the entire pristine inventory again on the consumer runtime' do
    allow(Ruby4Lich5::RubyInventory).to receive(:capture).and_return(inventory)
    expect(Ruby4Lich5::RubyInventory.verify!(inventory)).to be(true)
    changed = Marshal.load(Marshal.dump(inventory))
    changed['gems']['json']['version'] = '3.3.0'
    expect { Ruby4Lich5::RubyInventory.verify!(changed) }.to raise_error(ArgumentError, /inventory differs/)
  end

  it 'pins GTK-only non-GTK members while keeping unused catalog entries out of roots and closure' do
    extra = "    red-colors (0.5.0)\n    unused (1.0)\n"
    text = lockfile.sub("\nCHECKSUMS", "#{extra}\nCHECKSUMS") + "  red-colors (0.5.0) sha256=#{'e' * 64}\n  unused (1.0) sha256=#{'f' * 64}\n"
    File.write(File.join(@source, 'Gemfile.lock'), text)
    input = contract
    source = upstream(gtk_specs: [spec('red-colors', '0.5.0'), spec('red-colors', '0.6.0')])
    closure = Ruby4Lich5::ContractPlanner.plan(input, classifier: classifier, upstream: source)
    expect(input.pins).to include('red-colors' => '0.5.0', 'unused' => '1.0')
    expect(input.roots).not_to have_key('red-colors')
    expect(input.roots).not_to have_key('unused')
    expect(closure.find { |entry| entry[:name] == 'red-colors' }.fetch(:version)).to eq('0.5.0')
    expect(closure.map { |entry| entry[:name] }).not_to include('unused')
    reader = Lich::RuntimeGemContract.new(gemfile: File.binread(File.join(@source, 'Gemfile')), lockfile: text)
    expected_digest = reader.windows_contract_digest(inventory, build_roles: input.data.fetch('build_roles'), advertised_members: closure.map { |entry| entry.fetch(:name) })
    expect(input.data.fetch('windows_contract_sha256')).to eq(expected_digest)
    expect(expected_digest).not_to eq(reader.windows_contract_digest(inventory, build_roles: input.data.fetch('build_roles')))
    tampered = Marshal.load(Marshal.dump(closure))
    tampered.find { |entry| entry[:name] == 'red-colors' }[:version] = '0.6.0'
    expect { described_class.validate!(input.data, ruby_installer_version: '4.0.9-1', closure: tampered) }.to raise_error(described_class::Error, /version mismatch for red-colors/)
  end

  it 'rejects new GTK-only runtime dependencies absent from the selected lock' do
    source = upstream(gtk_specs: [spec('red-colors', '0.6.0')])
    expect { Ruby4Lich5::ContractPlanner.plan(contract, classifier: classifier, upstream: source) }.to raise_error(described_class::Error, /absent from the selected Windows lock/)
  end

  it 'wraps malformed contract metadata for direct lock construction and the manifest CLI' do
    input = contract
    closure = Ruby4Lich5::ContractPlanner.plan(input, classifier: classifier, upstream: upstream)
    args = { ruby_installer_version: '4.0.9-1', platform: 'x64-mingw-ucrt', requested_roots: input.roots, closure: closure,
             registry_commit_sha: 'a' * 40, registry_content_digest: "sha256:#{'b' * 64}" }
    expect { Ruby4Lich5::ResolutionLock.new(**args, contract: { 'schema' => 99 }) }.to raise_error(Ruby4Lich5::ResolutionLock::ValidationError, /invalid runtime contract/)
    lock = Ruby4Lich5::ResolutionLock.new(**args, contract: input.data).to_h
    lock['contract'] = { 'schema' => 99 }
    path = File.join(@source, 'invalid-lock.json')
    File.write(path, JSON.generate(lock))
    cli = File.expand_path('../../bin/generate_gem_manifest.rb', __dir__)
    _output, error, status = Open3.capture3(RbConfig.ruby, cli, path, 'owner/repo', 'tag', 'bundle.zip', 'a' * 64, @source, File.join(@source, 'manifest.json'))
    expect(status.exitstatus).to eq(2)
    expect(error).to include('ResolutionLock::ValidationError', 'invalid runtime contract')
    expect(error).not_to include('from_h', 'Traceback')
  end

  it 'keeps the locked Windows platform when upstream offers the same version as pure Ruby too' do
    windows = spec('redis-client', '0.30.1', 'json' => '>= 3.0')
    windows.platform = 'x64-mingw-ucrt'
    ruby = spec('redis-client', '0.30.1', 'json' => '>= 3.0')
    source = Gem::Resolver::Set.new
    source.define_singleton_method(:find_all) { |_request| [ruby, windows].map { |item| Gem::Resolver::InstalledSpecification.new(self, item) } }
    request = Gem::Resolver::DependencyRequest.new(Gem::Dependency.new('redis-client'), nil)
    set = Ruby4Lich5::PinnedResolverSet.new(pins: { 'redis-client' => '0.30.1' }, supplied: {}, platforms: { 'redis-client' => 'x64-mingw-ucrt' }, upstream: source)
    expect(set.find_all(request).map { |item| item.platform.to_s }).to eq(['x64-mingw-ucrt'])
  end

  it 'rejects malformed nested contract fields through the lock validation boundary' do
    input = contract
    closure = Ruby4Lich5::ContractPlanner.plan(input, classifier: classifier, upstream: upstream)
    [{ 'ruby_inventory' => [] }, { 'locked_packages' => { 'redis' => nil } }, { 'build_roles' => [] }].each do |bad|
      expect do
        Ruby4Lich5::ResolutionLock.new(ruby_installer_version: '4.0.9-1', platform: 'x64-mingw-ucrt', requested_roots: input.roots, closure: closure,
                                       registry_commit_sha: 'a' * 40, registry_content_digest: "sha256:#{'b' * 64}", contract: input.data.merge(bad))
      end.to raise_error(Ruby4Lich5::ResolutionLock::ValidationError, /invalid runtime contract/)
    end
  end
end
