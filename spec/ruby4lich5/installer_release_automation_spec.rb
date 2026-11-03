# frozen_string_literal: true

require 'yaml'
require 'open3'
require 'json'
require_relative '../../vendor/lich5/runtime_gem_contract'

RSpec.describe 'Installer release automation' do
  let(:root) { File.expand_path('../..', __dir__) }
  let(:workflow) { YAML.load_file(File.join(root, '.github/workflows/release-installer.yml')) }

  it 'executes the release state machine and adversarial API/byte probes without network access' do
    files = Dir.glob(File.join(root, 'spec/javascript/*.test.cjs')).sort
    output, status = Open3.capture2e('node', '--test', *files)
    expect(status.success?).to be(true), output
  end

  it 'shares canonical contract hashes with the actual Ruby consumer for supported values' do
    documents = [{ 'schema' => 2, 'roots' => { 'sequel' => ['>= 1'] }, 'inventory' => [{ 'version' => '1.0', 'bundled' => false }] },
                 { 'schema' => 1, 'empty' => {}, 'nothing' => nil, 'text' => [0xe9].pack('U'), 'integer' => 9_007_199_254_740_991 }]
    script = "const {canonical, digest} = require('./.github/scripts/release-common.cjs'); " \
             "const fs = require('node:fs'); process.stdout.write(JSON.stringify(JSON.parse(fs.readFileSync(0, 'utf8')).map(value => digest(Buffer.from(canonical(value))))));"
    output, status = Open3.capture2e('node', '-e', script, stdin_data: JSON.generate(documents), chdir: root)
    expect(status.success?).to be(true), output
    expect(JSON.parse(output)).to eq(documents.map { |document| Lich::RuntimeGemContract.digest(document) })
  end

  it 'requires separate protected approvals for recovery and Latest and never runs on external events' do
    expect(workflow.fetch(true).keys).to eq(['workflow_dispatch'])
    jobs = workflow.fetch('jobs')
    expect(jobs.fetch('promote_and_build').fetch('needs')).to eq('prepare')
    expect(jobs.fetch('promote_and_build').fetch('environment')).to eq('r4l5-recovery-promotion')
    expect(jobs.fetch('publish_latest').fetch('needs')).to eq('promote_and_build')
    expect(jobs.fetch('publish_latest').fetch('environment')).to eq('r4l5-installer-latest')
    publication = jobs.fetch('publish_latest')
    expect(publication.fetch('timeout-minutes')).to eq(20)
    script = publication.fetch('steps').find { |step| step.fetch('name', '') == 'Publish only approved unchanged bytes and verify Latest' }
    expect(script.fetch('timeout-minutes')).to eq(17)
    receipt = publication.fetch('steps').find { |step| step.dig('with', 'name') == 'published-installer-receipt' }
    expect(receipt.fetch('if')).to include('always()')
    expect(receipt.dig('with', 'path')).to include('publication-status.json')
    expect(workflow.dig('concurrency', 'cancel-in-progress')).to be(false)
    jobs.each_value do |job|
      expect(job.fetch('steps')).to include(hash_including('uses' => './.github/actions/require-admin-dispatch', 'with' => { 'default-branch-only' => 'true' }))
    end
  end

  it 'assembles a draft only after successful installer output, outside the native execution job' do
    installer = YAML.load_file(File.join(root, '.github/workflows/build-ruby4lich5-installer.yaml'))
    job = installer.fetch('jobs').fetch('draft_release')
    expect(job.fetch('needs')).to eq('build_installer')
    expect(job.fetch('if')).to include('github.event.repository.default_branch')
    expect(job.fetch('permissions')).to include('contents' => 'write')
    expect(installer.fetch('permissions')).to include('contents' => 'read')
    expect(job.fetch('steps')).to include(hash_including('with' => hash_including('name' => 'ruby4lich5-installer', 'digest-mismatch' => 'error')))
    expect(job.fetch('concurrency')).to eq(workflow.dig('jobs', 'publish_latest', 'concurrency'))
    expect(installer.dig('jobs', 'build_installer', 'needs')).to eq('preflight_version')
    version = installer.fetch(true).dig('workflow_dispatch', 'inputs', 'installer-version')
    expect(version.fetch('required')).to be(true)
    expect(version).not_to have_key('default')
  end

  it 'correlates child dispatches without weakening the completed manual factory run guard' do
    %w[ruby4-bundled-gems-suite.yml promote-gem-candidate.yml build-ruby4lich5-installer.yaml].each do |name|
      child = YAML.load_file(File.join(root, '.github/workflows', name))
      expect(child.fetch('run-name')).to include('inputs.release-request')
      expect(child.fetch(true).keys).to eq(['workflow_dispatch'])
    end
    guard = File.read(File.join(root, 'gem-bundle-artifact.ps1'))
    expect(guard).to include("$Run.path -ne '.github/workflows/ruby4-bundled-gems-suite.yml'", "$Run.status -ne 'completed'", "$Run.conclusion -ne 'success'")
  end
end
