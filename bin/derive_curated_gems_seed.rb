#!/usr/bin/env ruby
# frozen_string_literal: true

# CLI entry point: derives config/curated-gems.json's seed content from the
# real, current staged/runtime closure, not a mechanical transform of
# KnownNativeGems' own hardcoded
# lists. Resolves live against RubyGems.org (real network, same
# ClosureResolver/Classifier/BuildPlanner chain bin/prepare_native_gems.rb
# already uses in production), so this is real, current ground truth, not a
# guess -- but that also means its output is data entering a
# security-relevant allowlist, meant for human review before commit, not
# generated-and-trusted.
#
# Re-runnable: same root name/version pairs (recorded in this run's own
# printed summary, and in spec/fixtures/curated-gems-seed/inputs.json for
# the currently-committed seed) reliably produce the same real output when
# actually run -- real, diffable evidence of how the seed was derived, not
# a one-time trusted transcript. The assembly logic itself
# (CuratedGemsSeedBuilder) is unit-tested with fake plan data separately;
# this script is the thin, directly-run part that does real I/O, in the
# same tradition as bin/prepare_native_gems.rb.
#
# Root selection matches ruby4-bundled-gems-suite.yml's own real defaults --
# the FULL runtime-gems default list (15 roots: gtk3 + 14 ordinary entries),
# not just native-runtime-gems. Real gap found in review: an earlier version
# of this script only resolved native-runtime-gems (sqlite3/ox/ffi/curses),
# missing every *pure* runtime-gems default (ascii_charts, os, redis,
# sequel, terminal-table, kramdown, tzinfo, tzinfo-data, concurrent-ruby,
# webrick) -- confirmed against the real shipped
# manifest/R4L5-gem-manifest.json, whose 31 real members' non-ruby_bundled
# subset matches exactly once corrected (its own 14 *units* group some of
# these roots together, e.g. tzinfo/tzinfo-data/concurrent-ruby into one
# "tzinfo-data-runtime" unit -- a shipping-artifact grouping this registry
# doesn't need to mirror, since each is still independently a real
# requested root).
# - gtk3, at the workflow's ruby-gnome-version default (4.3.9) -- the one
#   real special-case root version source, per Phase 17 section 8.
# - Every other runtime-gems default, each resolved to its real "latest" --
#   non-prerelease, maximal by real Gem::Version comparison, never a string
#   sort. This project has no formal "resolution lock" abstraction for this
#   yet (Phase 17 section 8's own future work); the same simple, correct
#   algorithm is used directly here rather than invented differently.
#
# All 15 roots are the current default *root* selection, so all 15 get
# bundle_default: true. Every other closure member (glib2, cairo, the real
# transitive gems like rake/json/fiddle/pkg-config/rexml/redis-client/
# connection_pool/unicode-display_width/unicode-emoji/etc.) gets
# approval: approved with bundle_default: false, per section 10's two
# separate equivalence assertions.
#
# Usage:
#   ruby bin/derive_curated_gems_seed.rb [output_json_path]
#     Defaults output_json_path to config/curated-gems.json.
#   GEM_PLATFORM=aarch64-mingw-ucrt ruby bin/derive_curated_gems_seed.rb
#     Derives the selected platform row instead (config/platforms.json).
#     Must run under a genuine Ruby for that platform (on windows-11-arm,
#     RubyInstaller's arm ruby.exe). Closures are resolved for the running
#     Ruby, so a host Ruby would classify for ARM but resolve dependencies
#     for itself: the ruby-platform sqlite3's mini_portile2, for one, would
#     be missing and then removed from the registry. A non-default platform
#     on any other Ruby stops before resolving or writing anything.
#     (The default x64 row keeps its existing behaviour: its recorded
#     provenance predates this check, and the precompiled x64 gems it
#     passes through carry no runtime dependencies.)
#
# Merge mode: an existing output file is updated, not replaced. Only the
# selected platform's targets are rewritten; other platforms' targets,
# gems curated only for another platform, and the hand-reviewed
# build_role/build_order/smoke_requires fields are kept
# (CuratedGemsSeedBuilder.merge_platform). The recorded provenance
# fixtures are x64's (the default platform's); another platform's run
# writes its own under spec/fixtures/curated-gems-seed/<platform>/ instead,
# so it never overwrites the evidence the x64 regeneration spec and the x64
# platform snapshot read.

require 'fileutils'
require 'json'
require_relative '../lib/ruby4lich5/build_planner'
require_relative '../lib/ruby4lich5/curated_gems_seed_builder'
require_relative '../lib/ruby4lich5/default_root_selection'
require_relative '../lib/ruby4lich5/msys2_bootstrap'
require_relative '../lib/ruby4lich5/rubygems_client'
require_relative '../lib/ruby4lich5/target_platform'

