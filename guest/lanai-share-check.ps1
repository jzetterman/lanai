<#
.SYNOPSIS
  Check that the shared folder from Linux appears in Windows as a drive
  that lists (Lanai, spec requirement 7).

.DESCRIPTION
  setup.cmd runs it from the setup drive in step 5, right after it starts
  the file-sharing service (VirtioFsSvc). It waits up to TimeoutSec
  seconds, polling every second, for a ready drive with file system
  VirtIO-FS and volume label lanai (Lanai's virtio-fs tag; setup checks
  phase 0), then lists that drive's root, and keeps trying a failed listing
  each second until the limit. It ignores every other drive. The service
  runs as LocalSystem, so its drive is in Windows' global namespace, which
  the user's own, non-elevated session sees too (phase 0).

  Exit codes: 0 the share appeared and listed; 10 no such drive appeared in
  time; 11 the drive appeared but never listed. PowerShell itself exits 1
  for a parse error, an unhandled exception or a blocked script, so
  setup.cmd treats any other code as "the check could not run". A share
  that hangs the drive list or the listing holds the script past its limit.

.PARAMETER TimeoutSec
  How long to wait, in seconds. 0 checks once.

.EXAMPLE
  powershell -ExecutionPolicy Bypass -File lanai-share-check.ps1
#>
param([int]$TimeoutSec = 30)

$ErrorActionPreference = 'Stop'

# The elevated stage keeps the user's environment, and a cmdlet loads its
# module from this path: the system module folders only, as in
# lanai-scale.ps1.
$env:PSModulePath = "$([Environment]::SystemDirectory)\WindowsPowerShell\v1.0\Modules;C:\Program Files\WindowsPowerShell\Modules"

# Find-Share: poll for the share's drive and list its root. Returns 0 once a
# listing works, 10 when no drive matched by the deadline, and 11 when one
# matched but never listed; it sets $script:ShareRoot to the last matching
# root. The delegates are Windows' side, so tests can fake it: $GetDrives
# returns the drives (DriveInfo-like: Name, IsReady, DriveFormat,
# VolumeLabel) and may throw, which ends the check; $Now returns seconds;
# $Sleep waits a second; $ListRoot lists a root and throws on failure.
# Their output is dropped, so the result is always one integer.
function Find-Share($GetDrives, $Now, $Sleep, $ListRoot, [int]$TimeoutSec) {
    $deadline = (& $Now) + $TimeoutSec
    $matched = $false
    while ($true) {
        foreach ($d in @(& $GetDrives)) {
            # A drive that throws while being read is not the share.
            $isShare = $false
            try {
                $isShare = $d.IsReady -and $d.DriveFormat -eq 'VirtIO-FS' -and $d.VolumeLabel -eq 'lanai'
            } catch { }
            if (-not $isShare) { continue }
            $matched = $true
            $script:ShareRoot = $d.Name
            try {
                $null = & $ListRoot $d.Name
                return 0
            } catch { }
        }
        if ((& $Now) -ge $deadline) {
            if ($matched) { return 11 }
            return 10
        }
        $null = & $Sleep
    }
}

$clock = [Diagnostics.Stopwatch]::StartNew()
try {
    $rc = Find-Share -TimeoutSec $TimeoutSec -GetDrives { [IO.DriveInfo]::GetDrives() } `
        -Now { $clock.Elapsed.TotalSeconds } -Sleep { Start-Sleep -Seconds 1 } `
        -ListRoot { param($Root) Get-ChildItem -LiteralPath $Root -Force -ErrorAction Stop }
} catch {
    Write-Output "The check for the shared folder failed: $($_.Exception.Message)"
    exit 1
}
switch ($rc) {
    0 { Write-Output "The shared folder from Linux is drive $script:ShareRoot." }
    10 { Write-Output "The shared folder from Linux did not appear as a drive in $TimeoutSec seconds." }
    11 { Write-Output "The shared folder from Linux appeared as drive $script:ShareRoot, but Windows could not list it." }
}
exit $rc
