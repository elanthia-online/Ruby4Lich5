# frozen_string_literal: true

module Ruby4Lich5
  # Legacy consumers permit one native replacement suite per recover call.
  # Keep their actual selected units and validation; batch direct units with
  # at most one native suite, preferring GTK before helpers validate Gtk.init.
  class RecoverySequence
    def self.next_plan(recovery, names, installed: ->(package) { !Gem::Specification.find_all_by_name(package.fetch('name'), "= #{package.fetch('version')}").empty? })
      selected = recovery.recovery_plan(names)
      raise "recovery planning failed: #{selected.error}" unless selected.success?

      pending = selected.units.reject { |unit| unit.fetch('packages').all? { |package| installed.call(package) } }
      return nil if pending.empty?

      native, direct = pending.partition { |unit| recovery.send(:native_runtime_unit?, unit) }
      replacement = native.find { |unit| unit.fetch('members').include?('gtk3') } || native.first
      selected.class.new(units: direct + [replacement].compact)
    end
  end
end
