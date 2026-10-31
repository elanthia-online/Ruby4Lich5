# frozen_string_literal: true

module Ruby4Lich5
  # Acceptance must not hide a consumer's unsupported startup recovery plan.
  class RecoverySequence
    def self.next_plan(recovery, names, installed: ->(package) { !Gem::Specification.find_all_by_name(package.fetch('name'), "= #{package.fetch('version')}").empty? })
      selected = recovery.recovery_plan(names)
      raise "recovery planning failed: #{selected.error}" unless selected.success?

      # Conservative all-members gate. Retire this restriction only when the
      # gate derives and executes each pinned consumer's actual startup sets.
      if selected.units.count { |unit| recovery.send(:native_runtime_unit?, unit) } > 1
        raise 'clean recovery acceptance supports at most one native runtime unit; sequencing must not hide an unsupported consumer plan'
      end

      pending = selected.units.reject { |unit| unit.fetch('packages').all? { |package| installed.call(package) } }
      return nil if pending.empty?

      native, direct = pending.partition { |unit| recovery.send(:native_runtime_unit?, unit) }
      replacement = native.find { |unit| unit.fetch('members').include?('gtk3') } || native.first
      selected.class.new(units: direct + [replacement].compact)
    end
  end
end
