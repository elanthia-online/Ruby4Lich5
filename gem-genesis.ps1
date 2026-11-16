# Genesis: the first accepted manifest for a platform that has none. Every
# check here refuses unless the platform's production release is proven
# absent; ordinary publication and promotion never call it.
. (Join-Path $PSScriptRoot 'platform-table.ps1')

# Returns the exit code and combined output so a clear HTTP 404 can be told
# apart from an authentication, rate-limit or network failure.
function Invoke-GenesisGh {
  param([Parameter(Mandatory = $true)][string[]]$Arguments)
  $output = & gh @Arguments 2>&1
  return [pscustomobject]@{ ExitCode = $LASTEXITCODE; Output = (@($output) -join "`n") }
}

# 'absent' only when the release and the git tag both answer HTTP 404 and no
# release this token can list (drafts included) carries the tag. 'release',
# 'tag' (a bare tag a new release would attach to) and 'draft' all mean the
# production name is taken. Any other failure throws: unknown is not absent.
function Get-GemProductionReleaseState {
  param(
    [Parameter(Mandatory = $true)][string]$Repository,
    [string]$Tag = (Get-TargetPlatform).gem_bundle_tag
  )
  if ($Repository -cnotmatch '\A[A-Za-z0-9_.-]+/[A-Za-z0-9_.-]+\z' -or $Tag -cnotmatch '\AR4L5-gem-bundle-[a-z0-9_]+-mingw-ucrt\z') {
    throw 'Invalid repository or production tag.'
  }
  $release = Invoke-GenesisGh -Arguments @('api', "repos/$Repository/releases/tags/$Tag")
  if ($release.ExitCode -eq 0) { return 'release' }
  if ($release.Output -notmatch 'HTTP 404') { throw "Production release state is unknown: $($release.Output)" }
  $ref = Invoke-GenesisGh -Arguments @('api', "repos/$Repository/git/ref/tags/$Tag")
  if ($ref.ExitCode -eq 0) { return 'tag' }
  if ($ref.Output -notmatch 'HTTP 404') { throw "Production tag state is unknown: $($ref.Output)" }
  $listed = Invoke-GenesisGh -Arguments @('api', '--paginate', "repos/$Repository/releases?per_page=100", '--jq', '.[].tag_name')
  if ($listed.ExitCode -ne 0) { throw "Release listing failed: $($listed.Output)" }
  if (@($listed.Output -split "`r?`n") -ccontains $Tag) { return 'draft' }
  return 'absent'
}

function Assert-GemProductionReleaseAbsent {
  param([Parameter(Mandatory = $true)][string]$Repository)
  $tag = (Get-TargetPlatform).gem_bundle_tag
  $state = Get-GemProductionReleaseState -Repository $Repository -Tag $tag
  if ($state -cne 'absent') { throw "Genesis refused: $tag already exists ($state); use the normal accepted-predecessor path." }
}

# Genesis has no predecessor, so nothing may depend on one: no reuse of an
# accepted candidate and no lifecycle rule (shared across platforms) that
# would need predecessor bytes.
function Assert-GemGenesisInputs {
  param(
    [Parameter(Mandatory = $true)][string]$LifecyclePath,
    [AllowEmptyString()][string]$AcceptedCandidateTag
  )
  if (-not [string]::IsNullOrWhiteSpace($AcceptedCandidateTag)) {
    throw 'Genesis has no accepted candidate to reuse; leave accepted-candidate-tag blank.'
  }
  $policy = Get-Content -LiteralPath $LifecyclePath -Raw | ConvertFrom-Json
  $names = @($policy.PSObject.Properties | ForEach-Object { $_.Name } | Sort-Object)
  if (($names -join ',') -cne 'range_reader,ranges,schema,units' -or $policy.schema -ne 1 -or
      $policy.units -isnot [pscustomobject] -or @($policy.units.PSObject.Properties).Count -ne 0 -or
      $policy.ranges -isnot [pscustomobject] -or @($policy.ranges.PSObject.Properties).Count -ne 0 -or
      $null -ne $policy.range_reader) {
    throw 'Genesis requires config/gem-lifecycle.json without units, ranges or range_reader.'
  }
}
