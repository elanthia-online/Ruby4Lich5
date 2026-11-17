# Platform genesis

How a new platform (first: `aarch64-mingw-ucrt`) gets its first accepted gem manifest, and
what the factory checks for it. Only repository administrators run any of this.

## Per-platform supported-client scope

Before recovery installs anything, promotion checks that every supported Lich client can
start against the candidate manifest (`SupportedStartupPolicy`). The two legacy consumers
(`current`, `oldest`) and the published startup revisions (`startup`) are registered in
`config/supported-startup-clients.json`. The candidate's own ranged consumer is not registered
there: `SupportedStartupPolicy.identity` derives it from the candidate contract and the
reviewed source (`vendor/lich5/ranged-source.json`).

A new platform has no published Lich release that ever ran on it, so checking the x64
client history there proves nothing. `config/supported-startup-platform-scopes.json` narrows
the checked set per platform:

```json
{ "schema": 1, "platforms": { "aarch64-mingw-ucrt": { "legacy": [], "startup": [], "soak": [], "ranged": true } } }
```

- `legacy` and `startup` name registered clients that are checked on that platform.
- `soak` names registered startup clients being soaked on that platform before they become
  part of its permanent set. R6d adds `v5_25_0` to the aarch64 `soak` list once Lich 5.25.0
  is published and registered, and it leaves `soak` when the R7 soak ends.
- `ranged` must be `true`: the candidate's own ranged consumer is always checked.
- Every name must be a registered client, and no client may be in both `startup` and `soak`.

A platform with no entry (x64) keeps every registered client, and its approval still hashes
the clients file itself, so the scopes file can change without changing any x64 approval.
A scoped platform's approval hashes `scope_projection`: the whole clients file, with
`legacy`/`startup` narrowed to its entries, nested under `clients`, beside the platform and
its scope. Because the file is nested, a key in it named `platform` or `scope` cannot be
overwritten, so every key, including one added later, is bound.

Two rules keep the scope from weakening anything else:

- **Retention is not scoped.** The published-release retention check still runs over every
  registered client before the scope narrows what is checked.
- **The platform comes from the candidate, not the host.** `SupportedStartupPolicy.candidate_platform`
  reads the candidate contract's measured platform; `identity`, `verify!` and the recovery
  smoke's skip decision all use it, so an x64 candidate relabelled as aarch64 is refused.

At runtime only the requested platform's entry is validated, so an unfinished entry for
another platform cannot stop x64 promotion. `SupportedStartupPolicy.validate_scopes!`
validates the whole file, and the spec suite runs it on the committed files in CI.

In the recovery job, a consumer outside the approved scope (on aarch64: `current` and
`oldest`) loads no consumer code and writes a skip marker so the job completes. A name that
is neither configured in `config/recovery-consumers.json` nor `ranged` is refused before
that decision, so it never leaves a marker. A skip marker is never a receipt: the required receipt set comes from the approved scope, which the
ranged receipt binds by digest.

## Genesis publication

Ordinary publication fetches the accepted predecessor manifest from the platform's
production release and builds the candidate's lifecycle from it. A platform with no
production release has no predecessor, so the bundled-gems suite takes an explicit
`genesis` input (default `false`). With `genesis: true`:

- **Before the build** (`Prepare accepted package reuse`), the run refuses a non-blank
  `accepted-candidate-tag` (there is no accepted candidate to reuse) and runs
  `LifecyclePolicy#require_predecessor_free!`, which refuses any lifecycle unit transition
  or range in `config/gem-lifecycle.json`: whatever the generator would refuse later
  without a predecessor. The message can differ from the generator's: for a range naming an
  unknown unit, or ranges that disagree on a shared closure, `apply` reports "range names
  unknown unit X" or "shared closures require the same Lich range" where the early check
  reports "ranges require a legacy predecessor". A `range_reader` alone is accepted: without
  ranges it has no effect.
- **After the build**, the generator runs without its optional predecessor argument, the GTK
  freeze step is skipped, and `LifecyclePolicy#apply` refuses the same rules again.
- **Before the only write**, the publish step proves the production release absent
  (`Get-GemProductionReleaseState`): the release and the git tag must both answer HTTP 404,
  and no listed release, drafts included, may carry the tag. Any other failure is "unknown",
  never "absent". The publish job has `contents: write`, so every step in it, actions
  included, runs with that permission; the publish step is the only one that exports
  `GH_TOKEN` to its shell, and the only one that writes a release.
- **At publication**, the candidate release gets genesis notes
  (`Get-GemCandidateReleaseNotes -Mode genesis`): no predecessor, a pointer to this
  document, the genesis inspect and promote inputs (`genesis=true`, `live-sha256=absent`,
  `genesis-confirm` set to the production tag), and that the installer stays x64-only.
  Ordinary candidates keep their existing notes unchanged.

With `genesis: false` nothing changes: a missing predecessor still fails with "Accepted
predecessor acquisition failed."

### Lifecycle ordering constraint

`config/gem-lifecycle.json` is shared by every platform. Genesis refuses while it holds any
lifecycle unit transition or range, because those rules need predecessor bytes the new
platform does not have. **aarch64 genesis must therefore run before any x64 lifecycle rule
lands in that file.** If an x64 rule has to land first, it must be removed (or the file made
per-platform) before genesis can run.

### Native gh calls

Every `gh` call in the publication, promotion and genesis scripts goes through
`Invoke-GhNative` (`gh-native.ps1`). It sets a function-local
`$ErrorActionPreference = 'Continue'` so that, under Windows PowerShell 5.1 and the
`Stop` preference GitHub Actions sets, gh's stderr (for example the HTTP 404 that proves
absence) reaches the exit-code check instead of becoming a terminating error.
`Invoke-CandidateGh` and `Invoke-PromotionGh` are thin layers that throw `gh failed: ...`
on a non-zero exit.
