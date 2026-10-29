Describe 'Bounded resolver retries' {
  BeforeAll {
    . "$PSScriptRoot/../../bundle-resolution.ps1"
    function Invoke-FixtureResolution { param([string]$Lock) }
  }
  BeforeEach { Mock Start-Sleep {} }

  It 'retries exit 1 once and preserves a later success' {
    $script:ResolutionCalls = 0
    Mock Invoke-FixtureResolution {
      $script:ResolutionCalls++
      $global:LASTEXITCODE = if ($script:ResolutionCalls -eq 1) { 1 } else { 0 }
    }
    Invoke-BundleResolution -RubyExecutable 'Invoke-FixtureResolution' -Arguments @('lock with spaces.json') | Should -Be 0
    Should -Invoke Invoke-FixtureResolution -Times 2 -Exactly -ParameterFilter { $Lock -eq 'lock with spaces.json' }
    Should -Invoke Start-Sleep -Times 1 -Exactly
  }

  It 'never retries deterministic exit 2' {
    Mock Invoke-FixtureResolution { $global:LASTEXITCODE = 2 }
    Invoke-BundleResolution -RubyExecutable 'Invoke-FixtureResolution' -Arguments @('lock.json') | Should -Be 2
    Should -Invoke Invoke-FixtureResolution -Times 1 -Exactly
    Should -Invoke Start-Sleep -Times 0 -Exactly
  }

  It 'returns a persistent transient failure after two attempts' {
    Mock Invoke-FixtureResolution { $global:LASTEXITCODE = 1 }
    Invoke-BundleResolution -RubyExecutable 'Invoke-FixtureResolution' -Arguments @('lock.json') | Should -Be 1
    Should -Invoke Invoke-FixtureResolution -Times 2 -Exactly
  }
}
