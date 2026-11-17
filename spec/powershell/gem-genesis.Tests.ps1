Describe 'Genesis publication guards' {
  BeforeAll { . "$PSScriptRoot/../../gem-genesis.ps1" }

  BeforeEach {
    $env:GEM_PLATFORM = 'aarch64-mingw-ucrt'
    $script:Responses = @{
      release = [pscustomobject]@{ ExitCode = 1; Output = 'gh: Not Found (HTTP 404)' }
      ref     = [pscustomobject]@{ ExitCode = 1; Output = 'gh: Not Found (HTTP 404)' }
      list    = [pscustomobject]@{ ExitCode = 0; Output = "R4L5-gem-bundle-x64-mingw-ucrt`nR4L5-gem-bundle-aarch64-mingw-ucrt-candidate-1-1" }
    }
    Mock Invoke-GhNative {
      if ($Arguments[1] -like '*/releases/tags/*') { return $script:Responses.release }
      if ($Arguments[1] -like '*/git/ref/tags/*') { return $script:Responses.ref }
      if ($Arguments[1] -eq '--paginate') { return $script:Responses.list }
      throw "unexpected gh call: $Arguments"
    }
  }

  AfterEach { Remove-Item Env:\GEM_PLATFORM -ErrorAction SilentlyContinue }

  It 'reports absent only when the release and tag are 404 and no listed release carries the tag' {
    Get-GemProductionReleaseState -Repository 'elanthia-online/Ruby4Lich5' | Should -Be 'absent'
    { Assert-GemProductionReleaseAbsent -Repository 'elanthia-online/Ruby4Lich5' } | Should -Not -Throw
    Should -Invoke Invoke-GhNative -Times 2 -Exactly -ParameterFilter { $Arguments[1] -eq 'repos/elanthia-online/Ruby4Lich5/releases/tags/R4L5-gem-bundle-aarch64-mingw-ucrt' }
  }

  It 'refuses genesis when the production release, a bare tag or a draft already exists' {
    $script:Responses.release = [pscustomobject]@{ ExitCode = 0; Output = '{"tag_name":"R4L5-gem-bundle-aarch64-mingw-ucrt"}' }
    { Assert-GemProductionReleaseAbsent -Repository 'elanthia-online/Ruby4Lich5' } | Should -Throw '*already exists (release)*'
    $script:Responses.release = [pscustomobject]@{ ExitCode = 1; Output = 'gh: Not Found (HTTP 404)' }
    $script:Responses.ref = [pscustomobject]@{ ExitCode = 0; Output = '{"ref":"refs/tags/R4L5-gem-bundle-aarch64-mingw-ucrt"}' }
    { Assert-GemProductionReleaseAbsent -Repository 'elanthia-online/Ruby4Lich5' } | Should -Throw '*already exists (tag)*'
    $script:Responses.ref = [pscustomobject]@{ ExitCode = 1; Output = 'gh: Not Found (HTTP 404)' }
    $script:Responses.list = [pscustomobject]@{ ExitCode = 0; Output = "R4L5-gem-bundle-aarch64-mingw-ucrt`nother" }
    { Assert-GemProductionReleaseAbsent -Repository 'elanthia-online/Ruby4Lich5' } | Should -Throw '*already exists (draft)*'
  }

  It 'treats any failure other than a clear 404 as unknown, never absent' {
    $script:Responses.release = [pscustomobject]@{ ExitCode = 1; Output = 'gh: Bad credentials (HTTP 401)' }
    { Get-GemProductionReleaseState -Repository 'elanthia-online/Ruby4Lich5' } | Should -Throw '*release state is unknown*'
    $script:Responses.release = [pscustomobject]@{ ExitCode = 1; Output = 'gh: Not Found (HTTP 404)' }
    $script:Responses.ref = [pscustomobject]@{ ExitCode = 1; Output = 'connection reset' }
    { Get-GemProductionReleaseState -Repository 'elanthia-online/Ruby4Lich5' } | Should -Throw '*tag state is unknown*'
    $script:Responses.ref = [pscustomobject]@{ ExitCode = 1; Output = 'gh: Not Found (HTTP 404)' }
    $script:Responses.list = [pscustomobject]@{ ExitCode = 1; Output = 'API rate limit exceeded' }
    { Get-GemProductionReleaseState -Repository 'elanthia-online/Ruby4Lich5' } | Should -Throw '*listing failed*'
    { Get-GemProductionReleaseState -Repository 'bad repo' } | Should -Throw '*Invalid repository*'
  }
}

