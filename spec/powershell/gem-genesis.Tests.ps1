Describe 'Genesis publication guards' {
  BeforeAll { . "$PSScriptRoot/../../gem-genesis.ps1" }

  BeforeEach {
    $env:GEM_PLATFORM = 'aarch64-mingw-ucrt'
    $script:Responses = @{
      release = [pscustomobject]@{ ExitCode = 1; Output = 'gh: Not Found (HTTP 404)' }
      ref     = [pscustomobject]@{ ExitCode = 1; Output = 'gh: Not Found (HTTP 404)' }
      list    = [pscustomobject]@{ ExitCode = 0; Output = "R4L5-gem-bundle-x64-mingw-ucrt`nR4L5-gem-bundle-aarch64-mingw-ucrt-candidate-1-1" }
    }
    Mock Invoke-GhNative {
      if ($Arguments[1] -like '*/releases/tags/*') { return $script:Responses.release }
      if ($Arguments[1] -like '*/git/ref/tags/*') { return $script:Responses.ref }
      if ($Arguments[1] -eq '--paginate') { return $script:Responses.list }
      throw "unexpected gh call: $Arguments"
    }
  }

  AfterEach { Remove-Item Env:\GEM_PLATFORM -ErrorAction SilentlyContinue }

  It 'reports absent only when the release and tag are 404 and no listed release carries the tag' {
    Get-GemProductionReleaseState -Repository 'elanthia-online/Ruby4Lich5' | Should -Be 'absent'
    { Assert-GemProductionReleaseAbsent -Repository 'elanthia-online/Ruby4Lich5' } | Should -Not -Throw
    Should -Invoke Invoke-GhNative -Times 2 -Exactly -ParameterFilter { $Arguments[1] -eq 'repos/elanthia-online/Ruby4Lich5/releases/tags/R4L5-gem-bundle-aarch64-mingw-ucrt' }
  }

  It 'refuses genesis when the production release, a bare tag or a draft already exists' {
    $script:Responses.release = [pscustomobject]@{ ExitCode = 0; Output = '{"tag_name":"R4L5-gem-bundle-aarch64-mingw-ucrt"}' }
    { Assert-GemProductionReleaseAbsent -Repository 'elanthia-online/Ruby4Lich5' } | Should -Throw '*already exists (release)*'
    $script:Responses.release = [pscustomobject]@{ ExitCode = 1; Output = 'gh: Not Found (HTTP 404)' }
    $script:Responses.ref = [pscustomobject]@{ ExitCode = 0; Output = '{"ref":"refs/tags/R4L5-gem-bundle-aarch64-mingw-ucrt"}' }
    { Assert-GemProductionReleaseAbsent -Repository 'elanthia-online/Ruby4Lich5' } | Should -Throw '*already exists (tag)*'
    $script:Responses.ref = [pscustomobject]@{ ExitCode = 1; Output = 'gh: Not Found (HTTP 404)' }
    $script:Responses.list = [pscustomobject]@{ ExitCode = 0; Output = "R4L5-gem-bundle-aarch64-mingw-ucrt`nother" }
    { Assert-GemProductionReleaseAbsent -Repository 'elanthia-online/Ruby4Lich5' } | Should -Throw '*already exists (draft)*'
  }

  It 'treats any failure other than a clear 404 as unknown, never absent' {
    $script:Responses.release = [pscustomobject]@{ ExitCode = 1; Output = 'gh: Bad credentials (HTTP 401)' }
    { Get-GemProductionReleaseState -Repository 'elanthia-online/Ruby4Lich5' } | Should -Throw '*release state is unknown*'
    $script:Responses.release = [pscustomobject]@{ ExitCode = 1; Output = 'gh: Not Found (HTTP 404)' }
    $script:Responses.ref = [pscustomobject]@{ ExitCode = 1; Output = 'connection reset' }
    { Get-GemProductionReleaseState -Repository 'elanthia-online/Ruby4Lich5' } | Should -Throw '*tag state is unknown*'
    $script:Responses.ref = [pscustomobject]@{ ExitCode = 1; Output = 'gh: Not Found (HTTP 404)' }
    $script:Responses.list = [pscustomobject]@{ ExitCode = 1; Output = 'API rate limit exceeded' }
    { Get-GemProductionReleaseState -Repository 'elanthia-online/Ruby4Lich5' } | Should -Throw '*listing failed*'
    { Get-GemProductionReleaseState -Repository 'bad repo' } | Should -Throw '*Invalid repository*'
  }
}
