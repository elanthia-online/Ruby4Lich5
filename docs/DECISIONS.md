# Phase 1 Decisions

Record of the foundational decisions from `ROADMAP-woven-plan.md` Phase 1, worked out
collaboratively in 2026-07. These gate Phase 2 (front door) and beyond — see the roadmap
for how they fit into the overall build order.

## 1. Gems-server flavor: release-asset store only

No RubyGems-compatible static index (no GitHub Pages compact index). Gems are published
as GitHub Release assets on Ruby4Lich5 itself.

This was validated against a concrete future requirement: an in-game
`;lich5-update --gem=<name>` command that fetches and installs the latest matching gem
during an active Lich session. A static index would have made sense if that command
needed to speak RubyGems' own `gem install --source` protocol — but it's a bespoke Lich
command we fully control, so it doesn't need to. GitHub Releases already give a stable,
predictable download URL per tag; no compact-index infrastructure is needed.

## 2. Index schema: `gem × platform`, no ABI in the naming

Neither the release tag nor the asset filename needs to encode the Ruby ABI. Each
published gem is a **fat gem**: one package per platform, bundling precompiled binaries
for every currently-supported Ruby ABI under `lib/<gem>/<abi>/`, with a
`RUBY_VERSION`-based `require_relative` dispatch at load time — the pattern Nokogiri
already uses in production (verified directly: the installed `nokogiri-1.19.2-arm64-darwin`
gem has `lib/nokogiri/{3.2,3.3,3.4,4.0}/nokogiri.bundle`, selected by
`lib/nokogiri/extension.rb` parsing `RUBY_VERSION`).

Consequence: one release/tag per gem-version (e.g. `gtk3-v3.5.6`), with per-platform
assets (e.g. `gtk3-3.5.6-x64mingw-ucrt.gem`). The curation manifest is
`gem × platform -> {version/tag, asset, checksum}` — no ABI key.

**Build-discipline consequence:** whenever the supported-ABI set changes (adding Ruby
4.1, eventually dropping 4.0), every currently-tracked gem must be rebuilt to re-embed
*all* still-supported ABIs' binaries together, not just the new one — otherwise a user
on an older, still-supported ABI silently loses the gem the moment "latest" moves.

**Resolution mechanism** (for finding "latest," e.g. for the in-game update command):
reuse the pattern already proven in `elanthia-online/lich-5`'s own
`lib/common/update/` — try `/releases/latest` first, fall back to enumerating releases
and comparing via `Gem::Version` when there's more than one concurrent release lineage
in a repo (exactly our situation: one lineage per gem, not one for the whole repo). The
curation manifest exists specifically so this never has to enumerate/paginate the full
releases list — one fetch gets the current pin.

## 3. Repo topology: one repo, not three

Ruby4Lich5 is both the front door *and* the gems server — not a separate repo. Same-repo
means the front door's own default Actions token can publish releases with no cross-repo
write credential needed. The read side (installer-assembly, or a future in-game update)
is a public, unauthenticated fetch regardless of topology, so splitting the repos would
only have added cross-repo auth plumbing for no benefit.

Installer-assembly's long-term home is `elanthia-online/lich-5`'s own existing release
CI (see §5) — that's a *read* relationship (it consumes Ruby4Lich5's releases), not
something that changes this topology call.

## 4. Curation, pinning, and authorization

**Trigger:** manual dispatch only. No nightly builds, no auto-rebuild the moment an
upstream gem publishes — a human looks at what changed before a rebuild happens. Matches
the front door's "on demand" design from the vision doc.

**Mechanism to mirror:** `elanthia-online/lich-5`'s `prepare-stable-release.yaml`
structurally (guard → checkpoint/backup tag → open a PR for human review → separate
workflow finalizes on merge → real GitHub Release stays draft until a human publishes)
— **minus the Release Please step itself**. Release Please's job is deriving a semver
bump from *our own* Conventional Commits; gem versions aren't something we compute, they're
upstream-supplied inputs we choose to pin. The PR's diff is the curation-manifest change
itself (gem X: version A → B, asset, checksum) — arguably a more meaningful review
artifact than a generated changelog would be here.

**Installer versioning is owned by Ruby4Lich5, not by `lich-5`.** Verified directly: the
prototype's own version-resolution step and `elanthia-online/lich-5`'s live
`release-please-config.json` both currently derive the installer's version from Lich's
*own* tracked version (one Release Please package, `.`, manifest value `5.18.0`,
`extra-files` stamping that same value into `R4LGTK3.iss`). That conflates two things
that can now change independently: `lich-5`'s Release Please only ever sees `lich-5`'s
commit history, and has no visibility into a Ruby4Lich5-side gem rebuild or Ruby ABI
addition. Version identity for the installer has to be decided where the facts about its
contents actually live — Ruby4Lich5 — regardless of which org either repo sits in.

**Authorization policy:** curation and promotion require an EO Admin. EO Maintainers
(a broader group, working mostly on scripts and core Lich logic) are not part of this
specific process.

**Post-transfer update (2026-10-24):** Ruby4Lich5 is now under `elanthia-online`.
The original July proposal to mirror EO Admins in a Lich5-org team, and its assumptions
about Lich5-org default access, are superseded by the transfer. Verification of
repository access and branch protection against the EO Admin authorization policy
remains pending as a separate step.

**Promotion always requires the same approval chain**, no exceptions — including
promoting a beta-tested gem to production (see §7). No automation ever fires on a
signal from outside an authorized admin's direct control (see §8).

## 5. Release flow: `elanthia-online/lich-5` and Ruby4Lich5

The shared Windows contract supersedes the original release-first proposal in
this section. Runtime versions for every non-GTK package, including transitives,
come from `Gemfile` and `Gemfile.lock` at an administrator-selected full lich-5
commit. GTK versions and packaging remain Ruby4Lich5-owned. The static reader
is vendored from lich-5 and its exact bytes must match the selected commit.
Dynamic runtime declarations require an explicit reader update; Gemfile plugins
are not evaluated to derive this contract.

