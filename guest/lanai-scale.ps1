<#
.SYNOPSIS
  Set the Looking Glass monitor's display scale to the one the host chose
  (Lanai, spec requirement 12).

.DESCRIPTION
  Lanai starts the VM with an SMBIOS type 11 OEM string "lanai-scale=<percent>".
  <percent> is one of Windows' scale steps: 100 to 250 by 25, then 300 to 500
  by 50. Windows shows SMBIOS OEM strings in Win32_ComputerSystem.OEMStringArray.

  This script reads that string and sets the scale of the Looking Glass
  monitor with DisplayConfigSetDeviceInfo, the call the Settings app uses. The
  call takes the scale as a number of steps relative to the monitor's
  recommended scale, and applies at once, without a sign-out. The setting is
  per user, so the script runs as the signed-in user; it needs no admin rights.
  A sign-in task keeps the absolute target at sign-in and every 2 seconds until
  sign-out, including after a resize changes the recommended step. Windows caps
  it at its allowed maximum; the target recovers when that range grows. Manual
  changes in Windows Settings are reverted for both fixed and monitor choices.
  If Windows leaves a change unapplied, retry the same decision once a minute.
  Actual changes and distinct errors go to %LOCALAPPDATA%\Lanai\lanai-scale.log.

.PARAMETER Scale
  Use this percentage instead of the SMBIOS string. For testing.

.EXAMPLE
  powershell -ExecutionPolicy Bypass -File lanai-scale.ps1
  powershell -ExecutionPolicy Bypass -File lanai-scale.ps1 -Scale 250
#>
param([int]$Scale = 0)

$ErrorActionPreference = 'Stop'

# Windows' scale steps, in order. The index of a step is what the relative
# DPI calls count in.
$Steps = @(100, 125, 150, 175, 200, 225, 250, 300, 350, 400, 450, 500)
$LogFile = Join-Path $env:LOCALAPPDATA 'Lanai\lanai-scale.log'

# Write a line to the console and to the log file.
function Write-Log([string]$Message) {
    New-Item -ItemType Directory -Force -Path (Split-Path $LogFile) | Out-Null
    Add-Content -Path $LogFile -Value "$(Get-Date -Format o) $Message"
    Write-Output $Message
}

# Name step <i> of $Steps, as "150%", or "unknown" when <i> is outside the
# list. Every lookup goes through here: PowerShell wraps a negative index
# silently (index -1 gives 500), and Windows' relative values can point
# outside the list (proof 1 logged a blank current scale).
function StepName([int]$i) {
    if ($i -lt 0 -or $i -ge $Steps.Count) { return 'unknown' }
    return "$($Steps[$i])%"
}

# Pure absolute-step decision, reevaluated from each current DPI range. Never
# mutate Want: a cap at a small resolution must recover when the window grows.
function ScaleDecision([int]$Want, [int]$MinRel, [int]$CurrentRel, [int]$MaxRel) {
    $recommended = - $MinRel
    $maxIdx = [math]::Min($recommended + $MaxRel, $Steps.Count - 1)
    if ($recommended -lt 0 -or $maxIdx -lt 0 -or $Want -lt 0 -or $Want -ge $Steps.Count) {
        throw 'Invalid Windows scale range or target'
    }
    $target = [math]::Min($Want, $maxIdx)
    $current = $recommended + $CurrentRel
    return [pscustomobject][ordered]@{
        recommended = $recommended; current = $current; target = $target
        relative = $target - $recommended; change = $current -ne $target
    }
}

