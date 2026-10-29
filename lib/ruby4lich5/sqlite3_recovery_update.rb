# frozen_string_literal: true

require 'digest'
require 'json'
require 'rubygems/package'
require_relative 'gem_manifest_validator'

module Ruby4Lich5
  # Narrow offline preparation for P1. Retire after effort 5's accepted-lock
  # replacement tool covers direct RubyGems units and preserves unrelated units.
  class Sqlite3RecoveryUpdate
    VERSION = '2.10.2'
    PLATFORM = 'x64-mingw-ucrt'
    FILENAME = "sqlite3-#{VERSION}-#{PLATFORM}.gem"

    def self.prepare(manifest:, gem_path:, versions:)
      entry = versions.find { |item| item['number'] == VERSION && item['platform'] == PLATFORM }
      digest = Digest::SHA256.file(gem_path).hexdigest
      raise ArgumentError, 'sqlite3 package differs from RubyGems version metadata' unless entry && entry['sha'] == digest

      package = Gem::Package.new(gem_path)
      spec = package.spec
      unless File.basename(gem_path) == FILENAME && spec.name == 'sqlite3' && spec.version.to_s == VERSION &&
             spec.platform.to_s == PLATFORM && package.contents.any? { |name| name.start_with?('lib/sqlite3/4.0/') && name.end_with?('.so') }
        raise ArgumentError, 'sqlite3 package must be the 2.10.2 platform binary with Ruby 4.0 extension'
      end

      result = JSON.parse(JSON.generate(manifest))
      target = result.fetch('targets').find { |item| item['ruby_abi'] == '4.0' && item['platform'] == PLATFORM }
      raise ArgumentError, 'manifest has no Ruby 4.0 Windows target' unless target

      units = target.fetch('units').select { |unit| unit.fetch('members').include?('sqlite3') }
      unless units.size == 1 && units.first.fetch('members') == ['sqlite3'] && units.first.fetch('packages').size == 1
        raise ArgumentError, 'sqlite3 update requires exactly one single-member recovery unit'
      end

      unit = units.first
      unit['artifact'] = {
        'url' => "https://rubygems.org/downloads/#{FILENAME}", 'filename' => FILENAME,
        'sha256' => "sha256:#{digest}", 'archive' => 'gem'
      }
      unit['packages'] = [{ 'name' => 'sqlite3', 'version' => VERSION, 'filename' => FILENAME, 'sha256' => "sha256:#{digest}" }]
      GemManifestValidator.validate!(result)
      result
    end
  end
end
