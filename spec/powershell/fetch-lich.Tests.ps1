BeforeAll {
  . "$PSScriptRoot/../../fetch-lich.ps1"

  # A failed request shaped like Windows PowerShell 5.1's, the installer's
  # real runtime: a WebException whose Response has an HttpStatusCode and a
  # WebHeaderCollection. WebException.Response is read-only and
  # HttpWebResponse has no public constructor, so that Response rides on the
  # exception as a note property. $Status 0 means no response at all (DNS,
  # refused, timeout), where 5.1's WebException.Response is $null.
  function New-FakeHttpError {
    param([int]$Status, [hashtable]$Headers = @{})
    $exception = [System.Net.WebException]::new("The remote server returned an error: ($Status).")
    if ($Status -ne 0) {
      $collection = [System.Net.WebHeaderCollection]::new()
      foreach ($key in $Headers.Keys) { $collection.Add($key, [string]$Headers[$key]) }
      $response = [pscustomobject]@{ StatusCode = [System.Net.HttpStatusCode]$Status; Headers = $collection }
      $exception | Add-Member -NotePropertyName Response -NotePropertyValue $response -Force
    }
    return $exception
  }

  function Invoke-FakeHttpFailure {
    param([int]$Status, [hashtable]$Headers = @{})
    throw (New-FakeHttpError -Status $Status -Headers $Headers)
  }

  function New-FakeErrorRecord {
    param([int]$Status, [hashtable]$Headers = @{})
    try { Invoke-FakeHttpFailure -Status $Status -Headers $Headers } catch { return $_ }
  }

  $script:ZipDigest = 'sha256:6eed189751741e7113aee78d525d04bdfd1b87f6529a155818f88071e083b8e4'
  $script:ApiRelease = [pscustomobject]@{
    tag_name = 'v5.18.0'
    assets   = @([pscustomobject]@{ name = 'lich-5.zip'; browser_download_url = 'https://github.com/elanthia-online/lich-5/releases/download/v5.18.0/lich-5.zip'; digest = $script:ZipDigest })
  }

  # Verbatim element shape from the real github.com expanded_assets fragment
  # for lich-5 v5.24.2 (other markup trimmed), with this suite's digest.
  function New-AssetsHtml {
    param([string]$ZipDigest = $script:ZipDigest)
    @"
<li class="Box-row d-flex flex-column flex-md-row">
  <a href="/elanthia-online/lich-5/releases/download/v5.18.0/lich-5.tar.gz" rel="nofollow" data-turbo="false" data-view-component="true" class="Truncate"><span data-view-component="true" class="Truncate-text text-bold">lich-5.tar.gz</span></a>
  <clipboard-copy id="clipboard-button-sha256:2346b21afba1fff0455c524f5c9ee05c49f73925ceece3bdca1e55a6f0dd9c8d" aria-label="Copy to clipboard digest for lich-5.tar.gz" type="button" value="sha256:2346b21afba1fff0455c524f5c9ee05c49f73925ceece3bdca1e55a6f0dd9c8d" data-view-component="true" class="Button--invisible Button--small Button Button--invisible-noVisuals color-fg-muted">
</li>
<li class="Box-row d-flex flex-column flex-md-row">
  <a href="/elanthia-online/lich-5/releases/download/v5.18.0/lich-5.zip" rel="nofollow" data-turbo="false" data-view-component="true" class="Truncate"><span data-view-component="true" class="Truncate-text text-bold">lich-5.zip</span></a>
  <clipboard-copy id="clipboard-button-$ZipDigest" aria-label="Copy to clipboard digest for lich-5.zip" type="button" value="$ZipDigest" data-view-component="true" class="Button--invisible Button--small Button Button--invisible-noVisuals color-fg-muted">
</li>
"@
  }

  # Invoke-WebRequest result after following /releases/latest, in either
  # runtime's shape: 5.1 HttpWebResponse.ResponseUri or 7
  # HttpResponseMessage.RequestMessage.RequestUri.
  function New-RedirectedPage {
    param([string]$FinalUri, [switch]$Pwsh7Shape)
    if ($Pwsh7Shape) {
      return [pscustomobject]@{ BaseResponse = [pscustomobject]@{ RequestMessage = [pscustomobject]@{ RequestUri = [uri]$FinalUri } } }
    }
    return [pscustomobject]@{ BaseResponse = [pscustomobject]@{ ResponseUri = [uri]$FinalUri } }
  }
}

