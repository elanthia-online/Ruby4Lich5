BeforeAll {
  $script:Root = (Resolve-Path (Join-Path $PSScriptRoot '../..')).Path

  # The literal block scalar under "run: |" that starts after $Anchor, with its
  # common indentation removed: executes the real workflow text, not a copy.
  function Get-RunBlock {
    param([string]$Path, [string]$Anchor)
    $lines = (Get-Content -LiteralPath $Path -Raw) -split "`r?`n"
    $start = [Array]::IndexOf($lines, ($lines | Where-Object { $_ -ceq $Anchor } | Select-Object -First 1))
    if ($start -lt 0) { throw "anchor not found: $Anchor" }
    $run = $start
    while ($lines[$run] -notmatch '^\s+run: \|$') { $run++ }
    $indent = ($lines[$run] -replace '^(\s+).*$', '$1').Length + 2
    $body = New-Object System.Collections.Generic.List[string]
    for ($i = $run + 1; $i -lt $lines.Count; $i++) {
      $line = $lines[$i]
      if ($line.Trim().Length -gt 0 -and ($line.Length - $line.TrimStart().Length) -lt $indent) { break }
      if ($line.Length -ge $indent) { $body.Add($line.Substring($indent)) } else { $body.Add('') }
    }
    return ($body -join "`n")
  }

  function Invoke-WithEnv {
    param([hashtable]$Environment, [scriptblock]$Block)
    $saved = @{}
    foreach ($key in $Environment.Keys) {
      $saved[$key] = [Environment]::GetEnvironmentVariable($key)
      if ($null -eq $Environment[$key]) { Remove-Item "Env:$key" -ErrorAction SilentlyContinue }
      else { Set-Item "Env:$key" $Environment[$key] }
    }
    try { & $Block } finally {
      foreach ($key in $saved.Keys) {
        if ($null -eq $saved[$key]) { Remove-Item "Env:$key" -ErrorAction SilentlyContinue } else { Set-Item "Env:$key" $saved[$key] }
      }
    }
  }
}

Describe 'select-target-platform action' {
  BeforeAll {
    $script:Action = [scriptblock]::Create((Get-RunBlock -Path (Join-Path $script:Root '.github/actions/select-target-platform/action.yml') -Anchor '    - id: row'))

    function Invoke-Action {
      param([string]$Platform)
      $output = Join-Path $TestDrive 'output'
      $envFile = Join-Path $TestDrive 'env'
      Set-Content -LiteralPath $output -Value $null
      Set-Content -LiteralPath $envFile -Value $null
      Invoke-WithEnv @{ GITHUB_WORKSPACE = $script:Root; GITHUB_OUTPUT = $output; GITHUB_ENV = $envFile; PLATFORM_INPUT = $Platform; GEM_PLATFORM = $null } {
        & $script:Action 6>$null | Out-Null
      }
      $values = [ordered]@{}
      foreach ($line in @(Get-Content -LiteralPath $output | Where-Object { $_ })) {
        $pair = $line.TrimStart([char]0xFEFF) -split '=', 2
        $values[$pair[0]] = $pair[1]
      }
      return [pscustomobject]@{ Outputs = $values; Env = @(Get-Content -LiteralPath $envFile | Where-Object { $_ } | ForEach-Object { $_.TrimStart([char]0xFEFF) }) }
    }
  }

  It 'emits the x64 row exactly as the pre-table workflows hardcoded it, and exports GEM_PLATFORM' {
    $result = Invoke-Action -Platform 'x64-mingw-ucrt'
    # Same names and order as X64WorkflowSnapshot.action_outputs (Ruby).
    @($result.Outputs.Keys) | Should -Be @('platform', 'runner', 'msystem', 'msys2-prefix', 'msys2-package-prefix',
      'rubyinstaller-asset-suffix', 'gem-bundle-tag', 'toolchain-cc', 'toolchain-make', 'toolchain-pkg-config', 'toolchain-objdump')
    @($result.Outputs.Values) | Should -Be @('x64-mingw-ucrt', 'windows-latest', 'UCRT64', 'ucrt64', 'mingw-w64-ucrt-x86_64',
      'x64', 'R4L5-gem-bundle-x64-mingw-ucrt', 'gcc.exe', 'mingw32-make.exe', 'pkg-config.exe', 'objdump.exe')
    $result.Env | Should -Be @('GEM_PLATFORM=x64-mingw-ucrt')
  }

  It 'emits the aarch64 row when it is asked for, and exports GEM_PLATFORM' {
    $result = Invoke-Action -Platform 'aarch64-mingw-ucrt'
    @($result.Outputs.Keys) | Should -Be @('platform', 'runner', 'msystem', 'msys2-prefix', 'msys2-package-prefix',
      'rubyinstaller-asset-suffix', 'gem-bundle-tag', 'toolchain-cc', 'toolchain-make', 'toolchain-pkg-config', 'toolchain-objdump')
    @($result.Outputs.Values) | Should -Be @('aarch64-mingw-ucrt', 'windows-11-arm', 'CLANGARM64', 'clangarm64', 'mingw-w64-clang-aarch64',
      'arm', 'R4L5-gem-bundle-aarch64-mingw-ucrt', 'clang.exe', 'mingw32-make.exe', 'pkg-config.exe', 'llvm-objdump.exe')
    $result.Env | Should -Be @('GEM_PLATFORM=aarch64-mingw-ucrt')
  }

  It 'rejects names the table does not define, including case variants and blanks' -ForEach @(
    @{ Name = 'x86-mingw32'; Message = '*unknown platform*' }
    @{ Name = 'AARCH64-MINGW-UCRT'; Message = '*unknown platform*' }
    @{ Name = 'X64-MINGW-UCRT'; Message = '*unknown platform*' }
    @{ Name = ' x64-mingw-ucrt'; Message = '*disallowed characters*' }
    @{ Name = ''; Message = '*must not be nil or empty*' }
    @{ Name = 'x64-mingw-ucrt$(whoami)'; Message = '*disallowed characters*' }
  ) {
    { Invoke-Action -Platform $Name } | Should -Throw $Message
  }
}

