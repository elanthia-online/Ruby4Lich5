# frozen_string_literal: true

require 'json'
require 'digest'
require_relative '../../vendor/lich5/runtime_gem_contract'

module Ruby4Lich5
  # Producer side of the shared reader; no independently maintained gem list.
  class RuntimeContract
    Error = Lich::RuntimeGemContract::Error
    READER = File.expand_path('../../vendor/lich5/runtime_gem_contract.rb', __dir__)
    TARGET = File.expand_path('../../config/target-ruby.json', __dir__)

    attr_reader :data, :resolved, :pins, :roots, :registry

    def initialize(source_directory:, commit:, inventory:, registry:, gtk_version:, overrides: {}, selection: nil, target: JSON.parse(File.read(TARGET)))
      @registry = registry
      raise Error, 'lich-5 input requires a full commit SHA' unless commit.is_a?(String) && commit.match?(Lich::RuntimeGemContract::COMMIT)
      source_reader = File.join(source_directory, 'lib/runtime_gem_contract.rb')
      unless File.file?(source_reader) && Digest::SHA256.file(source_reader).hexdigest == Digest::SHA256.file(READER).hexdigest
        raise Error, 'selected lich-5 reader differs from the reviewed vendored reader'
      end
      reader = @reader = Lich::RuntimeGemContract.new(gemfile: File.binread(File.join(source_directory, 'Gemfile')), lockfile: File.binread(File.join(source_directory, 'Gemfile.lock')))
      unless inventory['ruby_version'] == target.fetch('ruby_installer_version').split('-').first && inventory['platform'] == target.fetch('platform') && inventory['ruby_abi'] == target.fetch('ruby_abi')
        raise Error, 'measured RubyInstaller inventory differs from target-ruby.json'
      end
      @resolved = reader.resolve(inventory)
      expected = resolved.fetch('packages')
      excluded = inventory.fetch('gems').keys | registry.names_for_role('gtk') | registry.names_for_role('tooling')
      locked = reader.locked_packages.reject { |name, _spec| excluded.include?(name) }
      runtime_roots = reader.roots.keys & expected.keys
      expected_roots = runtime_roots + ['gtk3']
      unless registry.bundle_default_roots.sort == expected_roots.sort
        raise Error, "registry roots differ from selected lich-5 roots: required=#{expected_roots.sort.inspect}, registered=#{registry.bundle_default_roots.sort.inspect}"
      end
      raise Error, 'GTK version has no reviewed immutable source' unless target.fetch('gtk_sources').key?(gtk_version)
      unless overrides.is_a?(Hash) && overrides.all? { |name, version| locked.key?(name) && version.is_a?(String) && !version.empty? && Gem::Version.correct?(version) }
        raise Error, 'overrides must map locked non-GTK names to explicit versions'
      end
      selected = selection.nil? || selection.empty? ? expected_roots : selection
      raise Error, 'selection may only name registry roots and must retain GTK in effort 3' unless (selected - expected_roots).empty? && selected.include?('gtk3') && selected.uniq == selected
      @pins = locked.transform_values { |spec| spec.fetch('version') }.merge(overrides)
      @roots = selected.to_h { |name| [name, name == 'gtk3' ? gtk_version : pins.fetch(name)] }
      @data = {
        'schema' => 2, 'lich5_commit' => commit, 'gemfile_sha256' => reader.gemfile_sha256, 'lock_sha256' => reader.lock_sha256,
        'ruby_installer_version' => target.fetch('ruby_installer_version'),
        'reader_sha256' => Digest::SHA256.file(READER).hexdigest,
        'ruby_inventory' => inventory, 'expected_packages' => expected, 'locked_packages' => locked, 'bundled_comparison' => resolved.fetch('bundled'),
        'gtk_source' => target.fetch('gtk_sources').fetch(gtk_version).merge('version' => gtk_version),
        'build_roles' => { 'gtk' => registry.names_for_role('gtk'), 'tooling' => registry.names_for_role('tooling') },
        'overrides' => overrides, 'selection' => selected.sort,
        'promotable' => overrides.empty? && selected.sort == expected_roots.sort && gtk_version == target.fetch('gtk_version')
      }
      record_windows_identity!(expected.keys)
    end

    # The final closure admits GTK-only non-GTK members without binding unused
    # development lock entries. Diagnostic selections remain unpromotable.
    def record_windows_identity!(members)
      data['windows_contract_sha256'] = @reader.windows_contract_digest(
        data.fetch('ruby_inventory'), build_roles: data.fetch('build_roles'), advertised_members: members
      )
    end

    def self.validate!(data, ruby_installer_version:, closure: nil)
      unless data.is_a?(Hash) && data['schema'] == 2 && data['lich5_commit'].is_a?(String) && data['lich5_commit'].match?(Lich::RuntimeGemContract::COMMIT) &&
             %w[gemfile_sha256 lock_sha256 reader_sha256 windows_contract_sha256].all? { |key| data[key].is_a?(String) && data[key].match?(Lich::RuntimeGemContract::SHA256) } &&
             data['overrides'].is_a?(Hash) && [true, false].include?(data['promotable']) &&
             data['ruby_inventory'].is_a?(Hash) && data.dig('ruby_inventory', 'gems').is_a?(Hash) &&
             data['build_roles'].is_a?(Hash) && data.dig('build_roles', 'gtk').is_a?(Array) &&
             data['ruby_installer_version'] == ruby_installer_version && data.dig('ruby_inventory', 'ruby_version') == ruby_installer_version.split('-').first &&
             data.dig('ruby_inventory', 'platform') == 'x64-mingw-ucrt' && data.dig('ruby_inventory', 'ruby_abi') == '4.0' &&
             valid_packages?(data['expected_packages']) && valid_packages?(data['locked_packages'])
        raise Error, 'invalid runtime contract metadata'
      end
      if data['promotable'] && !data['overrides'].empty?
        raise Error, 'override builds must be unpromotable'
      end
      if closure && data['promotable']
        by_name = closure.to_h { |entry| [entry.fetch(:name), entry] }
        missing = data.fetch('expected_packages').keys - by_name.keys
        raise Error, "contract closure is missing #{missing.join(', ')}" unless missing.empty?
        data.fetch('locked_packages').each do |name, spec|
          actual = by_name[name]
          next unless actual
          raise Error, "contract closure version mismatch for #{name}" unless actual && actual.fetch(:version) == spec.fetch('version')
          actual_dependencies = actual.fetch(:runtime_dependencies).to_h { |dep| [dep.fetch(:name), dep.fetch(:requirement)] }
          expected_dependencies = spec.fetch('dependencies').transform_values { |requirements| Gem::Requirement.new(requirements) }
          raise Error, "contract dependency graph mismatch for #{name}" unless actual_dependencies == expected_dependencies
        end
        allowed = data.fetch('locked_packages').keys | data.fetch('ruby_inventory').fetch('gems').keys | data.fetch('build_roles').fetch('gtk')
        unexpected = by_name.keys - allowed
        raise Error, "non-GTK closure packages are absent from the selected Windows lock: #{unexpected.join(', ')}" unless unexpected.empty?
      end
      true
    rescue KeyError, TypeError, ArgumentError => e
      raise Error, "invalid runtime contract: #{e.message}"
    end

    def self.valid_packages?(packages)
      packages.is_a?(Hash) && !packages.empty? && packages.all? do |name, spec|
        name.is_a?(String) && spec.is_a?(Hash) && spec['version'].is_a?(String) &&
          Gem::Version.correct?(spec['version']) && %w[ruby x64-mingw-ucrt].include?(spec['platform']) &&
          spec['sha256'].is_a?(String) && spec['sha256'].match?(Lich::RuntimeGemContract::SHA256) &&
          spec['dependencies'].is_a?(Hash) && spec['dependencies'].all? do |child, requirements|
            child.is_a?(String) && requirements.is_a?(Array) && requirements.all? { |value| value.is_a?(String) }
          end
      end
    end
    private_class_method :valid_packages?

    def self.require_promotable!(lock)
      validate!(lock.contract, ruby_installer_version: lock.ruby_installer_version, closure: lock.closure)
      raise Error, 'diagnostic or override build is unpromotable; update the lich-5 lock and rebuild' unless lock.contract.fetch('promotable') && lock.contract.fetch('overrides').empty?
      true
    end

    def report
      edits = data.fetch('overrides').map { |name, version| "#{name}: Gemfile.lock #{data.fetch('locked_packages').fetch(name).fetch('version')} -> #{version}; regenerate platform specs/checksums and dependent constraints" }
      { 'promotable' => data.fetch('promotable'), 'required_lich5_lock_edits' => edits,
        'bundled_comparison' => resolved.fetch('bundled'), 'selected_roots' => roots, 'build_tooling' => data.fetch('build_tooling', {}) }
    end
  end
end
