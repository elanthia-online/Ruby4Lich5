# frozen_string_literal: true

require 'ruby4lich5/promotion_plan'
require 'ruby4lich5/recovery_receipts'
require 'open3'
require 'tmpdir'

RSpec.describe Ruby4Lich5::PromotionPlan do
  # Frozen pre-contract predecessor: the candidate below retargets every GitHub
  # artifact to one candidate tag, which assumes one digest per artifact
  # filename. A promoted manifest may legitimately mix the production and
  # candidate bundle ZIPs under the same filename, so it cannot serve here.
  let(:live) { JSON.parse(File.read(File.expand_path('../fixtures/promotion/live-manifest.json', __dir__))) }
  let(:candidate) do
    JSON.parse(JSON.generate(live)).tap do |document|
      document.fetch('targets').first.fetch('units').each do |unit|
        artifact = unit.fetch('artifact')
        next unless artifact.fetch('url').start_with?('https://github.com/')

        artifact['url'] = "https://github.com/elanthia-online/Ruby4Lich5/releases/download/#{tag}/#{artifact.fetch('filename')}"
      end
    end
  end
  let(:tag) { 'R4L5-gem-bundle-x64-mingw-ucrt-candidate-123-1' }
  let(:assets) do
    units = candidate.fetch('targets').first.fetch('units').select { |unit| unit.dig('artifact', 'url').include?("/#{tag}/") }
    map = units.to_h { |unit| [unit.dig('artifact', 'filename'), unit.dig('artifact', 'sha256')] }
    map['R4L5-gem-manifest.json'] = described_class.digest(JSON.generate(candidate))
    map.map { |name, digest| { 'name' => name, 'digest' => digest } }
  end

  def build_plan
    described_class.build(candidate_bytes: JSON.generate(candidate), live_bytes: JSON.generate(live), candidate_tag: tag,
                          repository: 'elanthia-online/Ruby4Lich5', assets: assets, source_sha: 'a' * 40)
  end

  it 'records routing and ordering changes and binds approval to both exact byte streams' do
    candidate.fetch('targets').first.fetch('units').reverse!
    plan = build_plan
    expect(plan.fetch('changes').first.fetch('after')).to eq(candidate.fetch('targets').first.fetch('units'))
    expect(plan.fetch('change_sha256')).to match(/\Asha256:[0-9a-f]{64}\z/)
    expect do
      described_class.approve!(plan, candidate_digest: plan['candidate_sha256'], live_digest: plan['live_sha256'], change_digest: plan['change_sha256'])
    end.not_to raise_error
    expect do
      described_class.approve!(plan, candidate_digest: plan['candidate_sha256'], live_digest: "sha256:#{'b' * 64}", change_digest: plan['change_sha256'])
    end.to raise_error(ArgumentError, /exact candidate/)
  end

  it 'adds no package policy summary when no minimum or self_build_equivalent changed' do
    expect(build_plan).not_to have_key('package_policy_changes')
  end

  it 'summarizes a self_build_equivalent or minimum change per package' do
    packages = candidate.fetch('targets').first.fetch('units').flat_map { |unit| unit.fetch('packages') }
    packages.select { |package| package['name'] == 'ox' }.each { |package| package['self_build_equivalent'] = true }
    packages.select { |package| package['name'] == 'concurrent-ruby' }.each { |package| package['minimum'] = '1.3.0' }
    plan = build_plan
    expect(plan.fetch('package_policy_changes')).to eq(
      '4.0/x64-mingw-ucrt' => { 'concurrent-ruby' => { 'before' => {}, 'after' => { 'minimum' => '1.3.0' } },
                                'ox'              => { 'before' => {}, 'after' => { 'self_build_equivalent' => true } } }
    )
    expect(plan.fetch('changes').first.fetch('after')).to eq(candidate.fetch('targets').first.fetch('units'))
  end

  # A flagged ox has been promoted. Each transition below makes ox
  # ineligible for the flag on new bytes; none may strand the accepted live.
  context 'when a flagged package already live stops being eligible' do
    let(:seed) { JSON.parse(File.read(File.expand_path('../../config/curated-gems.json', __dir__))) }

    def ox_packages(document)
      document.fetch('targets').first.fetch('units').flat_map { |unit| unit.fetch('packages') }.select { |package| package['name'] == 'ox' }
    end

    def flag_ox!(document)
      ox_packages(document).each { |package| package['self_build_equivalent'] = true }
    end

    def stub_registry!(&change)
      change.call(seed.fetch('gems').fetch('ox'))
      allow(Ruby4Lich5::KnownNativeGems).to receive(:registry).and_return(Ruby4Lich5::CuratedGemRegistry.new(seed))
    end

    transitions = {
      'a curated patch lands under patches/ox'                        => lambda { |example|
        example.allow(Ruby4Lich5::PackagePolicy).to example.receive(:default_patched).and_return(->(name) { name == 'ox' })
      },
      'ox is reclassified as an upstream pass-through on this target' => lambda { |example|
        example.stub_registry! { |entry| entry['targets']['x64-mingw-ucrt']['4.0'] = { 'expected_classification' => 'native_pass_through' } }
      },
      'ox loses its repack build_role'                                => lambda { |example|
        example.stub_registry! { |entry| entry.delete('build_role') }
      }
    }

    transitions.each do |transition, apply|
      context "after #{transition}" do
        before do
          candidate # derived from the unflagged live
          flag_ox!(live)
          apply.call(self)
        end

        it 'refuses the flag on a candidate that newly adds it, proving the transition makes ox ineligible' do
          live.fetch('targets').first.fetch('units').each { |unit| unit.fetch('packages').each { |package| package.delete('self_build_equivalent') } }
          flag_ox!(candidate)
          expect { build_plan }.to raise_error(Ruby4Lich5::PackagePolicy::Error, /ox self_build_equivalent requires an unpatched repack package/)
        end

        it 'promotes an unflagged replacement over the flagged live, and validates the rollback' do
          plan = build_plan
          expect(plan.fetch('package_policy_changes')).to eq('4.0/x64-mingw-ucrt' => { 'ox' => { 'before' => { 'self_build_equivalent' => true }, 'after' => {} } })
          expect(plan.fetch('rollback_sha256')).to eq(plan.fetch('live_sha256'))
        end

        it 'keeps the flag on the exact accepted bytes when the candidate still serves them' do
          flag_ox!(candidate)
          expect(build_plan).not_to have_key('package_policy_changes')
        end

        it 'refuses a rebuilt artifact that still carries the flag' do
          flag_ox!(candidate)
          unit = candidate.fetch('targets').first.fetch('units').find { |item| item['id'] == 'ox' }
          rebuilt = "sha256:#{'c' * 64}"
          unit.fetch('packages').first['sha256'] = rebuilt
          unit['artifact'] = unit.fetch('artifact').merge('sha256' => rebuilt)
          expect { build_plan }.to raise_error(Ruby4Lich5::PackagePolicy::Error, /ox self_build_equivalent requires an unpatched repack package/)
        end
      end
    end

    context 'with copies LifecyclePolicy retains verbatim from live' do
      before do
        candidate # derived from the unflagged live
        flag_ox!(live)
        allow(Ruby4Lich5::PackagePolicy).to receive(:default_patched).and_return(->(name) { name == 'ox' })
      end

      it 'accepts a retained obsolete closure that keeps its accepted flag' do
        live_ox = live.fetch('targets').first.fetch('units').find { |unit| unit['id'] == 'ox' }
        live_ox['lifecycle'] = { 'state' => 'obsolete', 'until_date' => '2099-01-01' }
        candidate.fetch('targets').first.fetch('units').map! { |unit| unit['id'] == 'ox' ? JSON.parse(JSON.generate(live_ox)) : unit }
        expect(ox_packages(candidate).map { |package| package['self_build_equivalent'] }).to eq([true])
        expect { build_plan }.not_to raise_error
      end

      it 'accepts a retained range legacy closure that keeps its accepted flag beside an unflagged ranged replacement' do
        units = live.fetch('targets').first.fetch('units')
        legacy = units.find { |unit| unit['id'] == 'ox' }
        package = { 'name' => 'ox', 'version' => '2.14.30', 'filename' => 'ox-2.14.30-x64-mingw-ucrt.gem', 'sha256' => "sha256:#{'d' * 64}" }
        ranged = { 'id' => 'ox-ranged', 'members' => ['ox'], 'legacy_unit' => 'ox', 'lich_versions' => { 'min_inclusive' => '5.24.0' },
                   'artifact' => { 'url' => 'https://rubygems.org/downloads/ox-2.14.30-x64-mingw-ucrt.gem', 'filename' => package.fetch('filename'),
                                   'sha256' => package.fetch('sha256'), 'archive' => 'gem' },
                   'packages' => [package], 'install_order' => ['ox'] }
        units << ranged
        candidate_units = candidate.fetch('targets').first.fetch('units')
        candidate_units.map! { |unit| unit['id'] == 'ox' ? JSON.parse(JSON.generate(legacy)) : unit }
        candidate_units << JSON.parse(JSON.generate(ranged))
        candidate.fetch('targets').first['range_reader'] = { 'release' => 'v5.24.0', 'commit' => 'e' * 40 }
        expect(ox_packages(candidate).map { |entry| entry['self_build_equivalent'] }).to eq([true, nil])
        expect { build_plan }.not_to raise_error
      end
    end
  end

  it 'requires an explicit exact change digest even for otherwise matching input digests' do
    plan = build_plan
    expect do
      described_class.approve!(plan, candidate_digest: plan['candidate_sha256'], live_digest: plan['live_sha256'], change_digest: '')
    end.to raise_error(ArgumentError, /approval does not match/)
  end

  it 'binds the supported-client matrix into the exact administrative approval' do
    args = { candidate_bytes: JSON.generate(candidate), live_bytes: JSON.generate(live), candidate_tag: tag,
             repository: 'elanthia-online/Ruby4Lich5', assets: assets, source_sha: 'a' * 40 }
    first = described_class.build(**args, supported_startup_policy: { 'clients' => ['oldest'] })
    second = described_class.build(**args, supported_startup_policy: { 'clients' => %w[oldest current] })
    expect(first.fetch('change_sha256')).not_to eq(second.fetch('change_sha256'))
    expect do
      described_class.approve!(second, candidate_digest: first.fetch('candidate_sha256'), live_digest: first.fetch('live_sha256'), change_digest: first.fetch('change_sha256'))
    end.to raise_error(ArgumentError, /exact candidate/)
  end

  it 'binds unused retirement diagnostics into approval without changing the client matrix' do
    args = { candidate_bytes: JSON.generate(candidate), live_bytes: JSON.generate(live), candidate_tag: tag,
             repository: 'elanthia-online/Ruby4Lich5', assets: assets, source_sha: 'a' * 40 }
    policy = { 'clients' => %w[oldest current ranged] }
    first = described_class.build(**args, supported_startup_policy: policy)
    diagnostic = { 'v5.23.0-typo' => { 'commit' => 'b' * 40, 'reason' => 'Reviewed fixture retirement' } }
    second = described_class.build(**args, supported_startup_policy: policy.merge('unused_retirements' => diagnostic))
    expect(second.dig('supported_startup_policy', 'unused_retirements')).to eq(diagnostic)
    expect(second.fetch('change_sha256')).not_to eq(first.fetch('change_sha256'))
    expect { described_class.approve!(second, candidate_digest: first['candidate_sha256'], live_digest: first['live_sha256'], change_digest: first['change_sha256']) }
      .to raise_error(ArgumentError, /exact candidate/)
  end

  context 'with no accepted predecessor (genesis)' do
    def build_genesis(document = candidate, asset_list = assets)
      described_class.build_genesis(candidate_bytes: JSON.generate(document), candidate_tag: tag, repository: 'elanthia-online/Ruby4Lich5',
                                    assets: asset_list, source_sha: 'a' * 40, supported_startup_policy: { 'clients' => %w[ranged-core] })
    end

    def reassets(document)
      units = document.fetch('targets').first.fetch('units').select { |unit| unit.dig('artifact', 'url').include?("/#{tag}/") }
      map = units.to_h { |unit| [unit.dig('artifact', 'filename'), unit.dig('artifact', 'sha256')] }
      map['R4L5-gem-manifest.json'] = described_class.digest(JSON.generate(document))
      map.map { |name, digest| { 'name' => name, 'digest' => digest } }
    end

    it 'approves the literal live digest absent with no rollback, binding genesis into the change digest' do
      plan = build_genesis
      expect(plan.fetch('genesis')).to be(true)
      expect(plan.fetch('live_sha256')).to eq('absent')
      expect(plan).not_to have_key('rollback_sha256')
      expect(plan.fetch('changes')).to eq([{ 'target' => '4.0/x64-mingw-ucrt', 'before' => nil, 'after' => candidate.fetch('targets').first.fetch('units') }])
      approval = plan.slice('genesis', 'candidate_sha256', 'live_sha256', 'changes', 'supported_startup_policy')
      expect(plan.fetch('change_sha256')).to eq(described_class.digest(JSON.generate(approval)))
      expect { described_class.approve!(plan, candidate_digest: plan['candidate_sha256'], live_digest: 'absent', change_digest: plan['change_sha256']) }.not_to raise_error
      expect { described_class.approve!(plan, candidate_digest: plan['candidate_sha256'], live_digest: '', change_digest: plan['change_sha256']) }
        .to raise_error(ArgumentError, /exact candidate/)
      ordinary = build_plan
      expect(ordinary).not_to have_key('genesis')
      expect(ordinary.fetch('live_sha256')).to match(/\Asha256:\h{64}\z/)
      expect { described_class.approve!(ordinary, candidate_digest: ordinary['candidate_sha256'], live_digest: 'absent', change_digest: ordinary['change_sha256']) }
        .to raise_error(ArgumentError, /exact candidate/)
    end

    it 'rejects an artifact outside this candidate or RubyGems, since nothing is already served' do
      unit = candidate.fetch('targets').first.fetch('units').find { |item| item.dig('artifact', 'url').include?("/#{tag}/") }
      unit.fetch('artifact')['url'] = "https://github.com/elanthia-online/Ruby4Lich5/releases/download/R4L5-gem-bundle-x64-mingw-ucrt/#{unit.dig('artifact', 'filename')}"
      expect { build_genesis(candidate, reassets(candidate)) }.to raise_error(ArgumentError, /immutable candidate or original RubyGems/)
      # The same served artifact is accepted by an ordinary promotion because the predecessor serves it.
      live_unit = live.fetch('targets').first.fetch('units').find { |item| item['id'] == unit['id'] }
      live_unit['artifact'] = unit.fetch('artifact')
      expect { build_plan }.not_to raise_error
    end

    it 'keeps every candidate check that needs no predecessor' do
      expect { build_genesis(candidate, assets.reject { |asset| asset['name'] == 'R4L5-gem-manifest.json' }) }.to raise_error(ArgumentError, /manifest asset digest/)
      candidate.fetch('targets').first['contract'] = { 'promotable' => false, 'overrides' => {} }
      expect { build_genesis(candidate, reassets(candidate)) }.to raise_error(ArgumentError, /override or diagnostic/)
      candidate.fetch('targets').first.delete('contract')
      allow(Ruby4Lich5::GemManifestValidator).to receive(:validate!)
      candidate.fetch('targets').first.fetch('units').flat_map { |unit| unit.fetch('packages') }.select { |package| package['name'] == 'sqlite3' }.each { |package| package['version'] = '2.10.1' }
      expect { build_genesis(candidate, reassets(candidate)) }.to raise_error(ArgumentError, /sqlite3 2\.10\.2/)
      expect do
        described_class.build_genesis(candidate_bytes: JSON.generate(candidate), candidate_tag: 'R4L5-gem-bundle-x64-mingw-ucrt', repository: 'elanthia-online/Ruby4Lich5',
                                      assets: reassets(candidate), source_sha: 'a' * 40)
      end.to raise_error(ArgumentError, /invalid candidate identity/)
    end

    it 'refuses withdrawals and requires a released range reader for ranged units' do
      allow(Ruby4Lich5::GemManifestValidator).to receive(:validate!)
      { 'withdrawn_members' => ['retired-gem'], 'withdrawals' => { 'retired' => {} }, 'withdrawal_members' => { 'retired' => ['retired-gem'] } }.each do |key, value|
        candidate.fetch('targets').first[key] = value
        expect { build_genesis(candidate, reassets(candidate)) }.to raise_error(ArgumentError, /no predecessor to withdraw from/), key
        candidate.fetch('targets').first.delete(key)
      end
      candidate.fetch('targets').first.fetch('units').first['lich_versions'] = '>= 5.25.0'
      expect { build_genesis(candidate, reassets(candidate)) }.to raise_error(ArgumentError, /explicitly selected released reader/)
      candidate.fetch('targets').first['range_reader'] = { 'release' => 'v5.25.0', 'commit' => 'c' * 40 }
      expect { build_genesis(candidate, reassets(candidate)) }.not_to raise_error
    end
  end

  it 'refuses a rollback predecessor still serving affected sqlite3' do
    live.fetch('targets').first.fetch('units').first.fetch('packages').first['version'] = '2.10.1'
    expect { build_plan }.to raise_error(ArgumentError, /P1 sqlite3/)
  end

  it 'refuses a removed recovery member until lifecycle policy is implemented' do
    candidate.fetch('targets').first.fetch('units').reject! { |unit| unit['id'] == 'ox' }
    expect { build_plan }.to raise_error(ArgumentError, /withdrawal requires/)
  end

  it 'refuses duplicate unit identities even when the consumer can select an earlier match' do
    units = candidate.fetch('targets').first.fetch('units')
    units << JSON.parse(JSON.generate(units.last))
    expect { build_plan }.to raise_error(ArgumentError, /duplicate recovery unit/)
  end

  it 'rejects an artifact whose release digest changed after inspection' do
    assets.find { |asset| asset['name'].end_with?('.gem') }['digest'] = "sha256:#{'c' * 64}"
    expect { build_plan }.to raise_error(ArgumentError, /artifact identity differs/)
  end

  it 'rejects new artifact routing outside immutable candidates or original RubyGems files' do
    candidate.fetch('targets').first.fetch('units').find { |unit| unit['id'] == 'ox' }.fetch('artifact')['url'] = 'https://example.invalid/ox.gem'
    expect { build_plan }.to raise_error(ArgumentError, /new artifacts must use/)
  end

  it 'rejects a candidate manifest digest mismatch before any publication is possible' do
    assets.last['digest'] = "sha256:#{'d' * 64}"
    expect { build_plan }.to raise_error(ArgumentError, /manifest asset digest differs/)
  end

  it 'runs both pinned consumer parsers in separate processes against every committed unit' do
    expect(Ruby4Lich5::RecoveryConsumers.entry('current').fetch('sha256')).to eq(Ruby4Lich5::GemManifestValidator::CONSUMER_SHA256)
    %w[current oldest].each do |name|
      program = <<~RUBY
        require 'json'
        require_relative '#{File.expand_path('../../lib/ruby4lich5/recovery_consumers', __dir__)}'
        entry = Ruby4Lich5::RecoveryConsumers.entry('#{name}')
        require entry.fetch('absolute_path')
        document = #{live.inspect}
        target = document.fetch('targets').first
        target['platform'] = Gem::Platform.local.to_s
        recovery = Lich::DependencyRecovery.new(http_get: ->(_uri) { JSON.generate(document) })
        recovery.define_singleton_method(:ruby_abi) { target.fetch('ruby_abi') }
        target.fetch('units').each { |unit| recovery.send(:validate_unit!, unit) }
        abort 'old consumer rejected manifest' unless recovery.recovery_plan(target.fetch('units').flat_map { |u| u.fetch('members') }).success?
      RUBY
      output, status = Open3.capture2e(RbConfig.ruby, '-e', program)
      expect(status).to be_success, output
    end
  end

  context 'recovery receipts' do
    let(:context) do
      build_plan.merge('ruby_archive_digest' => "sha256:#{'e' * 64}", 'ruby_installer_version' => '4.0.9-1',
                       'native_restart_required' => true, 'expected_members' => %w[gtk3 sqlite3])
    end
    let(:receipts) do
      %w[current oldest].map do |key|
        consumer = Ruby4Lich5::RecoveryConsumers.entry(key)
        context.slice('candidate_sha256', 'change_sha256', 'source_sha', 'assets', 'ruby_archive_digest', 'ruby_installer_version').merge(
          'schema' => 1, 'success' => true, 'consumer' => key, 'consumer_commit' => consumer['commit'], 'consumer_sha256' => consumer['sha256'],
          'native_restart' => true, 'members' => %w[gtk3 sqlite3]
        )
      end
    end

    it 'requires both exact-candidate successful consumer receipts' do
      expect(Ruby4Lich5::RecoveryReceipts.verify!(context, receipts)).to be(true)
      expect { Ruby4Lich5::RecoveryReceipts.verify!(context, receipts.first(1)) }.to raise_error(ArgumentError, /required consumer/)
    end

    it 'also requires exact selected-candidate reader identity and applicable members for range-aware recovery' do
      context['ranged_consumer'] = { 'commit' => 'f' * 40, 'sha256' => 'a' * 64, 'policy_sha256' => 'b' * 64 }
      context['ranged_members'] = %w[gtk3 sqlite3 added-dependency]
      context['supported_startup_policy'] = { 'clients' => %w[current oldest ranged] }
      modern = receipts.first.merge('consumer' => 'ranged', 'consumer_commit' => 'f' * 40, 'consumer_sha256' => 'a' * 64,
                                    'members' => context.fetch('ranged_members'),
                                    'supported_startup_policy_sha256' => Digest::SHA256.hexdigest(JSON.generate(context.fetch('supported_startup_policy'))))
      expect { Ruby4Lich5::RecoveryReceipts.verify!(context, receipts) }.to raise_error(ArgumentError, /required consumer/)
      expect(Ruby4Lich5::RecoveryReceipts.verify!(context, receipts + [modern])).to be(true)
      modern['consumer_sha256'] = '0' * 64
      expect { Ruby4Lich5::RecoveryReceipts.verify!(context, receipts + [modern]) }.to raise_error(ArgumentError, /consumer or completion identity/)
    end

    it 'requires proof that the approved startup matrix passed before accepting the ranged receipt' do
      context['ranged_consumer'] = { 'commit' => 'f' * 40, 'sha256' => 'a' * 64, 'policy_sha256' => 'b' * 64 }
      context['ranged_members'] = %w[gtk3 sqlite3]
      context['supported_startup_policy'] = { 'clients' => %w[oldest current ranged] }
      modern = receipts.first.merge('consumer' => 'ranged', 'consumer_commit' => 'f' * 40, 'consumer_sha256' => 'a' * 64)
      expect { Ruby4Lich5::RecoveryReceipts.verify!(context, receipts + [modern]) }.to raise_error(ArgumentError, /startup policy receipt/)
      modern['supported_startup_policy_sha256'] = Digest::SHA256.hexdigest(JSON.generate(context.fetch('supported_startup_policy')))
      expect(Ruby4Lich5::RecoveryReceipts.verify!(context, receipts + [modern])).to be(true)
    end

    it 'requires a startup matrix whenever a ranged consumer is required' do
      context['ranged_consumer'] = { 'commit' => 'f' * 40, 'sha256' => 'a' * 64 }
      context['ranged_members'] = context.fetch('expected_members')
      modern = receipts.first.merge('consumer' => 'ranged', 'consumer_commit' => 'f' * 40, 'consumer_sha256' => 'a' * 64)
      expect { Ruby4Lich5::RecoveryReceipts.verify!(context, receipts + [modern]) }.to raise_error(ArgumentError, /requires.*matrix/)
    end

    it 'loads all required receipts through the actual CLI and fails on missing or unproven ranged recovery' do
      context['ranged_consumer'] = { 'commit' => 'f' * 40, 'sha256' => 'a' * 64 }
      context['ranged_members'] = context.fetch('expected_members')
      context['supported_startup_policy'] = { 'clients' => %w[current oldest ranged] }
      modern = receipts.first.merge('consumer' => 'ranged', 'consumer_commit' => 'f' * 40, 'consumer_sha256' => 'a' * 64,
                                    'supported_startup_policy_sha256' => Digest::SHA256.hexdigest(JSON.generate(context.fetch('supported_startup_policy'))))
      cli = File.expand_path('../../bin/check_recovery_receipts.rb', __dir__)
      Dir.mktmpdir do |directory|
        path = File.join(directory, 'context.json')
        File.write(path, JSON.generate(context))
        (receipts + [modern]).each { |receipt| File.write(File.join(directory, "#{receipt.fetch('consumer')}.json"), JSON.generate(receipt)) }
        output, status = Open3.capture2e(RbConfig.ruby, cli, path, directory)
        expect(status.success?).to be(true), output
        expect(output).to include('3 exact-candidate')
        modern['consumer_commit'] = '0' * 40
        File.write(File.join(directory, 'ranged.json'), JSON.generate(modern))
        output, status = Open3.capture2e(RbConfig.ruby, cli, path, directory)
        expect(status.success?).to be(false)
        expect(output).to include('consumer or completion identity')
        modern['consumer_commit'] = 'f' * 40
        modern.delete('supported_startup_policy_sha256')
        File.write(File.join(directory, 'ranged.json'), JSON.generate(modern))
        output, status = Open3.capture2e(RbConfig.ruby, cli, path, directory)
        expect(status.success?).to be(false)
        expect(output).to include('startup policy receipt')
        File.delete(File.join(directory, 'ranged.json'))
        output, status = Open3.capture2e(RbConfig.ruby, cli, path, directory)
        expect(status.success?).to be(false)
        expect(output).to include('ranged.json')
        context.delete('ranged_consumer')
        context.delete('supported_startup_policy')
        File.write(path, JSON.generate(context))
        output, status = Open3.capture2e(RbConfig.ruby, cli, path, directory)
        expect(status.success?).to be(true), output
        expect(output).to include('2 exact-candidate')
      end
    end

    context 'with an approved platform scope' do
      let(:scope) { { 'legacy' => [], 'startup' => [], 'soak' => [], 'ranged' => true, 'platform' => 'aarch64-mingw-ucrt' } }
      let(:modern) do
        receipts.first.merge('consumer' => 'ranged', 'consumer_commit' => 'f' * 40, 'consumer_sha256' => 'a' * 64, 'members' => context.fetch('ranged_members'),
                             'supported_startup_policy_sha256' => Digest::SHA256.hexdigest(JSON.generate(context.fetch('supported_startup_policy'))))
      end

      before do
        context['ranged_consumer'] = { 'commit' => 'f' * 40, 'sha256' => 'a' * 64 }
        context['ranged_members'] = context.fetch('expected_members')
        context['supported_startup_policy'] = { 'clients' => %w[ranged-core ranged-gtk], 'platform_scope' => scope }
      end

      it 'requires only the in-scope consumers for that platform and keeps x64 at all three' do
        expect(Ruby4Lich5::RecoveryReceipts.required_consumers(context)).to eq(%w[ranged])
        expect(Ruby4Lich5::RecoveryReceipts.verify!(context, [modern])).to be(true)
        expect { Ruby4Lich5::RecoveryReceipts.verify!(context, receipts + [modern]) }.to raise_error(ArgumentError, /required consumer/)
        expect { Ruby4Lich5::RecoveryReceipts.verify!(context, []) }.to raise_error(ArgumentError, /required consumer/)
        scope['legacy'] = %w[oldest]
        context['supported_startup_policy']['platform_scope'] = scope
        expect(Ruby4Lich5::RecoveryReceipts.required_consumers(context)).to eq(%w[oldest ranged])
        context['supported_startup_policy'] = { 'clients' => %w[current oldest ranged] }
        expect(Ruby4Lich5::RecoveryReceipts.required_consumers(context)).to eq(%w[current oldest ranged])
      end

      it 'never accepts an out-of-scope skip marker as a receipt' do
        skipped = { 'schema' => 1, 'consumer' => 'ranged', 'skipped' => true, 'platform' => scope['platform'], 'candidate_sha256' => context['candidate_sha256'] }
        expect { Ruby4Lich5::RecoveryReceipts.verify!(context, [skipped]) }.to raise_error(ArgumentError, /consumer or completion identity/)
      end

      it 'rejects a malformed approved scope instead of narrowing the required set' do
        [scope.merge('ranged' => false), scope.merge('legacy' => ['newest']), scope.except('platform'), scope.merge('legacy' => 'current')].each do |bad|
          context['supported_startup_policy']['platform_scope'] = bad
          expect { Ruby4Lich5::RecoveryReceipts.required_consumers(context) }.to raise_error(ArgumentError, /invalid approved platform scope/), bad.inspect
        end
        context['supported_startup_policy']['platform_scope'] = scope
        context.delete('ranged_consumer')
        expect { Ruby4Lich5::RecoveryReceipts.required_consumers(context) }.to raise_error(ArgumentError, /invalid approved platform scope/)
      end

      it 'loads only the in-scope receipts through the actual CLI' do
        cli = File.expand_path('../../bin/check_recovery_receipts.rb', __dir__)
        Dir.mktmpdir do |directory|
          path = File.join(directory, 'context.json')
          File.write(path, JSON.generate(context))
          File.write(File.join(directory, 'ranged.json'), JSON.generate(modern))
          File.write(File.join(directory, 'current.json'), JSON.generate('schema' => 1, 'consumer' => 'current', 'skipped' => true))
          output, status = Open3.capture2e(RbConfig.ruby, cli, path, directory)
          expect(status.success?).to be(true), output
          expect(output).to include('1 exact-candidate')
          File.delete(File.join(directory, 'ranged.json'))
          output, status = Open3.capture2e(RbConfig.ruby, cli, path, directory)
          expect(status.success?).to be(false)
          expect(output).to include('ranged.json')
        end
      end
    end

    it 'rejects another candidate, a missing member and a missing native restart' do
      receipts.first['candidate_sha256'] = 'wrong'
      expect { Ruby4Lich5::RecoveryReceipts.verify!(context, receipts) }.to raise_error(ArgumentError, /candidate_sha256/)
      receipts.first['candidate_sha256'] = context['candidate_sha256']
      receipts.first['members'] = ['gtk3']
      expect { Ruby4Lich5::RecoveryReceipts.verify!(context, receipts) }.to raise_error(ArgumentError, /omitted members/)
      receipts.first['members'] = context['expected_members']
      receipts.first['native_restart'] = false
      expect { Ruby4Lich5::RecoveryReceipts.verify!(context, receipts) }.to raise_error(ArgumentError, /native restart/)
    end
  end
end
