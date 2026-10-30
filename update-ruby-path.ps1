# Updates only this install root's Ruby entries in the current user's PATH.
[CmdletBinding()]
param(
    [ValidateSet('Install', 'Uninstall')][string]$Mode,
    [string]$InstallRoot,
    [string]$RubyVersion
)

function Get-R4LNormalizedPath {
    param([string]$Value)
    [Environment]::ExpandEnvironmentVariables($Value.Trim().Trim('"')).Replace('/', '\').TrimEnd('\')
}

function Get-R4LUserPath {
    param(
        [AllowEmptyString()][string]$CurrentPath,
        [Parameter(Mandatory)][string]$InstallRoot,
        [Parameter(Mandatory)][ValidateSet('Install', 'Uninstall')][string]$Mode,
        [string]$RubyVersion
    )
    $root = Get-R4LNormalizedPath $InstallRoot
    if ($root -notmatch '^(?:[A-Za-z]:\\|\\\\[^\\]+\\[^\\]+\\).+' -or $root -match '[;"\r\n]') {
        throw 'InstallRoot must be an absolute Windows directory below a drive or share root.'
    }
    if ($Mode -eq 'Install' -and $RubyVersion -notmatch '^\d+\.\d+\.\d+$') {
        throw 'RubyVersion must be N.N.N for installation.'
    }
    $owned = '^' + [regex]::Escape($root) + '\\(?:current|\d+\.\d+\.\d+)\\bin$'
    $kept = [System.Collections.Generic.List[string]]::new()
    if ($Mode -eq 'Install') { $kept.Add("$root\$RubyVersion\bin") }
    if ($CurrentPath.Length -gt 0) {
        foreach ($entry in $CurrentPath.Split(';')) {
            if ((Get-R4LNormalizedPath $entry) -notmatch $owned) { $kept.Add($entry) }
        }
    }
    $kept -join ';'
}

function Send-R4LEnvironmentChange {
    if (-not ('R4L.EnvironmentChange' -as [type])) {
        Add-Type @'
using System;
using System.Runtime.InteropServices;
namespace R4L {
    public static class EnvironmentChange {
        [DllImport("user32.dll", CharSet = CharSet.Unicode, SetLastError = true)]
        public static extern IntPtr SendMessageTimeout(IntPtr hwnd, uint msg,
            UIntPtr wparam, string lparam, uint flags, uint timeout, out UIntPtr result);
    }
}
'@
    }
    $result = [UIntPtr]::Zero
    $sent = [R4L.EnvironmentChange]::SendMessageTimeout([IntPtr]0xffff, 0x001a,
        [UIntPtr]::Zero, 'Environment', 2, 5000, [ref]$result)
    if ($sent -eq [IntPtr]::Zero) { Write-Warning 'PATH was saved; environment change notification timed out.' }
}

function Update-R4LUserPath {
    param(
        [Parameter(Mandatory)][ValidateSet('Install', 'Uninstall')][string]$Mode,
        [Parameter(Mandatory)][string]$InstallRoot,
        [string]$RubyVersion,
        $RegistryKey,
        [scriptblock]$Notify = { Send-R4LEnvironmentChange }
    )
    $ownedKey = $false
    try {
        if ($null -eq $RegistryKey) {
            if ([Environment]::OSVersion.Platform -ne [PlatformID]::Win32NT) { throw 'The user PATH can only be updated on Windows.' }
            $RegistryKey = [Microsoft.Win32.Registry]::CurrentUser.CreateSubKey('Environment')
            $ownedKey = $true
        }
        if ($Mode -eq 'Install' -and -not (Test-Path -LiteralPath "$InstallRoot\$RubyVersion\bin\ruby.exe" -PathType Leaf)) {
            throw 'The installed Ruby executable is missing; PATH was not changed.'
        }
        $old = $RegistryKey.GetValue('Path', $null, [Microsoft.Win32.RegistryValueOptions]::DoNotExpandEnvironmentNames)
        $kind = [Microsoft.Win32.RegistryValueKind]::ExpandString
        if ($null -ne $old) {
            $kind = $RegistryKey.GetValueKind('Path')
            if ($kind -notin @([Microsoft.Win32.RegistryValueKind]::String, [Microsoft.Win32.RegistryValueKind]::ExpandString)) {
                throw 'The user PATH has an unsupported registry value type; PATH was not changed.'
            }
        }
        $updated = Get-R4LUserPath -CurrentPath ([string]$old) -InstallRoot $InstallRoot -Mode $Mode -RubyVersion $RubyVersion
        if ($updated -cne [string]$old) {
            $RegistryKey.SetValue('Path', $updated, $kind)
            try { & $Notify } catch { Write-Warning "PATH was saved; notification failed: $_" }
        }
        $updated
    }
    finally { if ($ownedKey -and $null -ne $RegistryKey) { $RegistryKey.Dispose() } }
}

if ($MyInvocation.InvocationName -ne '.') {
    $ErrorActionPreference = 'Stop'
    if (-not $Mode -or -not $InstallRoot) { throw 'Mode and InstallRoot are required.' }
    Update-R4LUserPath -Mode $Mode -InstallRoot $InstallRoot -RubyVersion $RubyVersion
}
