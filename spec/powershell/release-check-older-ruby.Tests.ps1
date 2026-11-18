# Behaviour of Test-FailedRun, the early stop in the older-Ruby release check's
# relaunch poll (.github/workflows/release-check-older-ruby.yml). The function
# is read out of the workflow itself, so this exercises the committed code.
# lich_startup_probe.rb writes each run-<n>.json twice: at start without
# "exit", and again at exit with it.
BeforeAll {
  $workflow = Get-Content -Raw (Join-Path $PSScriptRoot '../../.github/workflows/release-check-older-ruby.yml')
  $match = [regex]::Match($workflow, '(?s)function Test-FailedRun \{.*?\n\s*return \$false\n\s*\}')
  if (-not $match.Success) { throw 'Test-FailedRun not found in release-check-older-ruby.yml' }
  . ([scriptblock]::Create($match.Value))

  function Set-Marker([string]$Name, [string]$Json) {
    Set-Content -LiteralPath (Join-Path $script:markers $Name) -Value $Json -Encoding utf8
  }
}

Describe 'Test-FailedRun (older-Ruby release check)' {
  BeforeEach {
    $script:markers = Join-Path ([System.IO.Path]::GetTempPath()) ("r4l5-markers-" + [guid]::NewGuid())
    New-Item -ItemType Directory -Path $script:markers | Out-Null
    $markers = $script:markers
  }
  AfterEach { Remove-Item -LiteralPath $script:markers -Recurse -Force -ErrorAction SilentlyContinue }

  It 'keeps waiting while no run has written a marker' {
    Test-FailedRun | Should -BeFalse
  }

  It 'stops when the first run recorded a non-zero exit' {
    Set-Marker 'run-1.json' '{"run":1,"exit":1}'
    Test-FailedRun | Should -BeTrue
  }

  It 'keeps waiting after a first run that scheduled the relaunch (exit 0)' {
    Set-Marker 'run-1.json' '{"run":1,"exit":0}'
    Test-FailedRun | Should -BeFalse
  }

  It 'keeps waiting while the relaunch is still loading (its marker has no exit yet)' {
    Set-Marker 'run-1.json' '{"run":1,"exit":0}'
    Set-Marker 'run-2.json' '{"run":2,"pid":4242}'
    Test-FailedRun | Should -BeFalse
  }

  It 'stops when the relaunch recorded a non-zero exit' {
    Set-Marker 'run-1.json' '{"run":1,"exit":0}'
    Set-Marker 'run-2.json' '{"run":2,"exit":1}'
    Test-FailedRun | Should -BeTrue
  }

  It 'ignores a marker that is only half written' {
    Set-Marker 'run-1.json' '{"run":1,"ex'
    Test-FailedRun | Should -BeFalse
  }
}
