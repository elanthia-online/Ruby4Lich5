BeforeAll {
  . "$PSScriptRoot/../../accepted-gem-manifest.ps1"
}

Describe 'Live accepted manifest authority for both installer sources' {
  BeforeEach {
    $script:Body = '{"schema":1,"targets":[]}'
    $hasher = [Security.Cryptography.SHA256]::Create()
    try { $hash = $hasher.ComputeHash([Text.Encoding]::UTF8.GetBytes($script:Body)) } finally { $hasher.Dispose() }
    $script:Digest = 'sha256:' + (($hash | ForEach-Object { $_.ToString('x2') }) -join '')
    $script:Url = 'https://github.com/elanthia-online/Ruby4Lich5/releases/download/R4L5-gem-bundle-x64-mingw-ucrt/R4L5-gem-manifest.json'
    $script:Release = [pscustomobject]@{
      tag_name = 'R4L5-gem-bundle-x64-mingw-ucrt'; draft = $false
      assets = @([pscustomobject]@{ name = 'R4L5-gem-manifest.json'; browser_download_url = $script:Url; digest = $script:Digest })
    }
    $script:Destination = Join-Path $TestDrive 'accepted.json'
    Mock Invoke-CandidateGh { $script:Release | ConvertTo-Json -Depth 6 }
    Mock Invoke-WebRequest {
      param($Uri, $OutFile)
      [IO.File]::WriteAllText($OutFile, $script:Body, (New-Object Text.UTF8Encoding($false)))
    }
  }

  It 'selects verified live bytes despite a conflicting checkout snapshot' {
    $checkout = Join-Path $TestDrive 'checkout-manifest.json'
    Set-Content $checkout 'stale repository manifest'
    $accepted = Read-LiveAcceptedGemManifest -Repository 'elanthia-online/Ruby4Lich5' -DestinationPath $script:Destination
    $accepted.Path | Should -Be $script:Destination
    $accepted.Digest | Should -Be $script:Digest
    [IO.File]::ReadAllText($accepted.Path) | Should -Be $script:Body
    Get-Content $checkout | Should -Be 'stale repository manifest'
    Should -Invoke Invoke-WebRequest -Times 1 -Exactly -ParameterFilter { $Uri -ceq $script:Url }
  }

  It 'verifies unchanged accepted bytes again when finalizing provenance' {
    Read-LiveAcceptedGemManifest -Repository 'elanthia-online/Ruby4Lich5' -DestinationPath $script:Destination -ExpectedDigest $script:Digest | Out-Null
    Should -Invoke Invoke-WebRequest -Times 1 -Exactly
  }

  It 'stops before downloading if promotion changes the accepted digest' {
    { Read-LiveAcceptedGemManifest -Repository 'elanthia-online/Ruby4Lich5' -DestinationPath $script:Destination -ExpectedDigest ('sha256:' + ('b' * 64)) } |
      Should -Throw '*Accepted manifest changed*'
    Should -Invoke Invoke-WebRequest -Times 0 -Exactly
  }

  It 'rejects a wrong release identity: <Field>' -TestCases @(
    @{ Field = 'draft'; Value = $true }; @{ Field = 'tag_name'; Value = 'other' }
  ) {
    param($Field, $Value)
    $script:Release.$Field = $Value
    { Read-LiveAcceptedGemManifest -Repository 'elanthia-online/Ruby4Lich5' -DestinationPath $script:Destination } | Should -Throw '*published accepted manifest identity*'
    Should -Invoke Invoke-WebRequest -Times 0 -Exactly
  }

  It 'rejects ambiguous or unavailable assets: <Variant>' -TestCases @(
    @{ Variant = 'missing' }; @{ Variant = 'duplicate' }; @{ Variant = 'foreign-url' }; @{ Variant = 'invalid-digest' }
  ) {
    param($Variant)
    switch ($Variant) {
      'missing' { $script:Release.assets = @() }
      'duplicate' { $script:Release.assets += $script:Release.assets[0] }
      'foreign-url' { $script:Release.assets[0].browser_download_url = 'https://example.test/manifest.json' }
      'invalid-digest' { $script:Release.assets[0].digest = 'unknown' }
    }
    { Read-LiveAcceptedGemManifest -Repository 'elanthia-online/Ruby4Lich5' -DestinationPath $script:Destination } | Should -Throw '*published accepted manifest identity*'
    Should -Invoke Invoke-WebRequest -Times 0 -Exactly
  }

  It 'rejects changed download bytes and preserves any prior verified destination' {
    Set-Content $script:Destination 'previous verified bytes'
    $script:Body = 'not the accepted bytes'
    { Read-LiveAcceptedGemManifest -Repository 'elanthia-online/Ruby4Lich5' -DestinationPath $script:Destination } | Should -Throw '*Digest mismatch*'
    Get-Content $script:Destination | Should -Be 'previous verified bytes'
  }

  It 'fails closed on API errors instead of using a repository fallback' {
    Mock Invoke-CandidateGh { throw 'API unavailable' }
    { Read-LiveAcceptedGemManifest -Repository 'elanthia-online/Ruby4Lich5' -DestinationPath $script:Destination } | Should -Throw '*API unavailable*'
    Should -Invoke Invoke-WebRequest -Times 0 -Exactly
  }

  It 'fails closed on a download error and preserves the previous destination' {
    Set-Content $script:Destination 'previous verified bytes'
    Mock Invoke-WebRequest { throw 'Download unavailable' }
    { Read-LiveAcceptedGemManifest -Repository 'elanthia-online/Ruby4Lich5' -DestinationPath $script:Destination } | Should -Throw '*Download unavailable*'
    Get-Content $script:Destination | Should -Be 'previous verified bytes'
  }

  It 'rejects invalid expected digests before acquisition' {
    { Read-LiveAcceptedGemManifest -Repository 'elanthia-online/Ruby4Lich5' -DestinationPath $script:Destination -ExpectedDigest 'invalid' } | Should -Throw '*valid expected digest*'
    Should -Invoke Invoke-CandidateGh -Times 0 -Exactly
  }
}
