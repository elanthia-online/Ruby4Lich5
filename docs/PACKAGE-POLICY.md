# Optional package keys: `minimum` and `self_build_equivalent`

Each package in the gem manifest names the exact `version` a repair installs. Current lich-5 releases
also read two optional keys next to it. Releases from before each key ignore it, so they stay strict. lich-5's
`docs/dependency-recovery/windows-r4l5-gem-manifest.md` describes how startup uses them. This page covers
how Ruby4Lich5 produces them.

```json
{ "name": "ox", "version": "2.14.29", "filename": "R4L5-ox-2.14.29-x64-mingw-ucrt.gem",
  "sha256": "sha256:...", "self_build_equivalent": true }
```

## `minimum`

The lowest installed version startup accepts without a repair. An installed version from `minimum` up
to `version` starts, and the gap is logged.

- **Where it is set:** `config/curated-gems.json`, per platform and Ruby ABI:
  `gems.<name>.targets.<platform>.<abi>.minimum`. x64 and aarch64 floors can differ.
- **Today:** no package has one. Every package keeps `minimum == version`, and nothing loosens until a
  package opts in (sqlite3 stays strict at 2.10.2).
- **Registry check** (`CuratedGemRegistry`): a canonical release version. That means a non-empty string in
  RubyGems' own spelling (`Gem::Version.new(v).to_s == v`), with no surrounding whitespace, no rewritten
  form such as `2.10.1-1`, and no prerelease. This is lich-5's `RecoveryUnitPolicy.canonical_release?`.
- **Generation** (`PackagePolicy`, called by `GemManifestGenerator`):
  - The key is written only when the configured minimum is below the served version. A minimum equal to
    the version is omitted, so a manifest with no minimums is byte-identical to one built before the key
    existed.
  - A minimum above the version stops generation.
  - So does a minimum on a package another member of its unit pins exactly, judged from the resolution
    lock's requirements. Any `=` clause counts as a pin, even next to a looser one (`= 2.0, >= 1.0`). A lower installed copy could never resolve with that dependent.
    Today's exact pins are redis → redis-client and the Ruby-GNOME `= 4.3.9` pins.
  - The minimum is decided once per package name and written on every copy (concurrent-ruby and tzinfo
    appear in several units).
- **Manifest check** (`GemManifestValidator`):
  - `minimum` must be a canonical release no higher than `version`.
  - `version` must be in canonical spelling. A prerelease `version` is still allowed.
  - Copies of one package at one version must agree on the effective minimum, compared by value, with an
    absent minimum counting as `version`.
  - A package name never carries two different minimums in one target.
  - The validator cannot see exact pins (the manifest carries no dependency edges), so it relies on
    generation for that refusal.
- **Served-version gate** (`SupportedStartupPolicy.verify!`): when any package's minimum is below its
  version, every supported client's checker runs once more, with every package served at its minimum.
  This runs alongside the floors and measured-gems runs ([RUBY-FLOORS.md](RUBY-FLOORS.md)). With no minimums nothing more runs, and the
  approval identity is unchanged either way.

## `self_build_equivalent`

`true` marks a package Ruby4Lich5 builds from unchanged upstream source. A user's own same-version build of
it (a `ruby`-platform gem from `gem install`) can then stand in for the R4L5 build, instead of being repaired
to it. Ruby4Lich5 only ever writes `true`. An absent key means strict, the same as `false`.

- **Eligibility**, decided per platform from the registry with no hardcoded list:
  - **Registry entry:** `build_role: repack`, which compiles the unchanged upstream source with
    `gem install` and repacks the result.
  - **Classification:** `native_self_contained` on that target, so Ruby4Lich5 really builds it there and
    does not pass through upstream's binary.
  - **Patches:** none under `patches/<name>/`.
  - **Never eligible:** `gtk`-role packages, which are always normalized and patched.
- **Generation** (`PackagePolicy`), from the lock's real dependency edges. An eligible package is flagged only
  when both of these hold, across every unit that holds it:
  - no other member of those units depends on it;
  - it does not depend, directly or transitively, on a native (platform-specific) unit-mate.

  lich-5 checks only the first direction. A flagged package over an R4L5 build that bundles DLLs (a flagged
  gtk3 over an R4L5 glib2) would start mixed, and that second direction is Ruby4Lich5's to refuse. A pure
  unit-mate is fine: sqlite3 over `mini_portile2`.
