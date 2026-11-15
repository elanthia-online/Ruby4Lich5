# frozen_string_literal: true

require 'json'
require 'rubygems'
require_relative 'target_platform'

module Ruby4Lich5
  # The floors a published contract sets for gems RubyInstaller ships.
  #
  # Deployed Lich (5.24.0 on) requires every RubyInstaller gem its Gemfile
  # declares to be at or above contract.ruby_inventory.gems[name].version.
  # Publishing the build installer's exact capture there made the floor
  # follow whichever RubyInstaller patch built the bundle, so a newer build
  # stopped every user on an older 4.0.x patch. The published floors are
  # instead the capture of the oldest RubyInstaller Lich accepts: the
  # RubyInstaller release of lich-5's REQUIRED_RUBY, recorded per platform
  # in config/ruby-floor-baseline.json by bin/derive_ruby_floor_baseline.rb.
  # The build installer's exact capture is kept in the contract as
  # measured_ruby_inventory, and must be at or above every floor.
  #
  # Raising a floor means raising REQUIRED_RUBY in lich-5 and moving the
  # baseline here in the same reviewed change.
  module RubyFloorBaseline
    PATH = File.expand_path('../../config/ruby-floor-baseline.json', __dir__)

    class Error < StandardError; end

    # @param platform [String]
    # @param path [String]
    # @return [Hash] the platform's baseline: ruby_installer_version,
    #   archive_sha256, ruby_version and gems
    # @raise [Error]
    def self.entry(platform = TargetPlatform.current.name, path: PATH)
      document = JSON.parse(File.read(path))
      raise Error, 'RubyInstaller floor baseline must be schema 1' unless document.is_a?(Hash) && document['schema'] == 1
      entry = document.fetch('platforms', {})[platform]
      raise Error, "no RubyInstaller floor baseline for #{platform}" unless entry.is_a?(Hash)

      installer = entry['ruby_installer_version']
      unless installer.is_a?(String) && installer.match?(/\A\d+\.\d+\.\d+-\d+\z/) && entry['ruby_version'] == installer.split('-').first &&
             entry['archive_sha256'].is_a?(String) && entry['archive_sha256'].match?(/\A[0-9a-f]{64}\z/) && valid_gems?(entry['gems'])
        raise Error, "invalid RubyInstaller floor baseline for #{platform}"
      end
      entry
    end

    # Fails unless the baseline installer's Ruby is the REQUIRED_RUBY of the
    # lich-5 source the contract is built from, read from lib/version.rb
    # without running it.
    # @param source_directory [String] sealed lich-5 source
    # @param baseline [Hash] an {entry}
    # @return [true]
    # @raise [Error]
    def self.require_lich_ruby!(source_directory, baseline)
      path = File.join(source_directory, 'lib/version.rb')
      required = File.file?(path) ? File.read(path)[/^REQUIRED_RUBY = '([^']+)'/, 1] : nil
      raise Error, 'candidate has no valid REQUIRED_RUBY' unless required && Gem::Version.correct?(required)
      unless Gem::Version.new(required) == Gem::Version.new(baseline.fetch('ruby_version'))
        raise Error, "RubyInstaller floor baseline #{baseline.fetch('ruby_installer_version')} is not lich-5's REQUIRED_RUBY #{required}"
      end
      true
    end

    # @param measured [Hash] the build installer's exact capture
    # @param baseline [Hash] an {entry}
    # @return [Hash] the inventory to publish: the measured Ruby identity with
    #   the baseline's gems as floors
    # @raise [Error] if the measured capture is not at or above the floors
    def self.floors(measured, baseline)
      floors = measured.merge('gems' => baseline.fetch('gems'))
      verify_relation!(floors, measured)
      floors
    end

    # The published floors and the measured capture describe the same Ruby,
    # name the same gems, and the measured versions are at or above the
    # floors. A gem only one of them ships is refused: it would change what
    # the contract counts as RubyInstaller-supplied.
    # @param floors [Hash]
    # @param measured [Hash]
    # @return [true]
    # @raise [Error]
    def self.verify_relation!(floors, measured)
      unless floors.is_a?(Hash) && measured.is_a?(Hash) && valid_gems?(floors['gems']) && valid_gems?(measured['gems']) &&
             %w[ruby_version ruby_abi platform].all? { |key| floors[key] == measured[key] }
        raise Error, 'published RubyInstaller floors and the measured capture describe different Rubies'
      end
      unless floors['gems'].keys.sort == measured['gems'].keys.sort
        raise Error, "RubyInstaller floor baseline and the measured capture ship different gems: #{((floors['gems'].keys - measured['gems'].keys) | (measured['gems'].keys - floors['gems'].keys)).sort.join(', ')}"
      end
      below = measured['gems'].select { |name, gem| Gem::Version.new(gem['version']) < Gem::Version.new(floors['gems'][name]['version']) }
      raise Error, "measured RubyInstaller gems are below the published floors: #{below.keys.sort.join(', ')}" unless below.empty?

      true
    end

    # A candidate contract publishes the platform's baseline gems as floors,
    # and the measured capture it was built on is at or above them.
    # @param contract [Hash] runtime contract data
    # @param baseline [Hash] an {entry}
    # @return [true]
    # @raise [Error]
    def self.verify_contract!(contract, baseline = entry(contract.dig('ruby_inventory', 'platform')))
      floors = contract['ruby_inventory']
      measured = contract['measured_ruby_inventory']
      raise Error, 'candidate contract has no measured RubyInstaller capture' unless measured.is_a?(Hash)
      raise Error, 'published RubyInstaller floors differ from the reviewed baseline' unless floors.is_a?(Hash) && floors['gems'] == baseline.fetch('gems')

      verify_relation!(floors, measured)
    end

    def self.valid_gems?(gems)
      gems.is_a?(Hash) && !gems.empty? && gems.all? do |name, gem|
        name.is_a?(String) && gem.is_a?(Hash) && gem['version'].is_a?(String) && Gem::Version.correct?(gem['version']) &&
          gem['dependencies'].is_a?(Hash) && gem['dependencies'].all? { |child, list| child.is_a?(String) && list.is_a?(Array) && list.all?(String) }
      end
    end
    private_class_method :valid_gems?
  end
end
