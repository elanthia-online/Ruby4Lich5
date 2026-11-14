BeforeAll {
  . "$PSScriptRoot/../../platform-table.ps1"
  $script:Root = (Resolve-Path (Join-Path $PSScriptRoot '../..')).Path
  $script:RealTable = Join-Path (Join-Path $script:Root 'config') 'platforms.json'
  # spec/support/x64_platform_snapshot.rb CANDIDATE_TAGS with the acceptance R1
  # recorded in spec/fixtures/platform-table/x64-snapshot.json; the Ruby
  # agreement test below proves this list still equals that snapshot.
  $script:CandidateTags = @(
    [pscustomobject]@{ Tag = 'R4L5-gem-bundle-x64-mingw-ucrt-candidate-1-1'; Accepted = $true }
    [pscustomobject]@{ Tag = 'R4L5-gem-bundle-x64-mingw-ucrt-candidate-123-45'; Accepted = $true }
    [pscustomobject]@{ Tag = 'R4L5-gem-bundle-x64-mingw-ucrt-candidate-0-1'; Accepted = $false }
    [pscustomobject]@{ Tag = 'R4L5-gem-bundle-x64-mingw-ucrt-candidate-1-0'; Accepted = $false }
    [pscustomobject]@{ Tag = 'R4L5-gem-bundle-x64-mingw-ucrt-candidate-1'; Accepted = $false }
    [pscustomobject]@{ Tag = 'R4L5-gem-bundle-x64-mingw-ucrt'; Accepted = $false }
    [pscustomobject]@{ Tag = 'R4L5-gem-bundle-x64-mingw-ucrtXcandidate-1-1'; Accepted = $false }
    [pscustomobject]@{ Tag = 'R4L5-gem-bundle-aarch64-mingw-ucrt-candidate-1-1'; Accepted = $false }
    [pscustomobject]@{ Tag = 'R4L5-gem-bundle-x64-mingw32-candidate-1-1'; Accepted = $false }
    [pscustomobject]@{ Tag = 'r4l5-gem-bundle-x64-mingw-ucrt-candidate-1-1'; Accepted = $false }
    [pscustomobject]@{ Tag = 'R4L5-gem-bundle-x64-mingw-ucrt-candidate-1-1-extra'; Accepted = $false }
  )

  # PowerShell turns $null into '' for .NET string arguments, so restore with
  # Remove-Item: an empty GEM_PLATFORM is "present" (and rejected) off Windows.
  function Set-GemPlatform {
    param([string]$Value)
    if ($null -eq $Value -or $Value.Length -eq 0) { Remove-Item Env:GEM_PLATFORM -ErrorAction SilentlyContinue }
    else { $env:GEM_PLATFORM = $Value }
  }

  function Get-X64Entry { (Get-Content $script:RealTable -Raw | ConvertFrom-Json).platforms.'x64-mingw-ucrt' }

  # A synthetic second row, as in target_platform_spec.rb: proves selection by
  # key without shipping values for a real second platform.
  function Get-DemoEntry {
    $entry = Get-X64Entry
    $entry.rubyinstaller_asset_suffix = 'demo'; $entry.runner = 'demo-runner'; $entry.msystem = 'DEMO64'
    $entry.msys2_prefix = 'demo64'; $entry.msys2_package_prefix = 'mingw-w64-demo'
    $entry.gem_bundle_tag = 'R4L5-gem-bundle-demo-mingw-ucrt'
    $entry.msys2_bootstrap_packages = @('base-devel', 'mingw-w64-demo-cc')
    return $entry
  }

  function Write-Fixture {
    param([string]$Name, $Document)
    $path = Join-Path $TestDrive $Name
    if ($Document -isnot [string]) { $Document = $Document | ConvertTo-Json -Depth 10 }
    [IO.File]::WriteAllText($path, $Document, (New-Object Text.UTF8Encoding($false)))
    return $path
  }

  function Write-Table {
    param($Platforms)
    if ($null -eq $Platforms) { $Platforms = [ordered]@{ 'x64-mingw-ucrt' = (Get-X64Entry); 'demo-mingw-ucrt' = (Get-DemoEntry) } }
    return Write-Fixture 'platforms.json' ([ordered]@{ schema = 1; platforms = $Platforms })
  }

  function Write-Target {
    param([string]$Platform = 'x64-mingw-ucrt')
    return Write-Fixture 'target-ruby.json' ([ordered]@{ schema = 1; platform = $Platform })
  }
}

