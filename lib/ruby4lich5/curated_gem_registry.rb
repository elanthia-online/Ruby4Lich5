# frozen_string_literal: true

require 'digest'
require 'json'
require_relative 'safe_token'

module Ruby4Lich5
  # The single source of truth for which gems are curated for self-contained
  # native compilation, and what MSYS2 packages each one needs -- per
  # docs/DECISIONS.md Phase 17. Replaces {KnownNativeGems}'s own hardcoded
  # constants (see that class's facade cutover) and the hardcoded MSYS2
  # +install:+ list in +ruby4-bundled-gems-suite.yml+, the two spots this
  # item exists to stop letting drift apart.
  #
  # Ruby owns all registry interpretation -- this class, and this class
  # alone, ever parses +config/curated-gems.json+ or answers "is this gem
  # approved" / "what MSYS2 packages does it need." Nothing on the
  # PowerShell/workflow side re-derives any of this independently; it only
  # ever consumes an already-computed result this class (via the CLI that
  # wraps it) produces. See docs/DECISIONS.md Phase 17 section 11.
  class CuratedGemRegistry
    # Raised for any structural or semantic violation of the registry
    # schema -- a malformed, unrecognized, or self-inconsistent document is
    # rejected outright rather than partially trusted.
    class ValidationError < StandardError; end

    # @return [Integer] the only +schema+ value this class currently accepts
    SCHEMA_VERSION = 2
    private_constant :SCHEMA_VERSION

    # @return [String] the only value +approval+ is ever allowed to hold on
    #   +main+ -- there is no live-state token for +proposed+/+rejected+ to
    #   accidentally satisfy.
    APPROVAL_APPROVED = 'approved'
    private_constant :APPROVAL_APPROVED

    # @return [Array<String>] the only classifications a registry entry may
    #   declare. +native_needs_system_lib+ means "not curated, needs manual
    #   review" -- self-contradictory next to an approved entry.
    #   +ruby_bundled+ gems get no registry entry at all ({Classifier}
    #   short-circuits those before the registry is ever consulted).
    CLASSIFICATIONS = %w[pure native_pass_through native_self_contained].freeze
    private_constant :CLASSIFICATIONS

    # @return [String] today's only real target platform, per
    #   docs/DECISIONS.md Phase 17 section 11 -- used by {#packages_for},
    #   the {KnownNativeGems}-compatible facade query that predates
    #   target-awareness and has no platform/ABI parameter of its own.
    CURRENT_PLATFORM = 'x64-mingw-ucrt'

    # @return [String] today's only real target Ruby ABI series, paired with
    #   {CURRENT_PLATFORM}.
    CURRENT_RUBY_ABI = '4.0'

    TOP_LEVEL_KEYS = %w[schema gems].freeze
    private_constant :TOP_LEVEL_KEYS

    GEM_ENTRY_KEYS = %w[approval bundle_default targets build_role build_order smoke_requires].freeze
    private_constant :GEM_ENTRY_KEYS

    TARGET_LEAF_KEYS_SELF_CONTAINED = %w[expected_classification msys2_packages].freeze
    private_constant :TARGET_LEAF_KEYS_SELF_CONTAINED

    TARGET_LEAF_KEYS_OTHER = %w[expected_classification].freeze
    private_constant :TARGET_LEAF_KEYS_OTHER

    # @return [String, nil] this registry's own +"sha256:<hex>"+ content
    #   digest, set only by {.load_file} -- +nil+ for an instance built from
    #   already-parsed data (specs, mainly), since by the time +data+ exists
    #   as a Ruby object, whatever produced it may already have
    #   re-serialized or re-encoded it and a digest computed here would not
    #   honestly describe the checked-in file's own bytes.
    attr_reader :content_digest

    # The smallest public seam onto {SCHEMA_VERSION} -- kept `private_constant`
    # (nothing outside this class should read the raw schema-version number
    # as if it were free-standing data), but {CuratedGemsSeedBuilder} writes
    # a `"schema"` field that must always agree with what this class accepts,
    # and a second hardcoded literal there was a real single-source-of-truth
    # violation, found in review: nothing enforced the two ever matching.
    #
    # @return [Integer] the only +schema+ value this class currently accepts
    def self.schema_version
      SCHEMA_VERSION
    end

    # Loads and validates the real, checked-in registry file, computing its
    # content digest over the exact bytes on disk (before any encoding
    # coercion) so the digest reflects precisely what's committed to git --
    # see the +.gitattributes+ +text eol=lf+ pin alongside this file, which
    # keeps those bytes stable across checkout environments.
    #
    # @param path [String]
    # @return [CuratedGemRegistry]
    # @raise [ValidationError] if the file's bytes aren't valid UTF-8, or the
    #   parsed document fails any schema check
    def self.load_file(path)
      bytes = File.binread(path)
      content_digest = "sha256:#{Digest::SHA256.hexdigest(bytes)}"

      text = bytes.dup.force_encoding('UTF-8')
      raise ValidationError, "#{path} is not valid UTF-8" unless text.valid_encoding?

      new(parse_strict(text), content_digest: content_digest, require_envelope: true)
    end

    # Parses JSON text with real duplicate-key detection -- exposed as its
    # own public class method, not folded silently into {.load_file} or
    # {#initialize}, since it's a meaningful independent capability specs
    # exercise directly to prove duplicate keys are actually caught, not
    # just described in a comment.
    #
    # Uses +allow_duplicate_key: false+ (json gem >= 2.20, confirmed against
    # this project's own pinned +json (2.20.0)+ in Gemfile.lock) rather than
    # a hand-rolled duplicate-key scanner. An earlier draft tried a custom
    # +object_class:+ Hash subclass overriding +#[]=+ to catch repeats as
    # they're assigned -- verified directly, against this exact json
    # version, that the C parser resolves duplicate keys to their final
    # value internally and calls +object_class#[]=+ only once per unique
    # key, so that approach silently never fires. +allow_duplicate_key:
    # false+ is the parser's own real, documented, correctly-implemented
    # check (json 3.0's planned default) instead.
    #
    # @param text [String]
    # @return [Hash] duplicate-key-checked parse result
    # @raise [ValidationError] on malformed JSON or a duplicate key
    def self.parse_strict(text)
      JSON.parse(text, allow_duplicate_key: false)
    rescue JSON::ParserError => e
      raise ValidationError, "malformed registry JSON: #{e.message}"
    end

    # @param data [Hash] already-parsed registry document (String or Symbol
    #   keys at the top level; nested content must use String keys, matching
    #   how {.load_file} always produces it). An empty Hash (the default)
    #   is treated as an intentional empty registry (nothing approved), the
    #   same "no data yet" convention {CurationManifest} uses -- unless
    #   +require_envelope:+ is true, see below.
    # @param content_digest [String, nil] set only by {.load_file}
    # @param require_envelope [Boolean] when true, an empty Hash is *not*
    #   treated as a legitimate empty registry -- it's rejected the same as
    #   any other document missing the +schema+/+gems+ envelope. Set only by
    #   {.load_file}: a real, checked-in registry file is never legitimately
    #   just +{}+ (that shape can only mean truncation/corruption), whereas a
    #   bare +CuratedGemRegistry.new+ with no arguments legitimately means
    #   "no data yet."
    # @raise [ValidationError] if +data+ isn't a Hash, or is non-empty (or
    #   +require_envelope+) and fails any schema check
    def initialize(data = {}, content_digest: nil, require_envelope: false)
      @content_digest = deep_freeze(content_digest)
      @gems = deep_freeze(validate!(data, require_envelope: require_envelope))
    end

    # @param gem_name [String]
    # @return [Boolean] true if +gem_name+ has any registry entry at all
    def known?(gem_name)
      @gems.key?(gem_name.to_s)
    end

    # @param gem_name [String]
    # @param platform [String]
    # @param ruby_abi [String]
    # @return [Boolean] true if +gem_name+ is approved with a target entry
    #   for the exact +platform+/+ruby_abi+ combination
    def approved?(gem_name, platform, ruby_abi)
      !target_entry(gem_name, platform, ruby_abi).nil?
    end

    # @param gem_name [String]
    # @param platform [String]
    # @param ruby_abi [String]
    # @return [String, nil] one of {CLASSIFICATIONS}, or +nil+ if there's no
    #   approved entry for this exact target
    def classification_for(gem_name, platform, ruby_abi)
      target_entry(gem_name, platform, ruby_abi)&.fetch('expected_classification')
    end

    # @param gem_name [String]
    # @param platform [String]
    # @param ruby_abi [String]
    # @return [Array<String>] the MSYS2 packages needed to build +gem_name+
    #   for this exact target -- always empty for +pure+/+native_pass_through+
    #   (the schema never carries the key for those), never +nil+
    def msys2_packages_for(gem_name, platform, ruby_abi)
      target_entry(gem_name, platform, ruby_abi)&.fetch('msys2_packages', []) || []
    end

    # {KnownNativeGems}-compatible facade query -- no platform/ABI
    # parameter, since the class it replaces predates target-awareness.
    # Always answers against {CURRENT_PLATFORM}/{CURRENT_RUBY_ABI}.
    #
    # **Deliberately narrower than "approved at all," found and fixed in
    # review before this had a real caller.** `KnownNativeGems` meant
    # "permitted fallback self-build": +nil+ answered "not a curated
    # self-build candidate," a non-empty Array answered "yes, here's the
    # recipe" -- and `Classifier#self_build_classification` branches on
    # exactly that nil-vs-Array truthiness to decide
    # +:native_self_contained+ vs. +:native_needs_system_lib+. The registry
    # means something broader: "approved, with *some* technical
    # classification" -- `pure` and `native_pass_through` gems get real
    # approved entries too (real example found during PR B's seed
    # derivation: `sqlite3`/`ffi` are approved and `native_pass_through`
    # today, upstream now ships matching precompiled builds). An earlier
    # version of this method returned `msys2_packages_for` gated only on
    # {#known?} (registry membership), which is *not* classification-aware
    # -- for a `native_pass_through` gem that returns `[]` (empty, but
    # truthy in Ruby), not +nil+. Fed into
    # `Classifier#self_build_classification`'s `if packages` check, a
    # truthy empty Array would have silently produced
    # +:native_self_contained+ with zero packages to actually build with,
    # instead of failing closed as +:native_needs_system_lib+ the moment a
    # gem's upstream precompiled build ever disappears. Gated on
    # {#classification_for} instead, not {#known?}, so only a genuine
    # +native_self_contained+ entry -- never `pure`/`native_pass_through`,
    # and never an unapproved gem -- returns a value.
    #
    # @param gem_name [String]
    # @param ruby_abi [String] defaults to {CURRENT_RUBY_ABI}, matching
    #   every existing caller (`KnownNativeGems`, specs) that predates
    #   target-awareness -- real gap, found in review: the F1 CLI
    #   (+bin/derive_dynamic_msys2_packages.rb+) resolves and classifies
    #   its closure against whatever ABI a caller-supplied
    #   +ruby_installer_version+ actually derives to ({ResolutionLock.ruby_abi_for}),
    #   but this method had no way to be asked about anything other than
    #   {CURRENT_RUBY_ABI}, so a non-default ABI run would silently query
    #   4.0-series registry entries regardless of what was actually
    #   resolved. An explicit override lets a caller ask about the *real*
    #   target instead; the default preserves every existing caller's
    #   behavior unchanged.
    # @return [Array<String>, nil] MSYS2 packages, or +nil+ unless
    #   +gem_name+ is approved as +native_self_contained+ for
    #   {CURRENT_PLATFORM}/+ruby_abi+ -- matches
    #   {KnownNativeGems.packages_for}'s exact contract when +ruby_abi+ is
    #   left at its default
    def self_build_packages_for(gem_name, ruby_abi: CURRENT_RUBY_ABI)
      return nil unless classification_for(gem_name, CURRENT_PLATFORM, ruby_abi) == 'native_self_contained'

      msys2_packages_for(gem_name, CURRENT_PLATFORM, ruby_abi)
    end

    # @return [Array<String>] gem names whose +bundle_default+ is +true+
    def names_for_role(role)
      @gems.select { |_name, entry| entry['build_role'] == role }.sort_by { |name, entry| [entry.fetch('build_order', 0), name] }.map(&:first)
    end

    def smoke_definitions
      @gems.filter_map { |name, entry| [name, entry['smoke_requires']] if entry.key?('smoke_requires') }.to_h
    end

    def bundle_default_roots
      @gems.select { |_name, entry| entry['bundle_default'] }.keys
    end

    private

    # @return [Hash, nil] the +targets.<platform>.<ruby_abi>+ leaf entry, or
    #   +nil+ if +gem_name+ isn't approved for that exact combination
    def target_entry(gem_name, platform, ruby_abi)
      @gems.dig(gem_name.to_s, 'targets', platform.to_s, ruby_abi.to_s)
    end

    # Recursively duplicates and freezes +obj+, real defensive-copy-and-freeze
    # rather than freezing in place -- {#validate!} builds +@gems+ out of
    # fresh Hash/Array literals at every level (+each_with_object({})+
    # throughout), but its String *leaf values* (+entry['approval']+, a
    # +msys2_packages+ entry, a +.to_s+'d key that was already a String --
    # +"x".to_s+ returns the exact same object, not a copy) are still live
    # references into whatever +data+ the caller passed in. Freezing those
    # in place would freeze the caller's own objects out from under them, a
    # surprising side effect on data this class doesn't own; duplicating
    # first means only this instance's private copy is ever frozen. Query
    # methods can then return these frozen values directly -- a caller
    # attempting to mutate one raises +FrozenError+ immediately rather than
    # silently corrupting this registry's own internal state for every
    # future query, which is what happened before this existed (real bug,
    # found in review: {#msys2_packages_for} was returning a live reference
    # into +@gems+).
    def deep_freeze(obj)
      case obj
      when String
        obj.dup.freeze
      when Hash
        obj.each_with_object({}) { |(k, v), out| out[deep_freeze(k)] = deep_freeze(v) }.freeze
      when Array
        obj.map { |v| deep_freeze(v) }.freeze
      else
        # Symbol, true/false, nil, Integer -- already immutable value types
        # in Ruby, nothing to copy or freeze.
        obj
      end
    end

    # @param data [Object] not necessarily a Hash -- {.load_file} hands this
    #   whatever +JSON.parse+ actually returned, which could be an Array,
    #   String, number, +true+/+false+, or +nil+ for a malformed file just
    #   as easily as a Hash. Type-checked here, before anything (including
    #   +#empty?+, which several non-Hash types respond to too -- +[].empty?+
    #   and +"".empty?+ are both true, and a naive +#empty?+-first check
    #   would silently accept either as "the empty registry").
    # @param require_envelope [Boolean]
    # @return [Hash{String => Hash}] gem name => validated entry
    # @raise [ValidationError]
    def validate!(data, require_envelope:)
      raise ValidationError, "registry data must be an object, got #{data.class}" unless data.is_a?(Hash)

      if data.empty?
        return {} unless require_envelope

        raise ValidationError, 'registry document is empty -- expected the schema/gems envelope'
      end

      data = stringify_top_level(data)
      reject_unknown_keys!(data, TOP_LEVEL_KEYS, 'registry')

      schema = data['schema']
      unless schema == SCHEMA_VERSION
        raise ValidationError, "unrecognized registry schema version: #{schema.inspect}"
      end

      gems = data['gems']
      raise ValidationError, "registry 'gems' must be an object, got #{gems.class}" unless gems.is_a?(Hash)

      gems.each_with_object({}) do |(gem_name, entry), validated|
        safe_token!(gem_name, 'gem name')
        validated[gem_name] = validate_gem_entry!(gem_name, entry)
      end
    end

    # {SafeToken.validate!} raises +ArgumentError+ -- correct for its own
    # callers elsewhere in this project, but this class's whole contract is
    # "every rejection is a {ValidationError}," so every {SafeToken} call
    # here goes through this wrapper rather than letting the mismatched
    # error class leak through directly.
    #
    # @raise [ValidationError]
    def safe_token!(value, label)
      SafeToken.validate!(value, label)
    rescue ArgumentError => e
      raise ValidationError, e.message
    end

    # @return [Hash]
    # @raise [ValidationError] if two top-level keys normalize to the same
    #   String -- e.g. +:schema+ and +"schema"+ both present. {.load_file}
    #   never hits this (JSON.parse only ever produces String keys, and
    #   +allow_duplicate_key: false+ already rejects a real duplicate before
    #   this method ever runs) -- this guards the same silent-overwrite
    #   failure mode for #initialize's other documented input shape, a
    #   hand-built Hash mixing Symbol and String keys at the top level.
    def stringify_top_level(data)
      data.each_with_object({}) do |(key, value), out|
        normalized_key = key.to_s
        raise ValidationError, "duplicate top-level key: #{normalized_key.inspect}" if out.key?(normalized_key)

        out[normalized_key] = value
      end
    end

    # @param gem_name [String] used only in raised error messages
    # @param entry [Object]
    # @return [Hash]
    # @raise [ValidationError]
    def validate_gem_entry!(gem_name, entry)
      unless entry.is_a?(Hash)
        raise ValidationError, "registry entry for #{gem_name.inspect} must be an object, got #{entry.class}"
      end

      reject_unknown_keys!(entry, GEM_ENTRY_KEYS, "registry entry for #{gem_name.inspect}")

      approval = entry['approval']
      unless approval == APPROVAL_APPROVED
        raise ValidationError, "registry entry for #{gem_name.inspect} has invalid approval: #{approval.inspect}"
      end

      bundle_default = entry['bundle_default']
      unless [true, false].include?(bundle_default)
        raise ValidationError,
              "registry entry for #{gem_name.inspect} has non-boolean bundle_default: #{bundle_default.inspect}"
      end

      targets = entry['targets']
      unless targets.is_a?(Hash) && !targets.empty?
        raise ValidationError, "registry entry for #{gem_name.inspect} must have at least one target"
      end

      extra = entry.select { |key, _value| %w[build_role build_order smoke_requires].include?(key) }
      if extra.key?('build_role') && !%w[gtk repack tooling none].include?(extra['build_role'])
        raise ValidationError, "invalid build_role for #{gem_name}"
      end
      if extra.key?('build_order') && !(extra['build_role'] == 'gtk' && extra['build_order'].is_a?(Integer) && extra['build_order'] >= 0)
        raise ValidationError, "invalid GTK build_order for #{gem_name}"
      end
      if extra.key?('smoke_requires') && !(extra['smoke_requires'].is_a?(Array) && !extra['smoke_requires'].empty? && extra['smoke_requires'].all? { |path| path.is_a?(String) && path.match?(/\A[a-zA-Z0-9_\/-]+\z/) && !path.split('/').include?('..') })
        raise ValidationError, "invalid smoke_requires for #{gem_name}"
      end
      extra.merge(
        'approval'       => approval,
        'bundle_default' => bundle_default,
        'targets'        => validate_targets!(gem_name, targets)
      )
    end

    # @return [Hash{String => Hash{String => Hash}}]
    # @raise [ValidationError]
    def validate_targets!(gem_name, targets)
      targets.each_with_object({}) do |(platform, abis), validated|
        safe_token!(platform, "platform for #{gem_name.inspect}")
        unless abis.is_a?(Hash) && !abis.empty?
          raise ValidationError, "#{gem_name.inspect} target #{platform.inspect} must have at least one Ruby ABI entry"
        end

        validated[platform] = abis.each_with_object({}) do |(ruby_abi, leaf), by_abi|
          safe_token!(ruby_abi, "ruby_abi for #{gem_name.inspect}/#{platform.inspect}")
          by_abi[ruby_abi] = validate_target_leaf!(gem_name, platform, ruby_abi, leaf)
        end
      end
    end

    # @return [Hash]
    # @raise [ValidationError]
    def validate_target_leaf!(gem_name, platform, ruby_abi, leaf)
      label = "#{gem_name.inspect} target #{platform.inspect}/#{ruby_abi.inspect}"
      raise ValidationError, "#{label} must be an object, got #{leaf.class}" unless leaf.is_a?(Hash)

      classification = leaf['expected_classification']
      unless CLASSIFICATIONS.include?(classification)
        raise ValidationError, "#{label} has invalid expected_classification: #{classification.inspect}"
      end

      if classification == 'native_self_contained'
        reject_unknown_keys!(leaf, TARGET_LEAF_KEYS_SELF_CONTAINED, label)
        validate_msys2_packages!(label, leaf['msys2_packages'])
        { 'expected_classification' => classification, 'msys2_packages' => leaf['msys2_packages'] }
      else
        reject_unknown_keys!(leaf, TARGET_LEAF_KEYS_OTHER, label)
        { 'expected_classification' => classification }
      end
    end

    # @raise [ValidationError]
    def validate_msys2_packages!(label, packages)
      unless packages.is_a?(Array) && !packages.empty?
        raise ValidationError, "#{label} is native_self_contained but msys2_packages is missing or empty"
      end

      packages.each { |pkg| safe_token!(pkg, "msys2 package for #{label}") }
    end

    # @raise [ValidationError]
    def reject_unknown_keys!(hash, allowed_keys, label)
      unknown = hash.keys.map(&:to_s) - allowed_keys
      return if unknown.empty?

      raise ValidationError, "#{label} has unrecognized field(s): #{unknown.sort.join(', ')}"
    end
  end
end