Describe 'Invoke-LichFetch' {
  BeforeEach {
    # A real, resolvable path on whatever OS is actually running the suite --
    # Pester creates $TestDrive as a genuine temp directory, so Join-Path/
    # Split-Path/Set-Content -Path all behave identically to the real Windows
    # target here. The production code (fetch-lich.ps1) is only ever run
    # against a real Windows path in practice; a literal 'C:\...' string in
    # a fixture isn't a more "realistic" test, it's just one that happens to
    # only resolve on Windows -- $TestDrive is the portable equivalent.
    $script:DestDir = Join-Path (Join-Path (Join-Path $TestDrive 'App') 'R4LInstall') 'Lich5'
    $script:ExpectedParent = Split-Path $script:DestDir -Parent

    Mock Invoke-WebRequest { }
    Mock Expand-Archive { }
    Mock Remove-Item { }
    Mock Set-Content { }
    Mock New-Item { }
    Mock Test-Path { $true }
    # Real Get-FileHash's .Hash is uppercase, no sha256: prefix -- matches the
    # real cmdlet's shape, not just a convenient string, so a test asserting
    # the wrong case-handling in Invoke-LichFetch would actually catch it.
    Mock Get-FileHash { [pscustomobject]@{ Hash = '6EED189751741E7113AEE78D525D04BDFD1B87F6529A155818F88071E083B8E4' } }
    # No test may really sleep; retry tests assert on the requested seconds.
    Mock Start-Sleep { }
  }

  Context 'happy path' {
    BeforeEach {
      Mock Invoke-RestMethod {
        [pscustomobject]@{
          tag_name = 'v5.18.0'
          assets   = @(
            [pscustomobject]@{ name = 'lich-5.tar.gz'; browser_download_url = 'https://github.com/elanthia-online/lich-5/releases/download/v5.18.0/lich-5.tar.gz' }
            [pscustomobject]@{ name = 'lich-5.zip'; browser_download_url = 'https://github.com/elanthia-online/lich-5/releases/download/v5.18.0/lich-5.zip'; digest = 'sha256:6eed189751741e7113aee78d525d04bdfd1b87f6529a155818f88071e083b8e4' }
            [pscustomobject]@{ name = 'Ruby4Lich5.exe'; browser_download_url = 'https://github.com/elanthia-online/lich-5/releases/download/v5.18.0/Ruby4Lich5.exe' }
          )
        }
      }
    }

    It 'returns the resolved tag' {
      $result = Invoke-LichFetch -DestDir $script:DestDir
      $result | Should -Be 'v5.18.0'
    }

    It 'requests the latest release endpoint, not a specific tag' {
      Invoke-LichFetch -DestDir $script:DestDir | Out-Null
      Should -Invoke Invoke-RestMethod -Times 1 -ParameterFilter {
        $Uri -eq 'https://api.github.com/repos/elanthia-online/lich-5/releases/latest'
      }
    }

    It 'downloads specifically the lich-5.zip asset, not the tar.gz or the .exe' {
      Invoke-LichFetch -DestDir $script:DestDir | Out-Null
      Should -Invoke Invoke-WebRequest -Times 1 -ParameterFilter {
        $Uri -eq 'https://github.com/elanthia-online/lich-5/releases/download/v5.18.0/lich-5.zip'
      }
    }

    It 'extracts into the parent of DestDir, not DestDir itself' {
      # lich-5.zip already contains a top-level Lich5/ folder (verified
      # directly against the real asset) -- extracting into DestDir itself
      # would double-nest it.
      Invoke-LichFetch -DestDir $script:DestDir | Out-Null
      Should -Invoke Expand-Archive -Times 1 -ParameterFilter {
        $DestinationPath -eq $script:ExpectedParent
      }
    }

    It 'writes a lich-fetched.txt record containing the resolved tag' {
      Invoke-LichFetch -DestDir $script:DestDir | Out-Null
      Should -Invoke Set-Content -Times 1 -ParameterFilter {
        $Path -eq (Join-Path $script:DestDir 'lich-fetched.txt') -and $Value -match 'tag=v5\.18\.0'
      }
    }

    It 'sets TLS 1.2 before the first network call' {
      Mock Invoke-RestMethod {
        [Net.ServicePointManager]::SecurityProtocol | Should -Match 'Tls12'
        [pscustomobject]@{
          tag_name = 'v5.18.0'
          assets   = @([pscustomobject]@{ name = 'lich-5.zip'; browser_download_url = 'https://github.com/elanthia-online/lich-5/releases/download/v5.18.0/lich-5.zip'; digest = 'sha256:6eed189751741e7113aee78d525d04bdfd1b87f6529a155818f88071e083b8e4' })
        }
      }
      Invoke-LichFetch -DestDir $script:DestDir | Out-Null
    }

    It 'verifies the downloaded zip against the release-reported digest' {
      Invoke-LichFetch -DestDir $script:DestDir | Out-Null
      Should -Invoke Get-FileHash -Times 1 -ParameterFilter {
        $Path -like '*lich-5-fetch.zip'
      }
    }

    It 'removes a pre-existing DestDir before extracting, so a stale install cannot linger' {
      Invoke-LichFetch -DestDir $script:DestDir | Out-Null
      Should -Invoke Remove-Item -ParameterFilter { $Path -eq $script:DestDir }
    }

    It 'cleans up the downloaded zip after extraction' {
      Invoke-LichFetch -DestDir $script:DestDir | Out-Null
      Should -Invoke Remove-Item -ParameterFilter { $Path -like '*lich-5-fetch.zip' }
    }

    It 'reports each phase, in order, on the Information stream tagged LichPhase' {
      $result = Invoke-LichFetch -DestDir $script:DestDir -InformationVariable info
      $phases = @($info | Where-Object { $_.Tags -contains 'LichPhase' } | ForEach-Object { "$($_.MessageData)" })
      $phases | Should -Be @(
        'Finding the latest Lich release on GitHub...'
        'Downloading Lich v5.18.0...'
        'Verifying the download (SHA-256)...'
        'Extracting Lich v5.18.0...'
      )
      # Phases must not leak into the output stream: the job's output is the tag.
      @($result).Count | Should -Be 1
    }

    It 'turns off progress rendering before downloading (slow on Windows PowerShell 5.1)' {
      Mock Invoke-WebRequest { $ProgressPreference | Should -Be 'SilentlyContinue' }
      Invoke-LichFetch -DestDir $script:DestDir | Out-Null
      Should -Invoke Invoke-WebRequest -Times 1
    }
  }

  Context 'the release has no lich-5.zip asset' {
    BeforeEach {
      Mock Invoke-RestMethod {
        [pscustomobject]@{
          tag_name = 'v5.18.0'
          assets   = @([pscustomobject]@{ name = 'lich-5.tar.gz'; browser_download_url = 'https://github.com/elanthia-online/lich-5/releases/download/v5.18.0/lich-5.tar.gz' })
        }
      }
    }

    It 'throws naming the missing asset and the release tag' {
      { Invoke-LichFetch -DestDir $script:DestDir } | Should -Throw '*lich-5.zip not found in release v5.18.0*'
    }

    It 'never attempts a download once the asset is confirmed missing' {
      { Invoke-LichFetch -DestDir $script:DestDir } | Should -Throw
      Should -Invoke Invoke-WebRequest -Times 0
    }

    It 'does not announce a download it never starts' {
      $info = $null
      try { Invoke-LichFetch -DestDir $script:DestDir -InformationVariable info } catch { }
      @($info | ForEach-Object { "$($_.MessageData)" }) | Should -Be @('Finding the latest Lich release on GitHub...')
    }
  }

  Context 'extraction did not produce the expected DestDir' {
    BeforeEach {
      Mock Invoke-RestMethod {
        [pscustomobject]@{
          tag_name = 'v5.18.0'
          assets   = @([pscustomobject]@{ name = 'lich-5.zip'; browser_download_url = 'https://github.com/elanthia-online/lich-5/releases/download/v5.18.0/lich-5.zip'; digest = 'sha256:6eed189751741e7113aee78d525d04bdfd1b87f6529a155818f88071e083b8e4' })
        }
      }
      # First Test-Path call (pre-existing DestDir check) -> false;
      # second (post-extraction verification) -> false too, so this
      # exercises the real post-extraction guard, not the pre-clean check.
      Mock Test-Path { $false }
    }

    It 'throws rather than silently leaving the xcopy source empty' {
      { Invoke-LichFetch -DestDir $script:DestDir } | Should -Throw '*Expected extracted content*not found*'
    }
  }

  Context 'lich-5.zip digest does not match what was downloaded' {
    BeforeEach {
      Mock Invoke-RestMethod {
        [pscustomobject]@{
          tag_name = 'v5.18.0'
          assets   = @([pscustomobject]@{ name = 'lich-5.zip'; browser_download_url = 'https://github.com/elanthia-online/lich-5/releases/download/v5.18.0/lich-5.zip'; digest = 'sha256:6eed189751741e7113aee78d525d04bdfd1b87f6529a155818f88071e083b8e4' })
        }
      }
      # Deliberately different from the fixture's own digest above.
      Mock Get-FileHash { [pscustomobject]@{ Hash = 'FFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFF' } }
    }

    It 'throws naming both digests, rather than extracting an unverified download' {
      { Invoke-LichFetch -DestDir $script:DestDir } | Should -Throw '*digest mismatch*'
    }

    It 'never attempts extraction once the digest check fails' {
      { Invoke-LichFetch -DestDir $script:DestDir } | Should -Throw
      Should -Invoke Expand-Archive -Times 0
    }

    It 'cleans up the mismatched download rather than leaving it on disk' {
      { Invoke-LichFetch -DestDir $script:DestDir } | Should -Throw
      Should -Invoke Remove-Item -ParameterFilter { $Path -like '*lich-5-fetch.zip' }
    }
  }

  Context 'the release reports no digest for lich-5.zip' {
    BeforeEach {
      Mock Invoke-RestMethod {
        [pscustomobject]@{
          tag_name = 'v5.18.0'
          assets   = @([pscustomobject]@{ name = 'lich-5.zip'; browser_download_url = 'https://github.com/elanthia-online/lich-5/releases/download/v5.18.0/lich-5.zip' })
        }
      }
    }

    It 'throws rather than installing an unverifiable download' {
      { Invoke-LichFetch -DestDir $script:DestDir } | Should -Throw '*missing or malformed digest*'
    }

    It 'never attempts extraction once the digest is confirmed missing' {
      { Invoke-LichFetch -DestDir $script:DestDir } | Should -Throw
      Should -Invoke Expand-Archive -Times 0
    }
  }
}

