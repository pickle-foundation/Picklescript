# tools/selfhost_gate.ps1 - battery gate: the pickle toolchain self-hosts.
#
# Proves the property that makes Rust a seed-only dependency: FIXED POINT, the
# pickle seed (a `build` driver on the pickle runtime) rebuilds cli\build.pkl
# byte-identically to itself. The runtime prelude is embedded in every program
# object, so there is no separate runtime archive to regenerate.
#
# When no seed is present the toolchain is still on the Rust provider; the gate
# reports that and passes (nothing to prove yet) rather than failing. Enable the
# pickle provider by generating the seed once: `tools\selfhost.ps1 -SeedOnly`.
#
# The check is stamp-gated on (seed + driver tree), so a repeat run with
# unchanged inputs is instant.

$ErrorActionPreference = "Continue"
# UNPINNED: the port's shadow frames make the automatic collector safe here.
Remove-Item Env:PKL_NO_AUTO_GC -ErrorAction SilentlyContinue
. (Join-Path $PSScriptRoot "battery_common.ps1")

function Get-Sha([string]$path) {
    if (Test-Path -LiteralPath $path) { (Get-FileHash -LiteralPath $path -Algorithm SHA256).Hash } else { "" }
}

if (-not (Test-SelfHostSeed)) {
    Write-Output "RUN selfhost: no pickle seed (Rust provider active; run tools\selfhost.ps1 -SeedOnly to enable)"
    Write-Output "PASS selfhost: not enabled (Rust provider)"
    exit 0
}

$port = "tools\diff\port"
$work = "tools\diff\selfhost"
$buildDrv = Join-Path $port "pklc_build.exe"

if (-not (Invoke-BuildDriver "cli\build.pkl" $buildDrv)) { Write-Output "FAIL selfhost: pklc_build driver build failed"; exit 1 }

$H = (Get-Sha $selfhostSeed) + "|" + (Get-DriverHash)
$stamp = Join-Path $work "gate.hash"
if ((Test-Path -LiteralPath $stamp) -and ((Get-Content -LiteralPath $stamp -Raw).Trim() -eq $H)) {
    Write-Output "PASS selfhost: fixed-point (cached)"
    exit 0
}

New-Item -ItemType Directory -Path $work -Force | Out-Null
$ok = $true

# Fixed point: the seed compiles the build driver and gets itself back.
$fp = Join-Path $work "gate_build.exe"
$null = Invoke-NativeQuiet $selfhostSeed @("cli\build.pkl", $ignoredRuntimeArg, $fp)
if (ByteEq $fp $selfhostSeed) {
    Write-Output "PASS selfhost fixed-point: seed rebuilds cli\build.pkl byte-identically"
} else {
    $ok = $false
    Write-Output "FAIL selfhost fixed-point: seed != rebuild of cli\build.pkl"
}

if ($ok) { Set-Content -LiteralPath $stamp -Value $H -NoNewline; exit 0 }
exit 1
