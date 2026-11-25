# Run a probe executable headless with a timeout, capturing exit code and output.
# Usage: .\tools\runprobe.ps1 -Exe <path> [-TimeoutSec 10] [-Args a,b,c]
param(
    [Parameter(Mandatory = $true)][string]$Exe,
    [int]$TimeoutSec = 10,
    [string[]]$Args = @()
)
$psi = New-Object System.Diagnostics.ProcessStartInfo
$psi.FileName = (Resolve-Path $Exe).Path
foreach ($a in $Args) { $psi.Arguments += ('"' + $a + '" ') }
$psi.UseShellExecute = $false
$psi.RedirectStandardOutput = $true
$psi.RedirectStandardError = $true
$psi.CreateNoWindow = $true
$proc = [System.Diagnostics.Process]::Start($psi)
$exited = $proc.WaitForExit($TimeoutSec * 1000)
if (-not $exited) { $proc.Kill(); $proc.WaitForExit(5000) }
$out = $proc.StandardOutput.ReadToEnd()
$err = $proc.StandardError.ReadToEnd()
$code = if ($exited) { $proc.ExitCode } else { "TIMEOUT" }
Write-Output "exit=$code"
Write-Output "--- stdout ---"
Write-Output $out
if ($err.Length -gt 0) {
    Write-Output "--- stderr ---"
    Write-Output $err
}
