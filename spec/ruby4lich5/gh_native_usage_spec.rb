# frozen_string_literal: true

require 'yaml'

# Windows PowerShell 5.1 under Actions' $ErrorActionPreference = 'Stop' turns a
# redirected native stderr line into a terminating error before the exit code
# can be read. gh-native.ps1's Invoke-GhNative is the one place gh's stderr is
# redirected; every other call site must go through it.
RSpec.describe 'gh native invocation' do
  root = File.expand_path('../..', __dir__)

  # Logical PowerShell lines that run gh (or gh.exe) with stderr redirected
  # (2> or *>), as [first physical line number, text]. Backtick continuations
  # are joined first; quoted strings and comments are blanked, so a message
  # like "gh release list -> ok" is not a call. Not caught: a gh call built
  # inside a string (Invoke-Expression, & "gh"), one called by full path
  # (C:\...\gh.exe) or through a variable, and redirects split from the call
  # by a here-string or script block.
  def self.raw_gh_redirects(text)
    logical = []
    text.each_line.with_index(1) do |line, number|
      if logical.last&.last&.end_with?("`\n")
        logical.last[1] = logical.last.last.delete_suffix("`\n") + line
      else
        logical << [number, line]
      end
    end
    logical.filter_map do |number, line|
      code = line.gsub(/"(?:[^"`]|`.)*"|'[^']*'/m, "''").sub(/(?<!<)#.*/, '')
      [number, line.strip] if code.match?(/(?<![\w.$\\\/-])gh(?:\.exe)?(?=\s)/) && code.match?(/(?<![\w-])[2*]>/)
    end
  end

  # Every PowerShell run block in the workflows and composite actions, as
  # [label, text]. A step counts unless its shell (step, job or workflow
  # default) is named and is not powershell/pwsh, so a step with no shell
  # (pwsh on a Windows runner) or a matrix expression is scanned too.
  def self.powershell_blocks(root)
    Dir[File.join(root, '.github/{workflows,actions}/**/*.{yml,yaml}')].flat_map do |path|
      document = YAML.load_file(path)
      label = path.delete_prefix("#{root}/")
      default = document.dig('defaults', 'run', 'shell')
      groups = document.key?('jobs') ? document.fetch('jobs').values.map { |job| [job.dig('defaults', 'run', 'shell') || default, job.fetch('steps', [])] } : [[default, document.dig('runs', 'steps') || []]]
      groups.flat_map do |shell, steps|
        steps.filter_map do |step|
          chosen = (step['shell'] || shell).to_s
          next unless step['run'] && (chosen.empty? || chosen.include?('${{') || chosen.match?(/\A(?:powershell|pwsh)\b/))

          ["#{label} (#{step['name'] || step['run'].lines.first.strip})", step['run']]
        end
      end
    end
  end

  it 'flags only raw gh calls with redirected stderr' do
    flagged = [
      "$out = gh api repos/x 2>&1\n", "$out = gh.exe release view t 2>&1\n", "& gh.exe api repos/x 2>$null\n",
      "gh release list *> out.txt\n", "$out = gh api `\n  repos/x `\n  2>&1\n", "gh api repos/x 2>&1 # why\n"
    ]
    clean = [
      "Write-Host \"gh release list -> ok\"\n", "Write-Host 'gh api 2>&1 is not allowed'\n", "# gh api repos/x 2>&1\n",
      "$api = Invoke-GhNative -Arguments @('api', 'repos/x')\n", "gh api repos/x > out.json\n", "$sigh = foo 2>&1\n",
      "$out = gh api `\n  repos/x\nfoo 2>&1\n"
    ]
    flagged.each { |text| expect(self.class.raw_gh_redirects(text)).not_to be_empty, text }
    clean.each { |text| expect(self.class.raw_gh_redirects(text)).to be_empty, text }
    expect(self.class.raw_gh_redirects("a\n$out = gh api `\n  2>&1\n").map(&:first)).to eq([2])
  end

  it 'redirects gh stderr nowhere outside gh-native.ps1' do
    blocks = self.class.powershell_blocks(root)
    scripts = Dir[File.join(root, '*.ps1')] - [File.join(root, 'gh-native.ps1')]
    expect(blocks.length).to be >= 60
    expect(scripts.length).to be >= 10
    blocks += scripts.map { |path| [path.delete_prefix("#{root}/"), File.read(path)] }
    offenders = blocks.flat_map do |label, text|
      self.class.raw_gh_redirects(text).map { |number, line| "#{label}:#{number}: #{line}" }
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
