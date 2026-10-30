# frozen_string_literal: true

require 'digest'
require_relative 'gem_manifest_generator'
require_relative 'staged_gem_spec_finder'
require_relative 'runtime_contract'

module Ruby4Lich5
  # One accepted local/upstream acquisition map for ZIP, installer and gate.
  class DeliveryMap
    def self.build(lock, pkg_dir)
      shipped = lock.closure.reject { |entry| entry.fetch(:classification).ruby_bundled? }
      names = shipped.map { |entry| entry.fetch(:name) }
      nodes = InstalledGemClosure.new(
        requested_names: lock.requested_roots.keys & names,
        excluded_names: lock.closure.map { |entry| entry.fetch(:name) } - names,
        find_specs: StagedGemSpecFinder.new(pkg_dir: pkg_dir)
      ).resolve
      roots = GemManifestGenerator.roots_for(lock.requested_roots.keys & names)
      groups = GemUnitGrouper.new(closure_nodes: nodes, roots: roots).units
      multi_names = groups.select { |group| group.fetch(:members).length > 1 }.flat_map { |group| group.fetch(:members) }.uniq
      entries = shipped.map do |entry|
        name, version = entry.values_at(:name, :version)
        state = entry.fetch(:classification)
        platform = state.pure? ? 'ruby' : lock.platform
        filename = "#{name}-#{version}#{platform == 'ruby' ? '' : "-#{platform}"}.gem"
        digest = Digest::SHA256.file(File.join(pkg_dir, filename)).hexdigest
        upstream = !state.self_contained? && !multi_names.include?(name)
        expected = lock.contract&.dig('locked_packages', name)
        if expected && lock.contract.fetch('promotable') && !state.self_contained? && expected.fetch('sha256') != digest
          raise RuntimeContract::Error, "staged upstream package differs from selected lich-5 lock checksum: #{name}"
        end
        { 'name' => name, 'version' => version, 'platform' => platform, 'filename' => filename, 'sha256' => digest,
          'delivery' => upstream ? 'upstream' : 'bundle',
          'url' => upstream ? "https://rubygems.org/downloads/#{filename}" : nil }
      end
      { 'schema' => 1, 'packages' => entries }
    end
  end
end
