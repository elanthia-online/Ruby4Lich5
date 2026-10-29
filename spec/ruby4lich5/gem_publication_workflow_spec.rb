# frozen_string_literal: true

require 'yaml'

RSpec.describe 'Gem publication job preparation' do
  let(:workflow) { YAML.load_file(File.expand_path('../../.github/workflows/ruby4-bundled-gems-suite.yml', __dir__)) }
  let(:job) { workflow.fetch('jobs').fetch('publish_ruby4_bundled_gems_suite') }
  let(:steps) { job.fetch('steps') }

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
    guard = steps.index { |step| step['uses'] == './.github/actions/require-admin-dispatch' }
    expect(guard).not_to be_nil
    expect(guard).to be < validation
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
    bake = installer_steps.index { |step| step['name'].to_s.start_with?('Bake gems') }
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
end
