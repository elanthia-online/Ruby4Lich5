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
      'oldest-core', 'oldest-gtk', 'current-core', 'current-gtk', 'v5_24_0-core', 'v5_24_0-gtk', 'v5_24_1-core', 'v5_24_1-gtk',
      'ranged-core', 'ranged-gtk'
    )
    expect(verify).to eq(Digest::SHA256.hexdigest(JSON.generate(context.fetch('supported_startup_policy'))))
    clients = context.fetch('supported_startup_policy').fetch('clients')
    legacy = clients.select { |client| client['id'].start_with?('oldest-', 'current-') }
    expect(legacy.map { |client| client['execution'] }.uniq).to eq(['legacy-recovery'])
    expect((clients - legacy).map { |client| client['execution'] }.uniq).to eq(['startup'])
  end

  it 'exposes unused retirement tags and their configured identity in the inspected policy' do
    config = JSON.parse(File.binread(described_class::CONFIG))
    config['retired'] = { 'v5.23.0-typo' => { 'commit' => 'b' * 40, 'reason' => 'Reviewed fixture retirement' } }
    allow(File).to receive(:binread).and_call_original
    allow(File).to receive(:binread).with(described_class::CONFIG).and_return(JSON.generate(config))
    policy = context.fetch('supported_startup_policy')
    expect(policy.fetch('unused_retirements')).to eq(config.fetch('retired'))
    expect(policy.fetch('clients').size).to eq(10)
    expect(verify).to eq(Digest::SHA256.hexdigest(JSON.generate(policy)))
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

      context 'when the published earlier client is explicitly retired' do
        before do
          release = published_releases.fetch('clients').first
          config = JSON.parse(File.read(@config_path))
          config['startup'] = {}
          config['retired'] = { release.fetch('tag') => { 'commit' => release.fetch('commit'), 'reason' => 'Reviewed fixture retirement' } }
          File.write(@config_path, JSON.generate(config))
        end

        it 'omits unused-retirement diagnostics when every configured tag matches a published client' do
          policy = context.fetch('supported_startup_policy')
          expect(policy).not_to have_key('unused_retirements')
          expect(policy.fetch('clients').size).to eq(6)
          expect(verify).to eq(Digest::SHA256.hexdigest(JSON.generate(policy)))
        end

        it 'reports only the unmatched retirement when a real retirement and a typo are configured' do
          config = JSON.parse(File.read(@config_path))
          typo = { 'commit' => 'b' * 40, 'reason' => 'Unmatched fixture retirement' }
          config.fetch('retired')['v5.23.0-typo'] = typo
          File.write(@config_path, JSON.generate(config))

          policy = context.fetch('supported_startup_policy')
          expect(policy.fetch('unused_retirements')).to eq('v5.23.0-typo' => typo)
          expect(policy.fetch('clients').size).to eq(6)
          expect(verify).to eq(Digest::SHA256.hexdigest(JSON.generate(policy)))
        end
      end
    end

    it 'rejects a changed retained implementation before executing it' do
      File.write(@earlier_helper, '# changed retained reader')
      expect { verify }.to raise_error(ArgumentError, /implementation differs from pinned revision/)
    end
  end

  context 'with the registered published lich-5 5.24 startup clients' do
    let(:pinned) { File.join(root, 'vendor/lich5/supported-startup-clients') }
    # Real tag commits; bytes are the pinned copies whose Git blob IDs equal the tags' blobs.
    let(:tags) do
      { 'v5.24.0' => { 'id' => 101, 'commit' => '63db709b59a474b94fd2ef6eaea94422c0e71020' },
        'v5.24.1' => { 'id' => 102, 'commit' => '2ae1a07e130c01b1d7161885d2935c61ab1694d6' } }
    end
    let(:tag_bytes) do
      tags.to_h do |tag, _release|
        [tag, (Ruby4Lich5::PublishedStartupReleases::FILES + ['lib/version.rb']).to_h { |path| [path, File.binread(File.join(pinned, tag, path))] }]
      end
    end

    def blob_id(body)
      Digest::SHA1.hexdigest("blob #{body.bytesize}\0" + body)
    end

    def capture_published(sources)
      blobs = sources.values.flat_map(&:values).to_h { |body| [blob_id(body), body] }
      releases = sources.keys.map { |tag| { 'id' => tags.dig(tag, 'id') || 199, 'draft' => false, 'tag_name' => tag, 'prerelease' => false } }
      commits = sources.keys.to_h { |tag| [tag, tags.dig(tag, 'commit') || ('f' * 40)] }
      request = lambda do |endpoint|
        case endpoint
        when 'releases?per_page=100&page=1' then releases
        when %r{\Acommits/(.+)\z} then { 'sha' => commits.fetch(URI.decode_www_form_component(Regexp.last_match(1))) }
        when %r{\Agit/trees/(\h{40})\?recursive=1\z}
          tree = sources.fetch(commits.key(Regexp.last_match(1))).map { |path, body| { 'path' => path, 'sha' => blob_id(body), 'type' => 'blob', 'mode' => '100644' } }
          { 'truncated' => false, 'tree' => tree }
        when %r{\Agit/blobs/(\h{40})\z} then { 'sha' => Regexp.last_match(1), 'encoding' => 'base64', 'content' => [blobs.fetch(Regexp.last_match(1))].pack('m0') }
        else raise "unexpected endpoint #{endpoint}"
        end
      end
      Ruby4Lich5::PublishedStartupReleases.capture(request: request)
    end

    def identify(inventory)
      described_class.identity(document.fetch('targets').first.fetch('contract'), published_releases: inventory)
    end

    it 'pins byte-exact copies of the published tag blobs' do
      shared = { 'Gemfile' => '1ec438f2ececbc3c770242af8cb4ac6f58182e8d', 'lib/runtime_gem_contract.rb' => '7ea8a5f06979ce77f50b3c601e997d19a2c5a280',
                 'lib/recovery_unit_policy.rb' => 'cbec89a574ad4b0b3aee9c3fd67787a177fa9f40', 'lib/accepted_gem_policy.rb' => '99bb5b9a4dd3a79be9781989f36289d7f7f9de88',
                 'lib/startup_policy_compatibility.rb' => '76e717bdec88cf2df3baa98f3341ec697a5c2608' }
      upstream = {
        'v5.24.0' => shared.merge('lib/dependency_recovery.rb' => '6631dc8ce4e90377a3afa4b4aef17008dfc258b4', 'lib/version.rb' => '3eb3310136251b07175b707f815b4effc986d005'),
        'v5.24.1' => shared.merge('lib/dependency_recovery.rb' => '6ced86ce4d4b4885c949807d4f511831e3e4d928', 'lib/version.rb' => '6b6d82a1f48e77ad15f97f5b77c8653cb0b618d5')
      }
      expect(tag_bytes.transform_values { |files| files.transform_values { |body| blob_id(body) } }).to eq(upstream)
      expect(Dir.children(pinned).sort).to eq(%w[v5.24.0 v5.24.1])
    end

    it 'retains both published releases through their exact pinned sources' do
      inventory = capture_published(tag_bytes)
      expect(inventory.fetch('clients').map { |client| client.values_at('tag', 'commit', 'lich_version') }).to eq(
        [['v5.24.0', tags.dig('v5.24.0', 'commit'), '5.24.0'], ['v5.24.1', tags.dig('v5.24.1', 'commit'), '5.24.1']]
      )
      startup = JSON.parse(File.binread(described_class::CONFIG)).fetch('startup')
      expect(startup.transform_values { |entry| entry.values_at('commit', 'lich_version') }).to eq(
        'v5_24_0' => [tags.dig('v5.24.0', 'commit'), '5.24.0'], 'v5_24_1' => [tags.dig('v5.24.1', 'commit'), '5.24.1']
      )
      policy = identify(inventory)
      expect(policy).not_to have_key('unused_retirements')
      expect(policy.fetch('clients').select { |client| client['id'].start_with?('v5_24_') }.map { |client| client.values_at('id', 'commit', 'groups') }).to eq(
        [['v5_24_0-core', tags.dig('v5.24.0', 'commit'), %w[default profanity]], ['v5_24_0-gtk', tags.dig('v5.24.0', 'commit'), %w[default profanity gtk]],
         ['v5_24_1-core', tags.dig('v5.24.1', 'commit'), %w[default profanity]], ['v5_24_1-gtk', tags.dig('v5.24.1', 'commit'), %w[default profanity gtk]]]
      )
      approved = { 'candidate_sha256' => "sha256:#{Digest::SHA256.hexdigest(JSON.generate(document))}", 'supported_startup_policy' => policy }
      expect(verify(approved)).to eq(Digest::SHA256.hexdigest(JSON.generate(policy)))

      config = JSON.parse(File.binread(described_class::CONFIG)).merge('startup' => {})
      allow(File).to receive(:binread).and_call_original
      allow(File).to receive(:binread).with(described_class::CONFIG).and_return(JSON.generate(config))
      expect { identify(inventory) }.to raise_error(ArgumentError, /published policy client is missing from retention: v5\.24\.0 \(5\.24\.0\)/)
    end

    it 'still requires retention for an unregistered published release carrying the accepted policy' do
      latest = tag_bytes.fetch('v5.24.1')
      unreleased = latest.merge('lib/version.rb' => latest.fetch('lib/version.rb').sub("'5.24.1'", "'5.24.2'"))
      expect { identify(capture_published(tag_bytes.merge('v5.24.2' => unreleased))) }
        .to raise_error(ArgumentError, /published policy client is missing from retention: v5\.24\.2 \(5\.24\.2\)/)
      rebuilt = latest.merge('lib/dependency_recovery.rb' => "#{latest.fetch('lib/dependency_recovery.rb')}# rebuilt\n")
      expect { identify(capture_published(tag_bytes.merge('v5.24.1-rebuilt' => rebuilt))) }
        .to raise_error(ArgumentError, /published policy client is missing from retention: v5\.24\.1-rebuilt \(5\.24\.1\)/)
    end

    context 'when a pinned copy is tampered with' do
      around do |example|
        Dir.mktmpdir do |workspace|
          FileUtils.mkdir_p(File.join(workspace, 'vendor'))
          FileUtils.cp_r(File.join(described_class::ROOT, 'vendor/lich5'), File.join(workspace, 'vendor'))
          FileUtils.cp_r(File.join(described_class::ROOT, 'config'), workspace)
          @workspace = workspace
          example.run
        end
      end

      before do
        stub_const('Ruby4Lich5::SupportedStartupPolicy::ROOT', @workspace)
        stub_const('Ruby4Lich5::SupportedStartupPolicy::CONFIG', File.join(@workspace, 'config/supported-startup-clients.json'))
        stub_const('Ruby4Lich5::SupportedStartupPolicy::SOURCE', File.join(@workspace, 'vendor/lich5/ranged-source.json'))
      end

      it 'rejects a changed pinned implementation or Gemfile before inspection succeeds' do
        inventory = capture_published(tag_bytes)
        expect { identify(inventory) }.not_to raise_error
        implementation = File.join(@workspace, 'vendor/lich5/supported-startup-clients/v5.24.1/lib/dependency_recovery.rb')
        original = File.binread(implementation)
        File.binwrite(implementation, original.gsub("\n", "\r\n"))
        expect { identify(inventory) }.to raise_error(ArgumentError, /implementation differs from pinned revision/)
        File.binwrite(implementation, original)
        expect { identify(inventory) }.not_to raise_error
        File.binwrite(File.join(@workspace, 'vendor/lich5/supported-startup-clients/v5.24.0/Gemfile'), "gem 'other'\n")
        expect { identify(inventory) }.to raise_error(ArgumentError, /invalid supported startup revision/)
      end
    end
  end
end
