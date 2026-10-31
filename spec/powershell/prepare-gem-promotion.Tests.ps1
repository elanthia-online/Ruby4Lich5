Describe 'Read-only promotion preparation' {
  BeforeAll { . "$PSScriptRoot/../../prepare-gem-promotion.ps1" }
  BeforeEach {
    $testRoot = Join-Path $TestDrive ([guid]::NewGuid().ToString('N'))
    $script:Repository = 'elanthia-online/Ruby4Lich5'
    $script:Tag = 'R4L5-gem-bundle-x64-mingw-ucrt-candidate-123-1'
    $script:ReleaseDir = Join-Path $testRoot 'release'
    $script:Bundle = Join-Path $testRoot 'bundle'
    $script:Destination = Join-Path $testRoot 'preparation'
    New-Item -ItemType Directory -Path $script:Bundle, $script:ReleaseDir -Force | Out-Null
    Set-Content (Join-Path $script:Bundle 'fixture-1.0.gem') 'gem bytes'
    Set-Content (Join-Path $script:Bundle 'resolution-lock.json') '{}'
    Set-Content (Join-Path $script:Bundle 'runtime-gems-install-targets.txt') 'fixture-1.0.gem'
    Set-Content (Join-Path $script:Bundle 'runtime-gems-manifest.txt') 'fixture-1.0.gem'
    Set-Content (Join-Path $script:Bundle 'install-runtime-gems.cmd') '@echo off'
    New-GemBundleMetadata -Directory $script:Bundle -Repository $script:Repository -RunId '123' -RunAttempt 1 -SourceSha ('a' * 40) -RubyInstallerVersion '4.0.9-1' -RubyArchiveDigest ('sha256:' + ('b' * 64))
    $script:ZipPath = Join-Path $script:ReleaseDir 'R4L5-gem-bundle-x64-mingw-ucrt.zip'
    Compress-Archive -Path (Join-Path $script:Bundle '*') -DestinationPath $script:ZipPath
    Set-Content (Join-Path $script:ReleaseDir 'R4L5-gem-manifest.json') '{"schema":1}'
    $script:Release = [pscustomobject]@{
      tagName = $script:Tag; targetCommitish = ('a' * 40); isDraft = $false
      assets = @(Get-ChildItem $script:ReleaseDir -File | ForEach-Object {
        @{ name = $_.Name; digest = 'sha256:' + (Get-FileHash $_.FullName -Algorithm SHA256).Hash.ToLowerInvariant() }
      })
    }
    $script:Producer = @{
      id = 123; run_attempt = 1; head_sha = ('a' * 40)
      repository = @{ full_name = $script:Repository }; head_repository = @{ full_name = $script:Repository }
      path = '.github/workflows/ruby4-bundled-gems-suite.yml'; event = 'workflow_dispatch'; status = 'completed'; conclusion = 'success'
    }
    Mock Invoke-PromotionGh {
      if ($Arguments[0] -eq 'api') { return ($script:Producer | ConvertTo-Json -Depth 8) }
      if ($Arguments[1] -eq 'view') { return ($script:Release | ConvertTo-Json -Depth 8) }
      if ($Arguments[1] -ne 'download') { throw 'Preparation attempted a release write.' }
      $name = $Arguments[[Array]::IndexOf($Arguments, '--pattern') + 1]
      $directory = $Arguments[[Array]::IndexOf($Arguments, '--dir') + 1]
      Copy-Item -LiteralPath (Join-Path $script:ReleaseDir $name) -Destination (Join-Path $directory $name)
      return ''
    }
    Mock Get-LiveGemManifestDigest { 'sha256:' + (Get-FileHash (Join-Path $script:ReleaseDir 'R4L5-gem-manifest.json') -Algorithm SHA256).Hash.ToLowerInvariant() }
  }

  It 'uses a successful same-repository producer and checked flat files without any release write' {
    Prepare-GemPromotion -Directory $script:Destination -Repository $script:Repository -CandidateTag $script:Tag
    Test-Path (Join-Path $script:Destination 'bundle/gem-build-metadata.json') | Should -BeTrue
    Test-Path (Join-Path $script:Destination 'live/R4L5-gem-manifest.json') | Should -BeTrue
    Should -Invoke Invoke-PromotionGh -Times 0 -Exactly -ParameterFilter { $Arguments[1] -in @('upload', 'create', 'edit', 'delete') }
  }

  It 'refuses a producing run that did not complete successfully' {
    $script:Producer.conclusion = 'failure'
    { Prepare-GemPromotion -Directory $script:Destination -Repository $script:Repository -CandidateTag $script:Tag } | Should -Throw '*successful manual*'
  }

  It 'refuses mismatched release source identity' {
    $script:Release.targetCommitish = 'c' * 40
    { Prepare-GemPromotion -Directory $script:Destination -Repository $script:Repository -CandidateTag $script:Tag } | Should -Throw '*differs from its producing run*'
  }

  It 'rejects traversal entries before extracting a bundle' {
    Add-Type -AssemblyName System.IO.Compression.FileSystem
    $zip = [IO.Compression.ZipFile]::Open($script:ZipPath, [IO.Compression.ZipArchiveMode]::Update)
    try { $zip.CreateEntry('../outside.txt') | Out-Null } finally { $zip.Dispose() }
    ($script:Release.assets | Where-Object { $_.name -eq 'R4L5-gem-bundle-x64-mingw-ucrt.zip' }).digest = 'sha256:' + (Get-FileHash $script:ZipPath -Algorithm SHA256).Hash.ToLowerInvariant()
    { Prepare-GemPromotion -Directory $script:Destination -Repository $script:Repository -CandidateTag $script:Tag } | Should -Throw '*unsafe or duplicate*'
    Test-Path (Join-Path $script:Destination 'outside.txt') | Should -BeFalse
  }
}