Describe 'Get-TargetPlatform selection' {
  BeforeEach {
    $script:PreviousGemPlatform = $env:GEM_PLATFORM
    Set-GemPlatform $null
  }
  AfterEach { Set-GemPlatform $script:PreviousGemPlatform }

  It 'defaults to x64-mingw-ucrt from the real checked-in configuration, independent of the working directory' {
    Push-Location $TestDrive
    try { $selected = Get-TargetPlatform } finally { Pop-Location }
    $selected.name | Should -BeExactly 'x64-mingw-ucrt'
    $selected.gem_bundle_tag | Should -BeExactly 'R4L5-gem-bundle-x64-mingw-ucrt'
    $selected.rubyinstaller_asset_suffix | Should -BeExactly 'x64'
    $selected.msystem | Should -BeExactly 'UCRT64'
    $selected.msys2_prefix | Should -BeExactly 'ucrt64'
    $selected.msys2_package_prefix | Should -BeExactly 'mingw-w64-ucrt-x86_64'
    $selected.toolchain.make | Should -BeExactly 'mingw32-make.exe'
    $selected.msys2_bootstrap_packages[0] | Should -BeExactly 'base-devel'
    $selected.candidate_tag_pattern | Should -BeExactly '\AR4L5-gem-bundle-x64-mingw-ucrt-candidate-([1-9][0-9]*)-([1-9][0-9]*)\z'
  }

  It 'falls back to target-ruby.json when neither -Platform nor GEM_PLATFORM is given' {
    (Get-TargetPlatform -TablePath (Write-Table) -TargetPath (Write-Target 'demo-mingw-ucrt')).name | Should -BeExactly 'demo-mingw-ucrt'
  }

  It 'honors GEM_PLATFORM over target-ruby.json' {
    $env:GEM_PLATFORM = 'demo-mingw-ucrt'
    (Get-TargetPlatform -TablePath (Write-Table) -TargetPath (Write-Target)).name | Should -BeExactly 'demo-mingw-ucrt'
  }

  It 'honors an explicit -Platform over GEM_PLATFORM' {
    $env:GEM_PLATFORM = 'demo-mingw-ucrt'
    (Get-TargetPlatform -Platform 'x64-mingw-ucrt' -TablePath (Write-Table) -TargetPath (Write-Target)).name | Should -BeExactly 'x64-mingw-ucrt'
  }

  It 'returns the row values for the selected platform' {
    $selected = Get-TargetPlatform -Platform 'demo-mingw-ucrt' -TablePath (Write-Table) -TargetPath (Write-Target)
    $selected.msystem | Should -BeExactly 'DEMO64'
    @($selected.msys2_bootstrap_packages) -join ',' | Should -BeExactly 'base-devel,mingw-w64-demo-cc'
    'R4L5-gem-bundle-demo-mingw-ucrt-candidate-1-1' | Should -MatchExactly $selected.candidate_tag_pattern
    'R4L5-gem-bundle-x64-mingw-ucrt-candidate-1-1' | Should -Not -MatchExactly $selected.candidate_tag_pattern
  }

  It 'rejects an unknown platform rather than falling back' {
    { Get-TargetPlatform -Platform 'aarch64-mingw-ucrt' -TablePath (Write-Table) -TargetPath (Write-Target) } |
      Should -Throw '*unknown platform "aarch64-mingw-ucrt"*'
    $env:GEM_PLATFORM = 'x86-mingw32'
    { Get-TargetPlatform } | Should -Throw '*unknown platform "x86-mingw32"*'
    Set-GemPlatform $null
    { Get-TargetPlatform -TablePath (Write-Table) -TargetPath (Write-Target 'x86-mingw32') } | Should -Throw '*unknown platform*'
  }

  It 'matches platform names case-sensitively' {
    { Get-TargetPlatform -Platform 'X64-MINGW-UCRT' } | Should -Throw '*unknown platform "X64-MINGW-UCRT"*'
  }

  # Windows deletes a variable assigned '', so "set but empty" is covered by -Platform ''.
  It 'rejects a blank or unsafe selection instead of treating it as unset' {
    { Get-TargetPlatform -Platform '' } | Should -Throw '*must not be nil or empty*'
    $env:GEM_PLATFORM = '  '
    { Get-TargetPlatform } | Should -Throw '*must not be nil or empty*'
    $env:GEM_PLATFORM = '../x64'
    { Get-TargetPlatform } | Should -Throw '*disallowed characters*'
    $env:GEM_PLATFORM = '..'
    { Get-TargetPlatform } | Should -Throw '*disallowed characters*'
  }

  It 'rejects a target-ruby.json without a platform' {
    { Get-TargetPlatform -TablePath (Write-Table) -TargetPath (Write-Fixture 'target-ruby.json' '{"schema":1}') } | Should -Throw '*has no platform*'
  }
}

