# frozen_string_literal: true

require 'digest'
require 'fileutils'
require_relative 'resolution_lock'
require_relative 'gem_manifest_validator'
require_relative 'patch_fingerprint'

module Ruby4Lich5
  # Reuse accepted bytes, never rebuild unchanged native packages. A changed
  # native dependency invalidates its containing build closure.
  #
  # A package also counts as changed when the accepted build is not proven to
  # have used the current curated patch set ({PatchFingerprint.reusable?}):
  # its fingerprint differs, or the accepted build recorded none while
  # +patches/<name>/+ exists today. That invalidates its closure exactly like
  # a changed native dependency.
  class ReplacementPlan
    # @param previous_lock [ResolutionLock] the accepted candidate's lock
    # @param lock [ResolutionLock] this run's lock
    # @param manifest [Hash] the accepted candidate's gem manifest
    # @param directory [String] the accepted bundle's extracted files
    # @param accepted_patches [Hash{String => String, nil}, nil] the accepted
    #   bundle's recorded +patch_fingerprints+ ({PatchFingerprint.read_metadata});
    #   +nil+ when it recorded none. Deliberately required: omitting it must
    #   not silently skip the patch check.
    # @param patches_root [String] the current tree's curated patches
    # @return [Hash] +reuse+, +rebuild+, +changed+, +removed+, plus
    #   +patch_changed+ (packages invalidated by their patches alone) and
    #   +patch_fingerprints+ (the record this run's bundle must carry: current
    #   fingerprints, except a reused package whose accepted build recorded
    #   none stays unrecorded)
    # @raise [ArgumentError] on contract, manifest or accepted-byte mismatch
    def self.build(previous_lock:, lock:, manifest:, directory:, accepted_patches:, patches_root: PatchFingerprint::DEFAULT_ROOT)
      RuntimeContract.require_promotable!(previous_lock)
      RuntimeContract.require_promotable!(lock)
      GemManifestValidator.validate!(manifest)
      raise ArgumentError, 'replacement target RubyInstaller must remain unchanged' unless previous_lock.ruby_installer_version == lock.ruby_installer_version && previous_lock.platform == lock.platform
      target = manifest.fetch('targets').find { |item| item['ruby_abi'] == lock.ruby_abi && item['platform'] == lock.platform }
      raise ArgumentError, 'accepted manifest differs from its resolution lock' unless target && target['contract'] == previous_lock.contract
      packages = target.fetch('units').flat_map { |unit| unit.fetch('packages') }
      previous = previous_lock.to_h.fetch('closure').to_h { |entry| [entry.fetch('name'), entry] }
      current = lock.to_h.fetch('closure').to_h { |entry| [entry.fetch('name'), entry] }
      changed = current.keys.select { |name| current[name] != previous[name] }
      PatchFingerprint.validate!(accepted_patches) unless accepted_patches.nil?
      fingerprints = PatchFingerprint.current(lock, patches_root: patches_root)
      patch_changed = fingerprints.reject { |name, fingerprint| PatchFingerprint.reusable?(accepted_patches, name, fingerprint) }.keys
      changed |= patch_changed
      loop do
        invalidated = current.values.select do |entry|
          entry.dig('classification', 'state') == 'native_self_contained' && entry.fetch('runtime_dependencies').any? { |dep| changed.include?(dep.fetch('name')) }
        end.map { |entry| entry.fetch('name') }
        expanded = changed | invalidated
        break if expanded == changed
        changed = expanded
      end
      gtk = lock.contract.fetch('build_roles').fetch('gtk')
      changed |= gtk unless (changed & gtk).empty?
      reuse = {}
      lock.closure.reject { |entry| entry.fetch(:classification).ruby_bundled? || changed.include?(entry.fetch(:name)) }.each do |entry|
        name = entry.fetch(:name)
        matches = packages.select { |package| package['name'] == name && package['version'] == entry.fetch(:version) }
        identities = matches.map { |package| package.fetch('sha256') }.uniq
        raise ArgumentError, "accepted map missing or ambiguous for #{name}" unless identities.length == 1
        package = matches.first
        path = File.join(directory, package.fetch('filename'))
        # Individual native release names differ from the bundle's gem name.
        platform = entry.fetch(:classification).pure? ? '' : "-#{lock.platform}"
        staged = "#{name}-#{entry.fetch(:version)}#{platform}.gem"
        path = File.join(directory, staged) unless File.file?(path)
        raise ArgumentError, "accepted package bytes differ for #{name}" unless File.file?(path) && "sha256:#{Digest::SHA256.file(path).hexdigest}" == package.fetch('sha256')
        reuse[name] = { 'path' => File.expand_path(path), 'filename' => staged, 'sha256' => package.fetch('sha256') }
      end
      native = lock.closure.select { |entry| entry.fetch(:classification).self_contained? }.map { |entry| entry.fetch(:name) }
      record = fingerprints.reject { |name, _| reuse.key?(name) && !accepted_patches&.key?(name) }
      { 'schema' => 1, 'reuse' => reuse, 'rebuild' => native - reuse.keys, 'changed' => changed.sort,
        'removed' => (previous.keys - current.keys).sort, 'patch_changed' => patch_changed.sort,
        'patch_fingerprints' => record }
    end

    # Installer relay metadata changes each run. Keep served artifact bytes
    # stable when only a D1 unit changed; a real shared-ZIP package change
    # moves all ZIP-backed units together.
    def self.retain_artifacts!(manifest, previous)
      manifest.fetch('targets').each do |target|
        old = previous.fetch('targets').find { |item| item.values_at('ruby_abi', 'platform') == target.values_at('ruby_abi', 'platform') }
        next unless old
        before = old.fetch('units')
        if before.any? { |unit| unit.key?('lich_versions') }
          before = Lich::RecoveryUnitPolicy.select(old, target.dig('contract', 'lich_version'))
        end
        after = target.fetch('units')
        zip_inventory = lambda do |units|
          units.select { |unit| unit.dig('artifact', 'archive') == 'zip' && !unit['lifecycle'] }
               .flat_map { |unit| unit.fetch('packages') }
               .map { |package| package.values_at('name', 'version', 'filename', 'sha256') }.uniq.sort
        end
        zip_changed = zip_inventory.call(before) != zip_inventory.call(after)
        after.each do |unit|
          accepted = before.find { |item| item['id'] == unit['id'] || item['legacy_unit'] == unit['id'] }
          next unless accepted && retained_shape(accepted) == retained_shape(unit)
          next if unit.dig('artifact', 'archive') == 'zip' && zip_changed
          unit['artifact'] = accepted.fetch('artifact').dup
        end
      end
      manifest
    end

    # Startup policy keys (a minimum, the self_build_equivalent flag) do not
    # change the served bytes, so they alone never move an artifact.
    def self.retained_shape(unit)
      packages = unit.fetch('packages').map { |package| package.except(*PackagePolicy::KEYS) }
      [unit.fetch('members'), packages, unit.fetch('install_order')]
    end
    private_class_method :retained_shape

    def self.verify_staged!(plan, directory)
      plan.fetch('reuse').each do |name, entry|
        path = File.join(directory, entry.fetch('filename'))
        unless File.file?(path) && "sha256:#{Digest::SHA256.file(path).hexdigest}" == entry.fetch('sha256')
          raise ArgumentError, "unrelated accepted package changed during replacement: #{name}"
        end
      end
      true
    end
  end
end
