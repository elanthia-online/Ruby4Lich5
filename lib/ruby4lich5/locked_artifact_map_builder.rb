# frozen_string_literal: true

require 'rubygems/package'
require_relative 'rubygems_client'

module Ruby4Lich5
  # F2's central no-re-resolution boundary (docs/DECISIONS.md's "resolve
  # once" cutover) -- turns a real {ResolutionLock}'s own closure into one
  # sealed staging input: a +Hash{name => verified local .gem path}+,
  # covering every non-+ruby_bundled+ member. Nothing downstream of
  # {#build} ever touches {RubygemsClient}/{ClosureResolver} again; runtime
  # staging only ever installs *entries already in this map*, +--local+,
  # no dependency resolution.
  #
  # Delivery role comes from the lock's own classification, never a
  # separate hand-maintained list (the hardcoded +ox+/+curses+ repack loop
  # this replaces was already evidence the old +native-runtime-gems+ input
  # wasn't authoritative):
  # - **+native_self_contained+**: compiled/repacked locally -- this class
  #   never fetches these itself. The caller (the native build step) has
  #   already produced a +.gem+ file on disk; {#build} only verifies it.
  # - **+native_pass_through+**: fetched as the exact locked upstream
  #   platform gem.
  # - **+pure+**: fetched as the exact locked +ruby+-platform gem.
  # - **+ruby_bundled+**: excluded entirely -- no artifact, ever. Verified
  #   separately, against the bootstrapped Ruby's own installed
  #   specifications (see {StagedClosureRevalidator}), not staged at all.
  #
  # Every artifact -- self-contained, pass-through, and pure alike -- is
  # verified the same way before it can ever enter the map: open the
  # +.gem+'s own embedded gemspec and confirm its name/version/platform
  # actually match what the lock recorded. The self-contained path is the
  # highest-risk one (a stale build-cache entry, a wrong version compiled)
  # but the sealed-pipe guarantee has to hold for every local +.gem+, not
  # just that one -- a corrupted or short download for a pass-through/pure
  # gem is exactly as capable of silently shipping the wrong thing.
  class LockedArtifactMapBuilder
    # Raised when an artifact -- whether just-downloaded or supplied by
    # the caller as an already-built local file -- does not actually match
    # what the lock recorded for it (wrong name, version, or platform), or
    # can't be read as a real gem package at all.
    class VerificationError < StandardError; end

    # @param rubygems_client [RubygemsClient]
    def initialize(rubygems_client: RubygemsClient.new)
      @rubygems_client = rubygems_client
    end

    # @param closure [Array<Hash>] a {ResolutionLock}'s own +#closure+
    # @param platform [String] target RubyGems platform tag, e.g.
    #   +"x64-mingw-ucrt"+ -- the expected platform for every
    #   +native_pass_through+/+native_self_contained+ artifact;
    #   +pure+ artifacts are always expected at platform +"ruby"+
    #   regardless of this value
    # @param built_gem_paths [Hash{String => String}] name => local
    #   +.gem+ path, for every +native_self_contained+ closure member --
    #   the caller's own responsibility (the native build/repack step) to
    #   have produced *before* calling this; this class never compiles or
    #   repacks anything itself
    # @return [Hash{String => String}] name => verified local +.gem+
    #   path, one entry per non-+ruby_bundled+ closure member
    # @raise [VerificationError] if a +native_self_contained+ member has
    #   no corresponding entry in +built_gem_paths+, or if any artifact's
    #   own embedded gemspec doesn't match the lock's recorded
    #   name/version/expected platform
    # @raise [RubygemsClient::RequestError] if fetching a
    #   +pure+/+native_pass_through+ artifact fails -- deliberately not
    #   rescued here; matches every other caller of {RubygemsClient} in
    #   this project, which lets that class's own real-network-failure
    #   signal propagate to the CLI's own exit-code contract rather than
    #   wrapping it into a second, narrower error type
    def build(closure, platform:, built_gem_paths:)
      closure.reject { |entry| entry.fetch(:classification).ruby_bundled? }
             .each_with_object({}) { |entry, map| map[entry.fetch(:name)] = artifact_for(entry, platform, built_gem_paths) }
    end

    private

    # @return [String] verified local path
    def artifact_for(entry, platform, built_gem_paths)
      name = entry.fetch(:name)
      version = entry.fetch(:version)
      classification = entry.fetch(:classification)
      expected_platform = classification.pure? ? 'ruby' : platform

      path = if built_gem_paths.key?(name)
               built_gem_paths.fetch(name)
             elsif classification.self_contained?
               built_gem_paths.fetch(name) do
                 raise VerificationError,
                       "#{name}: locked as native_self_contained, but no built artifact was provided in built_gem_paths"
               end
             else
               @rubygems_client.download_gem(name, version, platform: expected_platform)
             end

      verify!(path, name: name, version: version, expected_platform: expected_platform)
      path
    end

    # @raise [VerificationError]
    def verify!(path, name:, version:, expected_platform:)
      spec = read_spec!(path, name)

      mismatches = []
      mismatches << "name #{spec.name.inspect} (expected #{name.inspect})" unless spec.name == name
      mismatches << "version #{spec.version.to_s.inspect} (expected #{version.inspect})" unless spec.version.to_s == version
      unless spec.platform.to_s == expected_platform
        mismatches << "platform #{spec.platform.to_s.inspect} (expected #{expected_platform.inspect})"
      end
      return if mismatches.empty?

      raise VerificationError, "#{name}: artifact at #{path} does not match the locked entry -- #{mismatches.join(', ')}"
    end

    # @return [Gem::Specification]
    # @raise [VerificationError]
    def read_spec!(path, name)
      Gem::Package.new(path).spec
    rescue Gem::Package::FormatError, Errno::ENOENT => e
      raise VerificationError, "#{name}: could not read a gem package's embedded spec from #{path}: #{e.message}"
    end
  end
end
