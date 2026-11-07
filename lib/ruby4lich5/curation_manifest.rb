# frozen_string_literal: true

module Ruby4Lich5
  # Wraps the curation manifest's in-memory shape -- +gem x platform ->
  # {version:, tag:, asset:, checksum:}+ -- with the one query
  # {BuildPlanner} needs: is a given gem
  # already satisfied by what's currently pinned for a platform.
  #
  # Loading the manifest from wherever it actually lives (a Ruby4Lich5
  # release asset, once the publish mechanism from Phase 2 SS6 exists) is
  # deliberately out of scope here. This class takes already-parsed data
  # directly -- the same kind of seam {RubygemsClient} and {PatchApplier}'s
  # callers already use, so the on-disk manifest format can be decided when
  # the publish mechanism that actually writes it gets built, not guessed at
  # now.
  class CurationManifest
    # @param data [Hash] +gem_name => platform => {version:, tag:, asset:,
    #   checksum:}+ (or the same shape with String keys throughout, e.g.
    #   +"gem_name" => "platform" => {"version" => ...}+). Normalized once
    #   here rather than trusted as-is: +JSON.parse+ without
    #   +symbolize_names: true+ produces String keys at every level, and
    #   this manifest is explicitly meant to become a release asset loaded
    #   from parsed JSON. Without normalizing, +entry[:version]+ would
    #   silently always be +nil+ against a real parsed manifest, reporting
    #   every already-pinned gem as unsatisfied and triggering unnecessary
    #   rebuilds -- exactly the failure mode this exists to prevent.
    def initialize(data = {})
      @data = normalize(data)
    end

    # @param name [String] gem name
    # @param version [String] exact version to check
    # @param platform [String] target RubyGems platform tag
    # @return [Boolean] true if +name+ at +version+ is already the current
    #   pinned build for +platform+
    def satisfied?(name, version, platform)
      entry = @data.dig(name.to_s, platform.to_s)
      !entry.nil? && entry[:version] == version
    end

    private

    # @return [Hash{String => Hash{String => Hash}}] the same structure with
    #   String keys at the gem/platform levels and Symbol keys on the leaf
    #   +{version:, tag:, asset:, checksum:}+ hash, regardless of which key
    #   type the input used at any level
    def normalize(data)
      data.each_with_object({}) do |(gem_name, platforms), by_gem|
        by_gem[gem_name.to_s] = normalize_platforms(platforms)
      end
    end

    # @return [Hash{String => Hash}] +{}+ if +platforms+ isn't itself a Hash
    #   (e.g. a malformed manifest's gem-level entry is +nil+), rather than
    #   raising
    def normalize_platforms(platforms)
      return {} unless platforms.is_a?(Hash)

      platforms.each_with_object({}) do |(platform, entry), by_platform|
        by_platform[platform.to_s] = entry.is_a?(Hash) ? entry.transform_keys(&:to_sym) : {}
      end
    end
  end
end
