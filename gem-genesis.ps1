# Genesis: the first accepted manifest for a platform that has none. This file
# holds the proof that the platform's production release is absent; ordinary
# publication never calls it. See docs/PLATFORM-GENESIS.md.
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

# Throws unless the current platform's production release is absent; used by
# genesis publication before its only write.
function Assert-GemProductionReleaseAbsent {
  param([Parameter(Mandatory = $true)][string]$Repository)
  $tag = (Get-TargetPlatform).gem_bundle_tag
  $state = Get-GemProductionReleaseState -Repository $Repository -Tag $tag
  if ($state -cne 'absent') { throw "Genesis refused: $tag already exists ($state); use the normal accepted-predecessor path." }
}

$script:GenesisEnvironment = 'r4l5-recovery-promotion'

function Read-GenesisGhJson {
  param([Parameter(Mandatory = $true)][string[]]$Arguments, [Parameter(Mandatory = $true)][string]$Failure)
  $result = Invoke-GhNative -Arguments $Arguments
  if ($result.ExitCode -ne 0) { throw "${Failure}: $($result.Output)" }
  return ($result.Output | ConvertFrom-Json)
}

function Assert-GenesisAdministrator {
  param([Parameter(Mandatory = $true)][string]$Repository, [Parameter(Mandatory = $true)][string]$Login)
  if ($Login -cnotmatch '\A[A-Za-z0-9](?:[A-Za-z0-9-]{0,38})\z') { throw "Invalid reviewer login: $Login" }
  $level = Read-GenesisGhJson -Arguments @('api', "repos/$Repository/collaborators/$Login/permission") -Failure "Administrator check failed for $Login"
  if ($level.permission -cne 'admin') { throw "$Login must be a repository administrator." }
}

# Port of installer-release.cjs environment()/approval(): the protection
# environment must exist with exactly one required_reviewers rule naming
# administrator users explicitly. With -RunId, this run (first attempt only)
# must also carry a recorded administrator approval for that environment, so
# the gate holds even if the job did not bind the environment or an
# administrator bypassed its rules. Reads only; never creates or edits it.
function Assert-GemRecoveryPromotionEnvironment {
  param(
    [Parameter(Mandatory = $true)][string]$Repository,
    [string]$RunId,
    [string]$RunAttempt
  )
  if ($Repository -cnotmatch '\A[A-Za-z0-9_.-]+/[A-Za-z0-9_.-]+\z') { throw 'Invalid repository.' }
  $name = $script:GenesisEnvironment
  $environment = Read-GenesisGhJson -Arguments @('api', "repos/$Repository/environments/$name") -Failure "Genesis requires the $name environment"
  $rules = @($environment.protection_rules | Where-Object { $_.type -ceq 'required_reviewers' })
  if ($rules.Count -ne 1 -or @($rules[0].reviewers).Count -lt 1) { throw "$name requires one required-reviewers rule naming administrator reviewers." }
  foreach ($entry in @($rules[0].reviewers)) {
    if ($entry.type -cne 'User' -or [string]::IsNullOrWhiteSpace($entry.reviewer.login)) { throw "$name must name administrator users explicitly." }
    Assert-GenesisAdministrator -Repository $Repository -Login $entry.reviewer.login
  }
  if ([string]::IsNullOrEmpty($RunId)) { return }
  if ($RunId -cnotmatch '\A[1-9][0-9]*\z') { throw 'Invalid run identity.' }
  if ($RunAttempt -cne '1') { throw 'Start a fresh genesis dispatch instead of rerunning an approval job.' }
  $reviews = @(Read-GenesisGhJson -Arguments @('api', "repos/$Repository/actions/runs/$RunId/approvals") -Failure 'Run approval lookup failed')
  $approvals = @($reviews | Where-Object { $_.state -ceq 'approved' -and @($_.environments | Where-Object { $_.id -eq $environment.id }).Count -gt 0 })
  if ($approvals.Count -eq 0) { throw "No explicit approval recorded for $name in this run." }
  foreach ($review in $approvals) { Assert-GenesisAdministrator -Repository $Repository -Login $review.user.login }
}

# Create the platform's production release and serve the approved candidate
# manifest from it. Deletes, on failure, only a release this call created,
# then proves the name absent again.
function Invoke-GemManifestGenesis {
  param(
    [Parameter(Mandatory = $true)][string]$Repository,
    [Parameter(Mandatory = $true)][string]$CandidatePath,
    [Parameter(Mandatory = $true)][string]$ExpectedCandidateDigest,
    [Parameter(Mandatory = $true)][AllowEmptyString()][string]$ExpectedLiveDigest,
    [Parameter(Mandatory = $true)][string]$CandidateTag,
    [Parameter(Mandatory = $true)][string]$SourceSha,
    [Parameter(Mandatory = $true)][AllowEmptyString()][string]$Confirm,
    [Parameter(Mandatory = $true)][string]$ReadbackPath,
    [Parameter(Mandatory = $true)][string]$RunId,
    [Parameter(Mandatory = $true)][string]$RunAttempt
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
  Assert-GemRecoveryPromotionEnvironment -Repository $Repository -RunId $RunId -RunAttempt $RunAttempt
  Assert-GemProductionReleaseAbsent -Repository $Repository
  $date = [DateTime]::UtcNow.ToString('yyyy-MM-dd')
  $notes = "Built by Ruby4Lich5, commit $SourceSha. Released -- genesis manifest from $CandidateTag, smoke-tested and promoted $date. Single current artifact, overwritten in place by later promotions, not an incrementing version -- verify by SHA-256 digest, not by trusting the tag alone. Deliberately never claims the repo-wide 'Latest' designation (--latest=false) -- that's reserved for installer releases only."
  $created = $false
  try {
    Invoke-PromotionGh -Arguments @('release', 'create', $tag, '--repo', $Repository, '--target', $SourceSha, '--latest=false',
      '--title', "Gem bundle ($($platform.name))", '--notes', $notes) | Out-Null
    $created = $true
    Invoke-PromotionGh -Arguments @('release', 'upload', $tag, $CandidatePath, '--repo', $Repository) | Out-Null
    Confirm-LiveGemManifest -Repository $Repository -ExpectedDigest $ExpectedCandidateDigest -DestinationPath $ReadbackPath
  } catch {
    $originalError = $_.Exception.Message
    if (-not $created) { throw "Genesis failed before a release was created: $originalError; inspect $tag before retrying." }
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
