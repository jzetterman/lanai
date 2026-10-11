# proof-scale-flood.ps1: live-scale phase 0 proof (7). Writes to the scale port
# as fast as it can, to show that guest writes never slow the host feed, the
# panel or the bar. Run it in an elevated PowerShell from the shared folder:
#   powershell -ExecutionPolicy Bypass -File <share>\lanai-proof\proof-scale-flood.ps1
# -Minutes N sets the run time (default 10). It logs bytes written every 10 s
# to flood.log next to the script. If the open fails, the scale task holds the
# port; the log says so.
param([int]$Minutes = 10)

$ErrorActionPreference = 'Stop'
$port = '\\.\Global\io.lanai.scale.0'
$log = Join-Path $PSScriptRoot 'flood.log'

function Say([string]$text) {
  $line = "$([DateTimeOffset]::UtcNow.ToUnixTimeMilliseconds()) $text"
  Write-Host $line
  Add-Content -Path $log -Value $line
}

Add-Type -TypeDefinition @'
using System;
using System.Runtime.InteropServices;
using Microsoft.Win32.SafeHandles;
public static class FloodPort {
  [DllImport("kernel32.dll", SetLastError = true, CharSet = CharSet.Unicode)]
  public static extern SafeFileHandle CreateFile(string name, uint access, uint share,
    IntPtr security, uint disposition, uint flags, IntPtr template);
}
'@

Say "start minutes=$Minutes"
$GENERIC_WRITE = [uint32]1073741824
$handle = [FloodPort]::CreateFile($port, $GENERIC_WRITE, 0, [IntPtr]::Zero, 3, 0, [IntPtr]::Zero)
if ($handle.IsInvalid) {
  $code = [Runtime.InteropServices.Marshal]::GetLastWin32Error()
  Say "open-failed win32=$code ($((New-Object ComponentModel.Win32Exception $code).Message))"
  exit 1
}
Say "open-ok"
$stream = New-Object IO.FileStream($handle, [IO.FileAccess]::Write, 4096, $false)
$buf = [Text.Encoding]::ASCII.GetBytes(('flood ' * 682) + "`n")
$end = (Get-Date).AddMinutes($Minutes)
$next = (Get-Date).AddSeconds(10)
$total = 0
$errors = 0
while ((Get-Date) -lt $end) {
  try {
    $stream.Write($buf, 0, $buf.Length)
    $total += $buf.Length
  } catch {
    if ($errors -eq 0) { Say "write-error first: $($_.Exception.Message)" }
    $errors++
    Start-Sleep -Milliseconds 50
  }
  if ((Get-Date) -ge $next) {
    Say "written_bytes=$total write_errors=$errors"
    $next = (Get-Date).AddSeconds(10)
  }
}
Say "done written_bytes=$total write_errors=$errors"
