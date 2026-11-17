# The one native gh invocation shared by candidate publication, promotion and
# genesis. Callers decide whether a non-zero exit throws or is classified.

# Runs gh and returns its exit code and combined output, never throwing on a
# native failure. Windows PowerShell 5.1 turns a redirected native stderr line
# into a terminating error under $ErrorActionPreference = 'Stop', which GitHub
# Actions sets, before the exit code can be read; the preference set here is
# function-local, so callers keep their own.
function Invoke-GhNative {
  param([Parameter(Mandatory = $true)][string[]]$Arguments)
  $ErrorActionPreference = 'Continue'
  $output = & gh @Arguments 2>&1
  return [pscustomobject]@{ ExitCode = $LASTEXITCODE; Output = (@($output) -join "`n") }
}
