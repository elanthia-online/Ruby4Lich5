# frozen_string_literal: true

require 'digest'
require 'json'
require 'rubygems'
require_relative '../../vendor/lich5/recovery_unit_policy'

module Ruby4Lich5
  # Runs the pinned consumer's rules without downloading or installing gems.
  class GemManifestValidator
    CONSUMER_COMMIT = '89fa0fd77758e6d4c4385c6194dbc65535e47a3d'
    CONSUMER_SHA256 = '515ce67c6470deccbc1e5533bf4ca6074cb3543c327fbafd4d230dbef225ec52'
    CONSUMER_PATH = File.expand_path('../../vendor/lich5/dependency_recovery.rb', __dir__)

    def self.validate!(manifest)
      raise ArgumentError, 'pinned lich-5 recovery source digest mismatch' unless Digest::SHA256.file(CONSUMER_PATH).hexdigest == CONSUMER_SHA256

      require CONSUMER_PATH
      raise ArgumentError, 'manifest must have nonempty targets' unless manifest.is_a?(Hash) && manifest['targets'].is_a?(Array) && !manifest['targets'].empty?

      manifest.fetch('targets').each do |target|
        validate_target!(manifest, target)
      end
      true
    end

    def self.validate_target!(manifest, target)
      unless target.is_a?(Hash) && target['ruby_abi'].is_a?(String) && target['ruby_abi'].match?(/\A\d+\.\d+\z/) &&
             target['platform'].is_a?(String) && !target['platform'].empty? &&
             target['units'].is_a?(Array) && !target['units'].empty?
        raise ArgumentError, 'manifest target must have ABI, platform and nonempty units'
      end

      Lich::RecoveryUnitPolicy.validate!(target)

      # Only project target selection onto the host. Unit validation and
      # first-match planning below are the unchanged consumer implementation.
      projected = manifest.merge('targets' => [target.merge('platform' => Gem::Platform.local.to_s)])
      recovery = Lich::DependencyRecovery.new(http_get: ->(_uri) { JSON.generate(projected) })
      recovery.define_singleton_method(:ruby_abi) { target.fetch('ruby_abi') }
      target.fetch('units').each { |unit| recovery.send(:validate_unit!, unit) }
      names = target.fetch('units').flat_map { |unit| unit.fetch('members') }.uniq
      plan = recovery.recovery_plan(names)
      raise ArgumentError, "lich-5 recovery rejected manifest: #{plan.error}" unless plan.success?
    end
    private_class_method :validate_target!
  end
end
