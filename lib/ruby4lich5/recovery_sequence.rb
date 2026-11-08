# frozen_string_literal: true

module Ruby4Lich5
  # Acceptance must not hide a consumer's unsupported startup recovery plan.
  class RecoverySequence
    # @param single_transaction [Boolean] the consumer's Windows startup applies
    #   every pending unit, native or direct, in one deferred replacement and
    #   restart (lich-5 GemCheck.verify_windows! with restart: true). The gate
    #   then executes that same set as one batch instead of sequencing it.
    # @param completed_restarts [Integer] native restarts already taken; a
    #   single-transaction consumer must finish in its one restart, so units
    #   still pending afterwards fail acceptance instead of starting another round.
    def self.next_plan(recovery, names, installed: ->(package) { !Gem::Specification.find_all_by_name(package.fetch('name'), "= #{package.fetch('version')}").empty? },
                       single_transaction: false, completed_restarts: 0)
      selected = recovery.recovery_plan(names)
      raise "recovery planning failed: #{selected.error}" unless selected.success?

      # Conservative all-members gate for consumers that replace at most one
      # native unit per recovery. Retire this restriction only when the gate
      # derives and executes each pinned consumer's actual startup sets; a
      # single-transaction consumer's startup set is the whole pending plan.
      if !single_transaction && selected.units.count { |unit| recovery.send(:native_runtime_unit?, unit) } > 1
        raise 'clean recovery acceptance supports at most one native runtime unit; sequencing must not hide an unsupported consumer plan'
      end

      pending = selected.units.reject { |unit| unit.fetch('packages').all? { |package| installed.call(package) } }
      return nil if pending.empty?

      if single_transaction
        if completed_restarts.positive?
          raise "single-transaction recovery left units pending after its restart: #{pending.map { |unit| unit.fetch('id', unit.fetch('members').join(',')) }.join(', ')}"
        end

        return selected.class.new(units: pending)
      end

      native, direct = pending.partition { |unit| recovery.send(:native_runtime_unit?, unit) }
      replacement = native.find { |unit| unit.fetch('members').include?('gtk3') } || native.first
      selected.class.new(units: direct + [replacement].compact)
    end
  end
end
