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

  The feed also sends the exact line "lanai-display-restart" when the
  Looking Glass client sees no frame from Windows for 10 s (Lanai,
  docs/plugin/resize-hang/plan.md, requirements 12 and 13). The task then
  starts this script again with -DisplayRestart, in a child process it stops
  after 45 s with the processes the child started, at most once a minute and
  never while the last child or any pnputil.exe still runs. The child restarts the Looking Glass
  display adapter only when the driver's own log shows the hang: an
  unfinished monitor replug, the same one in two reads 10 s apart. A size the
  driver refuses on a still desktop also sends no frame, and its log shows
  no unfinished replug.

  The task also guards against the driver's memory leak (Lanai,
  docs/plugin/resize-hang/plan.md, part E): each monitor replug leaves about
  one old swap chain's buffers in the driver's host process until the driver
  restarts. A collector runspace reads the driver's GPU memory and Windows'
  free commit every 10 s. Over 1/8 of the VM's memory (at least 1 GiB), the
  task restarts the adapter once Windows has had no keyboard or mouse input
  for 5 minutes, at most once in 30 minutes; over twice that, or over 512 MiB
  with under 4 GiB of commit free, at once. It starts this script with
  -LeakRestart, under the same child rules. A restart that does not free the
  memory, or three failed ones in a row, stop the guard until the task
  starts again.

  The scale task runs C:\Program Files\Lanai\lanai-start.exe, a windowless
  program setup builds from lanai-start.cs. It starts this script in a
  hidden powershell.exe, in a job that ends the script when the program
  ends, and runs the sign-in step itself (its log is lanai-signin.log).

.PARAMETER Scale
  Use this percentage instead of the SMBIOS string. For testing.

.PARAMETER DisplayRestart
  Check the driver's log for the hang and, when it shows one, restart the
  Looking Glass display adapter, then exit. The scale task starts this.

.PARAMETER LeakRestart
  Restart the Looking Glass display adapter to free the driver's leaked
  memory, with no log check, then exit. The scale task starts this.

.EXAMPLE
  powershell -ExecutionPolicy Bypass -File lanai-scale.ps1
  powershell -ExecutionPolicy Bypass -File lanai-scale.ps1 -Scale 250
#>
param([int]$Scale = 0, [switch]$DisplayRestart, [switch]$LeakRestart)

$ErrorActionPreference = 'Stop'

# The task runs elevated with the user's environment, so nothing it loads
# may come from a folder that user can write: the system module folders
# only, and Add-Type's compiler files in Lanai's own administrator-only
# folder. Set before the first cmdlet or Add-Type. As in setup's build,
# LIB (the compiler's search path for references) is cleared and PATH is
# the system folder only. Add-Type runs the compiler in this process's
# working folder, which lanai-start.exe sets to Lanai's folder when it
# starts the script. Set-Location would not change it: it moves only
# PowerShell's own location.
$env:PSModulePath = "$([Environment]::SystemDirectory)\WindowsPowerShell\v1.0\Modules;C:\Program Files\WindowsPowerShell\Modules"
$env:TMP = 'C:\Program Files\Lanai\tmp'
$env:TEMP = 'C:\Program Files\Lanai\tmp'
$env:LIB = $null
$env:PATH = [Environment]::SystemDirectory
$LogFile = 'C:\Program Files\Lanai\lanai-scale.log'

# Windows' scale steps, in order. The index of a step is what the relative
# DPI calls count in.
$Steps = @(100, 125, 150, 175, 200, 225, 250, 300, 350, 400, 450, 500)

# The scale channel's port, as Windows names it.
$PortName = '\\.\Global\io.lanai.scale.0'

# The display driver's log (requirement 13). The driver starts a new file at
# each start and keeps writing it.
$IddLog = Join-Path ([Environment]::GetFolderPath('CommonApplicationData')) 'Looking Glass (IDD)\looking-glass-idd.txt'

# Write a line to the console and to the log file.
function Write-Log([string]$Message) {
    Add-Content -Path $LogFile -Value "$(Get-Date -Format o) $Message"
    Write-Output $Message
}

