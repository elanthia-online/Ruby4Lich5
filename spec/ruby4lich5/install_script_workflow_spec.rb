# frozen_string_literal: true

require 'yaml'

# The install scripts (site/install.sh for macOS and Linux, site/install.ps1
# for Windows) are tested on real runners and published to GitHub Pages
# (https://ruby4lich5.elanthia.online) only from main, only when site/ or the
# workflow changes, and only after every test leg passes.
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
    expect(jobs.fetch('windows').fetch('needs')).to eq('lint')
    expect(publish.fetch('needs')).to contain_exactly('test', 'windows')
    expect(publish.fetch('if')).to include("github.ref == 'refs/heads/main'", "github.event_name != 'pull_request'")
    expect(publish.dig('environment', 'name')).to eq('github-pages')
    expect(publish.dig('concurrency', 'cancel-in-progress')).to be(false)
  end

  it 'publishes exactly the site directory' do
    upload = jobs.fetch('publish').fetch('steps').find { |step| step['uses'].to_s.start_with?('actions/upload-pages-artifact@') }
    expect(upload.dig('with', 'path')).to eq('site')
    expect(File.read(File.join(root, 'site/index.html'))).to include('https://github.com/elanthia-online/Ruby4Lich5')
    expect(File).to exist(File.join(root, 'site/install.sh'))
    expect(File).to exist(File.join(root, 'site/install.ps1'))
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

  it 'tests on Linux (x64 and ARM), macOS and Windows (x64 and ARM)' do
    legs = jobs.dig('test', 'strategy', 'matrix', 'include')
    runners = legs.map { |leg| leg.fetch('runner') }
    expect(runners).to include('ubuntu-26.04', 'ubuntu-26.04-arm', 'ubuntu-24.04', 'ubuntu-22.04', 'macos-26', 'macos-15')
    expect(jobs.dig('windows', 'strategy', 'matrix', 'include').map { |leg| leg.fetch('runner') }.uniq).to contain_exactly('windows-latest', 'windows-11-arm')
    # Homebrew no longer supports Intel macOS, so GTK can't be built there in
    # reasonable time; an Intel leg may only test the GTK-free (--no-gtk) setup.
    intel = legs.select { |leg| leg.fetch('runner').include?('intel') }
    expect(intel.map { |leg| leg['args'] }).to all(eq('--no-gtk'))
  end

  it 'tests both Ruby managers: rv where prebuilt Ruby runs, and the rbenv fallback' do
    legs = jobs.dig('test', 'strategy', 'matrix', 'include')
    expect(legs.map { |leg| leg.fetch('manager') }.uniq).to contain_exactly('rv', 'rbenv')
    rbenv = legs.select { |leg| leg['manager'] == 'rbenv' }
    # glibc older than 2.39: the fallback is automatic.
    expect(rbenv.map { |leg| leg['container'] || leg['runner'] }).to include('ubuntu-22.04', 'debian:12')
    # --use-rbenv keeps the compile path tested on macOS too.
    expect(rbenv.select { |leg| leg['args'].to_s.include?('--use-rbenv') }.map { |leg| leg['runner'] }).to include('macos-26')
  end

  it 'makes an administrator approval a condition of merging the site and anything under .github' do
    admins = %w[@mrhoribu @OSXLich-Doug @MahtraDR]
    rules = File.readlines(File.join(root, '.github/CODEOWNERS'), chomp: true).reject { |line| line.strip.empty? || line.start_with?('#') }
    owners = rules.to_h { |line| [line.split.first, line.split.drop(1)] }
    expect(owners.keys).to contain_exactly('/site/', '/.github/')
    owners.each_value { |names| expect(names).to match_array(admins) }
  end

  it 'tests the Windows install end to end: the ARM manifest opt-in, a rerun and the uninstaller' do
    windows = jobs.fetch('windows')
    legs = windows.dig('strategy', 'matrix', 'include')
    expect(legs.select { |leg| leg['arm_manifest'] }.map { |leg| leg['runner'] }).to eq(['windows-11-arm'])
    # -DevKit installs MSYS2 from scratch: the runner's own C:\msys64 is hidden first.
    expect(legs.select { |leg| leg['devkit'] }.map { |leg| leg['runner'] }).to contain_exactly('windows-latest', 'windows-11-arm')
    # A -RubyDir with a space, with the Lich folder in the DragonRealms spot inside it.
    custom = legs.find { |leg| leg['ruby_dir'] }
    expect(custom['ruby_dir']).to include(' ')
    expect(custom['lich_dir']).to start_with("#{custom['ruby_dir']}\\")
    steps = windows.fetch('steps').map { |step| step['name'] }
    expect(steps).to include('Hide the runner\'s MSYS2 (DevKit leg)', 'Check the DevKit', 'Check Windows integration',
                             'Run again (upgrade path)', 'Uninstall, keeping the Lich folder')
    expect(windows.dig('defaults', 'run', 'shell')).to eq('powershell')
  end

  it 'keeps the piped script LF-only' do
    expect(File.binread(File.join(root, 'site/install.sh'))).not_to include("\r")
    expect(File.read(File.join(root, '.gitattributes'))).to match(%r{^site/\*\* text eol=lf$})
  end
end
