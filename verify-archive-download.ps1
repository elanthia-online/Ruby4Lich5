# Shared download-and-verify primitive, per docs/DECISIONS.md Phase 18 SS1 --
# given a URL and an expected sha256 digest, downloads to a destination path,
# hashes the local file, and either returns that verified path or throws.
# Deliberately does not resolve "which release/tag/asset" (that's two
# genuinely different policies -- exact-tag lookup vs. latest-in-series --
# left local to each caller, per Phase 18's own explicit rejection of a
# single resolver abstraction) and does not extract the downloaded archive
# (extraction/installation shape differs per caller: 7z for the .7z archive
# consumers, a silent .exe install for build-ruby4lich5-installer.yaml).
#
# Invoke-VerifiedDownload is a plain function, not top-level script code --
# same shape as fetch-lich.ps1's own Invoke-LichFetch, for the same reason:
# spec/powershell/verify-archive-download.Tests.ps1 dot-sources this file and
# calls the function directly with mocked cmdlets, real behavioral coverage
# instead of only a syntax check. It throws on failure rather than calling
# exit (exit inside a function would kill the whole test process on the first
# failure path); the bottom guard converts that into a real exit-code/stdout
# contract, but only when actually run as a script --
# $MyInvocation.InvocationName is '.' when dot-sourced, so the guard is a
# no-op during tests.

param(
  # Not Mandatory here -- the spec file dot-sources this with no args to
  # reach Invoke-VerifiedDownload directly, and a Mandatory top-level param
  # blocks on a missing-value prompt in that non-interactive context.
  # Required-ness is enforced below, only on the direct-execution path.
  [string]$Url,
  [string]$ExpectedDigest,
  [string]$DestinationPath
)

function Invoke-VerifiedDownload {
  param(
    [Parameter(Mandatory = $true)][string]$Url,
    [Parameter(Mandatory = $true)][string]$ExpectedDigest,
    [Parameter(Mandatory = $true)][string]$DestinationPath,
    [int]$TimeoutSec = 60,
    [ValidateRange(1, 5)][int]$MaxAttempts = 3,
    [ValidateRange(0, 30)][int]$RetryDelaySeconds = 2
  )

  # Validated here, not just trusted from the caller -- every caller of this
  # helper already validates this shape before calling (the same
  # '^sha256:[0-9a-f]{64}$' check used throughout this project), but a shared
  # primitive that's the one place a real digest comparison happens should
  # not silently compare against a malformed value and either always fail or,
  # worse, coincidentally match.
  if ($ExpectedDigest -notmatch '^sha256:[0-9a-f]{64}$') {
    throw "ExpectedDigest is missing or malformed -- got '$ExpectedDigest'."
  }

  # Downloads to a staging file, never $DestinationPath directly, and only
  # moves it into place after verification succeeds -- real gap, found in
  # review 2026-07-12: Invoke-WebRequest -OutFile writes straight to
  # $DestinationPath, so any failure (transport error, digest mismatch)
  # would truncate or destroy whatever was already there before this
  # function's own cleanup ever ran. A caller with something already valid
  # at $DestinationPath must see it survive a failed re-verify attempt
  # untouched, not just get the same treatment as a bad download. The
  # staging file lives alongside $DestinationPath (same volume, so the
  # final move is a real rename, not a cross-volume copy) and is the only
  # thing ever deleted on failure.
  $stagingPath = "$DestinationPath.download-$([guid]::NewGuid().ToString('N'))"
  try {
    for ($attempt = 1; $attempt -le $MaxAttempts; $attempt++) {
      try {
        Invoke-WebRequest -Uri $Url -OutFile $stagingPath -UseBasicParsing -TimeoutSec $TimeoutSec | Out-Null
        break
      } catch {
        Remove-Item -LiteralPath $stagingPath -Force -ErrorAction SilentlyContinue
        $exception = $_.Exception
        $status = if ($exception.Response) { [int]$exception.Response.StatusCode } else { 0 }
        $transient = $status -in @(408, 429, 500, 502, 503, 504) -or
          $exception -is [System.TimeoutException] -or
          ($exception -is [System.Net.WebException] -and $exception.Status -in @(
            [System.Net.WebExceptionStatus]::Timeout, [System.Net.WebExceptionStatus]::ConnectFailure,
            [System.Net.WebExceptionStatus]::ConnectionClosed, [System.Net.WebExceptionStatus]::NameResolutionFailure,
            [System.Net.WebExceptionStatus]::ReceiveFailure, [System.Net.WebExceptionStatus]::SendFailure
          ))
        if (-not $transient -or $attempt -eq $MaxAttempts) { throw }
        Start-Sleep -Seconds $RetryDelaySeconds
      }
    }
    if (!(Test-Path $stagingPath)) {
      throw "Download failed: expected file $stagingPath was not created."
    }

    $localDigest = "sha256:" + (Get-FileHash -Path $stagingPath -Algorithm SHA256).Hash.ToLowerInvariant()
    if ($localDigest -ne $ExpectedDigest) {
      throw "Digest mismatch for $DestinationPath -- expected $ExpectedDigest, got $localDigest. Refusing to trust this download."
    }

    Move-Item -Path $stagingPath -Destination $DestinationPath -Force
  } catch {
    Remove-Item $stagingPath -Force -ErrorAction SilentlyContinue
    throw
  }

  return $DestinationPath
}

if ($MyInvocation.InvocationName -ne '.') {
  $ErrorActionPreference = 'Stop'
  try {
    if ([string]::IsNullOrWhiteSpace($Url) -or [string]::IsNullOrWhiteSpace($ExpectedDigest) -or [string]::IsNullOrWhiteSpace($DestinationPath)) {
      throw "Url, ExpectedDigest, and DestinationPath are all required. Usage: verify-archive-download.ps1 -Url <url> -ExpectedDigest <sha256:...> -DestinationPath <path>"
    }

    $verifiedPath = Invoke-VerifiedDownload -Url $Url -ExpectedDigest $ExpectedDigest -DestinationPath $DestinationPath
    Write-Output $verifiedPath
    exit 0
  } catch {
    Write-Error "Verified download failed: $($_.Exception.Message)"
    exit 1
  }
}
