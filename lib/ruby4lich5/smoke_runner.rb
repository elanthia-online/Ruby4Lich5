# frozen_string_literal: true

require_relative 'executable_path'
require_relative 'subprocess_runner'

module Ruby4Lich5
  # Proves a resolved build plan's gems actually require successfully
  # together: write the plan out as a
  # throwaway Gemfile and run +Bundler.require+ against it, rather than
  # hand-deriving a require path per gem name (which don't always match --
  # +tzinfo-data+ requires as +tzinfo/data+, not literally +tzinfo-data+).
  # This also solves require *order* for free, since Bundler already
  # requires gems in dependency-resolved order.
  #
  # Deliberately gem-agnostic in scope, not deeper than that: this proves
  # requires succeed, nothing more (no real widget creation, no clean-runner
  # guarantee) -- deepening what smoke actually verifies is Phase 5's job
  # (gem-suite audit finding 2.9), not this.
  #
  # +Gtk.init+ is kept as the one narrow, justified exception: a real,
  # recurring "installed / no workie" failure history for GTK3 specifically
  # that a bare +require+ can't catch. Not a precedent for hand-writing
  # bespoke per-gem checks generally.
  class SmokeRunner
    # Raised when the requires (or the Gtk.init check, when gtk3 is in the
    # plan) fail in the target Ruby tree.
    class SmokeError < StandardError; end

    # @param run_ruby [#call] +->(ruby_exe, script, working_dir) {
    #   {success:, output:} }+ -- runs +script+ with the specific Ruby at
    #   +ruby_exe+. Defaults to a real subprocess; specs should inject a stub
    #   so they never actually shell out.
    # @param timeout_seconds [Numeric] wall-clock bound for the default
    #   subprocess, in case the plan's own requires (or Gtk.init) hang.
    #   Unused when +run_ruby+ is overridden -- a caller-supplied callable is
    #   responsible for its own timeout behavior.
    def initialize(run_ruby: method(:default_run_ruby), timeout_seconds: SubprocessRunner::DEFAULT_TIMEOUT_SECONDS)
      @run_ruby = run_ruby
      @timeout_seconds = timeout_seconds
    end

    # @param plan [Array<Hash>] +{name:, version:}+ entries in dependency
    #   order (e.g. from BuildPlanner#plan_for) -- only those two keys are
    #   read, so a full build-plan entry (which also carries
    #   +classification:+) works here unchanged
    # @param working_dir [String] the baked Ruby tree to smoke-test against
    #   -- where the throwaway Gemfile is written and where +ruby_exe+ runs
    # @param ruby_exe [String] absolute path to the specific Ruby executable
    #   inside the baked tree. Deliberately required, not guessed at from a
    #   directory-structure convention within +working_dir+: a bare +"ruby"+
    #   resolved via PATH would run whatever Ruby the CI runner (or a
    #   developer's shell) happens to have first, silently testing an
    #   unrelated, possibly-healthy Ruby install while the actual baked
    #   artifact could be broken -- exactly the false-confidence failure
    #   mode smoke-testing exists to catch, not produce.
    # @return [String] captured output, on success
    # @raise [ArgumentError] if +ruby_exe+ isn't an absolute, existing,
    #   executable path -- documenting it as such isn't enough to stop a
    #   caller from passing a bare +"ruby"+ and silently reintroducing
    #   PATH resolution
    # @raise [SmokeError] if the requires, or Gtk.init when gtk3 is present,
    #   fail
    def smoke(plan, working_dir, ruby_exe:)
      ExecutablePath.validate!(ruby_exe, 'ruby_exe')
      write_gemfile(plan, working_dir)
      result = @run_ruby.call(ruby_exe, smoke_script(plan), working_dir)
      raise SmokeError, "smoke failed in #{working_dir}: #{result.fetch(:output)}" unless result.fetch(:success)

      result.fetch(:output)
    end

    private

    # @return [void]
    def write_gemfile(plan, working_dir)
      lines = ['source "https://rubygems.org"']
      plan.each { |entry| lines << "gem #{entry.fetch(:name).inspect}, #{entry.fetch(:version).inspect}" }
      File.write(File.join(working_dir, 'Gemfile'), "#{lines.join("\n")}\n")
    end

    # @return [String] a one-line Ruby script requiring the whole plan via
    #   Bundler, plus the Gtk.init exception when gtk3 is in the plan
    def smoke_script(plan)
      lines = ["require 'bundler/setup'", 'Bundler.require']
      lines << 'Gtk.init' if plan.any? { |entry| entry.fetch(:name) == 'gtk3' }
      lines.join('; ')
    end

    # @return [Hash] +{success:, output:}+
    def default_run_ruby(ruby_exe, script, working_dir)
      SubprocessRunner.run(ruby_exe, '-e', script, chdir: working_dir, timeout_seconds: @timeout_seconds)
    end
  end
end
