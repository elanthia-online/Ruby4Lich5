# D1 acquisition is bound to the smoke-tested artifact's checksummed map.
. (Join-Path $PSScriptRoot 'verify-archive-download.ps1')

function Restore-UpstreamGemPackages {
  param([string]$Directory, $Metadata)
  $mapEntries = @($Metadata.files | Where-Object { $_.name -ceq 'delivery-map.json' })
  if ($mapEntries.Count -eq 0) { return } # Legacy diagnostic artifacts only; publication requires a contract.
  if ($mapEntries.Count -ne 1) { throw 'Duplicate delivery map.' }
  $mapPath = Join-Path $Directory 'delivery-map.json'
  if (!(Test-Path -LiteralPath $mapPath -PathType Leaf) -or
      (Get-FileHash -LiteralPath $mapPath -Algorithm SHA256).Hash.ToLowerInvariant() -cne $mapEntries[0].sha256) {
    throw 'Delivery map is missing or differs from tested metadata.'
  }
  $map = Get-Content -LiteralPath $mapPath -Raw | ConvertFrom-Json
  if ($map.schema -ne 1 -or @($map.packages).Count -eq 0) { throw 'Invalid delivery map.' }
  $seen = @{}
  foreach ($package in @($map.packages)) {
    $name = [string]$package.filename
    $listed = @($Metadata.files | Where-Object { $_.name -ceq $name })
    if ($name -cnotmatch '\A[A-Za-z0-9][A-Za-z0-9_.+-]*\.gem\z' -or $seen.ContainsKey($name) -or
        $package.sha256 -cnotmatch '\A[0-9a-f]{64}\z' -or $listed.Count -ne 1 -or $listed[0].sha256 -cne $package.sha256 -or
        $package.delivery -notin @('upstream', 'bundle')) { throw 'Delivery map has an unsafe, duplicate or untested package.' }
    $seen[$name] = $true
    if ($package.delivery -eq 'upstream') {
      if ($package.url -cne "https://rubygems.org/downloads/$name") { throw 'Upstream delivery must use the original RubyGems filename and URL.' }
      $path = Join-Path $Directory $name
      if (!(Test-Path -LiteralPath $path)) {
        Invoke-VerifiedDownload -Url $package.url -ExpectedDigest "sha256:$($package.sha256)" -DestinationPath $path | Out-Null
      }
    }
  }
  $listedGems = @($Metadata.files | Where-Object { $_.name -clike '*.gem' })
  if ($seen.Count -ne $listedGems.Count) { throw 'Delivery map does not cover the complete tested package inventory.' }
}
