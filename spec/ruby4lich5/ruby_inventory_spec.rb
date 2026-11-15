# frozen_string_literal: true

require 'ruby4lich5/ruby_inventory'

RSpec.describe Ruby4Lich5::RubyInventory do
  def spec(name, version, dependencies = {})
    Gem::Specification.new do |item|
      item.name = name
      item.version = version
      dependencies.each { |child, requirements| item.add_runtime_dependency(child, *Array(requirements)) }
    end
  end

  describe '.gems_from' do
    it 'keeps the newest version of each gem with its sorted runtime dependencies' do
      specs = [spec('zlib', '3.2.2'), spec('json', '2.18.0'), spec('zlib', '3.2.3'),
               spec('openssl', '4.0.0', 'zlib' => '>= 0', 'digest' => ['>= 3.0', '< 4'])]

      expect(described_class.gems_from(specs)).to eq(
        'json'    => { 'version' => '2.18.0', 'dependencies' => {} },
        'openssl' => { 'version' => '4.0.0', 'dependencies' => { 'digest' => Gem::Requirement.new(['>= 3.0', '< 4']).as_list, 'zlib' => ['>= 0'] } },
        'zlib'    => { 'version' => '3.2.3', 'dependencies' => {} }
      )
      expect(described_class.gems_from(specs).keys).to eq(%w[json openssl zlib])
      expect(described_class.gems_from(specs).dig('openssl', 'dependencies').keys).to eq(%w[digest zlib])
    end
  end

  # The floor baseline is derived from a RubyInstaller archive and compared
  # with live captures, so both must come from the same builder.
  it 'builds the live capture and the derived baseline with the same gem map builder' do
    expect(described_class.capture.fetch('gems')).to eq(described_class.gems_from(Gem::Specification.to_a))
    script = File.read(File.expand_path('../../bin/derive_ruby_floor_baseline.rb', __dir__))
    expect(script).to include('Ruby4Lich5::RubyInventory.gems_from(specs)')
    expect(script).not_to include('runtime_dependencies')
  end
end
