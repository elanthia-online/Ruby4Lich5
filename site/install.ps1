# Ruby4Lich5 installer for Windows (PowerShell).
#
#   irm https://ruby4lich5.elanthia.online/install.ps1 | iex
#
# With options:
#   & ([scriptblock]::Create((irm https://ruby4lich5.elanthia.online/install.ps1))) -Dir C:\Games\Lich5 -Yes
#
# 1. Ruby: rv (https://rv.dev) installs the RubyInstaller build that the live
#    Ruby4Lich5 gem manifest was built for (without the DevKit unless -DevKit
#    is given), after this script checks the archive against the SHA-256
#    GitHub publishes for it.
#    Like Ruby4Lich5.exe, it goes in <RubyDir>\<version> (C:\Ruby4Lich5 by
#    default), with <RubyDir>\current pointing at the version in use.
# 2. Lich: the latest release, checked against its SHA-256, unless the chosen
#    folder already holds Lich.
# 3. Gems: the units that Lich's own recovery policy selects for that Lich
#    version, prebuilt from the manifest, each checked against its SHA-256 and
#    installed in the manifest's order. That is the set Lich's startup check
#    enforces, so Lich starts without a repair and nothing is compiled.
# 4. Windows integration, as Ruby4Lich5.exe does it: Lich's Ruby on the user
#    PATH, .rb/.rbw file associations, and an entry in Settings > Apps that
#    uninstalls what this script added. With -AddShortcut, also a Lich5
#    shortcut on the Desktop and in the Start menu (the exe adds none).
# 5. Optionally (-DevKit), the RubyInstaller DevKit: MSYS2 and the MINGW
#    toolchain through ridk, for compiling gems yourself. Lich doesn't need it.
#
# Run it again at any time to upgrade: an existing Lich folder is upgraded in
# place to the latest release (release files replaced; settings, logins and
# data kept), and Ruby and the gems are brought up to date. The new Ruby
# becomes the one Lich uses only after Lich's own gem check passes with it.
# Ruby4Lich5.exe remains the full installer; this script is the one-command
# alternative, and also covers Windows on ARM.
#
# Windows PowerShell 5.1 compatible, ASCII only. Errors are thrown, never exit:
# under irm | iex an exit would close the user's PowerShell window. For the same
# reason, preferences are set inside the install and uninstall code, not here,
# so they don't change the user's window.
param(
  # Lich folder. Default: an existing Lich install if one is found, otherwise
  # ask: Desktop\Lich5 (GemStone IV), <RubyDir>\Lich5 (DragonRealms) or a
  # folder of your choice. -Yes takes Desktop\Lich5.
  [string]$Dir = '',
  # Where Ruby goes, as <RubyDir>\<version> with <RubyDir>\current pointing at
  # it, like Ruby4Lich5.exe. Default: the folder used last time, or C:\Ruby4Lich5.
  [string]$RubyDir = '',
  # Don't change the user PATH.
  [switch]$NoPath,
  # Don't associate .rb and .rbw files with Lich's Ruby.
  [switch]$NoAssociations,
  # Also add a shortcut that starts Lich, on the Desktop and in the Start
  # menu. Ruby4Lich5.exe adds none, so neither does this script by default.
  [switch]$AddShortcut,
  # Also install the RubyInstaller DevKit (MSYS2 and the MINGW toolchain, via
  # ridk install), for compiling gems yourself. Lich doesn't need it.
  [switch]$DevKit,
  # Windows on ARM: have Lich use the ARM gem manifest (sets the user
  # environment variable LICH_GEM_MANIFEST_URL). Opts in to the ARM soak.
  [switch]$UseArmManifest,
  # Remove what this script installed. The Lich folder is kept unless
  # -RemoveLich is also given.
  [switch]$Uninstall,
  [switch]$RemoveLich,
  # Don't ask for confirmation.
  [switch]$Yes
)
[Net.ServicePointManager]::SecurityProtocol = [Net.ServicePointManager]::SecurityProtocol -bor [Net.SecurityProtocolType]::Tls12

$R4l5Repo = 'elanthia-online/Ruby4Lich5'
$LichRepo = 'elanthia-online/lich-5'
$Wiki = 'https://gswiki.play.net/Lich:Software/Installation'
$Discord = 'https://discord.gg/KF9Wr8u'
$StateDir = Join-Path $env:LOCALAPPDATA 'Lich5'
$StatePath = Join-Path $StateDir 'install-state.json'
$UninstallScriptPath = Join-Path $StateDir 'uninstall.ps1'
$DefaultRubyDir = 'C:\Ruby4Lich5'
$AppsKey = 'HKCU:\Software\Microsoft\Windows\CurrentVersion\Uninstall\Lich5-Ruby4Lich5-script'
$ExeAppsKeys = @(
  'HKCU:\Software\Microsoft\Windows\CurrentVersion\Uninstall\{edd9ccd7-33cb-4577-a470-fe8fd087eb07}_is1',
  'HKLM:\Software\Microsoft\Windows\CurrentVersion\Uninstall\{edd9ccd7-33cb-4577-a470-fe8fd087eb07}_is1',
  'HKLM:\Software\WOW6432Node\Microsoft\Windows\CurrentVersion\Uninstall\{edd9ccd7-33cb-4577-a470-fe8fd087eb07}_is1'
)
$ArmManifestUrl = "https://github.com/$R4l5Repo/releases/download/R4L5-gem-bundle-aarch64-mingw-ucrt/R4L5-gem-manifest.json"

