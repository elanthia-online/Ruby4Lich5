# frozen_string_literal: true

require 'json'
require 'rubygems/package'
require_relative 'gem_manifest_validator'
require_relative 'resolution_lock'

module Ruby4Lich5
  # Rejects unreviewed factory version drift before baking an installer.
  class InstallerInventoryCheck
    def self.validate!(manifest:, pkg_dir:)
      GemManifestValidator.validate!(manifest)
      lock = ResolutionLock.from_h(JSON.parse(File.read(File.join(pkg_dir, 'resolution-lock.json'), encoding: 'bom|utf-8')))
      target = manifest.fetch('targets').find { |item| item['ruby_abi'] == lock.ruby_abi && item['platform'] == lock.platform }
      raise ArgumentError, 'accepted manifest has no installer target' unless target

      expected = {}
      target.fetch('units').each do |unit|
        unit.fetch('packages').each do |package|
          name, version = package.values_at('name', 'version')
          raise ArgumentError, "conflicting accepted versions for #{name}" if expected.key?(name) && expected[name] != version

          expected[name] = version
        end
      end
      # GHSA-4fqr-96q8-xrfx: never bake an affected sqlite3, even from an old manifest.
      raise ArgumentError, 'accepted sqlite3 must be at least 2.10.2' unless expected['sqlite3'] && Gem::Version.new(expected['sqlite3']) >= Gem::Version.new('2.10.2')

      actual = {}
      Dir.glob(File.join(pkg_dir, '*.gem')).each do |path|
        package = Gem::Package.new(path)
        spec = package.spec
        raise ArgumentError, "duplicate staged gem #{spec.name}" if actual.key?(spec.name)

        actual[spec.name] = spec.version.to_s
        next unless spec.name == 'sqlite3'

        unless spec.platform.to_s == lock.platform && package.contents.any? { |name| name.start_with?("lib/sqlite3/#{lock.ruby_abi}/") && name.end_with?('.so') }
          raise ArgumentError, 'sqlite3 platform gem must include the target Ruby ABI extension'
        end
      end
      differences = (expected.keys | actual.keys).sort.filter_map do |name|
        "#{name}: accepted #{expected[name].inspect}, staged #{actual[name].inspect}" unless expected[name] == actual[name]
      end
      raise ArgumentError, "installer inventory differs from accepted recovery manifest:\n#{differences.join("\n")}" unless differences.empty?

      locked = lock.closure.reject { |entry| entry.fetch(:classification).ruby_bundled? }.to_h do |entry|
        [entry.fetch(:name), entry.fetch(:version)]
      end
      raise ArgumentError, 'staged installer inventory differs from resolution lock' unless actual == locked

      true
    end
  end
end
