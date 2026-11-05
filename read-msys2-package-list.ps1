# PowerShell reader for the small package-list artifact F1's Ruby CLI
# (bin/derive_dynamic_msys2_packages.rb) emits -- the locked
# single-authority correction: this file only reads
# and transports an already-computed result. It never opens
# config/curated-gems.json, never re-derives a package list, and never
# appends the static bootstrap set itself -- Msys2Bootstrap's union with
# the registry-derived packages already happened inside the Ruby CLI
# before this artifact was written.
#
# Applies the identical strict checks Ruby4Lich5::Msys2PackageListArtifact
# (lib/ruby4lich5/msys2_package_list_artifact.rb) enforces on its own
# side of this hand-off -- unknown top-level fields, wrong schema version,
# a non-Array 'packages', an empty list, duplicate entries, unsafe package
# identifiers, a byte-order mark, or any non-UTF-8 byte sequence are all
# hard rejects here too, not just described in prose. Both readers are
# exercised against the identical shared fixture corpus (see
# spec/fixtures/msys2-package-list/).
#
# Read-Msys2PackageList is a plain function, not top-level script code --
# same shape as fetch-lich.ps1's own Invoke-LichFetch and
# verify-archive-download.ps1's own Invoke-VerifiedDownload, for the same
# reason: spec/powershell/read-msys2-package-list.Tests.ps1 dot-sources
# this file and calls the function directly against real fixture files,
# real behavioral coverage instead of only a syntax check. It throws on
# failure rather than calling exit (exit inside a function would kill the
# whole test process on the first failure path); the bottom guard converts
# that into a real exit-code/stdout contract, but only when actually run
# as a script -- $MyInvocation.InvocationName is '.' when dot-sourced, so
# the guard is a no-op during tests.

param(
  # Not Mandatory here -- the spec file dot-sources this with no args to
  # reach Read-Msys2PackageList directly, and a Mandatory top-level param
  # blocks on a missing-value prompt in that non-interactive context.
  # Required-ness is enforced below, only on the direct-execution path.
  [string]$Path
)

