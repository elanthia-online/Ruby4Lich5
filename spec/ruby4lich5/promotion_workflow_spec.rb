# frozen_string_literal: true

require 'yaml'

RSpec.describe 'Promotion workflow enforcement' do
  let(:root) { File.expand_path('../..', __dir__) }
  let(:workflow) { YAML.load_file(File.join(root, '.github/workflows/promote-gem-candidate.yml')) }

  it 'permits only manual dispatch and requires both clean consumer jobs before its write job' do
    expect(workflow.fetch(true).keys).to eq(['workflow_dispatch'])
    jobs = workflow.fetch('jobs')
    expect(jobs.fetch('recover').dig('strategy', 'matrix', 'consumer')).to eq(%w[current oldest])
    expect(jobs.fetch('promote').fetch('needs')).to contain_exactly('inspect', 'recover')
    expect(jobs.fetch('promote').fetch('if')).to include("inputs.mode == 'promote'")
    expect(workflow.fetch('concurrency').fetch('cancel-in-progress')).to be(false)
    expect(workflow.fetch('permissions').fetch('contents')).to eq('read')
    expect(jobs.fetch('promote').fetch('permissions').fetch('contents')).to eq('write')
    %w[inspect promote].each do |job|
      guard = jobs.fetch(job).fetch('steps').find { |step| step['uses'] == './.github/actions/require-admin-dispatch' }
      expect(guard.dig('with', 'default-branch-only')).to eq('true')
    end
  end

  it 'runs real recovery in PowerShell 5.1 without a release token and verifies receipts before writing' do
    jobs = workflow.fetch('jobs')
    smoke = jobs.fetch('recover').fetch('steps').find { |step| step['run'].to_s.include?('bin/recovery_smoke.rb') }
    expect(smoke.fetch('shell')).to eq('powershell')
    expect(smoke.fetch('env')).not_to have_key('GH_TOKEN')
    expect(smoke.fetch('run')).to include("'GH_TOKEN'", "'GEM_HOME'", '. ./recovery-receipt.ps1', 'Wait-RecoveryReceipt -ReceiptPath $receipt -TimeoutSeconds 360')
    retention = jobs.fetch('recover').fetch('steps').find { |step| step['name'] == 'Retain exact-candidate recovery result' }
    expect(retention.fetch('if')).to include('always()')
    source = File.read(File.join(root, 'bin/recovery_smoke.rb'))
    expect(source).to include('Lich::DependencyRecovery.new', 'recovery.recover(names, plan: batch)')
    expect(source).not_to include('install_gem:', 'helper_launcher:', 'extract_zip:')
    steps = jobs.fetch('promote').fetch('steps')
    receipts = steps.index { |step| step['run'].to_s.include?('bin/check_recovery_receipts.rb') }
    write = steps.index { |step| step['run'].to_s.include?('Invoke-GemManifestPromotion') }
    expect(receipts).to be < write
  end

  it 'requires the verified installer artifact rather than falling back to a release bundle' do
    installer = YAML.load_file(File.join(root, '.github/workflows/build-ruby4lich5-installer.yaml'))
    expect(installer.fetch(true).dig('workflow_dispatch', 'inputs', 'gem-build-run-id', 'required')).to be(true)
    source = File.read(File.join(root, '.github/workflows/build-ruby4lich5-installer.yaml'))
    expect(source).not_to include('Fetch gem bundle from Release', 'gem-repo:', 'gem-release-tag:')
    expect(source).to include('bin/smoke_runtime.rb')
    factory = File.read(File.join(root, '.github/workflows/ruby4-bundled-gems-suite.yml')).tr('\\', '/')
    expect(factory).to include('bin/smoke_runtime.rb', 'bin/check_smoke_contract.rb', 'Invoke-BundleResolution')
  end

  it 'always reports the three suite gates and includes workflow-only changes' do
    rspec = File.read(File.join(root, '.github/workflows/rspec_tests.yaml'))
    expect(rspec).not_to include("'.github/workflows/**'", "'.github/actions/**'")
    expect(File.read(File.join(root, '.github/workflows/rubocop.yaml'))).to include("path.startsWith('.github/workflows/')")
    pester = YAML.load_file(File.join(root, '.github/workflows/pester_tests.yaml'))
    expect(pester.fetch(true).fetch('pull_request')).to be_nil
    expect(pester.fetch('jobs').fetch('pester').dig('strategy', 'matrix', 'shell')).to eq(%w[powershell pwsh])
    gate = pester.fetch('jobs').fetch('pester_required')
    expect(gate.fetch('if')).to include('always()')
    expect(gate.fetch('needs')).to eq('pester')
    expect(gate.fetch('steps').first.fetch('run')).to include('= success')
  end

  it 'selects the Pester matrix shell in the job defaults supported by GitHub' do
    pester = YAML.load_file(File.join(root, '.github/workflows/pester_tests.yaml')).fetch('jobs').fetch('pester')
    expect(pester.dig('defaults', 'run', 'shell')).to eq('${{ matrix.shell }}')
    run_steps = pester.fetch('steps').select { |step| step.key?('run') }
    expect(run_steps.length).to eq(2)
    expect(run_steps).to all(satisfy { |step| !step.key?('shell') })
  end
end
