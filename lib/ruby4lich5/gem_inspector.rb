# frozen_string_literal: true

require 'rubygems/package'

module Ruby4Lich5
  # Reads facts out of a downloaded +.gem+ package that {RubygemsClient}
  # cannot answer on its own -- whether it declares native extensions, and
  # whether it bundles a precompiled binary for a specific Ruby ABI.
  #
  # Must be given a path to an actual downloaded package (see
  # {RubygemsClient#download_gem}), not an installed gem's name. Verified
  # directly: +Gem::Specification.find_all_by_name+ returns empty +files+ and
  # +extensions+ for installed gems regardless of what's actually packaged;
  # only +Gem::Package.new(path).spec+ against the raw +.gem+ reflects reality.
  class GemInspector
    # @param gem_path [String] path to a downloaded +.gem+ file
    def initialize(gem_path)
      @spec = Gem::Package.new(gem_path).spec
    end

    # @return [Boolean] true when this package declares no native extensions
    #   at all -- meaningful only when +gem_path+ is the +"ruby"+ (source)
    #   platform package. A precompiled platform package legitimately has no
    #   extensions either, since there's nothing left to build; that is not
    #   the same thing as being a pure gem, so callers must not use this
    #   method against a non-"ruby" platform package to answer "is this pure?"
    # @return [Boolean]
    def extensions?
      !@spec.extensions.empty?
    end

    # @param ruby_abi [String] a Ruby ABI series, e.g. +"4.0"+
    # @return [Boolean] true when this package bundles a precompiled *native*
    #   binary (a +.so+, RubyInstaller/MinGW's own +RbConfig::CONFIG['DLEXT']+
    #   on the ucrt64 target this factory builds for -- not a Windows +.dll+)
    #   for the given ABI, under either real fat-gem convention seen in the
    #   wild: +lib/<gem_name>/<ruby_abi>/+ (e.g. sqlite3's own
    #   +lib/sqlite3/4.0/sqlite3_native.so+, confirmed directly against the
    #   real 2.9.5 package) or the flatter +lib/<ruby_abi>/+, gem-name
    #   omitted (e.g. ffi's own +lib/4.0/ffi_c.so+, confirmed directly
    #   against the real 1.17.4 package -- the gap that produced a false
    #   +:native_self_contained+ classification for a gem upstream actually
    #   already precompiles, found 2026-07-08). Checking only the nested
    #   form was an unverified assumption, not a documented convention two
    #   real, currently-classified gems don't even agree on.
    #
    #   Matching directory alone isn't enough -- a gem can legitimately ship
    #   a plain +.rb+ file under an ABI-named directory (a per-version pure-Ruby
    #   compat shim) that carries no compiled binary at all; only a +.so+
    #   there means "this ABI has a precompiled binary," confirmed real
    #   2026-07-08 by reproducing the false positive directly.
    def abi_present?(ruby_abi)
      nested = %r{\Alib/#{Regexp.escape(@spec.name)}/#{Regexp.escape(ruby_abi)}/.+\.so\z}
      flat = %r{\Alib/#{Regexp.escape(ruby_abi)}/.+\.so\z}
      @spec.files.any? { |f| f.match?(nested) || f.match?(flat) }
    end

    # @return [Boolean] true when the package includes its own +spec/+ or
    #   +test/+ directory plus a +Rakefile+ -- the signal used for
    #   best-effort bundled-test-suite reuse.
    #   Deliberately scoped to what's in the package we already fetched, not
    #   the gem's upstream git repo (which might have tests excluded from
    #   the packaged gem) -- that would mean a second fetch path and a
    #   "which URL/tag is authoritative" question for what's explicitly a
    #   nice-to-have, not a requirement.
    def runnable_test_suite?
      has_test_dir = @spec.files.any? { |f| f.start_with?('spec/', 'test/') }
      has_test_dir && @spec.files.include?('Rakefile')
    end
  end
end