Describe 'Invoke-LichFetch when GitHub fails or rate-limits a request' {
  BeforeEach {
    $script:DestDir = Join-Path (Join-Path (Join-Path $TestDrive 'App') 'R4LInstall') 'Lich5'
    $script:ZipUrl = 'https://github.com/elanthia-online/lich-5/releases/download/v5.18.0/lich-5.zip'
    $script:LatestUrl = 'https://github.com/elanthia-online/lich-5/releases/latest'
    $script:AssetsUrl = 'https://github.com/elanthia-online/lich-5/releases/expanded_assets/v5.18.0'
    $script:ApiCalls = 0
    $script:Slept = [System.Collections.Generic.List[int]]::new()

    Mock Invoke-WebRequest { }
    Mock Invoke-WebRequest -ParameterFilter { $Uri -eq $script:LatestUrl } {
      New-RedirectedPage -FinalUri 'https://github.com/elanthia-online/lich-5/releases/tag/v5.18.0'
    }
    Mock Invoke-WebRequest -ParameterFilter { $Uri -eq $script:AssetsUrl } {
      [pscustomobject]@{ Content = (New-AssetsHtml) }
    }
    Mock Expand-Archive { }
    Mock Remove-Item { }
    Mock Set-Content { }
    Mock New-Item { }
    Mock Test-Path { $true }
    Mock Get-FileHash { [pscustomobject]@{ Hash = '6EED189751741E7113AEE78D525D04BDFD1B87F6529A155818F88071E083B8E4' } }
    Mock Start-Sleep { $script:Slept.Add([int]$Seconds) }
  }

  Context 'the API answers after a transient failure' {
    It 'retries a secondary-rate-limit 403, waiting the Retry-After seconds, then succeeds via the API' {
      Mock Invoke-RestMethod {
        $script:ApiCalls++
        if ($script:ApiCalls -eq 1) { Invoke-FakeHttpFailure -Status 403 -Headers @{ 'Retry-After' = '5' } }
        $script:ApiRelease
      }
      Invoke-LichFetch -DestDir $script:DestDir | Should -Be 'v5.18.0'
      Should -Invoke Invoke-RestMethod -Times 2 -Exactly
      $script:Slept | Should -Be @(5)
      Should -Invoke Invoke-WebRequest -Times 0 -ParameterFilter { $Uri -eq $script:LatestUrl }
      Should -Invoke Invoke-WebRequest -Times 1 -Exactly -ParameterFilter { $Uri -eq $script:ZipUrl }
    }

    It 'retries <Name> with a short backoff' -ForEach @(
      @{ Name = 'a 503'; Status = 503 }
      @{ Name = 'a 429 with no wait header'; Status = 429 }
      @{ Name = 'a request that got no response at all'; Status = 0 }
    ) {
      Mock Invoke-RestMethod {
        $script:ApiCalls++
        if ($script:ApiCalls -eq 1) { Invoke-FakeHttpFailure -Status $Status }
        $script:ApiRelease
      }
      Invoke-LichFetch -DestDir $script:DestDir | Should -Be 'v5.18.0'
      Should -Invoke Invoke-RestMethod -Times 2 -Exactly
      $script:Slept | Should -Be @(2)
    }

    It 'waits for a primary rate limit that resets within the cap, then retries the API' {
      $reset = [DateTimeOffset]::UtcNow.ToUnixTimeSeconds() + 5
      Mock Invoke-RestMethod {
        $script:ApiCalls++
        if ($script:ApiCalls -eq 1) { Invoke-FakeHttpFailure -Status 403 -Headers @{ 'X-RateLimit-Remaining' = '0'; 'X-RateLimit-Reset' = "$reset" } }
        $script:ApiRelease
      }
      Invoke-LichFetch -DestDir $script:DestDir | Should -Be 'v5.18.0'
      $script:Slept.Count | Should -Be 1
      $script:Slept[0] | Should -BeGreaterOrEqual 4
      $script:Slept[0] | Should -BeLessOrEqual 6
    }

    It 'shows the retry on the LichPhase stream' {
      Mock Invoke-RestMethod {
        $script:ApiCalls++
        if ($script:ApiCalls -eq 1) { Invoke-FakeHttpFailure -Status 503 }
        $script:ApiRelease
      }
      Invoke-LichFetch -DestDir $script:DestDir -InformationVariable info | Out-Null
      @($info | ForEach-Object { "$($_.MessageData)" }) | Should -Contain 'GitHub did not respond (HTTP 503); retrying in 2s...'
    }

    It 'retries a failed download and still verifies it' {
      Mock Invoke-RestMethod { $script:ApiRelease }
      $script:Downloads = 0
      Mock Invoke-WebRequest -ParameterFilter { $Uri -eq $script:ZipUrl } {
        $script:Downloads++
        if ($script:Downloads -eq 1) { Invoke-FakeHttpFailure -Status 502 }
      }
      Invoke-LichFetch -DestDir $script:DestDir | Should -Be 'v5.18.0'
      Should -Invoke Invoke-WebRequest -Times 2 -Exactly -ParameterFilter { $Uri -eq $script:ZipUrl }
      Should -Invoke Get-FileHash -Times 1 -Exactly
    }
  }

  Context 'the API stays unavailable, so the release comes from github.com' {
    It 'falls back at once, without sleeping, when the rate limit resets beyond the cap' {
      $reset = [DateTimeOffset]::UtcNow.ToUnixTimeSeconds() + 3000
      Mock Invoke-RestMethod { Invoke-FakeHttpFailure -Status 403 -Headers @{ 'X-RateLimit-Remaining' = '0'; 'X-RateLimit-Reset' = "$reset" } }
      Invoke-LichFetch -DestDir $script:DestDir | Should -Be 'v5.18.0'
      Should -Invoke Invoke-RestMethod -Times 1 -Exactly
      $script:Slept.Count | Should -Be 0
      Should -Invoke Invoke-WebRequest -Times 1 -Exactly -ParameterFilter { $Uri -eq $script:LatestUrl }
      Should -Invoke Invoke-WebRequest -Times 1 -Exactly -ParameterFilter { $Uri -eq $script:AssetsUrl }
      Should -Invoke Invoke-WebRequest -Times 1 -Exactly -ParameterFilter { $Uri -eq $script:ZipUrl }
    }

    It 'falls back at once when Retry-After asks for longer than the cap' {
      Mock Invoke-RestMethod { Invoke-FakeHttpFailure -Status 403 -Headers @{ 'Retry-After' = '3600' } }
      Invoke-LichFetch -DestDir $script:DestDir | Should -Be 'v5.18.0'
      Should -Invoke Invoke-RestMethod -Times 1 -Exactly
      $script:Slept.Count | Should -Be 0
    }

    It 'does not retry a plain 403 or 404 from the API, and falls back' -ForEach @(@{ Status = 403 }, @{ Status = 404 }) {
      Mock Invoke-RestMethod { Invoke-FakeHttpFailure -Status $Status }
      Invoke-LichFetch -DestDir $script:DestDir | Should -Be 'v5.18.0'
      Should -Invoke Invoke-RestMethod -Times 1 -Exactly
      $script:Slept.Count | Should -Be 0
    }

    It 'never sleeps more than 60s in total, however often GitHub asks' {
      Mock Invoke-RestMethod { Invoke-FakeHttpFailure -Status 403 -Headers @{ 'Retry-After' = '25' } }
      Mock Invoke-WebRequest -ParameterFilter { $Uri -eq $script:LatestUrl } { Invoke-FakeHttpFailure -Status 429 -Headers @{ 'Retry-After' = '25' } }
      { Invoke-LichFetch -DestDir $script:DestDir } | Should -Throw
      ($script:Slept | Measure-Object -Sum).Sum | Should -BeLessOrEqual 60
      $script:Slept | Should -Be @(25, 25)
      Should -Invoke Invoke-RestMethod -Times 3 -Exactly
    }

    It 'stops after 3 attempts per request' {
      Mock Invoke-RestMethod { Invoke-FakeHttpFailure -Status 500 }
      Invoke-LichFetch -DestDir $script:DestDir | Should -Be 'v5.18.0'
      Should -Invoke Invoke-RestMethod -Times 3 -Exactly
      $script:Slept | Should -Be @(2, 4)
    }

    It 'pins the asset list and the download to the redirected tag, and verifies the digest from github.com' {
      Mock Invoke-RestMethod { Invoke-FakeHttpFailure -Status 403 -Headers @{ 'Retry-After' = '3600' } }
      Invoke-LichFetch -DestDir $script:DestDir | Should -Be 'v5.18.0'
      Should -Invoke Get-FileHash -Times 1 -Exactly
      Should -Invoke Expand-Archive -Times 1 -Exactly
      Should -Invoke Set-Content -Times 1 -ParameterFilter { $Value -match 'tag=v5\.18\.0' }
    }

    It 'reads the redirect target from a PowerShell 7 shaped response too' {
      Mock Invoke-RestMethod { Invoke-FakeHttpFailure -Status 503 }
      Mock Invoke-WebRequest -ParameterFilter { $Uri -eq $script:LatestUrl } {
        New-RedirectedPage -FinalUri 'https://github.com/elanthia-online/lich-5/releases/tag/v5.18.0' -Pwsh7Shape
      }
      Invoke-LichFetch -DestDir $script:DestDir | Should -Be 'v5.18.0'
    }

    It 'announces the fallback on the LichPhase stream' {
      Mock Invoke-RestMethod { Invoke-FakeHttpFailure -Status 404 }
      Invoke-LichFetch -DestDir $script:DestDir -InformationVariable info | Out-Null
      @($info | Where-Object { $_.Tags -contains 'LichPhase' } | ForEach-Object { "$($_.MessageData)" }) | Should -Be @(
        'Finding the latest Lich release on GitHub...'
        'The GitHub API is unavailable; trying the github.com release page instead...'
        'Downloading Lich v5.18.0...'
        'Verifying the download (SHA-256)...'
        'Extracting Lich v5.18.0...'
      )
    }
  }

  Context 'the github.com fallback must still verify everything' {
    BeforeEach {
      Mock Invoke-RestMethod { Invoke-FakeHttpFailure -Status 403 -Headers @{ 'Retry-After' = '3600' } }
    }

    It 'refuses a redirect to <Name>, before any further request' -ForEach @(
      @{ Name = 'the releases list (no tag)'; Final = 'https://github.com/elanthia-online/lich-5/releases' }
      @{ Name = 'another host'; Final = 'https://example.com/elanthia-online/lich-5/releases/tag/v5.18.0' }
      @{ Name = 'another repository'; Final = 'https://github.com/someone/lich-5/releases/tag/v5.18.0' }
      @{ Name = 'plain HTTP'; Final = 'http://github.com/elanthia-online/lich-5/releases/tag/v5.18.0' }
      @{ Name = 'a tag that is not a release version'; Final = 'https://github.com/elanthia-online/lich-5/releases/tag/main' }
      @{ Name = 'an encoded path in the tag'; Final = 'https://github.com/elanthia-online/lich-5/releases/tag/v5.18.0%2F..%2F..' }
    ) {
      Mock Invoke-WebRequest -ParameterFilter { $Uri -eq $script:LatestUrl } { New-RedirectedPage -FinalUri $Final }
      { Invoke-LichFetch -DestDir $script:DestDir } | Should -Throw '*latest-release lookup*'
      Should -Invoke Invoke-WebRequest -Times 1 -Exactly
      Should -Invoke Expand-Archive -Times 0
    }

    It 'refuses when the redirect target is not reported' {
      Mock Invoke-WebRequest -ParameterFilter { $Uri -eq $script:LatestUrl } { [pscustomobject]@{ BaseResponse = $null } }
      { Invoke-LichFetch -DestDir $script:DestDir } | Should -Throw '*did not report where it redirected*'
    }

    It 'refuses to download when the asset list carries <Name>' -ForEach @(
      @{ Name = 'no digest for lich-5.zip'; Html = '<clipboard-copy aria-label="Copy to clipboard digest for lich-5.tar.gz" value="sha256:2346b21afba1fff0455c524f5c9ee05c49f73925ceece3bdca1e55a6f0dd9c8d">' }
      @{ Name = 'a malformed digest'; Html = '<clipboard-copy aria-label="Copy to clipboard digest for lich-5.zip" value="sha256:XYZ">' }
      @{ Name = 'a non-sha256 digest'; Html = '<clipboard-copy aria-label="Copy to clipboard digest for lich-5.zip" value="md5:c46da79eb68ff53df3a7b2f1a14c67c8">' }
      @{ Name = 'two different digests for lich-5.zip'; Html = '<clipboard-copy aria-label="Copy to clipboard digest for lich-5.zip" value="sha256:6eed189751741e7113aee78d525d04bdfd1b87f6529a155818f88071e083b8e4"><clipboard-copy aria-label="Copy to clipboard digest for lich-5.zip" value="sha256:2346b21afba1fff0455c524f5c9ee05c49f73925ceece3bdca1e55a6f0dd9c8d">' }
      @{ Name = 'nothing at all'; Html = '' }
    ) {
      Mock Invoke-WebRequest -ParameterFilter { $Uri -eq $script:AssetsUrl } { [pscustomobject]@{ Content = $Html } }
      { Invoke-LichFetch -DestDir $script:DestDir } | Should -Throw '*missing or malformed digest*'
      Should -Invoke Invoke-WebRequest -Times 0 -ParameterFilter { $Uri -eq $script:ZipUrl }
      Should -Invoke Expand-Archive -Times 0
    }

    It 'does not extract a fallback download whose digest does not match' {
      Mock Get-FileHash { [pscustomobject]@{ Hash = 'FFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFF' } }
      { Invoke-LichFetch -DestDir $script:DestDir } | Should -Throw '*digest mismatch*'
      Should -Invoke Expand-Archive -Times 0
    }
  }

  Context 'nothing works' {
    It 'names both failures and says GitHub is rate-limiting' {
      Mock Invoke-RestMethod { Invoke-FakeHttpFailure -Status 403 -Headers @{ 'X-RateLimit-Remaining' = '0'; 'X-RateLimit-Reset' = '9999999999' } }
      Mock Invoke-WebRequest -ParameterFilter { $Uri -eq $script:LatestUrl } { Invoke-FakeHttpFailure -Status 404 }
      { Invoke-LichFetch -DestDir $script:DestDir } | Should -Throw 'Could not find the latest Lich release. GitHub API request failed: HTTP 403 (GitHub rate limit); github.com latest-release lookup failed: HTTP 404 GitHub is rate-limiting requests from this network.'
      Should -Invoke Invoke-WebRequest -Times 0 -ParameterFilter { $Uri -eq $script:ZipUrl }
    }

    It 'does not claim rate limiting when GitHub was simply unreachable' {
      Mock Invoke-RestMethod { Invoke-FakeHttpFailure -Status 0 }
      Mock Invoke-WebRequest -ParameterFilter { $Uri -eq $script:LatestUrl } { Invoke-FakeHttpFailure -Status 0 }
      $message = try { Invoke-LichFetch -DestDir $script:DestDir; '' } catch { $_.Exception.Message }
      $message | Should -BeLike 'Could not find the latest Lich release. GitHub API request failed: network error*'
      $message | Should -Not -BeLike '*rate-limiting*'
    }

    It 'says GitHub is rate-limiting when the download itself is, and removes the partial zip' {
      Mock Invoke-RestMethod { $script:ApiRelease }
      Mock Invoke-WebRequest -ParameterFilter { $Uri -eq $script:ZipUrl } { Invoke-FakeHttpFailure -Status 429 -Headers @{ 'Retry-After' = '600' } }
      { Invoke-LichFetch -DestDir $script:DestDir } | Should -Throw 'Downloading lich-5.zip for v5.18.0 failed: HTTP 429 (GitHub rate limit) GitHub is rate-limiting requests from this network.'
      Should -Invoke Remove-Item -ParameterFilter { $Path -like '*lich-5-fetch.zip' }
      Should -Invoke Expand-Archive -Times 0
    }
  }

  Context 'an API answer that fails validation is final, not a reason to fall back' {
    It 'refuses <Name> without asking github.com or downloading' -ForEach @(
      @{ Name = 'a missing lich-5.zip asset'; Release = [pscustomobject]@{ tag_name = 'v5.18.0'; assets = @() }; Error = '*lich-5.zip not found in release v5.18.0*' }
      @{ Name = 'an asset hosted elsewhere'; Release = [pscustomobject]@{ tag_name = 'v5.18.0'; assets = @([pscustomobject]@{ name = 'lich-5.zip'; browser_download_url = 'https://example.com/lich-5.zip'; digest = 'sha256:6eed189751741e7113aee78d525d04bdfd1b87f6529a155818f88071e083b8e4' }) }; Error = '*unexpected location*' }
      @{ Name = 'an asset over plain HTTP'; Release = [pscustomobject]@{ tag_name = 'v5.18.0'; assets = @([pscustomobject]@{ name = 'lich-5.zip'; browser_download_url = 'http://github.com/elanthia-online/lich-5/releases/download/v5.18.0/lich-5.zip'; digest = 'sha256:6eed189751741e7113aee78d525d04bdfd1b87f6529a155818f88071e083b8e4' }) }; Error = '*unexpected location*' }
      @{ Name = 'an asset from a different tag'; Release = [pscustomobject]@{ tag_name = 'v5.18.0'; assets = @([pscustomobject]@{ name = 'lich-5.zip'; browser_download_url = 'https://github.com/elanthia-online/lich-5/releases/download/v5.17.0/lich-5.zip'; digest = 'sha256:6eed189751741e7113aee78d525d04bdfd1b87f6529a155818f88071e083b8e4' }) }; Error = '*unexpected location*' }
      @{ Name = 'an unexpected tag'; Release = [pscustomobject]@{ tag_name = '../../v5.18.0'; assets = @() }; Error = '*unexpected release tag*' }
      @{ Name = 'an uppercase digest'; Release = [pscustomobject]@{ tag_name = 'v5.18.0'; assets = @([pscustomobject]@{ name = 'lich-5.zip'; browser_download_url = 'https://github.com/elanthia-online/lich-5/releases/download/v5.18.0/lich-5.zip'; digest = 'sha256:6EED189751741E7113AEE78D525D04BDFD1B87F6529A155818F88071E083B8E4' }) }; Error = '*missing or malformed digest*' }
    ) {
      Mock Invoke-RestMethod { $Release }
      { Invoke-LichFetch -DestDir $script:DestDir } | Should -Throw $Error
      Should -Invoke Invoke-WebRequest -Times 0
      Should -Invoke Expand-Archive -Times 0
    }
  }
}

