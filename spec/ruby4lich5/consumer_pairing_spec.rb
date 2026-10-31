# frozen_string_literal: true

require 'tmpdir'
require 'fileutils'
require 'open3'
require 'ruby4lich5/contract_planner'
require 'ruby4lich5/known_native_gems'
require 'ruby4lich5/ruby_bundled_gems'
require 'ruby4lich5/runtime_inventory'
require 'ruby4lich5/resolution_lock'

RSpec.describe 'Pinned producer and consumer source pairing' do
  let(:root) { File.expand_path('../..', __dir__) }
  let(:identity) { JSON.parse(File.read(File.join(root, 'vendor/lich5/contract-source.json'))) }
  let(:fixture) { File.join(root, identity.fetch('fixture')) }
  let(:snapshot) { JSON.parse(File.read(File.join(fixture, 'source.json'))) }
  let(:registry) { Ruby4Lich5::KnownNativeGems.registry }
  let(:reader) do
    Lich::RuntimeGemContract.new(gemfile: File.binread(File.join(@source, 'Gemfile')), lockfile: File.binread(File.join(@source, 'Gemfile.lock')))
  end
  # Controlled supplied-gem inventory uses locked fixture versions. This is
  # integration coverage, not a measured RubyInstaller/native-build claim.
  let(:inventory) do
    gems = reader.locked_packages.select { |name, _| Ruby4Lich5::RubyBundledGems.bundled?(name) }
    { 'ruby_version' => '4.0.9', 'ruby_abi' => '4.0', 'platform' => 'x64-mingw-ucrt', 'gems' => gems }
  end
  let(:contract) do
    Ruby4Lich5::RuntimeContract.new(source_directory: @source, commit: identity.fetch('commit'), inventory: inventory, registry: registry, gtk_version: '4.3.9')
  end

  around do |example|
    Dir.mktmpdir do |directory|
      @source = File.join(directory, 'source')
      FileUtils.cp_r(fixture, @source)
      @output = directory
      example.run
    end
  end

  before do
    # Resolve Windows specs on the host without loading their native binaries.
    allow(Gem).to receive(:platforms).and_return([Gem::Platform::RUBY, Gem::Platform.new('x64-mingw-ucrt')])
  end

  def upstream
    # Real non-GTK Windows lock graph; GTK construction is an explicit seam.
    specs = reader.locked_packages.map do |name, entry|
      Gem::Specification.new do |spec|
        spec.name = name
        spec.version = entry.fetch('version')
        spec.platform = entry.fetch('platform')
        entry.fetch('dependencies').each { |child, requirements| spec.add_runtime_dependency(child, *requirements) }
      end
    end
    specs.reject! { |spec| spec.name == 'gtk3' }
    specs << Gem::Specification.new('gtk3', '4.3.9')
    set = Gem::Resolver::Set.new
    set.define_singleton_method(:find_all) do |request|
      specs.select { |spec| request.match?(spec) }.map { |spec| Gem::Resolver::InstalledSpecification.new(self, spec) }
    end
    set
  end

  def prepare
    supplied = inventory.fetch('gems')
    classifier = Object.new
    classifier.define_singleton_method(:classify) do |name:, version:, **_args|
      Ruby4Lich5::Classification.new(state: supplied.key?(name) ? :ruby_bundled : :pure, gem_name: name, gem_version: version, reason: 'offline pairing fixture')
    end
    closure = Ruby4Lich5::ContractPlanner.plan(contract, classifier: classifier, upstream: upstream)
    lock = Ruby4Lich5::ResolutionLock.new(ruby_installer_version: '4.0.9-1', platform: 'x64-mingw-ucrt',
                                          requested_roots: contract.roots, closure: closure, registry_commit_sha: 'a' * 40,
                                          registry_content_digest: "sha256:#{'b' * 64}", contract: contract.data)
    restored = Ruby4Lich5::ResolutionLock.from_h(JSON.parse(JSON.generate(lock.to_h)))
    expect(Ruby4Lich5::RuntimeContract.require_promotable!(restored)).to be(true)
    packages = Ruby4Lich5::RuntimeInventory.entries(closure).map do |node|
      name, version = node.values_at(:name, :version)
      spec = contract.data.fetch('locked_packages')[name]
      { 'name' => name, 'version' => version, 'filename' => "#{name}-#{version}.gem", 'sha256' => "sha256:#{spec ? spec.fetch('sha256') : 'e' * 64}" }
    end
    unit = { 'id' => 'runtime', 'members' => packages.map { |package| package['name'] }, 'packages' => packages,
             'install_order' => packages.map { |package| package['name'] },
             'artifact' => { 'url' => 'https://example.test/runtime.zip', 'filename' => 'runtime.zip', 'archive' => 'zip', 'sha256' => "sha256:#{'a' * 64}" } }
    manifest = { 'schema' => 1, 'targets' => [{ 'platform' => 'x64-mingw-ucrt', 'ruby_abi' => '4.0', 'contract' => restored.contract, 'units' => [unit] }] }
    write_manifest(manifest)
    manifest
  end

  def write_manifest(manifest)
    bytes = JSON.generate(manifest)
    File.write(File.join(@output, 'manifest.json'), bytes)
    provenance = { 'runtime_contract_sha256' => Lich::RuntimeGemContract.digest(manifest.fetch('targets').first.fetch('contract')),
                   'recovery_manifest_sha256' => Digest::SHA256.hexdigest(bytes), 'ruby_installer_version' => '4.0.9-1', 'installer_sha256' => 'f' * 64 }
    File.write(File.join(@output, 'provenance.json'), JSON.generate(provenance))
  end

  def check
    program = <<~'RUBY'
      require 'json'
      source, output, commit = ARGV
      begin
        Lich::R4L5ContractCheck.verify!(gemfile: File.binread(File.join(source, 'Gemfile')), lockfile: File.binread(File.join(source, 'Gemfile.lock')),
          manifest_bytes: File.binread(File.join(output, 'manifest.json')), provenance: JSON.parse(File.read(File.join(output, 'provenance.json'))), candidate_sha: commit, lich_version: File.read(File.join(source, 'lib/version.rb'))[/^LICH_VERSION = '([^']+)'/, 1])
        puts 'accepted'
      rescue Lich::RuntimeGemContract::Error => error
        warn error.message
        exit 2
      end
    RUBY
    environment = { 'RUBYOPT' => nil, 'RUBYLIB' => nil, 'BUNDLER_SETUP' => nil, 'RUBYGEMS_GEMDEPS' => nil }
    Open3.capture3(environment, RbConfig.ruby, '-r', File.join(@source, 'lib/r4l5_contract_check.rb'), '-e', program, @source, @output, identity.fetch('commit'))
  end

  it 'pins an independently captured consumer and accepts its real declarations through both sides' do
    expect(identity.fetch('repository')).to eq('elanthia-online/lich-5')
    expect(identity.fetch('commit')).to eq(snapshot.fetch('commit'))
    snapshot.fetch('files').each { |path, digest| expect(Digest::SHA256.file(File.join(fixture, path)).hexdigest).to eq(digest) }
    expect(Digest::SHA256.file(Ruby4Lich5::RuntimeContract::READER).hexdigest).to eq(identity.fetch('reader_sha256'))
    expect(identity.fetch('reader_sha256')).to eq(snapshot.fetch('files').fetch('lib/runtime_gem_contract.rb'))
    prepare
    output, error, status = check
    expect(status.success?).to be(true), error
    expect(output).to include('accepted')
  end

  it 'accepts dev-only changes but rejects a changed Windows requirement against the same accepted contract' do
    prepare
    path = File.join(@source, 'Gemfile')
    original = File.binread(path)
    File.write(path, original + "\ngroup :development do\n  gem 'fixture-development-only'\nend\n")
    lock = File.join(@source, 'Gemfile.lock')
    text = File.binread(lock)
    File.write(lock, text.sub("\nCHECKSUMS", "    fixture-development-only (1.0)\n\nCHECKSUMS") + "  fixture-development-only (1.0) sha256=#{'a' * 64}\n")
    _output, error, status = check
    expect(status.success?).to be(true), error
    File.write(path, original.sub('gem "redis"', 'gem "redis", ">= 5"'))
    _output, error, status = check
    expect(status.exitstatus).to eq(2)
    expect(error).to include('Windows projection')
  end

  it 'binds the candidate-selected members rather than a displaced legacy-only non-GTK lock member' do
    manifest = JSON.parse(JSON.generate(prepare))
    target = manifest.fetch('targets').first
    selected = target.fetch('units').first
    legacy = Marshal.load(Marshal.dump(selected))
    extra = reader.locked_packages.fetch('ast')
    legacy['members'] << 'ast'
    legacy['install_order'].unshift('ast')
    legacy['packages'] << { 'name' => 'ast', 'version' => extra.fetch('version'), 'filename' => "ast-#{extra.fetch('version')}.gem", 'sha256' => "sha256:#{extra.fetch('sha256')}" }
    version = contract.data.fetch('lich_version')
    target['units'] = [legacy, selected.merge('id' => 'runtime-ranged', 'legacy_unit' => 'runtime', 'lich_versions' => { 'min_inclusive' => version })]
    target['range_reader'] = { 'release' => "v#{version}", 'commit' => identity.fetch('commit') }
    expect(Lich::RecoveryUnitPolicy.select(target, version).flat_map { |unit| unit.fetch('members') }).not_to include('ast')
    write_manifest(manifest)
    _output, error, status = check
    expect(status.success?).to be(true), error
    wrong = reader.windows_contract_digest(inventory, build_roles: target.fetch('contract').fetch('build_roles'),
                                                      advertised_members: target.fetch('units').flat_map { |unit| unit.fetch('members') })
    expect(wrong).not_to eq(target.fetch('contract').fetch('windows_contract_sha256'))
    target.fetch('contract')['windows_contract_sha256'] = wrong
    write_manifest(manifest)
    _output, error, status = check
    expect(status.exitstatus).to eq(2)
    expect(error).to include('Windows projection')
  end

  it 'allows selected-group declarations without a lock but requires one for producer resolution' do
    declarations = "gem 'redis'\ngroup :development do\n  gem 'rake'\nend\n"
    selected = Lich::RuntimeGemContract.new(gemfile: declarations, groups: ['development'])
    expect(selected.roots.keys).to eq(['rake'])
    expect(selected.lock_sha256).to be_nil
    expect { selected.resolve(inventory) }.to raise_error(Lich::RuntimeGemContract::Error, /lockfile is required for producer resolution/)
    expect(Lich::RuntimeGemContract.new(gemfile: declarations).roots.keys).to eq(['redis'])
  end

  it 'retains strict reader-byte and old-schema rejection' do
    manifest = JSON.parse(JSON.generate(prepare))
    manifest.fetch('targets').first.fetch('contract')['schema'] = 1
    write_manifest(manifest)
    _output, error, status = check
    expect(status.exitstatus).to eq(2)
    expect(error).to include('unsupported runtime contract')
    File.open(File.join(@source, 'lib/runtime_gem_contract.rb'), 'a') { |file| file.puts('# unreviewed reader bytes') }
    expect do
      Ruby4Lich5::RuntimeContract.new(source_directory: @source, commit: identity.fetch('commit'), inventory: inventory, registry: registry, gtk_version: '4.3.9')
    end.to raise_error(Ruby4Lich5::RuntimeContract::Error, /reader differs/)
  end
end
