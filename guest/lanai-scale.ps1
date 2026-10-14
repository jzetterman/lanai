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
  minute. The port opens only to administrators, so the scale task runs
  elevated. Changes, caps, a current scale outside Windows' range (custom
  scaling) and distinct errors go to C:\Program Files\Lanai\lanai-scale.log.

  The scale task runs C:\Program Files\Lanai\lanai-start.exe, a windowless
  program setup builds from lanai-start.cs. It starts this script in a
  hidden powershell.exe, in a job that ends the script when the program
  ends, and runs the sign-in step itself (its log is lanai-signin.log).

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

# Log <Message> on the way out, unless the log's last line already carries
# it: the sign-in trigger starts the task every 5 minutes, and a start that
# ends the same way as the one before must not grow the log. An unreadable
# log counts as a different last line.
function Write-ExitLog([string]$Message) {
    $last = $null
    try { $last = Get-Content -LiteralPath $LogFile -Tail 1 -ErrorAction Stop } catch { }
    if ("$last" -cmatch '^\S+ (.*)$' -and $Matches[1] -ceq $Message) { Write-Output $Message; return }
    Write-Log $Message
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

# Name the cap when Windows' range at observation <Obs> holds target step
# <Target> below itself, or return '' when it does not. The line names the
# target, the capped step and the resolution, so a change in any of them
# makes a new line.
function Get-CapLine([int]$Target, $Obs) {
    $d = ScaleDecision $Target $Obs.MinRel $Obs.CurRel $Obs.MaxRel
    if ($d.target -ge $Target) { return '' }
    $at = StepName $d.target
    return "Windows allows at most $at at $($Obs.Resolution); using $at until the window grows (target $(StepName $Target))."
}

# Read the boot baseline from the SMBIOS OEM strings <Oem>: Scale from
# "lanai-scale=<percent>" and Save from "lanai-scale-save=<n>" ($null when
# missing or malformed: a host older than the save number sends none, and the
# first line sets it). Returns $null without a lanai-scale string (not
# Lanai's VM); throws on a malformed one.
function Get-OemBaseline([string[]]$Oem) {
    $entry = $Oem | Where-Object { $_ -like 'lanai-scale=*' } | Select-Object -First 1
    if (-not $entry) { return $null }
    if ($entry -cnotmatch '^lanai-scale=([0-9]{1,9})$') { throw "Bad OEM string: $entry" }
    $scale = [int]$Matches[1]
    $save = $null
    $saveEntry = $Oem | Where-Object { $_ -like 'lanai-scale-save=*' } | Select-Object -First 1
    if ($saveEntry -cmatch '^lanai-scale-save=([0-9]{1,9})$') { $save = [int64]$Matches[1] }
    return [pscustomobject]@{ Scale = $scale; Save = $save }
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
# ignored; malformed ones are counted in Malformed and dropped. Valid counts
# the valid lines.
function Get-DrainedLine([object[]]$Lines, [double]$Now) {
    $last = $null
    foreach ($l in $Lines) { if ($null -eq $last -or $l.At -gt $last) { $last = $l.At } }
    if ($null -ne $last -and $Now - $last -lt 300) {
        return [pscustomobject]@{ Kind = 'wait'; Line = $null; Malformed = 0; Valid = 0 }
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
    return [pscustomobject]@{ Kind = $kind; Line = $line; Malformed = $bad; Valid = $valid.Count }
}

# The task's state at start: Want (a step index) and LastSave from the OEM
# strings (LastSave $null without a lanai-scale-save string), no pick, and
# nothing observed. Ready turns true at the first valid line, or at
# Get-ReadyAt: ReadyAt (5 s after the start, or 3 s after the port opens,
# Invoke-ScaleTick) or later while lines keep arriving (LastArrival).
#   Confirmed  the last step observed
#   Pending    the step asked for and not yet observed
#   Requested  every step asked for since the pending request was
#              confirmed, a decision needed no change, another change (a
#              pick or not) was seen, the display path changed or the
#              display was missing
function New-ScaleState([int]$Want, $LastSave, [double]$Now) {
    return @{
        Want = $Want; LastSave = $LastSave; Pick = $null
        Confirmed = $null; Pending = $null; Requested = @(); NextRetry = 0
        Path = $null; Resolution = $null; Recommended = $null; SettledAt = $Now
        Ready = $false; ReadyAt = $Now + 5000; LastArrival = $null
    }
}

# Print when the first-line wait of <State> ends: ReadyAt, but no sooner than
# one feed period and a margin (2.5 s) after the last line arrived, so a line
# still in its quiet gap, or the fresh line after a dropped stale batch,
# applies alone instead of after the OEM step.
function Get-ReadyAt($State) {
    if ($null -eq $State.LastArrival) { return $State.ReadyAt }
    return [math]::Max($State.ReadyAt, $State.LastArrival + 2500)
}

# One pass (spec 12): observe the display and detect a pick, then process
# the drained line, then apply. <Obs> is one display observation
# (Get-DisplayObservation), or $null when the display is missing; <Line> a
# parsed line or $null. Returns the new State, an Action ("none", "set" a
# step, or "retry" an unapplied one once a minute), the Step index and its
# Relative value for SetScale, and the uncapped Target index ($null when the
# pass made no decision: not ready yet, or no display).
#   A step in none of Confirmed, Pending and Requested is a pick only when
#   it is a listed step, with the same recommended step and a resolution
#   unchanged for 5 s; otherwise
#   it just updates Confirmed. An older request that lands late is never a
#   pick: the newest is asked for again. The first observation, and the
#   first after the display path changes or the display was missing, never
#   make a pick; a missing display keeps an existing pick. A display change
#   drops an unapplied request, so the next decision asks again at once.
function Step-ScaleState($State, $Obs, $Line, [double]$Now) {
    $s = $State.Clone()
    $action = 'none'
    $step = -1
    $rel = 0
    $target = $null
    if (-not $s.Ready -and $Now -ge (Get-ReadyAt $s)) { $s.Ready = $true }
    if ($null -eq $Obs) {
        $s.Path = $null
        $s.Pending = $null
        $s.Requested = @()
    }
    else {
        $rec = $Obs.Recommended
        $cur = $Obs.Current
        $first = $null -eq $s.Path
        $pathMoved = -not $first -and $Obs.DevicePath -ne $s.Path
        $resMoved = -not $first -and $Obs.Resolution -ne $s.Resolution
        $recMoved = -not $first -and $rec -ne $s.Recommended
        if ($first -or $pathMoved -or $resMoved) { $s.SettledAt = $Now }
        if ($first -or $pathMoved -or ($null -ne $s.Pending -and $cur -eq $s.Pending)) {
            $s.Confirmed = $cur
            $s.Pending = $null
            $s.Requested = @()
        }
        elseif ($cur -ne $s.Confirmed -and $s.Requested -contains $cur) {
            $s.Confirmed = $cur
            $s.Pending = $null
            $s.NextRetry = 0
        }
        elseif ($cur -ne $s.Confirmed) {
            # Only a listed step: with custom scaling on, Windows reports
            # values outside its range (phase C), and a pick of one would
            # make every decision throw until the next save.
            if (-not $recMoved -and -not $resMoved -and $Now - $s.SettledAt -ge 5000 -and $cur -ge 0 -and $cur -lt $Steps.Count) { $s.Pick = $cur }
            $s.Confirmed = $cur
            $s.Pending = $null
            $s.Requested = @()
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
        if (-not $d.change) {
            # Nothing to ask for: an old unapplied request must not make a
            # later matching pick look like it landed.
            $s.Pending = $null
            $s.Requested = @()
        }
        else {
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
            if ($action -ne 'none' -and $s.Requested -notcontains $d.target) { $s.Requested = @($s.Requested) + $d.target }
        }
    }
    return [pscustomobject]@{ State = $s; Action = $action; Step = $step; Relative = $rel; Target = $target }
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
        $s.Requested = @()
    }
    return $s
}

# Observe the Looking Glass display: its path, device path, resolution, DPI
# range (relative to the recommended step) and the Recommended and Current
# step indices. Paths and the range are queried on every call: the IDD can
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
        Recommended = - $d.minScaleRel; Current = - $d.minScaleRel + $d.curScaleRel
    }
}

# The main loop's context:
#   State        the scale state (New-ScaleState)
#   Queue        the reader's queue of {Text; At} lines
#   Shared       values the reader sets: OpenedAt (when the port first
#                opened) and PortError (its last open or read error, empty
#                once the port opens again)
#   Lines        queued lines waiting for their quiet gap
#   NextObserve  the next 2 s display poll
#   LastError    the last logged display or SetScale error, cleared after
#                a pass in which nothing failed
#   LoggedPortError  the last logged port error
#   LoggedSet    the last "applying" line logged, so a set retried at each
#                poll while SetScale fails is logged once
#   LoggedCap    the last cap line logged (Get-CapLine), cleared after a
#                decision without a cap
#   RangeLogged  whether an out-of-range current scale was logged, cleared
#                after an observation in range
#   PortOpened   whether the port's opening was seen and logged
#   MalformedLogged  whether a malformed line was logged
function New-ScaleContext($State, $Queue, $Shared) {
    return @{
        State = $State; Queue = $Queue; Shared = $Shared
        Lines = New-Object 'System.Collections.Generic.List[object]'
        NextObserve = 0; LastError = ''; LoggedPortError = ''; LoggedSet = ''; LoggedCap = ''
        RangeLogged = $false; PortOpened = $false; MalformedLogged = $false
    }
}

# Log <Message> once until a healthy pass clears it. A failed log must not
# end the loop.
function Write-ErrorOnce($Ctx, [string]$Message) {
    if ($Message -eq $Ctx.LastError) { return }
    $Ctx.LastError = $Message
    try { Write-Log "Error: $Message" } catch { }
}

# Log once that observation <Obs> reports the current scale outside Windows'
# own range: custom scaling is on (phase C), and no set takes effect.
# Logged again only after an observation in range. Never throws.
function Write-RangeOnce($Ctx, $Obs) {
    if ($Obs.CurRel -ge $Obs.MinRel -and $Obs.CurRel -le $Obs.MaxRel) { $Ctx.RangeLogged = $false; return }
    if ($Ctx.RangeLogged) { return }
    try {
        Write-Log "Windows reports the current scale out of range (curScaleRel $($Obs.CurRel)). Custom scaling is probably on (Settings > System > Display); Lanai's scale has no effect until it is off."
        $Ctx.RangeLogged = $true
    } catch { }
}

# One 250 ms tick of the main loop at time <Now> (ms): log the port's
# opening and errors once each; move queued lines to Lines (stamping
# LastArrival) and drain them once quiet; then, when a line is ready, the 2 s
# display poll is due, or the first-line wait just ended, run one
# Step-ScaleState pass and call SetScale for its action, then read the scale
# back (Confirm-ScaleSet). An out-of-range current scale and a capped target
# are logged once each, whether or not a set follows.
function Invoke-ScaleTick($Ctx, [double]$Now) {
    $s = $Ctx.State
    # Checked before the first open, so the first open is not "again".
    $portError = [string]$Ctx.Shared.PortError
    if ($portError -ne $Ctx.LoggedPortError) {
        try {
            if ($portError -ne '') { Write-Log "Error: $portError" }
            elseif ($Ctx.PortOpened) { Write-Log 'The scale port is open again.' }
        } catch { }
        $Ctx.LoggedPortError = $portError
    }
    if ($null -ne $Ctx.Shared.OpenedAt -and -not $Ctx.PortOpened) {
        $Ctx.PortOpened = $true
        $s.ReadyAt = [math]::Min($s.ReadyAt, $Ctx.Shared.OpenedAt + 3000)
        try { Write-Log 'The scale port is open.' } catch { }
    }
    $item = $null
    while ($Ctx.Queue.TryDequeue([ref]$item)) {
        $Ctx.Lines.Add($item)
        if ($null -eq $s.LastArrival -or $item.At -gt $s.LastArrival) { $s.LastArrival = $item.At }
    }
    $drained = Get-DrainedLine $Ctx.Lines.ToArray() $Now
    $line = $null
    if ($drained.Kind -ne 'wait') {
        $Ctx.Lines.Clear()
        if ($drained.Malformed -gt 0 -and -not $Ctx.MalformedLogged) {
            $Ctx.MalformedLogged = $true
            try { Write-Log 'Dropped a malformed line from the scale channel.' } catch { }
        }
        if ($drained.Kind -eq 'stale') {
            try { Write-Log "Dropped $($drained.Valid) lines that arrived together; the next line comes within 2 seconds." } catch { }
        }
        if ($drained.Kind -eq 'line') { $line = $drained.Line }
    }
    if ($null -eq $line -and $Now -lt $Ctx.NextObserve -and ($s.Ready -or $Now -lt (Get-ReadyAt $s))) { return }
    $Ctx.NextObserve = $Now + 2000
    $obs = $null
    $failed = $false
    try {
        $obs = Get-DisplayObservation
        Write-RangeOnce $Ctx $obs
        $r = Step-ScaleState $s $obs $line $Now
    }
    catch {
        Write-ErrorOnce $Ctx $_.Exception.Message
        $failed = $true
        $obs = $null
        $r = Step-ScaleState $s $null $line $Now
    }
    $Ctx.State = $r.State
    try {
        if ($null -ne $line -and $null -ne $s.LastSave -and $r.State.LastSave -ne $s.LastSave) {
            Write-Log "Scale save $($line.Save): target $(StepName $line.Step)."
        }
        if ($null -ne $r.State.Pick -and $r.State.Pick -ne $s.Pick) {
            Write-Log "Pick: $(StepName $r.State.Pick) chosen in Windows; it holds until the next scale save."
        }
        if ($null -ne $r.Target) {
            $cap = Get-CapLine $r.Target $obs
            if ($cap -ne '' -and $cap -ne $Ctx.LoggedCap) { Write-Log $cap }
            $Ctx.LoggedCap = $cap
        }
        if ($r.Action -eq 'set') {
            $text = "Display '{0}' at {1}: raw minScaleRel {2}, curScaleRel {3}, maxScaleRel {4}; recommended {5}, current {6}, applying {7}" -f `
                $obs.Name, $obs.Resolution, $obs.MinRel, $obs.CurRel, $obs.MaxRel,
                (StepName $obs.Recommended), (StepName $obs.Current), (StepName $r.Step)
            if ($text -ne $Ctx.LoggedSet) { Write-Log $text }
            $Ctx.LoggedSet = $text
        }
    } catch { } # A failed log must not prevent the scale attempt.
    if ($r.Action -ne 'none') {
        try {
            [LanaiDisplay]::SetScale($obs.Path, $r.Relative)
            $Ctx.State = Confirm-ScaleSet $Ctx.State $r.Step ([LanaiDisplay]::GetScale($obs.Path))
        }
        catch {
            Write-ErrorOnce $Ctx $_.Exception.Message
            $failed = $true
            # Ask again at the next poll. The error is logged once
            # (Write-ErrorOnce), and the same applying line only once.
            $Ctx.State.Pending = $null
            $Ctx.State.NextRetry = 0
        }
    }
    # An error is logged again only after a pass in which nothing failed.
    if (-not $failed) { $Ctx.LastError = '' }
}

# Frame the port's bytes into lines: <Partial> is the unfinished line
# carried from the last read, <Chunk> the new text. Returns the complete
# Lines (CR trimmed) and the new Partial. Lanai's lines are short, so a
# Partial over 256 characters is dropped.
function Split-PortChunk {
    param([string]$Partial, [string]$Chunk)
    $parts = ($Partial + $Chunk).Split("`n")
    $lines = @()
    for ($i = 0; $i -lt $parts.Count - 1; $i++) { $lines += , $parts[$i].TrimEnd("`r") }
    $rest = $parts[$parts.Count - 1]
    if ($rest.Length -gt 256) { $rest = '' }
    return [pscustomobject]@{ Lines = $lines; Partial = $rest }
}

# Return $true when read error <Err> (or one it wraps) is
# ERROR_NO_SYSTEM_RESOURCES (1450, HResult 0x800705AA): what a read gets
# while no host is connected (phase 0 proof 3), so read again later. Any
# other error means the handle broke (a device reset, a resume): reopen.
function Test-PortIdle {
    param($Err)
    for ($e = $Err; $null -ne $e; $e = $e.InnerException) {
        if ($e.HResult -eq -2147023446) { return $true }
    }
    return $false
}

# The text of the functions the reader runspace calls: a runspace has its
# own function table.
function Get-ReaderFunctions {
    return (@('Split-PortChunk', 'Test-PortIdle') | ForEach-Object {
            "function $_ {`n$((Get-Item "function:$_").ScriptBlock)`n}"
        }) -join "`n"
}

# The reader runspace's loop: open the port with CreateFile (a FileStream
# cannot open a \\.\ path in PowerShell 5.1), stamp $Shared.OpenedAt once,
# and queue each complete line with its arrival time. The handle stays open
# across the feed's connects: a 0-byte read or error 1450 (no host
# connected) reads again after 250 ms. Any other read error closes the
# handle, and a failed open is retried every 2 s. Open and read errors go to
# $Shared.PortError for the main loop to log.
$ReaderScript = {
    param($Queue, $Shared, $Clock, $PortName, $Functions)
    . ([scriptblock]::Create($Functions))
    $handle = $null
    $stream = $null
    $buf = New-Object byte[] 4096
    $partial = ''
    while ($true) {
        try {
            if ($null -eq $handle) {
                $err = 0
                $handle = [LanaiPort]::Open($PortName, [ref]$err)
                if ($handle.IsInvalid) {
                    $handle = $null
                    $Shared.PortError = "Cannot open the scale port: $((New-Object ComponentModel.Win32Exception $err).Message) (error $err)"
                    Start-Sleep -Seconds 2
                    continue
                }
                $stream = New-Object IO.FileStream($handle, [IO.FileAccess]::Read, 4096, $false)
                $partial = ''
                $Shared.PortError = ''
                if ($null -eq $Shared.OpenedAt) { $Shared.OpenedAt = $Clock.Elapsed.TotalMilliseconds }
            }
            $n = 0
            try { $n = $stream.Read($buf, 0, $buf.Length) }
            catch {
                if (-not (Test-PortIdle $_.Exception)) {
                    $Shared.PortError = "Reading the scale port failed: $($_.Exception.Message)"
                    $stream.Dispose()
                    $handle = $null
                }
            }
            if ($n -le 0) { Start-Sleep -Milliseconds 250; continue }
            $now = $Clock.Elapsed.TotalMilliseconds
            $r = Split-PortChunk $partial ([Text.Encoding]::ASCII.GetString($buf, 0, $n))
            $partial = $r.Partial
            foreach ($l in $r.Lines) { $Queue.Enqueue([pscustomobject]@{ Text = $l; At = $now }) }
        }
        catch {
            # Close whatever is open, so a throw after the open (such as the
            # FileStream constructor) opens the port again.
            $Shared.PortError = "The scale port reader failed: $($_.Exception.Message)"
            if ($null -ne $stream) { $stream.Dispose() } elseif ($null -ne $handle) { $handle.Dispose() }
            $stream = $null
            $handle = $null
            Start-Sleep -Seconds 2
        }
    }
}

# The display configuration API from user32.dll and CreateFile for the
# scale port. DPI_GET and DPI_SET use the undocumented device info types -3 and -4, which the
# Settings app uses for "Scale"; their scale fields count steps relative to
# the recommended one. Windows PowerShell 5.1 compiles C# 5 only: no
# interpolated strings, ?., nameof or out var.
Add-Type -TypeDefinition @'
using System;
using System.Runtime.InteropServices;
using Microsoft.Win32.SafeHandles;

public static class LanaiPort {
    [DllImport("kernel32.dll", SetLastError = true, CharSet = CharSet.Unicode)]
    private static extern SafeFileHandle CreateFile(string name, uint access, uint share,
        IntPtr security, uint disposition, uint flags, IntPtr template);

    // Open a port for reading (GENERIC_READ, OPEN_EXISTING). On failure the
    // handle is invalid and error holds the Win32 error.
    public static SafeFileHandle Open(string name, out int error) {
        SafeFileHandle h = CreateFile(name, 0x80000000, 0, IntPtr.Zero, 3, 0, IntPtr.Zero);
        error = h.IsInvalid ? Marshal.GetLastWin32Error() : 0;
        return h;
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
        $baseline = Get-OemBaseline @((Get-CimInstance -ClassName Win32_ComputerSystem).OEMStringArray)
        if ($null -eq $baseline) {
            # Not Lanai's VM (spec 4): change nothing and keep nothing running.
            Write-ExitLog 'No lanai-scale OEM string; the scale stays as it is.'
            exit 0
        }
        $Scale = $baseline.Scale
        $save = $baseline.Save
    }
    $want = [array]::IndexOf($Steps, $Scale)
    if ($want -lt 0) { throw "Scale $Scale is not a Windows scale step ($($Steps -join ', '))" }

    $clock = [Diagnostics.Stopwatch]::StartNew()
    $queue = New-Object 'System.Collections.Concurrent.ConcurrentQueue[object]'
    $shared = [hashtable]::Synchronized(@{ OpenedAt = $null; PortError = '' })
    $reader = [PowerShell]::Create()
    $reader.AddScript($ReaderScript).AddArgument($queue).AddArgument($shared).AddArgument($clock).AddArgument($PortName).AddArgument((Get-ReaderFunctions)) | Out-Null
    $reader.BeginInvoke() | Out-Null
    $ctx = New-ScaleContext (New-ScaleState $want $save 0) $queue $shared
    while ($true) {
        Invoke-ScaleTick $ctx $clock.Elapsed.TotalMilliseconds
        Start-Sleep -Milliseconds 250
    }
}
catch {
    Write-ExitLog "Error: $($_.Exception.Message)"
    exit 1
}
