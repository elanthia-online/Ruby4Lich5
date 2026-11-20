# Candidate releases are immutable. This helper never writes a live release.
. (Join-Path $PSScriptRoot 'platform-table.ps1')
. (Join-Path $PSScriptRoot 'gh-native.ps1')

# gh for candidate publication: throws on a non-zero exit, else returns the output.
function Invoke-CandidateGh {
  param([Parameter(Mandatory = $true)][string[]]$Arguments)
  $result = Invoke-GhNative -Arguments $Arguments
  if ($result.ExitCode -ne 0) { throw "gh failed: $($result.Output)" }
  return $result.Output
}

# Release notes for a new candidate. Ordinary candidates are inspected and
# promoted against the platform's live predecessor; a genesis candidate is a
# platform's first manifest and has none (docs/PLATFORM-GENESIS.md).
function Get-GemCandidateReleaseNotes {
  param(
    [Parameter(Mandatory = $true)][ValidateSet('ordinary', 'genesis')][string]$Mode,
    [Parameter(Mandatory = $true)]$Platform
  )
  if ($Mode -ceq 'genesis') {
    $name = $Platform.name
    $production = $Platform.gem_bundle_tag
    return @"
Immutable first-platform (genesis) candidate for $name. There is no accepted predecessor: the production release $production does not exist yet, and publishing this candidate does not create it.

Follow the platform genesis runbook in docs/PLATFORM-GENESIS.md. Run promote-gem-candidate.yml with mode=inspect, platform=$name, genesis=true and this candidate-tag, and record the candidate and change-report SHA-256 values; live-sha256 must be absent. Then run mode=promote with platform=$name, genesis=true, the same candidate-tag, those exact candidate-sha256 and change-sha256 inputs, live-sha256=absent and genesis-confirm=$production. Do not use ordinary inspection (genesis=false): it requires a live predecessor, which this platform does not have.

The installer stays x64-only; this candidate builds and changes no installer.

Keep every candidate release and asset referenced by a served or retained rollback manifest. Never delete or replace those bytes. If promotion fails, follow the runbook's failure recovery section before retrying.
"@
  }
  # Matches the checked-in copy paths in docs/RELEASING.md step 9.
  $checkedIn = if ($Platform.name -ceq 'x64-mingw-ucrt') { 'manifest/R4L5-gem-manifest.json' } else { "manifest/$($Platform.name)/R4L5-gem-manifest.json" }
  return @"
Immutable candidate. Production assets are unchanged. Do not overwrite the production bundle or native gems.

Promotion requires the admin-controlled promote-gem-candidate.yml workflow delivered by PR #47; do not promote from PR #46 alone. Run mode=inspect for this candidate-tag, review its candidate, live predecessor and change-report SHA-256 values, then run mode=promote with those exact candidate-sha256, live-sha256 and change-sha256 inputs. A changed predecessor requires a new inspection.

After verified public readback, reconcile the emitted R4L5-gem-manifest.json into $checkedIn through owner-controlled Git history. Both installer sources validate against the live served manifest, not that repository snapshot, and verify the accepted digest again before finalizing provenance. The installer normally uses gem-source=actions with the successful gem-suite Actions run ID. After artifact expiry, use gem-source=accepted-candidate with this exact candidate tag and leave gem-build-run-id blank. The candidate manifest must exactly match the currently accepted manifest, which must bind this ZIP's digest; its complete tested metadata/inventories and exact RubyInstaller identity are verified again. No historical-manifest override, Actions-expiry fallback or mutable production ZIP is used.

Keep every candidate release and asset referenced by a served or retained rollback manifest. Never delete or replace those bytes. Promotion replaces only the served manifest; failures require verified restoration of the predecessor, or an administrative hold if restoration cannot be confirmed.
"@
}