Describe 'Read-PlatformTable validation' {
  It 'rejects <Case>' -ForEach @(
    @{ Case = 'malformed JSON'; Mutate = { 'not json' }; Message = '*malformed platform table JSON*' }
    @{ Case = 'another schema version'; Mutate = { '{"schema":2,"platforms":{}}' }; Message = '*with schema 1*' }
    @{ Case = 'a string schema'; Mutate = { '{"schema":"1","platforms":{}}' }; Message = '*with schema 1*' }
    @{ Case = 'a boolean schema'; Mutate = { '{"schema":true,"platforms":{}}' }; Message = '*with schema 1*' }
    @{ Case = 'an extra top-level key'; Mutate = { '{"schema":1,"platforms":{},"extra":1}' }; Message = '*must contain exactly*' }
    @{ Case = 'a top-level array'; Mutate = { '[1]' }; Message = '*must contain exactly*' }
    @{ Case = 'empty platforms'; Mutate = { '{"schema":1,"platforms":{}}' }; Message = '*platforms must be a non-empty object*' }
    @{ Case = 'a missing row key'; Mutate = { param($e) $e.PSObject.Properties.Remove('runner') }; Message = '*must define exactly*' }
    @{ Case = 'an extra row key'; Mutate = { param($e) $e | Add-Member -NotePropertyName extra -NotePropertyValue 'x' }; Message = '*must define exactly*' }
    @{ Case = 'a differently cased row key'; Mutate = { param($e) $e.PSObject.Properties.Remove('runner'); $e | Add-Member -NotePropertyName Runner -NotePropertyValue 'windows-latest' }; Message = '*must define exactly*' }
    @{ Case = 'a non-string token'; Mutate = { param($e) $e.msystem = 64 }; Message = '*msystem must be a String*' }
    @{ Case = 'an unsafe token'; Mutate = { param($e) $e.runner = 'windows latest' }; Message = '*runner contains disallowed characters*' }
    @{ Case = 'a gem_bundle_tag not named for the platform'; Mutate = { param($e) $e.gem_bundle_tag = 'R4L5-gem-bundle-x64-mingw32' }; Message = '*gem_bundle_tag must be R4L5-gem-bundle-x64-mingw-ucrt*' }
    @{ Case = 'empty bootstrap packages'; Mutate = { param($e) $e.msys2_bootstrap_packages = @() }; Message = '*must be a non-empty array*' }
    @{ Case = 'a scalar bootstrap package list'; Mutate = { param($e) $e.msys2_bootstrap_packages = 'base-devel' }; Message = '*must be a non-empty array*' }
    @{ Case = 'a repeated bootstrap package'; Mutate = { param($e) $e.msys2_bootstrap_packages = @('make', 'make') }; Message = '*must not repeat a package*' }
    @{ Case = 'another MSYS2 environment package'; Mutate = { param($e) $e.msys2_bootstrap_packages = @('make', 'mingw-w64-x86_64-gcc') }; Message = '*name another MSYS2 environment*' }
    @{ Case = 'a missing toolchain key'; Mutate = { param($e) $e.toolchain.PSObject.Properties.Remove('objdump') }; Message = '*toolchain must define exactly*' }
    @{ Case = 'a non-object toolchain'; Mutate = { param($e) $e.toolchain = 'gcc.exe' }; Message = '*toolchain must define exactly*' }
    @{ Case = 'an unsafe toolchain value'; Mutate = { param($e) $e.toolchain.cc = '../gcc.exe' }; Message = '*toolchain cc contains disallowed characters*' }
  ) {
    $entry = Get-X64Entry
    $document = & $Mutate $entry
    if ($document -isnot [string]) {
      $document = [ordered]@{ schema = 1; platforms = [ordered]@{ 'x64-mingw-ucrt' = $entry } } | ConvertTo-Json -Depth 10
    }
    { Read-PlatformTable -Path (Write-Fixture 'platforms.json' $document) } | Should -Throw $Message
  }

  It 'rejects an unsafe platform name' {
    $document = [ordered]@{ schema = 1; platforms = [ordered]@{ 'x64 mingw' = (Get-X64Entry) } } | ConvertTo-Json -Depth 10
    { Read-PlatformTable -Path (Write-Fixture 'platforms.json' $document) } | Should -Throw '*platform name contains disallowed characters*'
  }

  It 'accepts the checked-in table' {
    @((Read-PlatformTable).Keys) | Should -Be @('x64-mingw-ucrt', 'aarch64-mingw-ucrt')
  }

  It 'fails x64 selection too when any row is malformed' {
    $real = Get-Content $script:RealTable -Raw | ConvertFrom-Json
    $arm = $real.platforms.'aarch64-mingw-ucrt'
    $arm.PSObject.Properties.Remove('runner')
    $path = Write-Table ([ordered]@{ 'x64-mingw-ucrt' = $real.platforms.'x64-mingw-ucrt'; 'aarch64-mingw-ucrt' = $arm })
    { Get-TargetPlatform -Platform 'x64-mingw-ucrt' -TablePath $path -TargetPath (Write-Target) } | Should -Throw '*platform aarch64-mingw-ucrt must define exactly*'
  }
}

