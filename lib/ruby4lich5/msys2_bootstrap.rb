# frozen_string_literal: true

module Ruby4Lich5
  # The static, minimal MSYS2 ucrt64 toolchain set that stays hardcoded
  # outside the curated-gem registry -- the already-locked boundary:
  # generic compiler toolchain, not
  # gem-specific curation, and doesn't depend on any gem's own resolution.
  #
  # Real bug this closes, found in review (2026-07-13): the seed's first
  # draft copied the entire legacy uniform MSYS2 package list -- toolchain
  # included -- into every single native_self_contained registry entry.
  # Beyond violating the locked static-vs-gem-specific boundary, it also
  # meant a package removed from one entry (e.g. the stale
  # mingw-w64-ucrt-x86_64-sqlite3 pin, removed once sqlite3 itself stopped
  # needing MSYS2 compilation) would simply be reintroduced by every other
  # entry's own copy the moment they were aggregated together -- the
  # "reviewed delta" the session plan promised could never actually happen.
  #
  # This module is this project's one canonical source for the static set;
  # both the seed-derivation script (subtracting it from what gets recorded
  # per-gem) and the future dynamic MSYS2-install wiring (Phase 17 section
  # 8 step 5, unioning it back in before `with.install`) read from here.
  module Msys2Bootstrap
    # @return [Array<String>] confirmed against
    #   +ruby4-bundled-gems-suite.yml+'s own "Install MSYS2 UCRT build
    #   surface" step at time of writing -- +base-devel+, +make+, and the
    #   +gcc+/+binutils+/+pkgconf+/+libffi+ MinGW packages named explicitly
    #   in Phase 17 section 8's locked design.
    PACKAGES = %w[
      base-devel
      make
      mingw-w64-ucrt-x86_64-gcc
      mingw-w64-ucrt-x86_64-gcc-libs
      mingw-w64-ucrt-x86_64-binutils
      mingw-w64-ucrt-x86_64-make
      mingw-w64-ucrt-x86_64-pkgconf
      mingw-w64-ucrt-x86_64-libffi
    ].freeze
  end
end
