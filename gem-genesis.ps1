# Genesis: the first accepted manifest for a platform that has none. This file
# holds the production-release absence proof and the genesis production write
# with its input guards. Ordinary publication and promotion load these functions
# (prepare-gem-promotion.ps1 dot-sources this file) but never call them; the
# approval gate is the workflow's installer-release.cjs step, not code here.
# See docs/PLATFORM-GENESIS.md.
. (Join-Path $PSScriptRoot 'platform-table.ps1')
. (Join-Path $PSScriptRoot 'gh-native.ps1')
. (Join-Path $PSScriptRoot 'gem-manifest-promotion.ps1')

# 'absent' only when the release and the git tag both answer HTTP 404 and no
# release this token can list (drafts included) carries the tag. 'release',
# 'tag' (a bare tag a new release would attach to) and 'draft' all mean the
# production name is taken. Any other failure throws: unknown is not absent.
# Only a non-zero exit whose output carries HTTP 404 counts as not found, so an
# authentication, rate-limit or network failure is never read as absence.
function Get-GemProductionReleaseState {
  param(
    [Parameter(Mandatory = $true)][string]$Repository,
    [string]$Tag = (Get-TargetPlatform).gem_bundle_tag
  )
  if ($Repository -cnotmatch '\A[A-Za-z0-9_.-]+/[A-Za-z0-9_.-]+\z' -or $Tag -cnotmatch '\AR4L5-gem-bundle-[a-z0-9_]+-mingw-ucrt\z') {
    throw 'Invalid repository or production tag.'
  }
  $release = Invoke-GhNative -Arguments @('api', "repos/$Repository/releases/tags/$Tag")
  if ($release.ExitCode -eq 0) { return 'release' }
  if ($release.Output -notmatch 'HTTP 404') { throw "Production release state is unknown: $($release.Output)" }
  $ref = Invoke-GhNative -Arguments @('api', "repos/$Repository/git/ref/tags/$Tag")
  if ($ref.ExitCode -eq 0) { return 'tag' }
  if ($ref.Output -notmatch 'HTTP 404') { throw "Production tag state is unknown: $($ref.Output)" }
  $listed = Invoke-GhNative -Arguments @('api', '--paginate', "repos/$Repository/releases?per_page=100", '--jq', '.[].tag_name')
  if ($listed.ExitCode -ne 0) { throw "Release listing failed: $($listed.Output)" }
  if (@($listed.Output -split "`r?`n") -ccontains $Tag) { return 'draft' }
  return 'absent'
}

# Throws unless the current platform's production release is absent. Called by
# genesis publication before its only write, by Prepare-GemPromotion -Genesis
# before and after acquisition, and by Invoke-GemManifestGenesis before it writes.
function Assert-GemProductionReleaseAbsent {
  param([Parameter(Mandatory = $true)][string]$Repository)
  $tag = (Get-TargetPlatform).gem_bundle_tag
  $state = Get-GemProductionReleaseState -Repository $Repository -Tag $tag
  if ($state -cne 'absent') { throw "Genesis refused: $tag already exists ($state); use the normal accepted-predecessor path." }
}

# Create the platform's production release with the approved candidate
# manifest attached, then read it back through the consumer URL. Called only by
# promote-gem-candidate.yml's genesis branch, after its r4l5-recovery-promotion
# approval step (installer-release.cjs). In order, before any write: the typed
# confirmation, the exact repository, digest, candidate tag, source SHA and
# manifest filename, live-sha256 'absent', unchanged local bytes, and the
# production release proven absent again.
function Invoke-GemManifestGenesis {
  param(
    [Parameter(Mandatory = $true)][string]$Repository,
    [Parameter(Mandatory = $true)][string]$CandidatePath,
    [Parameter(Mandatory = $true)][string]$ExpectedCandidateDigest,
    [Parameter(Mandatory = $true)][AllowEmptyString()][string]$ExpectedLiveDigest,
    [Parameter(Mandatory = $true)][string]$CandidateTag,
    [Parameter(Mandatory = $true)][string]$SourceSha,
    [Parameter(Mandatory = $true)][AllowEmptyString()][string]$Confirm,
    [Parameter(Mandatory = $true)][string]$ReadbackPath
  )
  $platform = Get-TargetPlatform
  $tag = $platform.gem_bundle_tag
  if ($Confirm -cne $tag) { throw "Genesis requires genesis-confirm to equal $tag." }
  if ($Repository -cnotmatch '\A[A-Za-z0-9_.-]+/[A-Za-z0-9_.-]+\z' -or $ExpectedCandidateDigest -cnotmatch '\Asha256:[0-9a-f]{64}\z' -or
      $ExpectedLiveDigest -cne 'absent' -or $CandidateTag -cnotmatch $platform.candidate_tag_pattern -or $SourceSha -cnotmatch '\A[0-9a-f]{40}\z' -or
      (Split-Path $CandidatePath -Leaf) -cne 'R4L5-gem-manifest.json') {
    throw 'Genesis requires the exact manifest filename, repository, candidate, source and SHA-256 identities, and live-sha256 absent.'
  }
  $actual = 'sha256:' + (Get-FileHash -LiteralPath $CandidatePath -Algorithm SHA256).Hash.ToLowerInvariant()
  if ($actual -cne $ExpectedCandidateDigest) { throw 'Local genesis manifest bytes changed.' }
  Assert-GemProductionReleaseAbsent -Repository $Repository
  $date = [DateTime]::UtcNow.ToString('yyyy-MM-dd')
  $notes = "Built by Ruby4Lich5, commit $SourceSha. Released -- genesis manifest from $CandidateTag, smoke-tested and promoted $date. Single current artifact, overwritten in place by later promotions, not an incrementing version -- verify by SHA-256 digest, not by trusting the tag alone. Deliberately never claims the repo-wide 'Latest' designation (--latest=false) -- that's reserved for installer releases only."
  # One call: with an asset, gh creates a draft, uploads the manifest, then
  # publishes, so the published release never lacks its manifest. A failure
  # here may still have left a release or draft behind; nothing is deleted
  # that this run did not prove it created.
  try {
    Invoke-PromotionGh -Arguments @('release', 'create', $tag, $CandidatePath, '--repo', $Repository, '--target', $SourceSha, '--latest=false',
      '--title', "Gem bundle ($($platform.name))", '--notes', $notes) | Out-Null
  } catch {
    throw "Genesis release creation failed or its outcome is unknown: $($_.Exception.Message). A release or draft named $tag may exist; inspect it before retrying (docs/PLATFORM-GENESIS.md)."
  }
  try {
    Confirm-LiveGemManifest -Repository $Repository -ExpectedDigest $ExpectedCandidateDigest -DestinationPath $ReadbackPath
  } catch {
    $originalError = $_.Exception.Message
    try {
      Invoke-PromotionGh -Arguments @('release', 'delete', $tag, '--repo', $Repository, '--yes', '--cleanup-tag') | Out-Null
      $state = $null
      for ($attempt = 1; $attempt -le 5; $attempt++) {
        $state = Get-GemProductionReleaseState -Repository $Repository -Tag $tag
        if ($state -ceq 'absent') { break }
        if ($attempt -lt 5) { Start-Sleep -Seconds 2 }
      }
      if ($state -cne 'absent') { throw "$tag is still present ($state)" }
    } catch {
      throw "Genesis failed: $originalError; removal of the created $tag is unconfirmed: $($_.Exception.Message). Administrative cleanup is required."
    }
    throw "Genesis failed: $originalError; the created $tag was deleted and its absence verified."
  }
}
