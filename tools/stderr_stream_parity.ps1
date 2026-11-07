# stderr_stream_parity.ps1 - proves `stderr_stream()` reaches the stderr handle.
#
# Why this is a script and not a `pickle test`: the defect this guards lived in
# the Rust `nostd` build of runtime/src/stream.rs, where `stderr_write` used the
# console bridge that `StreamTarget::Stdout` uses. Both writes then landed on
# stdout. `runtime/stream_test.pkl` cannot see that - it writes through
# `newMemIo`, which never touches the bridge - so the whole 285-test suite stayed
# green while the bug was live. Only a spawned process with separated pipes makes
# the two handles observable.
#
# The fixture writes a distinct token per stream, and the assertions are
# per-channel, so a harness that merely checked "output appeared" would pass even
# with both writes folded onto one handle.
#
# Two sides are compared, because either can regress:
#   ported  - pklc_build output, nostd archive (the path that was broken)
#   native  - the Rust JIT oracle, when a Rust CLI happens to be built
# A mismatch in either direction fails; both must agree channel for channel.
# The native side is optional: on a Rust-free checkout the ported side is the
# only oracle, and it still catches the fold this script exists for.
#
# Usage:
#   powershell -NoProfile -ExecutionPolicy Bypass -File tools\stderr_stream_parity.ps1
#   ... -SelfhostLink    link the fixture with cli\selflink.pkl instead
#
# No Rust toolchain is required: the builder is the ported pklc_build (or the
# committed seed) and the archive is the committed tools\diff\rtlib.ar.

param(
    [switch]$SelfhostLink,
    [int]$TimeoutMs = 120000,
    # Selflink lowers every runtime/*.pkl member, so it needs minutes where a
    # plain archive build needs seconds.
    [int]$SelfLinkTimeoutMs = 1200000
)

$ErrorActionPreference = "Continue"
$Root = "."
. "$Root\tools\raw_capture.ps1"

$fixture = "$Root\tests\stderrstream\stderrstream_main.pkl"
if (-not (Test-Path -LiteralPath $fixture)) {
    Write-Output "STDERR-PARITY: FAIL (missing fixture $fixture)"
    exit 1
}

$work = Join-Path $env:TEMP "opencode\stderrstream"
New-Item -ItemType Directory -Force -Path $work | Out-Null

$expectedOut = "[OUTHANDLE]"
$expectedErr = "[ERRHANDLE]"

# Returns a SINGLE boolean and nothing else. It must not also write to the
# output stream: a PowerShell function that both writes and `return`s yields an
# Object[], and `-not @("msg", $false)` evaluates to False, so an
# `if (-not (Check ...))` caller silently treats every failure as a pass. That
# exact bug shipped in this file once - it reported PASS while the stderr fold
# was live. Diagnostics therefore go to stderr via [Console]::Error and the
# function returns only the boolean.
function Assert-Channels([string]$tag, $r) {
    $ok = $true
    if ($r.ExitCode -ne 0) { [Console]::Error.WriteLine("STDERR-PARITY: $tag exit=$($r.ExitCode), expected 0"); $ok = $false }
    if ($r.StdOutText -ne $expectedOut) { [Console]::Error.WriteLine("STDERR-PARITY: $tag stdout=[$($r.StdOutText)], expected [$expectedOut]"); $ok = $false }
    if ($r.StdErrText -ne $expectedErr) { [Console]::Error.WriteLine("STDERR-PARITY: $tag stderr=[$($r.StdErrText)], expected [$expectedErr]"); $ok = $false }
    return [bool]$ok
}

$fail = 0

# ---- ported AOT build against the nostd archive ----
#
# Builders are chosen in Rust-free order:
#   default       - tools\diff\port\pklc_build.exe (built by tools\selfhost.ps1),
#                   else the committed seed, whose `<src> <archive> <out>`
#                   contract is exactly build.pkl's.
#   -SelfhostLink - tools\diff\port\pklc_selflink.exe, else a seed-built copy of
#                   cli\selflink.pkl. It links against runtime/*.pkl through
#                   compiler\linker.pkl instead of prebuilt archive members.
#
# The runtime library is the committed rtlib.ar when present (the Rust-free
# path), falling back to a legacy combined.lib only on a Rust-enabled checkout.
$portedExe = Join-Path $work "ported.exe"
$seed = "$Root\tools\diff\selfhost\seed.exe"
$builder = $null
$buildArgs = $null
$buildTimeoutMs = $TimeoutMs

