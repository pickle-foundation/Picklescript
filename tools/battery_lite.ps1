# tools/battery_lite.ps1 - the behavior lane.
#
# User policy 2026-10-19: byte parity against the Rust oracle is demoted. The
# bar is "the port's JIT + AOT return correct data" - assert suites passing +
# exit codes. This runner keeps exactly that and nothing else: no oracle regen,
# no Rust in the loop, no golden bytes, no CLI/UNCAUGHT parity theater.
#
# Gates:
#   LITE GATE7  - the compiler corpus (compiler\*_test.pkl), exit-only, like
#                 GATE7's ancestral semantics, sharded.
#   LITE GATE10 - the runtime suite (runtime\*_test.pkl), requires exit 0 and
#                 zero failing tests per module, sharded.
#
# Parity gates (IR/IRX/lex/stdout goldens, mains 12/12b, CLI/UNCAUGHT, GATE8)
# stay the occasional audit inside battery_full.ps1. The self-host fixed point
# and driver artifact upkeep are tooling concerns (selfhost.ps1), also outside
# the behavior lane.
#
# Expected warm wall: ~15 min at 6 workers.

param(
    [int]$Workers = -1
)

. (Join-Path $PSScriptRoot "battery_common.ps1")

function Abs([string]$p) { (Resolve-Path -LiteralPath $p).Path }

$script:LiteWorkers = if ($Workers -gt 0) { $Workers } else { 6 }

function Invoke-LiteShards([object[]]$items, [string]$specFile, [string]$resultsBase) {
    $json = @($items | ForEach-Object { $_ | ConvertTo-Json -Compress })
    [IO.File]::WriteAllLines($specFile, [string[]]$json)
    $pids = @()
    for ($i = 0; $i -lt $script:LiteWorkers; $i++) {
        $res = "$resultsBase.r$i"
        Remove-Item $res, "$resultsBase.o$i", "$resultsBase.e$i" -ErrorAction SilentlyContinue
        $args2 = @("-NoProfile", "-ExecutionPolicy", "Bypass", "-File", (Join-Path $PSScriptRoot "battery_shard.ps1"), "-SpecFile", $specFile, "-Results", $res, "-Shard", $i, "-Stride", $script:LiteWorkers)
        $p = Start-Process -FilePath "powershell.exe" -ArgumentList $args2 -WorkingDirectory (Get-Location).Path -PassThru -WindowStyle Hidden -RedirectStandardOutput "$resultsBase.o$i" -RedirectStandardError "$resultsBase.e$i"
        if ($null -ne $p) { $pids += $p.Id }
    }
    if ($pids.Count -gt 0) { Wait-Process -Id $pids -Timeout 12600 -ErrorAction SilentlyContinue }
    $ok = 0; $fail = 0; $lines = @()
    for ($i = 0; $i -lt $script:LiteWorkers; $i++) {
        $res = "$resultsBase.r$i"
        if (Test-Path -LiteralPath $res) {
            foreach ($l in @(Get-Content -LiteralPath $res)) {
                $lines += $l
                if ($l.StartsWith("OK")) { $ok++ } else { $fail++ }
            }
        }
    }
    $r = [pscustomobject]@{ ok = $ok; fail = $fail; lines = $lines }
    $r
}

$sw = [System.Diagnostics.Stopwatch]::StartNew()
$failed = $false

Write-Output "===== BATTERY LITE (behavior lane, workers=$script:LiteWorkers) ====="

# PREP: runtime archive + ported test driver. A fresh checkout has no
# tools\diff\port directory (git does not track empty dirs) - the seed's
# linker needs it to exist before it can write a driver exe.
New-Item -ItemType Directory -Force -Path "tools\diff\port" | Out-Null
$rtlibCand = Get-RtlibArchive
if (-not $rtlibCand) {
    Write-Output "LITE PREP RUNTIME ARCHIVE: MISSING"
    exit 1
}
$pklcTest = "tools\diff\port\pklc_test.exe"
if (-not (Test-Path -LiteralPath $pklcTest)) { Invoke-BuildDriver "cli\test.pkl" $pklcTest | Out-Null }
if (-not (Test-Path -LiteralPath $pklcTest)) {
    Write-Output "LITE PREP TEST DRIVER: BUILD FAILED"
    exit 1
}
$rtlibAbs = Abs $rtlibCand
$pklcTestAbs = Abs $pklcTest
New-Item -ItemType Directory -Force -Path "tools\diff\ptest" | Out-Null
$gdir = Abs "tools\diff\ptest"

# LITE GATE7: the compiler corpus.
$g7items = @()
foreach ($pt in @(Get-ChildItem "compiler\*_test.pkl")) {
    $g7items += [pscustomobject]@{
        gate = "LITE-GATE7"; tag = $pt.BaseName
        kind = "result"; exitOnly = $true
        exe = $pklcTestAbs; argv = @($pt.FullName, $rtlibAbs)
        capture = (Join-Path $gdir ("lite_g7_" + $pt.BaseName + ".txt"))
        budget = 600
    }
}
$g7r = Invoke-LiteShards $g7items (Join-Path $gdir "lite_g7.spec") (Join-Path $gdir "lite_g7res")
Write-Output "LITE GATE7 COMPILER SUITE: PASS=$($g7r.ok) FAIL=$($g7r.fail)"
if ($g7r.fail -ne 0) {
    $failed = $true
    $g7r.lines | Where-Object { $_.StartsWith("FAIL") } | ForEach-Object { Write-Output $_ }
}

# LITE GATE10: the runtime suite, 0 failures required.
$g10items = @()
foreach ($f in @(Get-ChildItem "runtime\*_test.pkl")) {
    $g10items += [pscustomobject]@{
        gate = "LITE-GATE10"; tag = $f.BaseName
        kind = "result"; exitOnly = $false
        exe = $pklcTestAbs; argv = @($f.FullName, $rtlibAbs)
        capture = (Join-Path $gdir ("lite_g10_" + $f.BaseName + ".txt"))
        budget = 180
    }
}
$g10r = Invoke-LiteShards $g10items (Join-Path $gdir "lite_g10.spec") (Join-Path $gdir "lite_g10res")
$g10pass = 0; $g10fail = 0
foreach ($f in @(Get-ChildItem "runtime\*_test.pkl")) {
    $cap = Join-Path $gdir ("lite_g10_" + $f.BaseName + ".txt")
    foreach ($l in (Get-Content -LiteralPath $cap -ErrorAction SilentlyContinue | Select-String "test result:")) {
        if ($l.Line -match "test result: (\d+) passed; (\d+) failed") {
            $g10pass += [int]$matches[1]
            $g10fail += [int]$matches[2]
        }
    }
}
Write-Output "LITE GATE10 RUNTIME SUITE (pass=$g10pass fail=$g10fail): PASS=$($g10r.fail -eq 0 -and $g10fail -eq 0)"
if ($g10r.fail -ne 0 -or $g10fail -ne 0) {
    $failed = $true
    $g10r.lines | Where-Object { $_.StartsWith("FAIL") } | ForEach-Object { Write-Output $_ }
}

$elapsed = $sw.Elapsed.TotalMinutes.ToString('F2')
if ($failed) {
    Write-Output "===== BATTERY LITE COMPLETE ($elapsed min) EXITCODE=1 ====="
    exit 1
}
Write-Output "===== BATTERY LITE COMPLETE ($elapsed min) ====="