# Log <Message> on the way out, unless the log's last line already carries
# it: the sign-in trigger starts the task every 5 minutes, and a start that
# ends the same way as the one before must not grow the log. An unreadable
# log counts as a different last line. A write that meets another writer
# (the task or a restart child) is tried again, 5 times in all: phase 3 lost
# a restart child's error line while Windows was out of memory.
function Write-ExitLog([string]$Message) {
    $last = $null
    try { $last = Get-Content -LiteralPath $LogFile -Tail 1 -ErrorAction Stop } catch { }
    if ("$last" -cmatch '^\S+ (.*)$' -and $Matches[1] -ceq $Message) { Write-Output $Message; return }
    for ($i = 0; $i -lt 5; $i++) {
        try { Write-Log $Message; return } catch { Start-Sleep -Milliseconds 100 }
    }
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

# Return $true for the exact display restart line, and nothing longer or
# different.
function Test-RestartLine([string]$Line) {
    return $Line -ceq 'lanai-display-restart'
}

# Decide what a batch of queued lines ({Text; At} in ms) means at time
# <Now>: Kind "wait" while a line came less than 300 ms ago (a backlog
# arrives at full speed, so a quiet gap means it is drained); else "line"
# with the one valid scale line, "stale" for two or more (after a stall the
# port delivers its oldest lines, phase 0 proof 4), or "none". Restart lines
# are a separate kind: Restart counts them, and any number make one
# restart. Empty lines are ignored; malformed ones are counted in Malformed
# and dropped. Valid counts the valid scale lines.
function Get-DrainedLine([object[]]$Lines, [double]$Now) {
    $last = $null
    foreach ($l in $Lines) { if ($null -eq $last -or $l.At -gt $last) { $last = $l.At } }
    if ($null -ne $last -and $Now - $last -lt 300) {
        return [pscustomobject]@{ Kind = 'wait'; Line = $null; Malformed = 0; Valid = 0; Restart = 0 }
    }
    $valid = @()
    $bad = 0
    $restart = 0
    foreach ($l in $Lines) {
        if ($l.Text -eq '') { continue }
        if (Test-RestartLine $l.Text) { $restart++; continue }
        $p = ConvertFrom-ScaleLine $l.Text
        if ($null -eq $p) { $bad++ } else { $valid += , $p }
    }
    $kind = 'none'
    if ($valid.Count -gt 1) { $kind = 'stale' } elseif ($valid.Count -eq 1) { $kind = 'line' }
    $line = $null
    if ($kind -eq 'line') { $line = $valid[0] }
    return [pscustomobject]@{ Kind = $kind; Line = $line; Malformed = $bad; Valid = $valid.Count; Restart = $restart }
}

# --- the display restart (requirement 13) ---

# Read the last <Max> bytes of the driver's log at <Path>, opened for shared
# read and write, since the driver keeps it open. Returns the file's Size,
# the tail's Start offset and its Bytes. Throws when the log cannot be read.
function Read-IddTail([string]$Path, [long]$Max = 1048576) {
    $f = [IO.File]::Open($Path, [IO.FileMode]::Open, [IO.FileAccess]::Read,
        [IO.FileShare]::ReadWrite -bor [IO.FileShare]::Delete)
    try {
        $size = $f.Length
        $start = [math]::Max([long]0, $size - $Max)
        $f.Position = $start
        $bytes = New-Object byte[] ($size - $start)
        $got = 0
        while ($got -lt $bytes.Length) {
            $n = $f.Read($bytes, $got, $bytes.Length - $got)
            if ($n -le 0) { break }
            $got += $n
        }
        if ($got -lt $bytes.Length) { [Array]::Resize([ref]$bytes, $got) }
        return [pscustomobject]@{ Size = $size; Start = $start; Bytes = $bytes }
    }
    finally { $f.Dispose() }
}

# Find the unfinished replug in a tail of the driver's log: <Bytes> read from
# file offset <Start>. Only complete lines count: the first line of a tail
# that starts inside the file may be cut, and a last line with no newline
# may be half written. The candidate is the last line from
# CMonitorManager::Replug that ends "| ReplugMonitor", with no later line
# that ends "| Swap chain device set" (the new monitor is ready) or holds
# "IddCxMonitorDeparture Failed" (the driver kept the old monitor and stays
# healthy). Returns its file Offset, or $null and the Reason there is none.
function Find-ReplugCandidate([byte[]]$Bytes, [long]$Start) {
    $offset = $null
    $reason = 'no ReplugMonitor line in the driver log'
    $pos = 0
    $skip = $Start -gt 0
    while ($pos -lt $Bytes.Length) {
        $nl = [Array]::IndexOf($Bytes, [byte]10, $pos)
        if ($nl -lt 0) { break }
        if ($skip) {
            $skip = $false
        }
        else {
            $text = [Text.Encoding]::ASCII.GetString($Bytes, $pos, $nl - $pos).TrimEnd("`r")
            if ($text.Contains('CMonitorManager::Replug') -and $text.EndsWith('| ReplugMonitor')) {
                $offset = $Start + $pos
            }
            elseif ($null -ne $offset -and $text.EndsWith('| Swap chain device set')) {
                $offset = $null
                $reason = 'the last replug finished'
            }
            elseif ($null -ne $offset -and $text.Contains('IddCxMonitorDeparture Failed')) {
                $offset = $null
                $reason = 'the last replug kept the old monitor'
            }
        }
        $pos = $nl + 1
    }
    return [pscustomobject]@{ Offset = $offset; Reason = $reason }
}

# Confirm the hang from the driver's log at <Path>: the same unfinished
# replug at the same offset in two reads, with <Pause> (10 s by a monotonic
# timer, Wait-Monotonic) between them. Returns '' for a hang, or the reason
# it is not confirmed.
function Test-DisplayHang([string]$Path, [scriptblock]$Pause, [long]$Max = 1048576) {
    try { $a = Read-IddTail $Path $Max } catch { return 'the driver log cannot be read' }
    $first = Find-ReplugCandidate $a.Bytes $a.Start
    if ($null -eq $first.Offset) { return $first.Reason }
    & $Pause
    try { $b = Read-IddTail $Path $Max } catch { return 'the driver log cannot be read' }
    if ($b.Size -lt $a.Size) { return 'the driver log shrank between the reads' }
    $second = Find-ReplugCandidate $b.Bytes $b.Start
    if ($null -eq $second.Offset) { return $second.Reason }
    if ($second.Offset -ne $first.Offset) { return 'a new replug started between the reads' }
    return ''
}

# Wait <Ms> milliseconds by a Stopwatch, which a clock change cannot move.
function Wait-Monotonic([int]$Ms) {
    $w = [Diagnostics.Stopwatch]::StartNew()
    while ($w.ElapsedMilliseconds -lt $Ms) { Start-Sleep -Milliseconds 250 }
}

# Pick the Looking Glass display adapter from <Devices> (present devices,
# each with InstanceId and HardwareID): the one whose hardware IDs hold
# Root\LGIdd, in any case, the same on every install. Its instance ID is
# not, so it is read each time. Returns its InstanceId, or $null and the
# Reason when none or several match.
function Select-LgAdapter([object[]]$Devices) {
    $found = @($Devices | Where-Object { $null -ne $_ -and @($_.HardwareID | Where-Object { $_ -ieq 'Root\LGIdd' }).Count -gt 0 })
    if ($found.Count -eq 1) { return [pscustomobject]@{ InstanceId = [string]$found[0].InstanceId; Reason = '' } }
    return [pscustomobject]@{ InstanceId = $null; Reason = "found $($found.Count) Looking Glass display adapters, not one" }
}

# The present devices, for Select-LgAdapter.
function Get-LgDevices {
    return @(Get-PnpDevice -PresentOnly | Select-Object InstanceId, HardwareID)
}

# Restart device <InstanceId> with pnputil, the ID as one argument, and
# return pnputil's exit code.
function Invoke-PnpUtil([string]$InstanceId) {
    & (Join-Path ([Environment]::SystemDirectory) 'pnputil.exe') '/restart-device' $InstanceId | Out-Null
    return $LASTEXITCODE
}

# Log <Message> from the restart child. The task writes the same log, so a
# write that meets the task's is tried again; a failed log never stops the
# restart.
function Write-RestartLog([string]$Message) {
    for ($i = 0; $i -lt 5; $i++) {
        try { Write-Log $Message | Out-Null; return } catch { Start-Sleep -Milliseconds 100 }
    }
}

# The restart child (-DisplayRestart): confirm the hang from the driver log
# at <Path>, then restart the one Looking Glass display adapter. Logs the
# outcome and returns the exit code: 0 for no restart or a restart that
# worked, else pnputil's code (3010 means Windows needs a restart to finish),
# or 2 when no single adapter matches. The host's next send is the retry.
function Invoke-DisplayRestart([string]$Path, [scriptblock]$Pause) {
    $why = Test-DisplayHang $Path $Pause
    if ($why -ne '') {
        Write-RestartLog "Display hang not confirmed ($why); no restart."
        return 0
    }
    return Restart-LgAdapter 'Display hang confirmed'
}

# The leak child (-LeakRestart): restart the one Looking Glass display
# adapter to free the driver's leaked memory, with no log check. Returns as
# Invoke-DisplayRestart does.
function Invoke-LeakRestart {
    return Restart-LgAdapter 'The display driver holds too much memory'
}

# Restart the one Looking Glass display adapter, logging <Why> first.
# Returns pnputil's exit code, or 2 when no single adapter matches.
function Restart-LgAdapter([string]$Why) {
    $sel = Select-LgAdapter @(Get-LgDevices)
    if ($null -eq $sel.InstanceId) {
        Write-RestartLog "$Why, but Lanai $($sel.Reason); no restart."
        return 2
    }
    Write-RestartLog "$Why; restarting the Looking Glass display adapter $($sel.InstanceId)."
    $code = Invoke-PnpUtil $sel.InstanceId
    if ($code -eq 0) { Write-RestartLog 'The display adapter restarted (pnputil exit 0).' }
    elseif ($code -eq 3010) { Write-RestartLog 'pnputil exit 3010: Windows needs a restart to finish restarting the display adapter.' }
    else { Write-RestartLog "pnputil could not restart the display adapter (exit $code)." }
    return $code
}

# Start a restart child: this script with <Switch> (-DisplayRestart or
# -LeakRestart), in a hidden powershell.exe by its absolute path, in Lanai's
# folder as the task. It runs in the start program's job, so it ends with the task.
# Reading Handle at once keeps the process open, so ExitCode is still known
# after the child exits.
function Start-DisplayRestart([string]$Switch = '-DisplayRestart') {
    $ps = Join-Path ([Environment]::SystemDirectory) 'WindowsPowerShell\v1.0\powershell.exe'
    $p = Start-Process -FilePath $ps -WorkingDirectory $PSScriptRoot -WindowStyle Hidden -PassThru `
        -ArgumentList @('-NoProfile', '-NonInteractive', '-ExecutionPolicy', 'Bypass', '-File', "`"$PSCommandPath`"", $Switch)
    $null = $p.Handle
    return $p
}

# Stop process <Id> and every process it started (its pnputil), with
# taskkill /T /F while the child still lives to name them.
function Stop-ProcessTree([int]$Id) {
    & (Join-Path ([Environment]::SystemDirectory) 'taskkill.exe') '/PID' $Id '/T' '/F' 2>&1 | Out-Null
}

# True when any pnputil.exe runs, such as one a stopped child left behind.
function Test-PnpUtilRunning {
    return $null -ne (Get-Process -Name pnputil -ErrorAction SilentlyContinue)
}

# One tick of the restart handling at <Now> (ms), with <Requests> restart
# lines in the batch just drained. A child that runs 45 s is stopped with
# the processes it started, so it never holds the display; one that exited
# with an error is logged. A request starts a child at most once a minute,
# and never while the last child or any pnputil still runs: a stopped child
# stays known until it has exited. Any other request does nothing. Never
# throws.
function Step-DisplayRestart($Ctx, [double]$Now, [int]$Requests) {
    try {
        if ($null -ne $Ctx.Restart) {
            if ($Ctx.Restart.HasExited) {
                $code = $Ctx.Restart.ExitCode
                $failed = $Ctx.RestartStopped -or $code -ne 0
                $leak = $Ctx.RestartKind -eq 'leak'
                $stopped = $Ctx.RestartStopped
                $Ctx.Restart = $null
                $Ctx.RestartKind = $null
                $Ctx.RestartStopped = $false
                if ($leak) { Complete-LeakChild $Ctx $Now $failed }
                if (-not $stopped -and $code -ne 0) { Write-Log "The display restart ended with exit code $code." }
            }
            elseif (-not $Ctx.RestartStopped -and $Now - $Ctx.RestartAt -ge 45000) {
                # Stop first: the log write can fail, as the child writes the same log.
                $Ctx.RestartStopped = $true
                try { & $Ctx.StopRestart $Ctx.Restart.Id } catch { }
                try { Write-Log 'The display restart ran for 45 s; Lanai stopped it.' } catch { }
            }
        }
        if ($Requests -le 0) { return }
        if ($null -ne $Ctx.RestartAt -and $Now - $Ctx.RestartAt -lt 60000) {
            Write-Log 'Lanai asked to restart the display again within a minute; no restart.'
            return
        }
        if ($null -ne $Ctx.Restart -or (& $Ctx.PnpRunning)) {
            Write-Log 'Lanai asked to restart the display while the last restart still runs; no restart.'
            return
        }
        $Ctx.RestartAt = $Now
        $Ctx.RestartKind = 'hang'
        Write-Log 'Lanai sees no picture from Windows and asks to restart the display; checking the driver log.'
        $Ctx.Restart = & $Ctx.StartRestart
    }
    catch {
        Write-ErrorOnce $Ctx "The display restart did not start: $($_.Exception.Message)"
    }
}

# --- The leak guard (docs/plugin/resize-hang/plan.md, part E) ---

# The limit for a VM with <Ram> bytes of memory: 1/8 of it, at least 1 GiB.
function Get-LeakLimit([uint64]$Ram) {
    $l = [uint64][math]::Floor($Ram / 8)
    if ($l -lt [uint64]1GB) { $l = [uint64]1GB }
    return $l
}

# Milliseconds from tick <Last> to tick <Now>, both 32-bit tick counts, so
# the wrap after 49.7 days does not break it.
function Get-IdleSpan([uint32]$Now, [uint32]$Last) {
    return [uint32](([long]$Now - [long]$Last + 4294967296) % 4294967296)
}

# Milliseconds since the last keyboard or mouse input in this session. The
# last input is read first: input between the two reads then makes the span
# short, not 49.7 days. The readers are parameters for the tests.
function Get-IdleMs($LastInput = { [LanaiGuard]::LastInput() }, $Ticks = { [LanaiGuard]::Ticks() }) {
    $last = & $LastInput
    $now = & $Ticks
    return Get-IdleSpan $now $last
}

# The guard's state: the limit (set at start from the VM's memory), whether
# it stopped, the last guard restart's start (task clock, ms), failed guard
# children in a row, the restart awaiting its freed check, the last sample a
# routine decision used, and the no-sample log state.
function New-LeakGuard {
    return @{
        Limit = [uint64]1GB; Off = $false; LastAt = $null; Failures = 0; Verify = $null
        SeenAt = $null; LastUsable = $null; NoSampleLogged = $false
    }
}

# Stop the guard until the scale script starts again, logging <Why> once.
function Stop-LeakGuard($Guard, [string]$Why) {
    $Guard.Off = $true
    try { Write-Log "$Why The leak guard stops until the scale task starts again." } catch { }
}

# Count a guard child that restarted nothing; three in a row stop the guard.
function Add-LeakFailure($Guard) {
    $Guard.Failures++
    if ($Guard.Failures -ge 3) { Stop-LeakGuard $Guard 'Three display driver restarts for memory failed in a row.' }
}

# The supervision's report on a guard child at <Now>: <Failed> when it was
# stopped at 45 s or exited nonzero, else its freed check starts.
function Complete-LeakChild($Ctx, [double]$Now, [bool]$Failed) {
    $g = $Ctx.Guard
    if ($Failed) { Add-LeakFailure $g; return }
    $g.Verify = @{ ExitAt = $Now; Trigger = $g.Trigger; HostId = $g.TriggerHost; HostStart = $g.TriggerStart }
}

# One tick of the guard at <Now> (ms), on the collector's latest sample
# ($Ctx.Shared.Leak; used only under 30 s old). First a restart's freed
# check: the first usable sample taken after the child exited decides, and
# it must be taken within 60 s of the exit. Freed is a new host process, or a measure under
# half the trigger or under 512 MiB, whichever is larger. Then the decision:
# an emergency (over twice the limit, or over 512 MiB with under 4 GiB of
# commit free) at any tick the child rules allow; a routine restart (over the
# limit, 5 minutes with no input, 30 minutes after the last guard restart)
# only on a sample it has not judged before. Never throws.
function Step-LeakGuard($Ctx, [double]$Now) {
    $g = $Ctx.Guard
    if ($g.Off) { return }
    try {
        $s = $Ctx.Shared.Leak
        $usable = $null -ne $s -and $Now - $s.At -le 30000
        if ($null -eq $g.LastUsable) { $g.LastUsable = $Now }
        if ($usable) { $g.LastUsable = $Now; $g.NoSampleLogged = $false }
        elseif (-not $g.NoSampleLogged -and $Now - $g.LastUsable -ge 300000) {
            $g.NoSampleLogged = $true
            try { Write-Log "The display driver's memory has had no reading for 5 minutes; the leak guard waits for one." } catch { }
        }
        if ($null -ne $g.Verify) {
            if ($usable -and $s.At -gt $g.Verify.ExitAt -and $s.At -le $g.Verify.ExitAt + 60000) {
                $v = $g.Verify
                $g.Verify = $null
                $g.SeenAt = $s.At
                $floor = [math]::Max([double]$v.Trigger / 2, [double]512MB)
                if ($s.HostId -ne $v.HostId -or $s.HostStart -ne $v.HostStart -or [double]$s.Bytes -lt $floor) {
                    $g.Failures = 0
                    try { Write-Log "The display driver restart freed its memory: it holds $([int]($s.Bytes / 1MB)) MB." } catch { }
                }
                else {
                    Stop-LeakGuard $g "The display driver restart did not free its memory: it holds $([int]($s.Bytes / 1MB)) MB, against $([int]($v.Trigger / 1MB)) MB before."
                }
                return
            }
            if ($Now - $g.Verify.ExitAt -le 60000) { return }
            $g.Verify = $null
            Add-LeakFailure $g
            if ($g.Off) { return }
        }
        if (-not $usable) { return }
        $kind = $null
        $idle = $null
        if ($s.Bytes -gt 2 * $g.Limit -or ($s.Bytes -gt [uint64]512MB -and $s.FreeCommit -lt [uint64]4GB)) { $kind = 'emergency' }
        elseif ($s.Bytes -gt $g.Limit -and $s.At -ne $g.SeenAt) {
            $g.SeenAt = $s.At
            $idle = & $Ctx.IdleMs
            if ($idle -ge 300000 -and ($null -eq $g.LastAt -or $Now - $g.LastAt -ge 1800000)) { $kind = 'routine' }
        }
        if ($null -eq $kind) { return }
        # The child rules, shared with the hang restart (Step-DisplayRestart).
        if ($null -ne $Ctx.Restart -or ($null -ne $Ctx.RestartAt -and $Now - $Ctx.RestartAt -lt 60000) -or (& $Ctx.PnpRunning)) { return }
        # An emergency ignores input, so a failed idle read only changes its log line.
        if ($null -eq $idle) { try { $idle = & $Ctx.IdleMs } catch { } }
        $quiet = if ($null -eq $idle) { 'the input time could not be read' } else { "no input came for $([int][math]::Floor($idle / 60000)) minutes" }
        $Ctx.RestartAt = $Now
        $Ctx.RestartKind = 'leak'
        $g.LastAt = $Now
        $g.Trigger = $s.Bytes
        $g.TriggerHost = $s.HostId
        $g.TriggerStart = $s.HostStart
        try {
            Write-Log ("Restarting the display driver to free its memory ({0}): it holds {1} MB (limit {2} MB), Windows has {3} MB of commit free, and {4}." -f `
                    $kind, [int]($s.Bytes / 1MB), [int]($g.Limit / 1MB), [int]($s.FreeCommit / 1MB), $quiet)
        } catch { }
        $Ctx.Restart = & $Ctx.StartLeakRestart
    }
    catch {
        Write-ErrorOnce $Ctx "The leak guard failed: $($_.Exception.Message)"
    }
}

# --- The collector's reads (run in the collector runspace) ---

# The WQL filter for process <Id>'s GPU memory rows. _ alone matches any
# character in WQL, so each is escaped: pid_12_ must not take pid_123_.
function Get-LgRowFilter([int]$Id) {
    return "Name LIKE 'pid[_]$Id[_]%'"
}

# The processes named WUDFHost, each with its ID, start time, program path
# and owner (an account SID). Any user can start a program by that name, or
# the real one; Select-LgHost checks the owner and the path. A process that
# ends during the read is skipped.
function Get-WudfHosts {
    return @(Get-Process -Name WUDFHost -IncludeUserName -ErrorAction SilentlyContinue | ForEach-Object {
            try {
                $owner = $null
                if ($_.UserName) { $owner = ([Security.Principal.NTAccount]$_.UserName).Translate([Security.Principal.SecurityIdentifier]).Value }
                [pscustomobject]@{ Id = $_.Id; Start = $_.StartTime.ToFileTimeUtc(); Path = $_.Path; Owner = $owner; Process = $_ }
            }
            catch { }
        })
}

# Whether <Path> is a file inside folder <Folder> (any case), with no ".."
# step that could climb out of it.
function Test-InFolder([string]$Path, [string]$Folder) {
    if ([string]::IsNullOrEmpty($Path) -or [string]::IsNullOrEmpty($Folder) -or $Path.Contains('..')) { return $false }
    return $Path.StartsWith($Folder.TrimEnd('\') + '\', [StringComparison]::OrdinalIgnoreCase)
}

# The modules host <P> has loaded. Reading them needs the task's admin rights.
function Get-HostModules($P) {
    return @($P.Process.Modules)
}

# Process <Id>'s rows of the GPU memory counters, by WMI's names, which stay
# the same in every Windows language.
function Get-LgGpuRows([int]$Id) {
    return @(Get-CimInstance -ClassName Win32_PerfRawData_GPUPerformanceCounters_GPUProcessMemory `
            -Filter (Get-LgRowFilter $Id) -OperationTimeoutSec 20 -ErrorAction Stop)
}

# Process <Id>'s start time now, or $null when it is gone.
function Get-HostStart([int]$Id) {
    try { return (Get-Process -Id $Id -ErrorAction Stop).StartTime.ToFileTimeUtc() } catch { return $null }
}

# Windows' free commit in bytes.
function Get-FreeCommit {
    return [LanaiGuard]::FreeCommit()
}

# The one host in <Hosts> that a service account (LocalSystem, LocalService
# or NetworkService, which no user can run as) runs from
# <System32>\WUDFHost.exe, with LGIdd.dll (any case) loaded from inside
# <System32>, or $null for none or several. A program a user runs, even the
# real WUDFHost.exe with a DLL of that name, is skipped before its modules
# are read, so it cannot hide the real host. A module read that fails throws.
function Select-LgHost([object[]]$Hosts, [string]$System32) {
    if ([string]::IsNullOrEmpty($System32)) { return $null }
    $exe = $System32.TrimEnd('\') + '\WUDFHost.exe'
    $found = @($Hosts | Where-Object { $_.Owner -in @('S-1-5-18', 'S-1-5-19', 'S-1-5-20') -and [string]$_.Path -ieq $exe } | Where-Object {
            @(Get-HostModules $_ | Where-Object { $_.ModuleName -ieq 'LGIdd.dll' -and (Test-InFolder ([string]$_.FileName) $System32) }).Count -gt 0
        })
    if ($found.Count -eq 1) { return $found[0] }
    return $null
}

# The sum of TotalCommitted over <Rows> named for process <Id>, or $null
# when there are none: no rows is no measure, not zero.
function Measure-LgRows([object[]]$Rows, [int]$Id) {
    $mine = @($Rows | Where-Object { $null -ne $_ -and ([string]$_.Name).StartsWith("pid_$($Id)_") })
    if ($mine.Count -eq 0) { return $null }
    $sum = [uint64]0
    foreach ($r in $mine) { $sum += [uint64]$r.TotalCommitted }
    return $sum
}

# One sample taken at <At> (task clock, ms): the driver's GPU memory, its
# host's ID and start time, and Windows' free commit. $null unless exactly
# one host has the driver (Select-LgHost, with Windows' System32 folder), it
# has rows, and the same process (ID and start time) still runs after the
# query; any failed read is $null too.
function Read-LeakSample([double]$At, [string]$System32 = [Environment]::GetFolderPath('System')) {
    try {
        $h = Select-LgHost @(Get-WudfHosts) $System32
        if ($null -eq $h) { return $null }
        $bytes = Measure-LgRows @(Get-LgGpuRows $h.Id) $h.Id
        if ($null -eq $bytes) { return $null }
        $start = Get-HostStart $h.Id
        if ($null -eq $start -or $start -ne $h.Start) { return $null }
        return [pscustomobject]@{ At = $At; Bytes = [uint64]$bytes; FreeCommit = [uint64](Get-FreeCommit); HostId = $h.Id; HostStart = $h.Start }
    }
    catch { return $null }
}

# The text of the functions the collector runspace calls.
function Get-CollectorFunctions {
    return (@('Read-LeakSample', 'Select-LgHost', 'Measure-LgRows', 'Get-LgRowFilter', 'Get-WudfHosts',
            'Get-HostModules', 'Get-LgGpuRows', 'Get-HostStart', 'Get-FreeCommit', 'Test-InFolder') | ForEach-Object {
            "function $_ {`n$((Get-Item "function:$_").ScriptBlock)`n}"
        }) -join "`n"
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
#   Restart      the restart child until it has exited, or $null
#   RestartStopped  whether Restart was stopped at 45 s
#   RestartAt    when the last child started (ms), or $null
#   RestartKind  'hang' or 'leak' for the running child, or $null
#   StartRestart starts a restart child (Start-DisplayRestart); tests swap it,
#                StopRestart (Stop-ProcessTree) and PnpRunning (Test-PnpUtilRunning)
#   Guard        the leak guard's state (New-LeakGuard); IdleMs gives the
#                idle time and StartLeakRestart starts a -LeakRestart child,
#                both swapped by tests
function New-ScaleContext($State, $Queue, $Shared) {
    return @{
        State = $State; Queue = $Queue; Shared = $Shared
        Lines = New-Object 'System.Collections.Generic.List[object]'
        NextObserve = 0; LastError = ''; LoggedPortError = ''; LoggedSet = ''; LoggedCap = ''
        RangeLogged = $false; PortOpened = $false; MalformedLogged = $false
        Restart = $null; RestartStopped = $false; RestartAt = $null; RestartKind = $null; StartRestart = { Start-DisplayRestart }
        StopRestart = { param($Id) Stop-ProcessTree $Id }; PnpRunning = { Test-PnpUtilRunning }
        Guard = (New-LeakGuard); IdleMs = { Get-IdleMs }; StartLeakRestart = { Start-DisplayRestart '-LeakRestart' }
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
# LastArrival) and drain them once quiet; hand the batch's restart lines to
# Step-DisplayRestart; then, when a line is ready, the 2 s
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
    Step-DisplayRestart $Ctx $Now $drained.Restart
    Step-LeakGuard $Ctx $Now
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

# The collector runspace's loop: a sample of the driver's memory every 10 s
# (Read-LeakSample), stamped on the task's clock, into $Shared.Leak for the
# main loop. A failed read posts nothing; the main loop's 30 s age limit
# drops what grows old.
$CollectorScript = {
    param($Shared, $Clock, $Functions)
    . ([scriptblock]::Create($Functions))
    while ($true) {
        $s = Read-LeakSample $Clock.Elapsed.TotalMilliseconds
        if ($null -ne $s) { $Shared.Leak = $s }
        Start-Sleep -Seconds 10
    }
}

# The restart children use none of the display API below, so they start
# here and skip the compile.
if ($DisplayRestart) {
    try { exit (Invoke-DisplayRestart $IddLog { Wait-Monotonic 10000 }) }
    catch { Write-ExitLog "Error: $($_.Exception.Message)"; exit 1 }
}
if ($LeakRestart) {
    try { exit (Invoke-LeakRestart) }
    catch { Write-ExitLog "Error: $($_.Exception.Message)"; exit 1 }
}

# The display configuration API from user32.dll and CreateFile for the
# scale port. DPI_GET and DPI_SET use the undocumented device info types
# -3 and -4, which the Settings app uses for "Scale"; their scale fields
# count steps relative to the recommended one. Windows PowerShell 5.1 compiles C# 5 only: no
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

// Memory and input for the leak guard: total memory and free commit from
// GlobalMemoryStatusEx, and the tick count and the session's last input
// tick for the idle time.
public static class LanaiGuard {
    [StructLayout(LayoutKind.Sequential)]
    private struct MemoryStatusEx {
        public uint dwLength; public uint dwMemoryLoad;
        public ulong ullTotalPhys; public ulong ullAvailPhys;
        public ulong ullTotalPageFile; public ulong ullAvailPageFile;
        public ulong ullTotalVirtual; public ulong ullAvailVirtual; public ulong ullAvailExtendedVirtual;
    }

    [StructLayout(LayoutKind.Sequential)]
    private struct LastInputInfo { public uint cbSize; public uint dwTime; }

    [DllImport("kernel32.dll", SetLastError = true)]
    private static extern bool GlobalMemoryStatusEx(ref MemoryStatusEx m);

    [DllImport("user32.dll")]
    private static extern bool GetLastInputInfo(ref LastInputInfo i);

    [DllImport("kernel32.dll")]
    private static extern uint GetTickCount();

    private static MemoryStatusEx Status() {
        MemoryStatusEx m = new MemoryStatusEx();
        m.dwLength = (uint)Marshal.SizeOf(typeof(MemoryStatusEx));
        if (!GlobalMemoryStatusEx(ref m)) throw new Exception("GlobalMemoryStatusEx failed: " + Marshal.GetLastWin32Error());
        return m;
    }

    public static ulong TotalPhys() { return Status().ullTotalPhys; }
    public static ulong FreeCommit() { return Status().ullAvailPageFile; }
    public static uint Ticks() { return GetTickCount(); }

    public static uint LastInput() {
        LastInputInfo i = new LastInputInfo();
        i.cbSize = (uint)Marshal.SizeOf(typeof(LastInputInfo));
        if (!GetLastInputInfo(ref i)) throw new Exception("GetLastInputInfo failed");
        return i.dwTime;
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
    $shared = [hashtable]::Synchronized(@{ OpenedAt = $null; PortError = ''; Leak = $null })
    $reader = [PowerShell]::Create()
    $reader.AddScript($ReaderScript).AddArgument($queue).AddArgument($shared).AddArgument($clock).AddArgument($PortName).AddArgument((Get-ReaderFunctions)) | Out-Null
    $reader.BeginInvoke() | Out-Null
    $ctx = New-ScaleContext (New-ScaleState $want $save 0) $queue $shared
    $ctx.Guard.Limit = Get-LeakLimit ([LanaiGuard]::TotalPhys())
    $collector = [PowerShell]::Create()
    $collector.AddScript($CollectorScript).AddArgument($shared).AddArgument($clock).AddArgument((Get-CollectorFunctions)) | Out-Null
    $collector.BeginInvoke() | Out-Null
    while ($true) {
        Invoke-ScaleTick $ctx $clock.Elapsed.TotalMilliseconds
        Start-Sleep -Milliseconds 250
    }
}
catch {
    Write-ExitLog "Error: $($_.Exception.Message)"
    exit 1
}
