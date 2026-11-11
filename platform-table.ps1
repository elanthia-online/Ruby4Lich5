# PowerShell reader for config/platforms.json, mirroring Ruby4Lich5::TargetPlatform
# (lib/ruby4lich5/target_platform.rb) in its ROW validation and selection
# order -- explicit -Platform, then GEM_PLATFORM, then config/target-ruby.json's
# own platform. A name the table does not define is rejected rather than
# falling back to a default.
#
# The JSON layer is looser than Ruby's load_table, which rejects all of these:
# - duplicate keys (the last one wins);
# - a UTF-8 BOM (Get-Content strips it);
# - on pwsh 7, a table wrapped in a one-element top-level array (enumerated);
# - on pwsh 7, comments and trailing commas.
# Selection differs in one case: an explicit -Platform $null throws here,
# where Ruby's select(nil) falls back to GEM_PLATFORM.
# Strict syntax validation is TargetPlatform's job: rspec and the
# cross-language agreement test parse the committed table with Ruby, so this
# reader assumes a table Ruby already accepted.
#
# Dot-sourcing defines functions only; nothing is read until Get-TargetPlatform
# is called. Paths resolve from this file, never the caller's directory, so a
# script using it needs a checkout that includes config/ (not a sparse one).

function Assert-PlatformTableToken {
  param($Value, [string]$Label)
  # SafeToken.validate!: a non-blank String of [a-zA-Z0-9._-], never "." or "..".
  if ($null -eq $Value -or ($Value -is [string] -and $Value.Trim().Length -eq 0)) { throw "$Label must not be nil or empty" }
  if ($Value -isnot [string]) { throw "$Label must be a String, got $($Value.GetType().Name): $Value" }
  if ($Value -cnotmatch '\A(?!\.{1,2}\z)[a-zA-Z0-9._-]+\z') { throw "$Label contains disallowed characters: $Value" }
}

function Test-PlatformTableKeys {
  param($Object, [string[]]$Keys)
  # Exact, case-sensitive key set; PowerShell property access is case-insensitive.
  if ($Object -isnot [System.Management.Automation.PSCustomObject]) { return $false }
  $names = @($Object.PSObject.Properties | ForEach-Object { $_.Name })
  if ($names.Count -ne $Keys.Count) { return $false }
  foreach ($key in $Keys) { if ($names -cnotcontains $key) { return $false } }
  return $true
}

function ConvertTo-TargetPlatformRow {
  param([string]$Name, $Entry)
  $tokenKeys = @('rubyinstaller_asset_suffix', 'runner', 'msystem', 'msys2_prefix', 'msys2_package_prefix', 'gem_bundle_tag')
  $entryKeys = @($tokenKeys + @('msys2_bootstrap_packages', 'toolchain') | Sort-Object)
  $toolchainKeys = @('cc', 'make', 'pkg_config', 'objdump')

  Assert-PlatformTableToken -Value $Name -Label 'platform name'
  if (-not (Test-PlatformTableKeys -Object $Entry -Keys $entryKeys)) {
    throw "platform $Name must define exactly [$(($entryKeys | ForEach-Object { '"' + $_ + '"' }) -join ', ')]"
  }
  foreach ($key in $tokenKeys) { Assert-PlatformTableToken -Value $Entry.$key -Label "$Name $key" }
  if ($Entry.gem_bundle_tag -cne "R4L5-gem-bundle-$Name") { throw "$Name gem_bundle_tag must be R4L5-gem-bundle-$Name" }

  $packages = $Entry.msys2_bootstrap_packages
  if ($packages -isnot [array] -or $packages.Count -eq 0) { throw "$Name msys2_bootstrap_packages must be a non-empty array" }
  $seen = New-Object 'System.Collections.Generic.HashSet[string]' ([StringComparer]::Ordinal)
  foreach ($package in $packages) {
    Assert-PlatformTableToken -Value $package -Label "$Name msys2_bootstrap_packages entry"
  }
  foreach ($package in $packages) {
    if (-not $seen.Add($package)) { throw "$Name msys2_bootstrap_packages must not repeat a package" }
  }
  $foreign = @($packages | Where-Object {
    $_.StartsWith('mingw-w64-', [StringComparison]::Ordinal) -and
      -not $_.StartsWith("$($Entry.msys2_package_prefix)-", [StringComparison]::Ordinal)
  })
  if ($foreign.Count -ne 0) { throw "$Name msys2_bootstrap_packages name another MSYS2 environment: $($foreign -join ', ')" }

  $tools = $Entry.toolchain
  if (-not (Test-PlatformTableKeys -Object $tools -Keys $toolchainKeys)) {
    throw "$Name toolchain must define exactly [$((@($toolchainKeys | Sort-Object) | ForEach-Object { '"' + $_ + '"' }) -join ', ')]"
  }
  $toolchain = [ordered]@{}
  foreach ($key in $toolchainKeys) {
    Assert-PlatformTableToken -Value $tools.$key -Label "$Name toolchain $key"
    $toolchain[$key] = $tools.$key
  }

  return [pscustomobject]@{
    name = $Name
    rubyinstaller_asset_suffix = $Entry.rubyinstaller_asset_suffix
    runner = $Entry.runner
    msystem = $Entry.msystem
    msys2_prefix = $Entry.msys2_prefix
    msys2_package_prefix = $Entry.msys2_package_prefix
    msys2_bootstrap_packages = @($packages)
    toolchain = [pscustomobject]$toolchain
    gem_bundle_tag = $Entry.gem_bundle_tag
    # TargetPlatform#candidate_tag_pattern. [0-9], not \d: .NET \d also matches
    # non-ASCII digits, Ruby's does not. Groups capture run id and attempt.
    candidate_tag_pattern = '\A' + [regex]::Escape($Entry.gem_bundle_tag) + '-candidate-([1-9][0-9]*)-([1-9][0-9]*)\z'
  }
}

