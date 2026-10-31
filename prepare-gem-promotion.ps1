# Read-only acquisition and identity checks; never executes downloaded gem code.
. (Join-Path $PSScriptRoot 'gem-manifest-promotion.ps1')
. (Join-Path $PSScriptRoot 'gem-bundle-artifact.ps1')

function Prepare-GemPromotion {
  param([string]$Directory, [string]$Repository, [string]$CandidateTag)
  if ($CandidateTag -cnotmatch '\AR4L5-gem-bundle-x64-mingw-ucrt-candidate-[1-9][0-9]*-[1-9][0-9]*\z' -or
      $Repository -cnotmatch '\A[A-Za-z0-9_.-]+/[A-Za-z0-9_.-]+\z') { throw 'Invalid candidate or repository.' }
  New-Item -ItemType Directory -Path $Directory -ErrorAction Stop | Out-Null
  $candidateDir = Join-Path $Directory 'candidate'
  $liveDir = Join-Path $Directory 'live'
  $bundleDir = Join-Path $Directory 'bundle'
  foreach ($path in @($candidateDir, $liveDir, $bundleDir)) {
    New-Item -ItemType Directory -Path $path -ErrorAction Stop | Out-Null
  }
  $releaseJson = Invoke-PromotionGh -Arguments @('release', 'view', $CandidateTag, '--repo', $Repository, '--json', 'tagName,targetCommitish,isDraft,assets')
  $releaseJson | Set-Content -LiteralPath (Join-Path $Directory 'candidate-release.json') -Encoding utf8
  $release = $releaseJson | ConvertFrom-Json
  if ($release.tagName -cne $CandidateTag -or $release.isDraft -ne $false -or $release.targetCommitish -cnotmatch '\A[0-9a-f]{40}\z') {
    throw 'Candidate release identity is invalid.'
  }
  $zipName = 'R4L5-gem-bundle-x64-mingw-ucrt.zip'
  foreach ($name in @('R4L5-gem-manifest.json', $zipName)) {
    $assets = @($release.assets | Where-Object { $_.name -ceq $name })
    if ($assets.Count -ne 1 -or $assets[0].digest -cnotmatch '\Asha256:[0-9a-f]{64}\z') { throw "Missing candidate asset digest: $name" }
    Invoke-PromotionGh -Arguments @('release', 'download', $CandidateTag, '--repo', $Repository, '--pattern', $name, '--dir', $candidateDir) | Out-Null
    $digest = 'sha256:' + (Get-FileHash -LiteralPath (Join-Path $candidateDir $name) -Algorithm SHA256).Hash.ToLowerInvariant()
    if ($digest -cne $assets[0].digest) { throw "Candidate download digest mismatch: $name" }
  }
  Add-Type -AssemblyName System.IO.Compression.FileSystem
  $zipPath = Join-Path $candidateDir $zipName
  $zip = [IO.Compression.ZipFile]::OpenRead($zipPath)
  try {
    $names = @{}
    foreach ($entry in $zip.Entries) {
      if ($entry.FullName -cnotmatch '\A[A-Za-z0-9][A-Za-z0-9_.+-]*\z' -or $names.ContainsKey($entry.FullName)) { throw 'Bundle has a nested, unsafe or duplicate entry.' }
      $names[$entry.FullName] = $true
    }
  } finally { $zip.Dispose() }
  Expand-Archive -LiteralPath $zipPath -DestinationPath $bundleDir -ErrorAction Stop
  $metadata = Get-Content -LiteralPath (Join-Path $bundleDir 'gem-build-metadata.json') -Raw | ConvertFrom-Json
  if ([string]$metadata.run_id -cnotmatch '\A[1-9][0-9]*\z' -or [string]$metadata.run_attempt -cnotmatch '\A[1-9][0-9]*\z' -or
      $CandidateTag -cne "R4L5-gem-bundle-x64-mingw-ucrt-candidate-$($metadata.run_id)-$($metadata.run_attempt)" -or
      $metadata.source_sha -cne $release.targetCommitish) { throw 'Candidate differs from its producing run.' }
  $runJson = Invoke-PromotionGh -Arguments @('api', "repos/$Repository/actions/runs/$($metadata.run_id)")
  $run = $runJson | ConvertFrom-Json
  $runJson | Set-Content -LiteralPath (Join-Path $Directory 'producer-run.json') -Encoding utf8
  $series = ([string]$metadata.ruby_installer_version -split '\.')[0..1] -join '.'
  Read-VerifiedGemBundle -Directory $bundleDir -Run $run -Repository $Repository -RunId ([string]$metadata.run_id) -RubySeries $series | Out-Null
  $liveDigest = Get-LiveGemManifestDigest -Repository $Repository
  if (-not $liveDigest) { throw 'Existing live recovery manifest is required.' }
  Invoke-PromotionGh -Arguments @('release', 'download', 'R4L5-gem-bundle-x64-mingw-ucrt', '--repo', $Repository, '--pattern', 'R4L5-gem-manifest.json', '--dir', $liveDir) | Out-Null
  $downloadDigest = 'sha256:' + (Get-FileHash -LiteralPath (Join-Path $liveDir 'R4L5-gem-manifest.json') -Algorithm SHA256).Hash.ToLowerInvariant()
  if ($downloadDigest -cne $liveDigest) { throw 'Live manifest changed during inspection.' }
}
