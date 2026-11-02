# frozen_string_literal: true

require 'digest'
require_relative 'known_native_gems'
require_relative 'installed_gem_closure'
require_relative 'gem_unit_grouper'
require_relative 'digest_format'

module Ruby4Lich5
  # Builds the gem recovery manifest Lich's self-heal reads, per
  # docs/DECISIONS.md Phase 13 SS2/SS3 and docs/r4l5-gem-recovery-manifest.md
  # (lich-5, the schema this feeds).
  #
  # Root-declaration policy, locked 2026-07-10 (not derived from the
  # dependency graph, stated explicitly so the same drift the hand-built
  # predecessor manifest had -- concurrent-ruby getting a standalone unit,
  # tzinfo not, purely by omission -- can't recur silently):
  #   ordinary root      -> unit id equals the root's own name
  #   declared group      -> explicit unit id (today: only the GTK3 stack,
  #                          {GTK3_STACK} -> +"gtk3-runtime"+)
  #   unit package list    -> the complete, self-contained runtime closure
  #                          reachable from that root, independent of id
  class GemManifestGenerator
    # Raised when a pure or native_pass_through gem's locally-staged digest
    # doesn't match what RubyGems.org currently reports for that exact
    # name+version+platform, or when RubyGems.org's own digest is
    # missing/malformed -- a real, deterministic problem, never papered over
    # (docs/DECISIONS.md Phase 13 SS3).
    class DigestValidationError < StandardError; end

    # Raised when a resolved closure member has no recorded delivery state,
    # or one outside {ACCEPTED_DELIVERY_STATES} -- this class never guesses a
    # default; every staged member must be explicitly accounted for by the
    # caller's own +delivery_states_by_name+.
    class UnknownDeliveryStateError < StandardError; end

    # The one declared grouping exception -- every other top-level requested
    # name gets its own standalone-by-default unit. Order matters here only
    # for install_order *within* this group; membership in the closure
    # (matrix, red-colors) is discovered, the ten names themselves are not.
    #
    # @return [Array<String>]
    GTK3_STACK = KnownNativeGems.registry.names_for_role('gtk').freeze

    # The three delivery kinds a staged closure member can be -- a fourth
    # real {Classification} state, +ruby_bundled+, never reaches this class
    # at all (never staged, no artifact; see the caller's own responsibility
    # to exclude it building +delivery_states_by_name+).
    #
    # @return [Array<String>]
    ACCEPTED_DELIVERY_STATES = %w[native_self_contained native_pass_through pure].freeze

    SCHEMA_VERSION = 1
    private_constant :SCHEMA_VERSION

    # @param root_names [Array<String>] every top-level requested root name
    #   -- e.g. a resolved {ResolutionLock}'s own +requested_roots+ keys.
    #   When GTK is selected, includes +"gtk3"+ itself (grouped into the declared "gtk3-runtime"
    #   unit below, see {#roots}), never its individual {GTK3_STACK}
    #   sub-members -- those are transitive closure members, not requested
    #   roots, and are discovered via +excluded_names+/the closure resolver
    #   the same way they always were.
    # @param delivery_states_by_name [Hash{String => String}] every staged
    #   closure member's own locked delivery state -- one of
    #   {ACCEPTED_DELIVERY_STATES} -- the caller's responsibility to derive
    #   from a {ResolutionLock}'s own closure (excluding +ruby_bundled+
    #   members, which are never staged and never appear here). This class
    #   never deserializes a lock itself, matching every other class in this
    #   project's own injection-seam discipline.
    # @param excluded_names [Array<String>] passed straight through to
    #   {InstalledGemClosure}
    # @param ruby_abi [String] e.g. +"4.0"+
    # @param platform [String] e.g. +"x64-mingw-ucrt"+
    # @param repo [String] +"owner/repo"+, for constructing release URLs
    # @param bundle_asset [Hash] +{tag:, filename:, sha256:}+ for the
    #   already-published gem-bundle zip this run just verified. +tag+ is
    #   this specific run's own release tag (the live tag, a draft still
    #   sharing the live tag name, or a "-candidate" tag) -- never assumed
    #   to be the live tag, since a manifest generated from a candidate's
    #   own staging set must say so explicitly (real bug, found in review
    #   2026-07-10: hardcoding the live tag here let a candidate-produced
    #   manifest's package list and its own artifact URL describe two
    #   different sets of bytes -- the live zip's, not the candidate's).
    # @param pkg_dir [String] local directory containing every staged +.gem+
    #   file, native and pure alike, by their staged (non-R4L5-prefixed)
    #   filename
    # @param native_digest_lookup [#call] +->(name, version) { "sha256:..." }+
    #   -- fetches the already-published, already-verified digest for a
    #   native_self_contained gem's own individual release (Phase 12/13
    #   SS2). Real implementation is a caller concern (a +gh api+ call);
    #   this class only declares the shape it needs.
    # @param rubygems_client [RubygemsClient] used to cross-validate a
    #   pure/native_pass_through gem's locally-computed digest against
    #   RubyGems.org's own reported value at generation time (Phase 13 SS3)
    # @param closure_resolver [InstalledGemClosure, nil] injected for specs;
    #   defaults to a real one built from the given names/excludes
    # @param native_release_tag [String, nil] immutable candidate tag hosting
    #   native gem files; nil retains legacy per-gem release URLs
    def initialize(root_names:, delivery_states_by_name:, ruby_abi:, platform:, repo:, bundle_asset:, pkg_dir:,
                   native_digest_lookup:, rubygems_client:, excluded_names: [], closure_resolver: nil,
                   native_release_tag: nil)
      @root_names = root_names
      @delivery_states_by_name = delivery_states_by_name
      @ruby_abi = ruby_abi
      @platform = platform
      @repo = repo
      @bundle_asset = bundle_asset
      @pkg_dir = pkg_dir
      @native_digest_lookup = native_digest_lookup
      @native_release_tag = native_release_tag
      @rubygems_client = rubygems_client
      @closure_resolver = closure_resolver || InstalledGemClosure.new(
        requested_names: root_names, excluded_names: excluded_names
      )
    end

    # @return [Hash] the full manifest document, ready for +JSON.generate+
    # @raise [DigestValidationError]
    def generate
      # Reset here, not lazily inside native_digest_for -- real bug, found
      # in review 2026-07-11: a lazy `||= {}` there persists across every
      # call to #generate on the same instance, meaning a second real
      # generation run would silently reuse the first run's cached digests
      # even if the injected lookup would now return something different.
      # Memoization is meant to scope to *one* generation run, not the
      # object's whole lifetime.
      @native_digest_cache = {}

      closure_nodes = @closure_resolver.resolve
      validate_delivery_states!(closure_nodes)
      grouped = GemUnitGrouper.new(closure_nodes: closure_nodes, roots: roots).units
      by_name = closure_nodes.each_with_object({}) { |node, index| index[node.fetch(:name)] = node }

      units = grouped.map { |group| build_unit(group, by_name) }

      { 'schema'  => SCHEMA_VERSION,
        'targets' => [{ 'ruby_abi' => @ruby_abi, 'platform' => @platform, 'units' => units }] }
    end

    # @return [Array<GemUnitGrouper::Root>]
    def self.roots_for(root_names)
      ordinary = (root_names - GTK3_STACK).map do |name|
        GemUnitGrouper::Root.new(id: name, start_names: [name])
      end
      gtk = root_names.any? { |name| GTK3_STACK.include?(name) } ? [GemUnitGrouper::Root.new(id: 'gtk3-runtime', start_names: GTK3_STACK)] : []
      gtk + ordinary
    end

    private

    # Every resolved closure member must carry exactly one accepted
    # delivery state -- checked here, once the real closure is known,
    # rather than at construction time (+delivery_states_by_name+ is keyed
    # by the whole lock's closure; only {#generate} knows which of those
    # names are actually staged/resolved for *this* run).
    #
    # @raise [UnknownDeliveryStateError]
    def validate_delivery_states!(closure_nodes)
      bad = closure_nodes.filter_map do |node|
        name = node.fetch(:name)
        state = @delivery_states_by_name[name]
        next if ACCEPTED_DELIVERY_STATES.include?(state)

        "#{name.inspect}: #{state.nil? ? 'no delivery state recorded' : "unrecognized delivery state #{state.inspect}"}"
      end
      return if bad.empty?

      raise UnknownDeliveryStateError, "closure member(s) with missing/unrecognized delivery state:\n#{bad.join("\n")}"
    end

    def roots
      self.class.roots_for(@root_names)
    end

    # @param group [Hash] one {GemUnitGrouper#units} entry
    # @param by_name [Hash{String => Hash}] closure nodes by name
    # @return [Hash] one manifest "units" entry
    def build_unit(group, by_name)
      members = group.fetch(:members)
      packages = members.map { |name| build_package(by_name.fetch(name)) }
      artifact = artifact_for(members, by_name, packages)
      packages.first['filename'] = artifact.fetch('filename') if artifact.fetch('archive') == 'gem'

      { 'id'            => group.fetch(:id),
        'members'       => members,
        'artifact'      => artifact,
        'packages'      => packages,
        'install_order' => group.fetch(:install_order) }
    end

    # @param members [Array<String>]
    # @param by_name [Hash{String => Hash}] closure nodes by name
    # @param packages [Array<Hash>] already-digest-verified package entries
    # @return [Hash] original upstream file for a single pass-through binary,
    #   immutable R4L5 artifact for a single built gem, bundle zip otherwise
    def artifact_for(members, by_name, packages)
      # D1: unmodified single packages retain their original upstream URL.
      if members.length == 1 && %w[native_pass_through pure].include?(delivery_state_for(members.first))
        package = packages.first
        return { 'url' => "https://rubygems.org/downloads/#{package.fetch('filename')}", 'filename' => package.fetch('filename'),
                 'sha256' => package.fetch('sha256'), 'archive' => 'gem' }
      end

      return bundle_artifact unless members.length == 1 && individually_published?(members.first)

      name = members.first
      version = by_name.fetch(name).fetch(:version)
      filename = "R4L5-#{name}-#{version}-#{@platform}.gem"
      tag = @native_release_tag || "R4L5-#{name}-#{version}-#{@platform}"
      { 'url'      => "https://github.com/#{@repo}/releases/download/#{tag}/#{filename}",
        'filename' => filename,
        'sha256'   => native_digest_for(name, version),
        'archive'  => 'gem' }
    end

    # @return [Hash]
    def bundle_artifact
      tag = @bundle_asset.fetch(:tag)
      { 'url'      => "https://github.com/#{@repo}/releases/download/#{tag}/#{@bundle_asset.fetch(:filename)}",
        'filename' => @bundle_asset.fetch(:filename),
        'sha256'   => @bundle_asset.fetch(:sha256),
        'archive'  => 'zip' }
    end

    # @param node [Hash] one closure entry, +{name:, version:, ...}+
    # @return [Hash] one manifest "packages" entry
    def build_package(node)
      name = node.fetch(:name)
      version = node.fetch(:version)

      case delivery_state_for(name)
      when 'native_self_contained'
        filename = "#{name}-#{version}-#{@platform}.gem"
        digest = native_digest_for(name, version)
      when 'native_pass_through'
        filename = "#{name}-#{version}-#{@platform}.gem"
        digest = rubygems_verified_digest_for(name, version, filename, rubygems_platform: @platform)
      when 'pure'
        filename = "#{name}-#{version}.gem"
        digest = rubygems_verified_digest_for(name, version, filename, rubygems_platform: 'ruby')
      end

      { 'name' => name, 'version' => version, 'filename' => filename, 'sha256' => digest }
    end

    # Memoized by (name, version) within the current #generate run (the
    # cache itself is reset at the top of #generate, not created lazily
    # here) -- a standalone single-native-member unit (sqlite3, ox, curses,
    # ffi) previously called +@native_digest_lookup+ twice for the identical
    # pair, once from {#artifact_for} and once more from {#build_package}.
    # Real, found in review 2026-07-11: the real lookup shells out to
    # +gh api+ per call, so this was two live network round-trips for one
    # fact, for each of those four gems, every run.
    #
    # @param name [String]
    # @param version [String]
    # @return [String] +"sha256:<64 lowercase hex>"+
    def native_digest_for(name, version)
      @native_digest_cache[[name, version]] ||= @native_digest_lookup.call(name, version)
    end

    # @param name [String]
    # @return [String] one of {ACCEPTED_DELIVERY_STATES} -- safe to +fetch+
    #   without rescue here, since {#generate} already validated every
    #   closure member's name against this same Hash before any of this
    #   class's other private methods run
    def delivery_state_for(name)
      @delivery_states_by_name.fetch(name)
    end

    # @param name [String]
    # @return [Boolean] true only for +native_self_contained+ -- the one
    #   state that gets its own individual R4L5 release when standalone.
    #   +native_pass_through+ uses the upstream file without an R4L5 release.
    def individually_published?(name)
      delivery_state_for(name) == 'native_self_contained'
    end

    # Computes the real digest of the staged file, then validates it against
    # RubyGems.org's own reported digest for this exact name+version+platform
    # -- compute, then validate, per docs/DECISIONS.md Phase 13 SS3. Never
    # copies RubyGems.org's value directly into the manifest without this
    # check: the staged file is what's actually shipped, and only a real
    # local hash proves it matches what it claims to be. Shared by +pure+
    # (+rubygems_platform: 'ruby'+) and +native_pass_through+
    # (+rubygems_platform: @platform+) -- both are "trust, but verify, an
    # already-published upstream artifact," differing only in which
    # platform's published build they're being checked against.
    #
    # @param name [String]
    # @param version [String]
    # @param filename [String]
    # @param rubygems_platform [String]
    # @return [String] +"sha256:<64 lowercase hex>"+
    # @raise [DigestValidationError]
    def rubygems_verified_digest_for(name, version, filename, rubygems_platform:)
      path = File.join(@pkg_dir, filename)
      raise DigestValidationError, "staged gem file not found: #{path}" unless File.exist?(path)

      local_digest = "sha256:#{Digest::SHA256.file(path).hexdigest}"
      remote_digest = rubygems_digest_for(name, version, rubygems_platform)

      if remote_digest.nil?
        raise DigestValidationError, "RubyGems.org has no published #{rubygems_platform.inspect}-platform version " \
                                      "#{version} for #{name} (or no digest reported for it) -- refusing to trust " \
                                      'an unverifiable staged file'
      end
      unless remote_digest == local_digest
        raise DigestValidationError, "#{name} #{version}: staged file hashes to #{local_digest}, but " \
                                      "RubyGems.org reports #{remote_digest} -- refusing to ship an unverified gem"
      end

      local_digest
    end

    # @param name [String]
    # @param version [String]
    # @param rubygems_platform [String]
    # @return [String, nil] +"sha256:<64 lowercase hex>"+, or +nil+ if
    #   RubyGems.org has no matching, well-formed digest for this exact
    #   name+version+platform
    def rubygems_digest_for(name, version, rubygems_platform)
      entry = @rubygems_client.versions(name).find { |v| v['number'] == version && v['platform'] == rubygems_platform }
      return nil if entry.nil?

      sha = entry['sha']
      return nil if sha.nil? || sha.to_s.strip.empty?

      candidate = "sha256:#{sha.downcase}"
      DigestFormat.valid?(candidate) ? candidate : nil
    end
  end
end
