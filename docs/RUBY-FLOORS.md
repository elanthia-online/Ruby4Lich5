# RubyInstaller gem floors

Deployed Lich (5.24.0 and later) refuses to start when a gem that RubyInstaller ships, and that Lich's
Gemfile declares, is older than the version the accepted manifest's `contract.ruby_inventory.gems` lists
for it. Lich cannot repair those gems: they belong to the Ruby installation.

## What the contract publishes

- **`ruby_inventory`**: the floors. Its gems are the capture of the oldest RubyInstaller Lich accepts,
  the RubyInstaller release of lich-5's `REQUIRED_RUBY`. Its `ruby_version`, `ruby_abi` and `platform`
  remain the build installer's, so lich-5's installer-version check still holds.
- **`measured_ruby_inventory`**: the build installer's exact capture, as provenance. Every gem in it must
  be at or above its floor, and the two must name the same gems.

A contract built before this change carries only the exact capture as `ruby_inventory`. Those floors
followed whichever RubyInstaller patch built the bundle, so a bundle built on 4.0.9-1 stopped users on
older 4.0.x patches with "installed RubyInstaller gem openssl does not satisfy its inventory floor".

## The baseline

`config/ruby-floor-baseline.json` holds one entry per platform: the baseline RubyInstaller version, the
SHA-256 of its `.7z` archive as published on the GitHub release asset, and its gems. Today both
`x64-mingw-ucrt` and `aarch64-mingw-ucrt` are RubyInstaller **4.0.0-1** (`REQUIRED_RUBY = '4.0'`), and
both ship the same 85 gems. The floors that differ from the 4.0.9-1 capture for gems Lich declares are
openssl 4.0.0, resolv 0.7.0 and zlib 3.2.2.

The entry is derived from the official archive, never written by hand:

```
ruby bin/derive_ruby_floor_baseline.rb <platform> <installer version> <archive.7z> <sha256>
```

The script refuses an archive whose SHA-256 differs, extracts only the gemspec directories, and builds the
inventory the same way `bin/capture_ruby_inventory.rb` does on a running install.

## Gates

- **Contract build** (`RuntimeContract`): the baseline's Ruby must equal the `REQUIRED_RUBY` in the
  candidate lich-5 source's `lib/version.rb`, and the measured capture must be at or above the floors.
  Resolution, planning and `windows_contract_sha256` all use the floors.
- **Lock and smoke** (`RuntimeContract.validate!`, `RubyInventory.verify_contract!`): the clean target
  RubyInstaller must equal the measured capture exactly, and the measured capture must stay at or above the
  floors.
- **Manifest generation** (`bin/generate_gem_manifest.rb`): a candidate must publish exactly the reviewed
  baseline's gems as floors.
- **Served-version gate** (`SupportedStartupPolicy.verify!`): every supported client's startup checker runs
  against the floors and again against the measured gems.

## Raising a floor

Raising a floor is one reviewed change in two repositories: lich-5 raises `REQUIRED_RUBY`, and this
repository moves the baseline entry to that Ruby's RubyInstaller release. A contract build fails until both
agree. Recommending a newer Ruby without requiring it (lich-5's `RECOMMENDED_RUBY`) needs no change here.