# Real duplication fix, PR F1: PLATFORM/RUBY_ABI/GTK3_VERSION/RUNTIME_GEMS
# used to be a local copy here, independent of the identical set
# bin/derive_dynamic_msys2_packages.rb also needs -- both now read from
# the one canonical source, {Ruby4Lich5::DefaultRootSelection}.
PLATFORM = Ruby4Lich5::DefaultRootSelection::PLATFORM
RUBY_ABI = Ruby4Lich5::DefaultRootSelection::RUBY_ABI

# **Real fix, per review 2026-07-13: the legacy uniform MSYS2 list is not
# copied verbatim into every self-contained entry.** An earlier draft
# passed the entire current install: list -- static toolchain included --
# into CuratedGemsSeedBuilder for every native_self_contained gem, which
# both violated the already-locked static-bootstrap-outside-the-registry
# boundary (Phase 17 section 8) and meant a package removed from one
# entry would simply be reintroduced by every other entry's own copy the
# moment they're aggregated -- a "reviewed delta" that could never actually
# happen.
#
# Two real corrections applied here:
# 1. Every one of Msys2Bootstrap::PACKAGES (base-devel, make,
#    gcc/binutils/pkgconf/libffi) is excluded from the literal list below --
#    generic toolchain, never gem-specific curation, matches the
#    already-locked boundary exactly. Not a programmatic subtraction (the
#    two lists don't overlap by construction, so there's nothing to
#    subtract at runtime); Msys2Bootstrap is required here so this file's
#    exclusion is checkable against the real, canonical set rather than a
#    second hand-typed copy of it, and so a future reader can verify the
#    claim directly instead of trusting this comment alone.
# 2. mingw-w64-ucrt-x86_64-sqlite3 is dropped entirely, not just moved to
#    the bootstrap set -- real, traceable reasoning, not an invented
#    per-gem list: it was only ever needed to compile the sqlite3 *gem*
#    itself, which no longer happens on x64 (sqlite3 is
#    native_pass_through there). On aarch64-mingw-ucrt, which has no
#    precompiled sqlite3, the gem is self-built from the bundled SQLite
#    source it compiles through mini_portile2, so it is not expected to
#    need an MSYS2 sqlite3 package either (unconfirmed until R5's first
#    ARM build). No other member of any of the 15 real resolved closures has
#    any relationship to libsqlite3.
#
# What remains (gobject-introspection[-runtime]/gtk3/pdcurses/ncurses) is
# still applied uniformly to all 12 self-contained gems today, not
# genuinely gem-specific -- **explicitly a known, transitional limitation**,
# not claimed as evidence-backed per-gem curation. Real per-gem
# decomposition (does `atk` actually need `mingw-w64-ucrt-x86_64-gtk3`
# directly? almost certainly not) is future curation work, deliberately not
# invented here without evidence -- same principle KnownNativeGems' own
# original design note already established.
#
# Named under the selected platform's MSYS2 package prefix
# (config/platforms.json), e.g. mingw-w64-ucrt-x86_64-gtk3 for x64-mingw-ucrt.
LEGACY_UNIFORM_GTK3_CURSES_PACKAGES = %w[
  gobject-introspection
  gobject-introspection-runtime
  gtk3
  pdcurses
  ncurses
].map { |name| "#{Ruby4Lich5::TargetPlatform.current.msys2_package_prefix}-#{name}" }.freeze

# Turns the exclusion claim in the comment above into a real, enforced
# invariant rather than a comment someone has to trust: if a future edit
# ever let a bootstrap package slip into this literal list (or Msys2Bootstrap
# itself grows to include one of these), this fails loudly here rather than
# silently reintroducing generic toolchain into gem-specific curation data.
overlap = LEGACY_UNIFORM_GTK3_CURSES_PACKAGES & Ruby4Lich5::Msys2Bootstrap::PACKAGES
raise "LEGACY_UNIFORM_GTK3_CURSES_PACKAGES must never overlap the static bootstrap set, got: #{overlap.inspect}" unless overlap.empty?

output_json_path = ARGV.first || File.expand_path('../config/curated-gems.json', __dir__)
default_platform = JSON.parse(File.read(File.expand_path('../config/target-ruby.json', __dir__))).fetch('platform')

if PLATFORM != default_platform && !Ruby4Lich5::DefaultRootSelection.genuine_target_ruby?(PLATFORM)
  abort "Seed derivation for #{PLATFORM} requires a genuine #{PLATFORM} Ruby; this Ruby is #{Gem::Platform.local} " \
        "(Gem.platforms #{Gem.platforms.map(&:to_s).inspect}). Nothing was written."
end

rubygems_client = Ruby4Lich5::RubygemsClient.new

# Real single-source-of-truth fix, PR D: this "latest" selection logic used
# to be a local, untested duplicate here -- formalized and unit-tested on
# RubygemsClient itself instead (see its own #latest_version doc comment).
# Real single-source-of-truth fix, PR F1: root selection itself (which
# names, gtk3's special-cased version) now reads from
# {Ruby4Lich5::DefaultRootSelection} instead of a second local copy.
roots = Ruby4Lich5::DefaultRootSelection.resolve_versions(rubygems_client: rubygems_client)

