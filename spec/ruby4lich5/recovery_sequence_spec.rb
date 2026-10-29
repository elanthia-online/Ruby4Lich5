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

  it 'installs direct units with GTK first, then sequences other native suites across restarts' do
    installed = []
    rounds = []
    loop do
      batch = described_class.next_plan(recovery, %w[sqlite3 ffi gtk3 redis], installed: ->(package) { installed.include?(package['name']) })
      break unless batch

      rounds << batch.units.flat_map { |unit| unit['members'] }
      expect(batch.units.count { |unit| unit['native'] }).to be <= 1
      installed.concat(rounds.last)
    end
    expect(rounds).to eq([%w[redis gtk3], ['sqlite3'], ['ffi']])
    expect(installed.sort).to eq(%w[ffi gtk3 redis sqlite3])
  end

  it 'fails before installation when real consumer planning reports an error' do
    allow(recovery).to receive(:recovery_plan).and_return(plan_type.new(units: [], error: 'bad manifest'))
    expect { described_class.next_plan(recovery, %w[sqlite3 ffi gtk3 redis]) }.to raise_error(/bad manifest/)
  end
end
