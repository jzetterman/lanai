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
  A sign-in task runs it at every sign-in (plan phase 6).

  First draft: plan phase 1, proof 1, checks that it works. Each run appends
  to %LOCALAPPDATA%\Lanai\lanai-scale.log.

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

    // Return the active display paths.
    public static PathInfo[] ActivePaths() {
        uint numPaths, numModes;
        int rc = GetDisplayConfigBufferSizes(QDC_ONLY_ACTIVE_PATHS, out numPaths, out numModes);
        if (rc != 0) throw new Exception("GetDisplayConfigBufferSizes failed: " + rc);
        PathInfo[] paths = new PathInfo[numPaths];
        ModeInfo[] modes = new ModeInfo[numModes];
        rc = QueryDisplayConfig(QDC_ONLY_ACTIVE_PATHS, ref numPaths, paths, ref numModes, modes, IntPtr.Zero);
        if (rc != 0) throw new Exception("QueryDisplayConfig failed: " + rc);
        Array.Resize(ref paths, (int)numPaths);
        return paths;
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

    # Pick the Looking Glass monitor. Every target is logged, so proof 1
    # records the IDD's monitor name. With one active display (the normal
    # case: QEMU's own display is off), that display is the one.
    $paths = [LanaiDisplay]::ActivePaths()
    $chosen = @()
    foreach ($p in $paths) {
        $t = [LanaiDisplay]::GetTargetName($p)
        Write-Log "Display: name '$($t.monitorFriendlyDeviceName)', path '$($t.monitorDevicePath)'"
        if ("$($t.monitorFriendlyDeviceName) $($t.monitorDevicePath)" -match 'Looking|LGIDD') { $chosen += , $p }
    }
    if ($chosen.Count -eq 0 -and $paths.Count -eq 1) { $chosen = @($paths[0]) }
    if ($chosen.Count -ne 1) { throw "Found $($chosen.Count) Looking Glass displays among $($paths.Count); expected one" }
    $path = $chosen[0]

    # minScaleRel is the lowest step (100%) relative to the recommended one,
    # so the recommended step's index is -minScaleRel.
    $d = [LanaiDisplay]::GetScale($path)
    $recommended = - $d.minScaleRel
    $rel = $want - $recommended
    Write-Log ("Recommended {0}%, current {1}%, allowed {2}% to {3}%; want {4}%" -f `
            $Steps[$recommended], $Steps[$recommended + $d.curScaleRel],
            $Steps[$recommended + $d.minScaleRel], $Steps[[math]::Min($recommended + $d.maxScaleRel, $Steps.Count - 1)], $Scale)
    if ($rel -gt $d.maxScaleRel) {
        Write-Log "Windows allows at most $($Steps[$recommended + $d.maxScaleRel])% at this resolution; using that."
        $rel = $d.maxScaleRel
    }
    [LanaiDisplay]::SetScale($path, $rel)
    $after = [LanaiDisplay]::GetScale($path)
    Write-Log "Scale is now $($Steps[$recommended + $after.curScaleRel])%."
}
catch {
    Write-Log "Error: $($_.Exception.Message)"
    exit 1
}
