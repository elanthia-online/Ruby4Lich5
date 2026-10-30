# frozen_string_literal: true

require 'json'
require_relative '../../vendor/lich5/recovery_unit_policy'

module Ruby4Lich5
  # Explicit reviewed transitions only; reaching a date/floor never withdraws
  # a unit by itself. Historical artifacts are never changed or deleted.
  class LifecyclePolicy
    PATH = File.expand_path('../../config/gem-lifecycle.json', __dir__)
    Error = Lich::RecoveryUnitPolicy::Error

    def initialize(data = JSON.parse(File.read(PATH)))
      unless data.is_a?(Hash) && data['schema'] == 1 && (data.keys - %w[schema units ranges range_reader]).empty? &&
             data['units'].is_a?(Hash) && data['ranges'].is_a?(Hash)
        raise Error, 'invalid lifecycle policy'
      end
      @data = data
      data.fetch('units').each do |id, rule|
        unless id.match?(Lich::RecoveryUnitPolicy::NAME) && rule.is_a?(Hash) && %w[obsolete withdrawn].include?(rule['state']) &&
               (rule.keys - %w[state until_date floor_lich_version roots freeze]).empty?
          raise Error, 'invalid lifecycle transition'
        end
        if rule.key?('freeze') && !(id == 'gtk3-runtime' && rule['state'] == 'obsolete' && rule['freeze'] == true)
          raise Error, 'freeze is reserved for an explicit obsolete GTK transition'
        end
        Lich::RecoveryUnitPolicy.validate_lifecycle!(rule.reject { |key, _| %w[roots freeze].include?(key) }.merge('state' => 'obsolete'))
        next unless rule['state'] == 'withdrawn'
        unless (rule.key?('until_date') || rule.key?('floor_lich_version')) && rule['roots'].is_a?(Array) &&
               !rule['roots'].empty? && rule['roots'].all? { |name| name.is_a?(String) && name.match?(Lich::RecoveryUnitPolicy::NAME) }
          raise Error, 'withdrawal requires an explicit support boundary and root names'
        end
      end
    end

    def apply(current, previous, today: Date.today)
      result = Marshal.load(Marshal.dump(current))
      raise Error, 'lifecycle assembly requires one current runtime target' unless result.fetch('targets').length == 1
      target = result.fetch('targets').first
      old = previous&.fetch('targets')&.find { |item| item.values_at('ruby_abi', 'platform') == target.values_at('ruby_abi', 'platform') }
      rules = @data.fetch('units')
      raise Error, 'lifecycle transitions require the accepted predecessor' if !rules.empty? && !old
      old_units = old ? old.fetch('units') : []
      unknown = rules.keys - old_units.map { |unit| unit.fetch('id') } - (old&.fetch('withdrawals', {}) || {}).keys
      raise Error, "unknown lifecycle unit(s): #{unknown.join(', ')}" unless unknown.empty?
      units = target.fetch('units')
      old_units.each do |unit|
        rule = rules[unit.fetch('id')] || unit['lifecycle']
        next unless rule && rule['state'] == 'obsolete'
        units.reject! { |item| item['id'] == unit['id'] }
        units.unshift(unit.merge('lifecycle' => rule.reject { |key, _| %w[roots freeze].include?(key) }))
      end
      withdrawals = rules.select { |_id, rule| rule['state'] == 'withdrawn' }
      withdrawals.each_value do |rule|
        if rule['floor_lich_version']
          version = target.dig('contract', 'lich_version')
          unless version && Gem::Version.correct?(version) && Gem::Version.new(version) >= Gem::Version.new(rule['floor_lich_version'])
            raise Error, 'withdrawal floor has not been reached by the selected Lich contract'
          end
        end
        if rule['until_date'] && today < Date.iso8601(rule['until_date'])
          raise Error, 'withdrawal end date has not been reached'
        end
      end
      roots = withdrawals.values.flat_map { |rule| rule.fetch('roots') }
      units.reject! { |unit| withdrawals.key?(unit['id']) || !(unit.fetch('members') & roots).empty? }
      surviving = units.flat_map { |unit| unit.fetch('members') }.uniq
      removed = old_units.select { |unit| withdrawals.key?(unit['id']) || !(unit.fetch('members') & roots).empty? }.flat_map { |unit| unit.fetch('members') }
      withdrawn = (Array(old && old['withdrawn_members']) | roots | (removed - surviving)).sort
      target['withdrawn_members'] = withdrawn unless withdrawn.empty?
      target['withdrawals'] = (old&.fetch('withdrawals', {}) || {}).merge(withdrawals) unless withdrawals.empty? && !old&.key?('withdrawals')
      expanded = {}
      @data.fetch('ranges').each do |id, range|
        seed = units.find { |item| item['id'] == id }
        raise Error, "range names unknown unit #{id}" unless seed
        component = [seed]
        loop do
          names = component.flat_map { |item| item.fetch('members') }
          connected = units.select { |item| !(item.fetch('members') & names).empty? }
          break if connected == component
          component = connected
        end
        component.each do |unit|
          key = unit.fetch('id')
          raise Error, 'shared closures require the same Lich range' if expanded.key?(key) && expanded[key] != range
          expanded[key] = range
        end
      end
      replacements = units.select { |unit| expanded.key?(unit['id']) }
      unless replacements.empty?
        raise Error, 'ranges require a legacy predecessor' unless old
        names = replacements.flat_map { |unit| unit.fetch('members') }
        legacy = old_units.select { |item| !item.key?('lich_versions') && !(item.fetch('members') & names).empty? }
        raise Error, 'range has no legacy closure' if legacy.empty?
        units.reject! { |unit| expanded.key?(unit['id']) }
        units.unshift(*legacy.reject { |item| units.any? { |existing| existing['id'] == item['id'] } })
        replacements.each { |unit| units << unit.merge('id' => "#{unit.fetch('id')}-ranged", 'lich_versions' => expanded.fetch(unit['id']), 'legacy_unit' => unit.fetch('id')) }
      end
      target['range_reader'] = @data['range_reader'] if units.any? { |unit| unit.key?('lich_versions') }
      Lich::RecoveryUnitPolicy.validate!(target)
      missing = old_units.flat_map { |unit| unit.fetch('members') }.uniq - units.flat_map { |unit| unit.fetch('members') }.uniq - withdrawn
      raise Error, "unsupported coverage removal: #{missing.join(', ')}" unless missing.empty?
      result
    end

    def self.rollback(previous, candidate)
      result = Marshal.load(Marshal.dump(previous))
      result.fetch('targets').each do |target|
        current = candidate.fetch('targets').find { |item| item.values_at('ruby_abi', 'platform') == target.values_at('ruby_abi', 'platform') }
        withdrawn = current&.fetch('withdrawn_members', []) || []
        next if withdrawn.empty?
        target.fetch('units').reject! do |unit|
          !((unit.fetch('members') | unit.fetch('packages').map { |package| package.fetch('name') }) & withdrawn).empty?
        end
        target['withdrawn_members'] = withdrawn
        target['withdrawals'] = current.fetch('withdrawals')
      end
      result
    end
  end
end
