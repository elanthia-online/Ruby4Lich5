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

  it 'reads the older RubyInstaller from the reviewed floor baseline, not a hardcoded version' do
    source = File.read(File.join(root, '.github/workflows/release-check-older-ruby.yml'))
    expect(source).to include('config/ruby-floor-baseline.json', 'Invoke-VerifiedDownload')
    expect(source).not_to match(/rubyinstaller-\d|RubyInstaller-\d/)
  end
end
