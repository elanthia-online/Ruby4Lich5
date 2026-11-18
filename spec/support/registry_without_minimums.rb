# frozen_string_literal: true

require 'json'
require_relative '../../lib/ruby4lich5/known_native_gems'

# The real curated registry with every package +minimum+ removed. Generator
# and CLI fixtures build packages at placeholder versions such as 1.0, so a
# real configured minimum would sit "above its version" and stop
# generation. Those examples test generation, not which packages opt into a
# floor, so they use this registry; opting a package into a minimum leaves
# them unchanged. Specs that pin the real configuration (the live-manifest
# policy examples, the seed projection) keep using the real registry.
module RegistryWithoutMinimums
  # Loaded with `ruby -r` before bin/generate_gem_manifest.rb, so the CLI
  # subprocess reads this registry in place of the real one. Never loaded in
  # the spec process itself.
  PRELOAD = File.expand_path('registry_without_minimums_preload.rb', __dir__)
  # The file KnownNativeGems.registry loads (its SEED_PATH is private).
  CONFIG_PATH = File.expand_path('../../config/curated-gems.json', __dir__)

  # @return [Ruby4Lich5::CuratedGemRegistry]
  def self.registry
    document = JSON.parse(File.read(CONFIG_PATH))
    document.fetch('gems').each_value do |entry|
      entry.fetch('targets', {}).each_value { |abis| abis.each_value { |target| target.delete('minimum') } }
    end
    Ruby4Lich5::CuratedGemRegistry.new(document)
  end
end
