BeforeAll {
  $script:Root = (Resolve-Path (Join-Path $PSScriptRoot '../..')).Path
  # The P1 bootstrap consumer check, kept as its own fixture so this test proves it still runs.
  $script:ConsumerCheck = Get-Content (Join-Path $script:Root 'spec/powershell/fixtures/p1-consumer-check.rb') -Raw
  $script:Manifest = Join-Path $script:Root 'manifest/R4L5-gem-manifest.json'
}

Describe 'P1 bootstrap consumer invocation' {
  It 'runs the actual ruby -e check for <Consumer> without uploads' -TestCases @(
    @{ Consumer = 'current' }
    @{ Consumer = 'oldest' }
  ) {
    param($Consumer)
    Push-Location $script:Root
    try {
      $output = & ruby -e $script:ConsumerCheck $Consumer $script:Manifest 2>&1
      $result = $LASTEXITCODE
    } finally {
      Pop-Location
    }
    $result | Should -Be 0
    ($output -join "`n") | Should -Match "(?m)^$Consumer [0-9a-f]{40} P1 planning accepted$"
  }
}