`config/curated-gems.json` owns approved roots, ordered GTK build roles, the
repack allowlist and smoke require paths. Adding a Lich root requires matching
registry admission and smoke coverage. `config/target-ruby.json` owns the target
RubyInstaller revision and reviewed immutable GTK source. `.ruby-version` is a
checked mirror for Ruby tooling; installer compilation requires an explicit
verified RubyVersion. Diagnostic workflows use the same target default.

The producer captures the pristine target RubyInstaller's actual supplied gem
versions and dependency requirements before application installation. It reports
locked/supplied differences and rejects unsatisfied requirements; supplied gems
are not shipped to conceal a mismatch. All non-GTK package versions constrain
the RubyGems resolver, including transitives. One resolution feeds the existing
closure merger, resolution lock, staging checks and shared smoke contract.
GTK dependencies removed by the existing packaging normalizer are recorded
separately as reviewed `build_tooling` inputs, with exact versions. They may
exist on the build machine but cannot enter the staged runtime inventory.
Source archives use reviewed commit/digest pins. Original gem inputs are hashed
against RubyGems metadata before execution, and matching non-GTK source inputs
are also checked against the selected Lich lock. Source-package receipts are
retained with the tested artifact.

D1 delivery: unmodified single-package units use original rubygems.org files
and their verified checksums. R4L5-built gems and complete multi-package closures
remain in the ZIP. `delivery-map.json` records exact names, versions, platforms,
filenames, digests and acquisition routes; smoke-tested metadata binds the map
and the complete file inventory. Candidate preparation, promotion inspection
and installer acquisition restore omitted upstream files through the same
verified helper. The smaller ZIP is not a complete installer payload by itself.
Native standalone assets remain immutable. Existing GTK packaging patches and
the reviewed 4.3.9 source remain available; no GTK freeze or support cutoff is
introduced here.

Lich-first flow: prepare the candidate lock; an administrator selects its full
SHA for an R4L5 build; recover through the tested current/oldest-supported
consumers; promote recovery; build and publish the matching tested installer;
rerun the Lich contract check; then accept/release the consumer. Eligibility uses
schema-2 Windows semantic identity; raw Gemfile/lock hashes and source commit
remain provenance. Supported consumers retain coverage and recovery compatibility gates. Do not add exact equality against a
superseded main lock, which would make the handoff circular. Ordinary merges
may change the checkout SHA or dev-only source bytes without changing Windows eligibility.

R4L5-first investigation uses explicit version overrides or root subsets. These
builds are unpromotable, with exact required Lich lock-version edits reported.
Update the consumer lock and platform checksums, select its resulting full SHA,
and rebuild without overrides before publication. The factory and promotion
entry points reject uncontracted, diagnostic and override builds.

The manifest target carries `contract` schema 2: full `lich5_commit`, bare-hex
`gemfile_sha256`, `lock_sha256`, `reader_sha256`, `windows_contract_sha256`, exact `ruby_installer_version`, measured `ruby_inventory`,
`expected_packages`, `bundled_comparison`, approved `gtk_source`, `overrides`,
`selection` and `promotable`. Canonical contract hashing uses the shared reader's
`Lich::RuntimeGemContract.digest`. The installer records that bare-hex digest in
`runtime_contract_sha256`, exact served manifest bytes in
`recovery_manifest_sha256`, and its existing `ruby_installer_version` and
`installer_sha256`. Lich checks matching predecessor provenance and verifies
installer bytes before attachment, then rechecks at release time.

