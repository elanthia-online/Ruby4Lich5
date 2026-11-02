Describe 'Immutable frozen GTK archive preparation' {
  BeforeAll {
    . "$PSScriptRoot/../../frozen-gtk.ps1"
    function Invoke-FixtureFrozenRuby {
      param($ScriptPath, $ManifestPath, $Packages, $Prepared)
      $doc = Get-Content $ManifestPath -Raw | ConvertFrom-Json
      $unit = $doc.targets[0].units[0]
      New-Item -ItemType Directory -Path (Join-Path $Prepared 'pkg') -Force | Out-Null
      foreach ($package in $unit.packages) {
        Copy-Item (Join-Path $Packages $package.filename) (Join-Path (Join-Path $Prepared 'pkg') $package.filename)
      }
      $unit | ConvertTo-Json -Depth 20 | Set-Content (Join-Path $Prepared 'unit.json') -Encoding ascii
      $global:LASTEXITCODE = 0
    }
  }
  BeforeEach {
    $source = Join-Path $TestDrive 'source'
    $candidate = Join-Path $TestDrive 'candidate'
    New-Item -ItemType Directory -Path $source, $candidate -Force | Out-Null
    [IO.File]::WriteAllText((Join-Path $source 'gtk3-1.0.gem'), 'published GTK bytes')
    [IO.File]::WriteAllText((Join-Path $source 'red-colors-1.0.gem'), 'published pure closure bytes')
    [IO.File]::WriteAllText((Join-Path $source 'unrelated.gem'), 'not in frozen closure')
    $published = Join-Path $TestDrive 'published.zip'
    Compress-Archive -Path (Join-Path $source '*') -DestinationPath $published -Force
    $manifest = Join-Path $TestDrive 'manifest.json'
    @{ schema = 1; targets = @(@{ ruby_abi = '4.0'; platform = 'x64-mingw-ucrt'; units = @(@{
      id = 'gtk3-runtime'; members = @('red-colors', 'gtk3'); install_order = @('red-colors', 'gtk3')
      packages = @(@{ name = 'red-colors'; filename = 'red-colors-1.0.gem' }, @{ name = 'gtk3'; filename = 'gtk3-1.0.gem' })
      artifact = @{ url = 'https://example.test/published.zip'; archive = 'zip'; sha256 = 'sha256:' + ('a' * 64) }
    }) }) } | ConvertTo-Json -Depth 20 | Set-Content $manifest -Encoding ascii
    Mock Invoke-VerifiedDownload { Copy-Item $published $DestinationPath }
  }
  It 'copies the complete selected closure and refuses to overwrite its output' {
    $freezeArgs = @{ ManifestPath = $manifest; CandidateDirectory = $candidate; Repository = 'fixture/repo'; CandidateTag = 'R4L5-gem-bundle-x64-mingw-ucrt-candidate-123-1'; Ruby = 'Invoke-FixtureFrozenRuby' }
    $unit = New-FrozenGtkClosure @freezeArgs -WorkDirectory (Join-Path $TestDrive 'work')
    $unit.members | Should -Be @('red-colors', 'gtk3')
    $zip = [IO.Compression.ZipFile]::OpenRead((Join-Path $candidate $unit.artifact.filename))
    try { @($zip.Entries.FullName | Sort-Object) | Should -Be @('gtk3-1.0.gem', 'red-colors-1.0.gem') } finally { $zip.Dispose() }
    $unit.artifact.url | Should -Be "https://github.com/fixture/repo/releases/download/R4L5-gem-bundle-x64-mingw-ucrt-candidate-123-1/$($unit.artifact.filename)"
    { New-FrozenGtkClosure @freezeArgs -WorkDirectory (Join-Path $TestDrive 'retry') } | Should -Throw '*never overwrite*'
  }
  It 'rejects nested ZIP entries before extracting published content' {
    New-Item -ItemType Directory (Join-Path $source 'nested') | Out-Null
    [IO.File]::WriteAllText((Join-Path $source 'nested/unsafe.gem'), 'bad')
    Compress-Archive -Path (Join-Path $source '*') -DestinationPath $published -Force
    { New-FrozenGtkClosure -ManifestPath $manifest -WorkDirectory (Join-Path $TestDrive 'unsafe') -CandidateDirectory $candidate -Repository 'fixture/repo' -CandidateTag 'R4L5-gem-bundle-x64-mingw-ucrt-candidate-123-1' -Ruby 'Invoke-FixtureFrozenRuby' } | Should -Throw '*Unsafe or duplicate*'
  }
}