# Every selection validates every row, so the real aarch64 row is on the x64
# path: the two-row table still defaults to x64 with every x64 value unchanged.
Describe 'the checked-in two-row table' {
  BeforeEach {
    $script:PreviousGemPlatform = $env:GEM_PLATFORM
    Set-GemPlatform $null
  }
  AfterEach { Set-GemPlatform $script:PreviousGemPlatform }

  It 'still selects x64 by default and by name, with every x64 value unchanged' {
    foreach ($selected in @((Get-TargetPlatform), (Get-TargetPlatform -Platform 'x64-mingw-ucrt'))) {
      $selected.name | Should -BeExactly 'x64-mingw-ucrt'
      $selected.rubyinstaller_asset_suffix | Should -BeExactly 'x64'
      $selected.runner | Should -BeExactly 'windows-latest'
      $selected.msystem | Should -BeExactly 'UCRT64'
      $selected.msys2_prefix | Should -BeExactly 'ucrt64'
      $selected.msys2_package_prefix | Should -BeExactly 'mingw-w64-ucrt-x86_64'
      @($selected.msys2_bootstrap_packages) -join ',' | Should -BeExactly ('base-devel,make,mingw-w64-ucrt-x86_64-gcc,mingw-w64-ucrt-x86_64-gcc-libs,' +
        'mingw-w64-ucrt-x86_64-binutils,mingw-w64-ucrt-x86_64-make,mingw-w64-ucrt-x86_64-pkgconf,mingw-w64-ucrt-x86_64-libffi')
      (@('cc', 'make', 'pkg_config', 'objdump') | ForEach-Object { $selected.toolchain.$_ }) -join ',' | Should -BeExactly 'gcc.exe,mingw32-make.exe,pkg-config.exe,objdump.exe'
      $selected.gem_bundle_tag | Should -BeExactly 'R4L5-gem-bundle-x64-mingw-ucrt'
      $selected.candidate_tag_pattern | Should -BeExactly '\AR4L5-gem-bundle-x64-mingw-ucrt-candidate-([1-9][0-9]*)-([1-9][0-9]*)\z'
    }
  }

  It 'selects the aarch64 row only when asked, with the clangarm64 toolchain' {
    $env:GEM_PLATFORM = 'aarch64-mingw-ucrt'
    foreach ($selected in @((Get-TargetPlatform), (Get-TargetPlatform -Platform 'aarch64-mingw-ucrt'))) {
      $selected.name | Should -BeExactly 'aarch64-mingw-ucrt'
      $selected.rubyinstaller_asset_suffix | Should -BeExactly 'arm'
      $selected.runner | Should -BeExactly 'windows-11-arm'
      $selected.msystem | Should -BeExactly 'CLANGARM64'
      $selected.msys2_prefix | Should -BeExactly 'clangarm64'
      $selected.msys2_package_prefix | Should -BeExactly 'mingw-w64-clang-aarch64'
      @($selected.msys2_bootstrap_packages) -join ',' | Should -BeExactly ('base-devel,make,mingw-w64-clang-aarch64-clang,mingw-w64-clang-aarch64-llvm-tools,' +
        'mingw-w64-clang-aarch64-make,mingw-w64-clang-aarch64-pkgconf,mingw-w64-clang-aarch64-libffi')
      (@('cc', 'make', 'pkg_config', 'objdump') | ForEach-Object { $selected.toolchain.$_ }) -join ',' | Should -BeExactly 'clang.exe,mingw32-make.exe,pkg-config.exe,llvm-objdump.exe'
      $selected.gem_bundle_tag | Should -BeExactly 'R4L5-gem-bundle-aarch64-mingw-ucrt'
      'R4L5-gem-bundle-aarch64-mingw-ucrt-candidate-1-1' | Should -MatchExactly $selected.candidate_tag_pattern
      'R4L5-gem-bundle-x64-mingw-ucrt-candidate-1-1' | Should -Not -MatchExactly $selected.candidate_tag_pattern
    }
  }
}

