# frozen_string_literal: true

require 'rubygems'
require_relative 'ruby_floor_baseline'

module Ruby4Lich5
  module RubyInventory
    def self.capture
      gems = Gem::Specification.to_a.group_by(&:name).sort.to_h do |name, specs|
        spec = specs.max_by(&:version)
        [name, { 'version'      => spec.version.to_s,
                 'dependencies' => spec.runtime_dependencies.sort_by(&:name).to_h { |dep| [dep.name, dep.requirement.as_list] } }]
      end
      { 'ruby_version' => RUBY_VERSION, 'ruby_abi' => RUBY_VERSION.split('.')[0, 2].join('.'),
        'platform' => Gem::Platform.local.to_s, 'gems' => gems }
    end

    def self.verify!(expected)
      raise ArgumentError, 'clean target RubyInstaller inventory differs from the measured contract' unless capture == expected
      true
    end

    # Checks a clean target RubyInstaller against a runtime contract. A
    # contract with a measured capture must have been built on exactly this
    # RubyInstaller, and its published floors must sit at or below it; an
    # older contract carries only the exact capture as ruby_inventory.
    # @param contract [Hash] runtime contract data
    # @return [true]
    # @raise [ArgumentError]
    def self.verify_contract!(contract)
      measured = contract['measured_ruby_inventory']
      return verify!(contract.fetch('ruby_inventory')) unless measured

      verify!(measured)
      RubyFloorBaseline.verify_relation!(contract.fetch('ruby_inventory'), measured)
      true
    rescue RubyFloorBaseline::Error => e
      raise ArgumentError, e.message
    end
  end
end