Describe 'Genesis promotion' {
  BeforeAll { . "$PSScriptRoot/../../gem-genesis.ps1" }

  BeforeEach {
    $env:GEM_PLATFORM = 'aarch64-mingw-ucrt'
    $script:Tag = 'R4L5-gem-bundle-aarch64-mingw-ucrt'
    $script:CandidatePath = Join-Path $TestDrive 'candidate/R4L5-gem-manifest.json'
    New-Item -ItemType Directory -Path (Split-Path $script:CandidatePath) -Force | Out-Null
    [IO.File]::WriteAllText($script:CandidatePath, 'genesis bytes')
    $script:Digest = 'sha256:' + (Get-FileHash $script:CandidatePath -Algorithm SHA256).Hash.ToLowerInvariant()
    $script:GenesisArgs = @{
      Repository = 'elanthia-online/Ruby4Lich5'; CandidatePath = $script:CandidatePath; ExpectedCandidateDigest = $script:Digest
      ExpectedLiveDigest = 'absent'; CandidateTag = 'R4L5-gem-bundle-aarch64-mingw-ucrt-candidate-77-1'; SourceSha = ('a' * 40)
      Confirm = $script:Tag; ReadbackPath = (Join-Path $TestDrive 'readback.json')
    }
    $script:State = 'absent'
    $script:Published = $false
    $script:FailCreate = $false
    Mock Start-Sleep {}
    Mock Invoke-GhNative { throw "unexpected direct gh call: $Arguments" }
    Mock Get-GemProductionReleaseState { $script:State }
    Mock Invoke-PromotionGh {
      switch ($Arguments[1]) {
        'create' { if ($script:FailCreate) { throw 'gh failed: HTTP 502' }; $script:State = 'release'; $script:Published = $true; return '' }
        'delete' { $script:State = 'absent'; return '' }
        default { throw "unexpected release operation $($Arguments[1])" }
      }
    }
    Mock Confirm-LiveGemManifest {
      if (-not $script:Published) { throw 'Live manifest API digest does not match the approved bytes.' }
      [IO.File]::WriteAllText($DestinationPath, 'genesis bytes')
    }
  }

  AfterEach { Remove-Item Env:\GEM_PLATFORM -ErrorAction SilentlyContinue }

  It 'creates the production release with the manifest attached in one call and verifies the readback' {
    Invoke-GemManifestGenesis @script:GenesisArgs
    Should -Invoke Invoke-PromotionGh -Times 1 -Exactly -ParameterFilter {
      $Arguments[1] -eq 'create' -and $Arguments[2] -ceq 'R4L5-gem-bundle-aarch64-mingw-ucrt' -and $Arguments[3] -ceq $script:CandidatePath -and
        $Arguments -contains '--latest=false' -and $Arguments -notcontains '--draft' -and
        $Arguments[[Array]::IndexOf($Arguments, '--target') + 1] -ceq ('a' * 40) -and $Arguments[[Array]::IndexOf($Arguments, '--title') + 1] -ceq 'Gem bundle (aarch64-mingw-ucrt)'
    }
    Should -Invoke Invoke-PromotionGh -Times 1 -Exactly
    Should -Invoke Confirm-LiveGemManifest -Times 1 -Exactly -ParameterFilter { $ExpectedDigest -ceq $script:Digest }
    Should -Invoke Get-GemProductionReleaseState -Times 1 -Exactly
  }

  It 'refuses every malformed input before reading release state or writing' {
    foreach ($case in @(
        @{ Change = @{ Confirm = '' }; Message = '*genesis-confirm to equal R4L5-gem-bundle-aarch64-mingw-ucrt*' },
        @{ Change = @{ Confirm = 'r4l5-gem-bundle-aarch64-mingw-ucrt' }; Message = '*genesis-confirm to equal*' },
        @{ Change = @{ Confirm = 'R4L5-gem-bundle-x64-mingw-ucrt' }; Message = '*genesis-confirm to equal*' },
        @{ Change = @{ ExpectedLiveDigest = ('sha256:' + ('b' * 64)) }; Message = '*live-sha256 absent*' },
        @{ Change = @{ ExpectedLiveDigest = '' }; Message = '*live-sha256 absent*' },
        @{ Change = @{ ExpectedLiveDigest = 'ABSENT' }; Message = '*live-sha256 absent*' },
        @{ Change = @{ ExpectedCandidateDigest = ('sha256:' + ('A' * 64)) }; Message = '*SHA-256 identities*' },
        @{ Change = @{ ExpectedCandidateDigest = ('b' * 64) }; Message = '*SHA-256 identities*' },
        @{ Change = @{ CandidateTag = 'R4L5-gem-bundle-x64-mingw-ucrt-candidate-77-1' }; Message = '*candidate, source*' },
        @{ Change = @{ CandidateTag = 'R4L5-gem-bundle-aarch64-mingw-ucrt' }; Message = '*candidate, source*' },
        @{ Change = @{ SourceSha = ('A' * 40) }; Message = '*candidate, source*' },
        @{ Change = @{ SourceSha = ('a' * 39) }; Message = '*candidate, source*' },
        @{ Change = @{ Repository = 'elanthia-online/Ruby4Lich5/extra' }; Message = '*repository*' },
        @{ Change = @{ CandidatePath = (Join-Path $TestDrive 'candidate/r4l5-gem-manifest.json') }; Message = '*exact manifest filename*' })) {
      $arguments = $script:GenesisArgs.Clone()
      foreach ($key in $case.Change.Keys) { $arguments[$key] = $case.Change[$key] }
      { Invoke-GemManifestGenesis @arguments } | Should -Throw $case.Message -Because ($case.Change | ConvertTo-Json -Compress)
    }
    Add-Content $script:CandidatePath 'tampered'
    { Invoke-GemManifestGenesis @script:GenesisArgs } | Should -Throw '*bytes changed*'
    Should -Invoke Get-GemProductionReleaseState -Times 0 -Exactly
    Should -Invoke Invoke-PromotionGh -Times 0 -Exactly
  }

  It 'refuses when the production release already exists' {
    foreach ($state in @('release', 'tag', 'draft')) {
      $script:State = $state
      { Invoke-GemManifestGenesis @script:GenesisArgs } | Should -Throw "*already exists ($state)*"
    }
    Should -Invoke Invoke-PromotionGh -Times 0 -Exactly
  }

  It 'deletes the release it created when the readback fails and verifies absence' {
    Mock Confirm-LiveGemManifest { throw 'readback digest differs' }
    { Invoke-GemManifestGenesis @script:GenesisArgs } | Should -Throw '*readback digest differs; the created R4L5-gem-bundle-aarch64-mingw-ucrt was deleted and its absence verified*'
    Should -Invoke Invoke-PromotionGh -Times 1 -Exactly -ParameterFilter {
      $Arguments[1] -eq 'delete' -and $Arguments[2] -ceq 'R4L5-gem-bundle-aarch64-mingw-ucrt' -and $Arguments -contains '--cleanup-tag'
    }
    $script:State | Should -Be 'absent'
  }

  It 'never deletes after a failed create, whose outcome is unknown, and says a release may exist' {
    $script:FailCreate = $true
    { Invoke-GemManifestGenesis @script:GenesisArgs } |
      Should -Throw '*creation failed or its outcome is unknown: gh failed: HTTP 502. A release or draft named R4L5-gem-bundle-aarch64-mingw-ucrt may exist; inspect it before retrying*'
    Should -Invoke Invoke-PromotionGh -Times 0 -Exactly -ParameterFilter { $Arguments[1] -eq 'delete' }
    Should -Invoke Confirm-LiveGemManifest -Times 0 -Exactly
  }

  It 'reports unconfirmed cleanup when the created release does not disappear' {
    Mock Confirm-LiveGemManifest { throw 'readback digest differs' }
    Mock Invoke-PromotionGh {
      switch ($Arguments[1]) {
        'create' { $script:State = 'release'; return '' }
        'delete' { return '' }
      }
    }
    { Invoke-GemManifestGenesis @script:GenesisArgs } | Should -Throw '*removal of the created*unconfirmed*Administrative cleanup is required*'
  }
}
