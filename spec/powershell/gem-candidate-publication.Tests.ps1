Describe 'Immutable gem candidate publication' {
  BeforeAll {
    . "$PSScriptRoot/../../gem-candidate-publication.ps1"
  }

  BeforeEach {
    $script:CandidateDir = Join-Path $TestDrive 'candidate'
    New-Item -ItemType Directory -Path $script:CandidateDir -Force | Out-Null
    $script:Tag = 'R4L5-gem-bundle-x64-mingw-ucrt-candidate-123-1'
    $script:SourceSha = 'a' * 40
    foreach ($name in @('R4L5-gem-manifest.json', 'R4L5-gem-bundle-x64-mingw-ucrt.zip', 'R4L5-ox-1.0-x64-mingw-ucrt.gem')) {
      Set-Content -LiteralPath (Join-Path $script:CandidateDir $name) -Value "bytes for $name"
    }
    $script:Release = [pscustomobject]@{
      tagName = $script:Tag
      targetCommitish = $script:SourceSha
      isDraft = $false
      assets = @(Get-ChildItem -LiteralPath $script:CandidateDir -File | ForEach-Object {
        [pscustomobject]@{ name = $_.Name; digest = 'sha256:' + (Get-FileHash $_.FullName -Algorithm SHA256).Hash.ToLowerInvariant() }
      })
    }
    $script:PublishArgs = @{
      Directory = $script:CandidateDir
      Repository = 'elanthia-online/Ruby4Lich5'
      Tag = $script:Tag
      SourceSha = $script:SourceSha
    }
    Mock Invoke-CandidateGh { $script:Release | ConvertTo-Json -Depth 6 }
    Mock Start-Sleep {}
  }

  It 'reuses an identical existing identity without any release write' {
    Publish-ImmutableGemCandidate @script:PublishArgs
    Should -Invoke Invoke-CandidateGh -Times 1 -Exactly -ParameterFilter { $Arguments[1] -eq 'view' }
    Should -Invoke Invoke-CandidateGh -Times 0 -Exactly -ParameterFilter { $Arguments[1] -ne 'view' }
  }

  It 'rejects changed native gem bytes without disturbing any release' {
    Add-Content (Join-Path $script:CandidateDir 'R4L5-ox-1.0-x64-mingw-ucrt.gem') 'rebuilt bytes'
    { Publish-ImmutableGemCandidate @script:PublishArgs } | Should -Throw '*bytes differ*'
    Should -Invoke Invoke-CandidateGh -Times 0 -Exactly -ParameterFilter { $Arguments[1] -ne 'view' }
  }

  It 'rejects conflicting candidate <Field>' -ForEach @(
    @{ Field = 'targetCommitish'; Value = ('b' * 40) }
    @{ Field = 'tagName'; Value = 'other-tag' }
    @{ Field = 'isDraft'; Value = $true }
  ) {
    $script:Release.$Field = $Value
    { Publish-ImmutableGemCandidate @script:PublishArgs } | Should -Throw '*identity differs*'
    Should -Invoke Invoke-CandidateGh -Times 0 -Exactly -ParameterFilter { $Arguments[1] -ne 'view' }
  }

  It 'rejects an incomplete existing candidate instead of resuming an upload' {
    $script:Release.assets = @($script:Release.assets | Select-Object -First 1)
    { Publish-ImmutableGemCandidate @script:PublishArgs } | Should -Throw '*inventory differs*'
    Should -Invoke Invoke-CandidateGh -Times 0 -Exactly -ParameterFilter { $Arguments[1] -ne 'view' }
  }

  It 'rejects a remote asset whose name changes the case of the consumer basename' {
    ($script:Release.assets | Where-Object { $_.name -ceq 'R4L5-gem-manifest.json' }).name = 'r4l5-gem-manifest.json'
    { Publish-ImmutableGemCandidate @script:PublishArgs } | Should -Throw '*unexpected asset*'
    Should -Invoke Invoke-CandidateGh -Times 0 -Exactly -ParameterFilter { $Arguments[1] -ne 'view' }
  }

  It 'does not treat an authentication failure as an absent release' {
    Mock Invoke-CandidateGh { throw 'gh failed: HTTP 403 forbidden' }
    { Publish-ImmutableGemCandidate @script:PublishArgs } | Should -Throw '*403*'
    Should -Invoke Invoke-CandidateGh -Times 0 -Exactly -ParameterFilter { $Arguments[1] -ne 'view' }
  }

  It 'does not treat malformed successful JSON as an absent release' {
    Mock Invoke-CandidateGh { 'null' }
    { Publish-ImmutableGemCandidate @script:PublishArgs } | Should -Throw '*Malformed*'
    Should -Invoke Invoke-CandidateGh -Times 0 -Exactly -ParameterFilter { $Arguments[1] -ne 'view' }
  }

  It 'creates only the new immutable candidate with the exact consumer basename and then verifies its digests' {
    $script:Views = 0
    Mock Invoke-CandidateGh {
      $script:Views++
      if ($script:Views -eq 1) { throw 'gh failed: release not found' }
      $script:Release | ConvertTo-Json -Depth 6
    } -ParameterFilter { $Arguments[1] -eq 'view' }
    Mock Invoke-CandidateGh { '' } -ParameterFilter { $Arguments[1] -eq 'create' }
    Publish-ImmutableGemCandidate @script:PublishArgs
    Should -Invoke Invoke-CandidateGh -Times 1 -Exactly -ParameterFilter {
      $Arguments[1] -eq 'create' -and $Arguments[2] -eq $script:Tag -and
      $Arguments -contains (Join-Path $script:CandidateDir 'R4L5-gem-manifest.json') -and
      $Arguments -contains '--latest=false' -and $Arguments -notcontains '--clobber'
    }
    Should -Invoke Invoke-CandidateGh -Times 0 -Exactly -ParameterFilter { $Arguments[1] -in @('upload', 'edit', 'delete') }
  }

  It 'leaves previous service unchanged when creation fails' {
    Mock Invoke-CandidateGh { throw 'gh failed: release not found' } -ParameterFilter { $Arguments[1] -eq 'view' }
    Mock Invoke-CandidateGh { throw 'creation failed' } -ParameterFilter { $Arguments[1] -eq 'create' }
    { Publish-ImmutableGemCandidate @script:PublishArgs } | Should -Throw '*creation failed*'
    Should -Invoke Invoke-CandidateGh -Times 0 -Exactly -ParameterFilter { $Arguments[1] -in @('upload', 'edit', 'delete') }
  }

  It 'bounds empty-digest readback and never repairs by replacing assets' {
    $script:Release.assets[0].digest = ''
    { Publish-ImmutableGemCandidate @script:PublishArgs } | Should -Throw '*five reads*'
    Should -Invoke Start-Sleep -Times 4 -Exactly
    Should -Invoke Invoke-CandidateGh -Times 0 -Exactly -ParameterFilter { $Arguments[1] -ne 'view' }
  }

  It 'refuses the production or reusable candidate tag before any network access' -ForEach @(
    @{ BadTag = 'R4L5-gem-bundle-x64-mingw-ucrt' }
    @{ BadTag = 'R4L5-gem-bundle-x64-mingw-ucrt-candidate' }
    @{ BadTag = 'R4L5-ox-1.0-x64-mingw-ucrt' }
  ) {
    $script:PublishArgs.Tag = $BadTag
    { Publish-ImmutableGemCandidate @script:PublishArgs } | Should -Throw '*run/attempt tag*'
    Should -Invoke Invoke-CandidateGh -Times 0 -Exactly
  }

  It 'passes the ordinary notes by default and the genesis notes in genesis mode to the one create call' -ForEach @(
    @{ Mode = $null }
    @{ Mode = 'ordinary' }
    @{ Mode = 'genesis' }
  ) {
    Mock Invoke-CandidateGh { throw 'gh failed: release not found' } -ParameterFilter { $Arguments[1] -eq 'view' }
    Mock Invoke-CandidateGh { throw 'stop after create' } -ParameterFilter { $Arguments[1] -eq 'create' }
    if ($null -ne $Mode) { $script:PublishArgs.Mode = $Mode }
    $script:ExpectedNotes = Get-GemCandidateReleaseNotes -Mode $(if ($null -eq $Mode) { 'ordinary' } else { $Mode }) -Platform (Get-TargetPlatform)
    { Publish-ImmutableGemCandidate @script:PublishArgs } | Should -Throw '*stop after create*'
    Should -Invoke Invoke-CandidateGh -Times 1 -Exactly -ParameterFilter {
      $Arguments[1] -eq 'create' -and $Arguments[[array]::IndexOf($Arguments, '--notes') + 1] -ceq $script:ExpectedNotes
    }
  }

  It 'refuses an unknown publication mode before any network access' {
    $script:PublishArgs.Mode = 'Genesis2'
    { Publish-ImmutableGemCandidate @script:PublishArgs } | Should -Throw
    Should -Invoke Invoke-CandidateGh -Times 0 -Exactly
  }
}