Describe 'candidate tag pattern' {
  BeforeAll {
    $previous = $env:GEM_PLATFORM
    Set-GemPlatform $null
    try { $script:Pattern = (Get-TargetPlatform).candidate_tag_pattern } finally { Set-GemPlatform $previous }
  }

  It 'accepts and rejects the eleven snapshot tags exactly as the Ruby snapshot records' {
    $script:CandidateTags.Count | Should -Be 11
    foreach ($case in $script:CandidateTags) {
      ($case.Tag -cmatch $script:Pattern) | Should -Be $case.Accepted -Because $case.Tag
    }
  }

  It 'rejects a trailing newline and non-ASCII digits' {
    "R4L5-gem-bundle-x64-mingw-ucrt-candidate-1-1`n" | Should -Not -MatchExactly $script:Pattern
    ('R4L5-gem-bundle-x64-mingw-ucrt-candidate-1-1' + [char]0x0661) | Should -Not -MatchExactly $script:Pattern
  }

  It 'agrees with Ruby TargetPlatform.current.candidate_tag_pattern on the same tags' {
    $tags = @($script:CandidateTags | ForEach-Object { $_.Tag }) + @(
      "R4L5-gem-bundle-x64-mingw-ucrt-candidate-1-1`n",
      ('R4L5-gem-bundle-x64-mingw-ucrt-candidate-1-1' + [char]0x0661),
      ('R4L5-gem-bundle-x64-mingw-ucrt-candidate-' + [char]0x0661 + '-1')
    )
    $tagsPath = Join-Path $TestDrive 'tags.json'
    [IO.File]::WriteAllText($tagsPath, (ConvertTo-Json -InputObject $tags -Compress), (New-Object Text.UTF8Encoding($false)))
    $previous = $env:GEM_PLATFORM
    Set-GemPlatform $null
    try {
      $output = & ruby -I (Join-Path $script:Root 'lib') (Join-Path $PSScriptRoot 'fixtures/platform-candidate-tags.rb') $tagsPath 2>&1
      $result = $LASTEXITCODE
    } finally { Set-GemPlatform $previous }
    $result | Should -Be 0 -Because ($output -join "`n")
    # Enumerate: Windows PowerShell 5.1 emits a JSON array as one object.
    $report = ($output -join "`n") | ConvertFrom-Json
    $snapshot = @($report.snapshot | ForEach-Object { , $_ })
    $snapshot.Count | Should -Be $script:CandidateTags.Count
    for ($i = 0; $i -lt $snapshot.Count; $i++) {
      $snapshot[$i][0] | Should -BeExactly $script:CandidateTags[$i].Tag
      $snapshot[$i][1] | Should -Be $script:CandidateTags[$i].Accepted -Because $snapshot[$i][0]
    }
    $accepts = @($report.accepts)
    $accepts.Count | Should -Be $tags.Count
    for ($i = 0; $i -lt $tags.Count; $i++) {
      ($tags[$i] -cmatch $script:Pattern) | Should -Be $accepts[$i] -Because $tags[$i]
    }
  }
}

# Each converted helper reads its tag, zip name and platform from the selected
# row: with a synthetic row selected, x64 identities are refused and the
# synthetic ones are used.
Describe 'scripts follow the selected platform' {
  BeforeAll {
    foreach ($name in @('accepted-gem-manifest', 'gem-candidate-bundle', 'gem-manifest-promotion', 'prepare-gem-promotion', 'frozen-gtk')) {
      . (Join-Path $script:Root "$name.ps1")
    }
    $script:Demo = ConvertTo-TargetPlatformRow -Name 'demo-mingw-ucrt' -Entry (Get-DemoEntry)
  }
  BeforeEach { Mock Get-TargetPlatform { $script:Demo } }

  It 'rejects x64 candidate tags in every candidate validator' {
    $x64 = 'R4L5-gem-bundle-x64-mingw-ucrt-candidate-1-1'
    { Publish-ImmutableGemCandidate -Directory $TestDrive -Repository 'o/r' -Tag $x64 -SourceSha ('a' * 40) } | Should -Throw 'Candidate publication requires*'
    { Resolve-AcceptedGemCandidate -Release @{} -AcceptedManifestPath 'x' -Repository 'o/r' -Tag $x64 } | Should -Throw 'Retained source requires*'
    { Prepare-GemPromotion -Directory (Join-Path $TestDrive 'p') -Repository 'o/r' -CandidateTag $x64 } | Should -Throw 'Invalid candidate or repository.'
    { New-FrozenGtkClosure -ManifestPath 'x' -WorkDirectory 'w' -CandidateDirectory 'c' -Repository 'o/r' -CandidateTag $x64 } | Should -Throw 'Invalid frozen closure candidate identity.'
  }

  It 'requires the selected platform bundle name when publishing' {
    $directory = Join-Path $TestDrive 'publish'
    New-Item -ItemType Directory -Path $directory | Out-Null
    foreach ($name in @('R4L5-gem-manifest.json', 'R4L5-gem-bundle-x64-mingw-ucrt.zip')) { Set-Content (Join-Path $directory $name) $name }
    { Publish-ImmutableGemCandidate -Directory $directory -Repository 'o/r' -Tag 'R4L5-gem-bundle-demo-mingw-ucrt-candidate-1-1' -SourceSha ('a' * 40) } |
      Should -Throw 'Candidate must include the consumer-named manifest and bundle.'
  }

  It 'reads the selected platform live release' {
    Mock Invoke-PromotionGh { '{"assets":[]}' }
    Get-LiveGemManifestDigest -Repository 'o/r' | Should -BeNullOrEmpty
    Should -Invoke Invoke-PromotionGh -Times 1 -Exactly -ParameterFilter { $Arguments[2] -ceq 'R4L5-gem-bundle-demo-mingw-ucrt' }
    Mock Invoke-CandidateGh { '{"tag_name":"R4L5-gem-bundle-demo-mingw-ucrt","draft":false,"assets":[]}' }
    { Read-LiveAcceptedGemManifest -Repository 'o/r' -DestinationPath (Join-Path $TestDrive 'a.json') } | Should -Throw 'Missing exact published accepted manifest identity.'
    Should -Invoke Invoke-CandidateGh -Times 1 -Exactly -ParameterFilter { $Arguments[1] -ceq 'repos/o/r/releases/tags/R4L5-gem-bundle-demo-mingw-ucrt' }
  }

  It 'records and requires the selected platform in bundle metadata' {
    $directory = Join-Path $TestDrive 'bundle'
    New-Item -ItemType Directory -Path $directory | Out-Null
    New-GemBundleMetadata -Directory $directory -Repository 'o/r' -RunId '1' -RunAttempt 1 -SourceSha ('a' * 40) -RubyInstallerVersion '4.0.9-1' -RubyArchiveDigest ('sha256:' + 'b' * 64)
    (Get-Content (Join-Path $directory 'gem-build-metadata.json') -Raw | ConvertFrom-Json).platform | Should -BeExactly 'demo-mingw-ucrt'
    # Positive control: the same row passes the identity check and fails later.
    { Read-VerifiedGemBundleFiles -Directory $directory -Repository 'o/r' -RunId '1' -RunAttempt 1 -SourceSha ('a' * 40) -RubySeries '4.0' } |
      Should -Throw 'Gem artifact is missing required inventory*'
    Mock Get-TargetPlatform { ConvertTo-TargetPlatformRow -Name 'x64-mingw-ucrt' -Entry (Get-X64Entry) }
    { Read-VerifiedGemBundleFiles -Directory $directory -Repository 'o/r' -RunId '1' -RunAttempt 1 -SourceSha ('a' * 40) -RubySeries '4.0' } |
      Should -Throw 'Gem artifact identity does not match the selected run, source revision, or platform.'
  }
}

