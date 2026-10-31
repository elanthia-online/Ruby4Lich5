BeforeAll {
  . "$PSScriptRoot/../../gem-bundle-artifact.ps1"
  function Seal-PartialBundle {
    $script:Map | ConvertTo-Json -Depth 8 | Set-Content (Join-Path $script:Directory 'delivery-map.json')
    New-GemBundleMetadata -Directory $script:Directory -Repository 'elanthia-online/Ruby4Lich5' -RunId 42 -RunAttempt 1 `
      -SourceSha ('a' * 40) -RubyInstallerVersion '4.0.9-1' -RubyArchiveDigest ('sha256:' + ('b' * 64))
    Remove-Item (Join-Path $script:Directory 'upstream-1.0.gem')
  }

  function Read-PartialBundle {
    Read-VerifiedGemBundle -Directory $script:Directory -Run $script:Run -Repository 'elanthia-online/Ruby4Lich5' -RunId 42 -RubySeries '4.0'
  }

}

Describe 'D1 tested upstream acquisition' {
  BeforeEach {
    $script:Directory = Join-Path $TestDrive ([guid]::NewGuid().ToString('N'))
    New-Item -ItemType Directory $script:Directory | Out-Null
    $script:Run = [pscustomobject]@{
      id = 42; run_attempt = 1; head_sha = ('a' * 40)
      repository = @{ full_name = 'elanthia-online/Ruby4Lich5' }
      head_repository = @{ full_name = 'elanthia-online/Ruby4Lich5' }
      path = '.github/workflows/ruby4-bundled-gems-suite.yml'
      event = 'workflow_dispatch'; status = 'completed'; conclusion = 'success'
    }
    foreach ($name in @('upstream-1.0.gem', 'built-1.0-x64-mingw-ucrt.gem')) {
      [IO.File]::WriteAllText((Join-Path $script:Directory $name), 'tested bytes')
    }
    $script:Map = [ordered]@{ schema = 1; packages = @(
      [ordered]@{ filename = 'upstream-1.0.gem'; sha256 = (Get-FileHash (Join-Path $script:Directory 'upstream-1.0.gem')).Hash.ToLowerInvariant(); delivery = 'upstream'; url = 'https://rubygems.org/downloads/upstream-1.0.gem' }
      [ordered]@{ filename = 'built-1.0-x64-mingw-ucrt.gem'; sha256 = (Get-FileHash (Join-Path $script:Directory 'built-1.0-x64-mingw-ucrt.gem')).Hash.ToLowerInvariant(); delivery = 'bundle'; url = $null }
    ) }
    foreach ($name in @('runtime-gems-manifest.txt', 'runtime-gems-install-targets.txt')) {
      @('upstream-1.0.gem', 'built-1.0-x64-mingw-ucrt.gem') | Set-Content (Join-Path $script:Directory $name)
    }
    '{}' | Set-Content (Join-Path $script:Directory 'resolution-lock.json')
    '@echo off' | Set-Content (Join-Path $script:Directory 'install-runtime-gems.cmd')
    Mock Invoke-VerifiedDownload {
      param($Url, $ExpectedDigest, $DestinationPath)
      [IO.File]::WriteAllText($DestinationPath, 'tested bytes')
    }
  }

  It 'reconstructs omitted original packages and verifies the complete tested installer inventory' {
    Seal-PartialBundle
    $result = Read-PartialBundle
    $result.ruby_installer_version | Should -Be '4.0.9-1'
    (Test-Path (Join-Path $script:Directory 'upstream-1.0.gem')) | Should -BeTrue
    Should -Invoke Invoke-VerifiedDownload -Times 1 -Exactly -ParameterFilter {
      $Url -ceq 'https://rubygems.org/downloads/upstream-1.0.gem' -and $ExpectedDigest -cmatch '^sha256:[0-9a-f]{64}$'
    }
  }

  It 'does not download again when all checked package bytes already exist' {
    Seal-PartialBundle
    Read-PartialBundle | Out-Null
    Read-PartialBundle | Out-Null
    Should -Invoke Invoke-VerifiedDownload -Times 1 -Exactly
  }

  It 'rejects a changed delivery map before any acquisition' {
    Seal-PartialBundle
    '{}' | Set-Content (Join-Path $script:Directory 'delivery-map.json')
    { Read-PartialBundle } | Should -Throw '*differs from tested metadata*'
    Should -Invoke Invoke-VerifiedDownload -Times 0
  }

  It 'rejects an upstream redirector or alternate host in the accepted map' {
    $script:Map.packages[0].url = 'https://example.org/upstream-1.0.gem'
    Seal-PartialBundle
    { Read-PartialBundle } | Should -Throw '*original RubyGems filename and URL*'
    Should -Invoke Invoke-VerifiedDownload -Times 0
  }

  It 'rejects missing built files rather than silently fetching replacements' {
    Seal-PartialBundle
    Remove-Item (Join-Path $script:Directory 'built-1.0-x64-mingw-ucrt.gem')
    { Read-PartialBundle } | Should -Throw '*missing file*'
  }

  It 'rejects altered upstream bytes after acquisition' {
    Seal-PartialBundle
    Mock Invoke-VerifiedDownload { param($DestinationPath) [IO.File]::WriteAllText($DestinationPath, 'wrong bytes') }
    { Read-PartialBundle } | Should -Throw '*checksum mismatch*'
  }

  It 'rejects a package digest different from the tested inventory' {
    $script:Map.packages[0].sha256 = 'c' * 64
    Seal-PartialBundle
    { Read-PartialBundle } | Should -Throw '*untested package*'
  }

  It 'rejects unsafe filenames before downloads' {
    $script:Map.packages[0].filename = '../upstream-1.0.gem'
    Seal-PartialBundle
    { Read-PartialBundle } | Should -Throw '*unsafe*'
    Should -Invoke Invoke-VerifiedDownload -Times 0
  }

  It 'rejects incomplete acquisition maps' {
    $script:Map.packages = @($script:Map.packages[0])
    Seal-PartialBundle
    { Read-PartialBundle } | Should -Throw '*complete tested package inventory*'
  }
}
