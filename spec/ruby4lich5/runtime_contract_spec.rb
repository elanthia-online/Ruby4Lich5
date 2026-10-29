# frozen_string_literal: true

require 'tmpdir'
require 'fileutils'
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

  def upstream(extra_dependency: false)
    specs = [spec('gtk3', '4.3.9', 'json' => '>= 0'), spec('redis', '6.0.0', 'redis-client' => '>= 0'),
             spec('redis-client', '0.30.1', 'json' => '>= 3.0'), spec('redis-client', '99.0.0', 'json' => '>= 3.0')]
    if extra_dependency
      specs.find { |item| item.name == 'redis' }.add_runtime_dependency('unlocked')
      specs << spec('unlocked', '1.0')
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
end
