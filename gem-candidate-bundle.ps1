. (Join-Path $PSScriptRoot 'gem-bundle-artifact.ps1')

# Pure selection: network acquisition is confined to the workflow's API steps.
function Resolve-AcceptedGemCandidate {
  param(
    [Parameter(Mandatory = $true)]$Release,
    [Parameter(Mandatory = $true)][string]$AcceptedManifestPath,
    [Parameter(Mandatory = $true)][string]$Repository,
    [Parameter(Mandatory = $true)][string]$Tag
  )
  if ($Repository -cnotmatch '\A[A-Za-z0-9_.-]+/[A-Za-z0-9_.-]+\z' -or
      $Tag -cnotmatch '\AR4L5-gem-bundle-x64-mingw-ucrt-candidate-([1-9][0-9]*)-([1-9][0-9]*)\z') {
    throw 'Retained source requires a repository and exact immutable candidate run/attempt tag.'
  }
  $runId, $attempt = $Matches[1], $Matches[2]
  if ($Release.tag_name -cne $Tag -or $Release.draft -ne $false -or
      [string]$Release.target_commitish -cnotmatch '\A[0-9a-f]{40}\z' -or
      $Release.html_url -cne "https://github.com/$Repository/releases/tag/$Tag") {
    throw 'Retained candidate release identity differs from the selected repository/tag/source.'
  }
  $manifestDigest = 'sha256:' + (Get-FileHash -LiteralPath $AcceptedManifestPath -Algorithm SHA256).Hash.ToLowerInvariant()
  $manifest = Get-Content -LiteralPath $AcceptedManifestPath -Raw | ConvertFrom-Json
  $targets = @($manifest.targets | Where-Object { $_.platform -ceq 'x64-mingw-ucrt' -and $_.ruby_abi -ceq '4.0' })
  if ($manifest.schema -ne 1 -or $targets.Count -ne 1) { throw 'Accepted manifest requires exactly one Windows Ruby 4.0 target.' }
  $zipName = 'R4L5-gem-bundle-x64-mingw-ucrt.zip'
  $manifestAsset = @($Release.assets | Where-Object { $_.name -ceq 'R4L5-gem-manifest.json' })
  $zip = @($Release.assets | Where-Object { $_.name -ceq $zipName })
  if ($manifestAsset.Count -ne 1 -or $manifestAsset[0].digest -cne $manifestDigest -or
      $zip.Count -ne 1 -or [string]$zip[0].digest -cnotmatch '\Asha256:[0-9a-f]{64}\z' -or
      $zip[0].browser_download_url -cne "https://github.com/$Repository/releases/download/$Tag/$zipName") {
    throw 'Candidate assets do not match the currently accepted manifest and exact bundle identity.'
  }
  $references = @($targets[0].units | Where-Object {
    $_.artifact.url -ceq $zip[0].browser_download_url -and $_.artifact.archive -ceq 'zip' -and
    $_.artifact.filename -ceq $zipName -and $_.artifact.sha256 -ceq $zip[0].digest
  })
  if ($references.Count -eq 0) { throw 'Accepted manifest does not bind this retained candidate ZIP.' }
  return [pscustomobject]@{
    run_id = $runId; run_attempt = [int]$attempt; source_sha = $Release.target_commitish
    archive_url = $zip[0].browser_download_url; archive_digest = $zip[0].digest
    manifest_digest = $manifestDigest; candidate_tag = $Tag
  }
}

function Expand-CheckedGemBundle {
  param(
    [Parameter(Mandatory = $true)][string]$ArchivePath,
    [Parameter(Mandatory = $true)][string]$ExpectedDigest,
    [Parameter(Mandatory = $true)][string]$Directory
  )
  if ($ExpectedDigest -cnotmatch '\Asha256:[0-9a-f]{64}\z' -or
      ('sha256:' + (Get-FileHash -LiteralPath $ArchivePath -Algorithm SHA256).Hash.ToLowerInvariant()) -cne $ExpectedDigest) {
    throw 'Retained candidate archive checksum mismatch.'
  }
  if ((Test-Path -LiteralPath $Directory) -and @(Get-ChildItem -LiteralPath $Directory -Force).Count -ne 0) {
    throw 'Retained bundle extraction requires an empty destination.'
  }
  Add-Type -AssemblyName System.IO.Compression.FileSystem
  $archive = [IO.Compression.ZipFile]::OpenRead($ArchivePath)
  try {
    $names = @{}
    foreach ($entry in $archive.Entries) {
      if ($entry.FullName -cnotmatch '\A[A-Za-z0-9][A-Za-z0-9_.+-]*\z' -or $names.ContainsKey($entry.FullName) -or
          (($entry.ExternalAttributes -shr 16) -band 0xF000) -eq 0xA000) {
        throw 'Retained bundle ZIP contains an unsafe, duplicate or linked entry.'
      }
      $names[$entry.FullName] = $true
    }
    if ($names.Count -eq 0) { throw 'Retained bundle ZIP is empty.' }
    if (!(Test-Path -LiteralPath $Directory)) { New-Item -ItemType Directory -Path $Directory | Out-Null }
    foreach ($entry in $archive.Entries) {
      [IO.Compression.ZipFileExtensions]::ExtractToFile($entry, (Join-Path $Directory $entry.FullName), $false)
    }
  } finally { $archive.Dispose() }
}

function Read-AcceptedGemCandidate {
  param(
    [Parameter(Mandatory = $true)]$Release,
    [Parameter(Mandatory = $true)][string]$AcceptedManifestPath,
    [Parameter(Mandatory = $true)][string]$Repository,
    [Parameter(Mandatory = $true)][string]$Tag,
    [Parameter(Mandatory = $true)][string]$ArchivePath,
    [Parameter(Mandatory = $true)][string]$Directory,
    [Parameter(Mandatory = $true)][string]$RubySeries
  )
  $selection = Resolve-AcceptedGemCandidate -Release $Release -AcceptedManifestPath $AcceptedManifestPath -Repository $Repository -Tag $Tag
  Expand-CheckedGemBundle -ArchivePath $ArchivePath -ExpectedDigest $selection.archive_digest -Directory $Directory
  return Read-VerifiedGemBundleFiles -Directory $Directory -Repository $Repository -RunId $selection.run_id `
    -RunAttempt $selection.run_attempt -SourceSha $selection.source_sha -RubySeries $RubySeries
}
