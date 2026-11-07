# frozen_string_literal: true

module Ruby4Lich5
  # The single, unified policy check --
  # every non-+ruby_bundled+ member of a resolved closure must be approved
  # in the curated-gem registry for the run's exact platform/ABI, at
  # exactly the classification this run actually observed. Collapses what
  # were two separate failure modes into one check, both fail-closed:
  #
  # - **Unknown**: a shipped gem has no approved registry entry at all for
  #   this exact target (e.g. hand-typed into a selection override).
  # - **Drift**: a shipped gem has an approved entry, but this run's own
  #   live-observed {Classification} no longer matches the registry's
  #   +expected_classification+ (e.g. upstream starts shipping its own
  #   precompiled build, flipping +native_self_contained+ to
  #   +native_pass_through+).
  #
  # Generation-time only -- per SS7, this gate is never re-run at
  # promotion; that's a separate concern (Phase 15 step 3), not this
  # class's job.
  class RegistryPolicyGate
    # Raised when {#check!} finds one or more violations -- every
    # violation found, not just the first, so a maintainer sees the full
    # picture in one run rather than fixing one gem at a time across
    # repeated dispatches.
    class GateFailure < StandardError; end

    # @param registry [CuratedGemRegistry] must have been loaded via
    #   {CuratedGemRegistry.load_file} -- {#check!} needs its real
    #   +content_digest+ to bind it to the lock it's evaluating
    # @param registry_commit_sha [String] the exact git commit SHA
    #   +registry+ was loaded at -- the caller's own responsibility to
    #   determine (e.g. `git rev-parse HEAD`), the same seam discipline
    #   {ResolutionLock} already established for this exact pair of values;
    #   this class never shells out to Git itself
    def initialize(registry:, registry_commit_sha:)
      @registry = registry
      @registry_commit_sha = registry_commit_sha
    end

    # @param lock [ResolutionLock]
    # @raise [GateFailure] if +registry+'s own identity (commit SHA +
    #   content digest) doesn't match what +lock+ recorded as the registry
    #   in effect for that run -- real gap, found in review: without this,
    #   nothing stopped evaluating a lock against a *different* registry
    #   state than the one it actually claims, silently defeating the
    #   whole point of recording commit+digest identity on the lock at all.
    #   Confirmed live before this fix: a lock's own digest was simply
    #   never read anywhere in this class.
    # @raise [GateFailure] if any non-+ruby_bundled+ closure member is
    #   unknown to the registry for this run's exact target, or its
    #   observed classification has drifted from what the registry expects
    def check!(lock)
      verify_registry_identity!(lock)

      violations = lock.closure.filter_map do |entry|
        next if entry.fetch(:classification).ruby_bundled?

        violation_for(entry, lock)
      end
      return if violations.empty?

      raise GateFailure, "registry policy gate failed:\n#{violations.join("\n")}"
    end

    private

    # @raise [GateFailure]
    def verify_registry_identity!(lock)
      return if @registry_commit_sha == lock.registry_commit_sha && @registry.content_digest == lock.registry_content_digest

      raise GateFailure,
            "registry policy gate failed: the registry passed to this gate does not match the registry this lock " \
            "was resolved against -- lock recorded commit #{lock.registry_commit_sha.inspect}/" \
            "digest #{lock.registry_content_digest.inspect}, this gate was given commit #{@registry_commit_sha.inspect}/" \
            "digest #{@registry.content_digest.inspect}"
    end

    # @return [String, nil] a description of the violation, or +nil+ if
    #   +entry+ passes the gate cleanly
    def violation_for(entry, lock)
      name = entry.fetch(:name)

      unless @registry.approved?(name, lock.platform, lock.ruby_abi)
        return "#{name.inspect}: unknown -- no approved registry entry for #{lock.platform}/#{lock.ruby_abi}"
      end

      observed = entry.fetch(:classification).state.to_s
      expected = @registry.classification_for(name, lock.platform, lock.ruby_abi)
      return if observed == expected

      "#{name.inspect}: classification drift -- registry expects #{expected.inspect}, this run observed #{observed.inspect}"
    end
  end
end
