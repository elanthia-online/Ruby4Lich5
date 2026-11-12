. (Join-Path $PSScriptRoot 'platform-table.ps1')
. (Join-Path $PSScriptRoot 'gem-candidate-publication.ps1')
. (Join-Path $PSScriptRoot 'verify-archive-download.ps1')

# Both installer sources use this published manifest, never a checkout snapshot.
function Read-LiveAcceptedGemManifest {
  param(
    [Parameter(Mandatory = $true)][string]$Repository,
    [Parameter(Mandatory = $true)][string]$DestinationPath,
    [string]$ExpectedDigest
  )
  if ($Repository -cnotmatch '\A[A-Za-z0-9_.-]+/[A-Za-z0-9_.-]+\z' -or
      ($PSBoundParameters.ContainsKey('ExpectedDigest') -and $ExpectedDigest -cnotmatch '\Asha256:[0-9a-f]{64}\z')) {
    throw 'Accepted manifest requires an exact repository and valid expected digest.'
  }
  $tag = (Get-TargetPlatform).gem_bundle_tag
  $release = (Invoke-CandidateGh -Arguments @('api', "repos/$Repository/releases/tags/$tag")) | ConvertFrom-Json
  $url = "https://github.com/$Repository/releases/download/$tag/R4L5-gem-manifest.json"
  $assets = @($release.assets | Where-Object { $_.name -ceq 'R4L5-gem-manifest.json' })
  if ($release.tag_name -cne $tag -or $release.draft -ne $false -or $assets.Count -ne 1 -or
      $assets[0].browser_download_url -cne $url -or [string]$assets[0].digest -cnotmatch '\Asha256:[0-9a-f]{64}\z') {
    throw 'Missing exact published accepted manifest identity.'
  }
  if ($ExpectedDigest -and $assets[0].digest -cne $ExpectedDigest) {
    throw 'Accepted manifest changed during the installer build; inspect the new accepted manifest before rebuilding.'
  }
  Invoke-VerifiedDownload -Url $url -ExpectedDigest $assets[0].digest -DestinationPath $DestinationPath | Out-Null
  return [pscustomobject]@{ Path = $DestinationPath; Digest = $assets[0].digest }
}
