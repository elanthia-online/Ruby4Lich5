Describe 'GTK vendoring from a full bundle plan' {
  It 'keeps GTK roots and leaves ox/curses for the later repack step' {
    $workflow = Get-Content "$PSScriptRoot/../../.github/workflows/ruby4-bundled-gems-suite.yml" -Raw
    # Execute the actual workflow selection, not a duplicate of its predicate.
    $stack = [regex]::Match($workflow, '(?m)^ {10}\$gtk3StackGems = @\([^\r\n]+\)')
    $selection = [regex]::Match($workflow, '(?m)^ {10}\$vendoringRoots = @\([\s\S]*?^ {10}\)')
    $stack.Success | Should -BeTrue
    $selection.Success | Should -BeTrue
    $plan = @(
      @{ name = 'glib2'; vendoring_role = 'vendoring_root' }
      @{ name = 'cairo'; vendoring_role = 'vendoring_root' }
      @{ name = 'ox'; vendoring_role = 'vendoring_root' }
      @{ name = 'curses'; vendoring_role = 'vendoring_root' }
      @{ name = 'gtk3'; vendoring_role = 'vendoring_dependent' }
    )
    $planPath = Join-Path $TestDrive 'mixed-plan.json'
    $plan | ConvertTo-Json | Set-Content $planPath
    $previousPlan = $env:NATIVE_GEMS_PLAN
    try {
      $env:NATIVE_GEMS_PLAN = $planPath
      . ([scriptblock]::Create($stack.Value + "`n" + $selection.Value))
      ($vendoringRoots -join ',') | Should -Be 'glib2,cairo'
    } finally {
      $env:NATIVE_GEMS_PLAN = $previousPlan
    }
  }
}
