# frozen_string_literal: true

require 'json'

module Ruby4Lich5
  # Shares the factory's reviewed build-only exclusions with delivery gates.
  module RuntimeInventory
    BUILD_TOOLING = JSON.parse(File.read(File.expand_path('../../config/runtime-build-tooling.json', __dir__))).map(&:freeze).freeze

    def self.entries(closure)
      closure.reject do |entry|
        entry.fetch(:classification).ruby_bundled? || BUILD_TOOLING.include?(entry.fetch(:name))
      end
    end
  end
end
