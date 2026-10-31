BeforeAll {
  . "$PSScriptRoot/../../gem-candidate-bundle.ps1"
  Add-Type -AssemblyName System.IO.Compression.FileSystem
  function Sync-CandidateFixture {
    if (Test-Path $script:ArchivePath) { Remove-Item $script:ArchivePath }
    Compress-Archive -LiteralPath @(Get-ChildItem $script:SourceDir -File | ForEach-Object { $_.FullName }) -DestinationPath $script:ArchivePath
    Update-CandidateFixtureDigest
  }
  function Update-CandidateFixtureDigest {
    $script:ArchiveDigest = 'sha256:' + (Get-FileHash $script:ArchivePath -Algorithm SHA256).Hash.ToLowerInvariant()
    $script:Manifest.targets[0].units[0].artifact.sha256 = $script:ArchiveDigest
    $script:Manifest | ConvertTo-Json -Depth 12 | Set-Content $script:ManifestPath -Encoding utf8
    $script:Release.assets[0].digest = 'sha256:' + (Get-FileHash $script:ManifestPath -Algorithm SHA256).Hash.ToLowerInvariant()
    $script:Release.assets[1].digest = $script:ArchiveDigest
  }
}

Describe 'Accepted immutable candidate installer source' {
  BeforeEach {
    $script:Directory = Join-Path $TestDrive ([guid]::NewGuid().ToString('N'))
    New-Item -ItemType Directory $script:Directory | Out-Null
    $script:SourceDir = Join-Path $script:Directory 'source'
    New-Item -ItemType Directory $script:SourceDir | Out-Null
    $script:ArchivePath = Join-Path $script:Directory 'bundle.zip'
    $script:ManifestPath = Join-Path $script:Directory 'accepted.json'
    $script:Repository = 'elanthia-online/Ruby4Lich5'
    $script:Tag = 'R4L5-gem-bundle-x64-mingw-ucrt-candidate-12345-1'
    $script:ZipName = 'R4L5-gem-bundle-x64-mingw-ucrt.zip'
    $script:Url = "https://github.com/$script:Repository/releases/download/$script:Tag/$script:ZipName"
    foreach ($fixtureFile in @('example-1.0.gem', 'runtime-gems-manifest.txt', 'runtime-gems-install-targets.txt')) {
      Set-Content (Join-Path $script:SourceDir $fixtureFile) 'example-1.0.gem'
    }
    Set-Content (Join-Path $script:SourceDir 'install-runtime-gems.cmd') '@echo off'
    Set-Content (Join-Path $script:SourceDir 'resolution-lock.json') '{}'
    New-GemBundleMetadata -Directory $script:SourceDir -Repository $script:Repository -RunId '12345' -RunAttempt 1 `
      -SourceSha ('a' * 40) -RubyInstallerVersion '4.0.9-1' -RubyArchiveDigest ('sha256:' + ('b' * 64))
    $script:Manifest = [pscustomobject]@{ schema = 1; targets = @([pscustomobject]@{
      ruby_abi = '4.0'; platform = 'x64-mingw-ucrt'; units = @([pscustomobject]@{
        artifact = [pscustomobject]@{ archive = 'zip'; filename = $script:ZipName; url = $script:Url; sha256 = '' }
      })
    }) }
    $script:Release = [pscustomobject]@{
      tag_name = $script:Tag; draft = $false; target_commitish = ('a' * 40)
      html_url = "https://github.com/$script:Repository/releases/tag/$script:Tag"
      assets = @(
        [pscustomobject]@{ name = 'R4L5-gem-manifest.json'; digest = '' }
        [pscustomobject]@{ name = $script:ZipName; digest = ''; browser_download_url = $script:Url }
      )
    }
    Sync-CandidateFixture
    $script:CandidateReadArgs = @{
      Release = $script:Release; AcceptedManifestPath = $script:ManifestPath; Repository = $script:Repository; Tag = $script:Tag
      ArchivePath = $script:ArchivePath; Directory = (Join-Path $script:Directory 'extracted'); RubySeries = '4.0'
    }
  }

  It 'rebuilds from the accepted candidate without Actions run or artifact availability' {
    $result = Read-AcceptedGemCandidate @script:CandidateReadArgs
    $result.run_id | Should -Be '12345'
    $result.run_attempt | Should -Be 1
    $result.source_sha | Should -Be ('a' * 40)
    $result.ruby_installer_version | Should -Be '4.0.9-1'
    Test-Path (Join-Path $script:CandidateReadArgs.Directory 'example-1.0.gem') | Should -BeTrue
  }
  It 'rejects mutable or malformed tag <Tag>' -TestCases @(
    @{ Tag = 'R4L5-gem-bundle-x64-mingw-ucrt' }; @{ Tag = 'latest' }; @{ Tag = 'candidate/../../elsewhere' }
  ) {
    param($Tag)
    $script:CandidateReadArgs.Tag = $Tag
    { Read-AcceptedGemCandidate @script:CandidateReadArgs } | Should -Throw '*exact immutable candidate*'
  }
  It 'rejects a foreign release even with a matching filename and digest' {
    $script:Release.html_url = 'https://github.com/other/repo/releases/tag/anything'
    { Read-AcceptedGemCandidate @script:CandidateReadArgs } | Should -Throw '*release identity*'
  }
  It 'rejects draft, branch-target and wrong-tag identities: <Field>' -TestCases @(
    @{ Field = 'draft'; Value = $true }; @{ Field = 'target_commitish'; Value = 'main' }; @{ Field = 'tag_name'; Value = 'other' }
  ) {
    param($Field, $Value)
    $script:Release.$Field = $Value
    { Read-AcceptedGemCandidate @script:CandidateReadArgs } | Should -Throw '*release identity*'
  }
  It 'rejects a candidate not matching the exact accepted manifest bytes' {
    Add-Content $script:ManifestPath ' '
    { Read-AcceptedGemCandidate @script:CandidateReadArgs } | Should -Throw '*currently accepted manifest*'
  }
  It 'rejects a bundle URL outside the selected repository/tag' {
    $script:Release.assets[1].browser_download_url = 'https://example.test/other.zip'
    { Read-AcceptedGemCandidate @script:CandidateReadArgs } | Should -Throw '*exact bundle identity*'
  }
  It 'rejects missing or duplicate candidate assets' -TestCases @(@{ Duplicate = $false }; @{ Duplicate = $true }) {
    param($Duplicate)
    if ($Duplicate) { $script:Release.assets += $script:Release.assets[1] }
    else { $script:Release.assets = @($script:Release.assets[0]) }
    { Read-AcceptedGemCandidate @script:CandidateReadArgs } | Should -Throw '*exact bundle identity*'
  }
  It 'requires an accepted manifest reference binding the selected ZIP digest' {
    $script:Manifest.targets[0].units[0].artifact.sha256 = 'sha256:' + ('0' * 64)
    $script:Manifest | ConvertTo-Json -Depth 12 | Set-Content $script:ManifestPath
    $script:Release.assets[0].digest = 'sha256:' + (Get-FileHash $script:ManifestPath -Algorithm SHA256).Hash.ToLowerInvariant()
    { Read-AcceptedGemCandidate @script:CandidateReadArgs } | Should -Throw '*does not bind*'
  }
  It 'rejects changed archive bytes before extraction' {
    Add-Content $script:ArchivePath 'changed'
    { Read-AcceptedGemCandidate @script:CandidateReadArgs } | Should -Throw '*archive checksum*'
    Test-Path $script:CandidateReadArgs.Directory | Should -BeFalse
  }
  It 'retains metadata identity and exact RubyInstaller checks: <Field>' -TestCases @(
    @{ Field = 'repository'; Value = 'someone/else' }; @{ Field = 'run_id'; Value = '999' }
    @{ Field = 'run_attempt'; Value = 2 }; @{ Field = 'source_sha'; Value = ('c' * 40) }
    @{ Field = 'ruby_installer_version'; Value = '4.1.0-1' }; @{ Field = 'ruby_archive_digest'; Value = 'invalid' }
  ) {
    param($Field, $Value)
    $path = Join-Path $script:SourceDir 'gem-build-metadata.json'
    $data = Get-Content $path -Raw | ConvertFrom-Json
    $data.$Field = $Value
    $data | ConvertTo-Json -Depth 6 | Set-Content $path
    Sync-CandidateFixture
    { Read-AcceptedGemCandidate @script:CandidateReadArgs } | Should -Throw
  }
  It 'retains per-file checksum verification within a valid candidate ZIP' {
    Add-Content (Join-Path $script:SourceDir 'example-1.0.gem') 'modified'
    Sync-CandidateFixture
    { Read-AcceptedGemCandidate @script:CandidateReadArgs } | Should -Throw '*checksum mismatch*'
  }
  It 'rejects unlisted bundle contents even when the accepted ZIP matches' {
    Set-Content (Join-Path $script:SourceDir 'extra.gem') 'unchecked'
    Sync-CandidateFixture
    { Read-AcceptedGemCandidate @script:CandidateReadArgs } | Should -Throw '*unlisted*'
  }
  It 'rejects unsafe ZIP names before writing any entry: <Name>' -TestCases @(
    @{ Name = '../escape.gem' }; @{ Name = 'nested/file.gem' }; @{ Name = 'EXAMPLE-1.0.GEM' }
  ) {
    param($Name)
    $zip = [IO.Compression.ZipFile]::Open($script:ArchivePath, [IO.Compression.ZipArchiveMode]::Update)
    try { $null = $zip.CreateEntry($Name) } finally { $zip.Dispose() }
    Update-CandidateFixtureDigest
    { Read-AcceptedGemCandidate @script:CandidateReadArgs } | Should -Throw '*unsafe, duplicate or linked*'
    Test-Path $script:CandidateReadArgs.Directory | Should -BeFalse
  }
}
