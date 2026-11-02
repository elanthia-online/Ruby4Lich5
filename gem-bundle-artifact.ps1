. (Join-Path $PSScriptRoot 'upstream-gem-acquisition.ps1')
# Shared tested-source checks; omitted upstream gems use the checksummed map.
# This helper never publishes.


function Assert-GemBuildRun {
  param(
    [Parameter(Mandatory = $true)]$Run,
    [Parameter(Mandatory = $true)][string]$Repository,
    [Parameter(Mandatory = $true)][string]$RunId
  )

  if ($RunId -notmatch '\A[1-9][0-9]*\z' -or [string]$Run.id -ne $RunId -or
      $Run.repository.full_name -ne $Repository -or $Run.head_repository.full_name -ne $Repository -or
      $Run.path -ne '.github/workflows/ruby4-bundled-gems-suite.yml' -or
      $Run.event -ne 'workflow_dispatch' -or $Run.status -ne 'completed' -or $Run.conclusion -ne 'success' -or
      [string]$Run.head_sha -notmatch '\A[0-9a-f]{40}\z' -or [string]$Run.run_attempt -notmatch '\A[1-9][0-9]*\z') {
    throw 'Gem source must be a completed, successful manual gem-suite run in this repository.'
  }
}

function New-GemBundleMetadata {
  param(
    [Parameter(Mandatory = $true)][string]$Directory,
    [Parameter(Mandatory = $true)][string]$Repository,
    [Parameter(Mandatory = $true)][string]$RunId,
    [Parameter(Mandatory = $true)][int]$RunAttempt,
    [Parameter(Mandatory = $true)][string]$SourceSha,
    [Parameter(Mandatory = $true)][string]$RubyInstallerVersion,
    [Parameter(Mandatory = $true)][string]$RubyArchiveDigest
  )

  $files = @(Get-ChildItem -LiteralPath $Directory -File | Where-Object { $_.Name -ne 'gem-build-metadata.json' } |
    Sort-Object Name | ForEach-Object {
      [ordered]@{ name = $_.Name; sha256 = (Get-FileHash -LiteralPath $_.FullName -Algorithm SHA256).Hash.ToLowerInvariant() }
    })
  $metadata = [ordered]@{
    schema_version = 1
    repository = $Repository
    run_id = $RunId
    run_attempt = $RunAttempt
    source_sha = $SourceSha
    ruby_installer_version = $RubyInstallerVersion
    ruby_archive_digest = $RubyArchiveDigest
    platform = 'x64-mingw-ucrt'
    files = $files
  }
  $metadata | ConvertTo-Json -Depth 6 | Set-Content -LiteralPath (Join-Path $Directory 'gem-build-metadata.json') -Encoding utf8
}