# Positive cases with the synthetic row selected. Each call succeeds only if
# every converted value (ZIP name, target filter, live tag, readback URL,
# expected candidate tag) takes the demo row's value, so an x64 literal left
# in any of them turns a case red. The x64 tests cover the same lines with
# the real row.
Describe 'converted scripts succeed with a demo row selected' {
  BeforeAll {
    foreach ($name in @('gem-candidate-bundle', 'gem-manifest-promotion', 'prepare-gem-promotion', 'frozen-gtk')) {
      . (Join-Path $script:Root "$name.ps1")
    }
    $script:Demo = ConvertTo-TargetPlatformRow -Name 'demo-mingw-ucrt' -Entry (Get-DemoEntry)
    $script:DemoCandidate = 'R4L5-gem-bundle-demo-mingw-ucrt-candidate-123-1'
    $script:DemoZip = 'R4L5-gem-bundle-demo-mingw-ucrt.zip'
    function Get-FixtureDigest { param([string]$Path) 'sha256:' + (Get-FileHash -LiteralPath $Path -Algorithm SHA256).Hash.ToLowerInvariant() }
  }
  BeforeEach { Mock Get-TargetPlatform { $script:Demo } }

  It 'selects the demo manifest target and demo bundle ZIP in Resolve-AcceptedGemCandidate' {
    $url = "https://github.com/o/r/releases/download/$script:DemoCandidate/$script:DemoZip"
    $digest = 'sha256:' + ('c' * 64)
    # An x64 target sits beside the demo one: the filter must choose by the selected row.
    $manifestPath = Write-Fixture 'demo-accepted.json' ([ordered]@{ schema = 1; targets = @(
      [ordered]@{ ruby_abi = '4.0'; platform = 'x64-mingw-ucrt'; units = @() }
      [ordered]@{ ruby_abi = '4.0'; platform = 'demo-mingw-ucrt'; units = @(
        [ordered]@{ artifact = [ordered]@{ archive = 'zip'; filename = $script:DemoZip; url = $url; sha256 = $digest } }
      ) }
    ) })
    $release = [pscustomobject]@{
      tag_name = $script:DemoCandidate; draft = $false; target_commitish = ('a' * 40)
      html_url = "https://github.com/o/r/releases/tag/$script:DemoCandidate"
      assets = @(
        [pscustomobject]@{ name = 'R4L5-gem-manifest.json'; digest = (Get-FixtureDigest $manifestPath) }
        [pscustomobject]@{ name = $script:DemoZip; digest = $digest; browser_download_url = $url }
      )
    }
    $selection = Resolve-AcceptedGemCandidate -Release $release -AcceptedManifestPath $manifestPath -Repository 'o/r' -Tag $script:DemoCandidate
    $selection.archive_url | Should -BeExactly $url
    $selection.archive_digest | Should -BeExactly $digest
    $selection.run_id | Should -BeExactly '123'
  }

  Context 'Invoke-GemManifestPromotion' {
    BeforeEach {
      $script:DemoCandidatePath = Join-Path $TestDrive 'demo-candidate/R4L5-gem-manifest.json'
      $script:DemoBackupPath = Join-Path $TestDrive 'demo-backup/R4L5-gem-manifest.json'
      New-Item -ItemType Directory -Path (Split-Path $script:DemoCandidatePath), (Split-Path $script:DemoBackupPath) -Force | Out-Null
      [IO.File]::WriteAllText($script:DemoCandidatePath, 'candidate bytes')
      [IO.File]::WriteAllText($script:DemoBackupPath, 'original bytes')
      $script:DemoNewDigest = Get-FixtureDigest $script:DemoCandidatePath
      $script:DemoOldDigest = Get-FixtureDigest $script:DemoBackupPath
      $script:DemoRemoteDigest = $script:DemoOldDigest
      $script:DemoPromotionArgs = @{
        Repository = 'o/r'; CandidatePath = $script:DemoCandidatePath; BackupPath = $script:DemoBackupPath
        ExpectedCandidateDigest = $script:DemoNewDigest; ExpectedLiveDigest = $script:DemoOldDigest
        ReadbackPath = (Join-Path $TestDrive 'demo-readback.json')
      }
      Mock Start-Sleep {}
      # Only the demo live release exists: an x64 tag or URL is an unexpected call.
      Mock Invoke-PromotionGh {
        if ($Arguments[2] -cne 'R4L5-gem-bundle-demo-mingw-ucrt') { throw "unexpected release tag $($Arguments[2])" }
        if ($Arguments[1] -eq 'view') {
          return (@{ assets = @(@{ name = 'R4L5-gem-manifest.json'; digest = $script:DemoRemoteDigest }) } | ConvertTo-Json -Depth 5)
        }
        if ($Arguments[1] -ne 'upload') { throw 'unexpected release operation' }
        $script:DemoRemoteDigest = if ($Arguments[3] -eq $script:DemoCandidatePath) { $script:DemoNewDigest } else { $script:DemoOldDigest }
        return ''
      }
      Mock Invoke-VerifiedDownload {
        if ($Url -cne 'https://github.com/o/r/releases/download/R4L5-gem-bundle-demo-mingw-ucrt/R4L5-gem-manifest.json') { throw "unexpected readback URL $Url" }
        $text = if ($ExpectedDigest -eq $script:DemoNewDigest) { 'candidate bytes' } else { 'original bytes' }
        [IO.File]::WriteAllText($DestinationPath, $text)
        return $DestinationPath
      }
    }

    It 'uploads to and reads back from the demo live release' {
      Invoke-GemManifestPromotion @script:DemoPromotionArgs
      Get-Content $script:DemoPromotionArgs.ReadbackPath -Raw | Should -Be 'candidate bytes'
      Should -Invoke Invoke-PromotionGh -Times 1 -Exactly -ParameterFilter {
        $Arguments[1] -eq 'upload' -and $Arguments[2] -ceq 'R4L5-gem-bundle-demo-mingw-ucrt' -and $Arguments[3] -eq $script:DemoCandidatePath
      }
      Should -Invoke Invoke-VerifiedDownload -Times 1 -Exactly -ParameterFilter {
        $Url -ceq 'https://github.com/o/r/releases/download/R4L5-gem-bundle-demo-mingw-ucrt/R4L5-gem-manifest.json' -and $ExpectedDigest -eq $script:DemoNewDigest
      }
    }

    It 'restores the predecessor to the demo live release after a failed readback' {
      Mock Invoke-VerifiedDownload { throw 'consumer readback failed' } -ParameterFilter { $ExpectedDigest -eq $script:DemoNewDigest }
      { Invoke-GemManifestPromotion @script:DemoPromotionArgs } | Should -Throw "*approved rollback $script:DemoOldDigest is live and verified*"
      Should -Invoke Invoke-PromotionGh -Times 1 -Exactly -ParameterFilter {
        $Arguments[1] -eq 'upload' -and $Arguments[2] -ceq 'R4L5-gem-bundle-demo-mingw-ucrt' -and $Arguments[3] -eq $script:DemoBackupPath
      }
    }
  }

  It 'downloads the demo ZIP, checks the demo candidate tag and reads the demo live predecessor in Prepare-GemPromotion' {
    $root = Join-Path $TestDrive 'demo-prepare'
    $bundle = Join-Path $root 'bundle'
    $script:DemoReleaseDir = Join-Path $root 'release'
    New-Item -ItemType Directory -Path $bundle, $script:DemoReleaseDir -Force | Out-Null
    Set-Content (Join-Path $bundle 'fixture-1.0.gem') 'gem bytes'
    Set-Content (Join-Path $bundle 'resolution-lock.json') '{}'
    Set-Content (Join-Path $bundle 'runtime-gems-install-targets.txt') 'fixture-1.0.gem'
    Set-Content (Join-Path $bundle 'runtime-gems-manifest.txt') 'fixture-1.0.gem'
    Set-Content (Join-Path $bundle 'install-runtime-gems.cmd') '@echo off'
    New-GemBundleMetadata -Directory $bundle -Repository 'o/r' -RunId '123' -RunAttempt 1 -SourceSha ('a' * 40) -RubyInstallerVersion '4.0.9-1' -RubyArchiveDigest ('sha256:' + ('b' * 64))
    Compress-Archive -Path (Join-Path $bundle '*') -DestinationPath (Join-Path $script:DemoReleaseDir $script:DemoZip)
    Set-Content (Join-Path $script:DemoReleaseDir 'R4L5-gem-manifest.json') '{"schema":1}'
    $script:DemoRelease = [pscustomobject]@{
      tagName = $script:DemoCandidate; targetCommitish = ('a' * 40); isDraft = $false
      assets = @(Get-ChildItem $script:DemoReleaseDir -File | ForEach-Object { @{ name = $_.Name; digest = (Get-FixtureDigest $_.FullName) } })
    }
    $script:DemoProducer = @{
      id = 123; run_attempt = 1; head_sha = ('a' * 40)
      repository = @{ full_name = 'o/r' }; head_repository = @{ full_name = 'o/r' }
      path = '.github/workflows/ruby4-bundled-gems-suite.yml'; event = 'workflow_dispatch'; status = 'completed'; conclusion = 'success'
    }
    Mock Invoke-PromotionGh {
      if ($Arguments[0] -eq 'api') { return ($script:DemoProducer | ConvertTo-Json -Depth 8) }
      if ($Arguments[1] -eq 'view') { return ($script:DemoRelease | ConvertTo-Json -Depth 8) }
      if ($Arguments[1] -ne 'download') { throw 'Preparation attempted a release write.' }
      # Only the demo candidate and the demo live release exist.
      if ($Arguments[2] -cnotin @('R4L5-gem-bundle-demo-mingw-ucrt-candidate-123-1', 'R4L5-gem-bundle-demo-mingw-ucrt')) { throw "unexpected release tag $($Arguments[2])" }
      $name = $Arguments[[Array]::IndexOf($Arguments, '--pattern') + 1]
      $directory = $Arguments[[Array]::IndexOf($Arguments, '--dir') + 1]
      Copy-Item -LiteralPath (Join-Path $script:DemoReleaseDir $name) -Destination (Join-Path $directory $name)
      return ''
    }
    Mock Get-LiveGemManifestDigest { 'sha256:' + (Get-FileHash (Join-Path $script:DemoReleaseDir 'R4L5-gem-manifest.json') -Algorithm SHA256).Hash.ToLowerInvariant() }
    Prepare-GemPromotion -Directory (Join-Path $root 'preparation') -Repository 'o/r' -CandidateTag $script:DemoCandidate
    Test-Path (Join-Path $root 'preparation/live/R4L5-gem-manifest.json') | Should -BeTrue
    Should -Invoke Invoke-PromotionGh -Times 1 -Exactly -ParameterFilter {
      $Arguments[1] -eq 'download' -and $Arguments[2] -ceq 'R4L5-gem-bundle-demo-mingw-ucrt-candidate-123-1' -and $Arguments[6] -ceq 'R4L5-gem-bundle-demo-mingw-ucrt.zip'
    }
    Should -Invoke Invoke-PromotionGh -Times 1 -Exactly -ParameterFilter {
      $Arguments[1] -eq 'download' -and $Arguments[2] -ceq 'R4L5-gem-bundle-demo-mingw-ucrt' -and $Arguments[6] -ceq 'R4L5-gem-manifest.json'
    }
  }

  It 'selects the demo GTK target in New-FrozenGtkClosure' {
    $manifest = Write-Fixture 'demo-gtk-manifest.json' ([ordered]@{ schema = 1; targets = @(
      [ordered]@{ ruby_abi = '4.0'; platform = 'x64-mingw-ucrt'; units = @(
        [ordered]@{ id = 'gtk3-runtime'; artifact = [ordered]@{ url = 'https://example.test/x64.zip'; archive = 'zip'; sha256 = 'sha256:' + ('a' * 64) } }
      ) }
      [ordered]@{ ruby_abi = '4.0'; platform = 'demo-mingw-ucrt'; units = @(
        [ordered]@{ id = 'gtk3-runtime'; artifact = [ordered]@{ url = 'https://example.test/demo.zip'; archive = 'zip'; sha256 = 'sha256:' + ('d' * 64) } }
      ) }
    ) })
    # Stop at the download: reaching it with the demo URL proves the demo target was chosen.
    Mock Invoke-VerifiedDownload { throw 'stop after target selection' }
    { New-FrozenGtkClosure -ManifestPath $manifest -WorkDirectory (Join-Path $TestDrive 'demo-gtk-work') -CandidateDirectory $TestDrive -Repository 'o/r' -CandidateTag $script:DemoCandidate } |
      Should -Throw 'stop after target selection'
    Should -Invoke Invoke-VerifiedDownload -Times 1 -Exactly -ParameterFilter { $Url -ceq 'https://example.test/demo.zip' }
  }
}
