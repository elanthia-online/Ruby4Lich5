# Prepares immutable GTK bytes; publication remains the existing candidate path.
. (Join-Path $PSScriptRoot 'verify-archive-download.ps1')

function New-FrozenGtkClosure {
  param([string]$ManifestPath, [string]$WorkDirectory, [string]$CandidateDirectory,
        [string]$Repository, [string]$CandidateTag, [string]$Ruby = 'ruby')
  if ($Repository -cnotmatch '\A[A-Za-z0-9_.-]+/[A-Za-z0-9_.-]+\z' -or
      $CandidateTag -cnotmatch '\AR4L5-gem-bundle-x64-mingw-ucrt-candidate-[1-9][0-9]*-[1-9][0-9]*\z') { throw 'Invalid frozen closure candidate identity.' }
  $manifest = Get-Content $ManifestPath -Raw | ConvertFrom-Json
  $targets = @($manifest.targets | Where-Object { $_.ruby_abi -ceq '4.0' -and $_.platform -ceq 'x64-mingw-ucrt' })
  $units = @($targets.units | Where-Object { $_.id -ceq 'gtk3-runtime' })
  if ($targets.Count -ne 1 -or $units.Count -ne 1) { throw 'Expected one accepted GTK closure.' }
  $unit = $units[0]
  if ($unit.artifact.archive -cne 'zip') { throw 'GTK requires a complete published ZIP closure.' }
  New-Item -ItemType Directory -Path $WorkDirectory -ErrorAction Stop | Out-Null
  $archive = Join-Path $WorkDirectory 'published.zip'
  Invoke-VerifiedDownload -Url $unit.artifact.url -ExpectedDigest $unit.artifact.sha256 -DestinationPath $archive | Out-Null
  Add-Type -AssemblyName System.IO.Compression.FileSystem
  $zip = [IO.Compression.ZipFile]::OpenRead($archive)
  try {
    $seen = @{}
    foreach ($entry in $zip.Entries) {
      if ($entry.FullName -cnotmatch '\A[A-Za-z0-9][A-Za-z0-9_.+-]*\z' -or $seen.ContainsKey($entry.FullName)) { throw 'Unsafe or duplicate published ZIP entry.' }
      $seen[$entry.FullName] = $true
    }
  } finally { $zip.Dispose() }
  $packages = Join-Path $WorkDirectory 'published'
  Expand-Archive -LiteralPath $archive -DestinationPath $packages -ErrorAction Stop
  $prepared = Join-Path $WorkDirectory 'frozen'
  & $Ruby (Join-Path $PSScriptRoot 'bin/prepare_frozen_gtk.rb') $ManifestPath $packages $prepared
  if ($LASTEXITCODE -ne 0) { throw 'Published GTK closure verification failed.' }
  $unit = Get-Content (Join-Path $prepared 'unit.json') -Raw | ConvertFrom-Json
  $identity = (Get-FileHash (Join-Path $prepared 'unit.json') -Algorithm SHA256).Hash.ToLowerInvariant()
  $filename = "R4L5-frozen-gtk-$identity.zip"
  $destination = Join-Path $CandidateDirectory $filename
  if (Test-Path -LiteralPath $destination) { throw 'Frozen closure output already exists; never overwrite it.' }
  $files = @(Get-ChildItem (Join-Path $prepared 'pkg') -File | ForEach-Object { $_.FullName })
  Compress-Archive -LiteralPath $files -DestinationPath $destination -CompressionLevel Optimal
  $digest = 'sha256:' + (Get-FileHash $destination -Algorithm SHA256).Hash.ToLowerInvariant()
  $unit.artifact = [pscustomobject]@{ url = "https://github.com/$Repository/releases/download/$CandidateTag/$filename"; filename = $filename; archive = 'zip'; sha256 = $digest }
  return $unit
}