function Read-Msys2PackageList {
  param(
    [Parameter(Mandatory = $true)][string]$Path
  )

  if (!(Test-Path -LiteralPath $Path -PathType Leaf)) {
    throw "artifact not found at '$Path'."
  }

  $bytes = [System.IO.File]::ReadAllBytes($Path)

  # Same three raw bytes Ruby's own BOM constant is built from (see
  # msys2_package_list_artifact.rb) -- checked here as raw byte values,
  # never as a string literal that a tool or linter could reinterpret.
  if ($bytes.Length -ge 3 -and $bytes[0] -eq 0xEF -and $bytes[1] -eq 0xBB -and $bytes[2] -eq 0xBF) {
    throw "artifact carries a byte-order mark, expected plain UTF-8."
  }

  # throwOnInvalidBytes: $true -- a plain [System.Text.Encoding]::UTF8
  # silently replaces invalid sequences with U+FFFD instead of rejecting
  # them; this is the one place the encoding contract actually gets
  # checked, matching Ruby's own String#valid_encoding? check.
  $strictUtf8 = [System.Text.UTF8Encoding]::new($false, $true)
  try {
    $text = $strictUtf8.GetString($bytes)
  } catch {
    throw "artifact is not valid UTF-8: $($_.Exception.Message)"
  }

  try {
    $data = $text | ConvertFrom-Json -ErrorAction Stop
  } catch {
    throw "artifact is not valid JSON: $($_.Exception.Message)"
  }

  if ($data -isnot [System.Management.Automation.PSCustomObject]) {
    $gotType = if ($null -eq $data) { 'null' } else { $data.GetType().Name }
    throw "artifact must be a JSON object, got $gotType."
  }

  $allowedKeys = @('schema', 'packages')
  $unknownKeys = @($data.PSObject.Properties.Name | Where-Object { $allowedKeys -notcontains $_ })
  if ($unknownKeys.Count -gt 0) {
    throw "artifact has unknown top-level field(s): $($unknownKeys -join ', ')."
  }

  if ($data.schema -ne 1) {
    throw "unrecognized artifact schema version: $($data.schema)."
  }

  # Checked via .GetType().IsArray, not '-is [array]' or an @()-wrapped
  # scalar check -- confirmed live: ConvertFrom-Json actually does return
  # a real System.Object[] (IsArray=True) for a JSON array down to a
  # single element, so no PowerShell-side unwrapping ambiguity exists
  # here to begin with. A bare JSON scalar (System.String, IsArray=False)
  # must still be a hard reject, not silently @()-wrapped into a
  # one-element package list -- an earlier draft's @($data.packages) did
  # exactly that, live-verified to wrongly accept
  # {"packages": "base-devel"} as if it were ["base-devel"].
  $packagesRaw = $data.packages
  if ($null -eq $packagesRaw -or -not $packagesRaw.GetType().IsArray) {
    $gotType = if ($null -eq $packagesRaw) { 'null' } else { $packagesRaw.GetType().Name }
    throw "artifact 'packages' must be an Array, got $gotType."
  }
  $packages = @($packagesRaw)
  if ($packages | Where-Object { $_ -isnot [string] }) {
    throw "artifact 'packages' must be an Array of Strings."
  }

  if ($packages.Count -eq 0) {
    throw "packages must be a non-empty Array."
  }

  # A manual [StringComparer]::Ordinal HashSet, not Group-Object -- real
  # dual-reader contract gap, found in review: Group-Object's *default*
  # comparer is case-insensitive, so ["foo", "FOO"] was reported as one
  # duplicate group here while Ruby's own Array#tally
  # (Msys2PackageListArtifact#validate!, exact String equality) accepted
  # the identical input as two distinct, valid entries. Reproduced live on
  # both sides before this fix.
  #
  # An earlier fix used `Group-Object -CaseSensitive` -- verified directly
  # against Microsoft's own Windows PowerShell 5.1 Group-Object reference
  # that -CaseSensitive genuinely is a documented, supported parameter
  # there (the only version-gapped behavior on record is -CaseSensitive
  # combined with -AsHashTable specifically, a different parameter this
  # code never uses) -- but this workflow's real target
  # (shell: powershell, Windows PowerShell 5.1) can't actually be
  # exercised from this development environment (only pwsh 7.6.3 is
  # available here), so resting a P1 correctness guarantee on cmdlet
  # documentation alone, for a real dispatch-blocking check, wasn't good
  # enough. [System.Collections.Generic.HashSet[string]] and
  # [StringComparer]::Ordinal are base class library types, not a cmdlet
  # parameter -- their behavior cannot differ across PowerShell editions
  # the way a cmdlet's own parameter set can, so this removes the version
  # question entirely rather than resolving it by citation.
  $seen = [System.Collections.Generic.HashSet[string]]::new([StringComparer]::Ordinal)
  $duplicates = [System.Collections.Generic.List[string]]::new()
  foreach ($pkg in $packages) {
    if (-not $seen.Add($pkg)) {
      $duplicates.Add($pkg)
    }
  }
  if ($duplicates.Count -gt 0) {
    throw "packages has duplicate entries: $($duplicates -join ', ')."
  }

  # Same allowlist pattern as Ruby4Lich5::SafeToken (lib/ruby4lich5/safe_token.rb)
  # -- a leading negative lookahead rejects a bare '.' or '..' entry, every
  # other character restricted to [a-zA-Z0-9._-], no '/' permitted at all.
  $safePattern = '^(?!\.{1,2}$)[a-zA-Z0-9._-]+$'
  foreach ($pkg in $packages) {
    if ([string]::IsNullOrWhiteSpace($pkg) -or ($pkg -notmatch $safePattern)) {
      throw "package name contains disallowed characters: '$pkg'."
    }
    # Real MSYS2 package names are lowercase-only by upstream convention
    # (every existing package this project references already is) --
    # enforced here on both readers (Msys2PackageListArtifact#lowercase!
    # is the Ruby side), matching, not just tolerating, that real-world
    # invariant, and closing the Group-Object case-sensitivity gap above
    # for good rather than relying on -CaseSensitive alone.
    if ($pkg -cne $pkg.ToLowerInvariant()) {
      throw "package name must be lowercase: '$pkg'."
    }
  }

  # The exact multiline string msys2/setup-msys2's own `with.install:` needs
  # -- one package per line. The static bootstrap set is already unioned in
  # by the Ruby CLI; this never appends anything of its own.
  return ($packages -join "`n")
}

if ($MyInvocation.InvocationName -ne '.') {
  $ErrorActionPreference = 'Stop'
  try {
    if ([string]::IsNullOrWhiteSpace($Path)) {
      throw "Path is required. Usage: read-msys2-package-list.ps1 -Path <path>"
    }

    $installList = Read-Msys2PackageList -Path $Path
    Write-Output $installList
    exit 0
  } catch {
    Write-Error "Reading MSYS2 package list failed: $($_.Exception.Message)"
    exit 1
  }
}
