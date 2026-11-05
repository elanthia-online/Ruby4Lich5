# frozen_string_literal: true

require_relative 'executable_path'
require_relative 'subprocess_runner'

module Ruby4Lich5
  # Best-effort reuse of a gem's own bundled test suite. Purely
  # informational: a failing or
  # unattemptable suite is a data point reported to a human reviewer, never
  # a build gate. Attempting with what's already on hand (a Rakefile inside
  # the package we already fetched) -- not provisioning a bundled suite's
  # own dev dependencies (test-only gems, display servers for GUI tests) to
  # force it to run.
  class BundledTestRunner
    # The three possible outcomes of {#attempt} -- never an exception,
    # deliberately, since none of these should ever block a build.
    RESULTS = %i[passed failed not_attempted].freeze

    # @param run_command [#call] +->(rake_exe, install_dir) { {success:} }+
    #   -- runs the gem's own +Rakefile+ from +install_dir+ using the
    #   specific +rake_exe+ given. Defaults to a real subprocess; specs
    #   should inject a stub.
    # @param timeout_seconds [Numeric] wall-clock bound for the default
    #   subprocess, in case a gem's own bundled suite hangs. Unused when
    #   +run_command+ is overridden -- a caller-supplied callable is
    #   responsible for its own timeout behavior.
    def initialize(run_command: method(:default_run_command), timeout_seconds: SubprocessRunner::DEFAULT_TIMEOUT_SECONDS)
      @run_command = run_command
      @timeout_seconds = timeout_seconds
    end

    # @param gem_inspector [GemInspector] already pointed at the gem's
    #   downloaded package
    # @param install_dir [String] where the gem is actually installed/
    #   unpacked, to run its Rakefile from
    # @param rake_exe [String] absolute path to the specific +rake+
    #   executable belonging to the baked tree's Ruby. Deliberately
    #   required rather than resolved via PATH -- a bare +"rake"+ could
    #   belong to an entirely different Ruby than the one this gem was
    #   actually built for, silently exercising the wrong environment.
    # @return [Symbol] one of {RESULTS}
    # @raise [ArgumentError] if there's a bundled suite to run and +rake_exe+
    #   isn't an absolute, existing, executable path. Checked only once
    #   there's actually something to run it against -- a gem with no
    #   bundled tests (the common case) must still resolve to
    #   +:not_attempted+ regardless of whether +rake_exe+ happens to be
    #   valid, since it was never going to be used. Deliberately *not*
    #   swallowed into +:not_attempted+ by the rescue below when it does
    #   apply -- that rescue exists for the bundled suite itself failing to
    #   run, not for a caller's own programming error, which should surface
    #   loudly, not get silently filed alongside "no test suite" or "test
    #   runner crashed."
    def attempt(gem_inspector, install_dir, rake_exe:)
      return :not_attempted unless gem_inspector.runnable_test_suite?

      ExecutablePath.validate!(rake_exe, 'rake_exe')

      begin
        @run_command.call(rake_exe, install_dir).fetch(:success) ? :passed : :failed
      rescue StandardError
        :not_attempted
      end
    end

    private

    # @return [Hash] +{success:}+
    def default_run_command(rake_exe, install_dir)
      { success: SubprocessRunner.run(rake_exe, chdir: install_dir, timeout_seconds: @timeout_seconds).fetch(:success) }
    end
  end
end
