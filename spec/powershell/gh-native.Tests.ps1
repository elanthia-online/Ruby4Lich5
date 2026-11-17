# Real child processes under Stop: on the Windows PowerShell 5.1 lane this is
# what turns a redirected native stderr line into a terminating error unless
# Invoke-GhNative sets its function-local preference.
Describe 'Native gh invocation' {
  BeforeAll {
    . "$PSScriptRoot/../../gem-candidate-publication.ps1"
    . "$PSScriptRoot/../../gem-manifest-promotion.ps1"
    . "$PSScriptRoot/../../gem-genesis.ps1"
    $script:NativeEngine = (Get-Process -Id $PID).Path
    $script:NativeFixture = Join-Path $TestDrive 'native-gh.ps1'
    # Plays gh: '-Message m -Code n' writes m to stderr and exits n; an 'api'
    # call answers like the GitHub API for a release that does not exist.
    @'
param([Parameter(ValueFromRemainingArguments = $true)][string[]]$Rest)
if ($Rest[0] -ceq 'api') {
  if ($Rest[1] -ceq '--paginate') { [Console]::Out.WriteLine('R4L5-gem-bundle-x64-mingw-ucrt'); exit 0 }
  [Console]::Error.WriteLine('gh: Not Found (HTTP 404)')
  exit 1
}
[Console]::Error.WriteLine($Rest[1])
exit ([int]$Rest[3])
'@ | Set-Content -LiteralPath $script:NativeFixture -Encoding ascii
    # Exercise a real child process without invoking GitHub or the network.
    function gh {
      & $script:NativeEngine -NoProfile -NonInteractive -File $script:NativeFixture @args
    }
  }

  AfterEach { Remove-Item Env:\GEM_PLATFORM -ErrorAction SilentlyContinue }

  It 'returns the exit code and stderr without throwing and preserves the caller preference' {
    $ErrorActionPreference = 'Stop'
    $result = Invoke-GhNative -Arguments @('-Message', 'release not found', '-Code', '1')
    $result.ExitCode | Should -Be 1
    $result.Output | Should -Be 'release not found'
    $ErrorActionPreference | Should -Be 'Stop'
  }

  It 'keeps the function-local guard that only the Windows PowerShell 5.1 lane can exercise' {
    # PowerShell 7 no longer raises on redirected native stderr, so the
    # behavioral tests above pass there without the guard; pin it as well.
    (Get-Command Invoke-GhNative).Definition | Should -Match "\`$ErrorActionPreference = 'Continue'\s+\`$output = & gh @Arguments 2>&1"
  }

  It 'throws gh failed from the candidate and promotion layers on a non-zero exit, without classifying it' {
    $ErrorActionPreference = 'Stop'
    { Invoke-CandidateGh -Arguments @('-Message', 'release not found', '-Code', '1') } | Should -Throw 'gh failed: release not found'
    { Invoke-CandidateGh -Arguments @('-Message', 'HTTP 403 forbidden', '-Code', '1') } | Should -Throw 'gh failed: HTTP 403 forbidden'
    { Invoke-PromotionGh -Arguments @('-Message', 'HTTP 502 bad gateway', '-Code', '1') } | Should -Throw 'gh failed: HTTP 502 bad gateway'
  }

  It 'uses the successful exit code even when a native process emits stderr' {
    $ErrorActionPreference = 'Stop'
    Invoke-CandidateGh -Arguments @('-Message', 'diagnostic', '-Code', '0') | Should -Be 'diagnostic'
    Invoke-PromotionGh -Arguments @('-Message', 'diagnostic', '-Code', '0') | Should -Be 'diagnostic'
  }

  It 'classifies a real HTTP 404 on stderr as absent for genesis' {
    $ErrorActionPreference = 'Stop'
    $env:GEM_PLATFORM = 'aarch64-mingw-ucrt'
    Get-GemProductionReleaseState -Repository 'elanthia-online/Ruby4Lich5' | Should -Be 'absent'
    { Assert-GemProductionReleaseAbsent -Repository 'elanthia-online/Ruby4Lich5' } | Should -Not -Throw
  }
}
