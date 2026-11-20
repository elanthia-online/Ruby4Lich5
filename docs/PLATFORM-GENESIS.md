# Platform genesis

How a new platform (first: `aarch64-mingw-ucrt`) gets its first accepted gem manifest, and
what the factory checks for it. Only repository administrators run any of this.

## What genesis is, and why

Every ordinary publication and promotion compares a candidate with the platform's accepted
predecessor: the `R4L5-gem-manifest.json` served from the production release
`R4L5-gem-bundle-<platform>`. Lifecycle rules, withdrawals, rollback bytes and the approved
`live-sha256` all come from it. A new platform has no production release, so there is
nothing to compare with, and the ordinary path refuses (by design): publication with
"Accepted predecessor acquisition failed", and inspect or promote with
`gh failed: release not found` from the live-manifest lookup.

Genesis is the explicit, administrator-gated path for exactly that case: publish a first
candidate without a predecessor, inspect and recover it like any other, and then create the
production release with that manifest. It refuses whenever the production release, a bare
tag of that name, or a draft of that name already exists, so it can never shadow an
accepted manifest. After genesis the platform uses the ordinary path.

Contents: [scope](#per-platform-supported-client-scope) ·
[publication](#genesis-publication) · [gates](#genesis-inspect-and-promote-gates) ·
[runbook](#operator-runbook) · [failure recovery](#failure-recovery) ·
[open verification](#open-verification)

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
{ "schema": 1, "platforms": { "aarch64-mingw-ucrt": { "legacy": [], "startup": [], "soak": ["v5_25_0"], "ranged": true } } }
```

- `legacy` and `startup` name registered clients that are checked on that platform.
- `soak` names registered startup clients being soaked on that platform before they become
  part of its permanent set. R6d added `v5_25_0` (lich-5 5.25.0, registered 2026-11-18) to
  the aarch64 `soak` list, so an aarch64 approval checks `v5_25_0` and the ranged consumer.
  It leaves `soak` when the R7 soak ends.
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

## Genesis inspect and promote gates

`promote-gem-candidate.yml` takes `genesis` (boolean, default `false`) and
`genesis-confirm`. Modes stay `inspect`/`promote`. A genesis promote writes only if every
gate below holds:

| Gate | Where |
|---|---|
| Administrator dispatch from the default branch | `require-admin-dispatch`, in the inspect and promote jobs (recover has none; it holds no write token and promote needs it) |
| `r4l5-recovery-promotion` exists with exactly one required-reviewers rule naming administrator users | inspect: `Check the genesis approval environment` (`InstallerRelease#environment` in `.github/scripts/installer-release.cjs`) |
| Production release, bare tag and drafts absent | inspect: `Prepare-GemPromotion -Genesis`, before and after acquisition, checks the release and bare tag; drafts are invisible to it (it runs with `contents: read`, which cannot list drafts). promote: `Invoke-GemManifestGenesis` re-checks all three, drafts included (the job has `contents: write`), before the write |
| Plan is a genesis plan: `genesis: true`, `live_sha256: "absent"`, no rollback, bound into `change_sha256` | `bin/prepare_promotion.rb ... genesis` (`PromotionPlan.build_genesis`) |
| Every `self_build_equivalent: true` is eligible today, since nothing carries over from a predecessor | `PromotionPlan.build_genesis`: `PackagePolicy.require_eligible_flags!(candidate, previous: nil)` |
| Exact `candidate-sha256` and `change-sha256`, and `live-sha256` set to the literal `absent` | `PromotionPlan.approve!` in the promote dispatch's inspect job checks all three inputs against the plan. In promote, `bin/check_recovery_receipts.rb` requires every receipt to carry that inspected plan's `change_sha256`, and `Invoke-GemManifestGenesis`, which receives no change digest, rechecks that the local candidate bytes match the inspected `candidate_sha256`, that the inspected live digest is the literal `absent`, and that the production release is still absent |
| Recovery receipts from this run (on aarch64 only `ranged` runs; `current`/`oldest` leave skip markers) | promote: `bin/check_recovery_receipts.rb` |
| A recorded administrator approval for `r4l5-recovery-promotion` in this run, first attempt only | promote: `Verify recorded genesis approval` (`InstallerRelease#approval`), the step before the write; the promote job also binds the environment |
| `genesis-confirm` equals the production tag exactly (case-sensitive) | `Invoke-GemManifestGenesis` |

The environment and approval checks are the same code the installer release uses, so they
share its transient-read retry. An ordinary plan cannot be promoted with `genesis`, and a
genesis plan cannot be promoted without it.

## Operator runbook

Before starting:

- R6d has merged: `v5_25_0` is registered as a startup client and listed in the aarch64
  `soak` scope. Registering it changes the x64 `configuration_sha256` too, so any genesis
  inspect done before R6d must be redone.
- `config/gem-lifecycle.json` holds no lifecycle unit transition or range
  ([ordering constraint](#lifecycle-ordering-constraint)).
- The `r4l5-recovery-promotion` environment exists with explicit administrator users as
  reviewers. It is shared with the installer release flow; it allows self-review, so the
  administrator who dispatches genesis may also approve it.
- Immutable releases stay disabled for the repository: ordinary promotions overwrite the
  production manifest in place, and genesis failure cleanup deletes the release and tag.

Steps:

1. **Publish.** Dispatch `ruby4-bundled-gems-suite.yml` with `platform=aarch64-mingw-ucrt`,
   `genesis=true`, `publish=true`, `accepted-candidate-tag` blank and `lich5-commit` set to
   the Lich 5.25.0 commit. Note the candidate tag it publishes
   (`R4L5-gem-bundle-aarch64-mingw-ucrt-candidate-<run>-<attempt>`).
2. **Inspect.** Dispatch `promote-gem-candidate.yml` with `mode=inspect`,
   `platform=aarch64-mingw-ucrt`, `genesis=true` and that `candidate-tag`. The run inspects,
   then runs `recover`: only `ranged` recovers on `windows-11-arm`; `current` and `oldest`
   leave skip markers. Read `promotion-plan.json` in the step summary and record
   `candidate_sha256` and `change_sha256`; `live_sha256` must be `absent`. Before step 3,
   also record the x64 production manifest's digest for step 5:
   `gh release view R4L5-gem-bundle-x64-mingw-ucrt --repo elanthia-online/Ruby4Lich5 --json assets --jq '.assets[] | select(.name == "R4L5-gem-manifest.json") | .digest'`
   prints one `sha256:...` value.
3. **Promote.** Dispatch `promote-gem-candidate.yml` with `mode=promote`,
   `platform=aarch64-mingw-ucrt`, `genesis=true`, the same `candidate-tag`,
   `candidate-sha256` and `change-sha256` from step 2, `live-sha256=absent` and
   `genesis-confirm=R4L5-gem-bundle-aarch64-mingw-ucrt`. Inspect and recover run again;
   approve the `r4l5-recovery-promotion` deployment when the promote job waits. Do not
   re-run any failed job of a genesis dispatch (a recover leg as well as promote): a re-run
   runs promote again as run attempt 2, which the approval check refuses because it accepts
   only the first attempt. Follow [Failure recovery](#failure-recovery) to verify the
   outcome and determine whether a fresh dispatch is needed.
4. **Read back.** The promote job reads the manifest back through the consumer URL. Confirm
   independently that both of these equal the approved `candidate_sha256`:
   - the release asset digest:
     `gh release view R4L5-gem-bundle-aarch64-mingw-ucrt --repo elanthia-online/Ruby4Lich5 --json assets --jq '.assets[] | select(.name == "R4L5-gem-manifest.json") | .digest'`
     prints exactly one `sha256:...` value;
   - the public download:
     `curl -fsSL -o aarch64-manifest.json https://github.com/elanthia-online/Ruby4Lich5/releases/download/R4L5-gem-bundle-aarch64-mingw-ucrt/R4L5-gem-manifest.json && sha256sum aarch64-manifest.json`
     prints the same hex digest, without the `sha256:` prefix. A failed download prints no
     hash.
5. **Confirm x64 is untouched.** Run the step 2 x64 command again; it prints the same digest
   you recorded before step 3.

From then on the platform uses the ordinary path (`genesis=false`), with the new production
release as its predecessor. R7 then starts with `LICH_GEM_MANIFEST_URL` on Lich 5.25.0.

### After genesis

- **Retention.** Every GitHub-hosted aarch64 unit downloads from the genesis candidate
  prerelease, so deleting it breaks every aarch64 install. The retention rule in
  [RELEASING.md](RELEASING.md#rules) reads every platform's live manifest; follow it before
  pruning any candidate release.

- **Checked-in copy.** Open the step 9 sync PR from [RELEASING.md](RELEASING.md#9-sync-the-checked-in-manifest)
  for the new platform, adding `manifest/<platform>/R4L5-gem-manifest.json` as a byte-for-byte
  copy of the live manifest. The aarch64 genesis copy is
  `sha256:a19e327bf970a96c348f18579684ede81f4a7c67704579662ba899c24e88d865`. Every later
  promotion of the platform syncs the same file.

## Failure recovery

First find where the failed dispatch stopped:

- **Before the release was created.** Inspect or a recover leg failed (promote is then
  skipped, because it `needs: [inspect, recover]`), the `r4l5-recovery-promotion`
  deployment was rejected, or the promote step failed one of its checks before the write,
  such as a `genesis-confirm` mismatch or changed local bytes. Nothing was created. Fix the
  cause and start again at step 2, which records fresh hashes: a step 3 dispatch reuses
  step 2's hashes, and its own inspect refuses them if anything they cover changed (for
  example "published clients changed after inspection"). Start at step 1 instead if the
  fix needs a new candidate.
- **"Genesis refused: ... already exists (release | draft | tag)".** Something named
  `R4L5-gem-bundle-aarch64-mingw-ucrt` already exists, usually left by an earlier attempt.
  The step 1 publish run and the step 2 and 3 promotion runs all apply this check. Inspect
  it and act on what exists as described under "creation failed or its outcome is unknown"
  below.
- **At or after `gh release create`.** The promote step reports one of the cases below.

Genesis creates the production release with the manifest attached in one
`gh release create <tag> R4L5-gem-manifest.json ...` call. With an asset, gh creates a
draft, uploads the asset, then publishes; these are separate API requests, not one atomic
operation. The promote step reports which case it hit:

- **"creation failed or its outcome is unknown".** gh returned an error. This run deleted
  nothing, because it cannot prove it created anything; gh itself may have deleted its own
  draft. When the upload or the publish fails, gh deletes the draft it created
  (`cleanupDraftRelease` in gh's `pkg/cmd/release/create/create.go`, lines 500-566 at
  v2.103.3). Deleting a release does not delete its tag, so a publish that created the tag
  but returned an error, followed by that cleanup, leaves a bare tag; if the cleanup itself
  fails, the draft remains. Any of these may exist:
  - a published release, with or without the manifest;
  - a draft release;
  - a bare tag with no release.

  Inspect before retrying, with a token that can see drafts (a repository administrator's
  `gh` login; the workflow's read token cannot list them):
  `gh api repos/elanthia-online/Ruby4Lich5/releases/tags/R4L5-gem-bundle-aarch64-mingw-ucrt`
  (published release),
  `gh api --paginate 'repos/elanthia-online/Ruby4Lich5/releases?per_page=100' --jq '.[] | select(.tag_name == "R4L5-gem-bundle-aarch64-mingw-ucrt") | {id, draft}'`
  (drafts and their ids) and
  `gh api repos/elanthia-online/Ruby4Lich5/git/ref/tags/R4L5-gem-bundle-aarch64-mingw-ucrt`
  (the tag). What to do depends on what exists:

  - **A published release holding the approved manifest.** The create succeeded and only
    its response was lost. Keep it: do not delete it, and do not retry genesis, whose
    absence gate refuses an existing release. Complete the runbook from step 4: both
    step 4 commands must print the approved `candidate_sha256`, then do step 5. Remove the
    release (below) only if a command prints a different digest, or the release has no
    `R4L5-gem-manifest.json` asset. A non-zero exit, an error message, or an empty or
    `null` digest (GitHub can take a moment to compute one after upload) proves nothing:
    rerun the command.
  - **Anything else.** Remove whatever exists, then confirm that the three inspection
    commands above all answer HTTP 404 (or, for the listing, print nothing) before starting
    again: at step 1 if the refusal came from the publish run, which published no
    candidate, otherwise at step 2. Until all of them are removed, both a genesis retry and
    ordinary promotion refuse.

  Removal commands:
  - published release (and its tag):
    `gh release delete R4L5-gem-bundle-aarch64-mingw-ucrt --repo elanthia-online/Ruby4Lich5 --yes --cleanup-tag`;
  - draft, by the id the listing printed (a draft has no git tag, so
    `gh release delete --cleanup-tag` would delete the draft and then fail on the tag):
    `gh api -X DELETE repos/elanthia-online/Ruby4Lich5/releases/<id>`;
  - bare tag (left after a draft is deleted, or with no release at all):
    `gh api -X DELETE repos/elanthia-online/Ruby4Lich5/git/refs/tags/R4L5-gem-bundle-aarch64-mingw-ucrt`.
- **"the created ... was deleted and its absence verified".** The release was created but
  the readback did not match; the run deleted it and proved the name absent. Start again
  at step 2.
- **"removal of the created ... is unconfirmed".** The readback did not match and cleanup
  could not be confirmed. Inspect and act on what exists as under "creation failed or its
  outcome is unknown".

A cancelled promote job can stop between those requests and leave the same states; treat it
like "creation failed or its outcome is unknown".

## Open verification

- **Empty `environment:` on ordinary promotes: settled.** The promote job's
  `environment: ${{ inputs.genesis && 'r4l5-recovery-promotion' || '' }}` means no
  environment when `genesis` is false. The x64 `mode=promote` run 44227967048 ran its promote
  job with no environment and no approval wait: its pending deployments stayed empty. That
  is the same job `installer-release.cjs` dispatches with `mode=promote` and no `genesis`
  input, so it settles the coordinator's case too.
- **Token reads.** The environment and approval steps use the default `GITHUB_TOKEN` (the
  jobs grant `actions: read`). The first genesis inspect shows whether it can read the
  environment's reviewers; the promote run shows whether it can read the run's approvals.
  Either failure stops before any write.
