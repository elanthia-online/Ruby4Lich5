# frozen_string_literal: true

require 'rubygems'
require_relative 'build_planner'
require_relative 'gemspec_normalizer'
require_relative 'patch_applier'
require_relative 'patch_generator'
require_relative 'vendoring_role_classifier'
require_relative 'glib2_reachability'
require_relative 'safe_token'

module Ruby4Lich5
  # The Ruby decision layer's actual entry point for one build request:
  # resolve the closure, classify each gem, and -- for every gem in the
  # fixed Ruby-GNOME/GTK3 stack ({GTK3_STACK}) -- normalize its gemspec,
  # auto-generate the common vendor-dir + ABI-require patch if it has none
  # at all yet (item 7a, {PatchGenerator}), and apply whatever curated
  # patches exist for it, hand-written or generated.
  #
  # **Not every +:native_self_contained+ gem** -- real gap, found live
  # (2026-07-13, this project's first real dispatch of the "resolve once"
  # cutover): an earlier version of this class ran the same normalize/patch
  # sequence for *every* +:native_self_contained+ closure member, on the
  # theory that it "falls out" harmlessly for a gem that doesn't need it.
  # That's true for the Ruby-GNOME family itself (every member either has a
  # curated patch, successfully auto-generates one, or hits the one
  # documented dependency-check exemption -- see {#maybe_generate_patch}),
  # but false in general: +ox+ is a real, independently self-contained gem
  # with its own C extension that doesn't use Ruby-GNOME's bare
  # +require "*.so"+ loading convention at all, so the auto-patch-
  # generator's anchor search fails with {PatchGenerator::NoAnchorFound},
  # unrescued (its one exemption is narrower, a different extensions
  # shape). Confirmed live: +ox+ has never needed this treatment -- before
  # this cutover, it was compiled and repacked entirely through the
  # surrounding workflow's own separate mechanism, never routed through
  # this class at all.
  #
  # Every {GTK3_STACK} member goes through exactly this same sequence,
  # deliberately no per-gem special-casing among *them*:
  # {GemspecNormalizer} always runs (the same transform for every one of
  # them), patch generation only ever fires for a gem with zero existing
  # patches (never touches a gem that already has any, hand-written or
  # previously generated), and {PatchApplier} always runs last and simply
  # returns an empty result for a gem that still has no
  # +patches/<gem_name>/+ directory at all after that (a real, expected
  # outcome for a gem with no compiled extension of its own). Patching
  # "falls out" for a *stack* member that doesn't need it -- it is not
  # attempted at all for a self-contained gem outside the stack.
  #
  # +:pure+ and +:native_pass_through+ gems need neither -- a pure gem has no
  # native extension to normalize, and a pass-through gem is fetched as an
  # already-published platform binary, never locally compiled at all. A
  # +:native_self_contained+ gem outside {GTK3_STACK} needs neither either,
  # but only if it is individually confirmed safe first -- on the explicit
  # {REPACK_ONLY_GEMS} allowlist (today: +ox+ and +curses+, each with its
  # own cited evidence; see that constant's own doc comment). It is then
  # compiled via ordinary +gem install+ (real
  # +extconf.rb+ machinery, no manual gemspec surgery) and repacked -- never
  # patched -- entirely by the surrounding workflow's own repack step. **Not
  # "any future addition"** -- real gap, found in review 2026-07-13, the
  # same day as the fix above: an earlier version of this comment (and of
  # {REPACK_ONLY_GEMS} itself, which briefly also listed +curses+ as
  # "believed" safe) implied every non-stack self-contained gem gets this
  # treatment. That directly contradicts the fail-closed point of the
  # allowlist -- an unconfigured gem must raise ({UnconfiguredNativeGemError}),
  # never silently repack.
  #
  # Deliberately stops at "resolve, classify, normalize, patch" -- same
  # boundary {BuildPlanner} already draws for its own scope. The actual
  # native compile (MSYS2, gcc, DLL-closure-walking) stays exactly where it
  # already is, PowerShell invoked by the surrounding workflow once this
  # returns its plan -- see docs/DECISIONS.md's "Ruby drives decisions,
  # PowerShell drives OS-level mechanics" split.
  class NativeGemPreparer
    # Raised when a +:native_self_contained+ closure member is neither part
    # of the fixed Ruby-GNOME/GTK3 stack ({GTK3_STACK}) nor on the explicit
    # {REPACK_ONLY_GEMS} allowlist -- fails closed rather than silently
    # assuming a gem this project has never actually checked is safe to
    # compile-and-repack without patching. Real gap, found in review
    # 2026-07-13: an earlier version of the ox/curses fix treated "not in
    # GTK3_STACK" alone as proof of safety, which was verified for ox/
    # curses specifically but not for some future self-contained gem this
    # project hasn't yet examined -- a future addition could genuinely need
    # the same DLL-path/ABI-require patching {GTK3_STACK} members get, and
    # silently skipping it would be a real, silent correctness gap.
    class UnconfiguredNativeGemError < StandardError; end

    # The ordered GTK build/grouping roles share the reviewed registry with
    # GemManifestGenerator and workflow role emission.
    GTK3_STACK = KnownNativeGems.registry.names_for_role('gtk').freeze
    private_constant :GTK3_STACK

    # +:native_self_contained+ gems outside {GTK3_STACK} that are
    # individually confirmed -- not merely assumed -- to need no
    # normalize/patch treatment at all: no DLL-path/ABI-require issue, no
    # curated patch, compiled via ordinary +gem install+ (real
    # +extconf.rb+ machinery) and repacked by the surrounding workflow.
    # Every name here must cite its own real evidence, not "believed" --
    # real gap, found in review 2026-07-13: an earlier version of this
    # list included +curses+ as merely believed to behave the same way as
    # +ox+, exactly the assumption this allowlist exists to reject.
    #
    # - +ox+: confirmed live 2026-07-13, this project's first real dispatch
    #   of the "resolve once" cutover (see the class doc comment) --
    #   PatchGenerator::NoAnchorFound proved it does not fit the Ruby-GNOME
    #   normalize/patch shape at all, and the bare-repack path (no
    #   patching) is what it has always actually needed.
    # - +curses+: confirmed from a real historical run, not a new dispatch
    #   -- GitHub Actions run 29060526789 (2026-07-10, main, pre-F2, full
    #   green: build + smoke + publish). Its build job repacked +curses+
    #   through the exact same bare mechanism (fetch, +gem install+ via
    #   real +extconf.rb+ against MSYS2's +pdcurses+/+ncurses+ packages,
    #   retag) this class's own repack step still uses; its smoke job --
    #   a genuinely clean RubyInstaller, no MSYS2, no DevKit -- ran
    #   +require 'curses'+ successfully alongside every other runtime gem
    #   and printed "Clean packaged Ruby4/Lich runtime smoke OK". That
    #   proves +curses+'s compiled extension loads on a clean end-user
    #   machine with no DLL-path patching, the exact question this
    #   allowlist exists to answer -- re-added here on that citation, not
    #   on the earlier, unevidenced "believed" claim.
    #
    # Adding any future name here is a decision, not a default -- state
    # real evidence (a run ID, a date, what it actually proved) the same
    # way, or leave the name off and let {UnconfiguredNativeGemError} do
    # its job -- see that class's own doc comment.
    #
    # @return [Array<String>]
    REPACK_ONLY_GEMS = KnownNativeGems.registry.names_for_role('repack').freeze
    private_constant :REPACK_ONLY_GEMS

    # @param build_planner [BuildPlanner]
    # @param gemspec_normalizer [GemspecNormalizer]
    # @param patch_applier [PatchApplier]
    # @param patch_generator [PatchGenerator]
    # @param vendoring_role_classifier [VendoringRoleClassifier]
    def initialize(
      build_planner: BuildPlanner.new,
      gemspec_normalizer: GemspecNormalizer.new,
      patch_applier: PatchApplier.new,
      patch_generator: PatchGenerator.new,
      vendoring_role_classifier: VendoringRoleClassifier.new
    )
      @build_planner = build_planner
      @gemspec_normalizer = gemspec_normalizer
      @patch_applier = patch_applier
      @patch_generator = patch_generator
      @vendoring_role_classifier = vendoring_role_classifier
    end

    # @param gem_name [String]
    # @param version [String] exact version to prepare, e.g. +"3.5.6"+
    # @param platform [String] target RubyGems platform tag
    # @param ruby_abi [String] target Ruby ABI series, e.g. +"4.0"+
    # @param source_root [String] directory containing one already-extracted
    #   subdirectory per gem in the closure, named +<gem_name>+ -- the
    #   surrounding workflow's job to have downloaded and extracted before
    #   calling this; this class only prepares what's already there
    # @return [Array<Hash>] one +{name:, version:, state:, reason:,
    #   platform_asset:, msys2_packages:, vendoring_role:, patches_applied:}+
    #   entry per gem in the plan, in the same dependency order
    #   {BuildPlanner#plan_for} returns. +patches_applied+ is +[]+ for
    #   anything not +:native_self_contained+, and also +[]+ for a
    #   +:native_self_contained+ entry outside {GTK3_STACK} (see the class
    #   doc comment). +vendoring_role+ is +nil+ for the same non-self-
    #   contained entries -- see {VendoringRoleClassifier} for
    #   +:vendoring_root+ vs. +:vendoring_dependent+.
    # @raise [ClosureResolver::ResolutionError] if the requested gem+version
    #   can't be resolved at all
    # @raise [BuildPlanner::UnbuildableGemError] if any gem in the closure
    #   classifies as +:native_needs_system_lib+
    # @raise [UnconfiguredNativeGemError] if any gem in the closure
    #   classifies as +:native_self_contained+ but is neither part of
    #   {GTK3_STACK} nor on the explicit {REPACK_ONLY_GEMS} allowlist
    # @raise [GemspecNormalizer::NormalizationError] if a {GTK3_STACK}
    #   member's gemspec is missing or malformed in a way normalization
    #   can't work around
    # @raise [PatchApplier::PatchError] if a {GTK3_STACK} member's curated
    #   patch doesn't apply cleanly against its actual extracted source
    def prepare(gem_name, version, platform:, ruby_abi:, source_root:)
      plan = @build_planner.plan_for(gem_name, version, platform: platform, ruby_abi: ruby_abi)
      prepare_from_plan(plan, platform: platform, source_root: source_root)
    end

    # The locked-input counterpart to {#prepare} -- takes an already-resolved
    # plan instead of calling {BuildPlanner#plan_for} itself, so a caller
    # holding a real {ResolutionLock} (built once, elsewhere, per
    # docs/DECISIONS.md's "resolve once" cutover) can normalize/patch the
    # GTK subset of that same lock without a second, independent live
    # resolve -- the exact "structurally impossible to reach a live
    # resolve" guarantee {StagedClosureRevalidator} already relies on,
    # extended to this class.
    #
    # @param plan [Array<Hash>] {BuildPlanner#plan_for}'s own output shape
    #   (+{name:, version:, classification:, runtime_dependencies:,
    #   runtime_dependency_names:}+ per entry, dependency order) -- a
    #   {ResolutionLock}'s +#closure+ carries the first four but not
    #   +runtime_dependency_names+; the caller translating a lock's closure
    #   into this shape is responsible for deriving it
    #   (+runtime_dependencies.map { |d| d.fetch(:name) }+) before calling
    #   this, matching {ClosureMerger}'s own documented shape contract
    #   rather than this class silently accepting a narrower Hash and
    #   raising a confusing +KeyError+ deep inside
    #   {VendoringRoleClassifier#classify}
    # @param platform [String] target RubyGems platform tag
    # @param source_root [String] same contract as {#prepare}'s own
    #   +source_root+
    # @return [Array<Hash>] same shape as {#prepare}'s own return value
    # @raise [BuildPlanner::UnbuildableGemError] if any plan entry
    #   classifies as +:native_needs_system_lib+ -- real gap, found in
    #   review: {#prepare} gets this check for free from
    #   {BuildPlanner#plan_for} itself (it raises before ever returning a
    #   plan containing one), but a plan built elsewhere (a lock's own
    #   closure) was never passed through that same check, so this method
    #   re-asserts it explicitly rather than silently normalizing/patching
    #   a gem this project already knows cannot be built
    # @raise [UnconfiguredNativeGemError] see {#prepare}
    # @raise [GemspecNormalizer::NormalizationError] see {#prepare}
    # @raise [PatchApplier::PatchError] see {#prepare}
    def prepare_from_plan(plan, platform:, source_root:)
      unbuildable = plan.select { |entry| entry.fetch(:classification).needs_system_lib? }
      unless unbuildable.empty?
        # Matches BuildPlanner#plan_for's own "name version: reason" message
        # shape exactly, one entry per line -- same wording a caller would
        # have seen from #prepare on the identical classification, just
        # covering every unbuildable entry at once rather than only the
        # first (a lock's plan is already fully resolved, so there is no
        # reason to make a caller fix one and re-run to discover the next).
        names = unbuildable.map { |entry| "#{entry.fetch(:name)} #{entry.fetch(:version)}: #{entry.fetch(:classification).reason}" }
        raise BuildPlanner::UnbuildableGemError, "plan contains unbuildable gem(s):\n#{names.join("\n")}"
      end

      # Preflighted here, before any normalize/patch call -- real gap,
      # found in review 2026-07-13: this check used to live only inside
      # #prepare_one, discovered entry by entry during the #map below. A
      # plan ordered [gtk3, some-new-gem] would normalize/patch gtk3 (real
      # filesystem mutations) before ever reaching some-new-gem and raising
      # -- the exact "fail before any mutation" guarantee the unbuildable
      # check above already gets right, this one didn't.
      unconfigured = plan.select { |entry| unconfigured_native_self_contained?(entry.fetch(:classification), entry.fetch(:name)) }
      raise_unconfigured!(unconfigured.map { |entry| entry.fetch(:name) }) unless unconfigured.empty?

      vendoring_roles = @vendoring_role_classifier.classify(plan)

      plan.map { |entry| prepare_one(entry, platform: platform, source_root: source_root, vendoring_roles: vendoring_roles, plan: plan) }
    end

    # RubyGems' own extension declarations end up runnable through several
    # real, quite different builders -- extconf.rb (mkmf), configure,
    # Rakefile/mkrf_conf.rb, and, for newer gems, CMakeLists.txt or
    # Cargo.toml (Rust). Guessing which filenames "mean compiled" and which
    # don't is exactly the wrong shape for a check whose only job is
    # deciding whether it's safe to silently skip generating a patch --
    # enumerating known-safe builder names fails *open* for every filename
    # not yet on the list, including ones that don't exist yet. Only this
    # one exact, independently verified task -- ruby-gnome's own
    # dependency-check convention, confirmed real against atk/gdk3/
    # gdk_pixbuf2's actual gemspecs 2026-07-08, confirmed to compile nothing
    # -- is exempted. Every other declared extension, known builder or not,
    # fails closed.
    DEPENDENCY_CHECK_TASK = 'dependency-check/Rakefile'
    private_constant :DEPENDENCY_CHECK_TASK

    private

    # @return [Hash]
    def prepare_one(entry, platform:, source_root:, vendoring_roles:, plan:)
      classification = entry.fetch(:classification)
      name = entry.fetch(:name)
      gem_root = File.join(source_root, name)

      patches_applied = self_contained_patches_applied(classification, name, gem_root, platform, plan)

      {
        name: name,
        version: entry.fetch(:version),
        state: classification.state,
        reason: classification.reason,
        platform_asset: classification.platform_asset,
        msys2_packages: classification.msys2_packages,
        vendoring_role: vendoring_roles[name],
        patches_applied: patches_applied
      }
    end

    # @return [Boolean] true for a +:native_self_contained+ gem that is
    #   neither part of {GTK3_STACK} nor on the explicit {REPACK_ONLY_GEMS}
    #   allowlist -- the one condition {#prepare_from_plan} preflights for
    #   the whole plan before any mutation, and {#self_contained_patches_applied}
    #   re-checks per entry as a structural (should be unreachable) backstop.
    def unconfigured_native_self_contained?(classification, name)
      classification.self_contained? && !GTK3_STACK.include?(name) && !REPACK_ONLY_GEMS.include?(name)
    end

    # @param names [Array<String>]
    # @raise [UnconfiguredNativeGemError]
    def raise_unconfigured!(names)
      raise UnconfiguredNativeGemError,
            "gem(s) #{names.join(', ')} classify native_self_contained but are neither part of the fixed " \
            "Ruby-GNOME/GTK3 stack (#{GTK3_STACK.join(', ')}) nor on the explicit repack-only allowlist " \
            "(#{REPACK_ONLY_GEMS.join(', ')}). Add each to REPACK_ONLY_GEMS only after confirming -- the same " \
            'way ox was confirmed live -- that it genuinely needs no vendor-dir/ABI-require patching; do not ' \
            'assume it.'
    end

    # @return [Array<Hash>] {PatchApplier#apply_all}'s own result for a
    #   {GTK3_STACK} member; +[]+ for anything not +:native_self_contained+
    #   at all; for a +:native_self_contained+ gem outside {GTK3_STACK},
    #   +[]+ only if it is on the explicit {REPACK_ONLY_GEMS} allowlist.
    #   The remaining case ({UnconfiguredNativeGemError}) should already be
    #   unreachable here -- {#prepare_from_plan} preflights the whole plan
    #   for it first -- but is re-checked per entry anyway as a structural
    #   backstop, not trusted to the caller alone.
    # @raise [UnconfiguredNativeGemError]
    def self_contained_patches_applied(classification, name, gem_root, platform, plan)
      return [] unless classification.self_contained?
      return prepare_self_contained(name, gem_root, platform, plan) if GTK3_STACK.include?(name)
      return [] if REPACK_ONLY_GEMS.include?(name)

      raise_unconfigured!([name])
    end

    # @return [Array<Hash>] {PatchApplier#apply_all}'s return value verbatim
    def prepare_self_contained(name, gem_root, platform, plan)
      # Captured before normalize -- GemspecNormalizer strips the gemspec's
      # own s.extensions = ... line as part of its own job (a binary gem
      # ships a precompiled .so, not source to extconf against), so this
      # has to run first or there would be nothing left to read.
      extensions = declared_extensions(name, gem_root)

      @gemspec_normalizer.normalize(name, gem_root, platform: platform)
      maybe_generate_patch(name, gem_root, plan, extensions: extensions)
      @patch_applier.apply_all(name, gem_root)
    end

    # Auto-generates the vendor-dir + ABI-require patch (item 7a) for a gem
    # that has no curated patch at all yet -- never for one that already has
    # any, hand-written or previously generated, so a bespoke addition
    # layered on top of the template (gobject-introspection's typelib/
    # fontconfig setup) or a narrower shape that doesn't need the full
    # template (cairo-gobject's require-abi-only) never gets silently
    # clobbered.
    #
    # PatchGenerator::NoAnchorFound is treated as success only for the one
    # verified-safe extensions shape (see DEPENDENCY_CHECK_TASK). Without
    # that check, "our regex didn't recognize this gem's anchor syntax" and
    # "this gem genuinely has nothing to require" are indistinguishable, and
    # the former would silently ship a gem missing its DLL-path patch --
    # exactly the failure mode 7a was scoped to fail loudly on, not paper
    # over. AmbiguousAnchor (more than one candidate, genuinely unclear)
    # always propagates regardless.
    def maybe_generate_patch(name, gem_root, plan, extensions:)
      return if @patch_applier.patches_exist_for?(name)

      @patch_generator.generate(name, gem_root, depends_on_glib2: Glib2Reachability.reachable?(name, plan))
    rescue PatchGenerator::NoAnchorFound
      raise unless extensions == [DEPENDENCY_CHECK_TASK]
    end

    # @return [Array<String>] this gem's own +extensions+ exactly as its
    #   gemspec declares them, forward-slash-normalized and sorted --
    #   deliberately read straight from the gemspec file rather than
    #   inferred from filenames on disk, so a builder this class has never
    #   heard of (a new RubyGems extension mechanism, or one simply not yet
    #   in {DEPENDENCY_CHECK_TASK}'s exemption) is never silently treated as
    #   "safe."
    # @raise [ArgumentError] if +name+ is missing or contains unsafe characters
    # @raise [GemspecNormalizer::NormalizationError] if the gemspec can't be
    #   loaded at all
    def declared_extensions(name, gem_root)
      SafeToken.validate!(name, 'gem name')
      path = File.join(gem_root, "#{name}.gemspec")
      spec = Gem::Specification.load(path)

      unless spec
        raise GemspecNormalizer::NormalizationError, "could not load extension declarations from #{path}"
      end

      spec.extensions.map { |entry| entry.tr('\\', '/') }.sort
    end
  end
end
