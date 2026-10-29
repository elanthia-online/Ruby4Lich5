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
end
