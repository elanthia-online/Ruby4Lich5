BeforeAll {
  . "$PSScriptRoot/../../gem-bundle-artifact.ps1"
}

Describe 'Tested gem artifact handoff' {
  BeforeEach {
    $script:BundleDir = Join-Path $TestDrive ([guid]::NewGuid().ToString('N'))
    New-Item -ItemType Directory $script:BundleDir | Out-Null
    $script:Repository = 'elanthia-online/Ruby4Lich5'
    $script:Run = [pscustomobject]@{
      id = 12345
      run_attempt = 1
      head_branch = 'feat/nonpublishing-gem-installer-test'
      repository = [pscustomobject]@{ full_name = $script:Repository }
      head_repository = [pscustomobject]@{ full_name = $script:Repository }
      path = '.github/workflows/ruby4-bundled-gems-suite.yml'
      event = 'workflow_dispatch'
      status = 'completed'
      conclusion = 'success'
      head_sha = 'a' * 40
    }
    # Real files and hashes, with stand-in gem bytes: no network or Ruby needed.
    Set-Content (Join-Path $script:BundleDir 'example-1.0.gem') 'gem one'
    Set-Content (Join-Path $script:BundleDir 'second-2.0-x64-mingw-ucrt.gem') 'gem two'
    $script:GemNames = @('example-1.0.gem', 'second-2.0-x64-mingw-ucrt.gem')
    Set-Content (Join-Path $script:BundleDir 'runtime-gems-install-targets.txt') $script:GemNames
    Set-Content (Join-Path $script:BundleDir 'runtime-gems-manifest.txt') $script:GemNames
    Set-Content (Join-Path $script:BundleDir 'install-runtime-gems.cmd') '@echo off'
    Set-Content (Join-Path $script:BundleDir 'resolution-lock.json') '{}'
    $script:MetadataArgs = @{
      Directory = $script:BundleDir
      Repository = $script:Repository
      RunId = '12345'
      RunAttempt = 1
      SourceSha = $script:Run.head_sha
      RubyInstallerVersion = '4.0.9-1'
      RubyArchiveDigest = 'sha256:' + ('b' * 64)
    }
    $script:ReadArgs = @{
      Directory = $script:BundleDir
      Run = $script:Run
      Repository = $script:Repository
      RunId = '12345'
      RubySeries = '4.0'
    }
    New-GemBundleMetadata @script:MetadataArgs
    $script:MetadataPath = Join-Path $script:BundleDir 'gem-build-metadata.json'
  }

  It 'accepts tested files from a same-repository feature branch and retains the full RubyInstaller revision' {
    $result = Read-VerifiedGemBundle @script:ReadArgs
    $result.ruby_installer_version | Should -Be '4.0.9-1'
    $result.files.Count | Should -Be 6
    $result.files.name | Should -Contain 'resolution-lock.json'
  }

  It 'rejects a source run with <Field> = <Value>' -TestCases @(
    @{ Field = 'id'; Value = 99999 }
    @{ Field = 'path'; Value = '.github/workflows/unrelated.yml' }
    @{ Field = 'event'; Value = 'pull_request' }
    @{ Field = 'status'; Value = 'in_progress' }
    @{ Field = 'conclusion'; Value = 'failure' }
    @{ Field = 'conclusion'; Value = 'cancelled' }
    @{ Field = 'head_sha'; Value = 'invalid' }
    @{ Field = 'run_attempt'; Value = 0 }
  ) {
    param($Field, $Value)
    $script:Run.$Field = $Value
    { Read-VerifiedGemBundle @script:ReadArgs } | Should -Throw '*successful manual gem-suite run*'
  }

  It 'rejects runs belonging to another repository' {
    $script:Run.repository.full_name = 'someone/else'
    { Read-VerifiedGemBundle @script:ReadArgs } | Should -Throw '*this repository*'
  }

  It 'rejects runs whose head repository is a fork' {
    $script:Run.head_repository.full_name = 'someone/Ruby4Lich5'
    { Read-VerifiedGemBundle @script:ReadArgs } | Should -Throw '*this repository*'
  }

  It 'rejects an earlier run attempt and directs a fresh dispatch with a new run ID' {
    $script:Run.run_attempt = 2
    { Read-VerifiedGemBundle @script:ReadArgs } | Should -Throw '*fresh gem-factory dispatch*new run ID*'
  }

  It 'rejects mismatched metadata <Field>' -TestCases @(
    @{ Field = 'schema_version'; Value = 2 }
    @{ Field = 'repository'; Value = 'someone/else' }
    @{ Field = 'run_id'; Value = '99999' }
    @{ Field = 'source_sha'; Value = ('c' * 40) }
    @{ Field = 'platform'; Value = 'arm64-darwin' }
  ) {
    param($Field, $Value)
    $metadata = Get-Content $script:MetadataPath -Raw | ConvertFrom-Json
    $metadata.$Field = $Value
    $metadata | ConvertTo-Json -Depth 6 | Set-Content $script:MetadataPath
    { Read-VerifiedGemBundle @script:ReadArgs } | Should -Throw '*identity*'
  }

  It 'rejects a different Ruby series' {
    $script:ReadArgs.RubySeries = '4.1'
    { Read-VerifiedGemBundle @script:ReadArgs } | Should -Throw '*RubyInstaller version/digest*'
  }

  It 'rejects malformed Ruby provenance <Field>' -TestCases @(
    @{ Field = 'ruby_installer_version'; Value = "4.0.9-1`nEXTRA=value" }
    @{ Field = 'ruby_archive_digest'; Value = 'not-a-digest' }
  ) {
    param($Field, $Value)
    $metadata = Get-Content $script:MetadataPath -Raw | ConvertFrom-Json
    $metadata.$Field = $Value
    $metadata | ConvertTo-Json -Depth 6 | Set-Content $script:MetadataPath
    { Read-VerifiedGemBundle @script:ReadArgs } | Should -Throw '*RubyInstaller version/digest*'
  }

  It 'rejects modified gem bytes' {
    Add-Content (Join-Path $script:BundleDir 'example-1.0.gem') 'changed'
    { Read-VerifiedGemBundle @script:ReadArgs } | Should -Throw '*checksum mismatch*'
  }

  It 'rejects missing files' {
    Remove-Item (Join-Path $script:BundleDir 'example-1.0.gem')
    { Read-VerifiedGemBundle @script:ReadArgs } | Should -Throw '*missing file*'
  }

  It 'rejects additional unchecked files' {
    Set-Content (Join-Path $script:BundleDir 'unlisted.gem') 'unchecked'
    { Read-VerifiedGemBundle @script:ReadArgs } | Should -Throw '*unlisted*'
  }

  It 'rejects nested directories' {
    New-Item -ItemType Directory (Join-Path $script:BundleDir 'nested') | Out-Null
    { Read-VerifiedGemBundle @script:ReadArgs } | Should -Throw '*directory*'
  }

  It 'rejects unsafe checksum names before accessing outside the bundle' {
    $metadata = Get-Content $script:MetadataPath -Raw | ConvertFrom-Json
    $metadata.files[0].name = '../outside.gem'
    $metadata | ConvertTo-Json -Depth 6 | Set-Content $script:MetadataPath
    { Read-VerifiedGemBundle @script:ReadArgs } | Should -Throw '*unsafe*'
  }

  It 'rejects duplicate checksum names including case variants' {
    $metadata = Get-Content $script:MetadataPath -Raw | ConvertFrom-Json
    $copy = [pscustomobject]@{ name = $metadata.files[0].name.ToUpperInvariant(); sha256 = $metadata.files[0].sha256 }
    $metadata.files += $copy
    $metadata | ConvertTo-Json -Depth 6 | Set-Content $script:MetadataPath
    { Read-VerifiedGemBundle @script:ReadArgs } | Should -Throw '*duplicate*'
  }

  It 'rejects missing resolution evidence even when remaining checksums are valid' {
    Remove-Item (Join-Path $script:BundleDir 'resolution-lock.json')
    New-GemBundleMetadata @script:MetadataArgs
    { Read-VerifiedGemBundle @script:ReadArgs } | Should -Throw '*missing required inventory*'
  }

  It 'rejects invalid install targets even when their checksum is valid: <Target>' -TestCases @(
    @{ Target = '--help' }
    @{ Target = '../outside.gem' }
    @{ Target = 'missing-1.0.gem' }
  ) {
    param($Target)
    Set-Content (Join-Path $script:BundleDir 'runtime-gems-install-targets.txt') $Target
    New-GemBundleMetadata @script:MetadataArgs
    { Read-VerifiedGemBundle @script:ReadArgs } | Should -Throw '*not a checked local gem*'
  }

  It 'rejects a target inventory that omits a shipped gem' {
    Set-Content (Join-Path $script:BundleDir 'runtime-gems-install-targets.txt') $script:GemNames[0]
    New-GemBundleMetadata @script:MetadataArgs
    { Read-VerifiedGemBundle @script:ReadArgs } | Should -Throw '*same gem files*'
  }

  It 'rejects duplicate install targets' {
    Set-Content (Join-Path $script:BundleDir 'runtime-gems-install-targets.txt') @($script:GemNames[0], $script:GemNames[0])
    New-GemBundleMetadata @script:MetadataArgs
    { Read-VerifiedGemBundle @script:ReadArgs } | Should -Throw '*unique*'
  }
}
