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
# Setup's ExecAndLogOutput + ResultCode depends on, but only when actually run as a
# script -- $MyInvocation.InvocationName is '.' when dot-sourced, so the
# guard is a no-op during tests.

param(
  # Not Mandatory here -- spec/powershell/fetch-lich.Tests.ps1 dot-sources this
  # file with no args to reach Invoke-LichFetch directly, and a Mandatory
  # top-level param blocks on a missing-value prompt in that non-interactive
  # context. Required-ness is enforced below, only on the direct-execution path.
  [string]$DestDir
)

# ---------------------------------------------------------------------------
# Network helpers. GitHub's REST API allows 60 unauthenticated requests an
# hour per IP address, which users on shared, VPN or work networks (and CI
# runners) can use up before Setup ever runs: a real installer acceptance run
# got an immediate HTTP 403 from the releases API. So every request is retried
# on transient failures, and when the API itself is unavailable the release is
# resolved from github.com's own release pages, which that limit does not
# cover. Both paths go through Assert-LichRelease and the same SHA-256 check
# before anything is extracted.
#
# These are plain top-level functions so Pester can call them with mocked
# cmdlets. The real run executes them in a Start-Job process, which receives
# only the script text it is given -- Get-LichFetchJobScript bundles every
# function named in $script:LichFetchJobFunctions into that text (and a spec
# checks the list covers every function the fetch calls).
# ---------------------------------------------------------------------------

# Tags lich-5 has published: v5.24.2, v5.10.0-beta.1, v5.11.0-rc.6, v5.9.2-ssl.
# Anchored with \A..\z (not ^..$, which accepts a trailing newline) and with no
# '/', '?', '#' or '%' possible, because the tag is placed into request URLs.
function Test-LichTag {
  param([AllowNull()][string]$Tag)
  return ($Tag -cmatch '\Av[0-9]+\.[0-9]+\.[0-9]+(-[0-9A-Za-z]+(\.[0-9A-Za-z]+)*)?\z')
}

# The only download location accepted on either path: HTTPS, github.com, this
# repository, this exact tag, the lich-5.zip asset.
function Get-LichAssetUrl {
  param([Parameter(Mandatory = $true)][string]$Tag)
  return "https://github.com/elanthia-online/lich-5/releases/download/$Tag/lich-5.zip"
}

# Reads one response header from either runtime's response object: Windows
# PowerShell 5.1 (the real installer runtime) throws a WebException whose
# Response is an HttpWebResponse with a WebHeaderCollection (string indexer);
# PowerShell 7 throws an HttpResponseException whose Response is an
# HttpResponseMessage with HttpHeaders (TryGetValues).
function Get-LichResponseHeader {
  param($Response, [Parameter(Mandatory = $true)][string]$Name)
  if ($null -eq $Response) { return $null }
  $headers = $Response.Headers
  if ($null -eq $headers) { return $null }
  if ($headers.PSObject.Methods['TryGetValues']) {
    $values = $null
    if ($headers.TryGetValues($Name, [ref]$values)) { return [string](@($values)[0]) }
    return $null
  }
  $value = $headers[$Name]
  if ($null -eq $value) { return $null }
  return [string](@($value)[0])
}

