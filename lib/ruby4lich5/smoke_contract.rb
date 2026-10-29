# frozen_string_literal: true

require 'json'
require_relative 'resolution_lock'

module Ruby4Lich5
  # Every selected application root must have an explicit load obligation.
  class SmokeContract
    DEFINITIONS = File.expand_path('../../config/smoke-requires.json', __dir__)

    def self.for_lock(lock, definitions: JSON.parse(File.read(DEFINITIONS)))
      bundled = lock.closure.select { |entry| entry.fetch(:classification).ruby_bundled? }.map { |entry| entry.fetch(:name) }
      roots = lock.requested_roots.reject { |name, _version| bundled.include?(name) }.map do |name, version|
        paths = definitions[name]
        unless paths.is_a?(Array) && !paths.empty? && paths.all? { |path| path.is_a?(String) && path.match?(/\A[a-zA-Z0-9_\/-]+\z/) }
          raise ArgumentError, "selected root #{name} has no safe smoke require definition"
        end

        { 'name' => name, 'version' => version, 'requires' => paths }
      end
      raise ArgumentError, 'smoke contract has no application roots' if roots.empty?

      { 'schema' => 1, 'roots' => roots, 'gtk' => roots.any? { |entry| entry.fetch('name') == 'gtk3' } }
    end
  end
end
