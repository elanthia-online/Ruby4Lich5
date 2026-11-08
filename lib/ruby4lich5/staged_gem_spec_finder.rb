# frozen_string_literal: true

require 'rubygems/package'

module Ruby4Lich5
  # A +find_specs+ callable for {InstalledGemClosure} that reads gemspecs
  # directly from staged +.gem+ files on disk, rather than querying a live
  # Ruby's own installed-gem registry.
  #
  # Real gap this closes, found in review 2026-07-10: the publish job that
  # runs the gem manifest generator downloads only +dist/pkg+ (the staged
  # +.gem+ files themselves) -- it never restores the actual installed-gem
  # environment the build job assembled and then discarded when its runner
  # terminated. {InstalledGemClosure}'s default
  # +Gem::Specification.find_all_by_name+ would find nothing there (or,
  # worse, resolve to whatever happens to be incidentally installed on that
  # generic runner). Every +.gem+ file already carries its own embedded
  # gemspec (including real runtime dependencies) -- reading it directly
  # needs nothing "installed" at all, just the file on disk. Same technique
  # already established in this project for cairo's synthesized gemspec
  # (+Gem::Package.new(path).spec+).
  class StagedGemSpecFinder
    # Raised when a staged +.gem+ file's own embedded metadata can't be
    # read at all -- a genuinely corrupt or malformed archive, not something
    # {InstalledGemClosure} could ever recover from. Names the offending
    # path explicitly (real gap, found in review 2026-07-11:
    # +Gem::Package+'s own raised errors don't reliably identify which of
    # potentially many staged files actually failed).
    class CorruptGemError < StandardError; end

    # @param pkg_dir [String] directory containing every staged +.gem+ file
    def initialize(pkg_dir:)
      @pkg_dir = pkg_dir
    end

    # @param name [String]
    # @return [Array<Gem::Specification>] every staged spec matching +name+
    #   (ordinarily zero or one -- more than one would mean two differently-
    #   versioned copies of the same gem were staged, a real anomaly
    #   {InstalledGemClosure} already handles by picking the highest version)
    # @raise [CorruptGemError]
    def call(name)
      specs_by_name.fetch(name, [])
    end

    private

    # @return [Hash{String => Array<Gem::Specification>}]
    # @raise [CorruptGemError]
    def specs_by_name
      # Glob relative to base: so a Windows pkg_dir such as D:\a\...\dist\pkg is
      # never parsed as a pattern, where each backslash would escape the next
      # character and silently match nothing.
      @specs_by_name ||= Dir.glob('*.gem', base: @pkg_dir).sort.each_with_object(Hash.new { |h, k| h[k] = [] }) do |name, index|
        path = File.join(@pkg_dir, name)
        spec = begin
          Gem::Package.new(path).spec
        rescue StandardError => e
          raise CorruptGemError, "could not read gemspec from staged file #{path}: #{e.class}: #{e.message}"
        end
        index[spec.name] << spec
      end
    end
  end
end