# Every validated row, keyed by platform name (case-sensitive lookups only).
function Read-PlatformTable {
  param([string]$Path = (Join-Path (Join-Path $PSScriptRoot 'config') 'platforms.json'))
  try {
    $data = Get-Content -LiteralPath $Path -Raw -ErrorAction Stop | ConvertFrom-Json -ErrorAction Stop
  } catch {
    throw "malformed platform table JSON: $($_.Exception.Message)"
  }
  $schema = $null
  if ($data -is [System.Management.Automation.PSCustomObject]) { $schema = $data.schema }
  $numeric = $schema -is [int] -or $schema -is [long] -or $schema -is [double] -or $schema -is [decimal]
  if (-not (Test-PlatformTableKeys -Object $data -Keys @('platforms', 'schema')) -or -not $numeric -or $schema -ne 1) {
    throw "$Path must contain exactly [""schema"", ""platforms""] with schema 1"
  }
  $platforms = $data.platforms
  if ($platforms -isnot [System.Management.Automation.PSCustomObject] -or @($platforms.PSObject.Properties).Count -eq 0) {
    throw "$Path platforms must be a non-empty object"
  }
  $rows = New-Object System.Collections.Specialized.OrderedDictionary ([StringComparer]::Ordinal)
  foreach ($property in $platforms.PSObject.Properties) {
    $rows[$property.Name] = ConvertTo-TargetPlatformRow -Name $property.Name -Entry $property.Value
  }
  return $rows
}

# TargetPlatform.select: explicit -Platform, then GEM_PLATFORM, then target-ruby.json.
function Get-TargetPlatform {
  param(
    [string]$Platform,
    [string]$TablePath = (Join-Path (Join-Path $PSScriptRoot 'config') 'platforms.json'),
    [string]$TargetPath = (Join-Path (Join-Path $PSScriptRoot 'config') 'target-ruby.json')
  )
  if ($PSBoundParameters.ContainsKey('Platform')) {
    $name = $Platform
  } else {
    # A present GEM_PLATFORM decides even when unusable, as in Ruby's env.key?.
    $name = [Environment]::GetEnvironmentVariable('GEM_PLATFORM')
    if ($null -eq $name) {
      $target = Get-Content -LiteralPath $TargetPath -Raw -ErrorAction Stop | ConvertFrom-Json -ErrorAction Stop
      if ($target -isnot [System.Management.Automation.PSCustomObject] -or
          @($target.PSObject.Properties | Where-Object { $_.Name -ceq 'platform' }).Count -ne 1) {
        throw "$TargetPath has no platform"
      }
      $name = $target.platform
    }
  }
  Assert-PlatformTableToken -Value $name -Label 'selected platform'
  $rows = Read-PlatformTable -Path $TablePath
  if (-not $rows.Contains($name)) {
    throw "unknown platform ""$name""; config/platforms.json defines [$((@($rows.Keys) | ForEach-Object { '"' + $_ + '"' }) -join ', ')]"
  }
  return $rows[$name]
}
