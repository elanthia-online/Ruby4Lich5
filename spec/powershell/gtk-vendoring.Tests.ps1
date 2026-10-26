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

Describe 'Packaged GdkPixbuf cache relocation' {
  BeforeAll {
    $workflow = Get-Content "$PSScriptRoot/../../.github/workflows/ruby4-bundled-gems-suite.yml" -Raw
    # Run the actual transformation after query-loaders has written its output.
    $start = $workflow.IndexOf('            $cacheTemplate = (Get-Content (Join-Path $cacheDst')
    $end = $workflow.IndexOf('-Encoding ascii', $start) + '-Encoding ascii'.Length
    $transform = [scriptblock]::Create($workflow.Substring($start, $end - $start))
  }

  It 'relocates actual forward-slash module records, including SVG, under a path with spaces' {
    $cacheDst = $TestDrive
    $loaderDst = 'D:\build root\loaders'
    @'
# LoaderDir = D:\build root\loaders
"D:/build root/loaders/libpixbufloader-png.dll"
"png" 5 "gdk-pixbuf" "PNG" "LGPL"
"D:/build root/loaders/pixbufloader_svg.dll"
"svg" 6 "gdk-pixbuf" "SVG" "LGPL"
'@ | Set-Content (Join-Path $cacheDst 'loaders.cache.in')
    . $transform
    $template = Get-Content (Join-Path $cacheDst 'loaders.cache.in') -Raw
    $template | Should -Not -Match 'D:[/\\]build root'
    $template | Should -Match '"@@MODULEDIR@@/pixbufloader_svg.dll"'
    $template | Should -Match '"@@MODULEDIR@@/libpixbufloader-png.dll"'
  }

  It 'rejects a cache with no SVG record or an unrelocated module path' -ForEach @(
    @{ Contents = '"D:/build root/loaders/libpixbufloader-png.dll"' }
    @{ Contents = "`"D:/build root/loaders/pixbufloader_svg.dll`"`n`"E:/other/loader.dll`"" }
  ) {
    $cacheDst = $TestDrive
    $loaderDst = 'D:\build root\loaders'
    $Contents | Set-Content (Join-Path $cacheDst 'loaders.cache.in')
    { . $transform } | Should -Throw
  }
}
