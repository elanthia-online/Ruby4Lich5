# Releasing a Ruby4Lich5 installer

Operator runbook for Ruby4Lich5 installer releases. Only repository administrators can run
these workflows.

**Today, releases are cut by hand.** The `Release Ruby4Lich5 installer` coordinator
(`release-installer.yml`, sections 1 to 4 below) cannot run yet: its token-free dispatch
design is pending in issue #53. Until it can, an administrator dispatches the child workflows
one at a time, as described in
[Manual release (until the coordinator runs, #53)](#manual-release-until-the-coordinator-runs-53).
Every installer release so far was cut this way. The model runs are R4L5-v040.004.007 and
R4L5-v040.005.008, recorded in issue #62.

Related documents:

- [`PLATFORM-GENESIS.md`](PLATFORM-GENESIS.md): a new platform's first gem manifest. It is not
  cut here. After genesis, the platform follows the ordinary promotion flow below.
- [`ACCEPTED-PACKAGE-REUSE.md`](ACCEPTED-PACKAGE-REUSE.md): what `accepted-candidate-tag`
  reuses and what forces a rebuild.
- [`PACKAGE-POLICY.md`](PACKAGE-POLICY.md): the `minimum` and `self_build_equivalent`
  package keys, which appear in the inspected plan as `package_policy_changes`.
- [`RUBY-FLOORS.md`](RUBY-FLOORS.md): the RubyInstaller gem floors, and the baseline
  RubyInstaller the older-Ruby check installs.

## Manual release (until the coordinator runs, #53)

The sequence is: build a candidate, inspect it, check it on an older RubyInstaller, promote
it, propose a version, build the installer draft, accept the installer, publish it, then sync
the checked-in manifest and clear lich-5 CI. Each step names what to record. Keep those values
in one place, such as a draft of the issue comment from
[After the release](#after-the-release).

The commands assume:

```sh
R=elanthia-online/Ruby4Lich5
```

Every `gh workflow run` uses `--ref main`. Every workflow dispatched here refuses other
events, and non-administrator dispatch and rerun actors, through
`.github/actions/require-admin-dispatch`. The two release checks, both promote-workflow jobs
that use that guard (`inspect` and `promote`) and the installer's `draft_release` job also
refuse any branch but the default branch. The factory and the installer build do not: a
factory run from another branch still publishes a candidate, and an installer build from one
builds but assembles no draft. Never use another branch for a release. A dispatch command
prints the run URL;
its number is the run id. If it does not, find the id with
`gh run list --repo $R --workflow <file> --event workflow_dispatch --limit 3`.

### Before you start

- **lich-5 commit.** The factory accepts only a lich-5 commit whose contract files equal the
  copies reviewed under `vendor/lich5/`: the reader, recovery, range policy and archive reader
  (`Ruby4Lich5::RuntimeContract`). Use the vendored pin:
  `git show origin/main:vendor/lich5/contract-source.json | jq -r .commit`. Record it as
  `LICH5`.
- **Accepted candidate to reuse (optional).** Reuse needs the candidate whose manifest is
  live now; any other tag fails with "Reuse requires the currently accepted candidate."
  Latest's `installer-provenance.json` names it in `gem_candidate_tag`, if Latest was built
  after the last promotion:
  `gh release download --repo $R -p installer-provenance.json -O - | jq -r .gem_candidate_tag`.
  Confirm it by comparing two digests, which must be equal:
  `gh release view <tag> --repo $R --json assets --jq '.assets[] | select(.name == "R4L5-gem-manifest.json") | .digest'`
  and the same command for `R4L5-gem-bundle-x64-mingw-ucrt`. Leave reuse blank for a full
  build, which you need after changing the build code (see
  [Consequences](ACCEPTED-PACKAGE-REUSE.md#consequences)). Record it as `ACCEPTED`.
- **lich-5 releases.** Promotion requires every published lich-5 release that ships
  `lib/accepted_gem_policy.rb` to be registered as a supported startup client. Registration
  means an entry in `config/supported-startup-clients.json` plus the release's files under
  `vendor/lich5/supported-startup-clients/<tag>/`, as PR #67 did for v5.24.2 in commit
  `7f837b7`. The retention check (`lib/ruby4lich5/published_startup_releases.rb`) counts
  every published, non-draft release, prereleases included. Register any new release on main
  before step 2. Agree with lich-5 maintainers that no such release is published between
  step 2 and step 4.
- **Time.** Steps 4 to 8 open a window in which lich-5 CI fails (see step 10). Start step 4
  only when you can carry the release through publish.

### 1. Build and publish a gem candidate

```sh
gh workflow run ruby4-bundled-gems-suite.yml --repo $R --ref main \
  -f publish=true -f lich5-commit=$LICH5 -f accepted-candidate-tag=$ACCEPTED
```

Omit `-f accepted-candidate-tag=...` for a full build. Leave every other input at its
default: `platform` is `x64-mingw-ucrt`, and `version-overrides` is diagnostic and always
unpromotable.

- **Record:** the factory run id, and the candidate tag
  `R4L5-gem-bundle-x64-mingw-ucrt-candidate-<run id>-<attempt>`. The step summary's
  `Candidate:` line prints the tag. Record it as `CANDIDATE`.
- **Pass:** the run succeeds, and
  `gh release view $CANDIDATE --repo $R --json isDraft,targetCommitish` shows
  `"isDraft": false`.
- **On failure:** nothing in production changed. The publish job writes only the new
  candidate release. Fix the cause, then start a fresh dispatch rather than re-running the
  old one. Common refusals:
  - "selected lich-5 ... differs from the reviewed ..." means the lich-5 commit is not the
    vendored pin.
  - "Reuse requires the currently accepted candidate." means `ACCEPTED` is not the live
    candidate.

### 2. Inspect the candidate

```sh
gh workflow run promote-gem-candidate.yml --repo $R --ref main \
  -f mode=inspect -f candidate-tag=$CANDIDATE
```

- **Record:** the inspect run id, and the three hashes from `promotion-plan.json`. The plan is
  in the step summary and in the `gem-promotion-preparation` artifact:

  ```sh
  gh run download $INSPECT_RUN --repo $R -n gem-promotion-preparation -D inspect-$INSPECT_RUN
  jq '{candidate_tag, candidate_sha256, live_sha256, change_sha256, source_sha}' inspect-$INSPECT_RUN/promotion-plan.json
  ```

  Also record `package_policy_changes`, and the packages whose bytes change. These show
  whether step 3 is required:

  ```sh
  jq -r '.changes[] | ([.before[] | .id as $u | .packages[]? | "\($u) \(.name) \(.sha256)"]) as $b
    | ([.after[] | .id as $u | .packages[]? | "\($u) \(.name) \(.sha256)"]) as $a | ($a - $b)[]' \
    inspect-$INSPECT_RUN/promotion-plan.json
  ```

- **Pass:** `inspect` and all three `recover` legs succeed: `current`, `oldest` and
  `ranged`. `live_sha256` equals the live manifest's current digest. The changes are the ones
  you meant to ship.
- **On failure:** inspect mode has no write job, so nothing changed. Fix the cause, then
  inspect again. If the candidate itself must change, start again at step 1. A refusal such
  as "Range consumer must already have a published release" names the missing
  prerequisite.

### 3. Older-RubyInstaller load check

Run this check if step 2 lists any changed `gtk3-runtime` member, or if the Ruby floors
changed ([`RUBY-FLOORS.md`](RUBY-FLOORS.md)). Both releases so far ran it: F3 for the floors,
and 040.005.008 for seven rebuilt GTK members. It is read-only, so run it whenever you are
unsure.

```sh
gh workflow run release-check-older-ruby.yml --repo $R --ref main \
  -f candidate-tag=$CANDIDATE -f candidate-sha256=<candidate_sha256>
```

`lich5-commit` is optional. Blank starts the candidate contract's `lich5_commit`.

The workflow first downloads the candidate manifest and refuses it unless it matches
`candidate-sha256`. It then installs the baseline RubyInstaller from
`config/ruby-floor-baseline.json` (4.0.0-1 today), verified against the baseline's archive
SHA-256. Lich's real startup gem check runs against the candidate: recovery installs the
bundle through its detached helper and relaunches Lich. The relaunched process must load
every unit (`.github/scripts/lich_startup_probe.rb`).

- **Record:** the run id.
- **Pass:** the run succeeds, and its summary ends with "Lich started on Ruby 4.0.0 (openssl
  ...) with every unit loaded". The control step prints what the startup policy needs from
  the live manifest and from the candidate, for information only. On a clean install both
  usually list every package. When a floor is the point of the release, as with F3, the
  live-manifest line shows the floor refusal and the candidate line does not.
- **On failure:** do not promote. The probe step prints every `run-*.json` marker and the
  Lich logs. Re-running this check is safe. If the candidate is at fault, fix it and start
  again at step 1.

### 4. Promote

Use the exact three hashes recorded in step 2:

```sh
gh workflow run promote-gem-candidate.yml --repo $R --ref main \
  -f mode=promote -f candidate-tag=$CANDIDATE \
  -f candidate-sha256=<candidate_sha256> -f live-sha256=<live_sha256> -f change-sha256=<change_sha256>
```

The run repeats `inspect` and all three `recover` legs. The `promote` job then checks the
recovery receipts, rechecks the published lich-5 clients and the candidate release, and
uploads the candidate manifest over the live one. It reads the result back through the
consumer URL, and restores the approved rollback if the readback fails. An ordinary promote
binds no environment and waits for no approval; run 44227967048 confirmed this. Only genesis
waits for `r4l5-recovery-promotion`.

- **Record:** the promote run id. The new live digest equals `candidate_sha256`.
- **Pass:** the run succeeds, and the summary says "Promotion verified through the consumer
  URL". Confirm independently that both of these print `candidate_sha256` (`sha256sum` prints
  it without the `sha256:` prefix):

  ```sh
  gh release view R4L5-gem-bundle-x64-mingw-ucrt --repo $R --json assets \
    --jq '.assets[] | select(.name == "R4L5-gem-manifest.json") | .digest'
  curl -fsSL https://github.com/$R/releases/download/R4L5-gem-bundle-x64-mingw-ucrt/R4L5-gem-manifest.json | sha256sum
  ```

  The release's `R4L5-gem-bundle-x64-mingw-ucrt.zip` asset is unchanged. Promotion uploads
  only the manifest.
- **On failure:** **never re-run the failed run or any of its jobs.** The ordinary path has no
  run-attempt guard (only genesis checks the attempt), so nothing in the code stops a re-run
  from repeating a write against state that has moved. Read the promote step's error:
  - **"published clients changed after inspection"**: a lich-5 release was published or
    changed after step 2. Register it if it ships `lib/accepted_gem_policy.rb` (see
    [Before you start](#before-you-start)), then inspect again (step 2) and promote with the
    new hashes. Nothing was uploaded.
  - **"Live predecessor changed after approval; nothing uploaded."**: go back to step 2.
  - **"... approved rollback sha256:... is live and verified ..."**: the upload or readback
    failed and production holds the approved rollback. Go back to step 2 for fresh hashes.
    The rollback can differ from the old live bytes, because the lifecycle policy may rewrite
    it (`rollback_sha256` in the plan), and only a new inspect reads the current state.
  - **"... restoration is unconfirmed ..."**: stop. Read the live digest with the first
    command above. The run's `gem-promotion-result` artifact holds the rollback bytes at
    `rollback/R4L5-gem-manifest.json` and the candidate bytes at
    `candidate/R4L5-gem-manifest.json`. Restore production by hand with
    `gh release upload R4L5-gem-bundle-x64-mingw-ucrt <file> --repo $R --clobber`, using
    only the rollback manifest file, and read it back. Never delete or replace the bundle ZIP.
  - **A failure in `inspect` or `recover`**: `promote` did not run, so nothing changed.
    Dispatch a fresh promote with the same hashes. If its inspect refuses them, go back to
    step 2.

### 5. Propose the installer version, after promote

`propose-installer-version.yaml` runs only on `pull_request`, so it cannot be dispatched. You
must re-run an existing run of it **after step 4**. A proposal from before the promote compares
against the old live manifest. It then misses the Gems bump: F3 shipped as 040.004.007 that way.

The proposal compares Latest's `installer-provenance.json` with two things:

- **Gems field:** the live manifest and its runtime contract. Any PR's run gives the right
  answer once step 4 is done.
- **CI field:** that PR's **head commit**, not main. It is bumped if Latest's
  `ruby_installer_version` differs from `config/target-ruby.json`, or if an installer input
  changed between Latest's `installer_source_sha` and that head. The inputs are the files in
  the workflow's `paths:` list, minus the workflow itself.

Pick a run whose PR head contains every installer-input change on the main commit you will
build, usually the most recent merged PR that touched those files. On 2026-11-18 that was
PR #85's run 44212856298. To check, list what changed between Latest's source and main:

```sh
gh release download --repo $R -p installer-provenance.json -O - | jq -r .installer_source_sha
gh api "repos/$R/compare/<installer_source_sha>...main" --jq '[.files[].filename]'
gh run list --repo $R --workflow propose-installer-version.yaml --limit 10 \
  --json databaseId,headBranch,headSha,displayTitle,createdAt
gh run rerun <proposer run id> --repo $R
```

Both the original actor and the rerun actor must be administrators; otherwise the run logs
"Version proposal skipped". The re-run rewrites the `<!-- r4l5-version-proposal -->` comment
on the PR it ran for. Read it with:

```sh
gh api "repos/$R/issues/<PR>/comments?per_page=100" \
  --jq '.[] | select(.body | contains("r4l5-version-proposal")) | .body'
```

- **Record:** the proposed version `NNN.NNN.NNN` as `VERSION`, and the proposer run id.
- **Pass:** the comment names `R4L5-v<VERSION>` with its reasons. If step 4 changed the
  manifest, the Gems field is bumped.
- **On failure:** "Version proposal unavailable: ..." covers transient API failures and
  missing provenance. Re-run the run once more. If it is still unavailable, apply the same
  rules by hand. The fields are Ruby, Gems and CI:
  - **Ruby:** `ruby_abi` from `config/target-ruby.json`, without the dot and padded to three
    digits (`040`).
  - **Gems:** add 1 if the live manifest digest or its contract digest differs from Latest's
    `recovery_manifest_sha256` or `runtime_contract_sha256`.
  - **CI:** add 1 under the rule above.

  Never reuse a published version.

### 6. Build the installer draft

```sh
gh workflow run build-ruby4lich5-installer.yaml --repo $R --ref main \
  -f gem-source=accepted-candidate -f gem-candidate-tag=$CANDIDATE -f installer-version=$VERSION
```

- **Record:** the build run id as `BUILD_RUN`, and the receipt:

  ```sh
  gh run download $BUILD_RUN --repo $R -n installer-release-receipt -D build-$BUILD_RUN
  jq . build-$BUILD_RUN/installer-release-receipt.json
  ```

  From the receipt, record `release_id`, `tag`, `source_sha`, `assets` and
  `recovery_manifest_sha256`. The draft's `url` reads `.../releases/tag/untagged-...`: a
  draft has no git tag until it is published.
- **Pass:** all three jobs succeed: `preflight_version`, `build_installer` and
  `draft_release`. `recovery_manifest_sha256` equals `candidate_sha256` without its prefix,
  and `source_sha` is the main commit you dispatched.
- **On failure:**
  - **"Installer version already exists; inspect it and choose a new version"**, **"Installer
    version belongs to another build"** or **"Draft ownership is missing or belongs to another
    build"**: an unpublished draft is tied to the build run that created it, through its
    `Source:` and `Build run:` body lines and its provenance. Only a re-run of that same build
    run can resume it. A fresh dispatch of that version is refused, even from the same
    commit. To rebuild the same version, for example from a newer main, find the draft and
    delete it by id:

    ```sh
    gh api --paginate "repos/$R/releases?per_page=100" \
      --jq '.[] | select(.tag_name == "R4L5-v'"$VERSION"'") | {id, draft, target_commitish}'
    gh api -X DELETE repos/$R/releases/<id>
    ```

    Delete only a release whose `draft` is `true`. A draft has no git tag, so
    `gh release delete --cleanup-tag` would fail on the tag. If the version is already
    published, choose a new version instead.
  - **"Accepted recovery changed; inspect and rebuild before release"**: the live manifest
    moved since the build read it. Find out why before you continue.
  - Other failures in `build_installer` or `draft_release` may be re-run on the same run
    (`gh run rerun $BUILD_RUN --repo $R --failed`), because a re-run keeps its run id and
    so still owns its draft.

### 7. Installer acceptance

```sh
gh workflow run release-check-installer-acceptance.yml --repo $R --ref main \
  -f installer-run-id=$BUILD_RUN \
  -f installer-sha256=<receipt assets["Ruby4Lich5.exe"]> \
  -f lich5-refs=main
```

The `plan` job runs four checks:

- the run is a successful default-branch dispatch of `build-ruby4lich5-installer.yaml`;
- the `ruby4lich5-installer` artifact's `Ruby4Lich5.exe` hashes to `installer-sha256`;
- that hash agrees with `installer-provenance.json`;
- `installer-provenance.json` and `resolution-lock.json` name the same `lich5_commit`.

The job then lists the legs:

- `installed`: the Lich the installer itself fetched, which is the latest published lich-5
  release;
- `pinned`: the installer contract's `lich5_commit`;
- each ref in `lich5-refs`: space-separated branches, tags or full SHAs. The default is
  `main`. Pass `-f lich5-refs=` for none.

Each leg runs on a clean `windows-latest` runner. It drives the real Inno Setup wizard by UI
Automation (`.github/scripts/drive_installer.ps1`), with the full type, the `LichDR` task and
`C:\Ruby4Lich5`. It then starts that Lich on the installed Ruby against the live manifest.

- **Record:** the run id, and the legs table in the summary, which gives each leg's lich-5
  commit. Also record the installed Lich version, which the install step logs.
- **Pass:** `plan` and every leg succeed. Each leg ends with "Lich <leg> (...) started with no
  repair on Ruby <version>". "No repair" means the first start loaded every unit, so only one
  `run-*.json` marker exists.
- **On failure:** do not publish.
  - **The wizard failed or timed out, and the `install.log` tail shows "Failed to download
    Lich"**: `fetch-lich.ps1` got a GitHub API error, such as a 403. Attempt 1 of the
    040.005.008 acceptance hit this, and the wizard hung until the 15-minute timeout. The
    check is read-only, so re-run the failed legs:
    `gh run rerun <run id> --repo $R --failed`.
  - **"installer showed a message box ..."**: the box's text is in the error.
  - **"startup needed a repair ..." or "Lich did not reach the loaded state"**: the baked gems
    do not satisfy the live manifest. Find the cause. Then rebuild: delete the draft by id as
    in step 6 and repeat steps 6 and 7. If the candidate is wrong, start again at step 1.

### 8. Publish as Latest

First check the draft against the receipt from step 6:

```sh
gh api repos/$R/releases/<release_id> \
  --jq '{draft, prerelease, tag_name, target_commitish, assets: (.assets | length)}'
diff <(jq -S .assets build-$BUILD_RUN/installer-release-receipt.json) \
  <(gh api repos/$R/releases/<release_id> --jq '[.assets[] | {(.name): .digest}] | add' | jq -S .) \
  && echo assets match
curl -fsSL https://github.com/$R/releases/download/R4L5-gem-bundle-x64-mingw-ucrt/R4L5-gem-manifest.json | sha256sum
```

Expect:

- `draft` is `true` and `prerelease` is `false`;
- `tag_name` equals the receipt's `tag`, and `target_commitish` equals its `source_sha`;
- there are exactly 4 assets, and the diff prints `assets match`;
- the live manifest still hashes to `recovery_manifest_sha256`.

Then publish:

```sh
gh release edit R4L5-v$VERSION --repo $R --draft=false --latest
```

Read it back without authentication, and check the tag:

```sh
curl -fsSL https://api.github.com/repos/$R/releases/latest | jq '{id, tag_name, draft}'
for f in Ruby4Lich5.exe installer-provenance.json; do
  curl -fsSL "https://github.com/$R/releases/latest/download/$f" | sha256sum
done
gh api repos/$R/commits/R4L5-v$VERSION --jq .sha
```

- **Record:** the time you published, and the readback results.
- **Pass:**
  - `/releases/latest` returns `id` equal to the receipt's `release_id`, with `draft` false;
  - both downloads hash to the receipt's `assets` values;
  - the tag resolves to the receipt's `source_sha`;
  - the asset diff above, run again, still prints `assets match`.
- **On failure:**
  - **The edit returned an error:** read the release by id before you try again; it may
    already be published.
  - **A readback does not match:** hold all release communication. Re-read after a minute,
    because the CDN can lag the API.
  - **Another release became Latest:** run `gh release edit <correct tag> --repo $R --latest`.

### 9. Sync the checked-in manifest

Open a PR that makes `manifest/R4L5-gem-manifest.json` a byte-for-byte copy of the new live
manifest. #78 did this for F3, and #87 for 040.005.008. Use the PR title
`chore(gems): reconcile manifest with the promoted live manifest`:

```sh
curl -fsSL -o manifest/R4L5-gem-manifest.json \
  https://github.com/$R/releases/download/R4L5-gem-bundle-x64-mingw-ucrt/R4L5-gem-manifest.json
sha256sum manifest/R4L5-gem-manifest.json
bundle exec rspec
```

- **Pass:** the hash equals `candidate_sha256`, and the suite passes. Some specs compare
  generated output with the checked-in manifest. #87 had to update one for the new
  `self_build_equivalent` flags.

### 10. Clear lich-5 CI

lich-5's CI job "Windows recovery and installer contract" runs
`.github/scripts/check_r4l5_contract.rb`, and `ci-gate` requires it. The check compares the
Latest installer's provenance with the live manifest. From step 4 until step 8, the two
disagree, so lich-5 CI runs started in that window fail. Once Latest is published:

```sh
L=elanthia-online/lich-5
gh run list --repo $L --workflow ci.yml --branch main --limit 1 --json databaseId,headSha,conclusion
gh run view <main run id> --repo $L --json jobs \
  --jq '.jobs[] | select(.name == "Windows recovery and installer contract") | .databaseId'
gh run rerun <main run id> --repo $L --job <job id>
gh run view <main run id> --repo $L --log | grep "R4L5 contract accepted"
gh run list --repo $L --workflow ci.yml --event pull_request --status failure \
  --created ">=<step 4 date>" --json databaseId,headBranch,displayTitle
gh run rerun <run id> --repo $L --failed
```

- **Pass:** main's log reads "R4L5 contract accepted: <n> locked Windows packages; matching
  installer predecessor", and every PR run that failed in the window passes on re-run.
- **On failure:** if main still fails after the publish, compare the error with steps 4 and
  8. The live manifest and Latest's `installer-provenance.json`
  (`recovery_manifest_sha256`) must agree.

### Rules

- Dispatch only from `main`, with exact SHAs, tags and hashes copied from the recorded
  outputs, never retyped or abbreviated.
- Never re-run a failed promote run or any of its jobs. Find out what is live, then start
  again from inspect (step 4, "On failure").
- Never delete the production bundle ZIP `R4L5-gem-bundle-x64-mingw-ucrt.zip`
  (`sha256:e80213ff...`) on `R4L5-gem-bundle-x64-mingw-ucrt`. Live manifest units still
  download it. Likewise, keep every candidate release that a live unit's `artifact.url`
  names. Read the live manifest, not the checked-in copy, which lags until step 9 merges:
  `curl -fsSL https://github.com/$R/releases/download/R4L5-gem-bundle-x64-mingw-ucrt/R4L5-gem-manifest.json | jq -r '.targets[].units[].artifact.url' | sort -u`.
- An unpublished installer draft is owned by the build run that created it. To build the same
  version from another run or a newer commit, delete the draft by its release id (step 6).
  Never delete a published release.
- No lich-5 release that ships `lib/accepted_gem_policy.rb` may be published between inspect
  and promote. If one is, promote refuses with "published clients changed after inspection".
  Register the client (supported startup clients), then inspect and promote again. Retention
  counts every published, non-draft lich-5 release, prereleases included
  (`lib/ruby4lich5/published_startup_releases.rb`).
- An ordinary promote binds no environment and waits for no approval (verified on run
  44227967048).
- If the manifest change touches GTK bytes, or the Ruby floors, run the older-Ruby check
  (step 3) before promote.
- Re-run the version proposal after promote, not before (step 5).
- Publish only after acceptance passes and the draft's assets match
  `installer-release-receipt.json` (steps 7 and 8).

### After the release

- [ ] **Manifest sync PR** opened and green (step 9).
- [ ] **lich-5 CI:** main's contract job re-run and reading "R4L5 contract accepted". Every
      lich-5 PR run that failed between promote and publish re-run and green (step 10).
- [ ] **Issue updates:** post a release record on the tracking issue (#62 so far). Use the
      table in the two earlier records: factory, inspect, older-Ruby check, promote,
      installer, acceptance, publish and the lich-5 contract check, each with its run id and
      result. Add what changed in the live manifest, and any follow-ups such as a failed
      acceptance attempt and its cause. Then update or close the issues the release resolves.
- [ ] **Clean-up:** delete any installer draft you abandoned (by id, step 6). Delete any
      throwaway branch used for the release.

## 1. One-time setup

This section covers the `Release Ruby4Lich5 installer` coordinator. The one-time setup is
being changed, so there is nothing to review here yet. The setup steps will be filed with the
change that introduces them.

## 2. Cutting a release

Pending finalization after section 1 is introduced, as committed in issue #53. Until then,
see [Manual release](#manual-release-until-the-coordinator-runs-53).

## 3. If a run fails

Pending finalization after section 1 is introduced, as committed in issue #53.

## 4. Choosing the installer version

Pending finalization after section 1 is introduced, as committed in issue #53. Until then,
see [step 5 of the manual release](#5-propose-the-installer-version-after-promote).