puts 'Resolving roots:'
roots.each { |name, version| puts "  #{name} #{version}" }

planner = Ruby4Lich5::BuildPlanner.new
root_plans = roots.each_with_object({}) do |(name, version), plans|
  puts "Resolving closure for #{name} #{version}..."
  plans[name] = planner.plan_for(name, version, platform: PLATFORM, ruby_abi: RUBY_ABI)
end

builder = Ruby4Lich5::CuratedGemsSeedBuilder.new(
  root_plans: root_plans, default_root_names: roots.keys, platform: PLATFORM, ruby_abi: RUBY_ABI,
  msys2_packages: LEGACY_UNIFORM_GTK3_CURSES_PACKAGES
)
seed = builder.build
existing = JSON.parse(File.read(output_json_path)) if File.exist?(output_json_path)
merged = Ruby4Lich5::CuratedGemsSeedBuilder.merge_platform(existing: existing, seed: seed, platform: PLATFORM)

File.write(output_json_path, "#{JSON.pretty_generate(merged)}\n")

provenance_dir = File.expand_path('../spec/fixtures/curated-gems-seed', __dir__)
provenance_dir = File.join(provenance_dir, PLATFORM) unless PLATFORM == default_platform
FileUtils.mkdir_p(provenance_dir)

# Real, regenerable provenance -- per review 2026-07-13: recording only
# root name/version pairs let a spec check the committed seed for internal
# *consistency*, but could never actually *regenerate* it, since the
# resolved/classified closure itself (what BuildPlanner#plan_for returned
# for each root -- every member, its classification, its dependency edges)
# was never captured. This snapshot is that missing evidence: normalized,
# JSON-serializable, and specifically what
# spec/curated_gems_seed_spec.rb's regeneration test feeds straight into
# CuratedGemsSeedBuilder to prove the committed config/curated-gems.json is
# exactly what this recorded resolution produces -- no live network
# required to verify it, and no need to mock the full Classifier/
# RubygemsClient chain to get real regeneration coverage.
def serialize_classification(classification)
  h = { 'state' => classification.state.to_s }
  h['msys2_packages'] = classification.msys2_packages if classification.self_contained?
  h['platform_asset'] = classification.platform_asset if classification.pass_through?
  h
end

snapshot = root_plans.transform_values do |plan|
  plan.map do |entry|
    { 'name' => entry.fetch(:name), 'version' => entry.fetch(:version),
      'classification' => serialize_classification(entry.fetch(:classification)),
      'runtime_dependency_names' => entry.fetch(:runtime_dependency_names) }
  end
end
snapshot_path = File.join(provenance_dir, 'resolved-plan.json')
File.write(snapshot_path, "#{JSON.pretty_generate(snapshot)}\n")
puts "Wrote resolved-plan snapshot to #{snapshot_path}"

# **Real fix, per review 2026-07-13: the regeneration spec was circular for
# the package recipe.** It read msys2_packages back out of the very
# CuratedGemRegistry loaded from the committed config/curated-gems.json it
# was asserting equality against -- a uniformly-wrong recipe baked into
# every self-contained entry would regenerate itself and the spec would
# still pass, verified directly by deliberately corrupting all 12 entries
# to the same bogus value and re-running it. Fixed: this script itself
# writes the actual recipe used this run into inputs.json, generated fresh
# here rather than hand-maintained separately (the same class of drift risk
# this whole item exists to close) -- the spec now reads msys2_packages
# from this file, genuinely independent of config/curated-gems.json's own
# content, not from the registry under test.
#
# This script fully rewrites inputs.json's machine-checked fields
# (roots/platform/ruby_abi/msys2_packages) every run; the "notes" field
# below is prose commentary, not verified data -- re-add any hand-written
# narrative notes after running this script, the same way a git diff would
# surface any other regenerated-file change for review before commit.
inputs = {
  'derived_at'     => Time.now.utc.strftime('%Y-%m-%d'),
  'derived_by'     => 'bin/derive_curated_gems_seed.rb',
  'platform'       => PLATFORM,
  'ruby_abi'       => RUBY_ABI,
  'roots'          => roots,
  'msys2_packages' => LEGACY_UNIFORM_GTK3_CURSES_PACKAGES,
  'notes'          => []
}
inputs_path = File.join(provenance_dir, 'inputs.json')
File.write(inputs_path, "#{JSON.pretty_generate(inputs)}\n")
puts "Wrote inputs record to #{inputs_path}"

gem_count = seed['gems'].size
default_roots = seed['gems'].select { |_, entry| entry['bundle_default'] }.keys.sort
self_contained = seed['gems'].select { |_, e| e.dig('targets', PLATFORM, RUBY_ABI, 'expected_classification') == 'native_self_contained' }.keys.sort
puts "Wrote #{gem_count} gem entries to #{output_json_path}"
puts "bundle_default: true roots: #{default_roots.join(', ')}"
puts "native_self_contained (MSYS2 self-build): #{self_contained.join(', ')}"
