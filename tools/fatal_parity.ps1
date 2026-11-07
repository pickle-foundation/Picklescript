<#
.SYNOPSIS
Checks the fatal `pickle_panic_*` / `fatalMsg` paths on a self-host linked
executable, byte-comparing against the JIT oracle when one is available.

.DESCRIPTION
`tools/selfhost_probe.ps1` requires a program to succeed; `tools/
uncaught_parity.ps1` handles uncaught `throw`. This harness is the third
shape: a program that is SUPPOSED to die with `fatal: pickle: ...` on stderr
and exit 1.

Each pair is (self, oracle):

  self   tests/tmp/<stem>.pkl        - imports the ported module, so the
                                        self-host linked image resolves the
                                        panic/cast symbol to the ported body
  oracle tests/tmp/<stem>_oracle.pkl - no imports, so the JIT runs the
                                        native body (sl_castpanic_iface and
                                        sl_ifacemiss are the exceptions: their
                                        by-name call needs the import, so
                                        those twins are byte-identical copies
                                        and compare ported-in-JIT against
                                        ported-in-linked-image)

The self side is Rust-free: it links `tests/tmp/<stem>.pkl` against the
committed `tools\diff\rtlib.ar` with the ported build driver (pklc_build, or
the committed seed). It must exit 1 and its stderr must start with the pair's
marker, so a wrong panic body cannot pass.

The oracle side is optional and only runs when a Rust CLI exists at
`target\debug\pickle-cli.exe`. Then all three channels - stdout, stderr, exit
code - are captured byte for byte and must agree as well.

.PARAMETER Filter
Only run pairs whose stem contains this substring.
#>
param(
    [string]$Filter = ""
)

$ErrorActionPreference = "Continue"
$Root = "."
$Cli  = "$Root\target\debug\pickle-cli.exe"
$Temp = Join-Path $Env:TEMP "opencode\fatalparity"
$Work = Join-Path $Temp "work"

New-Item -ItemType Directory -Force -Path $Work | Out-Null

function Invoke-Captured {
    param([string]$Exe, [string[]]$ExeArgs, [string]$WorkingDir, [string]$Tag)
    $out = Join-Path $Work "$Tag.out"
    $err = Join-Path $Work "$Tag.err"
    $sp = @{
        FilePath               = $Exe
        NoNewWindow            = $true
        Wait                   = $true
        PassThru               = $true
        WorkingDirectory       = $WorkingDir
        RedirectStandardOutput = $out
        RedirectStandardError  = $err
    }
    if ($ExeArgs -and $ExeArgs.Count -gt 0) { $sp.ArgumentList = $ExeArgs }
    $p = Start-Process @sp
    return [pscustomobject]@{
        Exit   = $p.ExitCode
        StdOut = [System.IO.File]::ReadAllBytes($out)
        StdErr = [System.IO.File]::ReadAllBytes($err)
    }
}

function Same-Bytes([byte[]]$a, [byte[]]$b) {
    if ($a.Length -ne $b.Length) { return $false }
    for ($i = 0; $i -lt $a.Length; $i++) { if ($a[$i] -ne $b[$i]) { return $false } }
    return $true
}

function StartsWith([byte[]]$b, [byte[]]$prefix) {
    if ($b.Length -lt $prefix.Length) { return $false }
    for ($i = 0; $i -lt $prefix.Length; $i++) { if ($b[$i] -ne $prefix[$i]) { return $false } }
    return $true
}

function Show([byte[]]$b) {
    if ($b.Length -eq 0) { return "<empty>" }
    return (($b | ForEach-Object { if ($_ -ge 32 -and $_ -lt 127) { [char]$_ } else { "<0x{0:X2}>" -f $_ } }) -join '')
}

# ---- Rust-free builder + archive selection -------------------------------------
$lib = $null
if (Test-Path -LiteralPath "$Root\tools\diff\rtlib.ar") {
    $lib = "$Root\tools\diff\rtlib.ar"
} else {
    $lib = @("$Env:TEMP\opencode\x64real\rarc\combined.lib", "$Env:TEMP\opencode\rarc\combined.lib") |
        Where-Object { Test-Path $_ } | Select-Object -First 1
}
if (-not $lib) {
    Write-Output "SKIP: no tools\diff\rtlib.ar and no combined.lib"
    exit 0
}

$builder = "$Root\tools\diff\port\pklc_build.exe"
if (-not (Test-Path -LiteralPath $builder)) { $builder = "$Root\tools\diff\selfhost\seed.exe" }
if (-not (Test-Path -LiteralPath $builder)) {
    Write-Output "BUILD DRIVER NOT FOUND: $builder (run tools\selfhost.ps1, or use the committed seed)"
    exit 1
}

$HaveOracle = Test-Path -LiteralPath $Cli
if (-not $HaveOracle) {
    Write-Output "FATAL PARITY: no Rust oracle at $Cli - checking self-hosted markers only"
}