# Turns a failed request's ErrorRecord into what the retry policy needs.
# Status is $null when no HTTP response arrived at all (DNS, refused, timeout).
function Get-LichHttpFailure {
  param([Parameter(Mandatory = $true)]$ErrorRecord)
  $exception = $ErrorRecord.Exception
  $response = $null
  if ($exception -and $exception.PSObject.Properties['Response']) { $response = $exception.Response }
  $status = $null
  if ($null -ne $response -and $null -ne $response.StatusCode) { $status = [int]$response.StatusCode }

  $retryAfter = $null
  $raw = Get-LichResponseHeader -Response $response -Name 'Retry-After'
  $parsed = [long]0
  if ($raw -and [long]::TryParse($raw.Trim(), [ref]$parsed) -and $parsed -ge 0) { $retryAfter = $parsed }

  $resetIn = $null
  $remaining = Get-LichResponseHeader -Response $response -Name 'X-RateLimit-Remaining'
  $reset = Get-LichResponseHeader -Response $response -Name 'X-RateLimit-Reset'
  $resetEpoch = [long]0
  if ($remaining -eq '0' -and $reset -and [long]::TryParse($reset.Trim(), [ref]$resetEpoch)) {
    $resetIn = [math]::Max([long]0, $resetEpoch - [DateTimeOffset]::UtcNow.ToUnixTimeSeconds())
  }

  # GitHub signals its primary limit as 403/429 with X-RateLimit-Remaining: 0,
  # and its secondary limit as 403/429 with Retry-After.
  $rateLimited = ($status -eq 429) -or (($status -eq 403) -and (($remaining -eq '0') -or ($null -ne $retryAfter)))

  $description = if ($null -eq $status) { "network error ($($exception.Message))" } else { "HTTP $status" }
  if ($rateLimited) { $description += ' (GitHub rate limit)' }

  return [pscustomobject]@{
    Status        = $status
    RetryAfterSec = $retryAfter
    ResetInSec    = $resetIn
    RateLimited   = $rateLimited
    Description   = $description
  }
}

# Seconds to wait before retrying, or -1 to stop retrying this request.
# Retried: no response at all, 408, 429, 5xx, and a rate-limited 403. Not
# retried: any other 4xx (a plain 403 or 404 will not change in seconds).
# A wait GitHub asks for (Retry-After, or the rate-limit reset time) is
# honoured only if it fits under MaxWaitSec and the remaining BudgetSec;
# otherwise this request gives up at once -- the primary limit can reset up to
# an hour later, and an installer must not sit on a spinner for that long when
# the github.com fallback is not subject to that limit anyway.
function Get-LichRetryDelay {
  param(
    [Parameter(Mandatory = $true)]$Failure,
    [Parameter(Mandatory = $true)][int]$Attempt,
    [Parameter(Mandatory = $true)][int]$BudgetSec,
    [int]$MaxWaitSec = 30
  )
  $status = $Failure.Status
  $retryable = ($null -eq $status) -or ($status -eq 408) -or ($status -eq 429) -or
    ($status -ge 500 -and $status -le 599) -or (($status -eq 403) -and $Failure.RateLimited)
  if (-not $retryable) { return -1 }

  # [double], not [int]: a reset time far in the future (or a huge
  # Retry-After) must compare as "too long", not overflow.
  if ($null -ne $Failure.RetryAfterSec) {
    $delay = [double]$Failure.RetryAfterSec
  } elseif ($null -ne $Failure.ResetInSec) {
    $delay = [double]$Failure.ResetInSec + 1
  } else {
    $delay = [math]::Pow(2, $Attempt)
  }
  if ($delay -gt $MaxWaitSec -or $delay -gt $BudgetSec) { return -1 }
  return [int]$delay
}

# Runs Action, retrying per Get-LichRetryDelay up to MaxAttempts times.
# State is shared across the whole fetch: WaitBudgetSec caps the total time
# spent sleeping, and RateLimited records that GitHub rate-limited any request
# so the final error can say so. Throws "<What> failed: <reason>" on give-up.
function Invoke-LichWithRetry {
  param(
    [Parameter(Mandatory = $true)][scriptblock]$Action,
    [Parameter(Mandatory = $true)][string]$What,
    [Parameter(Mandatory = $true)][hashtable]$State,
    [int]$MaxAttempts = 3
  )
  for ($attempt = 1; ; $attempt++) {
    try {
      return (& $Action)
    } catch {
      $failure = Get-LichHttpFailure -ErrorRecord $_
      if ($failure.RateLimited) { $State.RateLimited = $true }
      $delay = -1
      if ($attempt -lt $MaxAttempts) {
        $delay = Get-LichRetryDelay -Failure $failure -Attempt $attempt -BudgetSec $State.WaitBudgetSec
      }
      if ($delay -lt 0) {
        throw "$What failed: $($failure.Description)"
      }
      $State.WaitBudgetSec -= $delay
      Write-Information -MessageData "GitHub did not respond ($($failure.Description)); retrying in ${delay}s..." -Tags 'LichPhase'
      Start-Sleep -Seconds $delay
    }
  }
}

