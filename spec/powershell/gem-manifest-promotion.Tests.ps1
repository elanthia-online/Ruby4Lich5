Describe 'Manifest promotion with checked restoration' {
  BeforeAll { . "$PSScriptRoot/../../gem-manifest-promotion.ps1" }

  BeforeEach {
    $script:CandidatePath = Join-Path $TestDrive 'candidate/R4L5-gem-manifest.json'
    $script:BackupPath = Join-Path $TestDrive 'backup/R4L5-gem-manifest.json'
    New-Item -ItemType Directory -Path (Split-Path $script:CandidatePath), (Split-Path $script:BackupPath) -Force | Out-Null
    [IO.File]::WriteAllText($script:CandidatePath, 'candidate bytes')
    [IO.File]::WriteAllText($script:BackupPath, 'original bytes')
    $script:NewDigest = 'sha256:' + (Get-FileHash $script:CandidatePath -Algorithm SHA256).Hash.ToLowerInvariant()
    $script:OldDigest = 'sha256:' + (Get-FileHash $script:BackupPath -Algorithm SHA256).Hash.ToLowerInvariant()
    $script:RemoteDigest = $script:OldDigest
    $script:PromotionArgs = @{
      Repository = 'elanthia-online/Ruby4Lich5'; CandidatePath = $script:CandidatePath; BackupPath = $script:BackupPath
      ExpectedCandidateDigest = $script:NewDigest; ExpectedLiveDigest = $script:OldDigest
      ReadbackPath = (Join-Path $TestDrive 'readback.json')
    }
    Mock Start-Sleep {}
    Mock Invoke-PromotionGh {
      if ($Arguments[1] -eq 'view') {
        $assets = if ($script:RemoteDigest) { @(@{ name = 'R4L5-gem-manifest.json'; digest = $script:RemoteDigest }) } else { @() }
        return (@{ assets = $assets } | ConvertTo-Json -Depth 5)
      }
      if ($Arguments[1] -ne 'upload') { throw 'unexpected release operation' }
      $script:RemoteDigest = if ($Arguments[3] -eq $script:CandidatePath) { $script:NewDigest } else { $script:OldDigest }
      return ''
    }
    Mock Invoke-VerifiedDownload {
      $text = if ($ExpectedDigest -eq $script:NewDigest) { 'candidate bytes' } else { 'original bytes' }
      [IO.File]::WriteAllText($DestinationPath, $text)
      return $DestinationPath
    }
  }

  It 'changes only the manifest and verifies the exact public consumer URL' {
    Invoke-GemManifestPromotion @script:PromotionArgs
    Get-Content $script:PromotionArgs.ReadbackPath -Raw | Should -Be 'candidate bytes'
    Should -Invoke Invoke-PromotionGh -Times 1 -Exactly -ParameterFilter {
      $Arguments[1] -eq 'upload' -and $Arguments[2] -eq 'R4L5-gem-bundle-x64-mingw-ucrt' -and $Arguments[3] -eq $script:CandidatePath
    }
    Should -Invoke Invoke-VerifiedDownload -Times 1 -Exactly -ParameterFilter {
      $Url -eq 'https://github.com/elanthia-online/Ruby4Lich5/releases/download/R4L5-gem-bundle-x64-mingw-ucrt/R4L5-gem-manifest.json' -and $ExpectedDigest -eq $script:NewDigest
    }
  }

  It 'rejects a changed predecessor before any upload' {
    $script:RemoteDigest = 'sha256:' + ('c' * 64)
    { Invoke-GemManifestPromotion @script:PromotionArgs } | Should -Throw '*predecessor changed*'
    Should -Invoke Invoke-PromotionGh -Times 0 -Exactly -ParameterFilter { $Arguments[1] -eq 'upload' }
  }

  It 'rejects changed local candidate or rollback bytes before any network access' {
    Add-Content $script:BackupPath 'unexpected edit'
    { Invoke-GemManifestPromotion @script:PromotionArgs } | Should -Throw '*rollback bytes changed*'
    Should -Invoke Invoke-PromotionGh -Times 0 -Exactly
  }

  It 'restores the checked predecessor if delete-then-upload fails with the asset missing' {
    Mock Invoke-PromotionGh {
      if ($Arguments[3] -eq $script:CandidatePath) { $script:RemoteDigest = $null; throw 'upload failed after deletion' }
      $script:RemoteDigest = $script:OldDigest
      return ''
    } -ParameterFilter { $Arguments[1] -eq 'upload' }
    { Invoke-GemManifestPromotion @script:PromotionArgs } | Should -Throw '*previous manifest was restored or retained and verified*'
    $script:RemoteDigest | Should -Be $script:OldDigest
    Should -Invoke Invoke-PromotionGh -Times 1 -Exactly -ParameterFilter { $Arguments[1] -eq 'upload' -and $Arguments[3] -eq $script:BackupPath }
  }

  It 'restores and re-verifies the predecessor after a failed consumer readback' {
    Mock Invoke-VerifiedDownload { throw 'consumer readback failed' } -ParameterFilter { $ExpectedDigest -eq $script:NewDigest }
    { Invoke-GemManifestPromotion @script:PromotionArgs } | Should -Throw '*previous manifest was restored or retained and verified*'
    $script:RemoteDigest | Should -Be $script:OldDigest
    Should -Invoke Invoke-VerifiedDownload -Times 1 -Exactly -ParameterFilter { $ExpectedDigest -eq $script:OldDigest }
  }

  It 'retains rollback bytes and reports unconfirmed restoration if restoring fails' {
    Mock Invoke-PromotionGh {
      if ($Arguments[3] -eq $script:CandidatePath) { $script:RemoteDigest = $null }
      throw 'upload unavailable'
    } -ParameterFilter { $Arguments[1] -eq 'upload' }
    { Invoke-GemManifestPromotion @script:PromotionArgs } | Should -Throw '*restoration is unconfirmed*'
    Get-Content $script:BackupPath -Raw | Should -Be 'original bytes'
  }

  It 'never overwrites an unknown concurrent manifest during restoration' {
    Mock Invoke-PromotionGh { $script:RemoteDigest = 'sha256:' + ('d' * 64); return '' } -ParameterFilter { $Arguments[1] -eq 'upload' }
    { Invoke-GemManifestPromotion @script:PromotionArgs } | Should -Throw '*Concurrent manifest detected*'
    Should -Invoke Invoke-PromotionGh -Times 0 -Exactly -ParameterFilter { $Arguments[1] -eq 'upload' -and $Arguments[3] -eq $script:BackupPath }
  }
}
