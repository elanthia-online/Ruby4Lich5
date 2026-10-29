# Preserve the resolver's exit contract: 1 may be transient; 2 is terminal.
function Invoke-BundleResolution {
  param(
    [Parameter(Mandatory = $true)][string]$RubyExecutable,
    [Parameter(Mandatory = $true)][string[]]$Arguments
  )
  for ($attempt = 1; $attempt -le 2; $attempt++) {
    & $RubyExecutable @Arguments | Out-Host
    $code = $LASTEXITCODE
    if ($code -ne 1 -or $attempt -eq 2) { return $code }
    Start-Sleep -Seconds 2
  }
}