# Primary path: the REST API's latest-release JSON, which carries the asset's
# SHA-256 digest in structured form.
function Get-LichReleaseFromApi {
  param([Parameter(Mandatory = $true)][hashtable]$RequestHeaders, [Parameter(Mandatory = $true)][hashtable]$State)
  $release = Invoke-LichWithRetry -What 'GitHub API request' -State $State -Action {
    Invoke-RestMethod -Uri 'https://api.github.com/repos/elanthia-online/lich-5/releases/latest' -Headers $RequestHeaders -UseBasicParsing -TimeoutSec 30
  }
  $asset = @($release.assets | Where-Object { $_.name -eq 'lich-5.zip' }) | Select-Object -First 1
  return [pscustomobject]@{
    Tag    = [string]$release.tag_name
    Found  = ($null -ne $asset)
    Url    = if ($asset) { [string]$asset.browser_download_url } else { $null }
    Digest = if ($asset) { [string]$asset.digest } else { $null }
  }
}

# The final URL a followed redirect landed on: HttpWebResponse.ResponseUri on
# Windows PowerShell 5.1, HttpResponseMessage.RequestMessage.RequestUri on 7.
function Get-LichFinalUri {
  param($Response)
  $base = $Response.BaseResponse
  if ($null -eq $base) { return $null }
  if ($base.PSObject.Properties['ResponseUri'] -and $base.ResponseUri) { return [string]$base.ResponseUri }
  if ($base.PSObject.Properties['RequestMessage'] -and $base.RequestMessage -and $base.RequestMessage.RequestUri) {
    return [string]$base.RequestMessage.RequestUri
  }
  return $null
}

# Reads an asset's digest from github.com's expanded_assets fragment, which
# renders each digest as
#   <clipboard-copy aria-label="Copy to clipboard digest for lich-5.zip" value="sha256:...">
# Returns $null unless exactly one distinct value is labelled for exactly this
# asset name -- the caller then refuses to install (fails closed). The value's
# format is checked by Assert-LichRelease, the same as on the API path.
function Get-LichDigestFromAssetsHtml {
  param([AllowNull()][string]$Html, [Parameter(Mandatory = $true)][string]$AssetName)
  if ([string]::IsNullOrEmpty($Html)) { return $null }
  $label = "Copy to clipboard digest for $AssetName"
  $values = @()
  foreach ($element in [regex]::Matches($Html, '<clipboard-copy\b[^>]*>')) {
    $text = $element.Value
    $labelMatch = [regex]::Match($text, '\saria-label="([^"]*)"')
    $valueMatch = [regex]::Match($text, '\svalue="([^"]*)"')
    if ($labelMatch.Success -and $valueMatch.Success -and $labelMatch.Groups[1].Value -ceq $label) {
      $values += $valueMatch.Groups[1].Value
    }
  }
  $distinct = @($values | Select-Object -Unique)
  if ($distinct.Count -ne 1) { return $null }
  return $distinct[0]
}

