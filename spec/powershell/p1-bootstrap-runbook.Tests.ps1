BeforeAll {
  $script:Root = (Resolve-Path (Join-Path $PSScriptRoot '../..')).Path
  $document = Get-Content (Join-Path $script:Root 'docs/DECISIONS.md') -Raw
  $match = [regex]::Match($document, "(?ms)^\`$consumerCheck = @'\r?\n(.*?)\r?\n'@")
  if (!$match.Success) { throw 'Documented P1 consumer check was not found.' }
  $script:ConsumerCheck = $match.Groups[1].Value
  $script:Manifest = Join-Path $script:Root 'manifest/R4L5-gem-manifest.json'
}

Describe 'Documented P1 bootstrap consumer invocation' {
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
