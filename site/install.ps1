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
# 2. Gems: Lich's gems come prebuilt from that manifest, the same set Lich's own
#    startup check enforces. Each artifact is checked against its SHA-256 and
#    the gems are installed in the manifest's order, so nothing is compiled and
#    Lich starts without a repair.
# 3. Lich: the latest release, checked against its SHA-256.
#
# Run it again at any time: an existing Lich folder is left alone, and Ruby and
# the gems are brought up to date. Ruby4Lich5.exe remains the full installer
# (Start menu, uninstaller, file associations); this script is the one-command
# alternative, and also covers Windows on ARM.
#
# Windows PowerShell 5.1 compatible. Errors are thrown, never exit: under
# irm | iex an exit would close the user's PowerShell window.
param(
  # Lich folder. Default: Desktop\Lich5.
  [string]$Dir = '',
  # Don't change the user PATH.
  [switch]$NoPath,
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
# A stable path to the Ruby Lich uses; upgrades re-point it (like C:\Ruby4Lich5\current).
$RubyLink = Join-Path (Join-Path $env:LOCALAPPDATA 'Lich5') 'ruby'

function Write-Step([string]$Message) { Write-Host ''; Write-Host "==> $Message" -ForegroundColor Cyan }
function Write-Ok([string]$Message) { Write-Host "    ok $Message" -ForegroundColor Green }
function Write-Info([string]$Message) { Write-Host "    $Message" }

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
    $manifestPath = Join-Path $tmp 'R4L5-gem-manifest.json'
    Invoke-WebRequest -Uri "https://github.com/$R4l5Repo/releases/download/R4L5-gem-bundle-$platform/R4L5-gem-manifest.json" -OutFile $manifestPath -UseBasicParsing
    $target = (Get-Content -Raw $manifestPath | ConvertFrom-Json).targets | Where-Object { $_.platform -eq $platform } | Select-Object -First 1
    if (-not $target) { throw "The live gem manifest has no $platform target." }
    $riVersion = [string]$target.contract.ruby_installer_version        # for example 4.0.9-1
    if ($riVersion -notmatch '^\d+\.\d+\.\d+-\d+$') { throw "The live gem manifest names an unexpected RubyInstaller version: '$riVersion'." }
    $rubyVersion = $riVersion.Split('-')[0]
    # Units for a Lich version range or kept for older Lich releases aren't
    # needed by the latest Lich.
    $units = @($target.units | Where-Object { -not $_.lich_versions -and -not $_.lifecycle })
    Write-Ok "$platform, manifest sha256 $((Get-Sha256 $manifestPath).Substring(0, 12))..., RubyInstaller $riVersion"

    Write-Step 'Checking the latest Lich release'
    $lich = Get-ReleaseAsset $LichRepo $null 'lich-5.zip'
    Write-Ok "Latest Lich: $($lich.Tag)"

    if (-not $Dir) { $Dir = Join-Path ([Environment]::GetFolderPath('Desktop')) 'Lich5' }
    $Dir = [IO.Path]::GetFullPath($Dir)
    $existing = Test-Path (Join-Path $Dir 'lich.rbw')
    if (-not $existing -and (Test-Path $Dir) -and (Get-ChildItem -Force -LiteralPath $Dir | Select-Object -First 1)) {
      throw "$Dir already exists, isn't empty, and doesn't look like a Lich folder. Choose another place with -Dir."
    }

    Write-Step 'Plan'
    Write-Info "System:       Windows $([Environment]::OSVersion.Version) ($platform)"
    if ($existing) { Write-Info "Lich folder:  $Dir  (existing install: left as is, only Ruby and gems are updated)" }
    else { Write-Info "Lich folder:  $Dir  (new install of Lich $($lich.Tag))" }
    Write-Info "Ruby:         $rubyVersion (RubyInstaller $riVersion), installed with rv; Lich uses $RubyLink"
    Write-Info "Gems:         $($units.Count) prebuilt units from the Ruby4Lich5 manifest (nothing is compiled)"
    if ($NoPath) { Write-Info 'PATH:         unchanged (-NoPath)' } else { Write-Info "PATH:         adds $RubyLink\bin to your user PATH" }
    Write-Info 'Time:         a few minutes'
    Write-Host ''
    if (-not (Confirm-Plan 'Continue?')) { Write-Host 'Cancelled. Nothing was changed.'; return }

    # --- rv
    Write-Step 'Setting up rv'
    $rvCommand = Get-Command rv.exe -ErrorAction SilentlyContinue
    $rv = Join-Path (Join-Path (Join-Path $HOME '.local') 'bin') 'rv.exe'
    if ($rvCommand) { $rv = $rvCommand.Source }
    if (-not (Test-Path $rv)) {
      Write-Info 'Installing rv (https://rv.dev). It installs prebuilt Ruby.'
      # In its own process: under irm | iex it would share this script's scope.
      $rvInstaller = Join-Path $tmp 'rv-install.ps1'
      Invoke-WebRequest -Uri 'https://rv.dev/install.ps1' -OutFile $rvInstaller -UseBasicParsing
      $env:RV_NO_MODIFY_PATH = '1'
      & powershell.exe -NoProfile -ExecutionPolicy Bypass -File $rvInstaller | Out-Null
      if ($LASTEXITCODE -ne 0) { throw "rv's installer failed." }
      if (-not (Test-Path $rv)) { throw "rv's installer finished, but $rv is missing." }
    }
    Write-Ok (& $rv --version)

    # --- Ruby
    Write-Step "Installing Ruby $rubyVersion (RubyInstaller $riVersion)"
    $rubies = (& $rv ruby dir | Out-String).Trim()
    $rubyDir = Join-Path $rubies "ruby-$rubyVersion"
    if (Test-Path (Join-Path (Join-Path $rubyDir 'bin') 'ruby.exe')) {
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
      if (-not (Test-Path (Join-Path (Join-Path $rubyDir 'bin') 'ruby.exe'))) { throw "rv reported success, but Ruby is missing from $rubyDir." }
    }
    # Re-point the junction. rmdir removes only the link; Remove-Item could
    # recurse into the Ruby it points at on Windows PowerShell 5.1.
    New-Item -ItemType Directory -Force -Path (Split-Path $RubyLink) | Out-Null
    if (Test-Path $RubyLink) { cmd.exe /c rmdir "$RubyLink" | Out-Null }
    New-Item -ItemType Junction -Path $RubyLink -Target $rubyDir | Out-Null
    $rubyBin = Join-Path $RubyLink 'bin'
    $env:Path = "$rubyBin;$env:Path"
    Write-Ok (& (Join-Path $rubyBin 'ruby.exe') -v)

    # --- Gems, prebuilt, in the manifest's order
    Write-Step "Installing Lich's prebuilt gems"
    $gem = Join-Path $rubyBin 'gem.cmd'
    $unpacked = @{}
    foreach ($unit in $units) {
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
    Write-Ok 'Gems are installed'

    # --- Lich
    Write-Step 'Installing Lich'
    if ($existing) {
      Write-Ok "Found Lich in $Dir. Leaving it as it is."
      Write-Info 'To update Lich itself, enter this in the game:  ;lich5-update --update'
    } else {
      $zip = Join-Path $tmp 'lich-5.zip'
      Save-Verified $lich.Url $zip $lich.Digest
      Write-Ok "Verified lich-5.zip ($($lich.Tag))"
      # Unpack beside the destination and rename into place, so an interrupted
      # run never leaves a partial folder a rerun would take for an install.
      $parent = Split-Path $Dir
      New-Item -ItemType Directory -Force -Path $parent | Out-Null
      $stage = Join-Path $parent ('.lich5-install-' + [guid]::NewGuid().ToString('N'))
      Expand-Archive -LiteralPath $zip -DestinationPath $stage
      if (-not (Test-Path (Join-Path (Join-Path $stage 'Lich5') 'lich.rbw'))) { throw "The Lich archive didn't contain Lich5\lich.rbw." }
      if (Test-Path $Dir) { [IO.Directory]::Delete($Dir) }      # empty folder only; checked above
      Move-Item -LiteralPath (Join-Path $stage 'Lich5') -Destination $Dir
      Remove-Item -LiteralPath $stage -Force
      $stage = $null
      Write-Ok "Lich $($lich.Tag) is in $Dir"
    }

    # --- PATH
    if (-not $NoPath) {
      Write-Step "Putting Lich's Ruby on your PATH"
      $userPath = [Environment]::GetEnvironmentVariable('Path', 'User')
      $kept = @($userPath -split ';' | Where-Object { $_ -and ($_.TrimEnd('\') -ne $rubyBin) })
      [Environment]::SetEnvironmentVariable('Path', ((@($rubyBin) + $kept) -join ';'), 'User')
      Write-Ok "Added $rubyBin to your user PATH (new windows)"
    }

    # --- Check
    Write-Step 'Checking the install'
    Push-Location $Dir
    try {
      $check = Join-Path $tmp 'check.rb'
      Set-Content -Encoding ascii -Path $check -Value 'require "gemcheck"; m = Lich::GemCheck.missing_gems([:default, :profanity, :gtk]); abort("missing: " + m.join(", ")) unless m.empty?'
      & (Join-Path $rubyBin 'ruby.exe') -I lib $check
      if ($LASTEXITCODE -ne 0) { throw "Lich's gem check found missing gems." }
    } finally { Pop-Location }
    Write-Ok "Lich's gems are all present"

    Write-Host ''
    Write-Host 'Done!' -ForegroundColor Green
    Write-Host ''
    Write-Host "    Lich folder:  $Dir"
    Write-Host "    Ruby:         $rubyBin\ruby.exe"
    Write-Host ''
    Write-Host '    Start Lich with:'
    Write-Host ''
    Write-Host "        & '$rubyBin\rubyw.exe' '$Dir\lich.rbw'"
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
    if ($stage -and (Test-Path $stage)) { Remove-Item -LiteralPath $stage -Recurse -Force -ErrorAction SilentlyContinue }
    Remove-Item -LiteralPath $tmp -Recurse -Force -ErrorAction SilentlyContinue
  }
}

Install-Lich5
