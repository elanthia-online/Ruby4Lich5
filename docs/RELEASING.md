# Releasing a Ruby4Lich5 installer

Operator runbook for the `Release Ruby4Lich5 installer` workflow
(`.github/workflows/release-installer.yml`). Only repository administrators can run it.
The design rationale lives in `docs/DECISIONS.md` under "Administrator release operation";
this file carries the steps. A reader should be able to follow it on a clean fork without
reading the scripts.

One run of the workflow does the whole release: build and inspect a gem candidate, pause for
an administrator to approve recovery promotion, promote it, build the installer draft, pause
for an administrator to confirm a real Windows install, then publish the draft as Latest.
The same administrator may give both approvals.

## 1. One-time setup

Do these in order, before the first run. The `prepare` job checks both environments and
stops before building anything if they are missing.

1. Dispatch credential (`RELEASE_DISPATCH_TOKEN`).
   NOTE: not ready for production use. A redesign of this credential is pending and
   this step will change. Do not create the token unless you are testing the interim
   design.
   The coordinator starts three other workflows and they accept only an administrator
   as the person starting them, so it uses an administrator's own token; the repository
   secret below is what the workflow reads.
   - GitHub profile menu > Settings > Developer settings > Personal access tokens >
     Fine-grained tokens > Generate new token. Resource owner: `elanthia-online`.
     Repository access: only `Ruby4Lich5`. Repository permissions: Actions read and
     write, Contents read (Metadata read is added automatically). Set an expiry and note
     who rotates it before that date. The organization may have to approve the token
     before it works.
   - The token's owner must be a repository administrator; the built-in Actions token or
     an app installation token is refused.
   - Repository Settings > Secrets and variables > Actions > Secrets > New repository
     secret, name `RELEASE_DISPATCH_TOKEN`. Never put the value in inputs, files or
     records.
   - If the secret is missing or expired, `prepare` fails at "Build and inspect with the
     administrator dispatch credential" before anything is dispatched.
2. Environment `r4l5-recovery-promotion`. Repository Settings > Environments > New
   environment. Enable Required reviewers and add individual administrator users (not
   teams; the coordinator rejects team reviewers). Set Prevent self-review according to
   your operating policy. Under Deployment branches, choose Selected branches and add
   `main`.
3. Environment `r4l5-installer-latest`, configured the same way.
4. If an environment is missing or has no administrator reviewers, the run stops in
   `prepare` with "requires configured administrator reviewers" or "must name
   administrator users explicitly"; fix the environment and start a fresh run.

## 2. Cutting a release

1. Choose the Lich commit: the full 40-character SHA of the reviewed `lich-5` commit that
   owns the dependency contract for this installer.
2. Choose the installer version `NNN.NNN.NNN` (see section 4). Never reuse a version that
   has a published release, a draft, or a tag.
3. Actions > "Release Ruby4Lich5 installer" > Run workflow. Branch: `main`. Fill
   `lich5-commit` and `installer-version`. Click Run workflow. A non-administrator or a
   non-`main` dispatch fails in the first job.
4. Wait. `preflight_version` rejects an occupied version; `prepare` builds the gem
   candidate and inspects it (this can take hours; the job allows six).
5. First approval (recovery promotion). The run page shows a "Review deployments" button
   for `r4l5-recovery-promotion`. Before approving, open the `prepare` job summary
   "Recovery promotion approval" and read the full promotion plan: removed rollback
   units, permanent withdrawals, unused-retirement diagnostics and the linked
   clean-consumer evidence. Approve only the exact plan shown; approval forwards those
   hashes to the normal promotion workflow. It does not publish an installer.
6. Installer draft. After promotion, `promote_and_build` builds the installer and leaves a
   draft release `R4L5-vNNN.NNN.NNN`; its job summary "Installer acceptance required" links
   the draft. Drafts are visible to administrators under Releases.
7. Windows acceptance. Download `Ruby4Lich5.exe` from the draft, install it on a Windows
   machine, confirm the installer fetches the currently published Lich at install time, and
   confirm Lich starts and survives a restart of the machine. Nothing is public yet.
