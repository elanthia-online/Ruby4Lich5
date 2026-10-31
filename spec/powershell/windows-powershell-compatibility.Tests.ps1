BeforeAll {
    $root = Split-Path (Split-Path $PSScriptRoot -Parent) -Parent
    $sources = @(
        Get-ChildItem -LiteralPath $root -Filter '*.ps1' -File
        Get-ChildItem -LiteralPath $PSScriptRoot -Filter '*.ps1' -File -Recurse
    )
    $workflow = Get-Content (Join-Path $root '.github/workflows/pester_tests.yaml') -Raw
    $start = $workflow.IndexOf('          if ($env:PESTER_SHELL')
    if ($start -lt 0) { throw 'Pester runtime verification is missing.' }
    $end = $workflow.IndexOf('          Import-Module Pester', $start)
    if ($end -le $start) { throw 'Pester runtime verification is missing.' }
    # Exercise the actual preflight with injected version data, without changing
    # the host's automatic PSVersionTable variable or installing any module.
    $versionGuard = [scriptblock]::Create($workflow.Substring($start, $end - $start).Replace('$PSVersionTable', '$FixtureVersion'))

    function Get-JoinPathCompatibilityErrors {
        param([System.Management.Automation.Language.Ast]$Ast)
        $calls = $Ast.FindAll({
            param($node)
            $node -is [System.Management.Automation.Language.CommandAst] -and
                $node.GetCommandName() -eq 'Join-Path'
        }, $true)
        foreach ($call in $calls) {
            $arguments = @($call.CommandElements | Select-Object -Skip 1)
            $parameters = @($arguments | Where-Object { $_ -is [System.Management.Automation.Language.CommandParameterAst] })
            # PowerShell 6 added AdditionalChildPath and its remaining-position binding.
            # Keep this guard on pwsh too, where the incompatible call would succeed.
            if (($parameters.ParameterName -contains 'AdditionalChildPath') -or
                ($parameters.Count -eq 0 -and $arguments.Count -gt 2)) {
                "Line $($call.Extent.StartLineNumber): $($call.Extent.Text)"
            }
        }
    }
}

Describe 'Pester lane runtime identity' {
    BeforeEach {
        $previousShell = $env:PESTER_SHELL
        Mock Write-Host {}
    }
    AfterEach { $env:PESTER_SHELL = $previousShell }

    It 'checks <Shell> against <Edition> <Major>.<Minor>' -ForEach @(
        @{ Shell = 'powershell'; Edition = 'Desktop'; Major = 5; Minor = 1; Accepted = $true }
        @{ Shell = 'powershell'; Edition = 'Core'; Major = 7; Minor = 6; Accepted = $false }
        @{ Shell = 'powershell'; Edition = 'Desktop'; Major = 5; Minor = 0; Accepted = $false }
        @{ Shell = 'pwsh'; Edition = 'Core'; Major = 7; Minor = 6; Accepted = $true }
        @{ Shell = 'pwsh'; Edition = 'Desktop'; Major = 5; Minor = 1; Accepted = $false }
    ) {
        $env:PESTER_SHELL = $Shell
        $FixtureVersion = @{ PSEdition = $Edition; PSVersion = [version]"$Major.$Minor" }
        if ($Accepted) { { & $versionGuard } | Should -Not -Throw }
        else { { & $versionGuard } | Should -Throw }
    }
}

Describe 'Windows PowerShell compatibility' {
    It 'parses every standalone helper and PowerShell test on the executing engine' {
        foreach ($source in $sources) {
            $tokens = $null; $errors = $null
            $null = [System.Management.Automation.Language.Parser]::ParseFile($source.FullName, [ref]$tokens, [ref]$errors)
            @($errors).Count | Should -Be 0 -Because $source.FullName
        }
    }

    It 'uses the Windows PowerShell 5.1 Join-Path contract in helpers and tests' {
        foreach ($source in $sources) {
            $tokens = $null; $errors = $null
            $ast = [System.Management.Automation.Language.Parser]::ParseFile($source.FullName, [ref]$tokens, [ref]$errors)
            @(Get-JoinPathCompatibilityErrors $ast).Count | Should -Be 0 -Because $source.FullName
        }
    }

    It 'detects the extra-child call even when the local pwsh engine accepts it' {
        foreach ($code in @('Join-Path root App R4LInstall Lich5', 'Join-Path root App -AdditionalChildPath R4LInstall,Lich5')) {
            $tokens = $null; $errors = $null
            $ast = [System.Management.Automation.Language.Parser]::ParseInput($code, [ref]$tokens, [ref]$errors)
            @(Get-JoinPathCompatibilityErrors $ast).Count | Should -Be 1
        }
    }

    It 'accepts nested two-argument path construction' {
        $tokens = $null; $errors = $null
        $ast = [System.Management.Automation.Language.Parser]::ParseInput(
            "Join-Path (Join-Path (Join-Path root App) R4LInstall) Lich5", [ref]$tokens, [ref]$errors)
        @(Get-JoinPathCompatibilityErrors $ast).Count | Should -Be 0
    }
}
