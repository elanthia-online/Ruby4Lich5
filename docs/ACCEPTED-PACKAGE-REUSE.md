# Accepted package reuse

A bundled-gems suite run with `accepted-candidate-tag` set reuses the accepted candidate's
package bytes instead of rebuilding them. The step `Prepare accepted package reuse` acquires
and verifies the candidate (`Prepare-GemPromotion`), then `bin/prepare_replacement.rb` runs
`Ruby4Lich5::ReplacementPlan.build`. Later, `Verify unchanged accepted package bytes`
(`bin/verify_replacement.rb`) proves the reused files were staged unchanged.

## What forces a rebuild

A package is **changed** and is rebuilt, not reused, when any of these holds:

1. Its resolution-lock entry differs from the accepted lock: version, dependencies, or
   classification.
2. **Its curated patch set is not proven identical to the accepted build's**. See below.
3. It is a `native_self_contained` package with a runtime dependency that is changed.
   This repeats until nothing new is added, so a whole build closure is rebuilt together.
4. It belongs to the GTK build role and any GTK role member is changed. The role is
   rebuilt as one unit.

Everything else must match the accepted manifest by name, version and SHA-256, or the plan
fails.

## Curated patch fingerprints

The build applies the curated patches under `patches/<name>/` (`PatchApplier`). A patch
can change while the package version stays the same. The lock does not show that change,
so the plan also compares patch sets.

- **Fingerprint.** `Ruby4Lich5::PatchFingerprint.compute` hashes every regular file under
  `patches/<name>/`. It takes SHA-256 over the sorted lines
  `"<relative path>\0<sha256 of bytes>\n"`. A package with no patch files has the
  fingerprint `null`. Symlinks are refused.
- **Recording.** `Prepare accepted package reuse` runs `bin/record_patch_fingerprints.rb`
  before `Prepare native gems`. That step can generate patches into `patches/` for GTK
  members that have no curated patch, and those generated patches must not be recorded.
  The build job carries the record to the smoke job. `Stage artifact` then embeds it as
  `patch_fingerprints` in `gem-build-metadata.json`, a map of package name to fingerprint
  or `null`. `schema_version` stays 1, and the field is additive.
- **Reuse rule** (`PatchFingerprint.reusable?`). A package may be reused only when:
  - the accepted record has an entry for the package that equals the current fingerprint,
    or
  - the accepted record has no entry for the package (or the bundle predates recording)
    **and** the current tree has no patches for it.

  If neither holds, the package goes into the plan's `changed` (and `patch_changed`) set,
  so its closure and role rebuild as described above. This fails closed: an accepted build
  that recorded nothing never has its bytes reused for a package that has patches today.
- **Carry-forward.** For a reused package, the new record copies the accepted record's
  entry. When the accepted build recorded nothing for that package, the new record leaves
  it unrecorded too. A reused build therefore never claims a patch set it did not prove.
- **Integrity.** `gem-build-metadata.json` does not list itself in its `files` checksums. The
  record is trusted because the candidate zip that carries it matches its release-asset
  digest, which `Prepare-GemPromotion` verifies.
- **Line endings.** Fingerprints hash file bytes as the Windows runner checks them out.
  A fingerprint computed locally on another OS may differ only because of line endings.
  In CI such a difference can only force a rebuild, never allow a reuse.

### Consequences

- Accepted candidates built before recording existed have no `patch_fingerprints`. The
  first reuse from one of them rebuilds every package that has curated patches. Today that
  is the whole GTK role.
- Suppose a patch directory is deleted before the first build that records fingerprints.
  The plan cannot detect that change, because the accepted build recorded nothing and the
  current tree has no patches. The rule above allows the reuse, and the reused package
  stays unrecorded.
- Only the checked-in curated patch set is fingerprinted. Changes to the build code are not
  covered: `GemspecNormalizer`, the `PatchGenerator` template, and the inline workflow
  substitutions can all change built bytes without forcing a rebuild. Run a full build
  (blank `accepted-candidate-tag`) after changing them.

The `self_build_equivalent` eligibility rule in [`PACKAGE-POLICY.md`](PACKAGE-POLICY.md)
also reads `patches/`. It decides whether newly built bytes for a package may carry the
flag, which lets Lich accept a same-version self-built copy in place of the R4L5 build.
This document decides whether accepted bytes may be reused at all.
