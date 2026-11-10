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
    @((Read-PlatformTable).Keys) | Should -Be @('x64-mingw-ucrt')
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
