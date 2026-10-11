<#
.SYNOPSIS
  Keep the Looking Glass monitor's display scale at the one Lanai sends
  (Lanai, spec requirements 12 and 27).

.DESCRIPTION
  Lanai starts the VM with SMBIOS type 11 OEM strings "lanai-scale=<percent>"
  and "lanai-scale-save=<n>". <percent> is one of Windows' scale steps: 100 to
  250 by 25, then 300 to 500 by 50; <n> is the scale save number. Windows
  shows them in Win32_ComputerSystem.OEMStringArray. Without the lanai-scale
  string Lanai is not running this VM, and the script exits at once and
  changes nothing.

  While Windows runs, Lanai's scale feed sends "lanai-scale <step> <save>"
  over the virtio-serial port io.lanai.scale.0 every 2 seconds. A reader
  runspace queues each line; the main loop acts on a batch once no line has
  come for 300 ms, and drops a batch with more than one valid line as a stale
  backlog. A changed save number is a scale save: it replaces a pick. A pick
  is a scale the user chose in Windows' settings, at a resolution unchanged
  for 5 seconds; it holds until the next save or sign-out.

  The scale is set with DisplayConfigSetDeviceInfo, the call the Settings app
  uses, as steps relative to the recommended scale, and applies at once.
  Windows caps it at what the current resolution allows; the target recovers
  when the window grows. A set Windows leaves unapplied is retried once a
  minute. The port opens only to administrators, so the sign-in task runs
  elevated. Changes and distinct errors go to
  C:\Program Files\Lanai\lanai-scale.log.

.PARAMETER Scale
  Use this percentage instead of the SMBIOS string. For testing.

.EXAMPLE
  powershell -ExecutionPolicy Bypass -File lanai-scale.ps1
  powershell -ExecutionPolicy Bypass -File lanai-scale.ps1 -Scale 250
#>
param([int]$Scale = 0)

$ErrorActionPreference = 'Stop'

# The task runs elevated with the user's environment, so nothing it loads
# may come from a folder that user can write: the system module folders
# only, and Add-Type's compiler files in Lanai's own administrator-only
# folder. Set before the first cmdlet or Add-Type.
$env:PSModulePath = "$([Environment]::SystemDirectory)\WindowsPowerShell\v1.0\Modules;C:\Program Files\WindowsPowerShell\Modules"
$env:TMP = 'C:\Program Files\Lanai\tmp'
$env:TEMP = 'C:\Program Files\Lanai\tmp'
$LogFile = 'C:\Program Files\Lanai\lanai-scale.log'

# Windows' scale steps, in order. The index of a step is what the relative
# DPI calls count in.
$Steps = @(100, 125, 150, 175, 200, 225, 250, 300, 350, 400, 450, 500)

# The scale channel's port, as Windows names it.
$PortName = '\\.\Global\io.lanai.scale.0'

