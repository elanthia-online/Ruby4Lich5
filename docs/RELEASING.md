# Releasing a Ruby4Lich5 installer

Operator runbook for the `Release Ruby4Lich5 installer` workflow
(`.github/workflows/release-installer.yml`). Only repository administrators can run it.

One run of the workflow does the whole release: build and inspect a gem candidate, pause for
an administrator to approve recovery promotion, promote it, build the installer draft, pause
for an administrator to confirm a real Windows install, then publish the draft as Latest.
The same administrator may give both approvals.

This runbook is not final. The coordinator is not yet ready for production use, and the
sections below are completed in the order the underlying changes land.

## 1. One-time setup

The one-time setup is being changed. There is no appropriate documentation to review here;
the setup steps will be filed with the change that introduces them.

## 2. Cutting a release

Pending finalization after section 1 is introduced, as committed in issue #53.

## 3. If a run fails

Pending finalization after section 1 is introduced, as committed in issue #53.

## 4. Choosing the installer version

Pending finalization after section 1 is introduced, as committed in issue #53.
