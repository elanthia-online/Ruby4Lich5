# Ruby4Lich5

The installer factory for [Lich5](https://github.com/elanthia-online/lich-5). Ruby4Lich5
exists to produce a Windows installer (`Ruby4Lich5.exe`) that bakes together a specific
Ruby version, the latest Lich, and a curated set of precompiled (binary) gems — so
consumers get a fast, single-app install with no build tools required, while power users
can still opt in to a full MSYS2/RIDK toolchain afterward.

## Status

Phase 1 (foundational decisions), Phase 2 (front-door design), and Phase 5 (hardening/
polish decisions) are complete as of 2026-07; the decision record is kept by the maintainer
outside this repository. Phase 3 and Phase 4 turned out to be fully satisfied as a side
effect of Phase 1/2 (see below). The factory, gems server and installer release flow are
implemented; this README is a living document, not a spec frozen in stone.

## Installing with one command

One command installs what Lich needs and then Lich itself.

macOS and Linux:

```sh
curl -fsSL https://ruby4lich5.elanthia.online/install.sh | bash
```

Windows (PowerShell; x64 and ARM64):

```powershell
irm https://ruby4lich5.elanthia.online/install.ps1 | iex
```

`Ruby4Lich5.exe` remains the full Windows installer: it adds a Settings > Apps entry with an
uninstaller and associates `.rb`/`.rbw` files with its Ruby. The script does the same and also adds
a Start menu shortcut for Lich, and it runs on Windows on ARM.

### macOS and Linux (`site/install.sh`)

It installs the system packages (Homebrew on macOS; apt, pacman or dnf on Linux), then the Ruby
of the Ruby4Lich5 contract, the latest Lich release (verified by SHA-256) and Lich's gems.
Options such as `--no-gtk` and `--dir` go after `bash -s --`; see `install.sh --help`.

- **Ruby:** prebuilt, with [rv](https://rv.dev), on macOS 14+ and on Linux (x86_64, arm64) with
  glibc 2.39+ (Ubuntu 24.04, Debian 13, Fedora 40 or newer). The Ruby tarball is checked against the
  SHA-256 GitHub publishes for it. Everywhere else (Debian 12 and Chromebooks, Ubuntu 22.04, older
  macOS) the script compiles Ruby with rbenv, as the gswiki guides do; `--use-rbenv` forces that.
  Gems install with `bundle install --prefer-local`, so the gems Ruby already ships aren't rebuilt.
  Lich's release ships no `Gemfile.lock`, so the gems resolve afresh for the new Ruby, and that lock
  replaces the folder's old one.

- **Ruby version:** the Ruby4Lich5 contract's Ruby (the gem manifest's `ruby_installer_version`,
  which Lich's `.ruby-version` follows), never older than the latest Lich's `REQUIRED_RUBY`.
  `--ruby` picks another.
- **Existing Lich folder:** running the script again upgrades it in place to the latest release.
  `lib/` is replaced whole, as Lich's own updater does. The release's other files, including its
  `scripts/` and `data/` files, are copied over (into a symlinked `scripts/` or `data/` too). Anything
  not in the release (settings, logins, data, logs) is kept. The gems are installed and checked against
  the new release, and every path the upgrade writes is checked, before the folder is touched. A
  failure up to then leaves the previous Lich and Ruby untouched, and a path the upgrade can't write
  (such as a release script linked to your own copy) is named instead. The copy itself writes the
  release's other files first and swaps `lib/` in last by rename (put back if the swap fails); a
  copy that still fails partway may leave some release files updated, and a rerun finishes it. It keeps the folder's Bundler setting for which gem groups to leave
  out, so a folder set up with `--no-gtk` stays without GTK (`bundle config unset without` in the
  folder, then a rerun, turns it back on). `--use-rbenv` isn't remembered: pass it on each run.
- **Ruby switch:** the new Ruby becomes the one Lich uses (the rv link, or `rbenv global`) only after
  Lich's gems load with it, so a failed upgrade leaves the previous Ruby working.
- **Intel Macs:** Homebrew no longer supports them, so GTK's dependencies would compile from
  source, which failed or ran for hours in testing. With GTK, the script stops there and points to
  Windows in Parallels (`--allow-intel-mac` tries anyway). `--no-gtk` works on Intel Macs.

### Windows (`site/install.ps1`)

- **Ruby:** rv installs the RubyInstaller build that the live Ruby4Lich5 gem manifest was built for,
  after the script checks the archive's SHA-256. There's no DevKit or MSYS2.
- **Gems:** installed prebuilt from that manifest, each checked against its SHA-256, in the
  manifest's order. That's the set Lich's own startup check enforces, so Lich starts without a
  repair and nothing is compiled.
- **Gem selection:** Lich's own recovery policy (`lib/recovery_unit_policy.rb` in the Lich folder)
  picks the manifest units for that Lich version, so version ranges and retired gems are handled the
  way Lich handles them.
- **Lich folder:** an existing install is found and updated (the last one this script installed, the
  Desktop, or `C:\Ruby4Lich5\Lich5`). Otherwise the script asks, offering the same choices as
  `Ruby4Lich5.exe`.
- **Ruby path:** `%LOCALAPPDATA%\Lich5\ruby` is a junction to the installed Ruby, re-pointed on
  upgrades, and its `bin` goes on the user `PATH`.
- **Windows integration:**
  - `.rb`/`.rbw` file associations, per user. These are left to `Ruby4Lich5.exe` when it's also
    installed.
  - A Start menu shortcut.
  - A Settings > Apps entry, "Lich5 (Ruby4Lich5 install script)".
- **Uninstall:** from that Apps entry, or with `-Uninstall`. It removes only what the script recorded
  in `%LOCALAPPDATA%\Lich5\install-state.json`, and only while it's still the script's (associations
  that now point elsewhere are left alone). The Lich folder is kept unless `-RemoveLich` is given.
- **Windows on ARM:** `-UseArmManifest` sets the user variable `LICH_GEM_MANIFEST_URL` to the ARM
  gem manifest, which opts that machine in to the ARM soak (#62): Lich then enforces the ARM gem
  versions at startup and repairs from them.
- **Options:** `-Dir`, `-NoPath`, `-NoAssociations`, `-NoShortcut`, `-UseArmManifest`, `-Uninstall`,
  `-RemoveLich`, `-Yes`. Pass them with
  `& ([scriptblock]::Create((irm https://ruby4lich5.elanthia.online/install.ps1))) -Dir C:\Games\Lich5`.

### Testing and publishing

The `Install script` workflow tests both scripts whenever `site/` or the workflow changes:
- `install.sh` on Ubuntu, Debian, Fedora, Arch and macOS, with both Ruby managers;
- `install.ps1` on Windows x64 and ARM64.

A merge to `main` publishes `site/` to GitHub Pages only after every test passes. Administrators gate
the content: `.github/CODEOWNERS` and the `main` ruleset's required code-owner review make an
administrator's approval a condition of merging any change to `site/` or `.github/`, and a later push
dismisses it. Publishing itself is delegated: once a change is approved, any repository writer may
merge it, or re-run the push run on `main`, and that publishes it. Dispatching the workflow by hand
(a re-publish) is administrator-only.

## Releasing an installer

Administrators cut releases by dispatching the factory, promotion and installer workflows by
hand, with two release-check workflows between them. The `Release Ruby4Lich5 installer`
coordinator will replace that sequence once it can run (issue #53). The operator runbook for
both is [`docs/RELEASING.md`](docs/RELEASING.md); its manual-release section is the one in
use today.

A new platform's first gem manifest goes through the genesis path described in
[`docs/PLATFORM-GENESIS.md`](docs/PLATFORM-GENESIS.md).

When a gem-suite run reuses an accepted candidate's packages (`accepted-candidate-tag`), it
rebuilds any package whose lock entry or curated patch set changed. The rules are in
[`docs/ACCEPTED-PACKAGE-REUSE.md`](docs/ACCEPTED-PACKAGE-REUSE.md).

A package can carry two optional manifest keys: `minimum`, the lowest installed version Lich accepts
without a repair, and `self_build_equivalent`, which lets a user's own same-version build of an unpatched
package stand. Configure `minimum` in `config/curated-gems.json`. The factory derives
`self_build_equivalent` from the registry, patches and dependency graph. For the eligibility and release
rules, including how to opt a package into a `minimum`, see [`docs/PACKAGE-POLICY.md`](docs/PACKAGE-POLICY.md).

## What this factory does

- Produces a `.exe` installer for Windows that bakes in:
  - the latest released version of Lich
  - a specific, pinned Ruby version
  - precompiled/binary gems (cuts installer size and install time vs. compiling on the
    user's machine)
- Supports installing RIDK (MSYS2 toolchain) as an opt-in, post-install step — without
  shipping MSYS2 in the base installer
- Maintains a growing, curated list of precompiled binary gems available to the Lich
  ecosystem, versioned per platform (each gem internally bundles every currently-
  supported Ruby ABI, dispatched at load time)
- Publishes releases publicly from a single repo — no cross-repo write credential is
  needed to publish; consumers read via plain, public, unauthenticated requests

## Architecture: three components

```
  FRONT DOOR              GEMS SERVER               INSTALLER ASSEMBLY
  (per-gem, on demand)    (accumulating repo of      (periodic snapshot)
                           released gems + manifest)
  name a gem (+version)                              current curated set
    -> fetch RubyGems           release assets              + Ruby
    -> classify                 + curation manifest         + Lich
    -> build binary/pass-through (this same repo)            -> installer
    -> resolve + build closure
    -> smoke
    -> publish
```

- **Front door** — dispatch with a gem name (+ version). Fetch from RubyGems, classify
  (pure / native-self-contained / native-needs-system-lib), build the binary gem (or pass
  through pure gems), resolve and build the gem's full dependency closure, smoke test,
  and publish. This generalizes the fixed monolithic GTK3-suite build the prototype
  proved into "build any named gem."
- **Gems server** — holds released gems (as GitHub Release assets, no separate index)
  plus a curation manifest of the pinned set (`gem x platform -> version/tag/checksum`).
  Non-central, ours to own, and lives in this same repo.
- **Installer assembly** — periodically gathers the current curated set + Ruby + Lich
  files and builds the installer. Most of the time this reuses a cached, previously-baked
  Ruby+gems working directory rather than rebuilding it.

## What the prototype already proved

The `lich5-gtk3-gems` prototype (and the resulting test installer built from
`lich-5`) validated six load-bearing assumptions this factory builds on:

1. We can patch a problematic upstream gem we don't own (the glib2 GC/property patch).
2. We can compile binary (native) gems and distribute them.
3. A build-on-the-user's-machine installer is the wrong call (slow, two-app, freeze) —
   replaced by the **baked** model (compiled ahead of time, shipped ready to run).
4. We don't have to ship MSYS2/build tools for the runtime to work — binary gems vendor
   their own DLLs; non-DevKit Ruby is enough.
5. We can bifurcate consumer vs. power-user/developer and serve both (opt-in RIDK).
6. We can produce either a Lich-bundled installer or a standalone one.

The compile -> DLL-vendor -> smoke engine exists as the gem suite workflow, inherited
from the prototype and since generalized into the front door and gems server.

## Platform scope

Windows first, deliberately: the gem factory, gem manifests and installer build only
Windows (`x64-mingw-ucrt`, and `aarch64-mingw-ucrt` manifests).

macOS and Linux have an install script, [`site/install.sh`](site/install.sh) (see
[Installing with one command](#installing-with-one-command)). It compiles Lich's native gems on the
user's machine from system packages, with no Ruby4Lich5 gem artifacts. Windows also has
[`site/install.ps1`](site/install.ps1), which installs the Ruby4Lich5 manifest's prebuilt gems.

Prebuilt Linux and macOS binary gems remain future work, after the Windows factory and releases are
solid. Nothing here should be designed Windows-only in a way that forecloses that: the gem/index
schema is `Ruby ABI x platform` from the start, so Linux/macOS become additional matrix cells
later rather than a redesign.

## Related repositories

- **`elanthia-online/lich-5`** — true upstream Lich. The customer-facing project this
  factory serves. The finished installer-assembly CI is expected to eventually live
  here (or be consumed from here), once the design settles.
- **`Lich5/lich-5`** — a plain synced-from-upstream repo (not a linked GitHub fork, by
  design — see below), used as a disposable CI sandbox for iterating on installer-
  assembly workflow design without cluttering upstream's history. Tracks
  `elanthia-online/lich-5` via a plain `upstream` remote, synced manually. When the CI
  design is settled, the finished workflow(s) get PR'd to `elanthia-online/lich-5` as a
  small number of clean commits (a fresh branch off current upstream with the finished
  files copied in — not the sandbox's iteration history). This repo is then archived and
  made private.
  - It is deliberately *not* a GitHub-linked fork: forks default "Compare & pull request"
    to targeting the parent as the base repo, which risks a sandbox PR accidentally
    opening against upstream. A plain repo with a manual `upstream` remote avoids that
    failure mode entirely.
- **`Lich5/lich5-gtk3-gems`** — the prototype gem-build engine this factory generalizes
  from. Expected to be superseded once the front door exists.
- **`Lich5/lich-5-installer-prototype-202606`** — the original `Lich5/lich-5` fork,
  renamed, archived, and made private once the plain sandbox repo above replaced it.
  Holds the installer-prototype CI history, including the original Inno Setup script,
  for reference, not for further work.

## Org home

Ruby4Lich5 is maintained under the `elanthia-online` org at
[elanthia-online/Ruby4Lich5](https://github.com/elanthia-online/Ruby4Lich5),
following its transfer from `Lich5`.

## Roadmap phases

0. Urgent/time-bound fixes (e.g. Actions Node-version migrations) — handled as they come.
1. **Foundational decisions** (gate everything else — see Phase 1 decisions below).
2. **Front door** (design resolved — see Phase 2 decisions below; not yet implemented):
   generalize the fixed suite build into "build any named gem."
3. **Gems server / index** (satisfied by Phase 1 §1-3 + Phase 2 §6 — no separate work):
   durable publish mechanism, retiring the hand-made test prerelease.
4. **Installer assembly rework** (satisfied by Phase 1 §5-7, plus Phase 2 §4's
   redundant-gem exclusion covering GA §2.11): repoint at the curated set.
5. **Hardening/polish** (resolved — see Phase 5 decisions below): DevKit freeze fix,
   duplicate-installs note, gio2 DLL-noise corral, `.lic`-pinning decision, code-signing
   (deferred), deepened smoke.
6. **Multi-version variants** (resolved — see Phase 6 decisions below): additive, since
   the Phase 1 matrix index already accommodates a new Ruby ABI as a cell, not a redesign.
7. **Docs/governance** (resolved — see Phase 7 decisions below): load-order contract,
   ADR, and runbook.

## Phase 1 decisions (resolved)

- **Gems-server flavor:** release-asset store only. No RubyGems-compatible static index.
- **Index schema:** `gem x platform`, no Ruby ABI in tag or asset naming — each gem is a
  fat gem bundling every supported ABI internally (the Nokogiri pattern), dispatched at
  load time by the gem's own code.
- **Repo topology:** one repo. Ruby4Lich5 is both the front door and the gems server.
- **Curation, pinning, and authorization:** manual dispatch only, with EO Admin
  authorization as the intended policy
  (mirrors `elanthia-online/lich-5`'s own PR-review pattern, minus Release Please — gem
  versions are upstream-supplied, not commit-derived). Installer versioning is owned by
  Ruby4Lich5 itself, not by `lich-5`. Following the transfer to `elanthia-online`,
  verification of repository access and branch protection against that authorization
  policy remains pending as a separate step.
- **Release flow with `elanthia-online/lich-5`:** EO publishes 4 archive artifacts
  (tarball/zip x repo/app) and retires its existing embedded installer-build job.
  Ruby4Lich5 consumes the app archive, publishes its own gem/bundle/installer releases,
  and opens a PR (not a direct cross-repo asset upload) adding version/checksum/link
  metadata back onto the EO release. Fully human-coordinated, no automated hand-off.
- **Build caching:** the assembled Ruby+gems working directory (not Ruby alone) is
  cached as one unit and reused for Lich-app-only releases — the common case.
- **Test vs. production installers:** disposable, manifest-untouched one-off builds for
  EO/power-user gem evaluation, using the installer's existing Ruby-only component type.
  Promotion to production always goes through the same approval chain.
- **Automation philosophy:** automation may only fire on an authorized admin's own
  directly-controlled action, never on a lower-privileged or external signal.

## Phase 2 decisions (resolved)

- **Tri-state classification:** pure (no extensions) / native pass-through (upstream
  already precompiles a matching platform+ABI binary — verified against real
  rubygems.org data, e.g. `sqlite3`/`ffi` already do, `gtk3`/`glib2`/`cairo` don't) /
  native-self-contained (we compile via a known MSYS2 package mapping) /
  native-needs-system-lib (reject loudly). No version-hunting fallback — an exact
  requested version that lacks a precompiled match gets built ourselves, not
  substituted with an earlier version that happens to have one.
- **DLL bundling:** consolidate to the one mechanism that actually works (the PowerShell
  DLL-closure walker); delete the dead, always-empty per-gem dedup script. Windows-only
  for now — Linux/macOS will need native, platform-specific vendoring logic later, not a
  shared script.
- **Version-literal parameterization:** gem name+version become real per-gem inputs;
  every patch asserts an exact expected match count and derives versions from the
  actually-fetched source, not a trusted input string.
- **Closure resolution:** reuse `Gem::Resolver`/`bundle lock` rather than a hand-rolled
  solver; walk the resolved set bottom-up against the curation manifest, reusing
  already-published compatible versions; any unbuildable dependency fails the whole
  request loudly.
- **Generalized smoke:** reuse the resolved closure as a throwaway `Gemfile` +
  `Bundler.require` (solves require-ordering for free); `Gtk.init` stays as a narrow,
  justified exception for GTK3 specifically. Bundled upstream test suites are reused
  best-effort and reported in the PR, never as a build gate.
- **Publish mechanism:** guard → checkpoint → build the full closure → upload as draft
  releases → one PR per dispatch (not per gem) updating the curation manifest → PR merge
  publishes the already-built drafts. Manifest pin and live releases go from draft to
  live together, at the same approved moment.

## Phase 3 & 4 — satisfied, not separately worked

Both turned out to already be covered once Phase 1 and Phase 2 landed, rather than
needing their own discussion — consistent with the roadmap's own "don't touch twice"
principle. Phase 3's bullets (stand up a server repo, a durable publish mechanism, a
curation manifest) are Phase 1 §1-4 and Phase 2 §6. Phase 4's bullets (repoint the
installer workflow at the curated set; exclude redundant default/bundled gems per GA
§2.11) are Phase 1 §5-7 and the closure-resolution design in Phase 2 §4, respectively.

## Phase 5 decisions (resolved)

- **DevKit wizard freeze:** fix by moving DevKit install to the finish page (`postinstall
  nowait`, visible console), matching RubyInstaller's own reference installer exactly.
- **Duplicate-installs note:** documentation only — already verified safe, no fix needed.
- **gio2/DLL noise:** a curated, verified list of 44 known-expected system DLLs (compared
  case-insensitively) silences known-benign noise and summarizes genuine surprises per
  gem — also the foundation for a future fail-loud-on-genuine-miss check.
- **`.lic`-from-master pinning:** deliberately not pinned — the script-update cycle is
  meant to be fluid, and Lich's own `;repository download-updates` mechanism (with a
  per-script `unset-updatable` opt-out) already handles staleness/pinning at the
  application level.
- **Code-signing:** deferred, pending an upcoming policy decision that will inform next
  steps. Nothing in this design forecloses adding it later.
- **Deepened smoke:** split into environment (move smoke to its own CI job for a
  genuinely clean, no-MSYS2-residue runner — not yet implemented) and depth (`Gtk.init`
  remains sufficient per real historical experience; the Phase 2 §5 bundled-test-suite
  reuse is the answer to "prove it works," not a second mechanism).

## Phase 6 decisions (resolved)

- **ABI guard generalization:** make the installer-assembly workflow's Ruby-series
  target (today hardcoded to `4.0.x`) a real per-build parameter, so a future Ruby 4.1
  installer variant is a parameter value, not a forked workflow. Everything else a new
  ABI needs (rebuild every tracked gem, keep the older ABI's variant running alongside)
  is already covered by Phase 1 §2.

## Phase 7 decisions (resolved)

- **Consumer load-order contract:** already solved in the design, not just documented —
  Phase 2 §5's `Bundler.require` reuse requires gems in dependency-resolved order
  automatically. A short explanatory note is still worth adding for non-Bundler consumers.
- **ADR:** not adopting a separate convention; the maintainer's decision record serves that role.
- **Build/release runbook:** `docs/RELEASING.md`. Its manual-release section is in use; the
  coordinator sections are completed as the coordinator's underlying changes land.
- **Vision document:** retained in the maintainer's records as a historical snapshot, not
  in this repository.

## License

BSD 3-Clause, matching `lich-5` and the wider Lich5/Elanthia Online ecosystem.