# Fallback path, used only when the API request itself fails: no REST API at
# all. github.com/<repo>/releases/latest redirects to .../releases/tag/<tag>;
# the tag is validated before it goes into any further URL, and every later
# request is pinned to that tag (not /latest/download) so the digest and the
# bytes come from the same release even if a new one is published meanwhile.
function Get-LichReleaseFromWeb {
  param([Parameter(Mandatory = $true)][hashtable]$RequestHeaders, [Parameter(Mandatory = $true)][hashtable]$State)
  $page = Invoke-LichWithRetry -What 'github.com latest-release lookup' -State $State -Action {
    Invoke-WebRequest -Uri 'https://github.com/elanthia-online/lich-5/releases/latest' -Headers $RequestHeaders -UseBasicParsing -TimeoutSec 30
  }
  $final = Get-LichFinalUri -Response $page
  $uri = $null
  if (-not $final -or -not [uri]::TryCreate($final, [UriKind]::Absolute, [ref]$uri)) {
    throw 'github.com latest-release lookup did not report where it redirected.'
  }
  $pathMatch = [regex]::Match($uri.AbsolutePath, '\A/elanthia-online/lich-5/releases/tag/([^/]+)\z')
  if ($uri.Scheme -cne 'https' -or $uri.Host -ne 'github.com' -or -not $pathMatch.Success) {
    throw "github.com latest-release lookup redirected to an unexpected location: $final"
  }
  $tag = $pathMatch.Groups[1].Value
  if (-not (Test-LichTag -Tag $tag)) {
    throw "github.com latest-release lookup returned an unexpected tag '$tag'."
  }
  $assets = Invoke-LichWithRetry -What "github.com asset list for $tag" -State $State -Action {
    Invoke-WebRequest -Uri "https://github.com/elanthia-online/lich-5/releases/expanded_assets/$tag" -Headers $RequestHeaders -UseBasicParsing -TimeoutSec 30
  }
  $digest = Get-LichDigestFromAssetsHtml -Html ([string]$assets.Content) -AssetName 'lich-5.zip'
  return [pscustomobject]@{
    Tag    = $tag
    # The asset list names lich-5.zip only alongside its digest, so a missing
    # digest is reported as a missing or malformed digest, not a missing asset.
    Found  = $true
    Url    = Get-LichAssetUrl -Tag $tag
    Digest = $digest
  }
}

# The checks every resolved release must pass before anything is downloaded,
# whichever path resolved it.
function Assert-LichRelease {
  param([Parameter(Mandatory = $true)]$Release)
  $tag = $Release.Tag
  if (-not (Test-LichTag -Tag $tag)) {
    throw "GitHub returned an unexpected release tag '$tag'. Refusing to install it."
  }
  if (-not $Release.Found) {
    throw "lich-5.zip not found in release $tag"
  }
  $expectedUrl = Get-LichAssetUrl -Tag $tag
  if ($Release.Url -cne $expectedUrl) {
    throw "Release $tag lists lich-5.zip at an unexpected location '$($Release.Url)' (expected $expectedUrl). Refusing to download it."
  }
  if ($Release.Digest -cnotmatch '\Asha256:[0-9a-f]{64}\z') {
    throw "Release $tag returned a missing or malformed digest for lich-5.zip -- got '$($Release.Digest)'. Refusing to install an unverified download."
  }
}

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

  # Windows PowerShell 5.1 renders a progress bar for Invoke-WebRequest and
  # Expand-Archive even with no visible console, and that rendering makes both
  # several times slower. Set here, inside the function, because the real run
  # executes this function in a Start-Job process, which does not inherit
  # script-level preference variables.
  $ProgressPreference = 'SilentlyContinue'

  # Phase messages go to the Information stream, tagged LichPhase, so the
  # return value stays just the tag. Wait-LichFetchJob forwards them live as
  # "PHASE: ..." lines, which the installer shows under its status text.
  Write-Information -MessageData 'Finding the latest Lich release on GitHub...' -Tags 'LichPhase'

  $headers = @{ 'User-Agent' = 'Ruby4Lich5-Installer' }

  # Shared by every request below. WaitBudgetSec: at most 60s of retry sleeps
  # in total across the whole fetch, so that together with the request
  # timeouts the fetch still fits inside Wait-LichFetchJob's 300s backstop.
  $state = @{ WaitBudgetSec = 60; RateLimited = $false }

  # -TimeoutSec explicitly on every network call -- Invoke-RestMethod and
  # Invoke-WebRequest default to TimeoutSec=0 (indefinite) on Windows PowerShell
  # 5.1, so a dead/firewalled connection would otherwise hang ExecAndLogOutput's
  # ewWaitUntilTerminated wait in the .iss forever, with no cancel path for the
  # user. 30s covers each small metadata call (plus slow DNS, which can itself
  # take up to 15s); 120s covers the zip download on a slow connection.
  #
  # Only a failed API *request* falls back to github.com. A release the API
  # did describe (no lich-5.zip, a bad digest, a bad tag) is a real answer,
  # and fails below without a second opinion.
  try {
    $release = Get-LichReleaseFromApi -RequestHeaders $headers -State $state
  } catch {
    $apiError = $_.Exception.Message
    Write-Information -MessageData 'The GitHub API is unavailable; trying the github.com release page instead...' -Tags 'LichPhase'
    try {
      $release = Get-LichReleaseFromWeb -RequestHeaders $headers -State $state
    } catch {
      $message = "Could not find the latest Lich release. $apiError; $($_.Exception.Message)"
      if ($state.RateLimited) {
        $message += ' GitHub is rate-limiting requests from this network.'
      }
      throw $message
    }
  }

  Assert-LichRelease -Release $release
  $tag = $release.Tag

  # [System.IO.Path]::GetTempPath() over $env:TEMP -- the latter is Windows-only
  # and is $null under pwsh on macOS/Linux, which is where this suite actually
  # runs locally (this script's only real execution target is still Windows,
  # via powershell.exe from Inno Setup's [Code]; GetTempPath() resolves
  # correctly there too).
  $zipPath = Join-Path ([System.IO.Path]::GetTempPath()) 'lich-5-fetch.zip'
  Write-Information -MessageData "Downloading Lich $tag..." -Tags 'LichPhase'
  $downloadUrl = $release.Url
  try {
    Invoke-LichWithRetry -What "Downloading lich-5.zip for $tag" -State $state -Action {
      Invoke-WebRequest -Uri $downloadUrl -OutFile $zipPath -Headers $headers -UseBasicParsing -TimeoutSec 120
    } | Out-Null
  } catch {
    Remove-Item $zipPath -Force -ErrorAction SilentlyContinue
    $message = $_.Exception.Message
    if ($state.RateLimited) {
      $message += ' GitHub is rate-limiting requests from this network.'
    }
    throw $message
  }

  # The release's own sha256 digest -- from the API's asset record, or from
  # github.com's asset list on the fallback path; Assert-LichRelease has
  # already checked its format either way. Verified before extraction: this
  # is the one trust anchor on the only download in the whole repo that runs
  # outside CI, so a mismatch fails closed rather than silently extracting
  # and installing a corrupted or tampered archive.
  Write-Information -MessageData 'Verifying the download (SHA-256)...' -Tags 'LichPhase'
  $localZipDigest = "sha256:" + (Get-FileHash -Path $zipPath -Algorithm SHA256).Hash.ToLowerInvariant()
  if ($localZipDigest -cne $release.Digest) {
    Remove-Item $zipPath -Force -ErrorAction SilentlyContinue
    throw "lich-5.zip digest mismatch -- expected $($release.Digest), got $localZipDigest. Download may be corrupted or tampered with."
  }

  Write-Information -MessageData "Extracting Lich $tag..." -Tags 'LichPhase'
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

