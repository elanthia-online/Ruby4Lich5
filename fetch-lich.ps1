# Fetches Lich from elanthia-online/lich-5's own GitHub Releases at install
# time, rather than baking a specific Lich payload in at CI build time.
# Bundled into the installer via [Files] Flags: dontcopy -- extracted to {tmp}
# by Inno Setup at runtime, invoked from [Code], never part of the installed
# tree itself.
#
# Always fetches latest -- deliberately no tag-override parameter (2026-07-08:
# considered and dropped for this iteration; a user wanting a specific
# non-latest Lich can grab it directly from the EO/lich-5 release page today,
# and that need may end up served by update.rb's own eventual self-heal logic
# instead of a Windows-installer command-line flag).
#
# Extracts into $DestDir's *parent* -- the real lich-5.zip asset already
# contains a top-level Lich5/ folder (confirmed directly against the real
# asset, and cross-verified against elanthia-online/lich-5's own
# release-on-push-stable.yaml, which does the same unzip-and-expect-Lich5/
# dance at build time today) -- so extracting into $DestDir's parent lands
# the content at exactly $DestDir.
#
# Invoke-LichFetch is a plain function, not top-level script code -- lets
# spec/powershell/fetch-lich.Tests.ps1 dot-source this file and call it
# directly with mocked cmdlets, real behavioral coverage instead of only a
# syntax check. It throws on failure rather than calling exit (exit inside a
# function would kill the whole test process on the first failure path); the
# bottom guard converts that into the real exit-code/stdout contract Inno
# Setup's Exec + ResultCode depends on, but only when actually run as a
# script -- $MyInvocation.InvocationName is '.' when dot-sourced, so the
# guard is a no-op during tests.

param(
  # Not Mandatory here -- spec/powershell/fetch-lich.Tests.ps1 dot-sources this
  # file with no args to reach Invoke-LichFetch directly, and a Mandatory
  # top-level param blocks on a missing-value prompt in that non-interactive
  # context. Required-ness is enforced below, only on the direct-execution path.
  [string]$DestDir
)

