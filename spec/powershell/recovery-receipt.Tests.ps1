BeforeAll {
  . "$PSScriptRoot/../../recovery-receipt.ps1"
}

Describe 'Recovery receipt and native helper failures' {
  BeforeEach {
    $directory = Join-Path $TestDrive ([Guid]::NewGuid().ToString('N'))
    New-Item -ItemType Directory -Path $directory | Out-Null
    $script:Receipt = Join-Path $directory 'current.json'
    $script:HelperLog = Join-Path $directory 'lich5-missing-gems.log'
    Mock Start-Sleep { throw 'Unexpected polling delay' }
  }

  It 'returns a completed receipt without polling' {
    Set-Content -LiteralPath $script:Receipt -Value '{"success":true}' -Encoding ascii
    (Wait-RecoveryReceipt -ReceiptPath $script:Receipt | ConvertFrom-Json).success | Should -BeTrue
    Should -Invoke Start-Sleep -Times 0 -Exactly
  }

  It 'surfaces a probe error immediately' {
    Set-Content -LiteralPath "$script:Receipt.error" -Value 'probe rejected candidate' -Encoding ascii
    { Wait-RecoveryReceipt -ReceiptPath $script:Receipt } | Should -Throw '*probe rejected candidate*'
    Should -Invoke Start-Sleep -Times 0 -Exactly
  }

  It 'surfaces the actual helper log contents without waiting for the timeout' {
    Set-Content -LiteralPath $script:HelperLog -Value 'Lich5 native gem replacement failure: fixture DLL load failure' -Encoding ascii
    { Wait-RecoveryReceipt -ReceiptPath $script:Receipt } | Should -Throw '*fixture DLL load failure*'
    Should -Invoke Start-Sleep -Times 0 -Exactly
  }

  It 'retains a bounded timeout when neither a receipt nor a failure exists' {
    { Wait-RecoveryReceipt -ReceiptPath $script:Receipt -TimeoutSeconds 0 } |
      Should -Throw 'Native helper/restart did not finish before the deadline.'
    Should -Invoke Start-Sleep -Times 0 -Exactly
  }

  It 'polls until a delayed helper writes the receipt' {
    Mock Start-Sleep {
      Set-Content -LiteralPath $script:Receipt -Value '{"success":true}' -Encoding ascii
    }
    (Wait-RecoveryReceipt -ReceiptPath $script:Receipt | ConvertFrom-Json).success | Should -BeTrue
    Should -Invoke Start-Sleep -Times 1 -Exactly -ParameterFilter { $Seconds -eq 2 }
  }
}
