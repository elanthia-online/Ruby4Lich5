# frozen_string_literal: true

require 'ruby4lich5/recovery_sequence'

RSpec.describe Ruby4Lich5::RecoverySequence do
  plan_class = Struct.new(:units, :error, keyword_init: true) do
    def success?
      error.nil?
    end
  end
  let(:plan_type) { plan_class }
  let(:units) do
    %w[sqlite3 ffi gtk3 redis].map do |name|
      { 'members' => [name], 'packages' => [{ 'name' => name, 'version' => '1.0.0' }], 'native' => name != 'redis' }
    end
  end
  let(:recovery) do
    object = double('consumer')
    allow(object).to receive(:recovery_plan).with(%w[sqlite3 ffi gtk3 redis]).and_return(plan_type.new(units: units))
    allow(object).to receive(:native_runtime_unit?) { |unit| unit.fetch('native') }
    object
  end

  it 'rejects multi-native acceptance plans before sequencing can hide a consumer limitation' do
    expect { described_class.next_plan(recovery, %w[sqlite3 ffi gtk3 redis], installed: ->(_) { false }) }
      .to raise_error(/at most one native runtime unit/)
  end

  it 'rejects multi-native plans even when installed gems would hide the extra unit' do
    expect { described_class.next_plan(recovery, %w[sqlite3 ffi gtk3 redis], installed: ->(_) { true }) }
      .to raise_error(/at most one native runtime unit/)
  end

  it 'recovers one native suite and all direct units, then completes after restart' do
    units.each { |unit| unit['native'] = unit['members'] == ['gtk3'] }
    installed = []
    rounds = []
    loop do
      batch = described_class.next_plan(recovery, %w[sqlite3 ffi gtk3 redis], installed: ->(package) { installed.include?(package['name']) })
      break unless batch

      rounds << batch.units.flat_map { |unit| unit['members'] }
      expect(batch.units.count { |unit| unit['native'] }).to be <= 1
      installed.concat(rounds.last)
    end
    expect(rounds).to eq([%w[sqlite3 ffi redis gtk3]])
    expect(installed.sort).to eq(%w[ffi gtk3 redis sqlite3])
  end

  context 'with a single-transaction consumer' do
    def next_plan(installed)
      described_class.next_plan(recovery, %w[sqlite3 ffi gtk3 redis], installed: installed, single_transaction: true)
    end

    it 'returns every pending native and direct unit as one batch' do
      batch = next_plan(->(_) { false })
      expect(batch.units.flat_map { |unit| unit['members'] }).to eq(%w[sqlite3 ffi gtk3 redis])
    end

    it 'omits already-installed units and completes once everything is installed' do
      expect(next_plan(->(package) { package['name'] == 'ffi' }).units.flat_map { |unit| unit['members'] }).to eq(%w[sqlite3 gtk3 redis])
      expect(next_plan(->(_) { true })).to be_nil
    end

    it 'still fails before installation when consumer planning reports an error' do
      allow(recovery).to receive(:recovery_plan).and_return(plan_type.new(units: [], error: 'bad manifest'))
      expect { next_plan(->(_) { false }) }.to raise_error(/bad manifest/)
    end

    it 'completes after its one restart when everything is installed' do
      expect(described_class.next_plan(recovery, %w[sqlite3 ffi gtk3 redis], installed: ->(_) { true },
                                                                              single_transaction: true, completed_restarts: 1)).to be_nil
    end

    it 'rejects units still pending after its restart instead of starting another round' do
      expect do
        described_class.next_plan(recovery, %w[sqlite3 ffi gtk3 redis], installed: ->(package) { package['name'] != 'gtk3' },
                                                                        single_transaction: true, completed_restarts: 1)
      end.to raise_error(/single-transaction recovery left units pending after its restart: gtk3/)
    end
  end

  it 'keeps sequencing one native unit per restart for older consumers regardless of restarts taken' do
    units.each { |unit| unit['native'] = unit['members'] == ['gtk3'] }
    batch = described_class.next_plan(recovery, %w[sqlite3 ffi gtk3 redis], installed: ->(package) { package['name'] != 'gtk3' },
                                                                            completed_restarts: 1)
    expect(batch.units.flat_map { |unit| unit['members'] }).to eq(%w[gtk3])
  end

  it 'fails before installation when real consumer planning reports an error' do
    allow(recovery).to receive(:recovery_plan).and_return(plan_type.new(units: [], error: 'bad manifest'))
    expect { described_class.next_plan(recovery, %w[sqlite3 ffi gtk3 redis]) }.to raise_error(/bad manifest/)
  end
end
