# frozen_string_literal: true

require_relative 'recovery_consumers'

module Ruby4Lich5
  # The workflow additionally requires successful jobs in this same run.
  class RecoveryReceipts
    # A platform scope is part of the approved supported-client policy, which
    # the ranged receipt binds by digest, so the required set cannot drift from
    # what inspection approved and the target runner re-derived.
    #
    # The scope is re-checked here because the context is an uploaded artifact
    # read on the runner before any receipt is bound, and a malformed scope must
    # not be able to shrink the required set. Only the fields this method reads
    # are checked, against the receipt consumer names. SupportedStartupPolicy's
    # entry validator is not reused: it checks the clients file and platform
    # table, which this receipts-only check (bin/check_recovery_receipts.rb)
    # does not load.
    def self.required_consumers(context)
      policy = context['supported_startup_policy']
      scope = policy['platform_scope'] if policy.is_a?(Hash)
      return context.key?('ranged_consumer') ? %w[current oldest ranged] : %w[current oldest] if scope.nil?

      unless scope.is_a?(Hash) && scope['platform'].is_a?(String) && scope['ranged'] == true && context.key?('ranged_consumer') &&
             scope['legacy'].is_a?(Array) && scope['legacy'].uniq == scope['legacy'] && (scope['legacy'] - %w[current oldest]).empty?
        raise ArgumentError, 'invalid approved platform scope for recovery receipts'
      end
      (scope['legacy'] + ['ranged']).sort
    end

    def self.verify!(context, receipts)
      raise ArgumentError, 'all required consumer receipts are required' unless receipts.map { |item| item['consumer'] }.sort == required_consumers(context)

      if context.key?('ranged_consumer')
        matrix = context['supported_startup_policy']
        unless matrix.is_a?(Hash) && matrix['clients'].is_a?(Array) && !matrix['clients'].empty?
          raise ArgumentError, 'ranged recovery requires the approved supported startup policy matrix'
        end
      end

      receipts.each do |receipt|
        consumer = receipt.fetch('consumer') == 'ranged' ? context.fetch('ranged_consumer') : RecoveryConsumers.entry(receipt.fetch('consumer'))
        unless receipt['schema'] == 1 && receipt['success'] == true && receipt['consumer_commit'] == consumer.fetch('commit') &&
               receipt['consumer_sha256'] == consumer.fetch('sha256')
          raise ArgumentError, 'recovery receipt has invalid consumer or completion identity'
        end
        %w[candidate_sha256 change_sha256 source_sha assets ruby_archive_digest ruby_installer_version].each do |key|
          raise ArgumentError, "recovery receipt #{key} differs from this candidate" unless receipt.fetch(key) == context.fetch(key)
        end
        if context.fetch('native_restart_required') && receipt['native_restart'] != true
          raise ArgumentError, 'recovery receipt lacks the required native restart'
        end
        expected = context.fetch('expected_members')
        if receipt.fetch('consumer') == 'ranged'
          digest = Digest::SHA256.hexdigest(JSON.generate(context.fetch('supported_startup_policy')))
          raise ArgumentError, 'supported startup policy receipt differs' unless receipt['supported_startup_policy_sha256'] == digest
        end
        expected = context.fetch('ranged_members') if receipt.fetch('consumer') == 'ranged'
        raise ArgumentError, 'recovery receipt omitted members' unless receipt.fetch('members') == expected
      end
      true
    end
  end
end