Describe 'fetch-lich retry policy' {
  It 'Get-LichRetryDelay returns <Expected> for <Name>' -ForEach @(
    @{ Name = 'no response, attempt 1'; Failure = @{ Status = $null }; Attempt = 1; Budget = 60; Expected = 2 }
    @{ Name = 'no response, attempt 2'; Failure = @{ Status = $null }; Attempt = 2; Budget = 60; Expected = 4 }
    @{ Name = 'a 408'; Failure = @{ Status = 408 }; Attempt = 1; Budget = 60; Expected = 2 }
    @{ Name = 'a 500'; Failure = @{ Status = 500 }; Attempt = 1; Budget = 60; Expected = 2 }
    @{ Name = 'a 599'; Failure = @{ Status = 599 }; Attempt = 1; Budget = 60; Expected = 2 }
    @{ Name = 'a 429 with Retry-After 7'; Failure = @{ Status = 429; RetryAfterSec = 7; RateLimited = $true }; Attempt = 1; Budget = 60; Expected = 7 }
    @{ Name = 'a 403 with Retry-After 0'; Failure = @{ Status = 403; RetryAfterSec = 0; RateLimited = $true }; Attempt = 1; Budget = 60; Expected = 0 }
    @{ Name = 'a rate-limited 403 resetting in 9s'; Failure = @{ Status = 403; ResetInSec = 9; RateLimited = $true }; Attempt = 1; Budget = 60; Expected = 10 }
    @{ Name = 'Retry-After at the 30s cap'; Failure = @{ Status = 429; RetryAfterSec = 30; RateLimited = $true }; Attempt = 1; Budget = 60; Expected = 30 }
    @{ Name = 'Retry-After over the 30s cap'; Failure = @{ Status = 429; RetryAfterSec = 31; RateLimited = $true }; Attempt = 1; Budget = 60; Expected = -1 }
    @{ Name = 'Retry-After over the remaining budget'; Failure = @{ Status = 429; RetryAfterSec = 20; RateLimited = $true }; Attempt = 1; Budget = 10; Expected = -1 }
    @{ Name = 'a reset an hour away'; Failure = @{ Status = 403; ResetInSec = 3600; RateLimited = $true }; Attempt = 1; Budget = 60; Expected = -1 }
    @{ Name = 'a reset far beyond Int32'; Failure = @{ Status = 403; ResetInSec = [long]8204991675; RateLimited = $true }; Attempt = 1; Budget = 60; Expected = -1 }
    @{ Name = 'a Retry-After beyond Int32'; Failure = @{ Status = 429; RetryAfterSec = [long]99999999999; RateLimited = $true }; Attempt = 1; Budget = 60; Expected = -1 }
    @{ Name = 'a backoff over the remaining budget'; Failure = @{ Status = 503 }; Attempt = 2; Budget = 3; Expected = -1 }
    @{ Name = 'a plain 403'; Failure = @{ Status = 403; RateLimited = $false }; Attempt = 1; Budget = 60; Expected = -1 }
    @{ Name = 'a 404'; Failure = @{ Status = 404 }; Attempt = 1; Budget = 60; Expected = -1 }
    @{ Name = 'a 401'; Failure = @{ Status = 401 }; Attempt = 1; Budget = 60; Expected = -1 }
  ) {
    $value = [pscustomobject]@{ Status = $null; RetryAfterSec = $null; ResetInSec = $null; RateLimited = $false }
    foreach ($key in $Failure.Keys) { $value.$key = $Failure[$key] }
    Get-LichRetryDelay -Failure $value -Attempt $Attempt -BudgetSec $Budget | Should -Be $Expected
  }

  It 'Get-LichHttpFailure reads <Name> from a Windows PowerShell 5.1 shaped error' -ForEach @(
    @{ Name = 'a secondary rate limit'; Status = 403; Headers = @{ 'Retry-After' = '12' }; RateLimited = $true; RetryAfter = 12 }
    @{ Name = 'a primary rate limit'; Status = 403; Headers = @{ 'X-RateLimit-Remaining' = '0'; 'X-RateLimit-Reset' = '1' }; RateLimited = $true; RetryAfter = $null }
    @{ Name = 'a 429'; Status = 429; Headers = @{}; RateLimited = $true; RetryAfter = $null }
    @{ Name = 'a plain 403 with quota left'; Status = 403; Headers = @{ 'X-RateLimit-Remaining' = '12' }; RateLimited = $false; RetryAfter = $null }
    @{ Name = 'an HTTP-date Retry-After (ignored)'; Status = 503; Headers = @{ 'Retry-After' = 'Wed, 21 Oct 2026 07:28:00 GMT' }; RateLimited = $false; RetryAfter = $null }
  ) {
    $failure = Get-LichHttpFailure -ErrorRecord (New-FakeErrorRecord -Status $Status -Headers $Headers)
    $failure.Status | Should -Be $Status
    $failure.RateLimited | Should -Be $RateLimited
    $failure.RetryAfterSec | Should -Be $RetryAfter
  }

  It 'Get-LichHttpFailure reports a past rate-limit reset as 0s away, not negative' {
    $failure = Get-LichHttpFailure -ErrorRecord (New-FakeErrorRecord -Status 403 -Headers @{ 'X-RateLimit-Remaining' = '0'; 'X-RateLimit-Reset' = '1' })
    $failure.ResetInSec | Should -Be 0
  }

  It 'Get-LichHttpFailure treats a missing response as a network error' {
    $failure = Get-LichHttpFailure -ErrorRecord (New-FakeErrorRecord -Status 0)
    $failure.Status | Should -BeNullOrEmpty
    $failure.RateLimited | Should -BeFalse
    $failure.Description | Should -BeLike 'network error (*'
  }

  It 'Get-LichHttpFailure reads a real PowerShell 7 HttpResponseException' -Skip:($PSVersionTable.PSEdition -ne 'Core') {
    $response = [System.Net.Http.HttpResponseMessage]::new([System.Net.HttpStatusCode]::Forbidden)
    $response.Headers.Add('Retry-After', '9')
    $response.Headers.Add('X-RateLimit-Remaining', '0')
    $exception = [Microsoft.PowerShell.Commands.HttpResponseException]::new('Response status code does not indicate success: 403 (Forbidden).', $response)
    $record = try { throw $exception } catch { $_ }
    $failure = Get-LichHttpFailure -ErrorRecord $record
    $failure.Status | Should -Be 403
    $failure.RetryAfterSec | Should -Be 9
    $failure.RateLimited | Should -BeTrue
  }

  It 'Test-LichTag accepts every tag shape lich-5 has released and nothing that could leave the URL path' {
    foreach ($tag in @('v5.24.2', 'v5.0.19', 'v5.10.0-beta.1', 'v5.11.0-rc.6', 'v5.12.0-beta.0', 'v5.9.2-ssl')) {
      Test-LichTag -Tag $tag | Should -BeTrue -Because $tag
    }
    foreach ($tag in @('', $null, 'main', '5.24.2', 'v5.24', 'v5.24.2/../x', 'v5.24.2?x', 'v5.24.2#x', 'v5.24.2%2F', "v5.24.2`n", 'v5.24.2-', 'V5.24.2', 'checkpoint/stable/20261118-000801')) {
      Test-LichTag -Tag $tag | Should -BeFalse -Because "'$tag'"
    }
  }

  It 'Get-LichDigestFromAssetsHtml finds the lich-5.zip digest in the real page shape, not the tar.gz one' {
    Get-LichDigestFromAssetsHtml -Html (New-AssetsHtml) -AssetName 'lich-5.zip' | Should -Be $script:ZipDigest
  }

  It 'Get-LichDigestFromAssetsHtml ignores a label for a longer asset name' {
    $html = '<clipboard-copy aria-label="Copy to clipboard digest for lich-5.zip.sig" value="sha256:2346b21afba1fff0455c524f5c9ee05c49f73925ceece3bdca1e55a6f0dd9c8d">'
    Get-LichDigestFromAssetsHtml -Html $html -AssetName 'lich-5.zip' | Should -BeNullOrEmpty
  }

  It 'Get-LichDigestFromAssetsHtml accepts the same digest repeated' {
    $element = "<clipboard-copy aria-label=`"Copy to clipboard digest for lich-5.zip`" value=`"$($script:ZipDigest)`">"
    Get-LichDigestFromAssetsHtml -Html ($element + $element) -AssetName 'lich-5.zip' | Should -Be $script:ZipDigest
  }
}

