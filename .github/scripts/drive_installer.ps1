# Release check for the manual release runbook (docs/RELEASING.md), used by
# release-check-installer-acceptance.yml: run Ruby4Lich5.exe interactively (it
# refuses silent mode by design) and click through its wizard with UI
# Automation. The type, task and folder are preselected on the command line,
# which Inno Setup honours in interactive mode too, so the script only presses
# Next / Install / Finish. Any message box fails the run with its text.
#
#   drive_installer.ps1 -Installer <Ruby4Lich5.exe> -Log <install.log>
param([Parameter(Mandatory)] [string]$Installer, [Parameter(Mandatory)] [string]$Log)
$ErrorActionPreference = 'Stop'
Add-Type -AssemblyName UIAutomationClient, UIAutomationTypes
# Inno Setup's TNewButton exposes no UI Automation patterns, so buttons are
# clicked by posting BM_CLICK to their window handle.
Add-Type -Namespace Win32 -Name User32 -MemberDefinition '[DllImport("user32.dll")] public static extern bool PostMessage(System.IntPtr hWnd, uint Msg, System.IntPtr wParam, System.IntPtr lParam);'
$BM_CLICK = 0x00F5
$AE = [System.Windows.Automation.AutomationElement]
$TS = [System.Windows.Automation.TreeScope]
$PC = [System.Windows.Automation.PropertyCondition]

$process = Start-Process -FilePath $Installer -ArgumentList '/TYPE=full', '/TASKS=LichDR', '/DIR=C:\Ruby4Lich5', "/LOG=$Log" -PassThru
$deadline = (Get-Date).AddMinutes(15)

# Setup relaunches itself as a temporary Ruby4Lich5.tmp process (/SL5=...);
# the wizard and any message box belong to that child, so look at every
# window owned by either process.
function Get-Windows {
  $ids = @($process.Id) + @(Get-Process -ErrorAction SilentlyContinue | Where-Object { $_.ProcessName -like 'Ruby4Lich5*' } | ForEach-Object { $_.Id })
  foreach ($id in ($ids | Sort-Object -Unique)) {
    $condition = New-Object $PC ($AE::ProcessIdProperty), $id
    $AE::RootElement.FindAll($TS::Children, $condition)
  }
}
function Get-Buttons($window) {
  $window.FindAll($TS::Descendants, [System.Windows.Automation.Condition]::TrueCondition) |
    Where-Object { $_.Current.ClassName -in @('TNewButton', 'TButton', 'Button') }
}
function Show-Tree($window) {
  $window.FindAll($TS::Descendants, [System.Windows.Automation.Condition]::TrueCondition) | ForEach-Object {
    $c = $_.Current
    Write-Host ("  {0} class={1} name='{2}' enabled={3} offscreen={4} patterns={5}" -f $c.ControlType.ProgrammaticName, $c.ClassName, $c.Name, $c.IsEnabled, $c.IsOffscreen, (($_.GetSupportedPatterns() | ForEach-Object { $_.ProgrammaticName }) -join ','))
  }
}
function Get-Text($window) {
  $condition = New-Object $PC ($AE::ControlTypeProperty), ([System.Windows.Automation.ControlType]::Text)
  ($window.FindAll($TS::Descendants, $condition) | ForEach-Object { $_.Current.Name }) -join ' | '
}

$clicked = @()
$started = Get-Date
$dumped = $false
while (-not $process.HasExited) {
  if (-not $clicked -and ((Get-Date) - $started).TotalMinutes -gt 3) {
    foreach ($window in Get-Windows) { Write-Host "window $($window.Current.ClassName) '$($window.Current.Name)'"; Show-Tree $window }
    throw 'no wizard button was clicked within 3 minutes; see the control tree above'
  }
  if (-not $dumped -and ((Get-Date) - $started).TotalSeconds -gt 20) {
    foreach ($window in Get-Windows) { Write-Host "window $($window.Current.ClassName) '$($window.Current.Name)'"; Show-Tree $window }
    $dumped = $true
  }
  if ((Get-Date) -gt $deadline) {
    $seen = (Get-Windows | ForEach-Object { "$($_.Current.ClassName):'$($_.Current.Name)'" }) -join ', '
    throw "installer wizard did not finish within 15 minutes; clicked: $($clicked -join ', '); windows: $seen"
  }
  foreach ($window in Get-Windows) {
    $title = $window.Current.Name
    if ($window.Current.ClassName -eq '#32770') {
      throw "installer showed a message box '$title': $(Get-Text $window)"
    }
    foreach ($button in Get-Buttons $window) {
      $name = $button.Current.Name -replace '&', ''
      if ($name -match '^\s*(Next|Install|Finish)' -and $button.Current.IsEnabled) {
        Write-Host "[$title] click '$name'"
        $clicked += $name
        [void][Win32.User32]::PostMessage([System.IntPtr]$button.Current.NativeWindowHandle, $BM_CLICK, [System.IntPtr]::Zero, [System.IntPtr]::Zero)
        Start-Sleep -Seconds 2
        break
      }
    }
  }
  Start-Sleep -Seconds 2
}
Write-Host "installer exited with code $($process.ExitCode) after clicking: $($clicked -join ', ')"
if ($process.ExitCode -ne 0) { throw "installer exit code $($process.ExitCode)" }
if ($clicked -notcontains 'Finish') { throw 'installer exited without reaching the Finish page' }
