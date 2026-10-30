# frozen_string_literal: true

require 'ruby4lich5/promotion_plan'
require 'ruby4lich5/recovery_receipts'
require 'open3'

RSpec.describe Ruby4Lich5::PromotionPlan do
  let(:live) { JSON.parse(File.read(File.expand_path('../../manifest/R4L5-gem-manifest.json', __dir__))) }
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
      modern = receipts.first.merge('consumer' => 'ranged', 'consumer_commit' => 'f' * 40, 'consumer_sha256' => 'a' * 64,
                                    'members' => context.fetch('ranged_members'))
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