# The real run executes the fetch in a Start-Job process, which sees only the
# script text Get-LichFetchJobScript builds. Pester's dot-source sees every
# function, so a helper left out of that text would pass every mocked test
# above and fail on every real install.
Describe 'Get-LichFetchJobScript' {
  It 'bundles every fetch-lich.ps1 function the fetch can call' {
    $tokens = $null; $errors = $null
    $ast = [System.Management.Automation.Language.Parser]::ParseFile((Resolve-Path "$PSScriptRoot/../../fetch-lich.ps1").Path, [ref]$tokens, [ref]$errors)
    $defined = @{}
    foreach ($fn in $ast.FindAll({ param($n) $n -is [System.Management.Automation.Language.FunctionDefinitionAst] }, $true)) { $defined[$fn.Name] = $fn }
    $needed = [System.Collections.Generic.HashSet[string]]::new()
    $queue = [System.Collections.Generic.Queue[string]]::new()
    $queue.Enqueue('Invoke-LichFetch')
    while ($queue.Count -gt 0) {
      $name = $queue.Dequeue()
      if (-not $needed.Add($name)) { continue }
      foreach ($call in $defined[$name].FindAll({ param($n) $n -is [System.Management.Automation.Language.CommandAst] }, $true)) {
        $called = $call.GetCommandName()
        if ($called -and $defined.ContainsKey($called)) { $queue.Enqueue($called) }
      }
    }
    foreach ($name in $needed) {
      $script:LichFetchJobFunctions | Should -Contain $name
    }
  }

  It 'defines those functions in a real job process' {
    $job = Start-Job -ScriptBlock (Get-LichFetchJobScript -Invocation 'Get-Command -CommandType Function | ForEach-Object { $_.Name }')
    try {
      $names = @(Receive-Job -Job $job -Wait -ErrorAction Stop)
    } finally {
      Remove-Job -Job $job -Force -ErrorAction SilentlyContinue
    }
    foreach ($name in $script:LichFetchJobFunctions) {
      $names | Should -Contain $name
    }
  }
}

