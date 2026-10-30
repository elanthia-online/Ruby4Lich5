BeforeAll {
  . "$PSScriptRoot/../../fetch-lich.ps1"
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
  }

  Context 'happy path' {
    BeforeEach {
      Mock Invoke-RestMethod {
        [pscustomobject]@{
          tag_name = 'v5.18.0'
          assets   = @(
            [pscustomobject]@{ name = 'lich-5.tar.gz'; browser_download_url = 'https://example.com/lich-5.tar.gz' }
            [pscustomobject]@{ name = 'lich-5.zip'; browser_download_url = 'https://example.com/lich-5.zip'; digest = 'sha256:6eed189751741e7113aee78d525d04bdfd1b87f6529a155818f88071e083b8e4' }
            [pscustomobject]@{ name = 'Ruby4Lich5.exe'; browser_download_url = 'https://example.com/Ruby4Lich5.exe' }
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
        $Uri -eq 'https://example.com/lich-5.zip'
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
          assets   = @([pscustomobject]@{ name = 'lich-5.zip'; browser_download_url = 'https://example.com/lich-5.zip'; digest = 'sha256:6eed189751741e7113aee78d525d04bdfd1b87f6529a155818f88071e083b8e4' })
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
  }

  Context 'the release has no lich-5.zip asset' {
    BeforeEach {
      Mock Invoke-RestMethod {
        [pscustomobject]@{
          tag_name = 'v5.18.0'
          assets   = @([pscustomobject]@{ name = 'lich-5.tar.gz'; browser_download_url = 'https://example.com/lich-5.tar.gz' })
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
  }

  Context 'extraction did not produce the expected DestDir' {
    BeforeEach {
      Mock Invoke-RestMethod {
        [pscustomobject]@{
          tag_name = 'v5.18.0'
          assets   = @([pscustomobject]@{ name = 'lich-5.zip'; browser_download_url = 'https://example.com/lich-5.zip'; digest = 'sha256:6eed189751741e7113aee78d525d04bdfd1b87f6529a155818f88071e083b8e4' })
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
          assets   = @([pscustomobject]@{ name = 'lich-5.zip'; browser_download_url = 'https://example.com/lich-5.zip'; digest = 'sha256:6eed189751741e7113aee78d525d04bdfd1b87f6529a155818f88071e083b8e4' })
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
          assets   = @([pscustomobject]@{ name = 'lich-5.zip'; browser_download_url = 'https://example.com/lich-5.zip' })
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