Describe 'Gem candidate release notes' {
  BeforeAll {
    . "$PSScriptRoot/../../gem-candidate-publication.ps1"
  }

  It 'keeps the ordinary notes exactly as before' {
    $expected = @'
Immutable candidate. Production assets are unchanged. Do not overwrite the production bundle or native gems.

Promotion requires the admin-controlled promote-gem-candidate.yml workflow delivered by PR #47; do not promote from PR #46 alone. Run mode=inspect for this candidate-tag, review its candidate, live predecessor and change-report SHA-256 values, then run mode=promote with those exact candidate-sha256, live-sha256 and change-sha256 inputs. A changed predecessor requires a new inspection.

After verified public readback, reconcile the emitted R4L5-gem-manifest.json into manifest/R4L5-gem-manifest.json through owner-controlled Git history. Both installer sources validate against the live served manifest, not that repository snapshot, and verify the accepted digest again before finalizing provenance. The installer normally uses gem-source=actions with the successful gem-suite Actions run ID. After artifact expiry, use gem-source=accepted-candidate with this exact candidate tag and leave gem-build-run-id blank. The candidate manifest must exactly match the currently accepted manifest, which must bind this ZIP's digest; its complete tested metadata/inventories and exact RubyInstaller identity are verified again. No historical-manifest override, Actions-expiry fallback or mutable production ZIP is used.

Keep every candidate release and asset referenced by a served or retained rollback manifest. Never delete or replace those bytes. Promotion replaces only the served manifest; failures require verified restoration of the predecessor, or an administrative hold if restoration cannot be confirmed.
'@
    Get-GemCandidateReleaseNotes -Mode ordinary -Platform (Get-TargetPlatform -Platform 'x64-mingw-ucrt') | Should -BeExactly $expected
    Get-GemCandidateReleaseNotes -Mode ordinary -Platform (Get-TargetPlatform -Platform 'aarch64-mingw-ucrt') | Should -BeExactly $expected
  }

  It 'gives a genesis candidate the first-platform runbook inputs and no predecessor or installer steps' {
    $notes = Get-GemCandidateReleaseNotes -Mode genesis -Platform (Get-TargetPlatform -Platform 'aarch64-mingw-ucrt')
    foreach ($text in @(
        'first-platform (genesis) candidate for aarch64-mingw-ucrt',
        'There is no accepted predecessor',
        'docs/PLATFORM-GENESIS.md',
        'mode=inspect, platform=aarch64-mingw-ucrt, genesis=true and this candidate-tag',
        'live-sha256 must be absent',
        'mode=promote with platform=aarch64-mingw-ucrt, genesis=true',
        'live-sha256=absent and genesis-confirm=R4L5-gem-bundle-aarch64-mingw-ucrt.',
        'The installer stays x64-only',
        'Never delete or replace those bytes.')) {
      $notes | Should -BeLikeExactly "*$text*"
    }
    foreach ($text in @('live predecessor and change-report', 'manifest/R4L5-gem-manifest.json', 'gem-source=', 'restoration of the predecessor', 'PR #4')) {
      $notes | Should -Not -BeLike "*$text*"
    }
  }

  It 'refuses an unknown mode' {
    { Get-GemCandidateReleaseNotes -Mode 'other' -Platform (Get-TargetPlatform) } | Should -Throw
  }
}
