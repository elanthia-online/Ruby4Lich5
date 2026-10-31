BeforeAll { . "$PSScriptRoot/../../runtime-build-tooling.ps1" }

Describe 'Runtime build tooling staging policy' {
  BeforeEach {
    $script:Policy = Join-Path $TestDrive 'tooling.json'
    $script:Inventory = @('rake', 'pkg-config', 'native-package-installer', 'os', 'ox') | ForEach-Object { [pscustomobject]@{ name = $_; version = '1.0' } }
  }
  It 'executes the production selector against the real three-name policy' {
    $result = @(Select-RuntimeGemManifest -ToolingPath "$PSScriptRoot/../../config/runtime-build-tooling.json" -InstallManifest $script:Inventory)
    $result.Count | Should -Be 2
    ($result.name -join ',') | Should -Be 'os,ox'
  }
  It 'keeps a single-name JSON array valid on both PowerShell editions' {
    Set-Content $script:Policy '["rake"]'
    $result = @(Select-RuntimeGemManifest -ToolingPath $script:Policy -InstallManifest $script:Inventory)
    $result.Count | Should -Be 4
    $result.name | Should -Not -Contain 'rake'
  }
  It 'rejects malformed policy <Json>' -TestCases @(
    @{ Json = '[]' }; @{ Json = '{}' }; @{ Json = '"rake"' }; @{ Json = 'null' }
    @{ Json = '[1]' }; @{ Json = '[null]' }; @{ Json = '[""]' }; @{ Json = '[["rake"]]' }; @{ Json = '["rake"' }
  ) {
    param($Json)
    Set-Content $script:Policy $Json
    { Select-RuntimeGemManifest -ToolingPath $script:Policy -InstallManifest $script:Inventory } | Should -Throw
  }
}
