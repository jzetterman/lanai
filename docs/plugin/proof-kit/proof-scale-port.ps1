# proof-scale-port.ps1: live-scale phase 0 proof (docs/plugin/plan.md,
# "Phase 0: channel proof"). Opens the scale port and logs every read with a
# timestamp, so the host side can check access, order, latency, and what a
# read does with no host connected. Run it from the shared folder, once in an
# elevated PowerShell and once in a normal one:
#   powershell -ExecutionPolicy Bypass -File <share>\lanai-proof\proof-scale-port.ps1
# -HoldSeconds N opens the port, then waits N seconds before the first read
# (proof 4: the host writes while the guest is not reading).
# The log goes next to the script, named for the elevation, so the host can
# read it through the share. Ctrl+C stops it.
param([int]$HoldSeconds = 0)

$ErrorActionPreference = 'Stop'
$port = '\\.\Global\io.lanai.scale.0'
$elevated = ([Security.Principal.WindowsPrincipal][Security.Principal.WindowsIdentity]::GetCurrent()).IsInRole([Security.Principal.WindowsBuiltInRole]::Administrator)
$log = Join-Path $PSScriptRoot ("guest-" + $(if ($elevated) { 'elevated' } else { 'normal' }) + ".log")

function Now-Ms { [DateTimeOffset]::UtcNow.ToUnixTimeMilliseconds() }

# Writes one line to the console and the log, prefixed with UTC epoch ms.
function Say([string]$text) {
  $line = "$(Now-Ms) $text"
  Write-Host $line
  Add-Content -Path $log -Value $line
}

Add-Type -TypeDefinition @'
using System;
using System.Runtime.InteropServices;
using Microsoft.Win32.SafeHandles;
public static class ProofPort {
  [DllImport("kernel32.dll", SetLastError = true, CharSet = CharSet.Unicode)]
  public static extern SafeFileHandle CreateFile(string name, uint access, uint share,
    IntPtr security, uint disposition, uint flags, IntPtr template);
}
'@

Say "start elevated=$elevated user=$env:USERNAME hold=$HoldSeconds"
$GENERIC_READ = [uint32]2147483648
$OPEN_EXISTING = [uint32]3
$handle = [ProofPort]::CreateFile($port, $GENERIC_READ, 0, [IntPtr]::Zero, $OPEN_EXISTING, 0, [IntPtr]::Zero)
if ($handle.IsInvalid) {
  $code = [Runtime.InteropServices.Marshal]::GetLastWin32Error()
  Say "open-failed win32=$code ($((New-Object ComponentModel.Win32Exception $code).Message))"
  exit 1
}
Say "open-ok"
$stream = New-Object IO.FileStream($handle, [IO.FileAccess]::Read, 4096, $false)
if ($HoldSeconds -gt 0) {
  Say "hold $HoldSeconds s"
  Start-Sleep -Seconds $HoldSeconds
  Say "hold-done"
}

# Proof lines are "proof <seq> <host epoch ms>". Each read logs its byte
# count; each complete line logs its seq, a seq gap, and arrival minus send
# (that includes the clock skew between host and guest, so the spread is
# what matters).
$buf = New-Object byte[] 4096
$pending = ''
$lastSeq = $null
$zeros = 0
while ($true) {
  try {
    $n = $stream.Read($buf, 0, $buf.Length)
  } catch {
    $n = -1
    $why = if ($_.Exception.InnerException) { $_.Exception.InnerException.Message } else { $_.Exception.Message }
  }
  # A run of failed or 0-byte reads logs its first and its count, not every
  # read, and retries after 250 ms.
  if ($n -le 0) {
    if ($zeros -eq 0) { Say $(if ($n -eq 0) { 'read-0 first' } else { "read-error first: $why" }) }
    $zeros++
    Start-Sleep -Milliseconds 250
    continue
  }
  $now = Now-Ms
  if ($zeros -gt 0) { Say "empty-read run of $zeros ended"; $zeros = 0 }
  Say "read $n bytes"
  $pending += [Text.Encoding]::ASCII.GetString($buf, 0, $n)
  while (($i = $pending.IndexOf("`n")) -ge 0) {
    $text = $pending.Substring(0, $i).TrimEnd("`r")
    $pending = $pending.Substring($i + 1)
    if ($text -eq '') { continue }
    $f = $text -split ' '
    if ($f.Count -eq 3 -and $f[0] -eq 'proof') {
      $seq = [int64]$f[1]
      $gap = if ($null -ne $lastSeq -and $seq -ne $lastSeq + 1) { " GAP after $lastSeq" } else { '' }
      Say "line seq=$seq delta_ms=$($now - [int64]$f[2])$gap"
      $lastSeq = $seq
    } else {
      Say "line raw=$text"
    }
  }
}
