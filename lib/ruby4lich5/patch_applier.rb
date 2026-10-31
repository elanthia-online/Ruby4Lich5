# frozen_string_literal: true

require 'fileutils'
require_relative 'safe_token'

module Ruby4Lich5
  # Applies real, curated source patches to a gem's already-extracted source
  # tree -- the home for source changes that are genuine code, not the small
  # require-path string substitutions the build workflow still does inline
  # (see the "future work" note in +ruby4-bundled-gems-suite.yml+).
  #
  # Patch definitions live under +patches/<gem_name>/*.rb+, one file per
  # patch, applied in filename order. Each file, when +eval+'d, must produce
  # a Hash in one of two shapes, depending on whether it's editing an
  # existing file or vendoring in a whole new one:
  #
  #   # Anchor-based edit of an existing file:
  #   {
  #     file: "ext/glib2/rbgobj_object.c",  # relative to the gem's source root
  #     marker: "some distinctive string",  # presence => already patched, skip
  #     steps: [
  #       { old: "...", new: "...", count: 1 },
  #       # ...
  #     ],
  #     cleanup: ->(content) { content.gsub(/\n\n\n+/, "\n\n") }  # optional
  #   }
  #
  #   # Whole-file creation (e.g. a rubygems_plugin.rb the real gem doesn't
  #   # ship at all -- there's no existing content to anchor against):
  #   {
  #     file: "lib/rubygems_plugin.rb",
  #     marker: "some distinctive string",  # presence => already created, skip
  #     content: "...",
  #   }
  #
  # A definition must supply exactly one of +steps+ or +content+ -- editing
  # and whole-file creation are different operations, not two flavors of the
  # same one, and a definition trying to do both (or neither) is almost
  # certainly a mistake worth failing on loudly rather than guessing intent.
  #
  # Each step's +old+ must appear in the file exactly +count+ times -- not
  # "at least," not "did something change," the exact expected count -- or
  # the whole patch aborts loudly, naming the file and step that didn't match
  # (almost always an upstream version drift). Exact anchor counts bound
  # packaging edits even when upstream source formatting changes. Retired
  # crash patches are excluded; Lich's GtkCompaction owns compaction safety.
  #
  # Whole-file creation is idempotent the same way: +marker+'s presence in
  # whatever the target currently holds (if it exists at all) means skip,
  # not re-check content equality -- consistent with how anchor-based patches
  # decide "already applied" for the same reason (a byte-for-byte diff would
  # make an intentional later revision to the vendored content look like
  # drift needing investigation, when it's just this file being updated).
  #
  # Patches we don't own (they're gem source, not our own code) don't get
  # their own spec-suite coverage inside +patches/+ itself -- {PatchApplier}
  # is the thing under test; the patch definitions are its fixtures.
  class PatchApplier
    # Raised when a patch's target file is missing, or a step's anchor
    # doesn't appear the exact expected number of times.
    class PatchError < StandardError; end

    # @param patches_root [String] directory containing one subdirectory per
    #   gem name, each holding that gem's +*.rb+ patch definitions. Defaults
    #   to the repo's top-level +patches/+ directory.
    def initialize(patches_root: File.expand_path('../../patches', __dir__))
      @patches_root = patches_root
    end

    # Applies every curated patch for one gem to its extracted source.
    #
    # @param gem_name [String]
    # @param source_dir [String] the gem's extracted source root -- each
    #   patch's +file+ is resolved relative to this directory
    # @return [Array<Hash>] one +{patch:, status:}+ entry per patch found,
    #   +status+ is +:applied+ or +:already_applied+
    # @raise [ArgumentError] if +gem_name+ is missing or contains unsafe
    #   characters
    # @raise [PatchError] if a definition supplies both or neither of
    #   +steps+/+content+; if an edit's target file is missing or would
    #   resolve outside +source_dir+; or if any step's anchor doesn't appear
    #   the exact expected number of times
    def apply_all(gem_name, source_dir)
      SafeToken.validate!(gem_name, 'gem name')

      patch_files_for(gem_name).map do |patch_file|
        { patch: File.basename(patch_file, '.rb'), status: apply_patch(patch_file, source_dir) }
      end
    end

    # @param gem_name [String]
    # @return [Boolean] whether any curated patch file exists for this gem
    #   at all -- for a caller (e.g. auto-generating a missing patch) that
    #   needs to know "is there already something here" without applying
    #   anything or duplicating {#patch_files_for}'s own directory lookup
    # @raise [ArgumentError] if +gem_name+ is missing or contains unsafe
    #   characters
    def patches_exist_for?(gem_name)
      SafeToken.validate!(gem_name, 'gem name')

      !patch_files_for(gem_name).empty?
    end

    private

    # @return [Array<String>] absolute paths, sorted by filename
    def patch_files_for(gem_name)
      dir = File.join(@patches_root, gem_name)
      return [] unless Dir.exist?(dir)

      Dir.glob(File.join(dir, '*.rb')).sort
    end

    # @return [Symbol] +:applied+ or +:already_applied+
    # @raise [PatchError] if the definition supplies both or neither of
    #   +steps+/+content+
    def apply_patch(patch_file, source_dir)
      definition = load_definition(patch_file)
      target = resolve_target(source_dir, definition.fetch(:file), patch_file)
      has_steps = definition.key?(:steps)
      has_content = definition.key?(:content)
      unless has_steps ^ has_content
        raise PatchError, "#{patch_file}: definition must supply exactly one of steps: or content:"
      end

      has_content ? apply_whole_file(definition, target) : apply_edit(definition, target, patch_file)
    end

    # Creates or overwrites +target+ wholesale with +definition[:content]+ --
    # for vendoring in a file the real gem doesn't ship at all, so there's no
    # existing content to anchor edits against.
    #
    # @return [Symbol] +:applied+ or +:already_applied+
    def apply_whole_file(definition, target)
      if File.exist?(target) && File.read(target).include?(definition.fetch(:marker))
        return :already_applied
      end

      FileUtils.mkdir_p(File.dirname(target))
      File.write(target, definition.fetch(:content))
      :applied
    end

    # Anchor-based edit of an existing file's content.
    #
    # @return [Symbol] +:applied+ or +:already_applied+
    # @raise [PatchError] if +target+ doesn't already exist, or any step's
    #   anchor doesn't appear the exact expected number of times
    def apply_edit(definition, target, patch_file)
      raise PatchError, "#{patch_file}: target file not found at #{target}" unless File.exist?(target)

      content = File.read(target)
      return :already_applied if content.include?(definition.fetch(:marker))

      definition.fetch(:steps).each_with_index do |step, index|
        content = apply_step(content, step, patch_file: patch_file, step_index: index)
      end
      content = definition[:cleanup].call(content) if definition[:cleanup]

      File.write(target, content)
      :applied
    end

    # @return [String] the file's content with this step's anchor replaced
    # @raise [PatchError] unless +old+ appears exactly +count+ times
    def apply_step(content, step, patch_file:, step_index:)
      old = step.fetch(:old)
      expected = step.fetch(:count)
      actual = content.scan(old).size
      unless actual == expected
        raise PatchError,
              "#{patch_file} step #{step_index}: expected #{expected} occurrence(s) of anchor, " \
              "found #{actual} -- likely an upstream version mismatch. Anchor: #{old[0, 60].inspect}"
      end

      # Block form, not content.gsub(old, new) -- gsub's String-replacement
      # form reinterprets backslash sequences like \1 or \& as backreferences
      # even though old is a plain String, not a Regexp with capture groups.
      # Verified directly: "TARGET".gsub("TARGET", "a\\1b") silently drops
      # the \1 and produces "ab", not "a\1b". The block form inserts its
      # return value literally, which is what a C-source replacement needs.
      new = step.fetch(:new)
      content.gsub(old) { new }
    end

    # Resolves a patch's declared +file+ against +source_dir+, and confirms
    # the result actually stays inside it. Patch definitions are trusted,
    # admin-reviewed content, not external input -- but a mistaken +file:+
    # value (e.g. a stray leading +../+) should fail loudly, not silently
    # write outside the extracted gem tree.
    #
    # @return [String] the absolute target path
    # @raise [PatchError] if the resolved path falls outside +source_dir+
    def resolve_target(source_dir, relative_file, patch_file)
      root = File.expand_path(source_dir)
      target = File.expand_path(relative_file, root)
      return target if target == root || target.start_with?(root + File::SEPARATOR)

      raise PatchError, "#{patch_file}: file #{relative_file.inspect} resolves outside source_dir #{root}"
    end

    # @return [Hash] the patch definition -- trusted, admin-reviewed content
    #   committed to this repo, the same trust level as any other code here
    def load_definition(patch_file)
      eval(File.read(patch_file), binding, patch_file)
    end
  end
end
