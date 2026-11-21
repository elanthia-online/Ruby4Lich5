# Ruby4Lich5 installer for Windows (PowerShell).
#
#   irm https://ruby4lich5.elanthia.online/install.ps1 | iex
#
# With options:
#   & ([scriptblock]::Create((irm https://ruby4lich5.elanthia.online/install.ps1))) -Dir C:\Games\Lich5 -Yes
#
# 1. Ruby: rv (https://rv.dev) installs the RubyInstaller build that the live
#    Ruby4Lich5 gem manifest was built for (no DevKit or MSYS2), after this
#    script checks the archive against the SHA-256 GitHub publishes for it.
# 2. Lich: the latest release, checked against its SHA-256, unless the chosen
#    folder already holds Lich.
# 3. Gems: the units that Lich's own recovery policy selects for that Lich
#    version, prebuilt from the manifest, each checked against its SHA-256 and
#    installed in the manifest's order. That is the set Lich's startup check
#    enforces, so Lich starts without a repair and nothing is compiled.
# 4. Windows integration: Lich's Ruby on the user PATH, .rb/.rbw file
#    associations, a Start menu shortcut, and an entry in Settings > Apps that
#    uninstalls what this script added.
# 5. Optionally (-DevKit), the RubyInstaller DevKit: MSYS2 and the MINGW
#    toolchain through ridk, for compiling gems yourself. Lich doesn't need it.
#
# Run it again at any time: an existing Lich folder is left alone, and Ruby and
# the gems are brought up to date. Ruby4Lich5.exe remains the full installer;
# this script is the one-command alternative, and also covers Windows on ARM.
#
# Windows PowerShell 5.1 compatible, ASCII only. Errors are thrown, never exit:
# under irm | iex an exit would close the user's PowerShell window.
param(
  # Lich folder. Default: an existing Lich install if one is found, otherwise
  # ask (or Desktop\Lich5 with -Yes).
  [string]$Dir = '',
  # Don't change the user PATH.
  [switch]$NoPath,
  # Don't associate .rb and .rbw files with Lich's Ruby.
  [switch]$NoAssociations,
  # Don't create a Start menu shortcut.
  [switch]$NoShortcut,
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
$ErrorActionPreference = 'Stop'
$ProgressPreference = 'SilentlyContinue'
[Net.ServicePointManager]::SecurityProtocol = [Net.ServicePointManager]::SecurityProtocol -bor [Net.SecurityProtocolType]::Tls12

$R4l5Repo = 'elanthia-online/Ruby4Lich5'
$LichRepo = 'elanthia-online/lich-5'
$Wiki = 'https://gswiki.play.net/Lich:Software/Installation'
$Discord = 'https://discord.gg/KF9Wr8u'
$StateDir = Join-Path $env:LOCALAPPDATA 'Lich5'
$StatePath = Join-Path $StateDir 'install-state.json'
$UninstallScriptPath = Join-Path $StateDir 'uninstall.ps1'
# A stable path to the Ruby Lich uses; upgrades re-point it (like C:\Ruby4Lich5\current).
$RubyLink = Join-Path $StateDir 'ruby'
$AppsKey = 'HKCU:\Software\Microsoft\Windows\CurrentVersion\Uninstall\Lich5-Ruby4Lich5-script'
$ExeAppsKeys = @(
  'HKCU:\Software\Microsoft\Windows\CurrentVersion\Uninstall\{edd9ccd7-33cb-4577-a470-fe8fd087eb07}_is1',
  'HKLM:\Software\Microsoft\Windows\CurrentVersion\Uninstall\{edd9ccd7-33cb-4577-a470-fe8fd087eb07}_is1',
  'HKLM:\Software\WOW6432Node\Microsoft\Windows\CurrentVersion\Uninstall\{edd9ccd7-33cb-4577-a470-fe8fd087eb07}_is1'
)
$ArmManifestUrl = "https://github.com/$R4l5Repo/releases/download/R4L5-gem-bundle-aarch64-mingw-ucrt/R4L5-gem-manifest.json"

# ---------------------------------------------------------------------------
# Uninstaller. Self-contained: it runs for -Uninstall and is saved as
# %LOCALAPPDATA%\Lich5\uninstall.ps1 for the Settings > Apps entry. It removes
# only what install-state.json records, and only while it is still ours.
# ---------------------------------------------------------------------------
$UninstallCode = @'
param([switch]$Yes, [switch]$RemoveLich)
$ErrorActionPreference = 'Stop'
$stateDir = Join-Path $env:LOCALAPPDATA 'Lich5'
$statePath = Join-Path $stateDir 'install-state.json'
$appsKey = 'HKCU:\Software\Microsoft\Windows\CurrentVersion\Uninstall\Lich5-Ruby4Lich5-script'
if (-not (Test-Path -LiteralPath $statePath)) {
  Write-Host 'Nothing to uninstall: no Lich install by the Ruby4Lich5 install script was found.'
  Write-Host 'Ruby4Lich5.exe installs are removed from Settings > Apps instead.'
  return
}
$state = Get-Content -Raw -LiteralPath $statePath | ConvertFrom-Json

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

if ($state.path_entry) {
  $userPath = [Environment]::GetEnvironmentVariable('Path', 'User')
  if ($userPath) {
    $kept = @($userPath -split ';' | Where-Object { $_ -and ($_.TrimEnd('\') -ne $state.path_entry) })
    [Environment]::SetEnvironmentVariable('Path', ($kept -join ';'), 'User')
  }
}
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
    $folder = Split-Path $shortcut
    if (-not (Get-ChildItem -Force -LiteralPath $folder | Select-Object -First 1)) { Remove-Item -LiteralPath $folder -Force }
  }
}
# The junction first (rmdir removes only the link), then the Ruby folders.
if ($state.ruby_link -and (Test-Path -LiteralPath $state.ruby_link)) { cmd.exe /c rmdir "$($state.ruby_link)" | Out-Null }
foreach ($rubyDir in @($state.ruby_dirs)) {
  if ($rubyDir -and (Test-Path -LiteralPath $rubyDir)) { Remove-Item -LiteralPath $rubyDir -Recurse -Force }
}
if ($state.rv_installed -and $state.rv_path) {
  $rvDir = Split-Path $state.rv_path
  foreach ($name in @('rv.exe', 'rvx.exe')) {
    $file = Join-Path $rvDir $name
    if (Test-Path -LiteralPath $file) { Remove-Item -LiteralPath $file -Force }
  }
  if ($state.rv_rubies -and (Test-Path -LiteralPath $state.rv_rubies) -and -not (Get-ChildItem -Force -LiteralPath $state.rv_rubies | Select-Object -First 1)) {
    Remove-Item -LiteralPath $state.rv_rubies -Force
  }
}
if ($RemoveLich -and $state.lich_dir -and (Test-Path -LiteralPath (Join-Path $state.lich_dir 'lich.rbw'))) {
  Remove-Item -LiteralPath $state.lich_dir -Recurse -Force
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
'@

# ---------------------------------------------------------------------------
# Helpers
# ---------------------------------------------------------------------------
function Write-Step([string]$Message) { Write-Host ''; Write-Host "==> $Message" -ForegroundColor Cyan }
function Write-Ok([string]$Message) { Write-Host "    ok $Message" -ForegroundColor Green }
function Write-Info([string]$Message) { Write-Host "    $Message" }
function Write-Note([string]$Message) { Write-Host "    ! $Message" -ForegroundColor Yellow }

function Get-Sha256([string]$Path) { (Get-FileHash -Algorithm SHA256 -LiteralPath $Path).Hash.ToLowerInvariant() }

function Save-Verified([string]$Url, [string]$Path, [string]$Expected) {
  $Expected = $Expected -replace '^sha256:', ''
  Invoke-WebRequest -Uri $Url -OutFile $Path -UseBasicParsing
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

function Confirm-Plan([string]$Question) {
  if ($Yes) { return $true }
  $reply = Read-Host "$Question [Y/n]"
  return ($reply -eq '' -or $reply -match '^(y|yes)$')
}

function Read-InstallState {
  if (Test-Path -LiteralPath $StatePath) {
    try { return (Get-Content -Raw -LiteralPath $StatePath | ConvertFrom-Json) } catch { Write-Verbose 'Ignoring an unreadable install state file.' }
  }
  return $null
}

function Test-ExeInstalled {
  foreach ($key in $ExeAppsKeys) { if (Test-Path -LiteralPath $key) { return $true } }
  return $false
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

function New-LichShortcut([string]$RubyBin, [string]$LichDir) {
  $folder = Join-Path ([Environment]::GetFolderPath('Programs')) 'Lich5'
  New-Item -ItemType Directory -Force -Path $folder | Out-Null
  $path = Join-Path $folder 'Lich5.lnk'
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
# Desktop or Ruby4Lich5.exe's DragonRealms location); else ask, as
# Ruby4Lich5.exe does. -Yes takes the first choice without asking.
function Select-LichDir($State) {
  if ($Dir) { return [IO.Path]::GetFullPath($Dir) }
  $desktop = Join-Path ([Environment]::GetFolderPath('Desktop')) 'Lich5'
  $dr = Join-Path 'C:\Ruby4Lich5' 'Lich5'
  $candidates = @()
  if ($State -and $State.lich_dir) { $candidates += [string]$State.lich_dir }
  $candidates += @($desktop, $dr)
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
      return [IO.Path]::GetFullPath($custom)
    }
    default { return $desktop }
  }
}

# The manifest units Lich itself would use: Lich's own recovery policy, run
# from the Lich folder, picks them for that Lich version (ranged units for its
# version, legacy units otherwise). Lich before 5.24.0 has no policy file and
# predates ranges, so it gets every unit without a Lich version range.
$SelectUnitsRuby = @'
require "json"
lich, manifest, platform = ARGV
target = JSON.parse(File.read(manifest))["targets"].find { |t| t["platform"] == platform }
abort("The gem manifest has no #{platform} target.") unless target
policy = File.join(lich, "lib", "recovery_unit_policy.rb")
if File.file?(policy)
  require policy
  version = File.read(File.join(lich, "lib", "version.rb"))[/^LICH_VERSION = '([^']+)'/, 1]
  abort("Couldn't read LICH_VERSION from the Lich folder.") unless version
  units = Lich::RecoveryUnitPolicy.select(target, version)
  puts "# Lich #{version} uses #{units.length} of the manifest's #{target["units"].length} gem units."
else
  units = target["units"].reject { |u| u.key?("lich_versions") }
  puts "# This Lich predates gem unit selection; using #{units.length} gem units."
end
puts units.map { |u| u["id"] }
'@

# ---------------------------------------------------------------------------
# Install
# ---------------------------------------------------------------------------
function Install-Lich5 {
  $tmp = Join-Path ([IO.Path]::GetTempPath()) ('ruby4lich5-' + [guid]::NewGuid().ToString('N'))
  New-Item -ItemType Directory -Path $tmp | Out-Null
  $stage = $null
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
    Invoke-WebRequest -Uri "https://github.com/$R4l5Repo/releases/download/R4L5-gem-bundle-$platform/R4L5-gem-manifest.json" -OutFile $manifestPath -UseBasicParsing
    $target = (Get-Content -Raw $manifestPath | ConvertFrom-Json).targets | Where-Object { $_.platform -eq $platform } | Select-Object -First 1
    if (-not $target) { throw "The live gem manifest has no $platform target." }
    $riVersion = [string]$target.contract.ruby_installer_version        # for example 4.0.9-1
    if ($riVersion -notmatch '^\d+\.\d+\.\d+-\d+$') { throw "The live gem manifest names an unexpected RubyInstaller version: '$riVersion'." }
    $rubyVersion = $riVersion.Split('-')[0]
    Write-Ok "$platform, manifest sha256 $((Get-Sha256 $manifestPath).Substring(0, 12))..., RubyInstaller $riVersion"

    Write-Step 'Checking the latest Lich release'
    $lich = Get-ReleaseAsset $LichRepo $null 'lich-5.zip'
    Write-Ok "Latest Lich: $($lich.Tag)"

    $state = Read-InstallState
    $exeInstalled = Test-ExeInstalled
    $lichDir = Select-LichDir $state
    $existing = Test-Path -LiteralPath (Join-Path $lichDir 'lich.rbw')
    if (-not $existing -and (Test-Path -LiteralPath $lichDir) -and (Get-ChildItem -Force -LiteralPath $lichDir | Select-Object -First 1)) {
      throw "$lichDir already exists, isn't empty, and doesn't look like a Lich folder. Choose another place with -Dir."
    }
    # Ruby4Lich5.exe already owns .rb/.rbw; don't take them over from it.
    $associate = -not $NoAssociations -and -not $exeInstalled

    Write-Step 'Plan'
    Write-Info "System:        Windows $([Environment]::OSVersion.Version) ($platform)"
    if ($existing) { Write-Info "Lich folder:   $lichDir  (existing install: left as is, only Ruby and gems are updated)" }
    else { Write-Info "Lich folder:   $lichDir  (new install of Lich $($lich.Tag))" }
    Write-Info "Ruby:          $rubyVersion (RubyInstaller $riVersion), installed with rv; Lich uses $RubyLink"
    Write-Info 'Gems:          prebuilt from the Ruby4Lich5 manifest, as Lich selects them (nothing is compiled)'
    if ($NoPath) { Write-Info 'PATH:          unchanged (-NoPath)' } else { Write-Info "PATH:          adds $RubyLink\bin to your user PATH" }
    if ($associate) { Write-Info 'Files:         .rb and .rbw open with this Ruby (-NoAssociations to skip)' }
    elseif ($exeInstalled) { Write-Info 'Files:         .rb and .rbw associations left to Ruby4Lich5.exe, which is also installed' }
    else { Write-Info 'Files:         .rb and .rbw associations unchanged (-NoAssociations)' }
    if ($NoShortcut) { Write-Info 'Start menu:    no shortcut (-NoShortcut)' } else { Write-Info 'Start menu:    a Lich5 shortcut' }
    if ($DevKit) {
      Write-Info 'DevKit:        MSYS2 and the MINGW toolchain (ridk install 1 2 3), about 1.5 GB to download;'
      Write-Info '               for compiling gems yourself. MSYS2 goes inside the Ruby folder, unless an'
      Write-Info '               existing MSYS2 is found (such as C:\msys64), which ridk then updates.'
    }
    Write-Info 'Uninstall:     Settings > Apps > "Lich5 (Ruby4Lich5 install script)", or run this with -Uninstall'
    if ($exeInstalled) {
      Write-Note 'Ruby4Lich5.exe is also installed. Its Ruby stays; this Ruby comes first on your user PATH.'
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
      Invoke-WebRequest -Uri 'https://rv.dev/install.ps1' -OutFile $rvInstaller -UseBasicParsing
      $env:RV_NO_MODIFY_PATH = '1'
      & powershell.exe -NoProfile -ExecutionPolicy Bypass -File $rvInstaller | Out-Null
      if ($LASTEXITCODE -ne 0) { throw "rv's installer failed." }
      if (-not (Test-Path -LiteralPath $rv)) { throw "rv's installer finished, but $rv is missing." }
      $rvInstalledNow = $true
    }
    Write-Ok (& $rv --version)

    # --- Ruby
    Write-Step "Installing Ruby $rubyVersion (RubyInstaller $riVersion)"
    $rubies = (& $rv ruby dir | Out-String).Trim()
    $rubyDir = Join-Path $rubies "ruby-$rubyVersion"
    if (Test-Path -LiteralPath (Join-Path (Join-Path $rubyDir 'bin') 'ruby.exe')) {
      Write-Ok "Ruby $rubyVersion is already installed"
    } else {
      $asset = "rubyinstaller-$riVersion-$riArch.7z"
      $ri = Get-ReleaseAsset 'oneclick/rubyinstaller2' "RubyInstaller-$riVersion" $asset
      $archive = Join-Path $tmp $asset
      Save-Verified $ri.Url $archive $ri.Digest
      Write-Ok "Verified $asset"
      # The version is passed explicitly: rv 0.7.2 mislabels a --tarball-path install without one.
      & $rv ruby install $rubyVersion --tarball-path $archive
      if ($LASTEXITCODE -ne 0) { throw "rv couldn't install Ruby $rubyVersion." }
      if (-not (Test-Path -LiteralPath (Join-Path (Join-Path $rubyDir 'bin') 'ruby.exe'))) { throw "rv reported success, but Ruby is missing from $rubyDir." }
    }
    # Re-point the junction. rmdir removes only the link; Remove-Item could
    # recurse into the Ruby it points at on Windows PowerShell 5.1.
    New-Item -ItemType Directory -Force -Path $StateDir | Out-Null
    if (Test-Path -LiteralPath $RubyLink) { cmd.exe /c rmdir "$RubyLink" | Out-Null }
    New-Item -ItemType Junction -Path $RubyLink -Target $rubyDir | Out-Null
    $rubyBin = Join-Path $RubyLink 'bin'
    $ruby = Join-Path $rubyBin 'ruby.exe'
    $env:Path = "$rubyBin;$env:Path"
    Write-Ok (& $ruby -v)

    # --- Lich (before the gems: Lich's own policy picks them)
    Write-Step 'Installing Lich'
    if ($existing) {
      Write-Ok "Found Lich in $lichDir. Leaving it as it is."
      Write-Info 'To update Lich itself, enter this in the game:  ;lich5-update --update'
    } else {
      $zip = Join-Path $tmp 'lich-5.zip'
      Save-Verified $lich.Url $zip $lich.Digest
      Write-Ok "Verified lich-5.zip ($($lich.Tag))"
      # Unpack beside the destination and rename into place, so an interrupted
      # run never leaves a partial folder a rerun would take for an install.
      $parent = Split-Path $lichDir
      New-Item -ItemType Directory -Force -Path $parent | Out-Null
      $stage = Join-Path $parent ('.lich5-install-' + [guid]::NewGuid().ToString('N'))
      Expand-Archive -LiteralPath $zip -DestinationPath $stage
      if (-not (Test-Path -LiteralPath (Join-Path (Join-Path $stage 'Lich5') 'lich.rbw'))) { throw "The Lich archive didn't contain Lich5\lich.rbw." }
      if (Test-Path -LiteralPath $lichDir) { [IO.Directory]::Delete($lichDir) }      # empty folder only; checked above
      Move-Item -LiteralPath (Join-Path $stage 'Lich5') -Destination $lichDir
      Remove-Item -LiteralPath $stage -Force
      $stage = $null
      Write-Ok "Lich $($lich.Tag) is in $lichDir"
    }

    # --- Gems, as Lich selects them, prebuilt, in the manifest's order
    Write-Step "Installing Lich's prebuilt gems"
    $selector = Join-Path $tmp 'select-units.rb'
    Set-Content -Encoding ascii -LiteralPath $selector -Value $SelectUnitsRuby
    # Notes come back on stdout as '# ...' lines: native stderr can become a
    # terminating error on Windows PowerShell 5.1 with ErrorActionPreference Stop.
    $selected = @(& $ruby $selector $lichDir $manifestPath $platform)
    if ($LASTEXITCODE -ne 0) { throw "Couldn't select the gem units for this Lich." }
    $selected | Where-Object { $_ -like '# *' } | ForEach-Object { Write-Info $_.Substring(2) }
    $unitIds = @($selected | Where-Object { $_ -and $_ -notlike '# *' })
    if ($unitIds.Count -eq 0) { throw "Lich selected no gem units from the manifest." }
    $gem = Join-Path $rubyBin 'gem.cmd'
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
        & $gem list --installed --exact $package.name --version $package.version | Out-Null
        if ($LASTEXITCODE -eq 0) { continue }
        $path = Join-Path $unpacked[$artifact.url] $package.filename
        if ((Get-Sha256 $path) -ne ($package.sha256 -replace '^sha256:', '')) { throw "Download check failed for $($package.filename)." }
        & $gem install --local --ignore-dependencies --no-document $path | Out-Null
        if ($LASTEXITCODE -ne 0) { throw "gem install failed for $($package.filename)." }
        Write-Info "installed $($package.name) $($package.version)"
      }
    }
    Write-Ok "Gems are installed ($($unitIds.Count) units)"

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
      & (Join-Path $rubyBin 'ridk.cmd') install 1 2 3
      if ($LASTEXITCODE -ne 0) { throw "ridk install failed (exit $LASTEXITCODE). Lich itself is installed; re-run with -DevKit to try the DevKit again." }
      Write-Ok 'DevKit installed (use it with: ridk enable)'
    }

    # --- Windows integration
    Write-Step 'Setting up Windows'
    if (-not $NoPath) {
      $userPath = [Environment]::GetEnvironmentVariable('Path', 'User')
      $kept = @($userPath -split ';' | Where-Object { $_ -and ($_.TrimEnd('\') -ne $rubyBin) })
      [Environment]::SetEnvironmentVariable('Path', ((@($rubyBin) + $kept) -join ';'), 'User')
      Write-Ok "Added $rubyBin to your user PATH (new windows)"
    }
    if ($associate) {
      Set-RubyAssociations $rubyBin
      Write-Ok '.rb and .rbw files open with this Ruby'
    }
    $shortcuts = @()
    if ($state -and $state.shortcuts) { $shortcuts += @($state.shortcuts) }
    if (-not $NoShortcut) {
      $shortcuts += New-LichShortcut $rubyBin $lichDir
      Write-Ok 'Start menu shortcut: Lich5'
    }
    $manifestEnv = $null
    if ($state -and $state.manifest_url_env) { $manifestEnv = [string]$state.manifest_url_env }
    if ($UseArmManifest) {
      [Environment]::SetEnvironmentVariable('LICH_GEM_MANIFEST_URL', $ArmManifestUrl, 'User')
      $manifestEnv = $ArmManifestUrl
      Write-Ok 'Lich will use the ARM gem manifest (LICH_GEM_MANIFEST_URL)'
    }

    # --- What this script owns, for -Uninstall and Settings > Apps
    $rubyDirs = @()
    if ($state -and $state.ruby_dirs) { $rubyDirs += @($state.ruby_dirs) }
    $rubyDirs += $rubyDir
    $installState = [ordered]@{
      schema = 1
      updated = (Get-Date).ToString('o')
      lich_dir = $lichDir
      ruby_link = $RubyLink
      ruby_dirs = @($rubyDirs | Select-Object -Unique)
      rv_path = $rv
      rv_rubies = $rubies
      rv_installed = ($rvInstalledNow -or ($state -and $state.rv_installed))
      path_entry = $(if ($NoPath) { if ($state) { $state.path_entry } else { $null } } else { $rubyBin })
      associations = ($associate -or ($state -and $state.associations))
      shortcuts = @($shortcuts | Where-Object { $_ } | Select-Object -Unique)
      manifest_url_env = $manifestEnv
      devkit = ($DevKit -or ($state -and $state.devkit))
    }
    $installState | ConvertTo-Json -Depth 4 | Set-Content -Encoding ascii -LiteralPath $StatePath
    Set-Content -Encoding ascii -LiteralPath $UninstallScriptPath -Value $UninstallCode
    if (-not (Test-Path -LiteralPath $AppsKey)) { New-Item -Path $AppsKey -Force | Out-Null }
    $uninstallCommand = "powershell.exe -NoProfile -ExecutionPolicy Bypass -File `"$UninstallScriptPath`""
    Set-ItemProperty -LiteralPath $AppsKey -Name DisplayName -Value 'Lich5 (Ruby4Lich5 install script)'
    Set-ItemProperty -LiteralPath $AppsKey -Name DisplayVersion -Value "Lich $($lich.Tag.TrimStart('v')), Ruby $rubyVersion"
    Set-ItemProperty -LiteralPath $AppsKey -Name Publisher -Value 'Elanthia-Online'
    Set-ItemProperty -LiteralPath $AppsKey -Name InstallLocation -Value $lichDir
    Set-ItemProperty -LiteralPath $AppsKey -Name DisplayIcon -Value "$(Join-Path $rubyBin 'rubyw.exe'),0"
    Set-ItemProperty -LiteralPath $AppsKey -Name URLInfoAbout -Value "https://github.com/$R4l5Repo"
    Set-ItemProperty -LiteralPath $AppsKey -Name UninstallString -Value $uninstallCommand
    Set-ItemProperty -LiteralPath $AppsKey -Name QuietUninstallString -Value "$uninstallCommand -Yes"
    Set-ItemProperty -LiteralPath $AppsKey -Name NoModify -Value 1 -Type DWord
    Set-ItemProperty -LiteralPath $AppsKey -Name NoRepair -Value 1 -Type DWord
    Write-Ok 'Settings > Apps: "Lich5 (Ruby4Lich5 install script)"'

    # --- Check
    Write-Step 'Checking the install'
    Push-Location $lichDir
    try {
      $check = Join-Path $tmp 'check.rb'
      Set-Content -Encoding ascii -LiteralPath $check -Value 'require "gemcheck"; m = Lich::GemCheck.missing_gems([:default, :profanity, :gtk]); abort("missing: " + m.join(", ")) unless m.empty?'
      & $ruby -I lib $check
      if ($LASTEXITCODE -ne 0) { throw "Lich's gem check found missing gems." }
    } finally { Pop-Location }
    Write-Ok "Lich's gems are all present"

    Write-Host ''
    Write-Host 'Done!' -ForegroundColor Green
    Write-Host ''
    Write-Host "    Lich folder:  $lichDir"
    Write-Host "    Ruby:         $rubyBin\ruby.exe"
    Write-Host ''
    if (-not $NoShortcut) { Write-Host '    Start Lich from the Start menu (Lich5), or with:' } else { Write-Host '    Start Lich with:' }
    Write-Host ''
    Write-Host "        & '$rubyBin\rubyw.exe' '$lichDir\lich.rbw'"
    Write-Host ''
    Write-Host '    Front ends (Wrayth, Wizard, Saga, ...): https://gswiki.play.net/Lich:Software/Front_ends'
    Write-Host '    Keep Lich up to date from inside the game:  ;lich5-update --update'
    Write-Host '    Run this again later to move to a newer Ruby and gems.'
    Write-Host ''
  } catch {
    Write-Host ''
    Write-Host "Error: $($_.Exception.Message)" -ForegroundColor Red
    Write-Host "Need help? Ask in #scripting or #help on the GemStone IV Discord ($Discord)," -ForegroundColor DarkGray
    Write-Host "or follow the manual guide: $Wiki/Windows" -ForegroundColor DarkGray
    throw
  } finally {
    if ($stage -and (Test-Path -LiteralPath $stage)) { Remove-Item -LiteralPath $stage -Recurse -Force -ErrorAction SilentlyContinue }
    Remove-Item -LiteralPath $tmp -Recurse -Force -ErrorAction SilentlyContinue
  }
}

if ($Uninstall) {
  & ([scriptblock]::Create($UninstallCode)) -Yes:$Yes -RemoveLich:$RemoveLich
} else {
  Install-Lich5
}