# Every function the job process needs, in definition order. The job gets
# only the text Get-LichFetchJobScript builds from these -- a function missing
# here works under Pester and fails on every real install.
$script:LichFetchJobFunctions = @(
  'Test-LichTag'
  'Get-LichAssetUrl'
  'Get-LichResponseHeader'
  'Get-LichHttpFailure'
  'Get-LichRetryDelay'
  'Invoke-LichWithRetry'
  'Get-LichReleaseFromApi'
  'Get-LichFinalUri'
  'Get-LichDigestFromAssetsHtml'
  'Get-LichReleaseFromWeb'
  'Assert-LichRelease'
  'Invoke-LichFetch'
)

# Builds the job's script block from the functions' own definitions plus the
# call. Built in memory with [scriptblock]::Create rather than having the job
# dot-source this file, so the job never depends on the execution policy that
# applies to loading a .ps1 file in a fresh process.
function Get-LichFetchJobScript {
  param([string[]]$FunctionNames = $script:LichFetchJobFunctions, [string]$Invocation = 'Invoke-LichFetch -DestDir $args[0]')
  $parts = foreach ($name in $FunctionNames) {
    "function $name {`n$((Get-Item -Path "function:$name").Definition)`n}"
  }
  return [scriptblock]::Create((@($parts) + $Invocation) -join "`n")
}

