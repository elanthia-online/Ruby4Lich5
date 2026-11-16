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
      Confirm = $script:Tag; ReadbackPath = (Join-Path $TestDrive 'readback.json'); RunId = '4242'; RunAttempt = '1'
    }
    $script:Environment = @{ id = 9; name = 'r4l5-recovery-promotion'; protection_rules = @(
        @{ type = 'wait_timer'; wait_timer = 0 },
        @{ type = 'required_reviewers'; reviewers = @(@{ type = 'User'; reviewer = @{ login = 'admin-one' } }) }) }
    $script:EnvironmentExit = 0
    $script:Approvals = @(@{ state = 'approved'; environments = @(@{ id = 9 }); user = @{ login = 'admin-one' } })
    $script:Permissions = @{ 'admin-one' = 'admin'; 'writer' = 'write' }
    $script:State = 'absent'
    $script:Published = $false
    $script:FailUpload = $false
    $script:FailCreate = $false
    Mock Start-Sleep {}
    Mock Invoke-GhNative {
      $path = $Arguments[1]
      if ($path -like '*/environments/*') {
        if ($script:EnvironmentExit -ne 0) { return [pscustomobject]@{ ExitCode = 1; Output = 'gh: Not Found (HTTP 404)' } }
        return [pscustomobject]@{ ExitCode = 0; Output = ($script:Environment | ConvertTo-Json -Depth 8) }
      }
      if ($path -match '/collaborators/([^/]+)/permission$') {
        return [pscustomobject]@{ ExitCode = 0; Output = (@{ permission = $script:Permissions[$Matches[1]] } | ConvertTo-Json) }
      }
      if ($path -like '*/actions/runs/4242/approvals') { return [pscustomobject]@{ ExitCode = 0; Output = (ConvertTo-Json -InputObject @($script:Approvals) -Depth 8) } }
      throw "unexpected gh api call: $Arguments"
    }
    Mock Get-GemProductionReleaseState { $script:State }
    Mock Invoke-PromotionGh {
      switch ($Arguments[1]) {
        'create' { if ($script:FailCreate) { throw 'create failed' }; $script:State = 'release'; return '' }
        'upload' { if ($script:FailUpload) { throw 'upload failed' }; $script:Published = $true; return '' }
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

  It 'creates the production release once, uploads the manifest and verifies the readback' {
    Invoke-GemManifestGenesis @script:GenesisArgs
    Should -Invoke Invoke-PromotionGh -Times 1 -Exactly -ParameterFilter {
      $Arguments[1] -eq 'create' -and $Arguments[2] -ceq 'R4L5-gem-bundle-aarch64-mingw-ucrt' -and $Arguments -contains '--latest=false' -and
        $Arguments[[Array]::IndexOf($Arguments, '--target') + 1] -ceq ('a' * 40) -and $Arguments[[Array]::IndexOf($Arguments, '--title') + 1] -ceq 'Gem bundle (aarch64-mingw-ucrt)'
    }
    Should -Invoke Invoke-PromotionGh -Times 1 -Exactly -ParameterFilter { $Arguments[1] -eq 'upload' -and $Arguments -notcontains '--clobber' }
    Should -Invoke Confirm-LiveGemManifest -Times 1 -Exactly -ParameterFilter { $ExpectedDigest -ceq $script:Digest }
    Should -Invoke Invoke-PromotionGh -Times 0 -Exactly -ParameterFilter { $Arguments[1] -eq 'delete' }
  }

  It 'refuses wrong confirmation text, a live digest other than absent, or changed bytes before any read' {
    foreach ($case in @(
        @{ Change = @{ Confirm = '' }; Message = '*genesis-confirm to equal R4L5-gem-bundle-aarch64-mingw-ucrt*' },
        @{ Change = @{ Confirm = 'R4L5-gem-bundle-x64-mingw-ucrt' }; Message = '*genesis-confirm to equal*' },
        @{ Change = @{ ExpectedLiveDigest = ('sha256:' + ('b' * 64)) }; Message = '*live-sha256 absent*' },
        @{ Change = @{ ExpectedLiveDigest = '' }; Message = '*live-sha256 absent*' })) {
      $arguments = $script:GenesisArgs.Clone()
      foreach ($key in $case.Change.Keys) { $arguments[$key] = $case.Change[$key] }
      { Invoke-GemManifestGenesis @arguments } | Should -Throw $case.Message
    }
    Add-Content $script:CandidatePath 'tampered'
    { Invoke-GemManifestGenesis @script:GenesisArgs } | Should -Throw '*bytes changed*'
    Should -Invoke Invoke-GhNative -Times 0 -Exactly
    Should -Invoke Invoke-PromotionGh -Times 0 -Exactly
  }

  It 'refuses when the protection environment is missing, unprotected, or names no administrator users' {
    $script:EnvironmentExit = 1
    { Invoke-GemManifestGenesis @script:GenesisArgs } | Should -Throw '*requires the r4l5-recovery-promotion environment*'
    $script:EnvironmentExit = 0
    $script:Environment.protection_rules = @(@{ type = 'wait_timer'; wait_timer = 5 })
    { Invoke-GemManifestGenesis @script:GenesisArgs } | Should -Throw '*one required-reviewers rule*'
    $script:Environment.protection_rules = @(@{ type = 'required_reviewers'; reviewers = @() })
    { Invoke-GemManifestGenesis @script:GenesisArgs } | Should -Throw '*one required-reviewers rule*'
    $script:Environment.protection_rules = @(@{ type = 'required_reviewers'; reviewers = @(@{ type = 'Team'; reviewer = @{ slug = 'maintainers' } }) })
    { Invoke-GemManifestGenesis @script:GenesisArgs } | Should -Throw '*administrator users explicitly*'
    # A team is refused by type, whatever its fields resemble.
    $script:Environment.protection_rules = @(@{ type = 'required_reviewers'; reviewers = @(@{ type = 'Team'; reviewer = @{ login = 'admin-one' } }) })
    { Invoke-GemManifestGenesis @script:GenesisArgs } | Should -Throw '*administrator users explicitly*'
    $script:Environment.protection_rules = @(@{ type = 'required_reviewers'; reviewers = @(@{ type = 'User'; reviewer = @{ login = 'writer' } }) })
    { Invoke-GemManifestGenesis @script:GenesisArgs } | Should -Throw '*writer must be a repository administrator*'
    Should -Invoke Invoke-PromotionGh -Times 0 -Exactly
  }

  It 'requires a recorded administrator approval for that environment in this first run attempt' {
    $script:Approvals = @()
    { Invoke-GemManifestGenesis @script:GenesisArgs } | Should -Throw '*No explicit approval*'
    $script:Approvals = @(@{ state = 'approved'; environments = @(@{ id = 10 }); user = @{ login = 'admin-one' } })
    { Invoke-GemManifestGenesis @script:GenesisArgs } | Should -Throw '*No explicit approval*'
    $script:Approvals = @(@{ state = 'rejected'; environments = @(@{ id = 9 }); user = @{ login = 'admin-one' } })
    { Invoke-GemManifestGenesis @script:GenesisArgs } | Should -Throw '*No explicit approval*'
    $script:Approvals = @(@{ state = 'approved'; environments = @(@{ id = 9 }); user = @{ login = 'writer' } })
    { Invoke-GemManifestGenesis @script:GenesisArgs } | Should -Throw '*writer must be a repository administrator*'
    $script:Approvals = @(@{ state = 'approved'; environments = @(@{ id = 9 }); user = @{ login = 'admin-one' } })
    $arguments = $script:GenesisArgs.Clone(); $arguments.RunAttempt = '2'
    { Invoke-GemManifestGenesis @arguments } | Should -Throw '*fresh genesis dispatch*'
    Should -Invoke Invoke-PromotionGh -Times 0 -Exactly
  }

  It 'refuses when the production release already exists' {
    $script:State = 'release'
    { Invoke-GemManifestGenesis @script:GenesisArgs } | Should -Throw '*already exists (release)*'
    Should -Invoke Invoke-PromotionGh -Times 0 -Exactly
  }

  It 'deletes the release it created when the upload fails and verifies absence' {
    $script:FailUpload = $true
    { Invoke-GemManifestGenesis @script:GenesisArgs } | Should -Throw '*upload failed; the created R4L5-gem-bundle-aarch64-mingw-ucrt was deleted and its absence verified*'
    Should -Invoke Invoke-PromotionGh -Times 1 -Exactly -ParameterFilter {
      $Arguments[1] -eq 'delete' -and $Arguments[2] -ceq 'R4L5-gem-bundle-aarch64-mingw-ucrt' -and $Arguments -contains '--cleanup-tag'
    }
    $script:State | Should -Be 'absent'
  }

  It 'deletes after a failed readback but never deletes a release it did not create' {
    Mock Confirm-LiveGemManifest { throw 'readback digest differs' }
    { Invoke-GemManifestGenesis @script:GenesisArgs } | Should -Throw '*readback digest differs; the created*deleted*'
    $script:State = 'absent'
    $script:FailCreate = $true
    { Invoke-GemManifestGenesis @script:GenesisArgs } | Should -Throw '*before a release was created*'
    Should -Invoke Invoke-PromotionGh -Times 1 -Exactly -ParameterFilter { $Arguments[1] -eq 'delete' }
  }

  It 'reports unconfirmed cleanup when the created release does not disappear' {
    $script:FailUpload = $true
    Mock Invoke-PromotionGh {
      switch ($Arguments[1]) {
        'create' { $script:State = 'release'; return '' }
        'upload' { throw 'upload failed' }
        'delete' { return '' }
      }
    }
    { Invoke-GemManifestGenesis @script:GenesisArgs } | Should -Throw '*removal of the created*unconfirmed*'
  }

  It 'checks only the environment configuration when no run is given' {
    $script:Approvals = @()
    { Assert-GemRecoveryPromotionEnvironment -Repository 'elanthia-online/Ruby4Lich5' } | Should -Not -Throw
    Should -Invoke Invoke-GhNative -Times 0 -Exactly -ParameterFilter { $Arguments[1] -like '*/approvals' }
  }
}
