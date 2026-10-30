# frozen_string_literal: true

require 'tmpdir'
require 'fileutils'
require 'ruby4lich5/supported_startup_policy'
require_relative '../../vendor/lich5/runtime_gem_contract'

RSpec.describe Ruby4Lich5::SupportedStartupPolicy do
  let(:root) { File.expand_path('../..', __dir__) }
  let(:gemfile) { "gem 'redis', '< 99'\n" }
  let(:version) { '5.23.0' }
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
      'supported_startup_policy' => described_class.identity(document.fetch('targets').first.fetch('contract')) }
  end

  def verify(data = context)
    described_class.verify!(manifest_bytes: JSON.generate(document), context: data, source_directory: @source)
  end

  it 'runs the real source-pinned startup checker for all oldest/current/ranged core and GTK clients in isolation' do
    expect(context.fetch('supported_startup_policy').fetch('clients').map { |client| client.fetch('id') }).to contain_exactly(
      'oldest-core', 'oldest-gtk', 'current-core', 'current-gtk', 'ranged-core', 'ranged-gtk'
    )
    expect(verify).to eq(Digest::SHA256.hexdigest(JSON.generate(context.fetch('supported_startup_policy'))))
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
end
