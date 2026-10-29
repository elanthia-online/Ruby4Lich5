# frozen_string_literal: true

require 'rubygems'

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
  end
end
