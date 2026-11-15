# frozen_string_literal: true

require 'json'
require 'tmpdir'
require 'fileutils'
require 'ruby4lich5/ruby_floor_baseline'
require 'ruby4lich5/runtime_contract'
require 'ruby4lich5/known_native_gems'
require 'ruby4lich5/ruby_inventory'

RSpec.describe Ruby4Lich5::RubyFloorBaseline do
  let(:root) { File.expand_path('../..', __dir__) }
  let(:fixture) { File.join(root, 'spec/fixtures/lich5-contract/current') }
  # The live x64 manifest's ruby_inventory: RubyInstaller 4.0.9-1, measured.
  let(:measured) { JSON.parse(File.read(File.join(root, 'spec/fixtures/ruby-inventory/x64-mingw-ucrt-4.0.9-1.json'))) }
  let(:baseline) { described_class.entry('x64-mingw-ucrt') }

  describe 'the reviewed baseline' do
    it 'is RubyInstaller 4.0.0-1 on both platforms, with the same gems' do
      arm = described_class.entry('aarch64-mingw-ucrt')
      expect([baseline, arm].map { |entry| entry.fetch('ruby_installer_version') }).to eq(%w[4.0.0-1 4.0.0-1])
      expect(arm.fetch('gems')).to eq(baseline.fetch('gems'))
      expect(baseline.fetch('gems').size).to eq(85)
    end

    it 'sets the floors measured from RubyInstaller 4.0.0-1, not the build installer' do
      floors = baseline.fetch('gems').slice('openssl', 'resolv', 'zlib').transform_values { |gem| gem.fetch('version') }
      expect(floors).to eq('openssl' => '4.0.0', 'resolv' => '0.7.0', 'zlib' => '3.2.2')
    end

    it 'names the same gems as the measured 4.0.9-1 capture, each at or below it' do
      expect { described_class.verify_relation!(measured.merge('gems' => baseline.fetch('gems')), measured) }.not_to raise_error
    end

    it 'refuses a missing platform or a malformed document' do
      expect { described_class.entry('x86-mingw32') }.to raise_error(described_class::Error, /no RubyInstaller floor baseline/)
      Dir.mktmpdir do |directory|
        path = File.join(directory, 'baseline.json')
        File.write(path, JSON.generate('schema' => 2, 'platforms' => {}))
        expect { described_class.entry('x64-mingw-ucrt', path: path) }.to raise_error(described_class::Error, /schema 1/)
        broken = JSON.parse(File.read(described_class::PATH))
        broken['platforms']['x64-mingw-ucrt']['ruby_version'] = '4.0.9'
        File.write(path, JSON.generate(broken))
        expect { described_class.entry('x64-mingw-ucrt', path: path) }.to raise_error(described_class::Error, /invalid RubyInstaller floor baseline/)
      end
    end
  end

  describe '.require_lich_ruby!' do
    def source_with(version_rb)
      Dir.mktmpdir do |directory|
        FileUtils.mkdir_p(File.join(directory, 'lib'))
        File.write(File.join(directory, 'lib/version.rb'), version_rb) if version_rb
        yield directory
      end
    end

    it "accepts the baseline when it is lich-5's REQUIRED_RUBY" do
      expect(described_class.require_lich_ruby!(fixture, baseline)).to be(true)
    end

    it 'refuses a REQUIRED_RUBY the baseline does not match, or none at all' do
      source_with("REQUIRED_RUBY = '4.1'\n") do |directory|
        expect { described_class.require_lich_ruby!(directory, baseline) }.to raise_error(described_class::Error, /not lich-5's REQUIRED_RUBY 4.1/)
      end
      source_with("LICH_VERSION = '5.24.3'\n") do |directory|
        expect { described_class.require_lich_ruby!(directory, baseline) }.to raise_error(described_class::Error, /no valid REQUIRED_RUBY/)
      end
      source_with(nil) do |directory|
        expect { described_class.require_lich_ruby!(directory, baseline) }.to raise_error(described_class::Error, /no valid REQUIRED_RUBY/)
      end
    end
  end

  describe '.floors and .verify_relation!' do
    it "publishes the baseline's gems with the measured Ruby's identity" do
      floors = described_class.floors(measured, baseline)
      expect(floors.reject { |key, _| key == 'gems' }).to eq(measured.reject { |key, _| key == 'gems' })
      expect(floors.fetch('gems')).to eq(baseline.fetch('gems'))
    end

    it 'refuses a measured gem below its floor' do
      lower = Marshal.load(Marshal.dump(measured))
      lower['gems']['openssl']['version'] = '3.3.0'
      expect { described_class.floors(lower, baseline) }.to raise_error(described_class::Error, /below the published floors: openssl/)
    end

    it 'refuses a gem only one side ships' do
      extra = Marshal.load(Marshal.dump(measured))
      extra['gems']['newgem'] = { 'version' => '1.0.0', 'dependencies' => {} }
      expect { described_class.floors(extra, baseline) }.to raise_error(described_class::Error, /ship different gems: newgem/)
      fewer = Marshal.load(Marshal.dump(measured))
      fewer['gems'].delete('zlib')
      expect { described_class.floors(fewer, baseline) }.to raise_error(described_class::Error, /ship different gems: zlib/)
    end

    it 'refuses floors that describe another Ruby' do
      floors = described_class.floors(measured, baseline)
      expect { described_class.verify_relation!(floors.merge('ruby_version' => '4.0.0'), measured) }
        .to raise_error(described_class::Error, /different Rubies/)
    end
  end

  # The real x64 inputs: lich-5 93e13cbe9's sealed files and the measured
  # 4.0.9-1 capture. Publishing the floors moves only what is derived from
  # the RubyInstaller inventory.
  describe 'the x64 contract built with the floors' do
    let(:target) { JSON.parse(File.read(Ruby4Lich5::RuntimeContract::TARGET)) }

    def build(baseline_entry)
      Ruby4Lich5::RuntimeContract.new(source_directory: fixture, commit: JSON.parse(File.read(File.join(fixture, 'source.json'))).fetch('commit'),
                                      inventory: measured, registry: Ruby4Lich5::KnownNativeGems.registry,
                                      gtk_version: target.fetch('gtk_version'), platform: 'x64-mingw-ucrt', baseline: baseline_entry).data
    end

    it 'changes only the published inventory, its supplied comparison and the Windows digest' do
      exact = build(baseline.merge('gems' => measured.fetch('gems')))
      floored = build(baseline)
      expect(floored.keys).to eq(exact.keys)
      expect(floored.keys.reject { |key| floored[key] == exact[key] }).to contain_exactly('ruby_inventory', 'bundled_comparison', 'windows_contract_sha256')
      expect(floored.fetch('measured_ruby_inventory')).to eq(measured)
      changed = floored.fetch('bundled_comparison').reject { |name, entry| exact.fetch('bundled_comparison')[name] == entry }
      expect(changed.transform_values { |entry| entry.fetch('supplied') }).to eq('openssl' => '4.0.0', 'resolv' => '0.7.0', 'zlib' => '3.2.2')
      expect(changed.keys.map { |name| floored.dig('bundled_comparison', name, 'locked') }).to eq(changed.keys.map { |name| exact.dig('bundled_comparison', name, 'locked') })
      expect(described_class.verify_contract!(floored)).to be(true)
    end

    it 'refuses a contract publishing anything but the reviewed floors' do
      contract = build(baseline)
      exact = contract.merge('ruby_inventory' => contract.fetch('measured_ruby_inventory'))
      expect { described_class.verify_contract!(exact) }.to raise_error(described_class::Error, /differ from the reviewed baseline/)
      expect { described_class.verify_contract!(contract.except('measured_ruby_inventory')) }.to raise_error(described_class::Error, /no measured/)
    end

    it 'refuses a candidate whose REQUIRED_RUBY the baseline does not match' do
      Dir.mktmpdir do |directory|
        FileUtils.cp_r("#{fixture}/.", directory)
        File.write(File.join(directory, 'lib/version.rb'), File.read(File.join(directory, 'lib/version.rb')).sub("REQUIRED_RUBY = '4.0'", "REQUIRED_RUBY = '4.0.9'"))
        expect do
          Ruby4Lich5::RuntimeContract.new(source_directory: directory, commit: 'd' * 40, inventory: measured, registry: Ruby4Lich5::KnownNativeGems.registry,
                                          gtk_version: target.fetch('gtk_version'), platform: 'x64-mingw-ucrt')
        end.to raise_error(Lich::RuntimeGemContract::Error, /not lich-5's REQUIRED_RUBY 4.0.9/)
      end
    end

    it 'keeps the lock-boundary check on the measured capture' do
      contract = build(baseline)
      lower = Marshal.load(Marshal.dump(contract))
      lower['measured_ruby_inventory']['gems']['resolv']['version'] = '0.6.0'
      expect { Ruby4Lich5::RuntimeContract.validate!(lower, ruby_installer_version: target.fetch('ruby_installer_version')) }
        .to raise_error(Lich::RuntimeGemContract::Error, /below the published floors: resolv/)
      expect(Ruby4Lich5::RuntimeContract.validate!(contract.except('measured_ruby_inventory').merge('ruby_inventory' => measured),
                                                   ruby_installer_version: target.fetch('ruby_installer_version'))).to be(true)
    end
  end

  describe 'RubyInventory.verify_contract!' do
    let(:contract) { { 'ruby_inventory' => described_class.floors(measured, baseline), 'measured_ruby_inventory' => measured } }

    it 'requires the clean target to equal the measured capture, above the floors' do
      allow(Ruby4Lich5::RubyInventory).to receive(:capture).and_return(measured)
      expect(Ruby4Lich5::RubyInventory.verify_contract!(contract)).to be(true)
      other = Marshal.load(Marshal.dump(measured))
      other['gems']['zlib']['version'] = '3.2.5'
      allow(Ruby4Lich5::RubyInventory).to receive(:capture).and_return(other)
      expect { Ruby4Lich5::RubyInventory.verify_contract!(contract) }.to raise_error(ArgumentError, /differs from the measured contract/)
    end

    it 'refuses floors above the measured capture' do
      allow(Ruby4Lich5::RubyInventory).to receive(:capture).and_return(measured)
      high = Marshal.load(Marshal.dump(contract))
      high['ruby_inventory']['gems']['json']['version'] = '9.0.0'
      expect { Ruby4Lich5::RubyInventory.verify_contract!(high) }.to raise_error(ArgumentError, /below the published floors: json/)
    end

    it 'checks a contract from before the baseline against its exact capture' do
      allow(Ruby4Lich5::RubyInventory).to receive(:capture).and_return(measured)
      expect(Ruby4Lich5::RubyInventory.verify_contract!('ruby_inventory' => measured)).to be(true)
      expect { Ruby4Lich5::RubyInventory.verify_contract!('ruby_inventory' => contract.fetch('ruby_inventory')) }
        .to raise_error(ArgumentError, /differs from the measured contract/)
    end
  end
end
