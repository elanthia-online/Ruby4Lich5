# frozen_string_literal: true

require_relative 'safe_token'
require_relative 'known_native_gems'

module Ruby4Lich5
  # Normalizes a native gem's gemspec for the binary-gem packaging model --
  # the same transform applied identically to every native gem, unlike
  # {PatchApplier}'s gem-specific, anchor-keyed source patches. Doesn't fit
  # PatchApplier's shape at all: there's no per-gem patch file to look up,
  # because every native gem gets exactly the same four changes.
  #
  # Ported from the +Patch-Gemspec+ PowerShell function in
  # +ruby4-bundled-gems-suite.yml+, applied identically to all 10 native
  # gems there via a plain loop, not a per-gem patch file:
  #
  # 1. Strip +s.extensions = ...+ -- the binary gem ships a precompiled
  #    +.so+, not source to extconf against.
  # 2. Strip +pkg-config+/+native-package-installer+ runtime dependencies --
  #    build-only tooling a binary gem doesn't need at install time.
  # 3. Ensure +s.platform+ is set (only if not already present) -- marks the
  #    gem as platform-specific, required for it to be recognized as a
  #    binary gem for the target platform at all.
  # 4. Ensure the vendored +.so+/vendor files are included in +s.files+
  #    (only if not already present) -- otherwise the precompiled binaries
  #    and vendored DLLs never actually ship in the built package.
  #
  # Idempotent by construction, not by a marker check like {PatchApplier}:
  # steps 1-2 are no-ops once nothing matches; steps 3-4 explicitly check
  # for their own effect before applying it.
  class GemspecNormalizer
    # Raised when the gemspec is missing, or an anchor step 3/4 depends on
    # isn't found (a malformed or unexpectedly-shaped gemspec).
    class NormalizationError < StandardError; end

    # @param gem_name [String]
    # @param source_dir [String] the gem's own extracted source root --
    #   +<source_dir>/<gem_name>.gemspec+. Same convention as
    #   {PatchApplier#apply_all}'s +source_dir+ (the gem's own root, not a
    #   parent containing multiple gems) -- deliberately aligned so callers
    #   preparing one gem for build pass the same path to both.
    # @param platform [String] RubyGems platform tag, e.g. +"x64-mingw-ucrt"+
    # @return [void]
    # @raise [ArgumentError] if +gem_name+ or +platform+ is missing or
    #   contains unsafe characters
    # @raise [NormalizationError] if the gemspec is missing, or steps 3/4's
    #   anchor (+s.version =+ / a trailing bare +end+) isn't found
    def normalize(gem_name, source_dir, platform:)
      SafeToken.validate!(gem_name, 'gem name')
      SafeToken.validate!(platform, 'platform')

      gemspec_path = File.join(source_dir, "#{gem_name}.gemspec")
      raise NormalizationError, "gemspec not found for #{gem_name} at #{gemspec_path}" unless File.exist?(gemspec_path)

      content = File.read(gemspec_path)
      content = strip_build_only_dependencies(content)
      content = ensure_platform(content, platform, gemspec_path)
      content = ensure_binary_file_globs(content, gemspec_path)
      File.write(gemspec_path, content)
    end

    private

    # @return [String]
    def strip_build_only_dependencies(content)
      content = content.gsub(/^\s*s\.extensions\s*=.*\n/, '')
      KnownNativeGems.registry.names_for_role('tooling').reduce(content) do |text, name|
        # Preserve the existing quoted and serialized %q<> gemspec forms.
        text.gsub(/^.*add_runtime_dependency.*#{Regexp.escape(name)}.*\n/, '')
      end
    end

    # @return [String]
    # @raise [NormalizationError] if +s.platform+ isn't already present and
    #   no +s.version =+ line exists to insert after
    def ensure_platform(content, platform, gemspec_path)
      target_line = "  s.platform      = Gem::Platform.new(#{platform.inspect})\n"
      existing = content[/^\s*s\.platform\s*=.*$/]
      return content if existing && existing.include?(platform.inspect)
      return content.sub(/^\s*s\.platform\s*=.*\n/, target_line) if existing

      unless content.match?(/s\.version\s*=.*\n/)
        raise NormalizationError, "#{gemspec_path}: no s.version = line found to insert s.platform after"
      end

      content.sub(/(s\.version\s*=.*\n)/) { "#{Regexp.last_match(1)}#{target_line}" }
    end

    # @return [String]
    # @raise [NormalizationError] if a missing glob's anchor (trailing bare
    #   +end+) isn't found
    def ensure_binary_file_globs(content, gemspec_path)
      content = ensure_glob(content, 'lib/**/*.so', gemspec_path)
      ensure_glob(content, 'vendor/**/*', gemspec_path)
    end

    def ensure_glob(content, pattern, gemspec_path)
      glob_line = "Dir.glob(\"#{pattern}\")"
      return content if content.include?(glob_line)

      # rindex, not the first match -- a gemspec can contain an earlier,
      # unindented `end` closing some other top-level block (e.g. a bare
      # `if`/`unless`); inserting there would place s.files += ... outside
      # the Gem::Specification.new do |s| ... end block entirely.
      index = content.rindex(/^end\s*$/)
      unless index
        raise NormalizationError, "#{gemspec_path}: no trailing end found to insert file globs before"
      end

      "#{content[0...index]}  s.files += #{glob_line}\n#{content[index..]}"
    end
  end
end
