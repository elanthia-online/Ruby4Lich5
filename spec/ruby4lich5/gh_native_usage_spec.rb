# frozen_string_literal: true

require 'yaml'

# Windows PowerShell 5.1 under Actions' $ErrorActionPreference = 'Stop' turns a
# redirected native stderr line into a terminating error before the exit code
# can be read. gh-native.ps1's Invoke-GhNative is the one place gh's stderr is
# redirected; every other call site must go through it.
RSpec.describe 'gh native invocation' do
  root = File.expand_path('../..', __dir__)

  def self.code_lines(path)
    File.readlines(path).each_with_index.reject { |line, _| line.lstrip.start_with?('#') }
  end

  it 'redirects gh stderr nowhere outside gh-native.ps1' do
    files = Dir[File.join(root, '.github/{workflows,actions}/**/*.{yml,yaml}')] + Dir[File.join(root, '*.ps1')]
    files -= [File.join(root, 'gh-native.ps1')]
    offenders = files.flat_map do |path|
      self.class.code_lines(path).filter_map do |line, index|
        "#{path.delete_prefix("#{root}/")}:#{index + 1}" if line.match?(/(?<![\w-])gh\s[^#]*(?:\d?>|\*>)/)
      end
    end
    expect(offenders).to be_empty
  end

  it 'routes the released range capability lookup through the shared wrapper and fails closed on its exit code' do
    workflow = YAML.load_file(File.join(root, '.github/workflows/promote-gem-candidate.yml'))
    step = workflow.fetch('jobs').values.flat_map { |job| job.fetch('steps', []) }.find { |item| item['name'] == 'Select released range capability' }
    run = step.fetch('run')
    expect(step.fetch('shell')).to eq('powershell')
    expect(run).to include(". (Join-Path $env:GITHUB_WORKSPACE 'gh-native.ps1')")
    expect(run).to match(/\$api = Invoke-GhNative -Arguments @\('api', "repos\/elanthia-online\/lich-5\/releases\/tags\/\$\(\$reader\.release\)"\)/)
    expect(run).to match(/if \(\$api\.ExitCode -ne 0\) \{ throw /)
    expect(run).not_to match(/^\s*\$\w+ = gh /)
  end

  # A sparse checkout fetches only what it lists, so a job that dot-sources
  # gh-native.ps1 (directly, or through a root script that does) must check
  # out the whole repository or list the helper.
  it 'fetches gh-native.ps1 in every job that dot-sources it' do
    loaders = Dir[File.join(root, '*.ps1')].select { |path| File.read(path).include?("'gh-native.ps1'") }.map { |path| File.basename(path) }
    expect(loaders).to include('gem-genesis.ps1', 'gem-manifest-promotion.ps1')
    jobs = Dir[File.join(root, '.github/workflows/*.{yml,yaml}')].flat_map do |path|
      YAML.load_file(path).fetch('jobs').map { |name, job| ["#{File.basename(path)}:#{name}", job.fetch('steps', [])] }
    end
    users = jobs.select do |_name, steps|
      steps.any? { |step| step['run'].to_s.match?(/(?:^|[\s(])\.\s.*(?:gh-native|#{loaders.map { |file| Regexp.escape(file.delete_suffix('.ps1')) }.join('|')})\.ps1/) }
    end
    expect(users.length).to be >= 6
    users.each do |name, steps|
      checkouts = steps.select { |step| step['uses'].to_s.start_with?('actions/checkout@') && !step.dig('with', 'path') }
      expect(checkouts).not_to be_empty, "#{name} dot-sources gh-native.ps1 without a checkout"
      checkouts.each do |checkout|
        sparse = checkout.dig('with', 'sparse-checkout')
        expect(sparse.nil? || sparse.split("\n").map(&:strip).include?('gh-native.ps1')).to be(true), "#{name} sparse checkout lacks gh-native.ps1"
      end
    end
  end

  it 'dot-sources the wrapper in every workflow step that calls it' do
    steps = Dir[File.join(root, '.github/workflows/*.{yml,yaml}')].flat_map do |path|
      YAML.load_file(path).fetch('jobs').values.flat_map { |job| job.fetch('steps', []) }
    end
    callers = steps.select { |step| step['run'].to_s.include?('Invoke-GhNative') }
    expect(callers.length).to be >= 8
    callers.each { |step| expect(step.fetch('run')).to include(". (Join-Path $env:GITHUB_WORKSPACE 'gh-native.ps1')"), step['name'] }
  end
end