# The process-level contract with the installer's ExecAndLogOutput callback,
# on a failure path that needs no network: one FAILURE line on stdout, exit 1.
Describe 'fetch-lich.ps1 run as a script' {
  It 'writes a single FAILURE line on stdout and exits 1' {
    $shell = (Get-Process -Id $PID).Path
    $out = & $shell -NoProfile -NonInteractive -ExecutionPolicy Bypass -File (Resolve-Path "$PSScriptRoot/../../fetch-lich.ps1").Path 2>$null
    $code = $LASTEXITCODE
    $code | Should -Be 1
    @($out) | Should -Be @('FAILURE: DestDir is required. Usage: fetch-lich.ps1 -DestDir <path>')
  }
}

# Real Start-Job processes, not mocks: the live-progress behavior only exists
# across the job boundary, so it is exercised on both CI shells (Windows
# PowerShell 5.1 and pwsh) with stand-in job bodies instead of a real fetch.
Describe 'Wait-LichFetchJob' {
  AfterEach {
    if ($script:job) { Remove-Job -Job $script:job -Force -ErrorAction SilentlyContinue }
    $script:job = $null
  }

  It 'writes phases while the job is still running, then returns the job output' {
    $script:job = Start-Job {
      Write-Information -MessageData 'first' -Tags 'LichPhase'
      Start-Sleep -Seconds 4
      Write-Information -MessageData 'second' -Tags 'LichPhase'
      'v5.18.0'
    }
    $seen = @(Wait-LichFetchJob -Job $script:job | ForEach-Object {
      [pscustomobject]@{ Line = $_; JobState = "$($script:job.State)" }
    })

    $seen.Line | Should -Be @('PHASE: first', 'PHASE: second', 'v5.18.0')
    # The first phase reached the pipeline before the job finished -- the
    # point of the loop; a single Wait-Job + Receive-Job would fail this.
    $seen[0].JobState | Should -Be 'Running'
  }

  It 'skips Information records that are not tagged LichPhase' {
    $script:job = Start-Job {
      Write-Information -MessageData 'other' -Tags 'Other'
      Write-Information -MessageData 'kept' -Tags 'LichPhase'
      'v5.18.0'
    }
    $lines = @(Wait-LichFetchJob -Job $script:job 6>$null)
    $lines | Should -Be @('PHASE: kept', 'v5.18.0')
  }

  It "rethrows the job's own error when the fetch fails" {
    $script:job = Start-Job { throw 'lich-5.zip not found in release v5.18.0' }
    { Wait-LichFetchJob -Job $script:job } | Should -Throw '*lich-5.zip not found*'
  }

  It 'throws once the job runs past the timeout' {
    $script:job = Start-Job { Start-Sleep -Seconds 60 }
    { Wait-LichFetchJob -Job $script:job -TimeoutSec 2 } | Should -Throw '*timed out after 2s*'
  }
}