The effort-4 producer (#49) deliberately advances the shared reader to lich-5
commit `9e9259860887e9da7c6a49c0ef487c2973952c3b` from the matching effort-4
consumer (#2128). The preceding #48 layer pins #2127 at
`83ef0c529cda5610827e20a69a737704f5de6fd4`; it remains independently buildable
against that earlier consumer. #49 adds the optional-lock/group-selection API
needed by #2128, while producer resolution still requires a complete lock.
`vendor/lich5/contract-source.json` records the current full source identity and
reader digest. The pairing regression verifies independently captured #2128
consumer source, Gemfile and lock, not a reader copied out of the producer.
The earlier #2127 snapshot is retained as historical pairing evidence. #50 owns
the later range-capable source transition. Selecting a different reader requires
reviewed re-vendoring; the exact reader-byte guard remains enforced in addition
to semantic eligibility.
`windows_contract_sha256` uses that reader's shared digest
with the pristine inventory, approved GTK roles and the resolved shipped closure.
It binds runtime requirements, applicable Windows package versions/checksums and
dependencies, including non-GTK members reached only through GTK. Unused dev
entries, comments and non-Windows variants do not affect eligibility. Constraint
order is normalized; dependency graph validation compares RubyGems requirement
objects while retaining exact graph names and versions. Producer-owned GTK role
versions remain exempt from consumer lock pinning.

Runtime contract schema 1 is rejected; existing contracted locks must be rebuilt.
The resolution-lock and recovery-manifest envelopes remain schema 1. Final closure
resolution records the semantic identity before the lock is frozen; promotion and
installer provenance continue binding the complete contract and manifest digests.
Ranged producer integration in #50 must pass the same candidate-applicable member
catalog used by the range-aware consumer. The first real contracted build and
publication/readback remain explicit acceptance work; offline tests do not supply it.

Administrative dispatch remains the sole producer trigger. PR changes never
autonomously launch privileged R4L5 work. The effort-3 producer PR requires #47
to merge first. Its consumer PR may open earlier but cannot merge/release until
matching recovery and installer are live and its contract check is green.
Publication and repository-history reconciliation remain owner-controlled.
The effort-4 producer PR requires #48 to merge first. Factory selection of the
#2128 candidate must use #49's matching reader; tested recovery and its matching
installer/provenance must be live before accepting the #2128 consumer contract
gate. The unmerged full candidate SHA can be selected by the administrator, so
these are publication/acceptance prerequisites rather than simultaneous merges.

Existing Windows clients gain accepted-version enforcement only after receiving
the corresponding Lich runtime update. Startup checks selected roots and complete
closures against the accepted manifest before activation, asks consent before
repairs, and restarts to release loaded code. Lookup failures stop startup;
there is no offline success fallback. Eligible newer gems are retained.

Installer PATH updates normalize only this install root's versioned Ruby bins
and `current\bin` in HKCU Environment Path. Installation prepends the actual
versioned bin once, preserving unrelated tokens and the registry string type;
reinstallation is idempotent and uninstallation removes the same owned entries.
The helper never edits machine PATH or deletes old Ruby trees or user gems.
The existing uninstall/reinstall guidance remains applicable.

Installer version proposals read checksummed `installer-provenance.json` from
the latest final installer release, verify its executable digest, and compare
its exact recovery-manifest and canonical runtime-contract digests with accepted
recovery. Ruby comes from target configuration; CI also detects exact
RubyInstaller revision changes and installer inputs compared from the recorded
`installer_source_sha`. Neither legacy ZIP bytes nor release-note text is used.
Missing/incomplete historical provenance or an unavailable comparison yields
an explicit unavailable proposal, never a guessed bump. Integrity failures fail
the workflow. An administrator must supply the first provenance-bearing release
through the normal reviewed process before historical comparisons are possible.
Proposal comments require both the triggering and rerun actors to be admins and
the PR to originate in this repository; no external action dispatches production.

## 6. Build caching: the baked working directory

The factory's actual current build (`ruby4-bundled-gems-suite.yml`) installs MSYS2 only
as a transient build surface to compile native gems, then validates the result by
extracting a *fresh* RubyInstaller archive into a clean directory, stripping all
MSYS2/DevKit env vars, and running `gem install --local` of the whole bundle into it —
proving the gems load with zero MSYS2 present. Today that clean tree is built only to
smoke-test, then discarded; the actual "fetch Ruby + install the bundle" assembly
happens again later, in the installer-assembly step. Ruby4Lich5's own installer never
runs `gem install --local` on an end user's machine — Inno Setup's `[Files]` section
reads an already-assembled local directory at CI compile time and compresses it directly
into the `.exe`; the only runtime Ruby invocation is the optional, developer-only
`ridk.cmd install` for the DevKit task.

**Decision:** persist that clean-Ruby-plus-gems tree as its own release artifact instead
of discarding it — eliminating a redundant fetch-and-install cycle that currently happens
twice across two workflows. Ruby and gems are cached **together as one unit**, not
separately:

- Ruby alone is never cached — refetching a specific RubyInstaller archive is free and
  identical to grabbing the public download directly, so there's nothing to gain from a
  separate Ruby-only cache tier.
- The **assembled working directory** (a specific Ruby + all current bundle gems
  installed into it, no MSYS2) is the thing that's expensive to reproduce and worth
  retaining. It's published as its own Ruby4Lich5 release, tagged by Ruby version +
  platform, checked via a **single sha256 hash over the whole compressed archive** (not
  per-file — there's no scenario where knowing which file inside is stale helps; a
  mismatch means rebuild the whole tree).
- It is rebuilt **wholesale**, never patched incrementally, whenever *anything* in it
  changes — one gem, ten gems (e.g. a GTK3 suite bump), or the Ruby version itself all
  trigger the same "fetch fresh Ruby, `gem install --local` the current full bundle,
  publish a new working-directory artifact" cycle.
- **Fast path** (the common case — only the Lich app changed, no gem/Ruby work):
  the CI job downloads the cached working-directory archive, extracts it locally into
  the exact path Inno Setup's `[Files]` section expects, drops in the newly-fetched Lich
  app content, revalidates the single checksum, and compiles — no MSYS2, no
  RubyInstaller fetch, no `gem install --local` re-run. Doug estimates this is the
  common case, roughly 3-4 releases out of 5.
- **What gates fast-path vs. full-rebuild:** pure human judgment, for now — no automated
  drift-detection guard between the manifest's current pins and the cached artifact's
  tag. Revisit if this ever proves to be a real failure mode at scale; not solving for it
  preemptively given the low release cadence and small team.

## 7. Test vs. production installer builds

Power users / EO members need to beta-test critical gem changes (Sequel, SQLite3, GTK3,
Ox) against their *existing* Lich installation before a change is trusted enough to
promote to the production pin — motivated by a real past incident that required reactive
pin-version fixes. Production stays on the known-proven gem set until a beta-tested
change is explicitly promoted.

This doesn't need new build machinery — the existing `Ruby4Lich5-installer.iss` already
has a `"rubyonly": "Ruby Installation Only"` component type (no Lich files at all), and
the existing workflow already exposes per-gem version-override dispatch inputs
(`ruby-gnome-version`, `cairo-version`, etc.). A test-installer build is simply:

- An explicit, one-off dispatch overriding the specific gem(s) under evaluation while
  everything else defaults to the current production pin.
- **Disposable** — not part of the baked-tree caching system (§6), never persisted as a
  reusable artifact.
- **Never writes to the curation manifest.** The manifest reflects known-proven state
  only; a test build's candidate version has no manifest presence at all.
- Clearly labeled (distinct tag prefix, marked prerelease, explicit "for EO/power-user
  testing, not for distribution" in the release body) so it's never mistaken for a
  production artifact.
- Promotion to production, once a beta test passes, goes through the exact same
  admin-gated approval/PR-review chain as any other gem release (§4) — no lighter path,
  regardless of who signed off on the beta test itself (see §8).

## 8. Automation philosophy: controlled trigger, not "automated vs. manual"

The deciding factor for whether something may be automated is **whose action triggers
it**, not whether automation is involved at all. Automation firing on an event fully
within an authorized admin's direct control (their own commit, merge, or explicit
dispatch — e.g. Release Please) is fine. Automation reacting to a lower-privileged or
externally-sourced signal is not — even a purely informational one. Concretely: a
non-admin EO member marking "beta test passed" must never auto-trigger promotion; that
marker is a no-op for automation, always. It can inform a human admin's decision, but
must never be wired to fire one itself. Applies to every approval gate in this design,
not just gem promotion.

# Phase 2 Decisions

Record of the Phase 2 (front door) decisions, worked out collaboratively in 2026-07,
grounded directly in `AUDIT-ruby4-bundled-gems-suite.md` and
`AUDIT-ruby4lich5-installer.md` (both in this `docs/` folder) rather than re-derived from
scratch. Six items; see `ROADMAP-woven-plan.md` Phase 2 for how this fits the build order.

## 1. Tri-state classification

Given a gem name (+ version), classify in this order, cheapest check first:

1. **Pure?** Gemspec has zero `extensions` → pure. Fetch + package, no compile.
2. **Already precompiled upstream for our exact target platform *and* ABI?** Check for a
   published version tagged with our target platform (e.g. `x64-mingw-ucrt`) — but the
   platform tag alone is **not sufficient**. Verified directly against real rubygems.org
   data: `sqlite3` and `ffi` already ship `x64-mingw-ucrt` builds; `ox`, `curses`,
   `cairo`, `gtk3`, `glib2` do not (still only the old, pre-UCRT `mingw32` tag, if
   anything) — confirming why the factory needs to compile the GTK3 stack itself. Even
   when the platform tag matches, we must actually inspect the gem's contents for our
   specific target Ruby ABI subdirectory (the `lib/<gem>/<abi>/` convention from Phase 1
   §2) before trusting it — `required_ruby_version` is too often missing to rely on
   alone (per the gem-suite audit's §2.3 finding). If present and ABI-matching → **native,
   pass-through** (use upstream's binary directly, no MSYS2 involved).
   - **No version-hunting fallback.** If the *specific requested version* doesn't have a
     matching platform+ABI precompiled build, fall straight through to building that
     exact version ourselves. Never substitute a different (e.g. earlier) version just
     because it happens to be precompiled — that would silently ship something other
     than what was requested and reviewed. This also isn't a capability loss: the
     build-it-ourselves path is the factory's core proven capability, not a risky
     fallback, and it's specifically necessary right after adopting a new Ruby ABI, when
     upstream binaries for it don't exist anywhere yet regardless of maintainer quality.
3. **Neither of the above** — needs our own compilation. Maps to a known, maintained set
   of MSYS2 ucrt64 packages → **native-self-contained**, compile it. Doesn't map (a
   genuinely unvendorable system dependency) → **native-needs-system-lib**, reject
   loudly rather than guess.

## 2. DLL bundling strategy: consolidate to one mechanism

Per gem-suite audit §2.1/§2.2: two mechanisms exist today and only one actually works.
`extract-dll-dependencies.rb`'s dependency-aware de-duplication is dead code (its
gemspec lookup never resolves, since the build harness `chdir`s into the gem directory
first — it always returns an empty set and never deduplicates anything). The real
runtime dependency is the broad PowerShell DLL-closure walker that vendors DLLs into
`glib2`/`cairo`'s `vendor/bin`, relying on load-order + `prepend_dll_path`.

**Decision:** delete the dead per-gem Ruby script entirely; keep the PowerShell closure
walker. Fixing the dead script's gemspec-path bug would just resurrect a second
mechanism doing what the closure already does.

**Forward note, not a decision to make now:** this is PowerShell, Windows-only tooling.
When Linux/macOS are eventually built (Phase 1 §platform scope), native build (build ON
each target OS/distro, not cross-compilation) is the right approach — Linux's own
glibc/musl/arch diversity is better handled by building inside a real representative
container per target than by cross-compiling from one host, and cross-compiling to
macOS from Linux is genuinely painful and legally murky (osxcross + Apple SDK headers).
The overall classify → build → vendor-deps → smoke → publish architecture generalizes
across platforms; the vendor-deps step itself is inherently platform-native tooling
(PowerShell/DLL-closure on Windows, `ldd`/`patchelf`-shaped on Linux,
`otool`/`install_name_tool`-shaped on macOS) — three implementations, not one portable
script.

## 3. Version-literal parameterization + assert-changed patches

Per gem-suite audit §2.4/§2.5: cairo's patch step hardcodes the literal `'1.18.4'` and a
`= 4.3.\d+` regex; a version drift makes the replace silently no-op (this already cost a
real red build once, a `%q<pkg-config>` strip miss). Per the roadmap's own instruction,
this isn't a standalone patch — it's fixed by construction once gem name+version are
real per-gem inputs instead of hardcoded literals.

Two refinements beyond the audit's own recommendation:
- **Assert the exact expected match/replacement count**, not just "did anything
  change." A before/after diff would miss a regex that's slightly too loose and matches
  the wrong spot — technically non-a-no-op, but still wrong.
- **Derive the version from the actually-fetched source**, not just the dispatch input
  string. Read the real version back out of what was actually downloaded and use that
  for every subsequent patch operation, so a stale cache or wrong URL surfaces
  immediately as a mismatch rather than patching against an assumption.

## 4. Closure resolution

Reuse RubyGems' own dependency resolver (`Gem::Resolver`, or `bundle lock` against a
throwaway Gemfile requesting the target gem) rather than hand-rolling a constraint
solver — consistent with leaning on proven ecosystem tooling wherever it already solves
the problem (same reasoning as Phase 1's release-resolution mechanism).

- **Topologically sort the resolved set** (leaves first) — formalizes what the current
  prototype already does by hand for the GTK3 stack (gobject-introspection → cairo →
  cairo-gobject → pango → atk → gtk3).
- **Walk bottom-up, checking the curation manifest at each node first.** A compatible
  already-published version means skip/reuse, not rebuild. Missing or unsatisfied →
  recursively apply the same classify → build → publish pipeline to that dependency
  before touching the thing that depends on it.
- **A `native-needs-system-lib` classification anywhere in the closure fails the whole
  request loudly** — no partial-success state; you can't ship a gem whose dependency
  can't be built.
- Circular runtime dependencies aren't a practical Ruby-ecosystem concern; not building
  dedicated cycle-handling for a case that doesn't really occur.
- **Pragmatic caveat:** start with the `Gem::Resolver` path; if it doesn't hold up in
  practice, adapt without over-investing in defending the original choice.

## 5. Generalized smoke

Reuse the same resolved closure from §4: write it out as a throwaway `Gemfile` and run
`Bundler.require` against the freshly-baked tree, rather than hand-deriving a require
path per gem name (which don't always match — `tzinfo-data` requires as `tzinfo/data`,
not literally `tzinfo-data`). This also solves the audit's Part 3 "undocumented consumer
load-order contract" finding as a side effect — Bundler already requires gems in
dependency-resolved order, so there's no separate order to track.

**Scope boundary:** this item is only about making smoke gem-agnostic, not deepening
what it verifies (a truly clean runner with no MSYS2 on disk, real widget/query checks)
— that's audit §2.9, explicitly Phase 5.

**Kept exception:** `Gtk.init` stays as a post-require check specifically for GTK3, per
a real, recurring "installed / no workie" failure history that a bare `require` can't
catch. Not a precedent for hand-writing bespoke per-gem checks generally — a deliberate,
narrow exception for one gem with a documented reason, not the default.

**Bundled test-harness reconsumption (additive, informational only):** most well-
maintained gems ship their own test suite. Best-effort reuse:
- Scope detection to what's in the package **we already fetched** — a `spec/`/`test/`
  directory plus something runnable (`Rakefile` with a recognizable task, `.rspec`).
  Deliberately not also cloning the gem's upstream git repo looking for excluded tests —
  that adds a second fetch path and a "which URL/tag is authoritative" question for a
  nice-to-have.
- Attempt with what's already on hand; don't provision a bundled suite's own dev
  dependencies (test-only gems, display servers for GUI tests) to force it to run.
- **Never a hard gate.** Pass, fail, or "present but not runnable here" all just get
  written into the PR for the human to read. A failing or unattemptable bundled suite
  doesn't block build/publish — it's a data point for the approval decision, not a
  second, less-controllable smoke gate.

## 6. Publish mechanism

Reuses the same guard → checkpoint → PR-review → merge-triggers-finalize shape as
Phase 1 §4's curation mechanism, applied concretely:

1. **Guard:** if the requested gem+version already matches the manifest's current pin,
   stop — no duplicate release, no no-op PR.
2. **Checkpoint:** a timestamped backup tag of the manifest's current state before
   mutating anything.
3. **Build the full resolved closure** (§4), not just the named gem.
4. **Upload each built gem as a draft release**, one release/tag per gem-version, before
   the review step — review happens against the real built artifact and its real
   checksum, not a promise of one. (Confirmed: acceptable to spend the compute before
   approval, since a rejected draft release is just deleted.)
5. **Open one PR per dispatch, not one per gem** — a single upstream bump that touched
   ten gems (e.g. a GTK3 suite bump) is one coherent manifest diff, reviewed as one
   change.
6. **PR merge — an admin's own controlled action — triggers publishing the already-
   built draft releases**, mirroring `release-on-push-stable.yaml`'s own PR-merge-
   triggers-publish pattern. Manifest pin and the actual downloadable releases move from
   draft to live together, at the same approved moment — no window where one is current
   and the other isn't.

# Phase 5 Decisions

Record of the Phase 5 (hardening/polish) decisions, worked out collaboratively in
2026-07. Six items from the roadmap; all resolved or deliberately deferred with a
documented reason.

## 1. DevKit wizard freeze — fix, matching RubyInstaller's own reference pattern

The audit root-caused this precisely: the `[Run]` entry runs `ridk install` with
`waituntilterminated runhidden`, which blocks the Inno wizard's UI thread for the whole
of a hidden, minutes-long ~1.5GB MSYS2 download — the wizard looks hung. Of the three
options the audit offered, going with its top recommendation: move DevKit installation
to the **finish page** as a `postinstall nowait skipifsilent unchecked` task, running
`ridk.cmd install` with a visible console instead of hidden — matching RubyInstaller's
own reference `.iss` exactly (`ShellExec` with `ewNoWait` + `SW_SHOWNORMAL`).

## 2. Duplicate-installs note — documentation only, no fix needed

Audit §2.12 already verified this is expected multi-phase behavior (build → repack →
smoke produces the same gem installed 2-3 times during the pipeline), not version drift
— exactly one version of anything ever ships. Just needs a one-line log/comment note so
a future reader doesn't mistake the repeated install lines for a bug.

## 3. gio2/noise corral — curated known-good DLL list, verified against the real build

Audit §1.2's named-Win32-DLL warnings (29 lines) already have one clear recommended
rule: if it isn't in the MSYS2 ucrt64 lane, it's OS-provided, full stop. For §1.1's 711
"assuming system or non-UCRT" notices, rather than picking one of the audit's three
generic noise-reduction styles, built a real curated baseline from the actual reference
run's logs (verified directly, not estimated): **44 distinct DLL names** behind the 711
occurrences (case-insensitive; the raw extraction shows 46, but two are the same DLL
counted twice under inconsistent casing — `ws2_32.dll`/`WS2_32.dll`,
`userenv.dll`/`USERENV.dll`). All 44 are exactly the small, stable set you'd expect —
core Win32 libraries and the standard `api-ms-win-crt-*` Universal CRT api-set
forwarders — nothing gem-specific.

Mechanism: compare each "assuming system" DLL against the curated list, **case-
insensitively**. A match is silent — no log line at all. A miss (something not on the
list) gets a summary line per gem, not per DLL. This also lays the groundwork for audit
item 1.3 (fail-loud on a genuine miss), which needs exactly this kind of known-good
baseline to distinguish "known-benign" from "worth a human looking at."

## 4. `.lic`-from-master pinning — deliberately not pinned

Today's installer pulls default convenience scripts (`alias.lic`, `autostart.lic`,
`go2.lic`, etc.) from `elanthia-online/scripts`' `master` at build time, unpinned.
Decided to keep it that way, not as an oversight but because the script-update cycle is
intentionally fluid — a build is routinely "stale" within days of being cut, and that's
fine, because it's not the only mechanism keeping scripts current. Verified directly:
`scripts/scripts/repository.lic`'s `SettingsManager` tracks exactly this curated set as
`Settings['updatable'][:scripts]`, checks each one's remote timestamp on every
`;repository download-updates` run (widely believed, though not independently confirmed
by reading `autostart.lic`, to fire automatically on Lich launch), and lets a user pull
any single item out of that auto-update list via `unset-updatable` — which is exactly
the per-script pin/opt-out mechanism that makes floating safe at the installer level:
staleness at build time is smoothed over by the running application's own update cycle,
and a user who wants a script frozen already has a real, working way to do that
themselves.

## 5. Code-signing — deferred pending an upcoming policy decision

Not pursued for now; will inform next steps once decided. Nothing in this design
forecloses adding it later — signing is a post-build step against Inno Setup's single
finished `.exe`, composes cleanly with (doesn't replace) the checksum/provenance model
already in place, and the existing test-vs-production installer split (Phase 1 §7)
already gives a natural "sign production builds only" hook whenever it's adopted.

## 6. Deepen the smoke — split into environment and depth

**Environment (real fix, not yet implemented):** verified directly that this genuinely
hasn't landed yet. The archived installer-assembly workflow
(`build-ruby4lich5-installer.yaml`) already smoke-tests on an effectively clean runner,
but not because job separation was deliberately engineered for it — it never installs
MSYS2 at all, since it only consumes already-compiled gems from a Release. The actual
gem-*compilation* workflow (`ruby4-bundled-gems-suite.yml`, the real Phase 2 seed) is
still a single job: MSYS2 gets installed and smoke runs later in that same job, same
runner — audit §2.9's exact concern, unresolved. Fix, when Phase 2 gets implemented:
split gem-compilation and smoke into separate jobs. GitHub Actions jobs are separate VMs
by default, so this gets a genuinely clean, no-MSYS2-residue environment for free,
without containers or other infrastructure.

**Depth (no new mechanism needed):** `Gtk.init` stays as the sufficient check, per real
historical experience — it's the same check already used today to detect corrupted
installs when supporting Lich5 consumers. Going deeper (real widget creation/render) was
considered and explicitly not pursued, at least for now. For everything else, the
generalized bundled-test-suite reuse already designed in Phase 2 §5 *is* the answer to
"prove it works, not just loads" — not a second, parallel deepening mechanism.

# Phase 3 and Phase 4 — satisfied by Phase 1/2, no separate work

The roadmap's Phase 3 (gems server / index) and most of Phase 4 (installer assembly
rework) turned out to already be resolved as a side effect of Phase 1 and Phase 2, not
something requiring its own discussion:

- Phase 3's "stand up the server repo" is moot (Phase 1 §3: one repo, no separate server
  repo exists). Its "publish mechanism replacing the hand-made test prerelease" is Phase
  2 §6. Its "curation manifest + checksums" is Phase 1 §2/§4.