# ---------------------------------------------------------------------------
# The user PATH, edited the way update-ruby-path.ps1 (Ruby4Lich5.exe) does it:
# the raw registry value, so %VAR% entries stay unexpanded and the value keeps
# its type; unrelated entries (empty ones too) are kept as they are; then the
# change is broadcast so new windows see it. Shared with the uninstaller.
# ---------------------------------------------------------------------------
$HelperCode = @'
function Send-EnvironmentChange {
  if (-not ('Lich5Install.EnvironmentChange' -as [type])) {
    Add-Type -TypeDefinition @"
using System;
using System.Runtime.InteropServices;
namespace Lich5Install {
  public static class EnvironmentChange {
    [DllImport("user32.dll", CharSet = CharSet.Unicode, SetLastError = true)]
    public static extern IntPtr SendMessageTimeout(IntPtr hwnd, uint msg, UIntPtr wparam, string lparam, uint flags, uint timeout, out UIntPtr result);
  }
}
"@
  }
  $result = [UIntPtr]::Zero
  [void][Lich5Install.EnvironmentChange]::SendMessageTimeout([IntPtr]0xffff, 0x001a, [UIntPtr]::Zero, 'Environment', 2, 5000, [ref]$result)
}
# rmdir through cmd.exe, which (unlike Remove-Item on Windows PowerShell 5.1)
# doesn't follow junctions inside the folder. cmd would act on & | ^ % < > "
# in a path, even quoted, so such a path is refused rather than passed on.
function Invoke-Rmdir([string]$Path, [switch]$Recurse) {
  if ($Path -match '[&|^%<>"]') { throw "Remove $Path yourself: its name has characters this script won't pass to cmd.exe." }
  $flags = $(if ($Recurse) { '/s /q ' } else { '' })
  cmd.exe /c "rmdir $flags`"$Path`"" | Out-Null
}
# Removes a folder without following junctions inside it, then checks it is gone.
function Remove-Folder([string]$Path) {
  Invoke-Rmdir $Path -Recurse
  if (Test-Path -LiteralPath $Path) { throw "Couldn't remove $Path. Close anything using it and try again." }
}
function Test-Inside([string]$Path, [string]$Folder) {
  return ($Path -and $Folder -and "$($Path.TrimEnd('\'))\".StartsWith("$($Folder.TrimEnd('\'))\", [StringComparison]::OrdinalIgnoreCase))
}
# Processes running from any of these folders (Lich, through its Ruby).
function Get-ProcessUnder([string[]]$Folders) {
  return @(Get-Process -ErrorAction SilentlyContinue | Where-Object {
    $exe = $_.Path
    $exe -and @($Folders | Where-Object { $_ -and (Test-Inside $exe $_) }).Count
  })
}
# Puts $Add first (if given) and drops $Add's and $Remove's other copies.
function Update-UserPath([string]$Add, [string[]]$Remove) {
  $key = [Microsoft.Win32.Registry]::CurrentUser.CreateSubKey('Environment')
  try {
    $old = $key.GetValue('Path', $null, [Microsoft.Win32.RegistryValueOptions]::DoNotExpandEnvironmentNames)
    $kind = [Microsoft.Win32.RegistryValueKind]::ExpandString
    if ($null -ne $old) { $kind = $key.GetValueKind('Path') }
    $drop = @(@($Add) + @($Remove) | Where-Object { $_ } | ForEach-Object { $_.TrimEnd('\') })
    $entries = @()
    if ($Add) { $entries += $Add }
    if ([string]$old) {
      $entries += @(([string]$old).Split(';') | Where-Object { $drop -notcontains [Environment]::ExpandEnvironmentVariables($_.Trim().Trim('"')).TrimEnd('\') })
    }
    $new = $entries -join ';'
    if ($new -cne [string]$old) {
      $key.SetValue('Path', $new, $kind)
      try { Send-EnvironmentChange } catch { Write-Warning "PATH was saved; new windows may need a sign-out to see it: $_" }
    }
  } finally { $key.Dispose() }
}
'@

# ---------------------------------------------------------------------------
# Uninstaller. Self-contained: it runs for -Uninstall and is saved as
# %LOCALAPPDATA%\Lich5\uninstall.ps1 for the Settings > Apps entry. It removes
# only what install-state.json records, and only while it is still ours.
# ---------------------------------------------------------------------------
$UninstallCode = @'
param([switch]$Yes, [switch]$RemoveLich)
$ErrorActionPreference = 'Stop'
'@ + "`n" + $HelperCode + "`n" + @'
try {
$stateDir = Join-Path $env:LOCALAPPDATA 'Lich5'
$statePath = Join-Path $stateDir 'install-state.json'
$appsKey = 'HKCU:\Software\Microsoft\Windows\CurrentVersion\Uninstall\Lich5-Ruby4Lich5-script'
if (-not (Test-Path -LiteralPath $statePath)) {
  Write-Host 'Nothing to uninstall: no Lich install by the Ruby4Lich5 install script was found.'
  Write-Host 'Ruby4Lich5.exe installs are removed from Settings > Apps instead.'
  return
}
$state = Get-Content -Raw -Encoding UTF8 -LiteralPath $statePath | ConvertFrom-Json

# Lich (or anything else) still running from this Ruby would stop the removal
# halfway, so check first.
$running = Get-ProcessUnder (@($state.ruby_link) + @($state.ruby_dirs))
if ($running.Count) {
  throw "Close Lich first: $(@($running | ForEach-Object { $_.ProcessName } | Sort-Object -Unique) -join ', ') is running from Lich's Ruby. Nothing was changed."
}

Write-Host 'This removes what the Ruby4Lich5 install script added:'
if ($state.devkit) { Write-Host "    Lich's Ruby, with the DevKit (MSYS2) if it was installed inside it ($(@($state.ruby_dirs) -join ', '))" }
else { Write-Host "    Lich's Ruby ($(@($state.ruby_dirs) -join ', '))" }
if ($state.path_entry) { Write-Host "    the user PATH entry $($state.path_entry)" }
if ($state.associations) { Write-Host '    the .rb and .rbw file associations, if they still point at this Ruby' }
foreach ($shortcut in @($state.shortcuts)) { if ($shortcut) { Write-Host "    the shortcut $shortcut" } }
if ($state.manifest_url_env) { Write-Host '    the LICH_GEM_MANIFEST_URL setting (ARM gem manifest)' }
if ($state.rv_installed) { Write-Host '    rv, which this script installed' }
if ($RemoveLich) {
  Write-Host "    the Lich folder $($state.lich_dir), including your saved logins and settings" -ForegroundColor Yellow
} else {
  Write-Host "Your Lich folder is kept: $($state.lich_dir)"
}
if (-not $Yes) {
  $reply = Read-Host 'Continue? [y/N]'
  if ($reply -notmatch '^(y|yes)$') { Write-Host 'Cancelled. Nothing was changed.'; return }
}

if ($state.path_entry) { Update-UserPath -Remove @([string]$state.path_entry) }
if ($state.manifest_url_env -and ([Environment]::GetEnvironmentVariable('LICH_GEM_MANIFEST_URL', 'User') -eq $state.manifest_url_env)) {
  [Environment]::SetEnvironmentVariable('LICH_GEM_MANIFEST_URL', $null, 'User')
}
if ($state.associations) {
  foreach ($pair in @(@('.rb', 'RubyFile'), @('.rbw', 'RubyWFile'))) {
    $classKey = "HKCU:\Software\Classes\$($pair[1])"
    $command = Get-ItemProperty -LiteralPath "$classKey\shell\open\command" -ErrorAction SilentlyContinue
    # Leave the association alone if something else (Ruby4Lich5.exe, another Ruby) owns it now.
    if ($command -and ([string]$command.'(default)').Contains($state.ruby_link)) {
      Remove-Item -LiteralPath $classKey -Recurse -Force
      # The extension's default value names the class; clear it only if it's still ours,
      # and drop the key only if nothing else is left in it.
      $extKey = [Microsoft.Win32.Registry]::CurrentUser.OpenSubKey("Software\Classes\$($pair[0])", $true)
      if ($extKey) {
        $empty = $false
        try {
          if ([string]$extKey.GetValue('') -eq $pair[1]) { $extKey.DeleteValue('', $false) }
          $empty = ($extKey.SubKeyCount -eq 0 -and $extKey.ValueCount -eq 0)
        } finally { $extKey.Close() }
        if ($empty) { Remove-Item -LiteralPath "HKCU:\Software\Classes\$($pair[0])" -Force }
      }
    }
  }
}
foreach ($shortcut in @($state.shortcuts)) {
  if ($shortcut -and (Test-Path -LiteralPath $shortcut)) {
    Remove-Item -LiteralPath $shortcut -Force
    # The Start menu's Lich5 folder goes too once empty (never the Desktop).
    $folder = Split-Path $shortcut
    if (($folder -eq (Join-Path ([Environment]::GetFolderPath('Programs')) 'Lich5')) -and -not (Get-ChildItem -Force -LiteralPath $folder | Select-Object -First 1)) {
      Remove-Item -LiteralPath $folder -Force
    }
  }
}
# Ruby4Lich5.exe installed into the same folder since: its <version> and
# current are its own now, so they stay.
$exeRoot = @('HKCU:\Software\Microsoft\Windows\CurrentVersion\Uninstall\{edd9ccd7-33cb-4577-a470-fe8fd087eb07}_is1',
  'HKLM:\Software\Microsoft\Windows\CurrentVersion\Uninstall\{edd9ccd7-33cb-4577-a470-fe8fd087eb07}_is1',
  'HKLM:\Software\WOW6432Node\Microsoft\Windows\CurrentVersion\Uninstall\{edd9ccd7-33cb-4577-a470-fe8fd087eb07}_is1') |
  ForEach-Object { (Get-ItemProperty -LiteralPath $_ -ErrorAction SilentlyContinue).InstallLocation } | Where-Object { $_ } | Select-Object -First 1
$exeOwnsRuby = $exeRoot -and $state.ruby_root -and (([string]$exeRoot).TrimEnd('\') -eq ([string]$state.ruby_root).TrimEnd('\'))
if ($exeOwnsRuby) { Write-Host "Kept the Ruby in $($state.ruby_root): Ruby4Lich5.exe is installed there now." }
# The junction first (rmdir removes only the link), then the Ruby folders.
if (-not $exeOwnsRuby -and $state.ruby_link -and (Test-Path -LiteralPath $state.ruby_link)) { Invoke-Rmdir $state.ruby_link }
foreach ($rubyDir in @($state.ruby_dirs)) {
  if ($exeOwnsRuby -or -not $rubyDir -or -not (Test-Path -LiteralPath $rubyDir)) { continue }
  if (Test-Inside $state.lich_dir $rubyDir) { Write-Host "Kept $rubyDir, because the Lich folder is inside it."; continue }
  # A DevKit MSYS2 inside it: its own maintenance tool removes its Start menu
  # shortcuts and Apps entry along with it.
  $msysTool = Join-Path $rubyDir 'msys64\uninstall.exe'
  if (Test-Path -LiteralPath $msysTool) {
    Write-Host 'Removing MSYS2 (the DevKit)...'
    $p = Start-Process -FilePath $msysTool -ArgumentList 'pr', '--confirm-command' -Wait -PassThru -WindowStyle Hidden
    if ($p.ExitCode -ne 0) { Write-Host "MSYS2's uninstaller exited $($p.ExitCode); removing its folder anyway." }
  }
  Remove-Folder $rubyDir
}
if ($state.rv_installed -and $state.rv_path) {
  $rvDir = Split-Path $state.rv_path
  foreach ($name in @('rv.exe', 'rvx.exe')) {
    $file = Join-Path $rvDir $name
    if (Test-Path -LiteralPath $file) { Remove-Item -LiteralPath $file -Force }
  }
}
if ($RemoveLich -and $state.lich_dir -and (Test-Path -LiteralPath (Join-Path $state.lich_dir 'lich.rbw'))) {
  Remove-Folder $state.lich_dir
}
# The Ruby folder itself, once nothing is left in it (a DragonRealms Lich
# folder kept inside it keeps it too).
if ($state.ruby_root -and (Test-Path -LiteralPath $state.ruby_root) -and -not (Get-ChildItem -Force -LiteralPath $state.ruby_root | Select-Object -First 1)) {
  Remove-Item -LiteralPath $state.ruby_root -Force
}
if (Test-Path -LiteralPath $appsKey) { Remove-Item -LiteralPath $appsKey -Recurse -Force }
Remove-Item -LiteralPath $statePath -Force
$uninstaller = Join-Path $stateDir 'uninstall.ps1'
if (Test-Path -LiteralPath $uninstaller) { Remove-Item -LiteralPath $uninstaller -Force }
if ((Test-Path -LiteralPath $stateDir) -and -not (Get-ChildItem -Force -LiteralPath $stateDir | Select-Object -First 1)) {
  Remove-Item -LiteralPath $stateDir -Force
}
Write-Host 'Uninstalled.' -ForegroundColor Green
if (-not $RemoveLich -and $state.lich_dir) { Write-Host "Your Lich folder is still at $($state.lich_dir)." }
} catch {
  Write-Host "Error: $($_.Exception.Message)" -ForegroundColor Red
  # From Settings > Apps the window would close before the error could be read.
  if (-not $Yes) { [void](Read-Host 'Press Enter to close') }
  throw
}
'@

# ---------------------------------------------------------------------------
# Helpers
# ---------------------------------------------------------------------------
function Write-Step([string]$Message) { Write-Host ''; Write-Host "==> $Message" -ForegroundColor Cyan }
function Write-Ok([string]$Message) { Write-Host "    ok $Message" -ForegroundColor Green }
function Write-Info([string]$Message) { Write-Host "    $Message" }
function Write-Note([string]$Message) { Write-Host "    ! $Message" -ForegroundColor Yellow }

function Get-Sha256([string]$Path) { (Get-FileHash -Algorithm SHA256 -LiteralPath $Path).Hash.ToLowerInvariant() }

# A download, retried up to three times on network errors.
function Save-Download([string]$Url, [string]$Path) {
  for ($attempt = 1; ; $attempt++) {
    try { Invoke-WebRequest -Uri $Url -OutFile $Path -UseBasicParsing; return }
    catch {
      if ($attempt -ge 3) { throw }
      Write-Info "Download failed ($($_.Exception.Message)); trying again."
      Start-Sleep -Seconds (2 * $attempt)
    }
  }
}

# A download checked against its SHA-256. A mismatch is never retried.
function Save-Verified([string]$Url, [string]$Path, [string]$Expected) {
  $Expected = $Expected -replace '^sha256:', ''
  Save-Download $Url $Path
  $actual = Get-Sha256 $Path
  if ($actual -ne $Expected) {
    throw "Download check failed for $(Split-Path $Path -Leaf): expected SHA-256 $Expected, got $actual. Nothing from it was installed."
  }
}

# The final URL after redirects, on Windows PowerShell 5.1 and PowerShell 7.
function Get-FinalUrl([string]$Url) {
  $response = Invoke-WebRequest -Uri $Url -UseBasicParsing
  $base = $response.BaseResponse
  if ($base.ResponseUri) { return $base.ResponseUri.AbsoluteUri }
  return $base.RequestMessage.RequestUri.AbsoluteUri
}

# A release asset's URL and SHA-256: from GitHub's API, or, when the API
# refuses (60 requests an hour per network), from github.com's release pages,
# accepting exactly one digest labelled for exactly this asset, as
# fetch-lich.ps1 and install.sh do.
function Get-ReleaseAsset([string]$Repo, [string]$Tag, [string]$Asset) {
  try {
    if ($Tag) { $release = Invoke-RestMethod "https://api.github.com/repos/$Repo/releases/tags/$Tag" }
    else { $release = Invoke-RestMethod "https://api.github.com/repos/$Repo/releases/latest" }
    $found = $release.assets | Where-Object { $_.name -eq $Asset } | Select-Object -First 1
    if ($found -and $found.digest -match '^sha256:[0-9a-f]{64}$') {
      return @{ Tag = $release.tag_name; Url = $found.browser_download_url; Digest = $found.digest }
    }
  } catch {
    Write-Verbose "GitHub API lookup failed, using the release pages: $($_.Exception.Message)"
  }
  if (-not $Tag) { $Tag = (Get-FinalUrl "https://github.com/$Repo/releases/latest") -replace '^.*/releases/tag/', '' }
  $html = (Invoke-WebRequest "https://github.com/$Repo/releases/expanded_assets/$Tag" -UseBasicParsing).Content
  $label = "aria-label=`"Copy to clipboard digest for $([regex]::Escape($Asset))`""
  $digests = @([regex]::Matches($html, '<clipboard-copy\b[^>]*>') | ForEach-Object { $_.Value } |
    Where-Object { $_ -match $label } |
    ForEach-Object { if ($_ -match 'value="(sha256:[0-9a-f]{64})"') { $Matches[1] } } | Sort-Object -Unique)
  if ($digests.Count -ne 1) { throw "GitHub didn't publish one SHA-256 for $Asset in $Repo $Tag, so it can't be verified." }
  return @{ Tag = $Tag; Url = "https://github.com/$Repo/releases/download/$Tag/$Asset"; Digest = $digests[0] }
}

