# frozen_string_literal: true

require 'yaml'

RSpec.describe 'Gem publication job preparation' do
  let(:workflow) { YAML.load_file(File.expand_path('../../.github/workflows/ruby4-bundled-gems-suite.yml', __dir__)) }
  let(:job) { workflow.fetch('jobs').fetch('publish_ruby4_bundled_gems_suite') }
  let(:steps) { job.fetch('steps') }

  it 'keeps every Ruby setup action aligned with the publication job' do
    publication_setup = steps.find { |step| step['uses'].to_s.start_with?('ruby/setup-ruby@') }.fetch('uses')
    workflows = Dir[File.expand_path('../../.github/workflows/*.{yaml,yml}', __dir__)]
    setups = workflows.flat_map do |path|
      YAML.load_file(path).fetch('jobs').values.flat_map { |item| item.fetch('steps', []) }
    end.filter_map { |step| step['uses'] if step['uses'].to_s.start_with?('ruby/setup-ruby@') }

    expect(publication_setup).to match(%r{\Aruby/setup-ruby@[0-9a-f]{40}\z})
    expect(setups.uniq).to eq([publication_setup])
  end

  it 'exercises the repository Ruby pin on Windows without bundling or publication' do
    pester = YAML.load_file(File.expand_path('../../.github/workflows/pester_tests.yaml', __dir__))
    smoke = pester.fetch('jobs').fetch('pester')
    smoke_steps = smoke.fetch('steps')
    setup = smoke_steps.index { |step| step['uses'].to_s.start_with?('ruby/setup-ruby@') }
    check = smoke_steps.index { |step| step['name'] == 'Verify pinned Ruby on Windows PowerShell 5.1' }

    expect(smoke.fetch('runs-on')).to eq('windows-latest')
    expect(setup).to be < check
    expect(smoke_steps[setup].fetch('with')).to include('bundler' => 'none', 'bundler-cache' => false)
    expect(smoke_steps[check].fetch('shell')).to eq('powershell')
    expect(smoke_steps[check].fetch('run')).to include('Get-Content .ruby-version', 'print RUBY_VERSION', '$LASTEXITCODE', '$actual -cne $expected')
    %w[push pull_request].each do |event|
      expect(pester.fetch(true).fetch(event).fetch('paths')).to include('.ruby-version', '.github/workflows/pester_tests.yaml')
    end
    expect(pester.fetch('permissions')).to eq('contents' => 'read')
    expect(smoke_steps.map { |step| step['run'] }.join).not_to match(/gh release (create|upload|edit|delete)/)
  end

  it 'checks out source before Ruby setup and artifact downloads, without persisting credentials' do
    workflow = YAML.load_file(File.expand_path('../../.github/workflows/ruby4-bundled-gems-suite.yml', __dir__))
    steps = workflow.fetch('jobs').fetch('publish_ruby4_bundled_gems_suite').fetch('steps')
    checkout = steps.index { |step| step['uses'].to_s.start_with?('actions/checkout@') }

    expect(checkout).not_to be_nil
    expect(steps[checkout].fetch('with').fetch('persist-credentials')).to be(false)
    consumers = steps.each_index.select do |index|
      steps[index]['uses'].to_s.match?(%r{\A(?:ruby/setup-ruby|actions/download-artifact)@})
    end
    expect(consumers).not_to be_empty
    expect(consumers).to all(be > checkout)
  end

  it 'validates every unit before the only release-writing step and scopes its token to that step' do
    validation = steps.index { |step| step['run'].to_s.include?('bin/validate_gem_manifest.rb') }
    writes = steps.each_index.select { |index| steps[index]['run'].to_s.include?('Publish-ImmutableGemCandidate') }
    expect(validation).not_to be_nil
    expect(writes.size).to eq(1)
    expect(writes).to all(be > validation)
    expect(job.fetch('env')).not_to have_key('GH_TOKEN')
    steps.each_with_index do |step, index|
      next if writes.include?(index)

      expect(step.fetch('env', {})).not_to have_key('GH_TOKEN')
      expect(step['run'].to_s).not_to match(/gh release (create|upload|edit|delete)/)
    end
  end

  it 'prepares the exact consumer basename and run-specific native URLs before any upload' do
    preparation = steps.find { |step| step['name'] == 'Prepare candidate assets and manifest' }.fetch('run')
    expect(preparation).to include("'R4L5-gem-manifest.json'", 'candidate-$env:GITHUB_RUN_ID-$env:GITHUB_RUN_ATTEMPT')
    expect(preparation).to include('$manifestPath $tag')
    expect(steps.map { |step| step['run'] }.join).not_to include('--clobber', 'retarget_gem_manifest.rb')
    expect(workflow.fetch(true).keys).to eq(['workflow_dispatch']) # Psych parses YAML 1.1's "on" as true.
  end

  it 'checks accepted installer versions before any gem installation or installer compilation' do
    installer = YAML.load_file(File.expand_path('../../.github/workflows/build-ruby4lich5-installer.yaml', __dir__))
    installer_steps = installer.fetch('jobs').fetch('build_installer').fetch('steps')
    check = installer_steps.index { |step| step['run'].to_s.include?('bin/check_installer_inventory.rb') }
    bake = installer_steps.index { |step| step['name'].start_with?('Bake gems') }
    expect(check).not_to be_nil
    expect(check).to be < bake
  end

  it 'requires an explicit source and keeps Actions acquisition separate from accepted candidates' do
    installer = YAML.load_file(File.expand_path('../../.github/workflows/build-ruby4lich5-installer.yaml', __dir__))
    inputs = installer.fetch(true).fetch('workflow_dispatch').fetch('inputs')
    expect(inputs.fetch('gem-source').fetch('options')).to eq(%w[actions accepted-candidate])
    expect(inputs.fetch('gem-build-run-id').fetch('required')).to be(false)
    installer_steps = installer.fetch('jobs').fetch('build_installer').fetch('steps')
    selection = installer_steps.find { |step| step['name'] == 'Select tested gem artifact' }
    expect(selection.fetch('if')).to include("inputs.gem-source == 'actions'")
    expect(selection.fetch('run')).to include('Assert-GemBuildRun')
    candidate = installer_steps.find { |step| step['name'] == 'Download accepted candidate bundle' }
    expect(candidate.fetch('if')).to include("inputs.gem-source == 'accepted-candidate'")
    expect(candidate.fetch('run')).to include('Resolve-AcceptedGemCandidate', 'Invoke-VerifiedDownload')
    verification = installer_steps.find { |step| step['name'] == 'Verify gem artifact identity and contents' }
    expect(verification.fetch('env', {})).not_to have_key('GH_TOKEN')
    expect(verification.fetch('run')).to include('Read-VerifiedGemBundle', 'Read-AcceptedGemCandidate')
    expect(installer_steps.map { |step| step['run'] }.join).not_to include('gh release download', "gem_source = 'release'")
  end

  it 'uses the shared build-tool selection when preparing the shipped inventory' do
    preparation = workflow.fetch('jobs').values
                          .flat_map { |item| item.fetch('steps', []) }
                          .map { |step| step['run'].to_s }.find { |body| body.include?('$shippedManifest = @(Select-RuntimeGemManifest') }
    expect(preparation).to include('config/runtime-build-tooling.json', 'runtime-build-tooling.ps1', 'Select-RuntimeGemManifest')
    expect(preparation).not_to include("@('rake', 'pkg-config', 'native-package-installer')")
  end

  it 'uses one live manifest for both source routes and rechecks it before provenance' do
    installer = YAML.load_file(File.expand_path('../../.github/workflows/build-ruby4lich5-installer.yaml', __dir__))
    steps = installer.fetch('jobs').fetch('build_installer').fetch('steps')
    read = steps.index { |step| step['name'] == 'Read live accepted manifest for both installer sources' }
    recheck = steps.index { |step| step['name'] == 'Recheck live accepted manifest before finalizing either installer source' }
    provenance = steps.index { |step| step['name'] == 'Record installer provenance' }
    %w[actions accepted-candidate].each do |source|
      selection = steps.index { |step| step['if'].to_s.include?("inputs.gem-source == '#{source}'") }
      expect(read).to be < selection
    end
    expect(steps[read]).not_to have_key('if')
    expect(steps[recheck]).not_to have_key('if')
    expect(steps[read].fetch('run')).to include('Read-LiveAcceptedGemManifest', 'GEM_ACCEPTED_MANIFEST_DIGEST')
    expect(steps[recheck].fetch('run')).to include('-ExpectedDigest $env:GEM_ACCEPTED_MANIFEST_DIGEST')
    inventory = steps.find { |step| step['run'].to_s.include?('bin/check_installer_inventory.rb') }
    expect(inventory.fetch('run')).to include('bin/check_installer_inventory.rb $env:GEM_ACCEPTED_MANIFEST')
    expect(recheck).to be < provenance
    expect(steps[provenance].fetch('run')).to include('accepted_manifest_digest = $env:GEM_ACCEPTED_MANIFEST_DIGEST')
    expect(steps.map { |step| step['run'] }.join).not_to include('GEM_ACCEPTED_MANIFEST=$env:GITHUB_WORKSPACE/manifest/')
  end
end