if ($SelfhostLink) {
    $builder = "$Root\tools\diff\port\pklc_selflink.exe"
    if (-not (Test-Path -LiteralPath $builder)) {
        if (-not (Test-Path -LiteralPath $seed)) {
            Write-Output "STDERR-PARITY: FAIL (no pklc_selflink.exe and no committed seed)"
            exit 1
        }
        if (-not (Test-Path -LiteralPath "$Root\tools\diff\rtlib.ar")) {
            Write-Output "STDERR-PARITY: SKIP (cannot build selflink driver without rtlib.ar)"
            exit 0
        }
        $builder = Join-Path $work "pklc_selflink.exe"
        $db = Invoke-RawCapture -Exe $seed -Arguments "cli\selflink.pkl `"$Root\tools\diff\rtlib.ar`" `"$builder`"" -TimeoutMs $TimeoutMs
        if ($db.ExitCode -ne 0 -or -not (Test-Path -LiteralPath $builder)) {
            Write-Output "STDERR-PARITY: FAIL (seed could not build cli\selflink.pkl: $($db.StdErrText))"
            exit 1
        }
    }
    $buildArgs = "`"$fixture`" `"$portedExe`""
    $buildTimeoutMs = $SelfLinkTimeoutMs
} else {
    $lib = $null
    if (Test-Path -LiteralPath "$Root\tools\diff\rtlib.ar") {
        $lib = "$Root\tools\diff\rtlib.ar"
    } elseif (Test-Path -LiteralPath "$env:TEMP\opencode\rarc\combined.lib") {
        $lib = "$env:TEMP\opencode\rarc\combined.lib"
    }
    if (-not $lib) {
        Write-Output "STDERR-PARITY: SKIP (no rtlib.ar and no combined.lib)"
        exit 0
    }
    $builder = "$Root\tools\diff\port\pklc_build.exe"
    if (-not (Test-Path -LiteralPath $builder)) { $builder = $seed }
    if (-not (Test-Path -LiteralPath $builder)) {
        Write-Output "STDERR-PARITY: FAIL (no pklc_build.exe and no committed seed)"
        exit 1
    }
    $buildArgs = "`"$fixture`" `"$lib`" `"$portedExe`""
}

$b = Invoke-RawCapture -Exe $builder -Arguments $buildArgs -TimeoutMs $buildTimeoutMs
if ($b.ExitCode -ne 0 -or -not (Test-Path -LiteralPath $portedExe)) {
    Write-Output "STDERR-PARITY: FAIL (ported build failed: $($b.StdErrText))"
    exit 1
}
if (-not (Assert-Channels "ported" (Invoke-RawCapture -Exe $portedExe -TimeoutMs $TimeoutMs))) { $fail++ }

# ---- native oracle (optional; only on a Rust-enabled checkout) ----
$nativeExe = Join-Path $work "native.exe"
$nativeRan = $false
$cli = "$Root\target\debug\pickle-cli.exe"
if (Test-Path -LiteralPath $cli) {
    $n = Invoke-RawCapture -Exe $cli -Arguments "build `"$fixture`" -o `"$nativeExe`"" -TimeoutMs $TimeoutMs
    if ($n.ExitCode -eq 0 -and (Test-Path -LiteralPath $nativeExe)) {
        $nativeRan = $true
        if (-not (Assert-Channels "native" (Invoke-RawCapture -Exe $nativeExe -TimeoutMs $TimeoutMs))) { $fail++ }
    } else {
        Write-Output "STDERR-PARITY: native build unavailable, skipping oracle side"
    }
} else {
    Write-Output "STDERR-PARITY: native oracle unavailable, skipping that side"
}

if ($fail -eq 0) {
    $sides = if ($nativeRan) { "ported + native" } else { "ported" }
    Write-Output "STDERR-PARITY: PASS ($sides keeps stdout/stderr separate)"
    exit 0
}
Write-Output "STDERR-PARITY: FAIL ($fail side(s) folded a stream)"
exit 1
