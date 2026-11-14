BeforeAll {
  $script:Root = (Resolve-Path (Join-Path $PSScriptRoot '../..')).Path
  $script:SuitePath = Join-Path $script:Root '.github/workflows/ruby4-bundled-gems-suite.yml'
  . (Join-Path $script:Root 'lane-path.ps1')

  # The literal block scalar under "run: |" that starts after $Anchor, with its
  # common indentation removed (as in select-target-platform.Tests.ps1).
  function Get-SuiteRunBlock {
    param([string]$Anchor)
    $lines = (Get-Content -LiteralPath $script:SuitePath -Raw) -split "`r?`n"
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

  # The inline filter the "Build sanitized PATH" step used before
  # lane-path.ps1, verbatim: the x64 reference every x64 result is held to.
  function Select-PreviousLanePathEntry {
    param([string[]]$Orig)
    $Orig | Where-Object {
      $_ -and
      ($_ -notlike '*\Ruby\*\x64\msys64\*') -and
      ($_ -notmatch '^C:\\hostedtoolcache\\windows\\Ruby(\\|$)') -and
      ($_ -ne 'C:\mingw64\bin') -and
      ($_ -notmatch '^C:\\Strawberry(\\|$)')
    }
  }

  $script:RunnerPaths = @(
    'C:\Program Files\PowerShell\7',
    '',
    'C:\hostedtoolcache\windows\Ruby\3.4.1\x64\bin',
    'C:\hostedtoolcache\windows\Ruby',
    'C:\hostedtoolcache\windows\Ruby2\bin',
    'C:\hostedtoolcache\windows\Python\3.12.0\x64',
    'D:\tools\Ruby\3.3.0\x64\msys64\usr\bin',
    'D:\tools\Ruby\3.3.0\arm64\msys64\usr\bin',
    'C:\mingw64\bin',
    'c:\mingw64\bin',
    'C:\mingw64\bin\',
    'C:\Strawberry\c\bin',
    'C:\Strawberry',
    'C:\StrawberryPerl\bin',
    'c:\strawberry\perl\bin',
    'C:\msys64\usr\bin',
    'C:\Windows\system32',
    'C:\Windows\system32'
  )
}

Describe 'Select-LanePathEntry' {
  It 'keeps the x64 lane PATH byte-identical to the previous inline filter, silently' -ForEach @(
    @{ Case = 'the runner sample'; Entries = $null }
    @{ Case = 'one kept entry'; Entries = @('C:\Windows\system32') }
    @{ Case = 'nothing kept'; Entries = @('', 'C:\mingw64\bin') }
    @{ Case = 'an empty PATH'; Entries = @('') }
  ) {
    if ($null -eq $Entries) { $Entries = $script:RunnerPaths }
    $previous = Select-PreviousLanePathEntry -Orig $Entries
    $information = $null
    $filtered = Select-LanePathEntry -Entries $Entries -Platform 'x64-mingw-ucrt' -InformationVariable information 6>$null
    $expected = (@('D:\msys64\ucrt64\bin', 'D:\msys64\usr\bin') + $previous) -join ';'
    $actual = (@('D:\msys64\ucrt64\bin', 'D:\msys64\usr\bin') + $filtered) -join ';'
    $actual | Should -BeExactly $expected
    @($information).Count | Should -Be 0
  }

  It 'filters the x64 runner toolchains from the sample' {
    $kept = @(Select-LanePathEntry -Entries $script:RunnerPaths -Platform 'x64-mingw-ucrt')
    $kept | Should -Be @('C:\Program Files\PowerShell\7', 'C:\hostedtoolcache\windows\Ruby2\bin', 'C:\hostedtoolcache\windows\Python\3.12.0\x64',
      'D:\tools\Ruby\3.3.0\arm64\msys64\usr\bin', 'C:\mingw64\bin\', 'C:\StrawberryPerl\bin', 'C:\msys64\usr\bin', 'C:\Windows\system32', 'C:\Windows\system32')
  }

  It 'applies the explicit aarch64 list and prints every entry it keeps or filters' {
    $information = $null
    $kept = @(Select-LanePathEntry -Entries $script:RunnerPaths -Platform 'aarch64-mingw-ucrt' -InformationVariable information 6>$null)
    $kept | Should -Be @('C:\Program Files\PowerShell\7', 'C:\hostedtoolcache\windows\Ruby2\bin', 'C:\hostedtoolcache\windows\Python\3.12.0\x64',
      'C:\mingw64\bin\', 'C:\StrawberryPerl\bin', 'C:\msys64\usr\bin', 'C:\Windows\system32', 'C:\Windows\system32')
    $lines = @($information | ForEach-Object { [string]$_.MessageData })
    $lines.Count | Should -Be $script:RunnerPaths.Count
    $lines | Should -Contain 'lane PATH filtered (hosted Ruby arm64 MSYS2): D:\tools\Ruby\3.3.0\arm64\msys64\usr\bin'
    $lines | Should -Contain 'lane PATH filtered (hosted Ruby x64 MSYS2): D:\tools\Ruby\3.3.0\x64\msys64\usr\bin'
    $lines | Should -Contain 'lane PATH filtered (hosted Ruby tool cache): C:\hostedtoolcache\windows\Ruby\3.4.1\x64\bin'
    $lines | Should -Contain 'lane PATH filtered (C:\mingw64): c:\mingw64\bin'
    $lines | Should -Contain 'lane PATH filtered (Strawberry): c:\strawberry\perl\bin'
    $lines | Should -Contain 'lane PATH filtered (empty entry)'
    $lines | Should -Contain 'lane PATH kept: C:\msys64\usr\bin'
  }

  It 'rejects a platform with no measured filter list' -ForEach @(
    @{ Platform = 'demo-mingw-ucrt' }
    @{ Platform = 'X64-MINGW-UCRT' }
    @{ Platform = '' }
  ) {
    { Select-LanePathEntry -Entries @('C:\Windows') -Platform $Platform } | Should -Throw
  }
}

Describe 'Build sanitized PATH step' {
  BeforeAll {
    $script:Step = Get-SuiteRunBlock -Anchor '      - name: Build sanitized PATH'
  }

  It 'runs the workflow step end to end and writes the x64 lane exactly as the previous filter did' {
    $msys = Join-Path $TestDrive 'msys64'
    New-Item -ItemType Directory -Path $msys -Force | Out-Null
    $output = Join-Path $TestDrive 'output'
    $envFile = Join-Path $TestDrive 'env'
    Set-Content -LiteralPath $output -Value $null
    Set-Content -LiteralPath $envFile -Value $null
    $script:Step | Should -Match ([regex]::Escape("'`${{ steps.msys2.outputs.msys2-location }}'"))
    $block = [scriptblock]::Create($script:Step.Replace('${{ steps.msys2.outputs.msys2-location }}', $msys))
    $saved = @{}
    foreach ($key in 'Path', 'GITHUB_WORKSPACE', 'GITHUB_ENV', 'GITHUB_OUTPUT', 'MSYS2_PREFIX', 'GEM_PLATFORM') { $saved[$key] = [Environment]::GetEnvironmentVariable($key) }
    $samplePath = $script:RunnerPaths -join ';'
    try {
      $env:Path = $samplePath
      $env:GITHUB_WORKSPACE = $script:Root; $env:GITHUB_ENV = $envFile; $env:GITHUB_OUTPUT = $output
      $env:MSYS2_PREFIX = 'ucrt64'; $env:GEM_PLATFORM = 'x64-mingw-ucrt'
      & $block 6>$null | Out-Null
    } finally {
      foreach ($key in $saved.Keys) { [Environment]::SetEnvironmentVariable($key, $saved[$key]) }
    }
    $expected = (@("$msys\ucrt64\bin", "$msys\usr\bin") + (Select-PreviousLanePathEntry -Orig ($samplePath -split ';'))) -join ';'
    $lines = @(Get-Content -LiteralPath $envFile | ForEach-Object { $_.TrimStart([char]0xFEFF) })
    $lines | Should -Contain "PATH_GEM_SUITE=$expected"
    @(Get-Content -LiteralPath $output | ForEach-Object { $_.TrimStart([char]0xFEFF) }) | Should -Contain "path=$expected"
  }
}

# The function is defined inline in the workflow's GTK vendoring step, so the
# real text is extracted and run against canned objdump -p output:
# - gnu-objdump-p-zlib.so.txt: real GNU objdump -p of RubyInstaller
#   4.0.9-1-x64's zlib.so (headers through the export table);
# - llvm-objdump-p-zlib.so.txt: written to the layout of LLVM's
#   llvm-objdump COFFDump.cpp printImportTables ("    DLL Name: ") and
#   printExportTable (" DLL name: "), not captured from a real binary (R5).
Describe 'Get-DllDependencies' {
  BeforeAll {
    $workflow = Get-Content -LiteralPath $script:SuitePath -Raw
    $match = [regex]::Match($workflow, '(?ms)^ {10}function Get-DllDependencies\(.*?^ {10}\}\r?$')
    $match.Success | Should -BeTrue
    $script:Function = [scriptblock]::Create($match.Value)
    $script:Fixtures = Join-Path $PSScriptRoot 'fixtures/objdump'

    function Invoke-DllDependencies {
      param([string]$Fixture)
      # Get-DllDependencies runs "& $objdump -p $path"; this scope's $objdump answers.
      $fixturePath = Join-Path $script:Fixtures $Fixture
      $objdump = { Get-Content -LiteralPath $fixturePath }
      $binary = Join-Path $TestDrive 'zlib.so'
      Set-Content -LiteralPath $binary -Value 'binary'
      . $script:Function
      return @(Get-DllDependencies $binary)
    }
  }

  It 'reads GNU objdump import lines exactly as before' {
    $previousPattern = 'DLL Name:\s*(.+)$'
    $expected = @(Get-Content -LiteralPath (Join-Path $script:Fixtures 'gnu-objdump-p-zlib.so.txt') | Select-String -Pattern $previousPattern |
      ForEach-Object { $_.Matches[0].Groups[1].Value.Trim() } | Sort-Object -Unique)
    $actual = Invoke-DllDependencies 'gnu-objdump-p-zlib.so.txt'
    $actual | Should -Be $expected
    $actual | Should -Be @('api-ms-win-crt-private-l1-1-0.dll', 'api-ms-win-crt-runtime-l1-1-0.dll', 'api-ms-win-crt-stdio-l1-1-0.dll',
      'api-ms-win-crt-string-l1-1-0.dll', 'api-ms-win-crt-time-l1-1-0.dll', 'api-ms-win-crt-utility-l1-1-0.dll', 'KERNEL32.dll',
      'x64-ucrt-ruby400.dll', 'zlib1.dll')
  }

  It 'reads llvm-objdump import lines and not the export table''s own DLL name' {
    Invoke-DllDependencies 'llvm-objdump-p-zlib.so.txt' |
      Should -Be @('aarch64-ucrt-ruby400.dll', 'api-ms-win-crt-runtime-l1-1-0.dll', 'KERNEL32.dll', 'zlib1.dll')
  }

  It 'returns nothing for a missing binary' {
    $objdump = { throw 'objdump must not run' }
    . $script:Function
    @(Get-DllDependencies (Join-Path $TestDrive 'missing.dll')).Count | Should -Be 0
  }
}
