# Wait for the real recovery helper's receipt or either failure channel.
function Wait-RecoveryReceipt {
  param(
    [Parameter(Mandatory = $true)][string]$ReceiptPath,
    [ValidateRange(0, 3600)][int]$TimeoutSeconds = 360
  )

  $helperLog = Join-Path (Split-Path -Parent $ReceiptPath) 'lich5-missing-gems.log'
  $deadline = [DateTime]::UtcNow.AddSeconds($TimeoutSeconds)
  while (-not (Test-Path -LiteralPath $ReceiptPath)) {
    if (Test-Path -LiteralPath "$ReceiptPath.error") { throw (Get-Content -LiteralPath "$ReceiptPath.error" -Raw) }
    if (Test-Path -LiteralPath $helperLog) { throw (Get-Content -LiteralPath $helperLog -Raw) }
    if ([DateTime]::UtcNow -ge $deadline) { throw 'Native helper/restart did not finish before the deadline.' }
    Start-Sleep -Seconds 2
  }
  Get-Content -LiteralPath $ReceiptPath -Raw
}