# Query paths and the range on every poll: the IDD can attach late and Windows
# can change its recommendation after the resolution has settled. An unchanged
# poll is silent; identical errors are logged only once until a healthy poll.
# Windows may accept a set without applying it. Retry an identical decision
# once a minute; changed displays, ranges or targets still apply at once.
function Update-DisplayScale([int]$Want) {
    try {
        $paths = [LanaiDisplay]::ActivePaths()
        $chosen = @()
        foreach ($p in $paths) {
            $t = [LanaiDisplay]::GetTargetName($p)
            if ("$($t.monitorFriendlyDeviceName) $($t.monitorDevicePath)" -match 'Looking|LGIDD') { $chosen += , $p }
        }
        if ($chosen.Count -eq 0 -and $paths.Count -eq 1) { $chosen = @($paths[0]) }
        if ($chosen.Count -ne 1) { throw "Found $($chosen.Count) Looking Glass displays among $($paths.Count); expected one" }
        $path = $chosen[0]
        $resolution = [LanaiDisplay]::Resolution($path)
        $d = [LanaiDisplay]::GetScale($path)
        $decision = ScaleDecision $Want $d.minScaleRel $d.curScaleRel $d.maxScaleRel
        if ($decision.change) {
            $t = [LanaiDisplay]::GetTargetName($path)
            $key = "{0}|{1}|{2}|{3}|{4}|{5}|{6}" -f $t.monitorDevicePath, $resolution,
                $decision.recommended, $decision.current, $decision.target, $decision.relative, $d.maxScaleRel
            $now = Get-Date
            if ($key -eq $script:LastScaleDecision -and $now -lt $script:NextScaleAttempt) { return }
            $newDecision = $key -ne $script:LastScaleDecision
            if ($newDecision) {
                try {
                    Write-Log "Display: name '$($t.monitorFriendlyDeviceName)', path '$($t.monitorDevicePath)', resolution $resolution"
                    Write-Log ("Raw minScaleRel {0}, curScaleRel {1}, maxScaleRel {2}" -f `
                        $d.minScaleRel, $d.curScaleRel, $d.maxScaleRel)
                    Write-Log ("Recommended {0}, current {1}, allowed {2} to {3}; target {4}, applying {5}" -f `
                        (StepName $decision.recommended), (StepName $decision.current), (StepName 0),
                        (StepName ([math]::Min($decision.recommended + $d.maxScaleRel, $Steps.Count - 1))),
                        (StepName $Want), (StepName $decision.target))
                } catch { } # A failed log must not prevent the scale attempt.
            }
            try { [LanaiDisplay]::SetScale($path, $decision.relative) }
            finally {
                # Back off only once the API was attempted, even if it threw.
                $script:LastScaleDecision = $key
                $script:NextScaleAttempt = $now.AddSeconds(60)
            }
            $after = [LanaiDisplay]::GetScale($path)
            $result = "Scale is now $(StepName (- $after.minScaleRel + $after.curScaleRel))."
            if ($newDecision -or $result -ne $script:LastScaleResult) { Write-Log $result }
            $script:LastScaleResult = $result
            if (- $after.minScaleRel + $after.curScaleRel -eq $decision.target) {
                # Confirmed changes need no backoff, even if a user reverses
                # the setting before the next unchanged poll.
                $script:LastScaleDecision = ''
                $script:LastScaleResult = ''
            }
        }
        else {
            # A healthy poll permits immediate correction of a later manual change.
            $script:LastScaleDecision = ''
            $script:LastScaleResult = ''
        }
        $script:LastScaleError = ''
    }
    catch {
        $message = $_.Exception.Message
        $newError = $message -ne $script:LastScaleError
        $script:LastScaleError = $message
        if ($newError) {
            # A missing or unwritable log must not terminate the sign-in loop.
            try { Write-Log "Error: $message" } catch { }
        }
    }
}

# The display configuration API from user32.dll. DPI_GET and DPI_SET use
# the undocumented device info types -3 and -4, which the Settings app uses
# for "Scale"; their scale fields count steps relative to the recommended one.
Add-Type -TypeDefinition @'
using System;
using System.Runtime.InteropServices;

public static class LanaiDisplay {
    public const uint QDC_ONLY_ACTIVE_PATHS = 2;
    public const int GET_TARGET_NAME = 2;
    public const int GET_DPI_SCALE = -3;
    public const int SET_DPI_SCALE = -4;

    [StructLayout(LayoutKind.Sequential)]
    public struct LUID { public uint LowPart; public int HighPart; }

    [StructLayout(LayoutKind.Sequential)]
    public struct Rational { public uint Numerator; public uint Denominator; }

    [StructLayout(LayoutKind.Sequential)]
    public struct PathSourceInfo {
        public LUID adapterId; public uint id; public uint modeInfoIdx; public uint statusFlags;
    }

    [StructLayout(LayoutKind.Sequential)]
    public struct PathTargetInfo {
        public LUID adapterId; public uint id; public uint modeInfoIdx;
        public int outputTechnology; public int rotation; public int scaling;
        public Rational refreshRate; public int scanLineOrdering;
        public int targetAvailable; public uint statusFlags;
    }

    [StructLayout(LayoutKind.Sequential)]
    public struct PathInfo {
        public PathSourceInfo sourceInfo; public PathTargetInfo targetInfo; public uint flags;
    }

    // DISPLAYCONFIG_MODE_INFO: 16 bytes of header, then a 48-byte union this
    // script never reads.
    [StructLayout(LayoutKind.Sequential)]
    public struct ModeInfo {
        public int infoType; public uint id; public LUID adapterId;
        [MarshalAs(UnmanagedType.ByValArray, SizeConst = 48)] public byte[] data;
    }

    [StructLayout(LayoutKind.Sequential)]
    public struct Header { public int type; public int size; public LUID adapterId; public uint id; }

    [StructLayout(LayoutKind.Sequential, CharSet = CharSet.Unicode)]
    public struct TargetName {
        public Header header; public uint flags; public int outputTechnology;
        public ushort edidManufactureId; public ushort edidProductCodeId; public uint connectorInstance;
        [MarshalAs(UnmanagedType.ByValTStr, SizeConst = 64)] public string monitorFriendlyDeviceName;
        [MarshalAs(UnmanagedType.ByValTStr, SizeConst = 128)] public string monitorDevicePath;
    }

    [StructLayout(LayoutKind.Sequential)]
    public struct DpiGet { public Header header; public int minScaleRel; public int curScaleRel; public int maxScaleRel; }

    [StructLayout(LayoutKind.Sequential)]
    public struct DpiSet { public Header header; public int scaleRel; }