# stem -> expected stderr marker (byte prefix, trailing newline excluded)
$pairs = @(
    @{ stem = "sl_panic";          marker = "fatal: pickle: match is not exhaustive" }
    @{ stem = "sl_castpanic";      marker = "fatal: pickle: invalid class cast" }
    @{ stem = "sl_castpanic_iface"; marker = "fatal: pickle: invalid interface cast" }
    @{ stem = "sl_noneunwrap";     marker = "fatal: pickle: unwrapped none value" }
    @{ stem = "sl_aritydiff";      marker = "fatal: pickle: spread list does not match the expected number of arguments" }
    @{ stem = "sl_ifacemiss";      marker = "fatal: pickle: interface method dispatch found no implementation" }
    @{ stem = "sl_sync_kindmutex";   marker = "fatal: pickle: handle 1 is not a mutex" }
    @{ stem = "sl_sync_kindcond";    marker = "fatal: pickle: handle 1 is not a cond" }
    @{ stem = "sl_sync_kindsem";     marker = "fatal: pickle: handle 1 is not a semaphore" }
    @{ stem = "sl_sync_kindatomic";  marker = "fatal: pickle: handle 1 is not an atomic" }
    @{ stem = "sl_sync_kindchannel"; marker = "fatal: pickle: handle 1 is not a channel" }
    @{ stem = "sl_sync_sendclosed";  marker = "fatal: pickle: send on closed channel" }
    @{ stem = "sl_sync_trysendclosed"; marker = "fatal: pickle: send on closed channel" }
    @{ stem = "sl_sync_recvclosed";  marker = "fatal: pickle: receive on a closed, empty channel" }
    @{ stem = "sl_sync_capzero";     marker = "fatal: pickle: channel capacity must be at least 1, got 0" }
    @{ stem = "sl_sync_capneg";      marker = "fatal: pickle: channel capacity must be at least 1, got -3" }
    @{ stem = "sl_once_kindonce";    marker = "fatal: pickle: handle 1 is not a once" }
)
$pairs = $pairs | Where-Object { $_.stem.Contains($Filter) }

if (-not $pairs) { Write-Output "NO PAIRS MATCHED FILTER '$Filter'"; exit 1 }

$pass = 0; $fail = 0; $oraclePairs = 0

foreach ($pr in $pairs) {
    $stem = $pr.stem
    $selfSrc  = Join-Path $Root "tests\tmp\$stem.pkl"
    $oracleSrc = Join-Path $Root "tests\tmp\${stem}_oracle.pkl"
    if (-not (Test-Path $selfSrc))  { Write-Output "FAIL $stem : missing $selfSrc"; $fail++; continue }
    if ($HaveOracle -and -not (Test-Path $oracleSrc)) {
        Write-Output "FAIL $stem : missing $oracleSrc"
        $fail++
        continue
    }

    # ---- self: ported lower + link against the ported runtime archive ----
    $probe = Join-Path $Work $stem
    New-Item -ItemType Directory -Force -Path $probe | Out-Null
    $exe = Join-Path $probe "probe.exe"
    Remove-Item -LiteralPath $exe -ErrorAction SilentlyContinue
    $build = Invoke-Captured -Exe $builder -ExeArgs @($selfSrc, $lib, $exe) -WorkingDir $Root -Tag "build_$stem"
    if ($build.Exit -ne 0 -or -not (Test-Path $exe)) {
        Write-Output "FAIL $stem : self-host build failed (exit $($build.Exit))"
        Write-Output (Show $build.StdErr)
        $fail++
        continue
    }
    $self = Invoke-Captured -Exe $exe -ExeArgs @() -WorkingDir $Root -Tag "self_$stem"

    $problems = @()
    if ($self.Exit -ne 1) { $problems += "self should exit 1, got $($self.Exit)" }
    $marker = [System.Text.Encoding]::UTF8.GetBytes($pr.marker)
    if (-not (StartsWith $self.StdErr $marker)) { $problems += "self stderr lacks marker: $(Show $self.StdErr)" }

    # ---- oracle: JIT, native panic bodies (Rust-enabled checkouts only) ----
    $orc = $null
    if ($HaveOracle) {
        $orc = Invoke-Captured -Exe $Cli -ExeArgs @("run", $oracleSrc) -WorkingDir $Root -Tag "orc_$stem"
        $oraclePairs++
        if ($orc.Exit -ne 1) { $problems += "oracle should exit 1, got $($orc.Exit)" }
        if (-not (StartsWith $orc.StdErr $marker)) { $problems += "oracle stderr lacks marker: $(Show $orc.StdErr)" }
        if (-not (Same-Bytes $orc.StdOut $self.StdOut)) {
            $problems += "stdout differs:`n      oracle: $(Show $orc.StdOut)`n      self  : $(Show $self.StdOut)"
        }
        if (-not (Same-Bytes $orc.StdErr $self.StdErr)) {
            $problems += "stderr differs:`n      oracle: $(Show $orc.StdErr)`n      self  : $(Show $self.StdErr)"
        }
    }

    if ($problems.Count -eq 0) {
        $via = if ($orc) { "oracle+self" } else { "self only" }
        Write-Output ("PASS {0,-24} exit=1 stdout={1}b stderr={2}b ({3})" -f $stem, $self.StdOut.Length, $self.StdErr.Length, $via)
        $pass++
    } else {
        Write-Output "FAIL $stem"
        $problems | ForEach-Object { Write-Output "      $_" }
        $fail++
    }
}

Write-Output ""
$how = if ($oraclePairs -gt 0) { "selfhost link + $oraclePairs Rust oracle pair(s)" } else { "selfhost link, no Rust oracle" }
Write-Output "FATAL PARITY: $pass passed, $fail failed ($how)"
if ($fail -gt 0) { exit 1 }
exit 0