- Phase 4's "repoint the installer workflow at the curated set" is Phase 1 §5/§6/§7 (the
  EO↔Ruby4Lich5 release flow, baked-tree caching, test/production installer split).

The one genuinely new piece of Phase 4 — gem-suite audit §2.11, redundant default/bundled
gems — is below.

## Redundant default/bundled gems (§2.11)

Verified directly (filesystem, not the unreliable `Gem::Specification#default_gem?` —
it reported `false` even for true default gems like `date`/`psych` in this rbenv-managed
Ruby; the authoritative signal is gemspec placement in `specifications/default/` vs.
plain `specifications/`): `rexml`, `matrix`, `set`, and `webrick` are **all four bundled
gems**, not default gems — the audit's original wording singled out `set` as "the
default gem" as if it were a different category from the other three; on this Ruby
series it isn't, all four are the same classification.

**Drop `rexml`, `matrix`, `set` from the shipped bundle** — RubyInstaller already
provides all three; shipping them again is redundant. `rexml`'s presence in `lich-5`'s
own Gemfile is separately a stale leftover of a since-resolved defect pin, worth cleaning
up there directly (not a Ruby4Lich5 concern).

**Keep `webrick`**, but not for the reason initially suspected. `mechanize` does declare
`webrick (~> 1.7)` as a genuine runtime dependency (confirmed against rubygems.org), but
`mechanize` itself doesn't appear anywhere in `lich-5`, `scripts/scripts`, or
`lich_repo_mirror` — that chain doesn't apply here. The real, stronger reason:
`scripts/scripts/webui.lic` directly `require`s `webrick` and runs an actual
`WEBrick::HTTPServer` with servlets — first-party, direct, deliberate usage. Exactly the
kind of documented allowlist entry the audit's own exclusion mechanism calls for.

