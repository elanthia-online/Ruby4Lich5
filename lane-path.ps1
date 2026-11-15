# PATH filtering for the gem suite's sanitized build lane
# (ruby4-bundled-gems-suite.yml, "Build sanitized PATH"). The lane prepends the
# setup-msys2 prefix and usr\bin itself; this drops the runner image's own
# toolchains so none of them can shadow it.
#
# x64-mingw-ucrt keeps the filters measured on windows-latest, unchanged and
# silent. aarch64-mingw-ucrt's filters are an explicit, named list, measured on
# windows-11-arm in suite run 43724350056 (2026-11-15). That image puts a
# standalone LLVM (C:\Program Files\LLVM\bin, with its own clang.exe and
# llvm-objdump.exe) and the hosted Ruby tool cache on PATH, so both are
# dropped. Every entry is still printed as kept or filtered (with the rule
# that dropped it), so an image change shows up in the log. Any other
# platform is rejected rather than given a guessed list.
#
# Runs under Windows PowerShell 5.1 (shell: powershell). Dot-sourcing defines
# functions only.

function Select-LanePathEntry {
  param(
    [AllowEmptyCollection()][AllowEmptyString()][string[]]$Entries,
    [Parameter(Mandatory = $true)][string]$Platform
  )
  if ($Platform -ceq 'x64-mingw-ucrt') {
    # Hosted Ruby's x64 MSYS2, the hosted Ruby tool cache, C:\mingw64 and Strawberry.
    return $Entries | Where-Object {
      $_ -and
      ($_ -notlike '*\Ruby\*\x64\msys64\*') -and
      ($_ -notmatch '^C:\\hostedtoolcache\\windows\\Ruby(\\|$)') -and
      ($_ -ne 'C:\mingw64\bin') -and
      ($_ -notmatch '^C:\\Strawberry(\\|$)')
    }
  }
  if ($Platform -ceq 'aarch64-mingw-ucrt') {
    $rules = @(
      [pscustomobject]@{ Name = 'hosted Ruby x64 MSYS2'; Test = { param($p) $p -like '*\Ruby\*\x64\msys64\*' } }
      [pscustomobject]@{ Name = 'hosted Ruby arm64 MSYS2'; Test = { param($p) $p -like '*\Ruby\*\arm64\msys64\*' } }
      [pscustomobject]@{ Name = 'hosted Ruby tool cache'; Test = { param($p) $p -match '^C:\\hostedtoolcache\\windows\\Ruby(\\|$)' } }
      [pscustomobject]@{ Name = 'C:\mingw64'; Test = { param($p) $p -eq 'C:\mingw64\bin' } }
      [pscustomobject]@{ Name = 'Strawberry'; Test = { param($p) $p -match '^C:\\Strawberry(\\|$)' } }
      [pscustomobject]@{ Name = 'standalone LLVM'; Test = { param($p) $p -match '^C:\\Program Files\\LLVM(\\|$)' } }
    )
    $kept = New-Object System.Collections.Generic.List[string]
    foreach ($entry in @($Entries)) {
      if (-not $entry) {
        Write-Host 'lane PATH filtered (empty entry)'
        continue
      }
      $rule = $rules | Where-Object { & $_.Test $entry } | Select-Object -First 1
      if ($rule) {
        Write-Host "lane PATH filtered ($($rule.Name)): $entry"
      } else {
        Write-Host "lane PATH kept: $entry"
        $kept.Add($entry)
      }
    }
    return $kept.ToArray()
  }
  throw "No measured lane PATH filters for platform ""$Platform""."
}