- **Manifest check** (`GemManifestValidator`, through `PackagePolicy.validate_target!`). It is structural: it
  judges only the document, never the registry or `patches/`, because it also runs on accepted documents (live,
  rollback, a replacement's predecessor, the installer's accepted manifest):
  - The value must be `true` or `false`.
  - Copies of one package at one version must agree.
  - Without dependency edges, the two directions are checked structurally. Both hold for every unit the
    generator builds (a root's complete closure, listed dependencies first in `install_order`):
    - **First direction:** the package must be last in `install_order` in every unit that holds it.
      Anything depending on it would have to install after it.
    - **Second direction:** every unit-mate must be a `ruby`-platform package. The unit-mates of the
      last-installed package are all its dependencies.
- **Eligibility check** (`PackagePolicy.require_eligible_flags!`). This runs only where new bytes are produced or
  approved: the generator CLI (`bin/generate_gem_manifest.rb`, after lifecycle assembly), promotion
  (`PromotionPlan.build`, candidate against live) and genesis promotion (`PromotionPlan.build_genesis`, with no
  previous manifest; see `docs/PLATFORM-GENESIS.md`). Every `true` must be eligible today (see above), unless the
  previous manifest (the accepted live one) already carried the flag on the same package. "Same package" means
  the same target ABI and platform, name, version and package `sha256`. A rebuilt artifact therefore never
  inherits a flag, and nothing is exempted by name. With no previous manifest, every flag gets the full check.
- **Today's set:**
  - x64: `ox` and `curses`. sqlite3 is upstream's binary there.
  - aarch64: `ox`, `curses` and `sqlite3`. sqlite3 is built there, and its only unit-mate is pure
    `mini_portile2`.

## Historical flags and transitions

A flag describes the bytes it was accepted with. Those bytes were built from unchanged upstream source, and a later
change does not alter them. Such changes include:

- a patch landing under `patches/<name>/`;
- a registry reclassification (for example aarch64 sqlite3 moving to `native_pass_through`);
- a `build_role` change.

So:

- **Accepted documents stay valid.** Live, its rollback, a replacement's predecessor and the installer's accepted
  manifest are checked structurally only, so a transition never blocks promotion, replacement or an installer
  build.
- **Un-flagging needs no procedure.** After a transition, the generator stops flagging the package. The next
  candidate is generated unflagged and promotes normally, and the approval's `package_policy_changes` shows the
  flag going away. The old bytes keep their flag in live and in the rollback.
- **Retained copies keep their flag.** Closures that lifecycle assembly copies verbatim from live (obsolete
  closures, a range's legacy closure) carry the accepted `sha256`, so their flag passes the eligibility check
  unchanged.
- **A rebuilt artifact that still carries the flag is refused.** Its `sha256` is new, so it gets the full check
  and fails it.

**Known limitation:** copies must agree by (name, version) across every unit in a target. That includes a legacy
closure and its `-ranged` replacement, which the consumer never selects together. A range rollout that puts a
package at the same version on both sides with different flags is refused. That covers a pre-flag legacy ox next
to a flagged `ox-ranged`, and a flagged legacy ox kept verbatim next to an unflagged `ox-ranged` after a
transition. Ranges are empty today, and a ranged replacement at a different version is unaffected.

## Promotion

- **Approval summary:** the promotion approval adds `package_policy_changes` when any package's `minimum`
  or `self_build_equivalent` differs between the live manifest and the candidate. It is keyed by target
  and package, with the keys before and after. The full unit diff stays in `changes`.
- **Artifact reuse:** these keys do not change served bytes, so they alone never move an accepted artifact
  (`ReplacementPlan.retain_artifacts!`).

Emitting either key changes the x64 manifest bytes. lich-5's CI gate binds the Latest installer's
provenance to the live manifest, so the first manifest carrying them ships as an x64 promotion and an
installer release together.
