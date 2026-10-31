# frozen_string_literal: true

require 'tmpdir'
require 'fileutils'
require 'ruby4lich5/supported_startup_policy'
require_relative '../../vendor/lich5/runtime_gem_contract'

RSpec.describe Ruby4Lich5::SupportedStartupPolicy do
  let(:root) { File.expand_path('../..', __dir__) }
  let(:gemfile) { "gem 'redis', '< 99'\n" }
  let(:version) { '5.23.0' }
  let(:published_releases) { { 'schema' => 1, 'repository' => 'elanthia-online/lich-5', 'complete' => true, 'release_ids' => [], 'clients' => [] } }
  let(:document) do
    data = JSON.parse(File.read(File.join(root, 'manifest/R4L5-gem-manifest.json')))
    target = data.fetch('targets').first
    # Host-only selection fixture. Production uses unmodified Windows bytes on
    # the exact RubyInstaller; this executes no native activation or installs.
    target['platform'] = Gem::Platform.local.to_s
    target.fetch('units').each do |unit|
      unit.fetch('packages').each { |package| package['filename'] = package.fetch('filename').sub('-x64-mingw-ucrt.gem', "-#{Gem::Platform.local}.gem") }
      %w[filename url].each { |key| unit.fetch('artifact')[key] = unit.fetch('artifact').fetch(key).sub('-x64-mingw-ucrt.gem', "-#{Gem::Platform.local}.gem") }
    end
    names = target.fetch('units').flat_map { |unit| unit.fetch('members') }
    legacy_roots = JSON.parse(File.read(described_class::CONFIG)).fetch('legacy').values.flat_map do |entry|
      text = File.read(File.join(root, entry.fetch('gemfile'))).sub(described_class::LEGACY_SQLITE, "gem 'sqlite3'\n")
      Lich::RuntimeGemContract.new(gemfile: text, groups: %w[default profanity gtk]).roots.keys
    end
    supplied = (legacy_roots - names).to_h { |name| [name, { 'version' => '1.0', 'dependencies' => {} }] }
    target['contract'] = { 'lich5_commit' => 'a' * 40, 'lich_version' => version, 'gemfile_sha256' => Digest::SHA256.hexdigest(gemfile),
                           'ruby_inventory' => { 'gems' => supplied } }
    data
  end

  around do |example|
    Dir.mktmpdir do |directory|
      @source = directory
      FileUtils.mkdir_p(File.join(directory, 'lib'))
      described_class::REVIEWED_FILES.each { |path, vendor| FileUtils.cp(File.join(root, 'vendor/lich5', vendor), File.join(directory, path)) }
      File.write(File.join(directory, 'Gemfile'), gemfile)
      File.write(File.join(directory, 'lib/version.rb'), "LICH_VERSION = '#{version}'\n")
      example.run
    end
  end

  def context
    { 'candidate_sha256'         => "sha256:#{Digest::SHA256.hexdigest(JSON.generate(document))}",
      'supported_startup_policy' => described_class.identity(document.fetch('targets').first.fetch('contract'), published_releases: published_releases) }
  end

  def verify(data = context)
    described_class.verify!(manifest_bytes: JSON.generate(document), context: data, source_directory: @source)
  end

  it 'runs pinned legacy recovery and candidate startup implementations for core and GTK in isolation' do
    expect(context.fetch('supported_startup_policy').fetch('clients').map { |client| client.fetch('id') }).to contain_exactly(
      'oldest-core', 'oldest-gtk', 'current-core', 'current-gtk', 'ranged-core', 'ranged-gtk'
    )
    expect(verify).to eq(Digest::SHA256.hexdigest(JSON.generate(context.fetch('supported_startup_policy'))))
    clients = context.fetch('supported_startup_policy').fetch('clients')
    expect(clients.reject { |client| client['id'].start_with?('ranged-') }.map { |client| client['execution'] }.uniq).to eq(['legacy-recovery'])
    expect(clients.select { |client| client['id'].start_with?('ranged-') }.map { |client| client['execution'] }.uniq).to eq(['startup'])
  end

  it 'rejects a policy that removes a required root from supported legacy clients' do
    document.fetch('targets').first.fetch('units').reject! { |unit| unit['id'] == 'ox' }
    expect { verify }.to raise_error(ArgumentError, /supported startup policy rejected:.*supported client current-core/m)
  end

  it 'rejects an unsupported schema and ABI instead of revoking startup support' do
    document['schema'] = 99
    expect { verify }.to raise_error(ArgumentError, /supported startup policy rejected/)
    document['schema'] = 1
    document.fetch('targets').first['ruby_abi'] = '9.9'
    expect { verify }.to raise_error(ArgumentError, /supported startup policy rejected/)
  end

  context 'when the selected candidate declares an incompatible version bound' do
    let(:gemfile) { "gem 'redis', '< 1'\n" }

    it 'rejects served floors that cannot satisfy the candidate startup declarations' do
      expect { verify }.to raise_error(ArgumentError, /supported client ranged-core/)
    end
  end

  it 'rejects matrix, candidate bytes, declaration and checker drift after inspection' do
    approved = context
    approved.fetch('supported_startup_policy').fetch('clients').pop
    expect { verify(approved) }.to raise_error(ArgumentError, /matrix differs/)
    expect { verify(context.merge('candidate_sha256' => 'wrong')) }.to raise_error(ArgumentError, /candidate bytes changed/)
    File.write(File.join(@source, 'Gemfile'), "gem 'other'\n")
    expect { verify }.to raise_error(ArgumentError, /client Gemfile changed/)
    File.write(File.join(@source, 'Gemfile'), gemfile)
    File.write(File.join(@source, 'lib/startup_policy_compatibility.rb'), '# altered')
    expect { verify }.to raise_error(ArgumentError, /differs from reviewed source/)
  end

  it 'requires the candidate version from its selected source, without guessing a future release' do
    File.write(File.join(@source, 'lib/version.rb'), "LICH_VERSION = '5.24.0'\n")
    expect { verify }.to raise_error(ArgumentError, /candidate version differs/)
  end
  context 'with a supported earlier startup implementation' do
    around do |example|
      real_root = described_class::ROOT
      Dir.mktmpdir do |workspace|
        FileUtils.mkdir_p(File.join(workspace, 'vendor'))
        FileUtils.cp_r(File.join(real_root, 'vendor/lich5'), File.join(workspace, 'vendor'))
        FileUtils.mkdir_p(File.join(workspace, 'config'))
        FileUtils.cp_r(File.join(real_root, 'config/supported-clients'), File.join(workspace, 'config'))
        directory = File.join(workspace, 'vendor/lich5/supported-startup-clients/earlier')
        FileUtils.mkdir_p(File.join(directory, 'lib'))
        described_class::REVIEWED_FILES.each do |path, vendor|
          FileUtils.cp(File.join(real_root, 'vendor/lich5', vendor), File.join(directory, path))
        end
        helper = File.join(directory, 'lib/startup_policy_compatibility.rb')
        File.open(helper, 'a') do |file|
          file.write(<<~'RUBY')
            class Lich::StartupPolicyCompatibility
              class << self
                alias_method :verify_before_fixture_gate!, :verify!
                def verify!(manifest_bytes:, clients:)
                  raise Lich::AcceptedGemPolicy::PolicyError, 'earlier-reader fixture rejects new selection rule' if JSON.parse(manifest_bytes)['fixture_new_selection']
                  verify_before_fixture_gate!(manifest_bytes: manifest_bytes, clients: clients)
                end
              end
            end
          RUBY
        end
        File.write(File.join(directory, 'Gemfile'), gemfile)
        config = JSON.parse(File.read(described_class::CONFIG))
        config['startup'] = { 'earlier' => {
          'commit' => 'e' * 40, 'lich_version' => version,
          'gemfile' => 'vendor/lich5/supported-startup-clients/earlier/Gemfile', 'gemfile_sha256' => Digest::SHA256.hexdigest(gemfile),
          'source_directory' => 'vendor/lich5/supported-startup-clients/earlier',
          'files' => described_class::REVIEWED_FILES.to_h { |path, _vendor| [path, Digest::SHA256.file(File.join(directory, path)).hexdigest] }
        } }
        path = File.join(workspace, 'config/supported-startup-clients.json')
        File.write(path, JSON.generate(config))
        @workspace = workspace
        @config_path = path
        @earlier_helper = helper
        example.run
      end
    end

    before do
      stub_const('Ruby4Lich5::SupportedStartupPolicy::ROOT', @workspace)
      stub_const('Ruby4Lich5::SupportedStartupPolicy::CONFIG', @config_path)
      stub_const('Ruby4Lich5::SupportedStartupPolicy::SOURCE', File.join(@workspace, 'vendor/lich5/ranged-source.json'))
    end

    it 'checks each older implementation rather than replaying its declarations with the candidate checker' do
      expect(context.fetch('supported_startup_policy').fetch('clients').map { |client| client['id'] }).to include('earlier-core', 'earlier-gtk')
      expect { verify }.not_to raise_error
      document['fixture_new_selection'] = true
      program = "require 'json'; input = JSON.parse($stdin.read); Lich::StartupPolicyCompatibility.verify!(manifest_bytes: input.fetch('manifest'), clients: input.fetch('clients'))"
      output, status = Open3.capture2e({ 'RUBYOPT' => nil, 'RUBYLIB' => nil, 'BUNDLER_SETUP' => nil, 'RUBYGEMS_GEMDEPS' => nil }, RbConfig.ruby, '-r', File.join(@source, 'lib/startup_policy_compatibility.rb'), '-e', program, stdin_data: JSON.generate('manifest' => JSON.generate(document), 'clients' => [{ 'id' => 'newest', 'gemfile' => gemfile, 'groups' => ['default'], 'lich_version' => version }]))
      expect(status.success?).to be(true), output
      expect { verify }.to raise_error(ArgumentError, /earlier-reader fixture rejects new selection rule/)
    end

    context 'after the earlier candidate becomes a published online-policy release' do
      let(:published_releases) do
        earlier = JSON.parse(File.read(@config_path)).fetch('startup').fetch('earlier')
        { 'schema' => 1, 'repository' => 'elanthia-online/lich-5', 'complete' => true, 'release_ids' => [1],
          'clients' => [{ 'release_id' => 1, 'tag' => 'v5.23.0', 'prerelease' => false, 'commit' => earlier.fetch('commit'),
                         'lich_version' => version, 'files' => earlier.fetch('files').merge('Gemfile' => earlier.fetch('gemfile_sha256'), 'lib/version.rb' => 'a' * 64) }] }
      end

      it 'requires the published X in the matrix when inspecting Y, and still executes X itself' do
        inventory = published_releases
        expect { verify }.not_to raise_error
        config = JSON.parse(File.read(@config_path))
        config['startup'] = {}
        File.write(@config_path, JSON.generate(config))
        expect do
          described_class.identity(document.fetch('targets').first.fetch('contract'), published_releases: inventory)
        end.to raise_error(ArgumentError, /published policy client is missing from retention/)
        config['retired'] = { 'v5.23.0' => { 'commit' => 'e' * 40, 'reason' => 'Explicit fixture support retirement' } }
        File.write(@config_path, JSON.generate(config))
        expect { described_class.identity(document.fetch('targets').first.fetch('contract'), published_releases: inventory) }.not_to raise_error
      end
    end

    it 'rejects a changed retained implementation before executing it' do
      File.write(@earlier_helper, '# changed retained reader')
      expect { verify }.to raise_error(ArgumentError, /implementation differs from pinned revision/)
    end
  end
end