Describe 'installer accepted-candidate tag validation' {
  BeforeAll {
    $script:Validate = [scriptblock]::Create((Get-RunBlock -Path (Join-Path $script:Root '.github/workflows/build-ruby4lich5-installer.yaml') -Anchor '      - name: Validate explicit gem source'))
    # The literal this step used before it read the platform table.
    $script:Previous = '\AR4L5-gem-bundle-x64-mingw-ucrt-candidate-[1-9][0-9]*-[1-9][0-9]*\z'
    $script:Tags = @(
      'R4L5-gem-bundle-x64-mingw-ucrt-candidate-1-1', 'R4L5-gem-bundle-x64-mingw-ucrt-candidate-123-45',
      'R4L5-gem-bundle-x64-mingw-ucrt-candidate-0-1', 'R4L5-gem-bundle-x64-mingw-ucrt-candidate-1-0',
      'R4L5-gem-bundle-x64-mingw-ucrt-candidate-1', 'R4L5-gem-bundle-x64-mingw-ucrt',
      'R4L5-gem-bundle-x64-mingw-ucrtXcandidate-1-1', 'R4L5-gem-bundle-aarch64-mingw-ucrt-candidate-1-1',
      'R4L5-gem-bundle-x64-mingw32-candidate-1-1', 'r4l5-gem-bundle-x64-mingw-ucrt-candidate-1-1',
      'R4L5-gem-bundle-x64-mingw-ucrt-candidate-1-1-extra', "R4L5-gem-bundle-x64-mingw-ucrt-candidate-1-1`n", ''
    )

    function Test-Accepted {
      param([hashtable]$Environment)
      $Environment.GITHUB_WORKSPACE = $script:Root
      try { Invoke-WithEnv $Environment { & $script:Validate }; return $true } catch { return $false }
    }
  }

  It 'accepts and rejects every candidate tag as the old x64 literal did, with GEM_PLATFORM set or defaulted' -ForEach @(
    @{ Platform = 'x64-mingw-ucrt' }
    @{ Platform = $null }
  ) {
    foreach ($tag in $script:Tags) {
      $expected = $tag -cmatch $script:Previous
      (Test-Accepted @{ GEM_SOURCE = 'accepted-candidate'; GEM_CANDIDATE_TAG = $tag; GEM_BUILD_RUN_ID = $null; GEM_PLATFORM = $Platform }) |
        Should -Be $expected -Because "[$tag]"
    }
    (Test-Accepted @{ GEM_SOURCE = 'accepted-candidate'; GEM_CANDIDATE_TAG = 'R4L5-gem-bundle-x64-mingw-ucrt-candidate-1-1'; GEM_BUILD_RUN_ID = '5'; GEM_PLATFORM = $Platform }) | Should -BeFalse
  }

  It 'leaves the actions source branch unchanged' {
    (Test-Accepted @{ GEM_SOURCE = 'actions'; GEM_BUILD_RUN_ID = '42'; GEM_CANDIDATE_TAG = $null; GEM_PLATFORM = 'x64-mingw-ucrt' }) | Should -BeTrue
    (Test-Accepted @{ GEM_SOURCE = 'actions'; GEM_BUILD_RUN_ID = '0'; GEM_CANDIDATE_TAG = $null; GEM_PLATFORM = 'x64-mingw-ucrt' }) | Should -BeFalse
    (Test-Accepted @{ GEM_SOURCE = 'release'; GEM_BUILD_RUN_ID = $null; GEM_CANDIDATE_TAG = $null; GEM_PLATFORM = 'x64-mingw-ucrt' }) | Should -BeFalse
  }
}
