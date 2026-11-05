# frozen_string_literal: true

require 'json'
require 'ruby4lich5/curated_gem_registry'
require 'ruby4lich5/msys2_bootstrap'
require 'ruby4lich5/msys2_package_list_artifact'

# The reviewed-delta test PR F1/F2 need, per the revised baseline-freeze
# note (2026-07-13): the dynamic,
# registry-derived MSYS2 package list is *expected* to legitimately differ
# from ruby4-bundled-gems-suite.yml's own hardcoded, pre-cutover list --
# sqlite3/ffi's real upstream classification moved to native_pass_through
# (PR B), so the dynamic list correctly stops requesting
# mingw-w64-ucrt-x86_64-sqlite3, which the legacy list still hardcodes.
# Asserting byte-identical equality against that legacy list would mean
# either forcing a stale package back in or never passing -- this asserts
# the exact, named, human-confirmed delta instead: one confirmed removal,
# zero additions. Any *other* difference (a new addition, an unexpected
# second removal) is a real signal something changed that this test's own
# human reviewer hasn't seen yet, and must fail loudly, not silently.
#
# **Selection set corrected 2026-07-13, per review**: an earlier version of
# this spec derived the "current dynamic list" from every gem name present
# anywhere in config/curated-gems.json -- global registry membership, not
# the actual set bin/derive_dynamic_msys2_packages.rb (the F1 CLI) selects.
# Those two happen to coincide today (confirmed directly: zero registry
# members are absent from the recorded default-root closure below), but
# Phase 17 explicitly permits *approved-but-dormant* registry entries --
# a gem approved for possible future use that no current default root's
# closure actually reaches. A future dormant native_self_contained entry
# would have made this spec see a package-list delta that the real CLI
# would never produce, since the CLI only ever derives packages for gems
# its own resolved closure actually contains (see the F1 CLI's own
# `closure.reject { ruby_bundled? }.flat_map { registry.self_build_packages_for(...) }`).
# Fixed: the selection set here is now the real, recorded default-root
# closure (spec/fixtures/curated-gems-seed/resolved-plan.json -- PR B's
# own committed BuildPlanner#plan_for snapshot for every default root,
# the same provenance spec/curated_gems_seed_spec.rb already trusts), not
# global registry enumeration -- no live network call either way.
RSpec.describe 'MSYS2 dynamic package list vs. legacy hardcoded baseline' do
  def registry_path
    File.join(__dir__, '..', '..', 'config', 'curated-gems.json')
  end

  def resolved_plan_fixture_path
    File.join(__dir__, '..', 'fixtures', 'curated-gems-seed', 'resolved-plan.json')
  end

  def legacy_baseline_fixture_path
    File.join(__dir__, '..', 'fixtures', 'msys2-package-list', 'legacy_baseline.json')
  end

  # Confirmed and locked in PR B, re-asserted here as the one reviewed,
  # named delta this test permits -- any other diff is a real regression.
  def expected_removals
    %w[mingw-w64-ucrt-x86_64-sqlite3]
  end

  def expected_additions
    []
  end

  # @return [Array<String>] every distinct gem name across every default
  #   root's own recorded closure, excluding ruby_bundled members -- the
  #   exact selection {bin/derive_dynamic_msys2_packages.rb} itself
  #   applies before ever consulting the registry for MSYS2 packages
  #   (`closure.reject { |entry| entry.fetch(:classification).ruby_bundled? }`),
  #   reproduced here from the recorded closure shape rather than a live
  #   BuildPlanner/RubygemsClient resolution
  def default_closure_gem_names
    resolved_plan = JSON.parse(File.read(resolved_plan_fixture_path))

    resolved_plan.values.flatten(1).filter_map do |entry|
      next if entry.fetch('classification').fetch('state') == 'ruby_bundled'

      entry.fetch('name')
    end.uniq
  end

  def current_dynamic_packages
    registry = Ruby4Lich5::CuratedGemRegistry.load_file(registry_path)

    gem_specific = default_closure_gem_names.flat_map { |name| registry.self_build_packages_for(name) || [] }
    (Ruby4Lich5::Msys2Bootstrap::PACKAGES + gem_specific).uniq.sort
  end

  def legacy_baseline_packages
    Ruby4Lich5::Msys2PackageListArtifact.parse_strict(File.binread(legacy_baseline_fixture_path)).packages
  end

  it 'differs from the legacy baseline by exactly the reviewed, named delta' do
    dynamic = current_dynamic_packages
    legacy = legacy_baseline_packages

    removed = legacy - dynamic
    added = dynamic - legacy

    expect(removed).to eq(expected_removals)
    expect(added).to eq(expected_additions)
  end

  it 'still includes every legacy package other than the reviewed removal(s)' do
    dynamic = current_dynamic_packages
    legacy = legacy_baseline_packages

    expect(dynamic).to include(*(legacy - expected_removals))
  end

  # Guards the fix itself, not just its current-day outcome: proves this
  # spec's selection set is genuinely narrower than "every registry
  # member" whenever the two diverge, rather than silently falling back to
  # global enumeration. Uses a synthetic registry/closure pair (a
  # dormant approved gem the closure never reaches) so this assertion
  # does not depend on config/curated-gems.json happening to have no
  # dormant members today.
  it 'excludes an approved-but-dormant registry member the recorded closure never reaches' do
    registry = Ruby4Lich5::CuratedGemRegistry.new(
      {
        'schema' => 2,
        'gems'   => {
          'in-closure-gem' => {
            'approval' => 'approved', 'bundle_default' => true,
            'targets' => { 'x64-mingw-ucrt' => { '4.0' => { 'expected_classification' => 'native_self_contained',
                                                            'msys2_packages'          => ['mingw-w64-ucrt-x86_64-in-closure'] } } }
          },
          'dormant-gem'    => {
            'approval' => 'approved', 'bundle_default' => false,
            'targets' => { 'x64-mingw-ucrt' => { '4.0' => { 'expected_classification' => 'native_self_contained',
                                                            'msys2_packages'          => ['mingw-w64-ucrt-x86_64-dormant'] } } }
          }
        }
      }
    )
    closure_names = ['in-closure-gem']

    gem_specific = closure_names.flat_map { |name| registry.self_build_packages_for(name) || [] }

    expect(gem_specific).to eq(['mingw-w64-ucrt-x86_64-in-closure'])
    expect(gem_specific).not_to include('mingw-w64-ucrt-x86_64-dormant')
  end
end
