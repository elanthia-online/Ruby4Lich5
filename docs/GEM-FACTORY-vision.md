# Lich Gem Factory & Gems Server — Design Discussion

Status: planning (2026-06-15). Captures the discussion that follows the Ruby4Lich5
prototype, so we build once rather than re-touch. Decisions marked **[OPEN]** are
deliberately deferred ("sleep on it").

> Preserved as the original historical snapshot. Every **[OPEN]** item below was resolved
> (2026-07); the maintainer's decision record, kept outside this repository, has the detail.

## What the prototype proved (foundation we build on)

The Ruby4Lich5 / lich5-gtk3-gems work validated six load-bearing assumptions:

1. We can patch a problematic upstream gem we don't own (the glib2 GC/property patch).
2. We can compile binary (native) gems and distribute them.
3. We can build an installer that does the work on the user's machine — *and learned
   it was the wrong call* (slow, two-app, freeze). Replaced by the **baked** model.
4. We don't have to ship MSYS2 / build tools for the runtime to work (binary gems
   vendor their own DLLs; non-DevKit Ruby is enough).
5. We can bifurcate **consumer** vs **power-user/developer** and serve both (opt-in RIDK).
6. We can produce either a Lich-bundled installer or a standalone one.

The compile → DLL-vendor → smoke **engine** exists. What's missing is the **front
door** (specify a gem → classify → build → publish) and the **gems server** (a
non-RubyGems home for our `--local`-installable gems).

## Target architecture (three components)

```
  ┌─────────────────┐     ┌──────────────────────┐     ┌────────────────────────┐
  │  FRONT DOOR      │     │   GEMS SERVER        │     │  INSTALLER ASSEMBLY    │
  │  (per-gem CI)    │ ──▶ │   (repo: released    │ ──▶ │  (periodic snapshot)   │
  │  name a gem →    │     │    gems + index)     │     │  current set + Ruby +  │
  │  fetch RubyGems→ │     │   --local source for │     │  Lich → installer      │
  │  classify→build→ │     │   the Lich ecosystem │     │                        │
  │  publish         │     │                      │     │                        │
  └─────────────────┘     └──────────────────────┘     └────────────────────────┘
        on demand               accumulating                 periodic
```

- **Front door (per-gem, on-demand):** dispatch with a gem name (+ version). Fetch from
  RubyGems, **classify** (pure / native-self-contained / native-needs-system-lib),
  build the binary gem (or pass through pure), resolve + build its **closure**, smoke,
  and publish to the gems server. This is the evolution of today's fixed monolithic
  GTK build into a general "build any named gem" pipeline.
- **Gems server (the repo):** holds the released gems + a manifest/index of the
  **curated set** (names × versions × ABI × platform). Non-central, ours.
- **Installer assembly (periodic):** gathers the *current* curated set + Ruby +
  Lich files and builds the installer. Separate from the front door — this is the
  bifurcation: build-a-gem vs assemble-the-installer.

## Open design decisions (sleep-on-it)

- **[OPEN] Gems-server flavor:**
  - **(a) Release-asset store** — gems as Release assets + a curated manifest;
    consumers download + `gem install --local`. Fewest moving parts; generalizes the
    bundle-release already proven.
  - **(b) Static gem index** — generate a RubyGems-compatible compact index
    (`/versions`, `/info/<name>`, the `.gem`s) on GitHub Pages, so
    `gem install <name> --source <url>` works and Lich treats it as a first-class
    **source**. The "real, less-central gem server."
  - **(both)** — publish assets *and* regenerate a static index from them.
  - *Depends on:* what the existing Lich loader contract assumes (download-then-local
    vs a gem source). Confirm before locking.
- **[OPEN] Index schema = Ruby ABI × platform matrix** (ruby400/410… × x64-mingw-ucrt…).
  Must be designed before first publish to avoid a rebuild at 4.1.x.
- **[OPEN] Final repo topology / home.** lich5-gtk3-gems is explicitly temporary;
  the gems-server repo's permanent home (Lich5 vs elanthia-online org) decides
  cross-repo auth (build the plumbing once).
- **[OPEN] Curation policy.** How a gem/version is pinned, when it's rebuilt (CVE,
  upstream bump), and who approves. Lives as a curation manifest in the server repo.
- **[OPEN] Provenance.** Checksums now; code/gem signing later. We're the trust root
  once we leave RubyGems.

## Hard parts (don't under-scope these)

- **Closure completeness** — curating one gem = building its whole dep tree; the index
  must be self-sufficient for offline `--local`.
- **Tri-state classification** — the native-needs-system-lib case (a gem linking a lib
  that isn't vendorable like the GTK DLLs) is the one that breaks the "just build it"
  assumption. Detect and route/reject loudly.
- **ABI/platform matrix** — every native gem is rebuilt per Ruby ABI; the server and
  the front door are matrix-aware from day one.

## Bifurcation model

- **Consumer:** baked, non-DevKit installer. Fast file-copy, single app, no build tools.
- **Power user / developer:** opt-in RIDK (MSYS2 + toolchain) as a deliberate,
  visible, non-blocking post-install action (per RubyInstaller's own pattern).
