# tools/battery_shard.ps1 - parallel shard worker for battery_full.ps1.
#
# Replaces the per-module serial loops inside the heavy gates (GATE7/9/10/11/12/12b
# and the selfhost driver builds) with K independent worker processes. The parent
# builds one spec file where every line is a JSON object describing one
# independent per-module step (an absolute exe + argv + a private capture path +
# the kind of check), then launches K workers with `-Shard i -Stride K`; worker i
# handles spec index i mod K, so a single spec file drives all shards.
#
# Every behavior route goes through battery_common.ps1's existing helpers
# (Invoke-NativeTimeout, ByteEq, Invoke-Artifact) so a sharded gate computes
# exactly what its serialized ancestor computed - same capture semantics, same
# stamp semantics, same golden byte-compare. The environment (PKL_NO_AUTO_GC and
# friends) is inherited from the parent process; the worker does not touch it.
#
# The worker appends one `STATE<TAB>gate<TAB>tag<TAB>detail<TAB>elapsed` line per
# item to its own private results file (-Results). The parent aggregates those
# into the gate summaries.

param(
    [Parameter(Mandatory = $true)][string]$SpecFile,
    [Parameter(Mandatory = $true)][string]$Results,
    [Parameter(Mandatory = $true)][int]$Shard,
    [Parameter(Mandatory = $true)][int]$Stride
)

$ErrorActionPreference = "Continue"
. (Join-Path $PSScriptRoot "battery_common.ps1")

$items = @(Get-Content -LiteralPath $SpecFile | Where-Object { $_.Trim() } | ForEach-Object { $_ | ConvertFrom-Json })
for ($i = 0; $i -lt $items.Count; $i++) {
    if (($i % $Stride) -ne $Shard) { continue }
    $it = $items[$i]
    $sw = [System.Diagnostics.Stopwatch]::StartNew()
    $state = "FAIL"
    $detail = "internal-error"
    try {
        if ($it.fresh) {
            Remove-Item -LiteralPath $it.exe, "$($it.exe).hash" -ErrorAction SilentlyContinue
        }
        switch ($it.kind) {
            "result" {
                $code = Invoke-NativeTimeout $it.exe $it.argv $it.capture $it.budget
                if (-not (Test-Path -LiteralPath $it.capture)) {
                    $detail = "exit=$code NO-RESULT"
                    break
                }
                $passSum = 0; $failSum = 0
                foreach ($l in (Get-Content -LiteralPath $it.capture | Select-String "test result:")) {
                    if ($l.Line -match "test result: (\d+) passed; (\d+) failed") {
                        $passSum += [int]$matches[1]
                        $failSum += [int]$matches[2]
                    }
                }
                # GATE7 counted only the exit code; GATE10 counts the test-result
                # lines. `exitOnly` preserves each gate's ancestral semantics.
                $ok = if ($it.exitOnly) { $code -eq 0 } else { ($code -eq 0) -and ($failSum -eq 0) }
                $detail = "exit=$code passed=$passSum failed=$failSum"
                if (-not $ok) {
                    $line = (Get-Content -LiteralPath $it.capture | Select-String "FAILED" | Select-Object -First 1)
                    if ($line) { $detail = "$detail [$($line.Line.Trim())]" }
                }
                $state = if ($ok) { "OK" } else { "FAIL" }
            }
            "parity" {
                $code = Invoke-NativeTimeout $it.exe $it.argv $it.capture $it.budget
                $rc = 0
                if (Test-Path -LiteralPath $it.goldenExit) { $rc = [int](Get-Content -LiteralPath $it.goldenExit -Raw) }
                $match = $false
                if (Test-Path -LiteralPath $it.goldenOut) { $match = ByteEq $it.capture $it.goldenOut }
                $ok = ($code -eq $rc) -and $match
                $detail = "exit=$rc/$code stdout_match=$match"
                $state = if ($ok) { "OK" } else { "FAIL" }
            }
            "buildparity" {
                if (-not (Invoke-Artifact $it.builder $it.source $it.lib $it.exe)) {
                    $detail = "build failed"
                    break
                }
                if (-not (Test-Path -LiteralPath $it.goldenOut)) {
                    $detail = "golden missing"
                    break
                }
                $code = Invoke-NativeTimeout $it.exe @() $it.capture $it.budget
                $rc = [int](Get-Content -LiteralPath $it.goldenExit -Raw)
                $match = ByteEq $it.capture $it.goldenOut
                $ok = ($code -eq $rc) -and $match
                $detail = "exit=$rc/$code stdout_match=$match"
                $state = if ($ok) { "OK" } else { "FAIL" }
            }
            "runparity" {
                if ((Test-Path -LiteralPath $it.exe) -and (Test-Path -LiteralPath $it.stamp) -and ((Get-Content -LiteralPath $it.stamp -Raw).Trim() -eq $it.want)) {
                    $code = Invoke-NativeTimeout $it.exe @() $it.capture $it.budget
                } else {
                    $code = Invoke-NativeTimeout $it.builder $it.argv $it.capture $it.budget
                    if ($code -eq 0 -and (Test-Path -LiteralPath $it.exe)) {
                        Set-Content -LiteralPath $it.stamp -Value $it.want -NoNewline
                    }
                }
                $rc = [int](Get-Content -LiteralPath $it.goldenExit -Raw)
                $match = ByteEq $it.capture $it.goldenOut
                $ok = ($code -eq $rc) -and $match
                $detail = "exit=$rc/$code stdout_match=$match"
                $state = if ($ok) { "OK" } else { "FAIL" }
            }
            default {
                # "plain": run and require exit 0 ($capture doubles as the run log).
                $code = Invoke-NativeTimeout $it.exe $it.argv $it.capture $it.budget
                $ok = $code -eq 0
                $detail = "exit=$code"
                $state = if ($ok) { "OK" } else { "FAIL" }
            }
        }
    } catch {
        $detail = "worker exception: $($_.Exception.Message)"
    }
    $elapsed = $sw.Elapsed.TotalSeconds.ToString('F1') + "s"
    [IO.File]::AppendAllText($Results, "$state`t$($it.gate)`t$($it.tag)`t$detail`t$elapsed`n")
}