function Read-VerifiedGemBundle {
  param(
    [Parameter(Mandatory = $true)][string]$Directory,
    [Parameter(Mandatory = $true)]$Run,
    [Parameter(Mandatory = $true)][string]$Repository,
    [Parameter(Mandatory = $true)][string]$RunId,
    [Parameter(Mandatory = $true)][string]$RubySeries
  )

  Assert-GemBuildRun -Run $Run -Repository $Repository -RunId $RunId
  return Read-VerifiedGemBundleFiles -Directory $Directory -Repository $Repository -RunId $RunId `
    -RunAttempt $Run.run_attempt -SourceSha $Run.head_sha -RubySeries $RubySeries
}

function Read-VerifiedGemBundleFiles {
  param(
    [Parameter(Mandatory = $true)][string]$Directory,
    [Parameter(Mandatory = $true)][string]$Repository,
    [Parameter(Mandatory = $true)][string]$RunId,
    [Parameter(Mandatory = $true)][int]$RunAttempt,
    [Parameter(Mandatory = $true)][string]$SourceSha,
    [Parameter(Mandatory = $true)][string]$RubySeries
  )
  if ($RunId -cnotmatch '\A[1-9][0-9]*\z' -or $RunAttempt -lt 1 -or $SourceSha -cnotmatch '\A[0-9a-f]{40}\z') {
    throw 'Invalid tested bundle identity.'
  }
  $items = @(Get-ChildItem -LiteralPath $Directory -Force)
  foreach ($item in $items) {
    if ($item.PSIsContainer -or ($item.Attributes -band [IO.FileAttributes]::ReparsePoint)) {
      throw "Gem artifact contains a directory or link: $($item.Name)"
    }
  }
  $metadata = Get-Content -LiteralPath (Join-Path $Directory 'gem-build-metadata.json') -Raw | ConvertFrom-Json
  if ($metadata.schema_version -ne 1 -or $metadata.repository -ne $Repository -or
      [string]$metadata.run_id -ne $RunId -or
      $metadata.source_sha -cne $SourceSha -or $metadata.platform -cne 'x64-mingw-ucrt') {
    throw 'Gem artifact identity does not match the selected run, source revision, or platform.'
  }
  if ($metadata.run_attempt -ne $RunAttempt) {
    throw 'Gem artifact attempt does not match the selected run attempt. Start a fresh gem-factory dispatch using Run workflow, wait for build and smoke to pass, then use the new run ID. Re-running jobs on the old run is not the recovery for this mismatch.'
  }
  if ($RubySeries -notmatch '\A[0-9]+\.[0-9]+\z' -or
      [string]$metadata.ruby_installer_version -notmatch '\A[0-9]+\.[0-9]+\.[0-9]+-[0-9]+\z' -or
      [string]$metadata.ruby_archive_digest -cnotmatch '\Asha256:[0-9a-f]{64}\z' -or
      -not $metadata.ruby_installer_version.StartsWith("$RubySeries.")) {
    throw 'Gem artifact RubyInstaller version/digest is invalid or does not match ruby-series.'
  }

  Restore-UpstreamGemPackages -Directory $Directory -Metadata $metadata

  $names = @{}
  foreach ($entry in @($metadata.files)) {
    $name = [string]$entry.name
    # Flat filenames only: no traversal, option injection, alternate streams,
    # wildcards, or case-insensitive duplicates on the Windows consumer.
    if ($name -cnotmatch '\A[A-Za-z0-9][A-Za-z0-9_.+-]*\z' -or
        $name -eq 'gem-build-metadata.json' -or $names.ContainsKey($name) -or
        [string]$entry.sha256 -cnotmatch '\A[0-9a-f]{64}\z') {
      throw 'Gem artifact contains an unsafe, duplicate, or malformed checksum entry.'
    }
    $path = Join-Path $Directory $name
    if (!(Test-Path -LiteralPath $path -PathType Leaf) -or
        (Get-FileHash -LiteralPath $path -Algorithm SHA256).Hash.ToLowerInvariant() -cne $entry.sha256) {
      throw "Gem artifact checksum mismatch or missing file: $name"
    }
    $names[$name] = $true
  }
  foreach ($item in $items) {
    if ($item.Name -ne 'gem-build-metadata.json' -and -not $names.ContainsKey($item.Name)) {
      throw "Gem artifact contains an unlisted file: $($item.Name)"
    }
  }
  foreach ($required in @('runtime-gems-manifest.txt', 'runtime-gems-install-targets.txt', 'install-runtime-gems.cmd', 'resolution-lock.json')) {
    if (-not $names.ContainsKey($required)) { throw "Gem artifact is missing required inventory: $required" }
  }
  $targets = @(Get-Content -LiteralPath (Join-Path $Directory 'runtime-gems-install-targets.txt') | Where-Object { $_.Trim() })
  $manifest = @(Get-Content -LiteralPath (Join-Path $Directory 'runtime-gems-manifest.txt') | Where-Object { $_.Trim() })
  $gems = @($names.Keys | Where-Object { $_ -clike '*.gem' } | Sort-Object)
  if ($targets.Count -eq 0 -or @($targets | Sort-Object -Unique).Count -ne $targets.Count) {
    throw 'Gem artifact install targets must be nonempty and unique.'
  }
  foreach ($target in $targets) {
    if ($target -cnotmatch '\A[A-Za-z0-9][A-Za-z0-9_.+-]*\.gem\z' -or -not $names.ContainsKey($target)) {
      throw "Gem artifact install target is not a checked local gem: $target"
    }
  }
  if (($gems -join "`n") -cne (($targets | Sort-Object) -join "`n") -or
      ($gems -join "`n") -cne (($manifest | Sort-Object) -join "`n")) {
    throw 'Gem artifact inventory and install targets do not describe the same gem files.'
  }
  return $metadata
}
