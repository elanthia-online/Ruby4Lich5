# Shared staging policy. Assignment enumerates top-level arrays on Desktop 5.1 too.
function Select-RuntimeGemManifest {
  param(
    [Parameter(Mandatory = $true)][string]$ToolingPath,
    [Parameter(Mandatory = $true)][object[]]$InstallManifest
  )
  $json = Get-Content -LiteralPath $ToolingPath -Raw
  # This configuration admits literal ASCII gem-name strings only. Validate the
  # entire array before parsing: older JSON readers can accept truncated input.
  $name = '"[a-zA-Z0-9][a-zA-Z0-9_.-]*"'
  if ($json -cnotmatch ('\A\s*\[\s*' + $name + '(?:\s*,\s*' + $name + ')*\s*\]\s*\z')) {
    throw 'Build tooling must be a nonempty array of gem-name strings.'
  }
  $parsed = $json | ConvertFrom-Json -ErrorAction Stop
  $names = @($parsed | ForEach-Object {
    if ($_ -isnot [string] -or $_ -cnotmatch '\A[a-zA-Z0-9][a-zA-Z0-9_.-]*\z') {
      throw 'Build tooling must contain only gem-name strings.'
    }
    $_
  })
  if ($names.Count -eq 0) { throw 'Build tooling must be a nonempty array of gem names.' }
  return @($InstallManifest | Where-Object { $names -notcontains $_.name })
}