# A path as PowerShell resolves it: relative to the current location, which
# isn't always the process's working directory.
function Resolve-UserPath([string]$Path) {
  return $ExecutionContext.SessionState.Path.GetUnresolvedProviderPathFromPSPath($Path).TrimEnd('\')
}

# A PowerShell single-quoted literal, for commands printed for copy and paste.
function ConvertTo-Literal([string]$Text) { return "'" + ($Text -replace "'", "''") + "'" }

# The command Windows runs to open .rb files now, or $null.
function Get-RubyFileCommand {
  $key = [Microsoft.Win32.Registry]::ClassesRoot.OpenSubKey('RubyFile\shell\open\command')
  if (-not $key) { return $null }
  try { return [string]$key.GetValue('') } finally { $key.Close() }
}

# The file class .rb is set to now (RubyFile, another program's, or $null).
function Get-RbClass {
  $key = [Microsoft.Win32.Registry]::ClassesRoot.OpenSubKey('.rb')
  if (-not $key) { return $null }
  try { return [string]$key.GetValue('') } finally { $key.Close() }
}

function Confirm-Plan([string]$Question) {
  if ($Yes) { return $true }
  $reply = Read-Host "$Question [Y/n]"
  return ($reply -eq '' -or $reply -match '^(y|yes)$')
}

function Read-InstallState {
  if (Test-Path -LiteralPath $StatePath) {
    try { return (Get-Content -Raw -Encoding UTF8 -LiteralPath $StatePath | ConvertFrom-Json) } catch { Write-Verbose 'Ignoring an unreadable install state file.' }
  }
  return $null
}

function Test-ExeInstalled {
  foreach ($key in $ExeAppsKeys) { if (Test-Path -LiteralPath $key) { return $true } }
  return $false
}

# Where Ruby4Lich5.exe is installed (Inno Setup's InstallLocation), or $null.
function Get-ExeInstallLocation {
  foreach ($key in $ExeAppsKeys) {
    $entry = Get-ItemProperty -LiteralPath $key -ErrorAction SilentlyContinue
    if ($entry -and $entry.InstallLocation) { return ([string]$entry.InstallLocation).TrimEnd('\') }
  }
  return $null
}

# Creates a registry key only if it's missing (New-Item -Force on an existing
# key can clear it on Windows PowerShell 5.1), then sets its default value.
function Set-RegistryDefault([string]$Key, [string]$Value) {
  if (-not (Test-Path -LiteralPath $Key)) { New-Item -Path $Key -Force | Out-Null }
  Set-Item -LiteralPath $Key -Value $Value
}

function Set-RubyAssociations([string]$RubyBin) {
  $classes = 'HKCU:\Software\Classes'
  foreach ($pair in @(@('.rb', 'RubyFile', 'ruby.exe'), @('.rbw', 'RubyWFile', 'rubyw.exe'))) {
    $exe = Join-Path $RubyBin $pair[2]
    Set-RegistryDefault "$classes\$($pair[0])" $pair[1]
    Set-RegistryDefault "$classes\$($pair[1])" $pair[1]
    Set-RegistryDefault "$classes\$($pair[1])\DefaultIcon" "$exe,0"
    Set-RegistryDefault "$classes\$($pair[1])\shell\open\command" "`"$exe`" `"%1`" %*"
  }
}

# The -AddShortcut shortcuts: the Start menu's Lich5\Lich5, and "Start Lich5"
# on the Desktop (a GemStone IV Lich5 folder may already be there).
function Get-LichShortcutPaths {
  return @(
    (Join-Path (Join-Path ([Environment]::GetFolderPath('Programs')) 'Lich5') 'Lich5.lnk'),
    (Join-Path ([Environment]::GetFolderPath('Desktop')) 'Start Lich5.lnk')
  )
}

function New-LichShortcut([string]$Path, [string]$RubyBin, [string]$LichDir) {
  New-Item -ItemType Directory -Force -Path (Split-Path $Path) | Out-Null
  $path = $Path
  $shell = New-Object -ComObject WScript.Shell
  $shortcut = $shell.CreateShortcut($path)
  $shortcut.TargetPath = Join-Path $RubyBin 'rubyw.exe'
  $shortcut.Arguments = "`"$(Join-Path $LichDir 'lich.rbw')`""
  $shortcut.WorkingDirectory = $LichDir
  $shortcut.IconLocation = "$(Join-Path $RubyBin 'rubyw.exe'),0"
  $shortcut.Description = 'Start Lich5'
  $shortcut.Save()
  return $path
}

# The Lich folder: -Dir; else an existing install (this script's last one, the
# Desktop, or the DragonRealms location inside the Ruby folder); else ask, as
# Ruby4Lich5.exe does: Desktop\Lich5 for GemStone IV, <RubyDir>\Lich5 for
# DragonRealms, or a folder of your choice. -Yes takes the first choice.
function Select-LichDir($State, [string]$RubyRoot) {
  if ($Dir) { return (Resolve-UserPath $Dir) }
  $desktop = Join-Path ([Environment]::GetFolderPath('Desktop')) 'Lich5'
  $dr = Join-Path $RubyRoot 'Lich5'
  $candidates = @()
  if ($State -and $State.lich_dir) { $candidates += [string]$State.lich_dir }
  $candidates += @($desktop, $dr, (Join-Path $DefaultRubyDir 'Lich5'))
  $found = @($candidates | Select-Object -Unique | Where-Object { Test-Path -LiteralPath (Join-Path $_ 'lich.rbw') })
  if ($found.Count -gt 0) {
    if ($Yes) { return $found[0] }
    if (($found.Count -eq 1) -and (Confirm-Plan "Found Lich in $($found[0]). Update that install?")) { return $found[0] }
    if ($found.Count -gt 1) {
      Write-Host 'Found Lich in more than one place:'
      for ($i = 0; $i -lt $found.Count; $i++) { Write-Host "    [$($i + 1)] $($found[$i])" }
      Write-Host "    [$($found.Count + 1)] a different folder"
      $reply = Read-Host "Which one? [1]"
      if ($reply -eq '') { $reply = '1' }
      $index = 0
      if ([int]::TryParse($reply, [ref]$index) -and $index -ge 1 -and $index -le $found.Count) { return $found[$index - 1] }
    }
  } elseif ($Yes) {
    return $desktop
  }
  Write-Host 'Where should Lich5 go?'
  Write-Host "    [1] $desktop  (preferred for GemStone IV)"
  Write-Host "    [2] $dr  (preferred for DragonRealms)"
  Write-Host '    [3] a different folder'
  $choice = Read-Host 'Choose [1]'
  switch ($choice) {
    '2' { return $dr }
    '3' {
      $custom = Read-Host 'Full folder path, for example C:\Games\Lich5'
      if (-not $custom -or -not [IO.Path]::IsPathRooted($custom)) { throw 'Please enter a full folder path, such as C:\Games\Lich5.' }
      return (Resolve-UserPath $custom)
    }
    default { return $desktop }
  }
}

# The manifest units Lich itself would use: Lich's own recovery policy, run
# from the Lich folder, picks them for that Lich version (ranged units for its
# version, legacy units otherwise).
$SelectUnitsRuby = @'
require "json"
lich, manifest, platform = ARGV
target = JSON.parse(File.read(manifest))["targets"].find { |t| t["platform"] == platform }
abort("The gem manifest has no #{platform} target.") unless target
require File.join(lich, "lib", "recovery_unit_policy.rb")
version = File.read(File.join(lich, "lib", "version.rb"))[/^LICH_VERSION = '([^']+)'/, 1]
abort("Couldn't read LICH_VERSION from the Lich folder.") unless version
units = Lich::RecoveryUnitPolicy.select(target, version)
puts "# Lich #{version} uses #{units.length} of the manifest's #{target["units"].length} gem units."
puts units.map { |u| u["id"] }
'@

# The installed gems, one "name version platform" line each, so the skip check
# can tell a manifest build from a same-version gem built another way.
$InstalledGemsRuby = @'
Gem::Specification.each { |s| puts "#{s.name} #{s.version} #{s.platform}" }
'@

# Lich's own startup check: every required gem present, and on Windows each one
# a build Lich's accepted-gem policy accepts (what Lich enforces at startup).
$CheckGemsRuby = @'
require "gemcheck"
groups = [:default, :profanity, :gtk]
missing = Lich::GemCheck.missing_gems(groups)
abort("Lich's gem check found missing gems: #{missing.join(", ")}") unless missing.empty?
begin
  needed = Array(Lich::AcceptedGemPolicy.new.check(Lich::GemCheck.required_dependencies(groups)).needed)
rescue Lich::AcceptedGemPolicy::UnsupportedRuntimeError
  needed = []
end
abort("Lich's startup check would repair: #{needed.map { |n| n.respond_to?(:name) ? n.name : n.to_s }.join(", ")}") unless needed.empty?
'@

# ---------------------------------------------------------------------------
# Install
# ---------------------------------------------------------------------------
function Install-Lich5 {
  # Local to this function, so the user's window keeps its own settings.
  $ErrorActionPreference = 'Stop'
  $ProgressPreference = 'SilentlyContinue'
  # Gems go into the Ruby this script installs, not a gem home set elsewhere;
  # the caller's settings come back afterwards.
  $callerEnv = @{ GEM_HOME = $env:GEM_HOME; GEM_PATH = $env:GEM_PATH; Path = $env:Path; RV_NO_MODIFY_PATH = $env:RV_NO_MODIFY_PATH }
  Remove-Item Env:GEM_HOME, Env:GEM_PATH -ErrorAction SilentlyContinue
  $tmp = Join-Path ([IO.Path]::GetTempPath()) ('ruby4lich5-' + [guid]::NewGuid().ToString('N'))
  New-Item -ItemType Directory -Path $tmp | Out-Null
  $stage = $null
  $rubyStage = $null
  try {
    Write-Host 'Ruby4Lich5 installer for Windows' -ForegroundColor White

    # --- Where are we, and what does the live manifest want?
    Write-Step 'Checking the live gem manifest'
    $arch = [System.Runtime.InteropServices.RuntimeInformation]::OSArchitecture.ToString()
    switch ($arch) {
      'X64'   { $platform = 'x64-mingw-ucrt'; $riArch = 'x64' }
      'Arm64' { $platform = 'aarch64-mingw-ucrt'; $riArch = 'arm' }
      default { throw "Unsupported Windows architecture: $arch" }
    }
    if ($UseArmManifest -and $platform -ne 'aarch64-mingw-ucrt') { throw '-UseArmManifest is only for Windows on ARM.' }
    $manifestPath = Join-Path $tmp 'R4L5-gem-manifest.json'
    Save-Download "https://github.com/$R4l5Repo/releases/download/R4L5-gem-bundle-$platform/R4L5-gem-manifest.json" $manifestPath
    $target = (Get-Content -Raw -LiteralPath $manifestPath | ConvertFrom-Json).targets | Where-Object { $_.platform -eq $platform } | Select-Object -First 1
    if (-not $target) { throw "The live gem manifest has no $platform target." }
    $riVersion = [string]$target.contract.ruby_installer_version        # for example 4.0.9-1
    if ($riVersion -notmatch '^\d+\.\d+\.\d+-\d+$') { throw "The live gem manifest names an unexpected RubyInstaller version: '$riVersion'." }
    $rubyVersion = $riVersion.Split('-')[0]
    Write-Ok "$platform, manifest sha256 $((Get-Sha256 $manifestPath).Substring(0, 12))..., RubyInstaller $riVersion"

    Write-Step 'Checking the latest Lich release'
    $lich = Get-ReleaseAsset $LichRepo $null 'lich-5.zip'
    Write-Ok "Latest Lich: $($lich.Tag)"
    # The contract's Ruby is the default; the latest Lich's REQUIRED_RUBY is the
    # lowest it may be.
    try {
      $versionRb = (Invoke-WebRequest "https://raw.githubusercontent.com/$LichRepo/$($lich.Tag)/lib/version.rb" -UseBasicParsing).Content
      if ($versionRb -match "(?m)^\s*REQUIRED_RUBY\s*=\s*'([0-9.]+)'") {
        if ([version]$rubyVersion -lt [version]$Matches[1]) { throw "Lich $($lich.Tag) needs Ruby $($Matches[1]) or newer, but the Ruby4Lich5 contract names Ruby $rubyVersion. Use Ruby4Lich5.exe, or try again once the contract is updated." }
        Write-Ok "Ruby $rubyVersion (Lich requires $($Matches[1]) or newer)"
      }
    } catch [System.Net.WebException] {
      Write-Verbose "Couldn't read Lich's REQUIRED_RUBY: $($_.Exception.Message)"
    }

    $state = Read-InstallState
    $exeInstalled = Test-ExeInstalled
    # The Ruby folder: -RubyDir, else the one used last time, else C:\Ruby4Lich5.
    if ($RubyDir) { $rubyRoot = Resolve-UserPath $RubyDir }
    elseif ($state -and $state.ruby_root) { $rubyRoot = [string]$state.ruby_root }
    else { $rubyRoot = $DefaultRubyDir }
    $rubyRoot = $rubyRoot.TrimEnd('\')
    # Ruby4Lich5.exe uses the same <version> and current names in its folder,
    # and its uninstaller treats that folder as its own, so don't share it.
    $exeLocation = Get-ExeInstallLocation
    if ($exeLocation -and ($exeLocation -eq $rubyRoot)) {
      throw "Ruby4Lich5.exe is installed in $rubyRoot. Keep using it, or pass -RubyDir with a different folder for this script's Ruby (for example -RubyDir `"$env:LOCALAPPDATA\Lich5`")."
    }
    $RubyLink = Join-Path $rubyRoot 'current'
    $rubyDir = Join-Path $rubyRoot $rubyVersion
    # A version folder without Ruby in it (Ruby4Lich5.exe's uninstaller leaves
    # files it didn't install, such as later gems or a DevKit) would get the new
    # Ruby nested inside it.
    if ((Test-Path -LiteralPath $rubyDir) -and -not (Test-Path -LiteralPath (Join-Path $rubyDir 'bin\ruby.exe'))) {
      throw "$rubyDir exists but has no Ruby in it (left by an earlier uninstall?). Delete that folder and run this again."
    }
    # Lich running from this Ruby would lock its files partway through.
    $running = Get-ProcessUnder (@($RubyLink, $rubyDir) + @($(if ($state) { $state.ruby_dirs })))
    if ($running.Count) {
      throw "Close Lich first: $(@($running | ForEach-Object { $_.ProcessName } | Sort-Object -Unique) -join ', ') is running from Lich's Ruby. Nothing was changed."
    }
    $lichDir = Select-LichDir $state $rubyRoot
    $existing = Test-Path -LiteralPath (Join-Path $lichDir 'lich.rbw')
    if (-not $existing -and (Test-Path -LiteralPath $lichDir) -and (Get-ChildItem -Force -LiteralPath $lichDir | Select-Object -First 1)) {
      throw "$lichDir already exists, isn't empty, and doesn't look like a Lich folder. Choose another place with -Dir."
    }
    # Upgrades and uninstalling replace the Ruby version folders and current,
    # so Lich can't live inside one (<RubyDir>\Lich5 itself is fine).
    if ($lichDir.TrimEnd('\') -eq $rubyRoot) {
      throw "$lichDir is the Ruby folder itself. Choose another place with -Dir, such as $(Join-Path $rubyRoot 'Lich5')."
    }
    if ($lichDir.StartsWith("$rubyRoot\", [StringComparison]::OrdinalIgnoreCase)) {
      $top = Join-Path $rubyRoot ($lichDir.Substring($rubyRoot.Length + 1).Split('\')[0])
      if (($top -eq $RubyLink) -or ($top -eq $rubyDir) -or (Test-Path -LiteralPath (Join-Path $top 'bin\ruby.exe'))) {
        throw "$lichDir is inside the Ruby folder $top, which upgrades and uninstalling replace. Choose another place with -Dir, such as $(Join-Path $rubyRoot 'Lich5')."
      }
    }
    # .rb/.rbw: taken only when nothing else owns them (Ruby4Lich5.exe or
    # another Ruby); one this script set up earlier is updated.
    $rubyFileCommand = Get-RubyFileCommand
    $ours = @(@($RubyLink) + @($(if ($state) { $state.ruby_link })) | Where-Object { $_ -and $rubyFileCommand -and $rubyFileCommand.Contains([string]$_) })
    $rbClass = Get-RbClass
    $associate = -not $NoAssociations -and ($ours.Count -or (-not $rubyFileCommand -and (-not $rbClass -or $rbClass -eq 'RubyFile')))
    # A Ruby on the system PATH comes before the user PATH in new windows.
    # (Test-Path, not Join-Path: Join-Path fails on a quoted entry or a missing drive.)
    $otherRuby = @([Environment]::GetEnvironmentVariable('Path', 'Machine') -split ';' | Where-Object {
      $_.Trim() -and (Test-Path -LiteralPath ($_.Trim().Trim('"').TrimEnd('\') + '\ruby.exe') -ErrorAction SilentlyContinue)
    }) | Select-Object -First 1

    Write-Step 'Plan'
    Write-Info "System:        Windows $([Environment]::OSVersion.Version) ($platform)"
    if ($existing) { Write-Info "Lich folder:   $lichDir  (existing install: upgraded in place to Lich $($lich.Tag); settings and data are kept)" }
    else { Write-Info "Lich folder:   $lichDir  (new install of Lich $($lich.Tag))" }
    Write-Info "Ruby:          $rubyVersion (RubyInstaller $riVersion), installed with rv in $rubyDir"
    Write-Info "               $RubyLink points at it (-RubyDir to choose another folder)"
    Write-Info 'Gems:          prebuilt from the Ruby4Lich5 manifest, as Lich selects them (nothing is compiled)'
    if ($NoPath) { Write-Info 'PATH:          unchanged (-NoPath)' } else { Write-Info "PATH:          adds $RubyLink\bin to your user PATH" }
    if ($associate) { Write-Info 'Files:         .rb and .rbw open with this Ruby (-NoAssociations to skip)' }
    elseif ($NoAssociations) { Write-Info 'Files:         .rb and .rbw associations unchanged (-NoAssociations)' }
    else { Write-Info "Files:         .rb and .rbw associations left as they are ($(if ($rubyFileCommand) { "they open with: $rubyFileCommand" } else { ".rb is set to $rbClass" }))" }
    if ($AddShortcut) { Write-Info 'Shortcuts:     Lich5 in the Start menu, and Start Lich5 on the Desktop' }
    else { Write-Info 'Shortcuts:     none, as with Ruby4Lich5.exe (-AddShortcut adds Desktop and Start menu ones)' }
    if ($DevKit) {
      Write-Info 'DevKit:        MSYS2 and the MINGW toolchain (ridk install 1 2 3), about 1.5 GB to download;'
      Write-Info '               for compiling gems yourself. MSYS2 goes inside the Ruby folder, unless an'
      Write-Info '               existing MSYS2 is found (such as C:\msys64), which ridk then updates.'
    }
    Write-Info 'Uninstall:     Settings > Apps > "Lich5 (Ruby4Lich5 install script)", or run this with -Uninstall'
    if ($otherRuby -and -not $NoPath) {
      Write-Note "Another Ruby is on the system PATH ($otherRuby). New windows find it before Lich's, so a bare"
      Write-Note "'ruby' runs that one. The command shown at the end (and -AddShortcut's shortcuts) use Lich's Ruby."
    }
    if ($exeInstalled) {
      Write-Note "Ruby4Lich5.exe is also installed$(if ($exeLocation) { " in $exeLocation" }). Its Ruby stays; this Ruby comes first on your user PATH."
    }
    if ($platform -eq 'aarch64-mingw-ucrt') {
      $currentManifest = [Environment]::GetEnvironmentVariable('LICH_GEM_MANIFEST_URL', 'User')
      if ($UseArmManifest) {
        Write-Info 'ARM manifest:  Lich will use the ARM gem manifest (LICH_GEM_MANIFEST_URL). This opts in to the'
        Write-Info '               ARM soak: Lich enforces the ARM gem versions at startup and repairs from them.'
      } elseif ($currentManifest -eq $ArmManifestUrl) {
        Write-Info 'ARM manifest:  in use (set by an earlier run with -UseArmManifest); left as is.'
        Write-Info '               -Uninstall removes it, or delete the user variable LICH_GEM_MANIFEST_URL.'
      } elseif ($currentManifest) {
        Write-Info "ARM manifest:  LICH_GEM_MANIFEST_URL is set to $currentManifest; left as is."
      } else {
        Write-Info 'ARM manifest:  not set. Lich reads the x64 manifest and checks only for missing gems.'
        Write-Info '               To opt in to the ARM soak, re-run with -UseArmManifest.'
      }
    }
    if ($DevKit) { Write-Info 'Time:          a few minutes, plus 10-20 for the DevKit' } else { Write-Info 'Time:          a few minutes' }
    Write-Host ''
    if (-not (Confirm-Plan 'Continue?')) { Write-Host 'Cancelled. Nothing was changed.'; return }

    # --- rv
    Write-Step 'Setting up rv'
    $rvCommand = Get-Command rv.exe -ErrorAction SilentlyContinue
    $rv = Join-Path (Join-Path (Join-Path $HOME '.local') 'bin') 'rv.exe'
    if ($rvCommand) { $rv = $rvCommand.Source }
    $rvInstalledNow = $false
    if (-not (Test-Path -LiteralPath $rv)) {
      Write-Info 'Installing rv (https://rv.dev). It installs prebuilt Ruby.'
      # In its own process: under irm | iex it would share this script's scope.
      $rvInstaller = Join-Path $tmp 'rv-install.ps1'
      Save-Download 'https://rv.dev/install.ps1' $rvInstaller
      $env:RV_NO_MODIFY_PATH = '1'
      & powershell.exe -NoProfile -ExecutionPolicy Bypass -File $rvInstaller | Out-Null
      if ($LASTEXITCODE -ne 0) { throw "rv's installer failed." }
      if (-not (Test-Path -LiteralPath $rv)) { throw "rv's installer finished, but $rv is missing." }
      $rvInstalledNow = $true
    }
    Write-Ok (& $rv --version)

    # --- Ruby
    Write-Step "Installing Ruby $rubyVersion (RubyInstaller $riVersion)"
    $rubyInstalledNow = $false
    if (Test-Path -LiteralPath (Join-Path (Join-Path $rubyDir 'bin') 'ruby.exe')) {
      Write-Ok "Ruby $rubyVersion is already installed in $rubyDir"
    } else {
      $asset = "rubyinstaller-$riVersion-$riArch.7z"
      $ri = Get-ReleaseAsset 'oneclick/rubyinstaller2' "RubyInstaller-$riVersion" $asset
      $archive = Join-Path $tmp $asset
      Save-Verified $ri.Url $archive $ri.Digest
      Write-Ok "Verified $asset"
      # rv installs into <install-dir>\ruby-<version>. Install into a hidden
      # staging folder beside the target, then rename it to <RubyDir>\<version>
      # (Ruby4Lich5.exe's layout), so an interrupted run never leaves a partial
      # version folder. The version is passed explicitly: rv 0.7.2 mislabels a
      # --tarball-path install without one.
      New-Item -ItemType Directory -Force -Path $rubyRoot | Out-Null
      $rubyStage = Join-Path $rubyRoot ('.ruby-install-' + [guid]::NewGuid().ToString('N'))
      & $rv ruby install $rubyVersion --tarball-path $archive --install-dir $rubyStage
      if ($LASTEXITCODE -ne 0) { throw "rv couldn't install Ruby $rubyVersion." }
      $installed = Join-Path $rubyStage "ruby-$rubyVersion"
      if (-not (Test-Path -LiteralPath (Join-Path (Join-Path $installed 'bin') 'ruby.exe'))) { throw "rv reported success, but Ruby is missing from $installed." }
      Move-Item -LiteralPath $installed -Destination $rubyDir
      Remove-Item -LiteralPath $rubyStage -Recurse -Force
      $rubyStage = $null
      $rubyInstalledNow = $true
      Write-Ok "Ruby $rubyVersion is in $rubyDir"
    }
    # Until Lich's gem check passes, everything runs on the new Ruby directly;
    # current still points at the previous one.
    $newBin = Join-Path $rubyDir 'bin'
    $ruby = Join-Path $newBin 'ruby.exe'
    $env:Path = "$newBin;$env:Path"
    Write-Ok (& $ruby -v)

    # --- Lich: staged beside the folder. The unit selector, the gems and Lich's
    # gem check use this copy; the Lich folder changes only after the check,
    # so a failure leaves the previous Lich (and Ruby) as they were.
    Write-Step "Getting Lich $($lich.Tag)"
    $zip = Join-Path $tmp 'lich-5.zip'
    Save-Verified $lich.Url $zip $lich.Digest
    Write-Ok "Verified lich-5.zip ($($lich.Tag))"
    $parent = Split-Path $lichDir
    New-Item -ItemType Directory -Force -Path $parent | Out-Null
    $stage = Join-Path $parent ('.lich5-install-' + [guid]::NewGuid().ToString('N'))
    Expand-Archive -LiteralPath $zip -DestinationPath $stage
    $release = Join-Path $stage 'Lich5'
    if (-not (Test-Path -LiteralPath (Join-Path $release 'lich.rbw'))) { throw "The Lich archive didn't contain Lich5\lich.rbw." }

    # --- Gems, as Lich selects them, prebuilt, in the manifest's order
    Write-Step "Installing Lich's prebuilt gems"
    $selector = Join-Path $tmp 'select-units.rb'
    Set-Content -Encoding ascii -LiteralPath $selector -Value $SelectUnitsRuby
    # Notes come back on stdout as '# ...' lines: native stderr can become a
    # terminating error on Windows PowerShell 5.1 with ErrorActionPreference Stop.
    $selected = @(& $ruby $selector $release $manifestPath $platform)
    if ($LASTEXITCODE -ne 0) { throw "Couldn't select the gem units for this Lich." }
    $selected | Where-Object { $_ -like '# *' } | ForEach-Object { Write-Info $_.Substring(2) }
    $unitIds = @($selected | Where-Object { $_ -and $_ -notlike '# *' })
    if ($unitIds.Count -eq 0) { throw "Lich selected no gem units from the manifest." }
    $gem = Join-Path $newBin 'gem.cmd'
    $gemsList = Join-Path $tmp 'installed-gems.rb'
    Set-Content -Encoding ascii -LiteralPath $gemsList -Value $InstalledGemsRuby
    $installedGems = @(& $ruby $gemsList)
    if ($LASTEXITCODE -ne 0) { throw "Couldn't list the installed gems." }
    $unpacked = @{}
    foreach ($unitId in $unitIds) {
      $unit = $target.units | Where-Object { $_.id -eq $unitId } | Select-Object -First 1
      if (-not $unit) { throw "Lich selected a gem unit the manifest doesn't have: $unitId" }
      $artifact = $unit.artifact
      if (-not $unpacked.ContainsKey($artifact.url)) {
        $folder = Join-Path $tmp ('unit-' + $unpacked.Count)
        New-Item -ItemType Directory -Path $folder | Out-Null
        $file = Join-Path $folder $artifact.filename
        Save-Verified $artifact.url $file $artifact.sha256
        if ($artifact.archive -eq 'zip') { Expand-Archive -LiteralPath $file -DestinationPath $folder }
        $unpacked[$artifact.url] = $folder
      }
      foreach ($name in $unit.install_order) {
        $package = $unit.packages | Where-Object { $_.name -eq $name } | Select-Object -First 1
        if (-not $package) { throw "The manifest's $($unit.id) unit doesn't describe $name." }
        # Skip a gem only when this exact build is installed. A prebuilt gem's
        # file ends in -<platform>.gem (some also carry a prefix, such as
        # R4L5-ox-...), anything else is the plain ruby platform.
        $gemPlatform = $(if ($package.filename -like "*-$platform.gem") { $platform } else { 'ruby' })
        if ($installedGems -contains "$($package.name) $($package.version) $gemPlatform") { continue }
        $path = Join-Path $unpacked[$artifact.url] $package.filename
        if ((Get-Sha256 $path) -ne ($package.sha256 -replace '^sha256:', '')) { throw "Download check failed for $($package.filename)." }
        & $gem install --local --ignore-dependencies --no-document $path | Out-Null
        if ($LASTEXITCODE -ne 0) { throw "gem install failed for $($package.filename)." }
        Write-Info "installed $($package.name) $($package.version)"
      }
    }
    Write-Ok "Gems are installed ($($unitIds.Count) units)"

    # --- Lich's own startup check, before anything points at the new Ruby
    Write-Step 'Checking the install'
    $checkScript = Join-Path $tmp 'check.rb'
    Set-Content -Encoding ascii -LiteralPath $checkScript -Value $CheckGemsRuby
    # The manifest Lich will read at startup: the ARM one when opted in.
    $manifestEnvBefore = $env:LICH_GEM_MANIFEST_URL
    $userManifest = [Environment]::GetEnvironmentVariable('LICH_GEM_MANIFEST_URL', 'User')
    if ($UseArmManifest) { $env:LICH_GEM_MANIFEST_URL = $ArmManifestUrl } elseif ($userManifest) { $env:LICH_GEM_MANIFEST_URL = $userManifest }
    Push-Location -LiteralPath $release
    try {
      & $ruby -I lib $checkScript
      if ($LASTEXITCODE -ne 0) { throw "Lich's gem check failed with the new Ruby, so Lich still uses the previous one (if any)." }
    } finally {
      Pop-Location
      $env:LICH_GEM_MANIFEST_URL = $manifestEnvBefore
    }
    Write-Ok "Lich's gems are all present and accepted"

    # --- Put Lich in place. A new folder is renamed into place, so an
    # interrupted run never leaves a partial folder a rerun would take for an
    # install. An existing folder is upgraded in place, as Lich's own updater
    # does it: lib\ is replaced whole (Lich loads whole directories, so a file
    # a release renamed or removed must not linger), and the release's other
    # files are copied over (robocopy merges folders reliably and writes
    # through a junctioned scripts\ or data\; exit codes below 8 mean
    # success). Anything not in the release (settings, logins, data, logs) is
    # kept.
    if ($existing) {
      Write-Step "Upgrading Lich in $lichDir to $($lich.Tag)"
      robocopy (Join-Path $release 'lib') (Join-Path $lichDir 'lib') /MIR /R:2 /W:2 /NFL /NDL /NJH /NJS /NP | Out-Null
      if ($LASTEXITCODE -lt 8) { robocopy $release $lichDir /E /R:2 /W:2 /NFL /NDL /NJH /NJS /NP | Out-Null }
      if ($LASTEXITCODE -ge 8) { throw "Couldn't copy Lich $($lich.Tag) into $lichDir (robocopy exit $LASTEXITCODE). Close Lich and run this again." }
      Remove-Item -LiteralPath $stage -Recurse -Force
      $stage = $null
      Write-Ok "Lich in $lichDir is upgraded to $($lich.Tag) (settings and data kept)"
    } else {
      if (Test-Path -LiteralPath $lichDir) { [IO.Directory]::Delete($lichDir) }      # empty folder only; checked above
      Move-Item -LiteralPath $release -Destination $lichDir
      Remove-Item -LiteralPath $stage -Force
      $stage = $null
      Write-Ok "Lich $($lich.Tag) is in $lichDir"
    }

    # --- Switch to the new Ruby: re-point the junction. rmdir removes only the
    # link; Remove-Item could recurse into the Ruby it points at on Windows
    # PowerShell 5.1.
    New-Item -ItemType Directory -Force -Path $StateDir | Out-Null
    if (Test-Path -LiteralPath $RubyLink) { Invoke-Rmdir $RubyLink }
    New-Item -ItemType Junction -Path $RubyLink -Target $rubyDir | Out-Null
    $rubyBin = Join-Path $RubyLink 'bin'
    Write-Ok "$RubyLink now points at Ruby $rubyVersion"

    # --- Windows integration
    Write-Step 'Setting up Windows'
    if (-not $NoPath) {
      # Also drop the previous run's entry, in case the Ruby folder moved.
      Update-UserPath -Add $rubyBin -Remove @($(if ($state -and $state.path_entry) { [string]$state.path_entry }))
      Write-Ok "Added $rubyBin to your user PATH (new windows)"
    }
    if ($associate) {
      Set-RubyAssociations $rubyBin
      Write-Ok '.rb and .rbw files open with this Ruby'
    }
    # Recorded shortcuts the user has since deleted stay deleted.
    $shortcuts = @()
    if ($state -and $state.shortcuts) { $shortcuts += @($state.shortcuts | Where-Object { $_ -and (Test-Path -LiteralPath $_) }) }
    # Shortcuts from -AddShortcut, now or on an earlier run, are kept current.
    $shortcutPaths = @(Get-LichShortcutPaths)
    if ($AddShortcut) { $shortcuts += $shortcutPaths }
    foreach ($path in @($shortcuts | Where-Object { $_ } | Select-Object -Unique)) {
      if ($shortcutPaths -contains $path) { [void](New-LichShortcut $path $rubyBin $lichDir) }
    }
    if ($AddShortcut) { Write-Ok 'Shortcuts: Lich5 in the Start menu, Start Lich5 on the Desktop' }
    $manifestEnv = $null
    if ($state -and $state.manifest_url_env) { $manifestEnv = [string]$state.manifest_url_env }
    if ($UseArmManifest) {
      [Environment]::SetEnvironmentVariable('LICH_GEM_MANIFEST_URL', $ArmManifestUrl, 'User')
      $manifestEnv = $ArmManifestUrl
      Write-Ok 'Lich will use the ARM gem manifest (LICH_GEM_MANIFEST_URL)'
    }

    # --- What this script owns, for -Uninstall and Settings > Apps
    # Only Ruby folders this script installed, never one it found and reused.
    $rubyDirs = @()
    if ($state -and $state.ruby_dirs) { $rubyDirs += @($state.ruby_dirs) }
    if ($rubyInstalledNow) { $rubyDirs += $rubyDir }
    $installState = [ordered]@{
      schema = 1
      updated = (Get-Date).ToString('o')
      lich_dir = $lichDir
      ruby_root = $rubyRoot
      ruby_link = $RubyLink
      ruby_dirs = @($rubyDirs | Select-Object -Unique)
      rv_path = $rv
      rv_installed = ($rvInstalledNow -or ($state -and $state.rv_installed))
      path_entry = $(if ($NoPath) { if ($state) { $state.path_entry } else { $null } } else { $rubyBin })
      associations = ($associate -or ($state -and $state.associations))
      shortcuts = @($shortcuts | Where-Object { $_ } | Select-Object -Unique)
      manifest_url_env = $manifestEnv
      devkit = [bool]($state -and $state.devkit)
    }
    # UTF-8 (no BOM), so non-ASCII profile and folder paths survive.
    $utf8 = New-Object Text.UTF8Encoding $false
    [IO.File]::WriteAllText($StatePath, ($installState | ConvertTo-Json -Depth 4), $utf8)
    Set-Content -Encoding ascii -LiteralPath $UninstallScriptPath -Value $UninstallCode
    if (-not (Test-Path -LiteralPath $AppsKey)) { New-Item -Path $AppsKey -Force | Out-Null }
    $uninstallCommand = "powershell.exe -NoProfile -ExecutionPolicy Bypass -File `"$UninstallScriptPath`""
    Set-ItemProperty -LiteralPath $AppsKey -Name DisplayName -Value 'Lich5 (Ruby4Lich5 install script)'
    # The Lich in the folder, which a rerun leaves as it is.
    $lichVersion = (Select-String -LiteralPath (Join-Path $lichDir 'lib\version.rb') -Pattern "^LICH_VERSION = '([^']+)'" | Select-Object -First 1).Matches[0].Groups[1].Value
    Set-ItemProperty -LiteralPath $AppsKey -Name DisplayVersion -Value "Lich $lichVersion, Ruby $rubyVersion"
    Set-ItemProperty -LiteralPath $AppsKey -Name Publisher -Value 'Elanthia-Online'
    Set-ItemProperty -LiteralPath $AppsKey -Name InstallLocation -Value $lichDir
    Set-ItemProperty -LiteralPath $AppsKey -Name DisplayIcon -Value "$(Join-Path $rubyBin 'rubyw.exe'),0"
    Set-ItemProperty -LiteralPath $AppsKey -Name URLInfoAbout -Value "https://github.com/$R4l5Repo"
    Set-ItemProperty -LiteralPath $AppsKey -Name UninstallString -Value $uninstallCommand
    Set-ItemProperty -LiteralPath $AppsKey -Name QuietUninstallString -Value "$uninstallCommand -Yes"
    Set-ItemProperty -LiteralPath $AppsKey -Name NoModify -Value 1 -Type DWord
    Set-ItemProperty -LiteralPath $AppsKey -Name NoRepair -Value 1 -Type DWord
    Write-Ok 'Settings > Apps: "Lich5 (Ruby4Lich5 install script)"'

    # --- Optional DevKit (MSYS2 + MINGW toolchain), as Ruby4Lich5.exe's
    # finish-page option does. Component 1 (MSYS2 itself) is skipped when ridk
    # finds an existing MSYS2; otherwise it goes into <Ruby folder>\msys64, so
    # -Uninstall removes it with the Ruby folder.
    if ($DevKit) {
      Write-Step 'Installing the DevKit (MSYS2 and the MINGW toolchain)'
      Write-Info 'This downloads about 1.5 GB and can take 10-20 minutes.'
      # RubyInstaller before 4.0.10-1 asks pacman for mingw-w64-gcc and
      # mingw-w64-gcc-libs; the latter no longer exists for clangarm64, so its
      # toolchain step fails on Windows on ARM. Apply RubyInstaller's own fix
      # (oneclick/rubyinstaller2@17088a0: both become the mingw-w64-cc meta
      # package, gcc on x64 and clang on ARM), only where it is missing.
      $devTools = Get-ChildItem -LiteralPath (Join-Path (Join-Path $rubyDir 'lib') 'ruby') -Recurse -Filter '03_dev_tools.rb' |
        Where-Object { $_.FullName -like '*ruby_installer*runtime*components*' } | Select-Object -First 1
      if ($devTools) {
        $source = [IO.File]::ReadAllText($devTools.FullName)
        $fixed = [regex]::Replace($source, '(?m)^([ \t]*)mingw-w64-gcc\r?\n[ \t]*mingw-w64-gcc-libs(\r?)$', '${1}mingw-w64-cc$2')
        if ($fixed -ne $source) {
          [IO.File]::WriteAllText($devTools.FullName, $fixed)
          Write-Info 'Applied RubyInstaller 4.0.10-1''s DevKit package fix (mingw-w64-cc) to this Ruby.'
        }
      }
      # ridk reports progress on stderr (such as "MSYS2 seems to be
      # unavailable" before it installs MSYS2). When this script's output is
      # redirected, Windows PowerShell 5.1 turns stderr into errors that 'Stop'
      # makes fatal, so only the exit code decides here.
      $ErrorActionPreference = 'Continue'
      & (Join-Path $newBin 'ridk.cmd') install 1 2 3
      $ErrorActionPreference = 'Stop'
      if ($LASTEXITCODE -ne 0) { throw "ridk install failed (exit $LASTEXITCODE). Lich itself is installed; re-run with -DevKit to try the DevKit again." }
      Write-Ok 'DevKit installed (use it with: ridk enable)'
      $installState.devkit = $true
      [IO.File]::WriteAllText($StatePath, ($installState | ConvertTo-Json -Depth 4), $utf8)
    }


    Write-Host ''
    Write-Host 'Done!' -ForegroundColor Green
    Write-Host ''
    Write-Host "    Lich folder:  $lichDir"
    Write-Host "    Ruby:         $rubyBin\ruby.exe"
    Write-Host ''
    if (@($shortcuts).Count) { Write-Host '    Start Lich from its shortcut (Start Lich5 on the Desktop, Lich5 in the Start menu), or with:' } else { Write-Host '    Start Lich with:' }
    Write-Host ''
    Write-Host "        & $(ConvertTo-Literal (Join-Path $rubyBin 'rubyw.exe')) $(ConvertTo-Literal (Join-Path $lichDir 'lich.rbw'))"
    Write-Host ''
    Write-Host '    Front ends (Wrayth, Wizard, Saga, ...): https://gswiki.play.net/Lich:Software/Front_ends'
    Write-Host '    Run this again later to upgrade Lich, Ruby and the gems'
    Write-Host '    (or update Lich alone from inside the game:  ;lich5-update --update).'
    Write-Host ''
  } catch {
    Write-Host ''
    Write-Host "Error: $($_.Exception.Message)" -ForegroundColor Red
    Write-Host "Need help? Ask in #scripting or #help on the GemStone IV Discord ($Discord)," -ForegroundColor DarkGray
    Write-Host "or follow the manual guide: $Wiki/Windows" -ForegroundColor DarkGray
    throw
  } finally {
    if ($stage -and (Test-Path -LiteralPath $stage)) { Remove-Item -LiteralPath $stage -Recurse -Force -ErrorAction SilentlyContinue }
    if ($rubyStage -and (Test-Path -LiteralPath $rubyStage)) { Remove-Item -LiteralPath $rubyStage -Recurse -Force -ErrorAction SilentlyContinue }
    Remove-Item -LiteralPath $tmp -Recurse -Force -ErrorAction SilentlyContinue
    foreach ($name in $callerEnv.Keys) { [Environment]::SetEnvironmentVariable($name, $callerEnv[$name], 'Process') }
  }
}

. ([scriptblock]::Create($HelperCode))

if ($Uninstall) {
  & ([scriptblock]::Create($UninstallCode)) -Yes:$Yes -RemoveLich:$RemoveLich
} else {
  Install-Lich5
}
