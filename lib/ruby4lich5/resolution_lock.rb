# frozen_string_literal: true

require_relative 'classification'
require_relative 'digest_format'
require_relative 'safe_token'

require_relative 'runtime_contract'

module Ruby4Lich5
  # An immutable, serializable record of exactly what one run resolved --
  # per docs/DECISIONS.md Phase 17 SS8's locked lock schema. Closes the real
  # TOCTOU that motivated it: `ClosureResolver`/`Classifier` resolve *live*
  # against RubyGems.org, so if that resolution happened once to derive an
  # MSYS2 package list and the actual build/staging happened later,
  # unrelated to this run, upstream could publish a new version in between
  # and the two could silently diverge. Persisting the resolved result as a
  # lock, then driving every later step from the lock instead of a fresh
  # resolve, closes that gap structurally.
  #
  # Deliberately a pure data holder, the same seam discipline every other
  # class here already uses (`RubygemsClient#initialize(http_get:)`,
  # `ClosureResolver#initialize(resolve:)`) -- it never shells out to Git,
  # never talks to RubygemsClient, never re-resolves anything. It receives
  # an already-resolved closure and the registry's exact identity (commit
  # SHA and content digest) as plain constructor arguments; the CLI entry
  # point that assembles a lock for a real run is responsible for actually
  # running `git rev-parse HEAD` and `CuratedGemRegistry.load_file`'s digest
  # and passing both in. Keeps this class testable without a real git
  # checkout or real file I/O in its own spec.
  class ResolutionLock
    # Raised for any structural or semantic violation of the lock's own
    # invariants -- malformed input is rejected outright at construction,
    # never partially trusted into a lock some later step relies on.
    class ValidationError < StandardError; end

    # @return [Integer]
    SCHEMA_VERSION = 1
    private_constant :SCHEMA_VERSION

    # Exact allowed field sets for {.from_h}'s own deserialization, one per
    # nesting level, matching {#to_h}/{#serialize_closure_entry}'s own
    # output shape precisely -- real gap, found in audit 2026-07-13: an
    # unrecognized field anywhere in a hand-edited or version-drifted lock
    # document previously passed through silently (JSON.parse itself never
    # rejects unknown keys), rather than failing closed the way this
    # project's other strict-schema boundaries already do (e.g.
    # CuratedGemRegistry's own allowed-keys check).
    ALLOWED_TOP_LEVEL_KEYS = %w[schema ruby_installer_version platform requested_roots closure registry contract].freeze
    private_constant :ALLOWED_TOP_LEVEL_KEYS
    ALLOWED_REGISTRY_KEYS = %w[commit_sha content_digest].freeze
    private_constant :ALLOWED_REGISTRY_KEYS
    ALLOWED_CLOSURE_ENTRY_KEYS = %w[name version runtime_dependencies classification].freeze
    private_constant :ALLOWED_CLOSURE_ENTRY_KEYS
    ALLOWED_CLASSIFICATION_KEYS = %w[state gem_name gem_version reason platform_asset msys2_packages].freeze
    private_constant :ALLOWED_CLASSIFICATION_KEYS
    ALLOWED_DEPENDENCY_KEYS = %w[name requirement].freeze
    private_constant :ALLOWED_DEPENDENCY_KEYS

    attr_reader :ruby_installer_version, :platform, :requested_roots, :closure,
                :registry_commit_sha, :registry_content_digest, :contract

    # The same ABI-series derivation {#ruby_abi} uses, exposed as a public
    # class method so a caller building the closure/plan that will
    # eventually go *into* a lock (e.g. the F1 CLI's own
    # +BuildPlanner#plan_for+/+CuratedGemRegistry#self_build_packages_for+
    # calls) can derive and use the exact same ABI *before* a lock
    # exists to ask -- real gap, found in review: an earlier version of
    # the F1 CLI resolved/classified/derived packages against a
    # hardcoded ABI constant while only recording the caller-supplied
    # +ruby_installer_version+ in the lock afterward, so a non-4.0
    # installer input would resolve under a genuinely different Ruby but
    # still apply 4.0-series policy throughout. One derivation, reused
    # everywhere a Ruby ABI series is needed from this same source value,
    # not two independent copies of the same regex that could drift.
    #
    # @param ruby_installer_version [String] e.g. +"4.0.5-1"+
    # @return [String] e.g. +"4.0"+ from +"4.0.5-1"+
    # @raise [ValidationError] if +ruby_installer_version+ doesn't match
    #   the N.N.N-N grammar {#initialize} itself also enforces
    def self.ruby_abi_for(ruby_installer_version)
      unless ruby_installer_version.is_a?(String) && RUBY_INSTALLER_VERSION_PATTERN.match?(ruby_installer_version)
        raise ValidationError,
              "ruby_installer_version must look like N.N.N-N (e.g. 4.0.5-1), got #{ruby_installer_version.inspect}"
      end

      ruby_installer_version[/\A(\d+\.\d+)\./, 1]
    end

    # @param ruby_installer_version [String] the exact resolved version this
    #   run bootstrapped, e.g. +"4.0.5-1"+ -- never just the ABI series
    #   (+"4.0"+ is too coarse, per Phase 17 SS8)
    # @param platform [String] target RubyGems platform tag, e.g.
    #   +"x64-mingw-ucrt"+
    # @param requested_roots [Hash{String => String}] root gem name => its
    #   exact selected version (already resolved via the caller's own
    #   root-version-selection step -- {RubygemsClient#latest_version} for
    #   an ordinary root, the +ruby-gnome-version+ input for +gtk3+, derived
    #   from the resolved gtk3 closure for +cairo+)
    # @param closure [Array<Hash>] one +{name:, version:, runtime_dependencies:,
    #   classification:}+ entry per resolved closure member, in dependency
    #   order (the same order +ClosureResolver#resolve_closure+ already
    #   guarantees -- this class trusts, and does not re-verify, that
    #   ordering). +runtime_dependencies+ is the +[{name:, requirement:}]+
    #   shape `ClosureResolver` returns (a real +Gem::Requirement+ per
    #   edge, per PR C); +classification+ is a real {Classification}
    #   instance, the same object {Classifier#classify}/{BuildPlanner#plan_for}
    #   already produce
    # @param registry_commit_sha [String] the curated-gem registry's exact
    #   git commit SHA in effect for this run -- full 40-character hex, the
    #   value that makes this auditable against real repo history
    # @param registry_content_digest [String] the registry's own
    #   +"sha256:<hex>"+ {CuratedGemRegistry#content_digest} for that same
    #   commit -- alongside the commit SHA, not instead of it: the digest
    #   lets any consumer verify the exact content without trusting a
    #   mutable ref, and the commit SHA is what makes the digest auditable
    #   against real history. Neither alone is sufficient.
    # @raise [ValidationError]
    def initialize(ruby_installer_version:, platform:, requested_roots:, closure:,
                   registry_commit_sha:, registry_content_digest:, contract: nil)
      @ruby_installer_version = ruby_installer_version
      @platform = platform
      @requested_roots = requested_roots
      @closure = closure
      @registry_commit_sha = registry_commit_sha
      @registry_content_digest = registry_content_digest
      @contract = contract
      begin
        RuntimeContract.validate!(contract, ruby_installer_version: ruby_installer_version, closure: closure) if contract
      rescue RuntimeContract::Error => e
        raise ValidationError, "invalid runtime contract: #{e.message}"
      end
      validate!

      # Real bug, found in review: this class's whole contract is "an
      # immutable, serializable record of exactly what one run resolved,"
      # but it stored the caller's own Hash/Array/String objects directly
      # -- confirmed live, mutating the original requested_roots Hash
      # *after* construction changed what #to_h and the public readers
      # reported. Deep-copied and frozen here, the same defensive-copy-
      # and-freeze discipline {CuratedGemRegistry} already established, not
      # freezing the caller's own objects in place (which would surprise a
      # caller still holding, and expecting to mutate, the data it handed
      # in). The four scalar Strings went through the same fix one round
      # later, found in a follow-up review pass -- confirmed live the same
      # way: mutating the caller's original platform String, or the
      # returned registry_commit_sha reader directly, both changed this
      # lock's own reported state.
      @requested_roots = deep_freeze(@requested_roots)
      @closure = deep_freeze(@closure)
      @ruby_installer_version = deep_freeze(@ruby_installer_version)
      @platform = deep_freeze(@platform)
      @registry_commit_sha = deep_freeze(@registry_commit_sha)
      @registry_content_digest = deep_freeze(@registry_content_digest)
      @contract = deep_freeze(@contract)
    end

    # The ABI series, derived from {#ruby_installer_version} -- never a
    # separate lock field (the schema deliberately doesn't carry a
    # redundant series alongside the exact version; PR D's own doc comment
    # already names +ruby_installer_version+ as "never just the ABI
    # series"). Mirrors the exact derivation
    # +ruby4-bundled-gems-suite.yml+ already uses for the same purpose
    # (+-replace '^(\d+\.\d+)\..*$', '$1'+), not a second, independent
    # convention.
    #
    # @return [String] e.g. +"4.0"+ from +"4.0.5-1"+
    def ruby_abi
      self.class.ruby_abi_for(@ruby_installer_version)
    end

    # @return [Hash] JSON-serializable, matching this project's existing
    #   small-JSON-hand-off convention (e.g. {CuratedGemsSeedBuilder#build}).
    #   Lossless -- round-trips through {.from_h} back into an equivalent
    #   lock, every +Classification+ field included, not just +state+ (see
    #   {.from_h}'s own doc comment for why this matters)
    def to_h
      {
        'schema'                 => SCHEMA_VERSION,
        'ruby_installer_version' => @ruby_installer_version,
        'platform'               => @platform,
        'requested_roots'        => @requested_roots,
        'closure'                => @closure.map { |entry| serialize_closure_entry(entry) },
        'registry'               => { 'commit_sha' => @registry_commit_sha, 'content_digest' => @registry_content_digest }
      }.tap { |data| data['contract'] = @contract if @contract }
    end

    # Reconstructs a real lock from {#to_h}'s own output shape -- the
    # actual "resolve once" cutover (docs/DECISIONS.md's F2 design) needs
    # this to exist at all: a lock resolved by one workflow step has to
    # survive being written to disk and read back by every later step
    # (native prep, runtime staging, revalidation) without any of them
    # touching {ClosureResolver}/{RubygemsClient} again.
    #
    # **Real gap, found in review, before this had a real caller**: an
    # earlier version of {#to_h}'s own closure serialization only kept
    # +classification.state.to_s+, dropping +reason+/+platform_asset+/
    # +msys2_packages+/+gem_name+/+gem_version+ entirely -- harmless for
    # its original purpose (a debug JSON dump nothing ever read back), but
    # actively broken for a real round-trip: reconstructing a
    # +:native_pass_through+ {Classification} with no +platform_asset}+
    # would raise +ArgumentError+ immediately from {Classification}'s own
    # constructor, which requires that field present for exactly that
    # state. Fixed here and in {#serialize_closure_entry} together, before
    # any real caller could hit it -- {#to_h}'s +'classification'+ value is
    # now the full field set, not just the state string.
    #
    # @param data [Hash] must match {#to_h}'s own shape (String keys
    #   throughout, matching how +JSON.parse+ always produces it)
    # @return [ResolutionLock]
    # @raise [ValidationError] if +data+ (or any nested document/object
    #   shape within it) is missing a required key, isn't the type this
    #   schema requires, has the wrong schema version, or otherwise fails
    #   {#initialize}'s own validation once reconstructed. Real gaps, found
    #   in audit 2026-07-13: +.from_h(nil)+ (or any other non-Hash
    #   top-level document) previously leaked a raw +NoMethodError+ from
    #   the very first +.fetch+ call, since neither +KeyError+ nor
    #   +TypeError+ covers "the receiver doesn't even have +#fetch+."
    #   Every document/object level this method or {.deserialize_closure_entry}
    #   touches is now shape-checked (+is_a?+) before anything calls
    #   +#fetch+ on it, rather than trusting exception classes alone to
    #   catch every possible malformed shape.
    def self.from_h(data)
      unless data.is_a?(Hash)
        raise ValidationError, "resolution lock data must be an object, got #{data.class}: #{data.inspect}"
      end
      reject_unknown_keys!(data, ALLOWED_TOP_LEVEL_KEYS, 'resolution lock data')

      schema = data.fetch('schema')
      unless schema == SCHEMA_VERSION
        raise ValidationError, "unrecognized resolution lock schema version: #{schema.inspect}"
      end

      registry = data.fetch('registry')
      unless registry.is_a?(Hash)
        raise ValidationError, "resolution lock 'registry' must be an object, got #{registry.class}: #{registry.inspect}"
      end
      reject_unknown_keys!(registry, ALLOWED_REGISTRY_KEYS, "resolution lock's registry")

      closure_data = data.fetch('closure')
      unless closure_data.is_a?(Array)
        raise ValidationError, "resolution lock 'closure' must be an array, got #{closure_data.class}: #{closure_data.inspect}"
      end

      new(
        ruby_installer_version: data.fetch('ruby_installer_version'),
        platform: data.fetch('platform'),
        requested_roots: data.fetch('requested_roots'),
        closure: closure_data.map { |entry| deserialize_closure_entry(entry) },
        registry_commit_sha: registry.fetch('commit_sha'),
        registry_content_digest: registry.fetch('content_digest'), contract: data['contract']
      )
    rescue KeyError, TypeError, ArgumentError => e
      # ArgumentError alongside KeyError/TypeError -- real gap, found in
      # audit 2026-07-13: a malformed requirement string (Gem::Requirement::
      # BadRequirementError, a subclass of ArgumentError) or a
      # Classification field violation (Classification#initialize's own
      # ArgumentError -- e.g. a native_pass_through entry missing
      # platform_asset) both previously leaked past this boundary
      # unrescued. Every exception this whole reconstruction can raise for
      # malformed *input* is one of these three classes; a real
      # programming bug elsewhere would raise something else entirely, so
      # this stays a deliberate, narrow list, not a bare +rescue+.
      raise ValidationError, "malformed resolution lock data: #{e.message}"
    end

    # @return [Hash] a {#initialize}-shaped closure entry
    # @raise [ValidationError] on any missing/malformed field, or a
    #   real gap found in audit 2026-07-13: a classification whose own
    #   recorded +gem_name+/+gem_version+ silently disagreed with the
    #   enclosing closure entry's own +name+/+version+ -- reproduced live
    #   (a hand-edited lock JSON with a classification naming a different
    #   gem than its own entry), constructing a {Classification} that
    #   reports a name/version different from the entry it's attached to,
    #   undetected. Every other exception this method raises (+KeyError+,
    #   +TypeError+, +ArgumentError+ from {Classification}/+Gem::Requirement+)
    #   is deliberately not rescued here; {.from_h} is this method's one
    #   real caller and wraps every exception from this whole
    #   reconstruction into a single +ValidationError+ boundary
    def self.deserialize_closure_entry(entry)
      unless entry.is_a?(Hash)
        raise ValidationError, "closure member must be an object, got #{entry.class}: #{entry.inspect}"
      end
      reject_unknown_keys!(entry, ALLOWED_CLOSURE_ENTRY_KEYS, 'closure member')

      name = entry.fetch('name')
      version = entry.fetch('version')

      runtime_dependencies_data = entry.fetch('runtime_dependencies')
      unless runtime_dependencies_data.is_a?(Array)
        raise ValidationError, "closure member #{name.inspect}'s runtime_dependencies must be an array, " \
                                "got #{runtime_dependencies_data.class}: #{runtime_dependencies_data.inspect}"
      end

      classification_data = entry.fetch('classification')
      unless classification_data.is_a?(Hash)
        raise ValidationError, "closure member #{name.inspect}'s classification must be an object, " \
                                "got #{classification_data.class}: #{classification_data.inspect}"
      end
      reject_unknown_keys!(classification_data, ALLOWED_CLASSIFICATION_KEYS, "closure member #{name.inspect}'s classification")

      gem_name = classification_data.fetch('gem_name')
      gem_version = classification_data.fetch('gem_version')
      unless gem_name == name && gem_version == version
        raise ValidationError, "closure member #{name.inspect}'s classification identity " \
                                "(#{gem_name.inspect} #{gem_version.inspect}) does not match its own enclosing " \
                                "entry (#{name.inspect} #{version.inspect})"
      end

      # Validated as a String before .to_sym -- real gap, found in review
      # 2026-07-13: JSON null, a number, or an object/array all respond to
      # neither KeyError nor TypeError/ArgumentError when .to_sym is called
      # directly on them -- they raise a bare NoMethodError (no such
      # method), past this whole boundary's promised ValidationError
      # contract entirely. Confirmed live for all three shapes before
      # fixing.
      state_value = classification_data.fetch('state')
      unless state_value.is_a?(String)
        raise ValidationError, "closure member #{name.inspect}'s classification state must be a string, " \
                                "got #{state_value.class}: #{state_value.inspect}"
      end

      {
        name: name,
        version: version,
        runtime_dependencies: runtime_dependencies_data.map { |dep| deserialize_dependency(name, dep) },
        classification: Classification.new(
          state: state_value.to_sym,
          gem_name: gem_name,
          gem_version: gem_version,
          reason: classification_data.fetch('reason'),
          platform_asset: classification_data.fetch('platform_asset'),
          msys2_packages: classification_data.fetch('msys2_packages')
        )
      }
    end
    private_class_method :deserialize_closure_entry

    # @param member_name [String] the enclosing closure entry's own name,
    #   for a clear error message only
    # @param dep [Object] one raw +runtime_dependencies+ array element
    # @return [Hash] +{name:, requirement:}+
    # @raise [ValidationError] if +dep+ isn't an object at all
    def self.deserialize_dependency(member_name, dep)
      unless dep.is_a?(Hash)
        raise ValidationError, "closure member #{member_name.inspect} has a malformed dependency entry: #{dep.inspect}"
      end
      reject_unknown_keys!(dep, ALLOWED_DEPENDENCY_KEYS, "closure member #{member_name.inspect}'s dependency entry")

      { name: dep.fetch('name'), requirement: Gem::Requirement.new(dep.fetch('requirement')) }
    end
    private_class_method :deserialize_dependency

    # @param hash [Hash]
    # @param allowed [Array<String>]
    # @param label [String]
    # @raise [ValidationError]
    def self.reject_unknown_keys!(hash, allowed, label)
      unknown = hash.keys - allowed
      return if unknown.empty?

      raise ValidationError, "#{label} has unrecognized field(s): #{unknown.sort.inspect}"
    end
    private_class_method :reject_unknown_keys!

    private

    # @return [Hash]
    def serialize_closure_entry(entry)
      classification = entry.fetch(:classification)
      {
        'name'                 => entry.fetch(:name),
        'version'              => entry.fetch(:version),
        'runtime_dependencies' => entry.fetch(:runtime_dependencies).map do |dep|
          # #as_list (an Array of individual constraint strings, e.g.
          # [">= 1.1.1", "< 4"]), not #to_s -- real gap, found live while
          # smoke-testing #from_h against a real resolved lock, before
          # this had a real caller: #to_s joins multiple constraints into
          # one comma-separated String (">= 1.1.1, < 4"), which
          # Gem::Requirement.new can't parse back -- it raises
          # BadRequirementError, treating the whole joined string as one
          # illformed constraint. #as_list is the same shape
          # {#deep_freeze}'s own Gem::Requirement rebuild already uses
          # (Gem::Requirement.new(obj.as_list)) for exactly this reason.
          { 'name' => dep.fetch(:name), 'requirement' => dep.fetch(:requirement).as_list }
        end,
        'classification'       => {
          'state'          => classification.state.to_s,
          'gem_name'       => classification.gem_name,
          'gem_version'    => classification.gem_version,
          'reason'         => classification.reason,
          'platform_asset' => classification.platform_asset,
          'msys2_packages' => classification.msys2_packages
        }
      }
    end

    # @raise [ValidationError]
    def validate!
      validate_ruby_installer_version!
      SafeToken.validate!(@platform, 'platform')
      validate_registry_identity!
      validate_requested_roots!
      validate_closure!
      validate_roots_match_closure!
      validate_dependencies_satisfied!
    rescue ArgumentError => e
      # {SafeToken#validate!} raises ArgumentError -- this class's whole
      # contract is "every rejection is a ValidationError," same wrapper
      # pattern {CuratedGemRegistry#safe_token!} already established.
      raise ValidationError, e.message
    end

    # The real grammar this project already enforces for RubyInstaller's
    # own version at the workflow level -- mirrored exactly, not invented,
    # from `.github/workflows/rubyinstaller-provenance.yml`'s
    # +^\d+\.\d+\.\d+-\d+$+ PowerShell check.
    #
    # @return [Regexp]
    RUBY_INSTALLER_VERSION_PATTERN = /\A\d+\.\d+\.\d+-\d+\z/
    private_constant :RUBY_INSTALLER_VERSION_PATTERN

    def validate_ruby_installer_version!
      # Delegates to {.ruby_abi_for} rather than re-checking the same
      # RUBY_INSTALLER_VERSION_PATTERN/message inline -- real gap, found
      # in review: this method and {.ruby_abi_for} had drifted into two
      # independent copies of the identical format check and identical
      # error message text, the exact "same rule in two places" risk this
      # project's own conventions elsewhere already guard against. The
      # return value is discarded here -- this method's job is only to
      # validate (raise on bad input), not to report the derived ABI.
      self.class.ruby_abi_for(@ruby_installer_version)
    end

    def validate_registry_identity!
      unless @registry_commit_sha.is_a?(String) && /\A[0-9a-f]{40}\z/.match?(@registry_commit_sha)
        raise ValidationError,
              "registry_commit_sha must be a full 40-character lowercase hex SHA, got #{@registry_commit_sha.inspect}"
      end

      return if DigestFormat.valid?(@registry_content_digest)

      raise ValidationError,
            "registry_content_digest must be a well-formed sha256: digest, got #{@registry_content_digest.inspect}"
    end

    def validate_requested_roots!
      unless @requested_roots.is_a?(Hash) && !@requested_roots.empty?
        raise ValidationError, "requested_roots must be a non-empty Hash, got #{@requested_roots.inspect}"
      end

      @requested_roots.each do |name, version|
        SafeToken.validate!(name, 'requested root name')
        validate_version!(version, "requested root #{name.inspect}'s version")
      end
    end

    # @return [Array<Symbol>]
    REQUIRED_CLOSURE_ENTRY_KEYS = %i[name version runtime_dependencies classification].freeze
    private_constant :REQUIRED_CLOSURE_ENTRY_KEYS

    def validate_closure!
      unless @closure.is_a?(Array) && !@closure.empty?
        raise ValidationError, "closure must be a non-empty Array, got #{@closure.inspect}"
      end

      # Shape-checked before anything calls #fetch on it -- real gap, found
      # in review: a malformed entry (e.g. a bare +nil+ standing in for a
      # Hash) previously reached +entry.fetch(:name)+ directly, leaking a
      # raw +NoMethodError+/+KeyError+ instead of this class's own promised
      # +ValidationError+ boundary.
      @closure.each { |entry| validate_closure_entry_shape!(entry) }

      names = @closure.map { |entry| entry.fetch(:name) }
      duplicates = names.tally.select { |_name, count| count > 1 }.keys
      raise ValidationError, "closure has duplicate member names: #{duplicates.inspect}" unless duplicates.empty?

      @closure.each { |entry| validate_closure_entry!(entry) }
    end

    def validate_closure_entry_shape!(entry)
      unless entry.is_a?(Hash)
        raise ValidationError, "every closure member must be an object, got #{entry.class}: #{entry.inspect}"
      end

      missing_keys = REQUIRED_CLOSURE_ENTRY_KEYS - entry.keys
      return if missing_keys.empty?

      raise ValidationError, "closure member #{entry.inspect} is missing required key(s): #{missing_keys.inspect}"
    end

    def validate_closure_entry!(entry)
      name = entry.fetch(:name)
      SafeToken.validate!(name, "closure member #{name.inspect}'s name")
      validate_version!(entry.fetch(:version), "closure member #{name.inspect}'s version")

      unless entry.fetch(:classification).is_a?(Classification)
        raise ValidationError, "closure member #{name.inspect}'s classification must be a real Classification, " \
                                "got #{entry.fetch(:classification).class}"
      end

      runtime_dependencies = entry.fetch(:runtime_dependencies)
      unless runtime_dependencies.is_a?(Array)
        raise ValidationError, "closure member #{name.inspect}'s runtime_dependencies must be an Array, " \
                                "got #{runtime_dependencies.class}"
      end

      runtime_dependencies.each { |dep| validate_dependency_shape!(name, dep) }
    end

    def validate_dependency_shape!(member_name, dep)
      unless dep.is_a?(Hash) && dep.key?(:name) && dep.key?(:requirement)
        raise ValidationError, "closure member #{member_name.inspect} has a malformed dependency entry: #{dep.inspect}"
      end

      SafeToken.validate!(dep.fetch(:name), "closure member #{member_name.inspect}'s dependency name")
      return if dep.fetch(:requirement).is_a?(Gem::Requirement)

      raise ValidationError, "closure member #{member_name.inspect}'s dependency #{dep.fetch(:name).inspect} " \
                              "requirement must be a real Gem::Requirement, got #{dep.fetch(:requirement).class}"
    end

    # @return [Hash{String => String}] closure member name => its resolved
    #   version -- built once, shared by both checks below
    def closure_versions_by_name
      @closure.to_h { |entry| [entry.fetch(:name), entry.fetch(:version)] }
    end

    # A requested root is, by construction, always a member of its own
    # resolved closure, **at the exact version requested** -- real gap,
    # found in review: the original check only confirmed the root *name*
    # occurred somewhere in the closure, never that the closure's own
    # recorded version for that name actually matched. A lock declaring
    # +root-gem: 2.0.0+ whose closure node for +root-gem+ was actually
    # resolved at +1.0.0+ defeated the entire point of an exact-version
    # lock while still passing validation.
    def validate_roots_match_closure!
      closure_versions = closure_versions_by_name

      mismatches = @requested_roots.filter_map do |name, version|
        closure_version = closure_versions[name]
        next if closure_version == version

        "#{name.inspect}: requested #{version.inspect}, closure has #{closure_version.inspect}"
      end
      return if mismatches.empty?

      raise ValidationError, "requested root(s) do not match their own resolved closure: #{mismatches.join('; ')}"
    end

    # Every declared runtime dependency edge must resolve to a real closure
    # member whose recorded version actually satisfies the edge's
    # +Gem::Requirement+ -- real gap, found in review: a dependency
    # referencing a name absent from the closure, or present at a version
    # that doesn't satisfy its own recorded requirement (e.g. a locked
    # +dep-gem: 1.0.0+ against a declared +>= 5.0+ edge), previously passed
    # validation silently. Ordering itself stays trusted, not re-verified
    # (documented on {#initialize}) -- this only checks that the
    # requirement each edge *records* is honest about the version actually
    # locked for it.
    def validate_dependencies_satisfied!
      closure_versions = closure_versions_by_name

      @closure.each do |entry|
        entry.fetch(:runtime_dependencies).each do |dep|
          validate_dependency_satisfied!(entry.fetch(:name), dep, closure_versions)
        end
      end
    end

    def validate_dependency_satisfied!(member_name, dep, closure_versions)
      dep_name = dep.fetch(:name)
      dep_version = closure_versions[dep_name]

      if dep_version.nil?
        raise ValidationError, "closure member #{member_name.inspect} depends on #{dep_name.inspect}, which is " \
                                'not present anywhere in the resolved closure'
      end

      requirement = dep.fetch(:requirement)
      return if requirement.satisfied_by?(Gem::Version.new(dep_version))

      raise ValidationError, "closure member #{member_name.inspect}'s dependency #{dep_name.inspect} " \
                              "#{dep_version.inspect} does not satisfy its own recorded requirement (#{requirement})"
    end

    # @param version [Object]
    # @param label [String]
    # @raise [ValidationError]
    def validate_version!(version, label)
      return if version.is_a?(String) && Gem::Version.correct?(version)

      raise ValidationError, "#{label} must be a valid RubyGems version, got #{version.inspect}"
    end

    # Recursively duplicates and freezes +obj+ -- real defensive-copy-and-
    # freeze, not freezing in place, the same pattern
    # {CuratedGemRegistry#deep_freeze} already established. Freezing a
    # caller's own object in place would surprise a caller still holding,
    # and expecting to mutate, the data it handed in; duplicating first
    # means only this instance's private copy is ever frozen.
    #
    # +Classification+ and +Gem::Requirement+ are handled explicitly, not
    # by the generic +#dup.freeze+ fallback -- real gap, found in review:
    # +#dup+ is a *shallow* copy, so +#dup.freeze+ only froze the outer
    # object, never what it references internally.
    # +Gem::Requirement#requirements+ (its own internal Array of
    # +[operator, Gem::Version]+ pairs) and +Classification#msys2_packages+
    # both stayed live, mutable references even after the outer object
    # reported +frozen? == true+ -- confirmed live: mutating
    # +requirement.requirements+ directly changed what an
    # already-"frozen" +Gem::Requirement+ reported for
    # +#to_s+/+#satisfied_by?+ afterward. Both are rebuilt from their own
    # public, value-based representation (+Gem::Requirement.new(req.as_list)+,
    # a fresh +Classification+ with every field deep-frozen) rather than
    # patched via a private ivar, so this never depends on either class's
    # internal storage shape.
    #
    # @param obj [Object]
    # @return [Object] a deep-frozen duplicate
    def deep_freeze(obj)
      case obj
      when Hash
        obj.each_with_object({}) { |(k, v), out| out[deep_freeze(k)] = deep_freeze(v) }.freeze
      when Array
        obj.map { |v| deep_freeze(v) }.freeze
      when Gem::Requirement
        # Rebuilding via .new(obj.as_list) alone was still not enough --
        # found in review, round two: freezing the rebuilt Gem::Requirement
        # object only froze *it*, not its own internal #requirements Array
        # (an Array of [operator, Gem::Version] pairs) that #requirements
        # returns the same live reference to on every call. Confirmed live:
        # `rebuilt.requirements << [...]` still succeeded on an object that
        # already reported `frozen? == true`. Every pair, and the operator/
        # version inside each pair, is frozen explicitly and in place --
        # all freshly created by this rebuild, never aliased to the
        # caller's own objects, so freezing in place (no dup needed here)
        # doesn't risk surprising a caller still holding the original.
        rebuilt = Gem::Requirement.new(obj.as_list)
        rebuilt.requirements.each do |pair|
          pair[0].freeze
          pair[1].freeze
          pair.freeze
        end
        rebuilt.requirements.freeze

        # Real gap, found in review, round four -- before this had a real
        # caller: Gem::Requirement#== (and #eql?) lazily memoize
        # @_sorted_requirements/@_tilde_requirements on first call
        # (+@_sorted_requirements ||= requirements.sort_by(&:to_s)+,
        # confirmed directly against the real installed rubygems source).
        # Freezing +rebuilt+ before that first call ever happens means the
        # *first* +==+ against this frozen object raises FrozenError
        # trying to write that memo ivar -- confirmed live. A self-
        # comparison here forces the memoization to happen while the
        # object is still mutable, so every real +==+/+eql?+ call
        # afterward hits the already-populated cache instead of trying to
        # write to a frozen object. Deliberately the public +==+/+eql?+
        # rather than reaching into the private +_sorted_requirements+
        # method directly -- not this class's business to depend on
        # RubyGems' own internal method name surviving a future version.
        rebuilt == rebuilt # rubocop:disable Lint/BinaryOperatorWithIdenticalOperands, Lint/Void
        rebuilt.eql?(rebuilt)
        rebuilt.freeze
      when Classification
        # Real gap, found in review, round three: only msys2_packages went
        # through deep_freeze -- gem_name, gem_version, reason, and
        # platform_asset were passed through unchanged, still the caller's
        # own live String objects. Confirmed live: mutating the caller's
        # original gem_name after construction changed what the lock's own
        # returned classification reported, and reason.<< succeeded
        # directly through the returned reader despite the outer
        # Classification already being frozen. Every member now goes
        # through deep_freeze, state (a Symbol) included for consistency
        # even though Symbols are already immutable.
        Classification.new(
          state: deep_freeze(obj.state), gem_name: deep_freeze(obj.gem_name), gem_version: deep_freeze(obj.gem_version),
          reason: deep_freeze(obj.reason), platform_asset: deep_freeze(obj.platform_asset),
          msys2_packages: deep_freeze(obj.msys2_packages)
        ).freeze
      else
        # String, Symbol, Integer, true/false, nil -- #dup.freeze is
        # sufficient for all of these: String is the only one of these
        # with any internal mutable state, and #dup gives it a fresh,
        # independent buffer; Ruby's own immediate types
        # (Symbol/Integer/true/false/nil) are already frozen, so
        # #dup.freeze on them is a safe no-op, not a special case.
        obj.dup.freeze
      end
    end
  end
end