8. Second approval (Latest). Use "Review deployments" for `r4l5-installer-latest` only
   after that acceptance passes. `approve_latest` records the approval; `publish_latest`
   rechecks the approval, the draft identity, every asset byte and the accepted recovery
   manifest, then publishes the exact draft bytes as Latest and verifies the public
   downloads.
9. Done when `publish_latest` reports "Latest verified". The run keeps three artifacts for
   90 days: `release-request`, `approved-installer-draft` and `published-installer-receipt`.

## 3. If a run fails

Do not rerun coordinator jobs; reruns are refused and a rerun never resumes an approval.
Read the failed job, inspect the linked child runs and the current Releases page, fix the
cause, then start a fresh run.

- Before the first approval (`preflight_version` or `prepare`). "Installer version already
  exists": a release, draft or tag with that version exists. Choose a new version, or, if
  the existing draft is a leftover you own, delete it (Releases > the draft > Delete) and
  delete its tag only if the tag was created by that draft. Token or environment errors:
  fix the setup in section 1. Nothing has been promoted; the same version is reusable
  once the collision is gone.
- `main` moved while waiting for the recovery approval. `promote_and_build` fails with
  "Default branch moved; start a fresh release request". Nothing was promoted or drafted.
  Start a fresh run with the same version; the candidate is rebuilt from the new `main`
  and inspected again. Changes to `main` during the Latest wait do not stop publication;
  that stage is bound to the approved draft.
- Promotion succeeded but the installer build or draft failed. Recovery is already
  promoted and is not rolled back automatically. Inspect the child run. If no draft was
  created, a fresh run with the same version is fine; if a draft exists with different
  bytes, choose a new version and delete or keep the old draft deliberately.
- Latest approval rejected or the run cancelled during the wait. The draft stays
  unpublished. Delete it, or keep it and choose a new version for the next attempt; a
  rejected approval cannot be reused.
- `publish_latest` failed. Download `published-installer-receipt` and read
  `publication-status.json`:
  - `not-published`: nothing changed publicly; fix the cause and start a fresh run.
  - `publication-uncertain`: the publish request was sent and no response was recorded.
    Check Releases: if the version is public, treat it as `published-unverified`.
  - `published-unverified`: the release is public but a check after publishing failed.
    Verify by hand: download
    `https://github.com/elanthia-online/Ruby4Lich5/releases/latest/download/Ruby4Lich5.exe`
    and `installer-provenance.json`, and compare their SHA-256 with `assets` in the
    receipt. A readback 404 is not retried by design; if the URL lagged publication,
    note it for the next run.
  - `verified`: the run succeeded; the failure was after verification.
- First live run (commissioning). Two behaviors are checked only on a real run: the
  dispatch response must carry a run ID (otherwise `prepare` stops with "Dispatch returned
  no run ID") and the public Latest download must answer immediately after publishing.
  Record both outcomes on the first run.

## 4. Choosing the installer version

The version is `RRR.GGG.CCC`:

- `RRR` is the target Ruby ABI with the dot removed and padded (Ruby 4.0 is `040`).
- `GGG` counts changes to the accepted gem set: bump it when the accepted recovery manifest
  or the runtime contract differs from the one the last published installer was built
  against.
- `CCC` counts installer input changes: bump it when any of `Ruby4Lich5-installer.iss`,
  `fetch-lich.ps1`, `update-ruby-path.ps1`, `config/target-ruby.json`,
  `bin/record_installer_contract.rb` or
  `.github/workflows/build-ruby4lich5-installer.yaml` changed, or the exact RubyInstaller
  version changed.

The "Proposed next installer version" comment on pull requests applies these rules from the
last published installer's `installer-provenance.json`. The current Latest,
`R4L5-v040.003.005`, predates that provenance, so the proposer reports "unavailable" and the
first release after it is chosen by hand with the same rules: keep `040` while the target
is Ruby 4.0, bump `003` to `004` if the accepted gem set or contract changed since that
release, and bump `005` to `006` because this coordinator's own changes touch an installer
input. Once a provenance-bearing installer is published, use the proposer's value.
