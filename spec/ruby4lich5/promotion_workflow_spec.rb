# frozen_string_literal: true

require 'yaml'
require 'open3'
require 'rbconfig'
require 'tmpdir'
require 'json'
require 'digest'
require 'fileutils'

RSpec.describe 'Promotion workflow enforcement' do
  let(:root) { File.expand_path('../..', __dir__) }
  let(:workflow) { YAML.load_file(File.join(root, '.github/workflows/promote-gem-candidate.yml')) }

  it 'permits only manual dispatch and requires both clean consumer jobs before its write job' do
    expect(workflow.fetch(true).keys).to eq(['workflow_dispatch'])
    jobs = workflow.fetch('jobs')
    expect(jobs.fetch('recover').dig('strategy', 'matrix', 'consumer')).to eq(%w[current oldest ranged])
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
    expect(source).to include('Lich::DependencyRecovery.new', 'recovery.recover(names, plan: batch, **startup_options)')
    # The ranged consumer runs its exact Windows startup repair: one deferred transaction.
    expect(source).to include("single_transaction = key == 'ranged'",
                              '{ force: true, restart: true, preserve_newer: true }',
                              'single_transaction: single_transaction',
                              "completed_restarts: pending.fetch('native_restarts')")
    expect(source).not_to include('install_gem:', 'helper_launcher:', 'extract_zip:')
    steps = jobs.fetch('promote').fetch('steps')
    receipts = steps.index { |step| step['run'].to_s.include?('bin/check_recovery_receipts.rb') }
    write = steps.index { |step| step['run'].to_s.include?('Invoke-GemManifestPromotion') }
    expect(receipts).to be < write
  end

  context 'with genesis' do
    let(:jobs) { workflow.fetch('jobs') }
    let(:inputs) { workflow.fetch(true).fetch('workflow_dispatch').fetch('inputs') }
    let(:write_step) { jobs.fetch('promote').fetch('steps').find { |step| step['run'].to_s.include?('Invoke-GemManifestPromotion') } }

    it 'adds explicit opt-in inputs and keeps the modes, job conditions and admin gates' do
      expect(inputs.fetch('genesis')).to include('type' => 'boolean', 'default' => false)
      expect(inputs.fetch('genesis-confirm').fetch('default')).to eq('')
      expect(inputs.fetch('mode').fetch('options')).to eq(%w[inspect promote])
      expect(jobs.fetch('inspect')).not_to have_key('if')
      expect(jobs.fetch('promote').fetch('if')).to eq("${{ inputs.mode == 'promote' }}")
      expect(jobs.keys).to eq(%w[inspect recover promote])
    end

    it 'binds the protection environment to the promote job only for genesis and lets it read approvals' do
      promote = jobs.fetch('promote')
      expect(promote.fetch('environment')).to eq("${{ inputs.genesis && 'r4l5-recovery-promotion' || '' }}")
      expect(promote.fetch('permissions')).to eq('contents' => 'write', 'actions' => 'read')
      expect(jobs.fetch('inspect')).not_to have_key('environment')
      expect(jobs.fetch('recover')).not_to have_key('environment')
    end

    # The environment and approval checks are installer-release.cjs, the code
    # the installer release runs, through the same pinned github-script.
    def genesis_script_step(job, call)
      steps = jobs.fetch(job).fetch('steps')
      index = steps.index { |step| step.dig('with', 'script').to_s.include?(call) }
      step = steps.fetch(index)
      expect(step).to include('if' => '${{ inputs.genesis }}', 'uses' => 'actions/github-script@3a2844b7e9c422d3c10d287c895573f7108da1b3')
      expect(step.fetch('with').keys).to eq(['script'])
      expect(step.dig('with', 'script')).to eq(<<~SCRIPT)
        const {InstallerRelease} = require('./.github/scripts/installer-release.cjs');
        await new InstallerRelease({github, context, core}).#{call};
      SCRIPT
      [index, steps]
    end

    it 'checks the environment and proves the release absent in inspect before any plan exists' do
      check, steps = genesis_script_step('inspect', "environment('r4l5-recovery-promotion')")
      checkout = steps.index { |step| step['uses'].to_s.start_with?('actions/checkout@') }
      acquire_index = steps.index { |step| step['run'].to_s.include?('Prepare-GemPromotion') }
      expect(checkout).to be < check
      expect(check).to be < acquire_index
      expect(steps.fetch(checkout).fetch('with')).to include('persist-credentials' => false)
      acquire = steps.fetch(acquire_index)
      expect(acquire.dig('env', 'GENESIS')).to eq('${{ inputs.genesis }}')
      body = acquire.fetch('run')
      expect(body).to include("$genesis = $env:GENESIS -ceq 'true'", '-CandidateTag $env:CANDIDATE_TAG -Genesis:$genesis')
      plan = jobs.fetch('inspect').fetch('steps').find { |step| step['run'].to_s.include?('bin/prepare_promotion.rb') }
      expect(plan.dig('env', 'GENESIS')).to eq('${{ inputs.genesis }}')
      expect(plan.fetch('run')).to include("if ($env:GENESIS -ceq 'true') { $kind = @('genesis') }",
                                           '& ruby bin/prepare_promotion.rb preparation $env:GITHUB_REPOSITORY $env:PROMOTION_MODE @kind')
    end

    it 'verifies the recorded genesis approval after the receipts and before the only write' do
      approval, steps = genesis_script_step('promote', "approval('r4l5-recovery-promotion')")
      receipts = steps.index { |step| step['run'].to_s.include?('bin/check_recovery_receipts.rb') }
      write = steps.index(write_step)
      expect(receipts).to be < approval
      expect(approval).to eq(write - 1)
      expect(File.read(File.join(root, 'gem-genesis.ps1'))).not_to include('approvals', 'required_reviewers', 'collaborators')
    end

    # The gates are separate steps, so a failed gate stops the write only
    # through Actions' default step semantics: no continue-on-error on a gate
    # or the write, and no write condition that runs after a failed step.
    it 'stops the genesis write when the approval or environment check fails' do
      approval, promote_steps = genesis_script_step('promote', "approval('r4l5-recovery-promotion')")
      check, inspect_steps = genesis_script_step('inspect', "environment('r4l5-recovery-promotion')")
      [promote_steps.fetch(approval), inspect_steps.fetch(check), write_step].each do |step|
        expect(step).not_to have_key('continue-on-error'), step['name']
      end
      expect(write_step.fetch('if', '').to_s).not_to match(/\b(?:always|cancelled|failure)\s*\(/)
    end

    it 'routes genesis plans only to genesis promotion, with the typed confirmation' do
      expect(write_step.dig('env', 'GENESIS')).to eq('${{ inputs.genesis }}')
      expect(write_step.dig('env', 'GENESIS_CONFIRM')).to eq('${{ inputs.genesis-confirm }}')
      body = write_step.fetch('run')
      genesis, ordinary = body.split(/^\s*\} else \{\n/)
      expect(genesis).to include("if ($env:GENESIS -ceq 'true') {", "if ($context.genesis -ne $true -or $context.live_sha256 -cne 'absent') { throw",
                                 '. ./gem-genesis.ps1', '-ExpectedLiveDigest $context.live_sha256')
      expect(genesis).to match(/^\s*Invoke-GemManifestGenesis .* -Confirm \$env:GENESIS_CONFIRM -ReadbackPath preparation\/served-manifest.json$/)
      expect(genesis).not_to include('Invoke-GemManifestPromotion')
      expect(ordinary).to include('if ($null -ne $context.genesis) { throw', 'Invoke-GemManifestPromotion')
      expect(ordinary).not_to include('Invoke-GemManifestGenesis')
      # Both paths follow the published-client recheck and the candidate identity recheck.
      expect(body.index('bin/check_published_clients.rb')).to be < body.index("if ($env:GENESIS -ceq 'true')")
      expect(body.index('Candidate asset identity changed after recovery gate.')).to be < body.index("if ($env:GENESIS -ceq 'true')")
    end

    # Runs the real CLI end to end on a genesis preparation directory (no
    # live/). Only the lock loader, its runtime and smoke contract gates and the
    # supported-client capture are stubbed: they need a real lock and network.
    it 'writes a genesis plan and gate context with live_sha256 absent and no rollback' do
      cli = File.join(root, 'bin/prepare_promotion.rb')
      tag = 'R4L5-gem-bundle-x64-mingw-ucrt-candidate-123-1'
      contract = { 'promotable' => true, 'overrides' => {}, 'lich_version' => '5.25.0', 'recovery_consumer' => { 'commit' => 'f' * 40 } }
      Dir.mktmpdir do |directory|
        manifest = JSON.parse(File.read(File.join(root, 'spec/fixtures/promotion/live-manifest.json')))
        manifest.fetch('targets').first['contract'] = contract
        manifest.fetch('targets').first.fetch('units').each do |unit|
          artifact = unit.fetch('artifact')
          artifact['url'] = "https://github.com/elanthia-online/Ruby4Lich5/releases/download/#{tag}/#{artifact.fetch('filename')}" if artifact.fetch('url').start_with?('https://github.com/')
        end
        bytes = JSON.generate(manifest)
        artifacts = manifest.fetch('targets').first.fetch('units').map { |unit| unit.fetch('artifact') }
        digests = artifacts.select { |artifact| artifact.fetch('url').include?("/#{tag}/") }.to_h { |artifact| [artifact.fetch('filename'), artifact.fetch('sha256')] }
        digests['R4L5-gem-manifest.json'] = "sha256:#{Digest::SHA256.hexdigest(bytes)}"
        assets = digests.map { |name, digest| { 'name' => name, 'digest' => digest } }
        FileUtils.mkdir_p(File.join(directory, 'candidate'))
        FileUtils.mkdir_p(File.join(directory, 'bundle'))
        File.write(File.join(directory, 'candidate/R4L5-gem-manifest.json'), bytes)
        File.write(File.join(directory, 'candidate-release.json'), JSON.generate('tagName' => tag, 'isDraft' => false, 'targetCommitish' => 'a' * 40, 'assets' => assets))
        File.write(File.join(directory, 'bundle/resolution-lock.json'), '{}')
        File.write(File.join(directory, 'bundle/gem-build-metadata.json'), JSON.generate('ruby_archive_digest' => "sha256:#{'d' * 64}"))
        prelude = <<~RUBY
          require 'json'
          lib = File.join(#{root.inspect}, 'lib/ruby4lich5')
          %w[promotion_plan smoke_contract supported_startup_policy].each { |name| require File.join(lib, name) }
          contract = JSON.parse(#{JSON.generate(contract).inspect})
          lock = Struct.new(:contract, :ruby_installer_version).new(contract, '4.0.1-1')
          Ruby4Lich5::ResolutionLock.define_singleton_method(:from_h) { |_data| lock }
          Ruby4Lich5::RuntimeContract.define_singleton_method(:require_promotable!) { |_lock| true }
          Ruby4Lich5::SmokeContract.define_singleton_method(:for_lock) { |_lock| {} }
          Ruby4Lich5::PublishedStartupReleases.define_singleton_method(:capture) { { 'captured' => true } }
          Ruby4Lich5::SupportedStartupPolicy.define_singleton_method(:identity) { |_contract, published_releases:| { 'clients' => ['ranged-core'], 'published_releases' => published_releases } }
          load ARGV.shift
        RUBY
        output, status = Open3.capture2e({ 'GEM_PLATFORM' => 'x64-mingw-ucrt' }, RbConfig.ruby, '-e', prelude, cli, directory, 'elanthia-online/Ruby4Lich5', 'inspect', 'genesis')
        expect(status.success?).to be(true), output
        plan = JSON.parse(File.read(File.join(directory, 'promotion-plan.json')))
        expect(plan).to include('genesis' => true, 'live_sha256' => 'absent', 'candidate_tag' => tag)
        expect(plan).not_to have_key('rollback_sha256')
        context = JSON.parse(File.read(File.join(directory, 'gate-context.json')))
        expect(context).to include('genesis' => true, 'live_sha256' => 'absent', 'change_sha256' => plan.fetch('change_sha256'),
                                   'supported_startup_policy' => { 'clients' => ['ranged-core'], 'published_releases' => { 'captured' => true } })
        expect(Dir.exist?(File.join(directory, 'rollback'))).to be(false)
        expect(Dir.exist?(File.join(directory, 'live'))).to be(false)
      end
    end

    it 'refuses an unknown plan kind and predecessor bytes in a genesis inspection' do
      cli = File.join(root, 'bin/prepare_promotion.rb')
      Dir.mktmpdir do |directory|
        output, status = Open3.capture2e(RbConfig.ruby, cli, directory, 'elanthia-online/Ruby4Lich5', 'inspect', 'predecessor')
        expect(status.success?).to be(false)
        expect(output).to include('optional fourth argument must be genesis')
        FileUtils.mkdir_p(File.join(directory, 'live'))
        File.write(File.join(directory, 'live/R4L5-gem-manifest.json'), '{}')
        output, status = Open3.capture2e(RbConfig.ruby, cli, directory, 'elanthia-online/Ruby4Lich5', 'inspect', 'genesis')
        expect(status.success?).to be(false)
        expect(output).to include('genesis inspection must not hold predecessor bytes')
      end
    end
  end

  it 'sets up Ruby without Bundler before checking out candidate recovery code' do
    steps = workflow.fetch('jobs').fetch('recover').fetch('steps')
    setup = steps.index { |step| step['uses'].to_s.start_with?('ruby/setup-ruby@') }
    checkout = steps.index { |step| step.dig('with', 'path') == 'range-consumer-checkout' }
    seal = steps.index { |step| step['run'].to_s.include?('bin/seal_contract_source.rb') }
    expect(setup).to be < checkout
    expect(checkout).to be < seal
    expect(steps[setup].fetch('if')).to eq(steps[checkout].fetch('if'))
    expect(steps[setup].fetch('with')).to include('bundler-cache' => false, 'bundler' => 'none')
  end

  it 'checks approved supported-client startup before installing recovery packages and binds the receipt' do
    prepare = File.read(File.join(root, 'bin/prepare_promotion.rb'))
    expect(prepare).to include('supported_startup_policy: Ruby4Lich5::SupportedStartupPolicy.identity(lock.contract, published_releases: Ruby4Lich5::PublishedStartupReleases.capture)')
    smoke = File.read(File.join(root, 'bin/recovery_smoke.rb'))
    expect(smoke.index('SupportedStartupPolicy.verify!')).to be < smoke.index('recovery.recover(names, plan: batch, **startup_options)')
    expect(smoke).to include("receipt['supported_startup_policy_sha256'] = policy_digest")
    seal = File.read(File.join(root, 'bin/seal_contract_source.rb'))
    expect(seal).to include('lib/accepted_gem_policy.rb', 'lib/startup_policy_compatibility.rb')
  end

  it 'preserves explicit verified installer sources without reviving the legacy release fallback' do
    installer = YAML.load_file(File.join(root, '.github/workflows/build-ruby4lich5-installer.yaml'))
    inputs = installer.fetch(true).fetch('workflow_dispatch').fetch('inputs')
    expect(inputs.fetch('gem-source').fetch('options')).to eq(%w[actions accepted-candidate])
    expect(inputs.fetch('gem-build-run-id').fetch('required')).to be(false)
    steps = installer.fetch('jobs').fetch('build_installer').fetch('steps')
    guard = steps.index { |step| step['uses'] == './.github/actions/require-admin-dispatch' }
    selection = steps.index { |step| step['name'] == 'Validate explicit gem source' }
    expect(guard).to be < selection
    expect(steps.find { |step| step['name'] == 'Select tested gem artifact' }.fetch('if')).to include("inputs.gem-source == 'actions'")
    expect(steps.find { |step| step['name'] == 'Download accepted candidate bundle' }.fetch('if')).to include("inputs.gem-source == 'accepted-candidate'")
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
    smoke = run_steps.find { |step| step['name'] == 'Verify pinned Ruby on Windows PowerShell 5.1' }
    expect(smoke.fetch('shell')).to eq('powershell')
    matrix_steps = run_steps.reject { |step| step.equal?(smoke) }
    expect(matrix_steps.map { |step| step.fetch('name') }).to contain_exactly('Install Pester 6.0.0', 'Run Pester tests')
    expect(matrix_steps).to all(satisfy { |step| !step.key?('shell') })
  end
end