function Publish-ImmutableGemCandidate {
  param(
    [Parameter(Mandatory = $true)][string]$Directory,
    [Parameter(Mandatory = $true)][string]$Repository,
    [Parameter(Mandatory = $true)][string]$Tag,
    [Parameter(Mandatory = $true)][string]$SourceSha,
    [ValidateSet('ordinary', 'genesis')][string]$Mode = 'ordinary'
  )

  $platform = Get-TargetPlatform
  if ($Tag -cnotmatch $platform.candidate_tag_pattern -or
      $Repository -cnotmatch '\A[A-Za-z0-9_.-]+/[A-Za-z0-9_.-]+\z' -or
      $SourceSha -cnotmatch '\A[0-9a-f]{40}\z') {
    throw 'Candidate publication requires a run/attempt tag, repository and full source SHA.'
  }
  $files = @(Get-ChildItem -LiteralPath $Directory -Force)
  $expected = @{}
  foreach ($file in $files) {
    if ($file.PSIsContainer -or ($file.Attributes -band [IO.FileAttributes]::ReparsePoint) -or
        $file.Name -cnotmatch '\A[A-Za-z0-9][A-Za-z0-9_.+-]*\z' -or $expected.ContainsKey($file.Name)) {
      throw 'Candidate assets must have unique flat filenames and contain no links.'
    }
    $expected[$file.Name] = 'sha256:' + (Get-FileHash -LiteralPath $file.FullName -Algorithm SHA256).Hash.ToLowerInvariant()
  }
  if (@($files.Name) -cnotcontains 'R4L5-gem-manifest.json' -or
      @($files.Name) -cnotcontains "$($platform.gem_bundle_tag).zip") {
    throw 'Candidate must include the consumer-named manifest and bundle.'
  }

  $viewArgs = @('release', 'view', $Tag, '--repo', $Repository, '--json', 'tagName,targetCommitish,isDraft,assets')
  $release = $null
  try {
    $release = (Invoke-CandidateGh -Arguments $viewArgs) | ConvertFrom-Json
    if ($null -eq $release) { throw 'Malformed candidate release response.' }
  } catch {
    # Transport/auth failures must never be treated as an absent release.
    if ($_.Exception.Message -notmatch '\Agh failed: release not found\s*\z') { throw }
  }
  if ($null -eq $release) {
    $notes = Get-GemCandidateReleaseNotes -Mode $Mode -Platform $platform
    $createArgs = @('release', 'create', $Tag) + @($files.FullName) + @(
      '--repo', $Repository, '--target', $SourceSha, '--prerelease', '--latest=false',
      '--title', "Gem bundle candidate $Tag", '--notes', $notes
    )
    Invoke-CandidateGh -Arguments $createArgs | Out-Null
  }

  for ($attempt = 1; $attempt -le 5; $attempt++) {
    if ($null -eq $release) { $release = (Invoke-CandidateGh -Arguments $viewArgs) | ConvertFrom-Json }
    if ($release.tagName -cne $Tag -or $release.targetCommitish -cne $SourceSha -or $release.isDraft) {
      throw 'Existing candidate identity differs; refusing any replacement.'
    }
    $assets = @($release.assets)
    if ($assets.Count -ne $expected.Count -or @($assets.name | Sort-Object -Unique).Count -ne $assets.Count) {
      throw 'Existing candidate asset inventory differs; refusing any replacement.'
    }
    $pending = $false
    foreach ($asset in $assets) {
      if (@($expected.Keys) -cnotcontains $asset.name) { throw 'Existing candidate has an unexpected asset.' }
      if ([string]::IsNullOrWhiteSpace($asset.digest)) {
        $pending = $true
      } elseif ($asset.digest -cne $expected[$asset.name]) {
        throw "Existing candidate bytes differ for $($asset.name); refusing any replacement."
      }
    }
    if (-not $pending) { return }
    if ($attempt -lt 5) { Start-Sleep -Seconds 2 }
    $release = $null
  }
  throw 'Candidate asset digests were not available after five reads.'
}