# Waits for the Invoke-LichFetch job, writing each LichPhase record the job
# produces as a "PHASE: <message>" line while the job is still running, then
# returns the job's own output (the resolved tag). Polls once a second, so a
# phase shows up at most about a second after the job writes it. Throws if the
# job runs past TimeoutSec, or rethrows the job's own error if it failed; the
# caller removes the job either way.
#
# Records are read from the child job's Information collection by index
# rather than through Receive-Job, which would also consume the job's output
# and errors before the job finishes. Records with other tags (for example
# Write-Host, which also uses the Information stream) are skipped.
function Wait-LichFetchJob {
  param(
    [Parameter(Mandatory = $true)][System.Management.Automation.Job]$Job,
    [int]$TimeoutSec = 300
  )

  $deadline = [DateTime]::UtcNow.AddSeconds($TimeoutSec)
  $records = $Job.ChildJobs[0].Information
  $seen = 0
  do {
    $finished = Wait-Job -Job $Job -Timeout 1
    while ($seen -lt $records.Count) {
      $record = $records[$seen]
      $seen++
      if ($record.Tags -contains 'LichPhase') {
        Write-Output "PHASE: $($record.MessageData)"
      }
    }
    if (-not $finished -and [DateTime]::UtcNow -ge $deadline) {
      throw "Lich fetch timed out after ${TimeoutSec}s -- network likely stalled or unreachable."
    }
  } until ($finished)

  Receive-Job -Job $Job -ErrorAction Stop
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
    # Remove-Job -Force reliably tears it down). ExecAndLogOutput's ewWaitUntilTerminated
    # wait in the .iss is now bounded no matter what. Only wraps this
    # real-execution path, not Invoke-LichFetch itself -- Start-Job runs in a
    # separate process with its own session state, which Pester's Mock cannot
    # reach into, so spec/powershell/fetch-lich.Tests.ps1's direct, mocked
    # calls to Invoke-LichFetch are unaffected.
    #
    # 300s: room for a 30s API call, the github.com fallback's two 30s
    # metadata calls, the 120s download and Invoke-LichFetch's 60s total
    # retry-sleep budget, plus slack. (It was 180s when the fetch was one API
    # call plus the download, with no retries or fallback.) A fetch whose
    # requests keep timing out one after another is cut off here instead.
    #
    # stdout contract with the installer's ExecAndLogOutput callback: zero or
    # more "PHASE: <message>" lines while the fetch runs, then the resolved
    # tag as the final line (exit 0), or a "FAILURE: <reason>" line (exit 1).
    # Each line goes straight to [Console]::Out and is flushed, so the
    # installer gets it the moment it happens instead of whenever redirected
    # output next fills a buffer.
    [Console]::Out.WriteLine('PHASE: Starting the Lich download...')
    [Console]::Out.Flush()
    $job = Start-Job -ScriptBlock (Get-LichFetchJobScript) -ArgumentList $DestDir
    try {
      $resolvedTag = $null
      Wait-LichFetchJob -Job $job -TimeoutSec 300 | ForEach-Object {
        if ("$_".StartsWith('PHASE: ')) {
          [Console]::Out.WriteLine($_)
          [Console]::Out.Flush()
        } else {
          $resolvedTag = $_
        }
      }
    } finally {
      Remove-Job -Job $job -Force -ErrorAction SilentlyContinue
    }

    [Console]::Out.WriteLine($resolvedTag)
    [Console]::Out.Flush()
    exit 0
  } catch {
    # One "FAILURE: <reason>" line on stdout, which the installer's callback
    # picks out and shows the user on its finished page, then the same reason
    # on stderr (both streams end up in the Setup log), then the exit code.
    # Explicit writes and exit rather than Write-Error: under
    # $ErrorActionPreference = 'Stop', Write-Error would itself terminate
    # the script before anything after it ran.
    $reason = ($_.Exception.Message -replace '[\r\n]+', ' ').Trim()
    [Console]::Out.WriteLine("FAILURE: $reason")
    [Console]::Out.Flush()
    [Console]::Error.WriteLine("Lich fetch failed: $reason")
    [Console]::Error.Flush()
    exit 1
  }
}
