# frozen_string_literal: true

require_relative 'curated_gem_registry'

module Ruby4Lich5
  # Thin, read-only facade over {CuratedGemRegistry}. Retains
  # {KnownNativeGems}'s original method surface and exact contract ("is
  # this gem permitted to fall back to a self-build via curated MSYS2
  # packages") unchanged, so {Classifier} and every other existing caller
  # needs zero code changes -- only the data source moved, from hardcoded
  # constants in this file to the checked-in, reviewed
  # +config/curated-gems.json+.
  #
  # Deliberately narrower than "is this gem approved in the registry at
  # all" -- see {CuratedGemRegistry#self_build_packages_for}'s own doc
  # comment for the real bug this distinction closes (an approved
  # +native_pass_through+ gem, e.g. today's real `sqlite3`/`ffi`, must
  # never be mistaken for a self-build candidate).
  module KnownNativeGems
    # @return [String]
    SEED_PATH = File.expand_path('../../config/curated-gems.json', __dir__)
    private_constant :SEED_PATH

    # Loaded once per process, not per call -- matches how the constants
    # this replaced were effectively "loaded once," at require-time.
    #
    # @return [CuratedGemRegistry]
    def self.registry
      @registry ||= CuratedGemRegistry.load_file(SEED_PATH)
    end

    # @param gem_name [String]
    # @return [Boolean] true when this gem is curated for self-contained
    #   compilation
    def self.known?(gem_name)
      !packages_for(gem_name).nil?
    end

    # @param gem_name [String]
    # @return [Array<String>, nil] the MSYS2 packages needed to build
    #   +gem_name+, or +nil+ if it isn't curated for self-build (either
    #   entirely unapproved, or approved with some other classification --
    #   see {CuratedGemRegistry#self_build_packages_for})
    def self.packages_for(gem_name)
      registry.self_build_packages_for(gem_name)
    end
  end
end
