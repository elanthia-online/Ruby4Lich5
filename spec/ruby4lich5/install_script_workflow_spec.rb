# frozen_string_literal: true

require 'yaml'

# The macOS/Linux install script (site/install.sh) is tested on real runners
# and published to GitHub Pages (https://ruby4lich5.elanthia.online) only
# from main, only when site/ or the workflow changes, and only after every
# test leg passes.
RSpec.describe 'Install script workflow' do
  let(:root) { File.expand_path('../..', __dir__) }
  let(:path) { File.join(root, '.github/workflows/install-script.yml') }
  let(:workflow) { YAML.load_file(path) }
  let(:jobs) { workflow.fetch('jobs') }
  let(:watched) { ['site/**', '.github/workflows/install-script.yml'] }

  it 'runs only when the script, the site or the workflow changes' do
    triggers = workflow.fetch(true)
    expect(triggers.keys).to contain_exactly('pull_request', 'push', 'workflow_dispatch')
    expect(triggers.dig('pull_request', 'paths')).to eq(watched)
    expect(triggers.dig('push', 'paths')).to eq(watched)
    expect(triggers.dig('push', 'branches')).to eq(['main'])
  end

  it 'publishes only from main, only after every test leg passes' do
    publish = jobs.fetch('publish')
    expect(jobs.fetch('test').fetch('needs')).to eq('lint')
    expect(publish.fetch('needs')).to eq('test')
    expect(publish.fetch('if')).to include("github.ref == 'refs/heads/main'", "github.event_name != 'pull_request'")
    expect(publish.dig('environment', 'name')).to eq('github-pages')
    expect(publish.dig('concurrency', 'cancel-in-progress')).to be(false)
  end

  it 'publishes exactly the site directory' do
    upload = jobs.fetch('publish').fetch('steps').find { |step| step['uses'].to_s.start_with?('actions/upload-pages-artifact@') }
    expect(upload.dig('with', 'path')).to eq('site')
    expect(File.read(File.join(root, 'site/index.html'))).to include('https://github.com/elanthia-online/Ruby4Lich5')
    expect(File).to exist(File.join(root, 'site/install.sh'))
  end

  it 'requires an administrator on the default branch for a manual publish' do
    guard = jobs.fetch('publish').fetch('steps').find { |step| step['uses'] == './.github/actions/require-admin-dispatch' }
    expect(guard).to include('if' => "${{ github.event_name == 'workflow_dispatch' }}", 'with' => { 'default-branch-only' => 'true' })
  end

  it 'reads the repository only, and gives only the publish job Pages access' do
    expect(workflow.fetch('permissions')).to eq('contents' => 'read')
    expect(jobs.fetch('publish').fetch('permissions')).to eq('pages' => 'write', 'id-token' => 'write')
    jobs.except('publish').each { |id, job| expect(job).not_to have_key('permissions'), id }
  end

  it 'pins every external action to a full commit SHA and checks out without credentials' do
    steps = jobs.values.flat_map { |job| job.fetch('steps') }
    steps.filter_map { |step| step['uses'] }.reject { |uses| uses.start_with?('./') }.each do |uses|
      expect(uses).to match(%r{\A[\w.-]+/[\w.-]+@[0-9a-f]{40}\z}), uses
    end
    steps.select { |step| step['uses'].to_s.start_with?('actions/checkout@') }.each do |step|
      expect(step.dig('with', 'persist-credentials')).to be(false)
    end
  end

  it 'tests on Linux (x64 and ARM) and Apple Silicon macOS' do
    runners = jobs.dig('test', 'strategy', 'matrix', 'include').map { |leg| leg.fetch('runner') }
    expect(runners).to include('ubuntu-26.04', 'ubuntu-26.04-arm', 'ubuntu-24.04', 'ubuntu-22.04', 'macos-26', 'macos-15')
    # Homebrew no longer supports Intel macOS; a leg there would hold every publish for hours.
    expect(runners.grep(/intel/)).to be_empty
  end

  it 'keeps the piped script LF-only' do
    expect(File.binread(File.join(root, 'site/install.sh'))).not_to include("\r")
    expect(File.read(File.join(root, '.gitattributes'))).to match(%r{^site/\*\* text eol=lf$})
  end
end
