BeforeAll {
    . "$PSScriptRoot/../../update-ruby-path.ps1"
}

Describe 'Ruby4Lich5 user PATH ownership' {
    It 'replaces stale versioned and junction entries, preserving unrelated tokens exactly' {
        $old = 'C:\Tools;"c:/ruby4lich5/4.0.5/bin/";C:\Ruby4Lich5\current\bin;C:\OtherRuby\bin;%USERPROFILE%\bin;;C:\Ruby4Lich5\data'
        Get-R4LUserPath -CurrentPath $old -InstallRoot 'C:\Ruby4Lich5' -Mode Install -RubyVersion '4.0.9' |
            Should -Be 'C:\Ruby4Lich5\4.0.9\bin;C:\Tools;C:\OtherRuby\bin;%USERPROFILE%\bin;;C:\Ruby4Lich5\data'
    }

    It 'is idempotent when reinstalling and removes duplicate owned entries' {
        $first = Get-R4LUserPath -CurrentPath 'C:\Tools;C:\Ruby4Lich5\4.0.9\bin;C:\Ruby4Lich5\4.0.9\bin' -InstallRoot 'C:\Ruby4Lich5' -Mode Install -RubyVersion '4.0.9'
        Get-R4LUserPath -CurrentPath $first -InstallRoot 'C:\Ruby4Lich5' -Mode Install -RubyVersion '4.0.9' | Should -Be $first
        $first | Should -Be 'C:\Ruby4Lich5\4.0.9\bin;C:\Tools'
    }

    It 'uninstalls only entries belonging to this exact root' {
        Get-R4LUserPath -CurrentPath 'C:\Ruby4Lich5-other\4.0.9\bin;C:\Ruby4Lich5\4.0.9\bin;C:\Ruby4Lich5\current\bin;C:\Ruby4Lich5\custom\bin' -InstallRoot 'C:\Ruby4Lich5' -Mode Uninstall |
            Should -Be 'C:\Ruby4Lich5-other\4.0.9\bin;C:\Ruby4Lich5\custom\bin'
    }

    It 'recognizes environment references for comparison without expanding retained entries' {
        $env:R4L_PATH_TEST = 'C:\Ruby4Lich5'
        try {
            Get-R4LUserPath -CurrentPath '%R4L_PATH_TEST%\4.0.5\bin;%USERPROFILE%\bin' -InstallRoot 'C:\Ruby4Lich5' -Mode Uninstall | Should -Be '%USERPROFILE%\bin'
        } finally { Remove-Item Env:R4L_PATH_TEST }
    }

    It 'handles a missing PATH without adding empty entries' {
        Get-R4LUserPath -CurrentPath '' -InstallRoot 'C:\Ruby4Lich5' -Mode Install -RubyVersion '4.0.9' | Should -Be 'C:\Ruby4Lich5\4.0.9\bin'
        Get-R4LUserPath -CurrentPath '' -InstallRoot 'C:\Ruby4Lich5' -Mode Uninstall | Should -Be ''
    }

    It 'rejects relative roots and unsafe versions' {
        { Get-R4LUserPath -CurrentPath '' -InstallRoot 'Ruby4Lich5' -Mode Uninstall } | Should -Throw '*absolute Windows*'
        { Get-R4LUserPath -CurrentPath '' -InstallRoot 'C:\Ruby;Other' -Mode Uninstall } | Should -Throw '*absolute Windows*'
        { Get-R4LUserPath -CurrentPath '' -InstallRoot 'C:\Ruby4Lich5' -Mode Install -RubyVersion '..\other' } | Should -Throw '*N.N.N*'
    }
}

Describe 'User registry PATH update' {
    BeforeEach {
        $script:writes = @()
        $script:notifications = 0
        $script:oldPath = 'C:\Tools;C:\Ruby4Lich5\4.0.5\bin'
        $script:kind = [Microsoft.Win32.RegistryValueKind]::ExpandString
        $script:deny = $false
        $script:key = [pscustomobject]@{}
        $script:key | Add-Member ScriptMethod GetValue { param($name, $default, $options) $script:oldPath }
        $script:key | Add-Member ScriptMethod GetValueKind { param($name) $script:kind }
        $script:key | Add-Member ScriptMethod SetValue {
            param($name, $value, $type)
            if ($script:deny) { throw 'access denied' }
            $script:writes += @{ Name = $name; Value = $value; Kind = $type }
        }
        Mock Test-Path { $true }
    }

    It 'preserves the original registry type and notifies after one write' -ForEach @(
        @{ Type = [Microsoft.Win32.RegistryValueKind]::ExpandString },
        @{ Type = [Microsoft.Win32.RegistryValueKind]::String }
    ) {
        $script:kind = $Type
        Update-R4LUserPath -Mode Install -InstallRoot 'C:\Ruby4Lich5' -RubyVersion '4.0.9' -RegistryKey $script:key -Notify { $script:notifications++ } | Out-Null
        $script:writes.Count | Should -Be 1
        $script:writes[0].Kind | Should -Be $Type
        $script:writes[0].Value | Should -Be 'C:\Ruby4Lich5\4.0.9\bin;C:\Tools'
        $script:notifications | Should -Be 1
    }

    It 'does not write or notify when nothing changes' {
        $script:oldPath = 'C:\Tools'
        Update-R4LUserPath -Mode Uninstall -InstallRoot 'C:\Ruby4Lich5' -RegistryKey $script:key -Notify { throw 'must not notify' } | Should -Be 'C:\Tools'
        $script:writes | Should -BeNullOrEmpty
    }

    It 'completes the Ruby PATH update for a <Case> before optional Lich acquisition' -ForEach @(
        @{ Case = 'fresh install'; PriorPath = 'C:\Tools' },
        @{ Case = 'version upgrade'; PriorPath = 'C:\Tools;C:\Ruby4Lich5\4.0.5\bin;C:\Ruby4Lich5\current\bin' }
    ) {
        $script:oldPath = $PriorPath
        Update-R4LUserPath -Mode Install -InstallRoot 'C:\Ruby4Lich5' -RubyVersion '4.0.9' -RegistryKey $script:key -Notify { $script:notifications++ } | Out-Null
        $script:writes.Count | Should -Be 1
        $script:writes[0].Value | Should -Be 'C:\Ruby4Lich5\4.0.9\bin;C:\Tools'
        $script:notifications | Should -Be 1
    }

    It 'reports an unsupported registry type without changing PATH' {
        $script:kind = [Microsoft.Win32.RegistryValueKind]::DWord
        { Update-R4LUserPath -Mode Uninstall -InstallRoot 'C:\Ruby4Lich5' -RegistryKey $script:key -Notify { $script:notifications++ } } | Should -Throw '*unsupported registry value type*'
        $script:writes | Should -BeNullOrEmpty
        $script:notifications | Should -Be 0
    }

    It 'reports an unwritable registry without notification' {
        $script:deny = $true
        { Update-R4LUserPath -Mode Uninstall -InstallRoot 'C:\Ruby4Lich5' -RegistryKey $script:key -Notify { $script:notifications++ } } | Should -Throw '*access denied*'
        $script:notifications | Should -Be 0
    }

    It 'refuses to install a PATH entry before Ruby exists' {
        Mock Test-Path { $false }
        { Update-R4LUserPath -Mode Install -InstallRoot 'C:\Ruby4Lich5' -RubyVersion '4.0.9' -RegistryKey $script:key } | Should -Throw '*executable is missing*'
        $script:writes | Should -BeNullOrEmpty
    }
}
