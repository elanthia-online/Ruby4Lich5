# frozen_string_literal: true

require 'json'
require 'digest'
require_relative 'gem_manifest_validator'
require_relative 'lifecycle_policy'

module Ruby4Lich5
  # Binds administrative approval to exact candidate and predecessor bytes.
  class PromotionPlan
    def self.digest(bytes)
      "sha256:#{Digest::SHA256.hexdigest(bytes)}"
    end

    def self.build(candidate_bytes:, live_bytes:, candidate_tag:, repository:, assets:, source_sha:, supported_startup_policy: nil)
      unless candidate_tag.match?(/\AR4L5-gem-bundle-x64-mingw-ucrt-candidate-[1-9]\d*-[1-9]\d*\z/) &&
             repository.match?(%r{\A[a-zA-Z0-9_.-]+/[a-zA-Z0-9_.-]+\z}) && source_sha.match?(/\A[0-9a-f]{40}\z/)
        raise ArgumentError, 'invalid candidate identity'
      end

      candidate = JSON.parse(candidate_bytes)
      candidate.fetch('targets').each do |target|
        contract = target['contract']
        if contract && (contract['promotable'] != true || contract['overrides'] != {})
          raise ArgumentError, 'override or diagnostic candidates cannot be promoted'
        end
      end
      live = JSON.parse(live_bytes)
      [candidate, live].each do |document|
        GemManifestValidator.validate!(document)
        keys = document.fetch('targets').map { |target| [target['ruby_abi'], target['platform']] }
        raise ArgumentError, 'duplicate runtime targets' unless keys.uniq == keys

        document.fetch('targets').each do |target|
          ids = target.fetch('units').map { |unit| unit.fetch('id') }
          raise ArgumentError, 'duplicate recovery unit identities' unless ids.uniq == ids
          sqlite = target.fetch('units').flat_map { |unit| unit.fetch('packages') }.select { |package| package['name'] == 'sqlite3' }
          if sqlite.empty? || sqlite.any? { |package| Gem::Version.new(package.fetch('version')) < Gem::Version.new('2.10.2') }
            raise ArgumentError, 'P1 sqlite3 2.10.2 recovery must be delivered before promotion/rollback'
          end
        end
      end
      before = units_by_target(live)
      after = units_by_target(candidate)
      raise ArgumentError, 'promotion cannot remove an existing ABI/platform target' unless (before.keys - after.keys).empty?

      before.each do |key, units|
        old_members = units.flat_map { |unit| unit.fetch('members') }.uniq
        new_members = after.fetch(key).flat_map { |unit| unit.fetch('members') }.uniq
        target = candidate.fetch('targets').find { |item| "#{item.fetch('ruby_abi')}/#{item.fetch('platform')}" == key }
        withdrawn = target.fetch('withdrawn_members', [])
        removed = old_members - new_members
        raise ArgumentError, 'withdrawal requires explicit lifecycle policy' unless (removed - withdrawn).empty?
        withdrawals = target.fetch('withdrawals', {})
        unless withdrawn.empty?
          LifecyclePolicy.new('schema' => 1, 'units' => withdrawals, 'ranges' => {}, 'range_reader' => nil)
          raise ArgumentError, 'withdrawal requires explicit lifecycle decisions' if withdrawals.empty?
          original = live.fetch('targets').find { |item| "#{item.fetch('ruby_abi')}/#{item.fetch('platform')}" == key }
          probe = { 'targets' => [original.merge('contract' => target['contract'])] }
          calculated = LifecyclePolicy.new('schema' => 1, 'units' => withdrawals, 'ranges' => {}, 'range_reader' => nil).apply({ 'targets' => [target] }, probe)
          unless calculated.fetch('targets').first.fetch('withdrawn_members') == withdrawn
            raise ArgumentError, 'withdrawal decisions do not cover exact removed members and orphan dependencies'
          end
        end
        old_target = live.fetch('targets').find { |item| "#{item.fetch('ruby_abi')}/#{item.fetch('platform')}" == key }
        raise ArgumentError, 'withdrawn recovery cannot be reintroduced' unless (old_target.fetch('withdrawn_members', []) - withdrawn).empty?
        units.select { |unit| unit.dig('lifecycle', 'state') == 'obsolete' }.each do |unit|
          next if withdrawals.key?(unit['id'])
          replacement = after.fetch(key).find { |item| item['id'] == unit['id'] }
          identical = replacement && replacement.reject { |field, _| field == 'lifecycle' } == unit.reject { |field, _| field == 'lifecycle' }
          first_freeze = unit['id'] == 'gtk3-runtime' && replacement && !unit.dig('artifact', 'filename').start_with?('R4L5-frozen-gtk-') &&
                         replacement.dig('artifact', 'filename').match?(/\AR4L5-frozen-gtk-[0-9a-f]{64}\.zip\z/) &&
                         replacement.reject { |field, _| %w[lifecycle artifact].include?(field) } == unit.reject { |field, _| %w[lifecycle artifact].include?(field) }
          raise ArgumentError, 'obsolete closures must retain their exact accepted bytes' unless identical || first_freeze
        end
        ranged_names = units.select { |unit| unit.key?('lich_versions') }.flat_map { |unit| unit.fetch('members') }
        units.reject { |unit| unit.key?('lich_versions') || (unit.fetch('members') & ranged_names).empty? }.each do |legacy|
          next if !(legacy.fetch('members') & withdrawn).empty?
          retained = after.fetch(key).find { |unit| unit['id'] == legacy['id'] }
          raise ArgumentError, 'retained range legacy closure changed' unless retained == legacy
        end
        if target.fetch('units').any? { |unit| unit.key?('lich_versions') }
          reader = target['range_reader']
          unless reader.is_a?(Hash) && reader['release'].is_a?(String) && reader['release'].match?(/\Av[0-9]+\.[0-9]+\.[0-9]+(?:[.-][a-zA-Z0-9.]+)?\z/) &&
                 reader['commit'].is_a?(String) && reader['commit'].match?(/\A[0-9a-f]{40}\z/)
            raise ArgumentError, 'ranges require an explicitly selected released reader'
          end
        end
      end
      expected_assets = assets.to_h { |asset| [asset.fetch('name'), asset.fetch('digest')] }
      raise ArgumentError, 'duplicate candidate assets' unless expected_assets.size == assets.size

      manifest_digest = digest(candidate_bytes)
      raise ArgumentError, 'candidate manifest asset digest differs' unless expected_assets['R4L5-gem-manifest.json'] == manifest_digest

      candidate.fetch('targets').each do |target|
        target.fetch('units').each do |unit|
          artifact = unit.fetch('artifact')
          prefix = "https://github.com/#{repository}/releases/download/#{candidate_tag}/"
          if artifact.fetch('url').start_with?(prefix)
            unless artifact.fetch('url') == prefix + artifact.fetch('filename') && expected_assets[artifact.fetch('filename')] == artifact.fetch('sha256')
              raise ArgumentError, 'candidate artifact identity differs from release metadata'
            end
          elsif !live.fetch('targets').flat_map { |item| item.fetch('units') }.any? { |old| old['artifact'] == artifact }
            unless artifact.fetch('url') == "https://rubygems.org/downloads/#{artifact.fetch('filename')}"
              raise ArgumentError, 'new artifacts must use this immutable candidate or original RubyGems downloads'
            end
          end
        end
      end
      changes = (before.keys | after.keys).map do |key|
        { 'target' => key, 'before' => before[key], 'after' => after[key] }
      end.reject { |change| change['before'] == change['after'] }
      rollback = LifecyclePolicy.rollback(live, candidate)
      GemManifestValidator.validate!(rollback)
      rollback_bytes = rollback == live ? live_bytes : JSON.pretty_generate(rollback) + "\n"
      approval = { 'rollback_sha256' => digest(rollback_bytes), 'candidate_sha256' => manifest_digest, 'live_sha256' => digest(live_bytes), 'changes' => changes }
      approval['supported_startup_policy'] = supported_startup_policy if supported_startup_policy
      approval.merge(
        'schema' => 1, 'candidate_tag' => candidate_tag, 'source_sha' => source_sha,
        'assets' => expected_assets.sort.to_h, 'change_sha256' => digest(JSON.generate(approval))
      )
    end

    def self.rollback_bytes(live_bytes, candidate_bytes)
      live = JSON.parse(live_bytes)
      rollback = LifecyclePolicy.rollback(live, JSON.parse(candidate_bytes))
      rollback == live ? live_bytes : JSON.pretty_generate(rollback) + "\n"
    end

    def self.approve!(plan, candidate_digest:, live_digest:, change_digest:)
      unless plan.fetch('candidate_sha256') == candidate_digest && plan.fetch('live_sha256') == live_digest && plan.fetch('change_sha256') == change_digest
        raise ArgumentError, 'approval does not match the exact candidate, predecessor and change report'
      end
    end

    def self.units_by_target(document)
      document.fetch('targets').to_h { |target| ["#{target.fetch('ruby_abi')}/#{target.fetch('platform')}", target.fetch('units')] }
    end
    private_class_method :units_by_target
  end
end
