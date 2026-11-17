# Genesis: the first accepted manifest for a platform that has none. This file
# holds the proof that the platform's production release is absent; ordinary
# publication never calls it. See docs/PLATFORM-GENESIS.md.
. (Join-Path $PSScriptRoot 'platform-table.ps1')
. (Join-Path $PSScriptRoot 'gh-native.ps1')

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