    [DllImport("user32.dll")]
    public static extern int GetDisplayConfigBufferSizes(uint flags, out uint numPaths, out uint numModes);

    [DllImport("user32.dll")]
    public static extern int QueryDisplayConfig(uint flags, ref uint numPaths, [Out] PathInfo[] paths,
        ref uint numModes, [Out] ModeInfo[] modes, IntPtr topologyId);

    [DllImport("user32.dll")]
    public static extern int DisplayConfigGetDeviceInfo(ref TargetName request);

    [DllImport("user32.dll")]
    public static extern int DisplayConfigGetDeviceInfo(ref DpiGet request);

    [DllImport("user32.dll")]
    public static extern int DisplayConfigSetDeviceInfo(ref DpiSet request);

    private static ModeInfo[] currentModes;

    // Return fresh active paths and source modes on every poll.
    public static PathInfo[] ActivePaths() {
        uint numPaths, numModes;
        int rc = GetDisplayConfigBufferSizes(QDC_ONLY_ACTIVE_PATHS, out numPaths, out numModes);
        if (rc != 0) throw new Exception("GetDisplayConfigBufferSizes failed: " + rc);
        PathInfo[] paths = new PathInfo[numPaths];
        ModeInfo[] modes = new ModeInfo[numModes];
        rc = QueryDisplayConfig(QDC_ONLY_ACTIVE_PATHS, ref numPaths, paths, ref numModes, modes, IntPtr.Zero);
        if (rc != 0) throw new Exception("QueryDisplayConfig failed: " + rc);
        currentModes = modes;
        Array.Resize(ref paths, (int)numPaths);
        return paths;
    }

    // DISPLAYCONFIG_SOURCE_MODE begins with width and height in the union.
    public static string Resolution(PathInfo path) {
        uint idx = path.sourceInfo.modeInfoIdx;
        if (currentModes == null || idx >= currentModes.Length || currentModes[idx].infoType != 1)
            throw new Exception("No active source resolution");
        byte[] data = currentModes[idx].data;
        return BitConverter.ToUInt32(data, 0) + "x" + BitConverter.ToUInt32(data, 4);
    }

    // Return the monitor name and device path of a path's target.
    public static TargetName GetTargetName(PathInfo path) {
        TargetName t = new TargetName();
        t.header.type = GET_TARGET_NAME;
        t.header.size = Marshal.SizeOf(typeof(TargetName));
        t.header.adapterId = path.targetInfo.adapterId;
        t.header.id = path.targetInfo.id;
        int rc = DisplayConfigGetDeviceInfo(ref t);
        if (rc != 0) throw new Exception("GET_TARGET_NAME failed: " + rc);
        return t;
    }

    // Return the source's scale range and current value, as steps relative
    // to the recommended scale.
    public static DpiGet GetScale(PathInfo path) {
        DpiGet d = new DpiGet();
        d.header.type = GET_DPI_SCALE;
        d.header.size = Marshal.SizeOf(typeof(DpiGet));
        d.header.adapterId = path.sourceInfo.adapterId;
        d.header.id = path.sourceInfo.id;
        int rc = DisplayConfigGetDeviceInfo(ref d);
        if (rc != 0) throw new Exception("GET_DPI_SCALE failed: " + rc);
        return d;
    }

    // Set the source's scale, as steps relative to the recommended scale.
    public static void SetScale(PathInfo path, int scaleRel) {
        DpiSet d = new DpiSet();
        d.header.type = SET_DPI_SCALE;
        d.header.size = Marshal.SizeOf(typeof(DpiSet));
        d.header.adapterId = path.sourceInfo.adapterId;
        d.header.id = path.sourceInfo.id;
        d.scaleRel = scaleRel;
        int rc = DisplayConfigSetDeviceInfo(ref d);
        if (rc != 0) throw new Exception("SET_DPI_SCALE failed: " + rc);
    }
}
'@

try {
    if ($Scale -eq 0) {
        $oem = @((Get-CimInstance -ClassName Win32_ComputerSystem).OEMStringArray)
        $entry = $oem | Where-Object { $_ -like 'lanai-scale=*' } | Select-Object -First 1
        if (-not $entry) {
            Write-Log 'No lanai-scale OEM string; the scale stays as it is.'
            exit 0
        }
        if ($entry -notmatch '^lanai-scale=(\d+)$') { throw "Bad OEM string: $entry" }
        $Scale = [int]$Matches[1]
    }
    $want = [array]::IndexOf($Steps, $Scale)
    if ($want -lt 0) { throw "Scale $Scale is not a Windows scale step ($($Steps -join ', '))" }

    # A task with an Interactive logon token ends with the user's session.
    # IgnoreNew prevents duplicates and its zero execution limit permits >72 h.
    $script:LastScaleError = ''
    $script:LastScaleDecision = ''
    $script:LastScaleResult = ''
    $script:NextScaleAttempt = [datetime]::MinValue
    while ($true) {
        Update-DisplayScale $want
        Start-Sleep -Seconds 2
    }
}
catch {
    Write-Log "Error: $($_.Exception.Message)"
    exit 1
}
