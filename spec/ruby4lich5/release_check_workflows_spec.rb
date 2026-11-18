# frozen_string_literal: true

require 'yaml'

# The two release checks the manual release runbook (docs/RELEASING.md) runs:
# manual, administrator-only, read-only, and with no token in any step that
# runs downloaded or installed code.
RSpec.describe 'Release check workflows' do
  let(:root) { File.expand_path('../..', __dir__) }
  let(:checks) do
    {
      'release-check-older-ruby.yml'           => { inputs: %w[candidate-tag candidate-sha256 lich5-commit], permissions: { 'contents' => 'read' } },
      'release-check-installer-acceptance.yml' => { inputs: %w[installer-run-id installer-sha256 lich5-refs], permissions: { 'contents' => 'read', 'actions' => 'read' } }
    }
  end

  def load(name)
    YAML.load_file(File.join(root, '.github/workflows', name))
  end

  def steps(workflow)
    workflow.fetch('jobs').values.flat_map { |job| job.fetch('steps') }
  end

  it 'accepts only an administrator dispatch from the default branch, in every job' do
    checks.each do |name, expected|
      workflow = load(name)
      expect(workflow.fetch(true).keys).to eq(['workflow_dispatch']), name
      expect(workflow.dig(true, 'workflow_dispatch', 'inputs').keys).to eq(expected.fetch(:inputs)), name
      workflow.fetch('jobs').each do |id, job|
        first, second = job.fetch('steps')
        expect(first.fetch('uses')).to start_with('actions/checkout@'), "#{name}:#{id}"
        expect(first.dig('with', 'persist-credentials')).to be(false), "#{name}:#{id}"
        expect(second).to eq('uses' => './.github/actions/require-admin-dispatch', 'with' => { 'default-branch-only' => 'true' }), "#{name}:#{id}"
      end
    end
  end

  it 'grants only read permissions, at the workflow level' do
    checks.each do |name, expected|
      workflow = load(name)
      expect(workflow.fetch('permissions')).to eq(expected.fetch(:permissions)), name
      workflow.fetch('jobs').each { |id, job| expect(job).not_to have_key('permissions'), "#{name}:#{id}" }
      expect(File.read(File.join(root, '.github/workflows', name))).not_to match(/:\s*write\b/), name
    end
  end

  it 'pins every external action to a full commit SHA and checks out other repositories without credentials' do
    checks.each_key do |name|
      steps(load(name)).filter_map { |step| step['uses'] }.reject { |uses| uses.start_with?('./') }.each do |uses|
        expect(uses).to match(%r{\A[\w.-]+/[\w.-]+@[0-9a-f]{40}\z}), "#{name}: #{uses}"
      end
      steps(load(name)).select { |step| step['uses'].to_s.start_with?('actions/checkout@') }.each do |step|
        expect(step.dig('with', 'persist-credentials')).to be(false), name
      end
    end
  end

  it 'reads dispatch inputs into run scripts only through the environment' do
    checks.each_key do |name|
      steps(load(name)).each do |step|
        expect("#{step['run']}#{step.dig('with', 'script')}").not_to include('${{'), "#{name}: #{step['name']}"
      end
    end
  end

  it 'runs the installer, RubyInstaller and Lich in steps that hold no token' do
    checks.each_key do |name|
      runners = steps(load(name)).select do |step|
        step['run'].to_s.match?(/lich_startup_probe\.rb|drive_installer\.ps1|OLDER_RUBY|7z x/)
      end
      expect(runners).not_to be_empty, name
      runners.each do |step|
        expect(step.fetch('env', {}).values.join(' ')).not_to match(/token|secrets\./i), "#{name}: #{step['name']}"
        expect(step['run']).not_to match(/GH_TOKEN|GITHUB_TOKEN|\bgh\s/), "#{name}: #{step['name']}"
      end
    end
  end

  it 'uses the shared release-check scripts, which exist' do
    sources = checks.keys.map { |name| File.read(File.join(root, '.github/workflows', name)) }
    expect(sources).to all(include('.github/scripts/lich_startup_probe.rb'))
    expect(sources.last).to include('.github/scripts/drive_installer.ps1')
    %w[lich_startup_probe.rb drive_installer.ps1].each { |file| expect(File).to exist(File.join(root, '.github/scripts', file)) }
  end

  it 'pins every startup and relaunch manifest read in the older-Ruby check to the inspected candidate digest' do
    workflow = load('release-check-older-ruby.yml')
    probe = steps(workflow).find { |step| step['run'].to_s.include?('lich_startup_probe.rb') }
    expect(probe.fetch('env')).to include('R4L5_EXPECTED_MANIFEST_SHA256' => '${{ inputs.candidate-sha256 }}')
    expect(probe.fetch('run')).to include('$result.manifest_sha256 -cne $env:R4L5_EXPECTED_MANIFEST_SHA256')
    control = steps(workflow).find { |step| step['name'].to_s.start_with?('Control') }
    expect(control.fetch('env')).to include('CANDIDATE_SHA256' => '${{ inputs.candidate-sha256 }}')
    expect(control.fetch('run')).to include('ManifestDigestPin.install!', '$env:CANDIDATE_SHA256 .github/scripts/manifest_digest_pin.rb')
    source = File.read(File.join(root, '.github/scripts/lich_startup_probe.rb'))
    expect(source).to include("require_relative 'manifest_digest_pin'", 'ManifestDigestPin.install!(Lich::DependencyRecovery',
                              "record['manifest_sha256'] == expected_manifest")
  end

  describe 'ManifestDigestPin' do
    let(:expected) { "sha256:#{Digest::SHA256.hexdigest('good')}" }
    let(:url) { 'https://example.invalid/R4L5-gem-manifest.json' }
    let(:recovery) do
      Class.new do
        attr_writer :bytes

        def initialize(manifest_url)
          @manifest_url = manifest_url
          @bytes = 'good'
        end

        def load_manifest = fetch(@manifest_url)
        def read(other) = fetch(other)

        private

        def fetch(_url) = @bytes
      end
    end

    before do
      require 'digest'
      require File.join(root, '.github/scripts/manifest_digest_pin.rb')
    end

    it 'passes the expected manifest bytes through and reports the verified digest' do
      seen = []
      ManifestDigestPin.install!(recovery, expected, on_verified: ->(digest) { seen << digest })
      expect(recovery.new(url).load_manifest).to eq('good')
      expect(seen).to eq([expected])
      expect(recovery.private_method_defined?(:fetch)).to be(true)
    end

    it 'refuses manifest bytes that differ from the expected digest' do
      ManifestDigestPin.install!(recovery, expected)
      instance = recovery.new(url)
      instance.bytes = 'changed'
      expect { instance.load_manifest }.to raise_error(RuntimeError, /not the expected #{expected}/)
    end

    it 'leaves reads of other URLs alone' do
      ManifestDigestPin.install!(recovery, expected)
      instance = recovery.new(url)
      instance.bytes = 'artifact'
      expect(instance.read('https://example.invalid/other.zip')).to eq('artifact')
    end

    it 'fails closed on a malformed digest or a recovery class without a private fetch' do
      expect { ManifestDigestPin.install!(recovery, 'sha256:abc') }.to raise_error(ArgumentError, /64 lowercase hex/)
      expect { ManifestDigestPin.install!(Class.new, expected) }.to raise_error(ArgumentError, /no private fetch/)
    end
  end

  it 'reads the older RubyInstaller from the reviewed floor baseline, not a hardcoded version' do
    source = File.read(File.join(root, '.github/workflows/release-check-older-ruby.yml'))
    expect(source).to include('config/ruby-floor-baseline.json', 'Invoke-VerifiedDownload')
    expect(source).not_to match(/rubyinstaller-\d|RubyInstaller-\d/)
  end
end