# Write a line to the console and to the log file.
function Write-Log([string]$Message) {
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

# Parse one channel line, "lanai-scale <step> <save>" (spec 27): ASCII
# digits only, a listed step, a save number below 10^9. Return the step's
# index and the save number, or $null for anything else.
function ConvertFrom-ScaleLine([string]$Line) {
    if ($Line.Length -gt 32 -or $Line -cnotmatch '^lanai-scale ([0-9]{3}) ([0-9]{1,9})$') { return $null }
    $i = [array]::IndexOf($Steps, [int]$Matches[1])
    if ($i -lt 0) { return $null }
    return [pscustomobject]@{ Step = $i; Save = [int64]$Matches[2] }
}

# Decide what a batch of queued lines ({Text; At} in ms) means at time
# <Now>: Kind "wait" while a line came less than 300 ms ago (a backlog
# arrives at full speed, so a quiet gap means it is drained); else "line"
# with the one valid line, "stale" for two or more (after a stall the port
# delivers its oldest lines, phase 0 proof 4), or "none". Empty lines are
# ignored; malformed ones are counted in Malformed and dropped.
function Get-DrainedLine([object[]]$Lines, [double]$Now) {
    $last = $null
    foreach ($l in $Lines) { if ($null -eq $last -or $l.At -gt $last) { $last = $l.At } }
    if ($null -ne $last -and $Now - $last -lt 300) {
        return [pscustomobject]@{ Kind = 'wait'; Line = $null; Malformed = 0 }
    }
    $valid = @()
    $bad = 0
    foreach ($l in $Lines) {
        if ($l.Text -eq '') { continue }
        $p = ConvertFrom-ScaleLine $l.Text
        if ($null -eq $p) { $bad++ } else { $valid += , $p }
    }
    $kind = 'none'
    if ($valid.Count -gt 1) { $kind = 'stale' } elseif ($valid.Count -eq 1) { $kind = 'line' }
    $line = $null
    if ($kind -eq 'line') { $line = $valid[0] }
    return [pscustomobject]@{ Kind = $kind; Line = $line; Malformed = $bad }
}

# The task's state at start: Want (a step index) and LastSave from the OEM
# strings (LastSave $null without a lanai-scale-save string), no pick, and
# nothing observed. Ready turns true at the first valid line, or at ReadyAt:
# 5 s after the start, or 3 s after the port opens (Invoke-ScaleTick).
function New-ScaleState([int]$Want, $LastSave, [double]$Now) {
    return @{
        Want = $Want; LastSave = $LastSave; Pick = $null
        Confirmed = $null; Pending = $null; NextRetry = 0
        Path = $null; Resolution = $null; Recommended = $null; SettledAt = $Now
        Ready = $false; ReadyAt = $Now + 5000
    }
}

# One pass (spec 12): observe the display and detect a pick, then process
# the drained line, then apply. <Obs> is one display observation ({DevicePath;
# Resolution; MinRel; CurRel; MaxRel}, or $null when none), <Line> a parsed
# line or $null. Returns the new State, an Action ("none", "set" a step, or
# "retry" an unapplied one once a minute), the Step index and its Relative
# value for SetScale.
#   Confirmed is the last step observed; Pending a step asked for and not yet
#   observed. A step equal to neither is a pick only with the same
#   recommended step and a resolution unchanged for 5 s; otherwise it just
#   updates Confirmed. The first observation, and the first after the
#   display path changes, never make a pick. A display change drops an
#   unapplied request, so the next decision asks again at once.
function Step-ScaleState($State, $Obs, $Line, [double]$Now) {
    $s = $State.Clone()
    $action = 'none'
    $step = -1
    $rel = 0
    if (-not $s.Ready -and $Now -ge $s.ReadyAt) { $s.Ready = $true }
    if ($null -ne $Obs) {
        $rec = - $Obs.MinRel
        $cur = $rec + $Obs.CurRel
        $first = $null -eq $s.Path
        $pathMoved = -not $first -and $Obs.DevicePath -ne $s.Path
        $resMoved = -not $first -and $Obs.Resolution -ne $s.Resolution
        $recMoved = -not $first -and $rec -ne $s.Recommended
        if ($first -or $pathMoved -or $resMoved) { $s.SettledAt = $Now }
        if ($first -or $pathMoved) {
            $s.Confirmed = $cur
            $s.Pending = $null
        }
        elseif ($null -ne $s.Pending -and $cur -eq $s.Pending) {
            $s.Confirmed = $cur
            $s.Pending = $null
        }
        elseif ($cur -ne $s.Confirmed) {
            if (-not $recMoved -and -not $resMoved -and $Now - $s.SettledAt -ge 5000) { $s.Pick = $cur }
            $s.Confirmed = $cur
            $s.Pending = $null
        }
        # A request Windows has not applied is asked again at once when the
        # display changes: its relative value may differ now.
        if (($pathMoved -or $resMoved -or $recMoved) -and $null -ne $s.Pending) {
            $s.Pending = $null
            $s.NextRetry = 0
        }
        $s.Path = $Obs.DevicePath
        $s.Resolution = $Obs.Resolution
        $s.Recommended = $rec
    }
    if ($null -ne $Line) {
        # A changed number is a save, even a lower one; the first line
        # without an OEM save number only sets the baseline.
        if ($null -ne $s.LastSave -and $Line.Save -ne $s.LastSave) { $s.Pick = $null }
        $s.LastSave = $Line.Save
        $s.Want = $Line.Step
        $s.Ready = $true
    }
    if ($s.Ready -and $null -ne $Obs) {
        $target = $s.Want
        if ($null -ne $s.Pick) { $target = $s.Pick }
        $d = ScaleDecision $target $Obs.MinRel $Obs.CurRel $Obs.MaxRel
        if ($d.change) {
            $step = $d.target
            $rel = $d.relative
            if ($s.Pending -eq $d.target) {
                if ($Now -ge $s.NextRetry) {
                    $action = 'retry'
                    $s.NextRetry = $Now + 60000
                }
            }
            else {
                $action = 'set'
                $s.Pending = $d.target
                $s.NextRetry = $Now + 60000
            }
        }
    }
    return [pscustomobject]@{ State = $s; Action = $action; Step = $step; Relative = $rel }
}

# After SetScale returns, read-back range <After> (GetScale) shows whether
# Windows applied step <Step>. If it did, the step is confirmed at once, so
# a pick of the old step before the next poll counts as a pick instead of
# looking like an unapplied request. Returns the new state.
function Confirm-ScaleSet($State, [int]$Step, $After) {
    $s = $State.Clone()
    if ((- $After.minScaleRel + $After.curScaleRel) -eq $Step) {
        $s.Confirmed = $Step
        $s.Pending = $null
    }
    return $s
}

# Observe the Looking Glass display: its path, device path, resolution and
# DPI range. Paths and the range are queried on every call: the IDD can
# attach late and Windows can change its recommendation after the
# resolution has settled. Throws when there is not exactly one.
function Get-DisplayObservation {
    $paths = [LanaiDisplay]::ActivePaths()
    $chosen = @()
    foreach ($p in $paths) {
        $t = [LanaiDisplay]::GetTargetName($p)
        if ("$($t.monitorFriendlyDeviceName) $($t.monitorDevicePath)" -match 'Looking|LGIDD') { $chosen += , $p }
    }
    if ($chosen.Count -eq 0 -and $paths.Count -eq 1) { $chosen = @($paths[0]) }
    if ($chosen.Count -ne 1) { throw "Found $($chosen.Count) Looking Glass displays among $($paths.Count); expected one" }
    $path = $chosen[0]
    $t = [LanaiDisplay]::GetTargetName($path)
    $d = [LanaiDisplay]::GetScale($path)
    return [pscustomobject]@{
        Path = $path; Name = $t.monitorFriendlyDeviceName; DevicePath = $t.monitorDevicePath
        Resolution = [LanaiDisplay]::Resolution($path)
        MinRel = $d.minScaleRel; CurRel = $d.curScaleRel; MaxRel = $d.maxScaleRel
    }
}

# The main loop's context: the state, the reader's queue and shared values
# (OpenedAt, the time the port first opened), lines waiting for their quiet
# gap, the next display poll, and the last logged error.
function New-ScaleContext($State, $Queue, $Shared) {
    return @{
        State = $State; Queue = $Queue; Shared = $Shared
        Pending = New-Object 'System.Collections.Generic.List[object]'
        NextObserve = 0; LastError = ''; MalformedLogged = $false
    }
}

# Log <Message> once until a healthy pass clears it. A failed log must not
# end the loop.
function Write-ErrorOnce($Ctx, [string]$Message) {
    if ($Message -eq $Ctx.LastError) { return }
    $Ctx.LastError = $Message
    try { Write-Log "Error: $Message" } catch { }
}

# One 250 ms tick of the main loop at time <Now> (ms): move queued lines to
# Pending and drain them once quiet; then, when a line is ready, the 2 s
# display poll is due, or the first-line wait just ended, run one
# Step-ScaleState pass and call SetScale for its action, then read the
# scale back (Confirm-ScaleSet).
function Invoke-ScaleTick($Ctx, [double]$Now) {
    $item = $null
    while ($Ctx.Queue.TryDequeue([ref]$item)) { $Ctx.Pending.Add($item) }
    $drained = Get-DrainedLine $Ctx.Pending.ToArray() $Now
    $line = $null
    if ($drained.Kind -ne 'wait') {
        $count = $Ctx.Pending.Count
        $Ctx.Pending.Clear()
        if ($drained.Malformed -gt 0 -and -not $Ctx.MalformedLogged) {
            $Ctx.MalformedLogged = $true
            try { Write-Log 'Dropped a malformed line from the scale channel.' } catch { }
        }
        if ($drained.Kind -eq 'stale') {
            try { Write-Log "Dropped a stale backlog of $count lines; the next line comes within 2 seconds." } catch { }
        }
        if ($drained.Kind -eq 'line') { $line = $drained.Line }
    }
    $s = $Ctx.State
    if ($null -ne $Ctx.Shared.OpenedAt) { $s.ReadyAt = [math]::Min($s.ReadyAt, $Ctx.Shared.OpenedAt + 3000) }
    # A first line waiting for its quiet gap holds the OEM fallback back, so
    # the line's step applies alone.
    $hold = -not $s.Ready -and $drained.Kind -eq 'wait'
    if ($null -eq $line -and $Now -lt $Ctx.NextObserve -and ($s.Ready -or $hold -or $Now -lt $s.ReadyAt)) { return }
    $Ctx.NextObserve = $Now + 2000
    $pass = $s
    if ($hold) {
        $pass = $s.Clone()
        $pass.ReadyAt = [double]::PositiveInfinity
    }
    $obs = $null
    try {
        $obs = Get-DisplayObservation
        $r = Step-ScaleState $pass $obs $line $Now
        $Ctx.LastError = ''
    }
    catch {
        Write-ErrorOnce $Ctx $_.Exception.Message
        $obs = $null
        $r = Step-ScaleState $pass $null $line $Now
    }
    if ($hold) { $r.State.ReadyAt = $s.ReadyAt }
    $Ctx.State = $r.State
    try {
        if ($null -ne $line -and $null -ne $s.LastSave -and $r.State.LastSave -ne $s.LastSave) {
            Write-Log "Scale save $($line.Save): target $(StepName $line.Step)."
        }
        if ($null -ne $r.State.Pick -and $r.State.Pick -ne $s.Pick) {
            Write-Log "Pick: $(StepName $r.State.Pick) chosen in Windows; it holds until the next scale save."
        }
        if ($r.Action -eq 'set') {
            Write-Log ("Display '{0}' at {1}: raw minScaleRel {2}, curScaleRel {3}, maxScaleRel {4}; recommended {5}, current {6}, applying {7}" -f `
                $obs.Name, $obs.Resolution, $obs.MinRel, $obs.CurRel, $obs.MaxRel,
                (StepName (- $obs.MinRel)), (StepName (- $obs.MinRel + $obs.CurRel)), (StepName $r.Step))
        }
    } catch { } # A failed log must not prevent the scale attempt.
    if ($r.Action -ne 'none') {
        try {
            [LanaiDisplay]::SetScale($obs.Path, $r.Relative)
            $Ctx.State = Confirm-ScaleSet $Ctx.State $r.Step ([LanaiDisplay]::GetScale($obs.Path))
        }
        catch { Write-ErrorOnce $Ctx $_.Exception.Message }
    }
}

# The reader runspace's loop: open the port with CreateFile (a FileStream
# cannot open a \\.\ path in PowerShell 5.1), stamp $Shared.OpenedAt once,
# and queue each complete line with its arrival time. The handle stays open
# across the feed's connects: a failed or 0-byte read (no host connected
# fails at once, phase 0 proof 3) reads again after 250 ms, and only an
# invalid handle or a failed open is retried, every 2 s.
$ReaderScript = {
    param($Queue, $Shared, $Clock, $PortName)
    $handle = $null
    $stream = $null
    $buf = New-Object byte[] 4096
    $partial = ''
    while ($true) {
        try {
            if ($null -eq $handle -or $handle.IsInvalid -or $handle.IsClosed) {
                $handle = [LanaiPort]::Open($PortName)
                if ($handle.IsInvalid) { Start-Sleep -Seconds 2; continue }
                $stream = New-Object IO.FileStream($handle, [IO.FileAccess]::Read, 4096, $false)
                $partial = ''
                if ($null -eq $Shared.OpenedAt) { $Shared.OpenedAt = $Clock.Elapsed.TotalMilliseconds }
            }
            $n = -1
            try { $n = $stream.Read($buf, 0, $buf.Length) } catch { $n = -1 }
            if ($n -le 0) { Start-Sleep -Milliseconds 250; continue }
            $now = $Clock.Elapsed.TotalMilliseconds
            $partial += [Text.Encoding]::ASCII.GetString($buf, 0, $n)
            $i = $partial.IndexOf("`n")
            while ($i -ge 0) {
                $Queue.Enqueue([pscustomobject]@{ Text = $partial.Substring(0, $i).TrimEnd("`r"); At = $now })
                $partial = $partial.Substring($i + 1)
                $i = $partial.IndexOf("`n")
            }
            # Lanai's lines are short: drop an oversize fragment.
            if ($partial.Length -gt 256) { $partial = '' }
        }
        catch { Start-Sleep -Seconds 2 }
    }
}

# The display configuration API from user32.dll, and CreateFile for the
# scale port. DPI_GET and DPI_SET use the undocumented device info types -3
# and -4, which the Settings app uses for "Scale"; their scale fields count
# steps relative to the recommended one.
Add-Type -TypeDefinition @'
using System;
using System.Runtime.InteropServices;
using Microsoft.Win32.SafeHandles;

public static class LanaiPort {
    [DllImport("kernel32.dll", SetLastError = true, CharSet = CharSet.Unicode)]
    private static extern SafeFileHandle CreateFile(string name, uint access, uint share,
        IntPtr security, uint disposition, uint flags, IntPtr template);

    // Open a port for reading (GENERIC_READ, OPEN_EXISTING).
    public static SafeFileHandle Open(string name) {
        return CreateFile(name, 0x80000000, 0, IntPtr.Zero, 3, 0, IntPtr.Zero);
    }
}

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
    $save = $null
    if ($Scale -eq 0) {
        $oem = @((Get-CimInstance -ClassName Win32_ComputerSystem).OEMStringArray)
        $entry = $oem | Where-Object { $_ -like 'lanai-scale=*' } | Select-Object -First 1
        if (-not $entry) {
            # Not Lanai's VM (spec 4): change nothing and keep nothing running.
            Write-Log 'No lanai-scale OEM string; the scale stays as it is.'
            exit 0
        }
        if ($entry -cnotmatch '^lanai-scale=([0-9]+)$') { throw "Bad OEM string: $entry" }
        $Scale = [int]$Matches[1]
        # A host older than the save number sends none: the first line sets it.
        $saveEntry = $oem | Where-Object { $_ -like 'lanai-scale-save=*' } | Select-Object -First 1
        if ($saveEntry -cmatch '^lanai-scale-save=([0-9]{1,9})$') { $save = [int64]$Matches[1] }
    }
    $want = [array]::IndexOf($Steps, $Scale)
    if ($want -lt 0) { throw "Scale $Scale is not a Windows scale step ($($Steps -join ', '))" }

    # A task with an Interactive logon token ends with the user's session.
    # IgnoreNew prevents duplicates and its zero execution limit permits >72 h.
    $clock = [Diagnostics.Stopwatch]::StartNew()
    $queue = New-Object 'System.Collections.Concurrent.ConcurrentQueue[object]'
    $shared = [hashtable]::Synchronized(@{ OpenedAt = $null })
    $reader = [PowerShell]::Create()
    $reader.AddScript($ReaderScript).AddArgument($queue).AddArgument($shared).AddArgument($clock).AddArgument($PortName) | Out-Null
    $reader.BeginInvoke() | Out-Null
    $ctx = New-ScaleContext (New-ScaleState $want $save 0) $queue $shared
    while ($true) {
        Invoke-ScaleTick $ctx $clock.Elapsed.TotalMilliseconds
        Start-Sleep -Milliseconds 250
    }
}
catch {
    Write-Log "Error: $($_.Exception.Message)"
    exit 1
}
