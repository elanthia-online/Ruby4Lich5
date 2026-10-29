# frozen_string_literal: true

require 'json'
require 'digest'
require_relative 'gem_manifest_validator'

module Ruby4Lich5
  # Binds administrative approval to exact candidate and predecessor bytes.
  class PromotionPlan
    def self.digest(bytes)
      "sha256:#{Digest::SHA256.hexdigest(bytes)}"
    end

    def self.build(candidate_bytes:, live_bytes:, candidate_tag:, repository:, assets:, source_sha:)
      unless candidate_tag.match?(/\AR4L5-gem-bundle-x64-mingw-ucrt-candidate-[1-9]\d*-[1-9]\d*\z/) &&
             repository.match?(%r{\A[a-zA-Z0-9_.-]+/[a-zA-Z0-9_.-]+\z}) && source_sha.match?(/\A[0-9a-f]{40}\z/)
        raise ArgumentError, 'invalid candidate identity'
      end

      candidate = JSON.parse(candidate_bytes)
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
        raise ArgumentError, 'withdrawal requires the later lifecycle policy' unless (old_members - new_members).empty?
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
      approval = { 'candidate_sha256' => manifest_digest, 'live_sha256' => digest(live_bytes), 'changes' => changes }
      approval.merge(
        'schema' => 1, 'candidate_tag' => candidate_tag, 'source_sha' => source_sha,
        'assets' => expected_assets.sort.to_h, 'change_sha256' => digest(JSON.generate(approval))
      )
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
