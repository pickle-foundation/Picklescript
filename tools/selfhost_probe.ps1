<#
.SYNOPSIS
Builds one PickleScript target with the ported AOT driver and runs it.

.DESCRIPTION
This is the single-target counterpart to `tools/uncaught_parity.ps1`: it
builds `$Target`, runs the produced native executable, and - when a Rust JIT
oracle happens to exist at `target\debug\pickle-cli.exe` - byte-compares
stdout, stderr, and exit code against `pickle-cli run $Target`.

The build itself is Rust-free: it uses the ported `pklc_build` driver (or the
committed seed) with the committed `tools\diff\rtlib.ar`. On a fresh checkout
with no Rust toolchain the probe still builds and runs the target and reports
PASS on a clean exit; pass `-RequireOracle` to demand a real parity comparison
instead.

.PARAMETER Target
Program to build and run (repo-relative or absolute path).

.PARAMETER RequireOracle
Fail if the Rust JIT oracle is unavailable, instead of reporting self-host-only.
#>
param(
    [Parameter(Mandatory = $true)][string]$Target,
    [switch]$RequireOracle
)

$ErrorActionPreference = "Continue"
$Root = "."
. "$Root\tools\raw_capture.ps1"

$Cli   = "$Root\target\debug\pickle-cli.exe"
$Stem  = [System.IO.Path]::GetFileNameWithoutExtension($Target)
$Probe = Join-Path $env:TEMP "opencode\selfhostprobe\$Stem"
New-Item -ItemType Directory -Force -Path $Probe | Out-Null

# ---- runtime archive: committed rtlib.ar first, legacy combined.lib second ----
$archive = $null
if (Test-Path -LiteralPath "$Root\tools\diff\rtlib.ar") {
    $archive = "$Root\tools\diff\rtlib.ar"
} else {
    $archive = @(
        "$env:TEMP\opencode\x64real\rarc\combined.lib",
        "$env:TEMP\opencode\rarc\combined.lib"
    ) | Where-Object { Test-Path -LiteralPath $_ } | Select-Object -First 1
}
if (-not $archive) {
    Write-Output "NO RUNTIME ARCHIVE: expected $Root\tools\diff\rtlib.ar"
    exit 1
}

# ---- builder: ported pklc_build first, committed seed second ----
$builder = "$Root\tools\diff\port\pklc_build.exe"
if (-not (Test-Path -LiteralPath $builder)) { $builder = "$Root\tools\diff\selfhost\seed.exe" }
if (-not (Test-Path -LiteralPath $builder)) {
    Write-Output "BUILD DRIVER NOT FOUND: expected $Root\tools\diff\port\pklc_build.exe or the committed seed"
    exit 1
}

$exe = Join-Path $Probe "probe.exe"
Remove-Item -LiteralPath $exe -ErrorAction SilentlyContinue
$b = Invoke-RawCapture -Exe $builder -Arguments "`"$Target`" `"$archive`" `"$exe`"" -TimeoutMs 600000
if ($b.ExitCode -ne 0 -or -not (Test-Path -LiteralPath $exe)) {
    Write-Output "BUILD FAIL exit=$($b.ExitCode)"
    Write-Output $b.StdErrText
    exit 1
}

$self = Invoke-RawCapture -Exe $exe -TimeoutMs 600000

# ---- optional Rust JIT oracle -------------------------------------------------
$haveOracle = Test-Path -LiteralPath $Cli
if ($RequireOracle -and -not $haveOracle) {
    Write-Output "ORACLE REQUIRED BUT MISSING: $Cli"
    exit 1
}
if (-not $haveOracle) {
    if ($self.ExitCode -ne 0) {
        Write-Output "PROBE FAIL exit=$($self.ExitCode) (no Rust oracle)"
        Write-Output $self.StdErrText
        exit 1
    }
    Write-Output "PROBE PASS exit=0 stdout=$($self.StdOut.Length)b stderr=$($self.StdErr.Length)b (self only, no Rust oracle)"
    Write-Output $self.StdOutText
    exit 0
}

$orc = Invoke-RawCapture -Exe $Cli -Arguments "run `"$Target`"" -TimeoutMs 600000

$problems = @()
if ($orc.ExitCode -ne $self.ExitCode) {
    $problems += "exit differs: oracle=$($orc.ExitCode) self=$($self.ExitCode)"
}
if ($orc.StdOutHex -ne $self.StdOutHex) {
    $problems += "stdout differs: oracle=$($orc.StdOut.Length)b self=$($self.StdOut.Length)b"
}
if ($orc.StdErrHex -ne $self.StdErrHex) {
    $problems += "stderr differs: oracle=$($orc.StdErr.Length)b self=$($self.StdErr.Length)b"
}

if ($problems.Count -eq 0) {
    Write-Output "PROBE PASS ($($self.StdOut.Length) bytes identical, exit=$($self.ExitCode))"
    Write-Output $self.StdOutText
    exit 0
}

Write-Output "PROBE MISMATCH"
$problems | ForEach-Object { Write-Output "  $_" }
Write-Output "--- oracle stdout ---"; Write-Output $orc.StdOutText
Write-Output "--- self stdout ---"; Write-Output $self.StdOutText
Write-Output "--- oracle stderr ---"; Write-Output $orc.StdErrText
Write-Output "--- self stderr ---"; Write-Output $self.StdErrText
exit 1
