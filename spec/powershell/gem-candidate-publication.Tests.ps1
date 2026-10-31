Describe 'Candidate gh native stderr normalization' {
  BeforeAll {
    . "$PSScriptRoot/../../gem-candidate-publication.ps1"
    $script:NativeEngine = (Get-Process -Id $PID).Path
    $script:NativeFixture = Join-Path $TestDrive 'native-stderr.ps1'
    @'
param([string]$Message, [int]$Code)
[Console]::Error.WriteLine($Message)
exit $Code
'@ | Set-Content -LiteralPath $script:NativeFixture -Encoding ascii
    # Exercise a real child process without invoking GitHub or the network.
    function gh {
      & $script:NativeEngine -NoProfile -NonInteractive -File $script:NativeFixture @args
    }
  }

  It 'normalizes native not-found stderr under Stop and preserves the caller preference' {
    $ErrorActionPreference = 'Stop'
    { Invoke-CandidateGh -Arguments @('-Message', 'release not found', '-Code', '1') } |
      Should -Throw 'gh failed: release not found'
    $ErrorActionPreference | Should -Be 'Stop'
  }

  It 'normalizes authentication failures without classifying them as absence' {
    $ErrorActionPreference = 'Stop'
    { Invoke-CandidateGh -Arguments @('-Message', 'HTTP 403 forbidden', '-Code', '1') } |
      Should -Throw 'gh failed: HTTP 403 forbidden'
  }

  It 'uses the successful exit code even when a native process emits stderr' {
    $ErrorActionPreference = 'Stop'
    Invoke-CandidateGh -Arguments @('-Message', 'diagnostic', '-Code', '0') | Should -Be 'diagnostic'
  }
}

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
}
