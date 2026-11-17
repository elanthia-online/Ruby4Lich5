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