function Invoke-LichFetch {
  param(
    [Parameter(Mandatory = $true)][string]$DestDir
  )

  # Unlike every other PowerShell step in this repo (all GH Actions
  # windows-latest, already TLS 1.2 by default), this runs on an end user's
  # own, arbitrary Windows PowerShell 5.1 -- ServicePointManager can still
  # default to an older protocol there depending on OS/.NET Framework
  # vintage, and GitHub requires TLS 1.2+. Set explicitly, not assumed.
  [Net.ServicePointManager]::SecurityProtocol = [Net.SecurityProtocolType]::Tls12

  $headers = @{ 'User-Agent' = 'Ruby4Lich5-Installer' }

  # -TimeoutSec explicitly on both network calls below -- Invoke-RestMethod and
  # Invoke-WebRequest default to TimeoutSec=0 (indefinite) on Windows PowerShell
  # 5.1, so a dead/firewalled connection would otherwise hang Exec's
  # ewWaitUntilTerminated wait in the .iss forever, with no cancel path for the
  # user. 30s covers the small JSON metadata call (plus slow DNS, which can
  # itself take up to 15s); 120s covers the zip download on a slow connection.
  $release = Invoke-RestMethod -Uri 'https://api.github.com/repos/elanthia-online/lich-5/releases/latest' -Headers $headers -UseBasicParsing -TimeoutSec 30

  $tag = $release.tag_name
  $asset = $release.assets | Where-Object { $_.name -eq 'lich-5.zip' }
  if (-not $asset) {
    throw "lich-5.zip not found in release $tag"
  }

  # [System.IO.Path]::GetTempPath() over $env:TEMP -- the latter is Windows-only
  # and is $null under pwsh on macOS/Linux, which is where this suite actually
  # runs locally (this script's only real execution target is still Windows,
  # via powershell.exe from Inno Setup's [Code]; GetTempPath() resolves
  # correctly there too).
  $zipPath = Join-Path ([System.IO.Path]::GetTempPath()) 'lich-5-fetch.zip'
  Invoke-WebRequest -Uri $asset.browser_download_url -OutFile $zipPath -Headers $headers -UseBasicParsing -TimeoutSec 120

  # GitHub's own Releases API reports a real sha256 digest per asset (present
  # on this exact unauthenticated endpoint, confirmed directly -- no token
  # available or needed here, this runs on an end user's machine). Verified
  # before extraction: this is the one trust anchor on the only download in
  # the whole repo that runs outside CI, so a mismatch fails closed rather
  # than silently extracting and installing a corrupted or tampered archive.
  if ($asset.digest -notmatch '^sha256:[0-9a-f]{64}$') {
    Remove-Item $zipPath -Force -ErrorAction SilentlyContinue
    throw "Release $tag returned a missing or malformed digest for lich-5.zip -- got '$($asset.digest)'. Refusing to install an unverified download."
  }
  $localZipDigest = "sha256:" + (Get-FileHash -Path $zipPath -Algorithm SHA256).Hash.ToLowerInvariant()
  if ($localZipDigest -ne $asset.digest) {
    Remove-Item $zipPath -Force -ErrorAction SilentlyContinue
    throw "lich-5.zip digest mismatch -- expected $($asset.digest), got $localZipDigest. Download may be corrupted or tampered with."
  }

  $parent = Split-Path $DestDir -Parent
  if (Test-Path $DestDir) {
    Remove-Item $DestDir -Recurse -Force
  }
  New-Item -ItemType Directory -Path $parent -Force | Out-Null
  Expand-Archive -Path $zipPath -DestinationPath $parent -Force
  Remove-Item $zipPath -Force

  if (!(Test-Path $DestDir)) {
    throw "Expected extracted content at $DestDir after unzip, not found."
  }

  $recordPath = Join-Path $DestDir 'lich-fetched.txt'
  "tag=$tag`nfetched_at=$(Get-Date -Format o)" | Set-Content -Path $recordPath -Encoding utf8

  return $tag
}

if ($MyInvocation.InvocationName -ne '.') {
  $ErrorActionPreference = 'Stop'
  try {
    if ([string]::IsNullOrWhiteSpace($DestDir)) {
      throw "DestDir is required. Usage: fetch-lich.ps1 -DestDir <path>"
    }

    # Hard backstop on top of the -TimeoutSec values inside Invoke-LichFetch:
    # -TimeoutSec is a stall-detection timeout, but Invoke-WebRequest -OutFile
    # has a documented, reported bug where it doesn't reliably honor -TimeoutSec
    # and can hang anyway (PowerShell/PowerShell#4679). Running the fetch as a
    # background job lets Wait-Job -Timeout kill it at the OS-process level
    # regardless of which layer's timeout actually fires -- confirmed locally
    # (Start-Job + Wait-Job -Timeout correctly detects a still-running job and
    # Remove-Job -Force reliably tears it down). Exec's ewWaitUntilTerminated
    # wait in the .iss is now bounded no matter what. Only wraps this
    # real-execution path, not Invoke-LichFetch itself -- Start-Job runs in a
    # separate process with its own session state, which Pester's Mock cannot
    # reach into, so spec/powershell/fetch-lich.Tests.ps1's direct, mocked
    # calls to Invoke-LichFetch are unaffected.
    $job = Start-Job -ScriptBlock ${function:Invoke-LichFetch} -ArgumentList $DestDir
    try {
      if (-not (Wait-Job -Job $job -Timeout 180)) {
        throw "Lich fetch timed out after 180s -- network likely stalled or unreachable."
      }
      $resolvedTag = Receive-Job -Job $job -ErrorAction Stop
    } finally {
      Remove-Job -Job $job -Force -ErrorAction SilentlyContinue
    }

    Write-Output $resolvedTag
    exit 0
  } catch {
    Write-Error "Lich fetch failed: $($_.Exception.Message)"
    exit 1
  }
}