**`matrix` is genuinely needed, just not by us to ship.** Traced the actual dependency
chain in `lich-5`'s `Gemfile.lock`: `cairo → red-colors → matrix`, entirely inside the
GTK3/Ruby-GNOME suite. Closure resolution (Phase 2 §4) will correctly find `matrix` as a
real, declared dependency when resolving `cairo`'s closure — the bundled-gem-exclusion
filter is what correctly drops it from the *shipped* set anyway, since the base Ruby
install already satisfies it. Two different, both-correct answers to two different
questions ("is this needed" vs. "do we need to distribute it").

**`ox`** is confirmed present on both the current `runtime-gems` and `native-runtime-gems`
workflow inputs — unaffected by this cleanup, and (per earlier verification) one of the
two gems with no precompiled Windows binary upstream at any version, so it always routes
to "build it ourselves" under the classification design.

# Phase 6 Decisions

One item, additive by the roadmap's own design — no index redo needed, since Phase 1
§2's `gem × platform` matrix already accommodates a new Ruby ABI as an additional cell,
not a restructure.

**Generalize the ABI guard.** The installer-assembly workflow's `ruby-installer-version`
resolution is hardcoded to a `4.0.x` series today (audit finding, `wf 105`). Fix: make
the Ruby-series target a real per-build parameter instead of a hardcoded value, so a
future "Ruby 4.1 installer" variant is a parameter value, not a forked workflow file.
Everything else a new ABI requires — rebuilding every tracked gem to embed the new ABI's
binary, keeping the older ABI's installer variant running alongside it — is already
decided (Phase 1 §2's build-discipline consequence).

# Phase 7 Decisions

Mostly already satisfied by earlier design choices rather than new writing:

- **Consumer load-order contract** — the mechanism is already designed, not just
  documented: Phase 2 §5's `Bundler.require` reuse means gems get required in
  dependency-resolved order automatically, as a side effect of reusing Bundler rather
  than hand-rolling require order. A short written note explaining *why* (for any
  consumer not going through Bundler) is still worth adding, but the hard part — actually
  getting load order right — is already solved in the design, not left as a doc-only gap.
- **ADR** — not adopting a separate ADR-per-file convention. `DECISIONS.md` already
  serves that role, consolidated by phase rather than one file per decision; a parallel
  system would be redundant.
- **Build/release runbook** — deliberately deferred, not skipped. A runbook describing
  how to operate workflows that don't exist yet risks being wrong the moment
  implementation differs from plan. Write it once there's real code to document
  truthfully, not before.
- **Keep `GEM-FACTORY-vision.md` current** — rather than rewriting its original
  "sleep-on-it" framing (which would blur what was open *then* vs. resolved *since*), add
  a short pointer at its top to this file. Preserves the original as a historical
  snapshot while directing readers to where the current state actually lives.



## Accepted candidate installer rebuilds

Candidate builds retain the complete tested bundle in their immutable ZIP:
`gem-build-metadata.json`, `resolution-lock.json`, ordered install targets,
runtime inventory, install script and gem packages. Keep the candidate and its
referenced assets while an accepted or rollback manifest needs them.

Installer source selection is explicit. `gem-source=actions` requires the
successful same-repository gem-suite `gem-build-run-id` and retains the checked
Actions artifact/run/attempt path. `gem-source=accepted-candidate` requires the
exact `R4L5-gem-bundle-x64-mingw-ucrt-candidate-RUN-ATTEMPT` tag and an empty run-ID
input. The deprecated `gem-repo` and `gem-release-tag` compatibility inputs are removed
with this layer's proposer update; neither is a source selector.

The retained source works after Actions artifacts expire; it does not query the
old run or depend on its artifact availability. It reads the currently served
accepted manifest and the explicitly selected same-repository candidate release.
The candidate's manifest asset digest must match the accepted bytes exactly,
and the accepted Windows Ruby 4.0 target must reference that candidate ZIP's exact
URL, filename and SHA-256. An unpromoted, superseded or mismatched candidate is
rejected. A candidate ZIP not referenced by accepted policy cannot be substituted
merely because its package versions appear equal. The mutable production ZIP is
never used, and an expired Actions request never silently switches source.

The downloaded ZIP is digest-checked before extraction. Entries must have unique
flat filenames and no links. Extracted run/attempt/source metadata, per-file
hashes and ordered inventories use the same verifier as Actions artifacts. The
RubyInstaller version and archive digest must match the original tested source;
the actual executable download is independently verified. The normal inventory,
SQLite ABI and baked-runtime checks still run before installer output is accepted.
The retained route checks the accepted manifest identity again before finalizing
provenance and rejects a changed predecessor. Provenance distinguishes the source
and records the candidate tag, accepted-manifest digest and ZIP digest.

Use this route to rebuild the currently accepted candidate, rather than rebuild
arbitrary historical candidates against newer policy. Restore an older accepted
state only through the separately reviewed promotion/rollback process. Missing
legacy metadata cannot be reconstructed by assertion: use a new reviewed factory
candidate when the retained bundle lacks the required evidence.

The shared `Select-RuntimeGemManifest` helper executes the actual factory tooling
exclusion. Its policy is a nonempty JSON array of literal ASCII gem-name strings;
assignment and explicit enumeration preserve the list under Windows PowerShell
5.1 and PowerShell 7. Native 5.1 Pester runs the same production helper, not a
textual copy of the workflow expression. Local PowerShell Core results do not
replace the native Windows factory/publication or installer acceptance runs.


## Promotion bootstrap and producer branch policy

An authorized administrator may build and select a candidate from an unmerged
producer branch. This is intentional. `Assert-GemBuildRun` requires a completed,
successful manual gem-suite run in this repository, and the bundle metadata binds
its full source SHA, run ID and attempt. The factory and installer accept an
administrator's own dispatch or rerun; neither implies that a producer branch has
merged. Both inspection and promotion must dispatch from the default branch.
Promotion approval binds the exact candidate, predecessor and change-report
hashes, and rechecks candidate identities after clean consumer recovery. Do not
add a producer-default-branch requirement as an incidental review change.

The P1 SQLite bootstrap is a one-time prerequisite to that normal promotion
operation. `PromotionPlan` deliberately refuses a predecessor or rollback still
serving sqlite3 below 2.10.2. Preparing a candidate is not delivery of P1: the
consumer URL must first serve the reviewed narrow manifest update. Do not disable
the fixed-SQLite floor or pretend ordinary inspect/promote can bootstrap it.
Retire this exceptional procedure after verified P1 public readback; subsequent
manifest changes use the normal administrative promotion gates.

### Prepare and validate the narrow P1 manifest

Run from this checkout using the validated Ruby environment and PowerShell 5.1
or newer. These preparation commands only read public bytes and write the local
work directory. The predecessor below is the reviewed pre-P1 manifest. A mismatch
requires a new inspection and review; do not replace the expected hash with
whatever was just downloaded. If the accepted predecessor already contains the
fixed SQLite package, use normal promotion instead of replaying this bootstrap.

```powershell
$ErrorActionPreference = 'Stop'
$repository = 'elanthia-online/Ruby4Lich5'
$liveTag = 'R4L5-gem-bundle-x64-mingw-ucrt'
$approvedPredecessor = 'sha256:644a01a8c3098bbf74a7db4446236324cf0db1a2615e983d88c2c6f007d4ab1c'
$workDir = Join-Path ([IO.Path]::GetTempPath()) ('r4l5-p1-' + [guid]::NewGuid().ToString('N'))
$previousDir = Join-Path $workDir 'previous'
$candidateDir = Join-Path $workDir 'candidate'
New-Item -ItemType Directory $previousDir, $candidateDir | Out-Null
$previous = Join-Path $previousDir 'R4L5-gem-manifest.json'
$candidate = Join-Path $candidateDir 'R4L5-gem-manifest.json'
$package = Join-Path $workDir 'sqlite3-2.10.2-x64-mingw-ucrt.gem'
$versions = Join-Path $workDir 'sqlite3-versions.json'
. ./gem-manifest-promotion.ps1
Confirm-LiveGemManifest -Repository $repository -ExpectedDigest $approvedPredecessor -DestinationPath $previous
Invoke-WebRequest -UseBasicParsing -Uri 'https://rubygems.org/api/v1/versions/sqlite3.json' -OutFile $versions
Invoke-WebRequest -UseBasicParsing -Uri 'https://rubygems.org/downloads/sqlite3-2.10.2-x64-mingw-ucrt.gem' -OutFile $package
& ruby bin/prepare_sqlite3_recovery.rb $previous $package $versions $candidate
if ($LASTEXITCODE -ne 0) { throw 'P1 preparation failed; nothing may be uploaded.' }
```

The preparation tool checks the exact upstream version/platform, downloaded
SHA-256 against RubyGems metadata and the Ruby 4.0 SQLite extension entry. It
requires exactly one single-member SQLite unit. Independently verify that only
its artifact and package descriptors changed, with other units, order, target
metadata, IDs, members and install order preserved:

```powershell
$structuralCheck = @'
require 'json'
before, after = ARGV.map { |path| JSON.parse(File.read(path, encoding: 'bom|utf-8')) }
key = ['4.0', 'x64-mingw-ucrt']
old_target = before.fetch('targets').find { |target| target.values_at('ruby_abi', 'platform') == key }
new_target = after.fetch('targets').find { |target| target.values_at('ruby_abi', 'platform') == key }
abort 'missing Windows target' unless old_target && new_target
index = old_target.fetch('units').index { |unit| unit.fetch('members') == ['sqlite3'] }
abort 'missing SQLite unit' unless index
old_unit = old_target.fetch('units').fetch(index)
new_unit = new_target.fetch('units').fetch(index)
keep = ->(unit) { unit.reject { |field, _| %w[artifact packages].include?(field) } }
abort 'SQLite unit identity/order changed' unless keep.call(old_unit) == keep.call(new_unit)
new_target.fetch('units')[index] = old_unit
abort 'unrelated manifest content changed' unless before == after
puts 'Only the SQLite artifact/package descriptors changed.'
'@
& ruby -e $structuralCheck $previous $candidate
if ($LASTEXITCODE -ne 0) { throw 'P1 structural review failed.' }
& ruby bin/validate_gem_manifest.rb $candidate
if ($LASTEXITCODE -ne 0) { throw 'P1 current-consumer validation failed.' }
```

Run both pinned consumer planners in separate processes. Host target projection
below checks parsing/planning only; it does not claim clean Windows recovery or
native activation. The normal promotion operation still requires those later.

```powershell
$consumerCheck = @'
require 'json'
require_relative './lib/ruby4lich5/recovery_consumers'
require_relative './lib/ruby4lich5/recovery_sequence'
entry = Ruby4Lich5::RecoveryConsumers.entry(ARGV.fetch(0))
require entry.fetch('absolute_path')
document = JSON.parse(File.read(ARGV.fetch(1), encoding: 'bom|utf-8'))
target = document.fetch('targets').find { |item| item.values_at('ruby_abi', 'platform') == ['4.0', 'x64-mingw-ucrt'] }
abort 'missing Windows target' unless target
projected = document.merge('targets' => [target.merge('platform' => Gem::Platform.local.to_s)])
recovery = Lich::DependencyRecovery.new(http_get: ->(_url) { JSON.generate(projected) })
recovery.define_singleton_method(:ruby_abi) { '4.0' }
names = target.fetch('units').flat_map { |unit| unit.fetch('members') }.uniq
Ruby4Lich5::RecoverySequence.next_plan(recovery, names, installed: ->(_package) { false })
puts "#{ARGV.fetch(0)} #{entry.fetch('commit')}: P1 planning accepted"
'@
foreach ($consumer in @('current', 'oldest')) {
  & ruby -e $consumerCheck $consumer $candidate
  if ($LASTEXITCODE -ne 0) { throw "P1 $consumer planning failed." }
}
$preparedDigest = 'sha256:' + (Get-FileHash $candidate -Algorithm SHA256).Hash.ToLowerInvariant()
Write-Host "Review P1 bytes and record candidate digest: $preparedDigest"
```

### Owner-only delivery and readback

Review the original package digest/ABI results, structural comparison, both
consumer plans, predecessor hash and exact prepared-manifest hash before any
write. Record the selected candidate digest explicitly. Keep other manifest
promotion operations idle during this one-time replacement. The following block
is an owner action after that review, never an automatic step of preparation:

```powershell
$approvedP1Digest = 'sha256:REPLACE_WITH_REVIEWED_64_HEX_DIGEST'
if ($approvedP1Digest -cnotmatch '\Asha256:[0-9a-f]{64}\z' -or
    ('sha256:' + (Get-FileHash $candidate -Algorithm SHA256).Hash.ToLowerInvariant()) -cne $approvedP1Digest) {
  throw 'Prepared P1 bytes differ from the explicit reviewed candidate digest.'
}
if ((Get-LiveGemManifestDigest -Repository $repository) -cne $approvedPredecessor) {
  throw 'Predecessor changed; stop for a new inspection. Nothing uploaded.'
}
Invoke-PromotionGh -Arguments @('release', 'upload', $liveTag, $candidate, '--repo', $repository, '--clobber') | Out-Null
$served = Join-Path $workDir 'served-R4L5-gem-manifest.json'
Confirm-LiveGemManifest -Repository $repository -ExpectedDigest $approvedP1Digest -DestinationPath $served
& ruby bin/validate_gem_manifest.rb $served
if ($LASTEXITCODE -ne 0) { throw 'P1 served readback failed validation; hold further releases.' }
foreach ($consumer in @('current', 'oldest')) {
  & ruby -e $consumerCheck $consumer $served
  if ($LASTEXITCODE -ne 0) { throw "P1 served $consumer planning failed; hold further releases." }
}
```

Only `R4L5-gem-manifest.json` is replaced. Do not upload a ZIP, native package,
installer or unrelated asset, and do not restore the vulnerable pre-P1 manifest
as a routine rollback. Unconfirmed readback requires an administrative hold and
investigation, not continuation to installer builds. Retain the previous,
prepared and served bytes, upstream package/metadata and hashes as delivery
evidence. Reconcile the exact readback manifest through owner-controlled
repository history before normal candidate promotion and installer acceptance.
No bootstrap upload is performed by this correction pass.

After promotion, installer rebuilds may use #46's explicit accepted-candidate
route even after the tested Actions artifact expires. That route does not need
another promotion dispatch or an old run lookup. Ordinary promotion inspection
continues to verify its producing run and clean recovery receipts; the installer
rebuild route does not weaken those admission requirements. A candidate whose
ZIP is not bound by the accepted manifest, or lacks the required metadata, remains
ineligible for retained-source installer rebuilding.
