# Candidate releases are immutable. This helper never writes a live release.

function Invoke-CandidateGh {
  param([Parameter(Mandatory = $true)][string[]]$Arguments)
  # Native stderr must reach the exit-code check on Windows PowerShell 5.1.
  # This preference is function-local; callers retain their own policy.
  $ErrorActionPreference = 'Continue'
  $output = & gh @Arguments 2>&1
  if ($LASTEXITCODE -ne 0) { throw "gh failed: $output" }
  return ($output -join "`n")
}

function Publish-ImmutableGemCandidate {
  param(
    [Parameter(Mandatory = $true)][string]$Directory,
    [Parameter(Mandatory = $true)][string]$Repository,
    [Parameter(Mandatory = $true)][string]$Tag,
    [Parameter(Mandatory = $true)][string]$SourceSha
  )

  if ($Tag -cnotmatch '\AR4L5-gem-bundle-x64-mingw-ucrt-candidate-[1-9][0-9]*-[1-9][0-9]*\z' -or
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
      @($files.Name) -cnotcontains 'R4L5-gem-bundle-x64-mingw-ucrt.zip') {
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
    $notes = @'
Immutable candidate. Production assets are unchanged. Do not overwrite the production bundle or native gems.

Promotion requires the admin-controlled promote-gem-candidate.yml workflow delivered by PR #47; do not promote from PR #46 alone. Run mode=inspect for this candidate-tag, review its candidate, live predecessor and change-report SHA-256 values, then run mode=promote with those exact candidate-sha256, live-sha256 and change-sha256 inputs. A changed predecessor requires a new inspection.

After verified public readback, reconcile the emitted R4L5-gem-manifest.json into manifest/R4L5-gem-manifest.json through owner-controlled Git history before building an installer. The installer requires the successful gem-suite Actions run ID for these exact tested bytes; it never uses the old production ZIP.

Keep every candidate release and asset referenced by a served or retained rollback manifest. Never delete or replace those bytes. Promotion replaces only the served manifest; failures require verified restoration of the predecessor, or an administrative hold if restoration cannot be confirmed.
'@
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
