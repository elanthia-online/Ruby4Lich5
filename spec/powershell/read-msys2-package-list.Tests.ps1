BeforeAll {
  . "$PSScriptRoot/../../read-msys2-package-list.ps1"
  $script:FixtureRoot = "$PSScriptRoot/../fixtures/msys2-package-list"
}

# Shared dual-reader fixture corpus, per the locked
# single-authority correction -- this artifact is the one genuine
# dual-language boundary in the whole registry/package-list design, so
# these fixtures are exercised here and again, byte-for-byte identical, by
# spec/ruby4lich5/msys2_package_list_artifact_spec.rb -- one canonical
# contract, never two independently-trusted implementations.
Describe 'Read-Msys2PackageList' {
  Context 'valid fixtures' {
    It 'accepts a multi-package artifact and returns one package per line' {
      $result = Read-Msys2PackageList -Path (Join-Path $script:FixtureRoot 'valid/multi_package.json')

      $result | Should -Be "base-devel`nmake`nmingw-w64-ucrt-x86_64-gcc`nmingw-w64-ucrt-x86_64-gtk3"
    }

    # The regression case that motivated this fixture existing at all --
    # ConvertFrom-Json returns a real System.Object[] (IsArray=True) even
    # for a single-element JSON array, confirmed live against a real pwsh
    # process, so this must be accepted the same as any other array --
    # not confused with (and not sharing a code path with) a bare JSON
    # scalar string, which packages_not_array.json below proves is still
    # correctly rejected.
    It 'accepts a single-package artifact' {
      $result = Read-Msys2PackageList -Path (Join-Path $script:FixtureRoot 'valid/single_package.json')

      $result | Should -Be 'base-devel'
    }
  }

  Context 'invalid fixtures' {
    $cases = @(
      @{ File = 'unknown_top_level_field.json'; Pattern = 'unknown top-level field' }
      @{ File = 'wrong_schema_version.json'; Pattern = 'unrecognized artifact schema version' }
      @{ File = 'packages_not_array.json'; Pattern = "'packages' must be an Array" }
      @{ File = 'empty_packages.json'; Pattern = 'must be a non-empty Array' }
      @{ File = 'duplicate_entries.json'; Pattern = 'duplicate entries' }
      @{ File = 'unsafe_identifier.json'; Pattern = 'disallowed characters' }
      @{ File = 'top_level_not_object.json'; Pattern = 'must be a JSON object' }
      @{ File = 'malformed_json.json'; Pattern = 'not valid JSON' }
      @{ File = 'byte_order_mark.json'; Pattern = 'byte-order mark' }
      @{ File = 'invalid_utf8.json'; Pattern = 'not valid UTF-8' }
      @{ File = 'mixed_case_identifier.json'; Pattern = 'must be lowercase' }
      @{ File = 'uppercase_identifier.json'; Pattern = 'must be lowercase' }
    )

    It 'rejects <File>' -ForEach $cases {
      { Read-Msys2PackageList -Path (Join-Path $script:FixtureRoot "invalid/$File") } |
        Should -Throw "*$Pattern*"
    }
  }

  Context 'file not found' {
    It 'throws rather than returning an empty or partial result' {
      { Read-Msys2PackageList -Path (Join-Path $script:FixtureRoot 'invalid/does-not-exist.json') } |
        Should -Throw '*not found*'
    }
  }
}
