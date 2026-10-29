# frozen_string_literal: true

require_relative 'rubygems_client'
require_relative 'known_native_gems'
require 'json'

module Ruby4Lich5
  # The one canonical source for "which roots, at which target, does a
  # default run select" -- matches +ruby4-bundled-gems-suite.yml+'s own
  # real defaults (+ruby-gnome-version+ plus the full +runtime-gems+
  # default list, 15 roots total), reused by both
  # +bin/derive_curated_gems_seed.rb+ (PR B) and
  # +bin/derive_dynamic_msys2_packages.rb+ (PR F1) rather than each
  # keeping its own copy -- real duplication risk this project has already
  # found and fixed twice this session (`SCHEMA_VERSION`, the
  # `classification`/`closure_entry` spec helpers).
  #
  # **Deliberately never resolves `cairo` as an independent root -- this
  # is the actual fix for the real `cairo-version`/closure mismatch gap
  # named in Phase 17 SS8, not a separate mechanism.** Checked directly:
  # only `gtk3` is ever a resolver root; `cairo` is always a *transitive
  # member* of gtk3's own resolved closure. The old, replaced design
  # independently fetched a `cairo-version` input with nothing enforcing
  # it agreed with what the gtk3 closure actually resolved. As long as
  # nothing here ever introduces a second, independent `cairo` root --
  # which this module's own return shape structurally cannot do, since it
  # only ever emits {GTK3_VERSION} plus {RUNTIME_GEMS} -- cairo's version
  # is simply whatever the real, resolved gtk3 closure contains. No
  # separate derivation step exists, or is needed, to "fix" this.
  module DefaultRootSelection
    # Raised when +runtime_gems:+ names +'cairo'+ explicitly -- real gap,
    # found in audit 2026-07-13: this module's own header comment already
    # documents "cairo is never an independent root" as a structural
    # guarantee, but +resolve_versions+ itself never actually enforced it;
    # a caller passing +runtime_gems: ['cairo']+ resolved it a second time
    # via +RubygemsClient#latest_version+, reproduced live returning
    # +{"gtk3"=>"4.3.6", "cairo"=>"9.9.9"}+ -- a version independent of,
    # and free to disagree with, gtk3's own real resolved closure. Fails
    # loudly instead, the same "reject, don't silently drop" choice this
    # module's own gtk3 special-casing already makes.
    class ReservedRootError < StandardError; end

    # @return [String]
    PLATFORM = 'x64-mingw-ucrt'

    # @return [String]
    RUBY_ABI = '4.0'

    # @return [String] matches +ruby4-bundled-gems-suite.yml+'s own
    #   +ruby-gnome-version+ default -- the one real special-case root
    #   version source (Phase 17 SS8); every other root resolves via
    #   {RubygemsClient#latest_version}
    GTK3_VERSION = JSON.parse(File.read(File.expand_path('../../config/target-ruby.json', __dir__))).fetch('gtk_version')

    # @return [Array<String>] every other +runtime-gems+ default root,
    #   matching +ruby4-bundled-gems-suite.yml+'s own real default list --
    #   confirmed against the real shipped `manifest/R4L5-gem-manifest.json`
    #   in PR B, not assumed
    RUNTIME_GEMS = (KnownNativeGems.registry.bundle_default_roots - ['gtk3']).freeze

    # @param rubygems_client [RubygemsClient]
    # @param gtk3_version [String] defaults to {GTK3_VERSION} -- overridable
    #   so a caller resolving against a real workflow's own
    #   +ruby-gnome-version+ dispatch input (e.g.
    #   +ruby4-bundled-gems-suite.yml+'s own F2 cutover) uses that value
    #   instead of this module's fixed default. gtk3 stays the one root
    #   with an externally-supplied version either way -- never a
    #   {RubygemsClient#latest_version} lookup, matching Phase 17 SS8's own
    #   design.
    # @param runtime_gems [Array<String>] defaults to {RUNTIME_GEMS} --
    #   overridable the same way, for the same real-workflow-input reason.
    #   Every entry still resolves via {RubygemsClient#latest_version}
    #   ("latest," never a caller-supplied version) -- only *which* names
    #   get asked about is overridable, not how each one resolves
    # @return [Hash{String => String}] +gtk3+ plus every requested runtime
    #   root, each resolved to its exact selected version -- the
    #   +requested_roots+ shape {ResolutionLock} and
    #   {Ruby4Lich5::CuratedGemsSeedBuilder} both expect
    def self.resolve_versions(rubygems_client:, gtk3_version: GTK3_VERSION, runtime_gems: RUNTIME_GEMS)
      if runtime_gems.include?('cairo')
        raise ReservedRootError, "runtime_gems must not include 'cairo' -- cairo is never an independent root " \
                                  "(see DefaultRootSelection's own header comment); its version always comes " \
                                  "from gtk3's own resolved closure"
      end

      # Excludes 'gtk3' from the runtime_gems side of the merge -- real gap,
      # found in review 2026-07-13: bin/resolve_bundle_lock.rb already
      # filters 'gtk3' out of its own runtime_gems_csv before calling here
      # (the real workflow's runtime-gems default input starts with the
      # bare word "gtk3"), but that protection lived only in that one
      # caller. Without it here too, Hash#merge's right-hand side would
      # silently win, letting a live rubygems_client.latest_version('gtk3')
      # result overwrite the caller-supplied gtk3_version -- the exact
      # double-resolution bug this module's own header comment already
      # promises structurally cannot happen.
      { 'gtk3' => gtk3_version }.merge(
        runtime_gems.reject { |name| name == 'gtk3' }.to_h { |name| [name, rubygems_client.latest_version(name)] }
      )
    end
  end
end
