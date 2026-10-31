# Only the consumer-named manifest is mutable. Artifacts retain immutable URLs.
. (Join-Path $PSScriptRoot 'verify-archive-download.ps1')

function Invoke-PromotionGh {
  param([Parameter(Mandatory = $true)][string[]]$Arguments)
  $output = & gh @Arguments 2>&1
  if ($LASTEXITCODE -ne 0) { throw "gh failed: $output" }
  return ($output -join "`n")
}

function Get-LiveGemManifestDigest {
  param([Parameter(Mandatory = $true)][string]$Repository)
  $json = Invoke-PromotionGh -Arguments @('release', 'view', 'R4L5-gem-bundle-x64-mingw-ucrt', '--repo', $Repository, '--json', 'assets')
  $assets = @((ConvertFrom-Json $json).assets | Where-Object { $_.name -ceq 'R4L5-gem-manifest.json' })
  if ($assets.Count -eq 0) { return $null }
  if ($assets.Count -ne 1) { throw 'Ambiguous live manifest assets.' }
  if ([string]::IsNullOrWhiteSpace($assets[0].digest)) { return $null }
  if ($assets[0].digest -cnotmatch '\Asha256:[0-9a-f]{64}\z') { throw 'Invalid live manifest digest.' }
  return $assets[0].digest
}

function Confirm-LiveGemManifest {
  param([string]$Repository, [string]$ExpectedDigest, [string]$DestinationPath)
  for ($attempt = 1; $attempt -le 5; $attempt++) {
    $digest = Get-LiveGemManifestDigest -Repository $Repository
    if ($digest) { break }
    if ($attempt -lt 5) { Start-Sleep -Seconds 2 }
  }
  if ($digest -cne $ExpectedDigest) { throw 'Live manifest API digest does not match the approved bytes.' }
  $url = "https://github.com/$Repository/releases/download/R4L5-gem-bundle-x64-mingw-ucrt/R4L5-gem-manifest.json"
  Invoke-VerifiedDownload -Url $url -ExpectedDigest $ExpectedDigest -DestinationPath $DestinationPath | Out-Null
}

function Invoke-GemManifestPromotion {
  param(
    [Parameter(Mandatory = $true)][string]$Repository,
    [Parameter(Mandatory = $true)][string]$CandidatePath,
    [Parameter(Mandatory = $true)][string]$BackupPath,
    [Parameter(Mandatory = $true)][string]$ExpectedCandidateDigest,
    [Parameter(Mandatory = $true)][string]$ExpectedLiveDigest,
    [Parameter(Mandatory = $true)][string]$ReadbackPath
  )
  if ($Repository -cnotmatch '\A[A-Za-z0-9_.-]+/[A-Za-z0-9_.-]+\z' -or
      $ExpectedCandidateDigest -cnotmatch '\Asha256:[0-9a-f]{64}\z' -or $ExpectedLiveDigest -cnotmatch '\Asha256:[0-9a-f]{64}\z' -or
      (Split-Path $CandidatePath -Leaf) -cne 'R4L5-gem-manifest.json' -or (Split-Path $BackupPath -Leaf) -cne 'R4L5-gem-manifest.json') {
    throw 'Promotion requires exact manifest filenames, repository and SHA-256 identities.'
  }
  foreach ($entry in @(@{ Path = $CandidatePath; Digest = $ExpectedCandidateDigest }, @{ Path = $BackupPath; Digest = $ExpectedLiveDigest })) {
    $actual = 'sha256:' + (Get-FileHash -LiteralPath $entry.Path -Algorithm SHA256).Hash.ToLowerInvariant()
    if ($actual -cne $entry.Digest) { throw 'Local promotion or rollback bytes changed.' }
  }
  if ((Get-LiveGemManifestDigest -Repository $Repository) -cne $ExpectedLiveDigest) { throw 'Live predecessor changed after approval; nothing uploaded.' }
  $liveTag = 'R4L5-gem-bundle-x64-mingw-ucrt'
  try {
    Invoke-PromotionGh -Arguments @('release', 'upload', $liveTag, $CandidatePath, '--repo', $Repository, '--clobber') | Out-Null
    Confirm-LiveGemManifest -Repository $Repository -ExpectedDigest $ExpectedCandidateDigest -DestinationPath $ReadbackPath
  } catch {
    $originalError = $_.Exception.Message
    try {
      $current = Get-LiveGemManifestDigest -Repository $Repository
      if ($current -cne $ExpectedLiveDigest) {
        if ($current -and $current -cne $ExpectedCandidateDigest) { throw 'Concurrent manifest detected; restoration would overwrite unapproved bytes.' }
        Invoke-PromotionGh -Arguments @('release', 'upload', $liveTag, $BackupPath, '--repo', $Repository, '--clobber') | Out-Null
      }
      Confirm-LiveGemManifest -Repository $Repository -ExpectedDigest $ExpectedLiveDigest -DestinationPath $ReadbackPath
    } catch {
      throw "Promotion failed: $originalError; restoration is unconfirmed: $($_.Exception.Message). Retain the rollback file for administrative recovery."
    }
    throw "Promotion failed: $originalError; previous manifest was restored or retained and verified."
  }
}
