# frozen_string_literal: true

require_relative 'recovery_consumers'

module Ruby4Lich5
  # The workflow additionally requires successful jobs in this same run.
  class RecoveryReceipts
    def self.verify!(context, receipts)
      raise ArgumentError, 'all required consumer receipts are required' unless receipts.map { |item| item['consumer'] }.sort == (context.key?('ranged_consumer') ? %w[current oldest ranged] : %w[current oldest])

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
        expected = context.fetch('ranged_members') if receipt.fetch('consumer') == 'ranged'
        raise ArgumentError, 'recovery receipt omitted members' unless receipt.fetch('members') == expected
      end
      true
    end
  end
end
