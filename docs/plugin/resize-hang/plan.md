# Windows freezes after quick resizes

Combined spec and plan for three changes. The first is two new Looking Glass
client patches: `patches/looking-glass/0004-client-resize-settle.patch` changes
the resize module, and `0005-client-resize-feed.patch` feeds it from the client.
The second is a
recovery path: the client notices the hang, the host passes it on, and the scale
task in Windows restarts the Looking Glass display driver. The third is a guard
(part E): the scale task watches the driver's memory leak, which phase 3 found
behind every hang it forced, and restarts the driver before the leak fills
Windows' memory.

Status: design reviewed (three rounds), 2026-11-21. Phase 0 passed the same
day: a driver restart recovered 3 of 3 forced hangs. It also found two changes
for part C, which John accepted (decision 3): the scale task confirms the hang
from the driver log, and selects the adapter by hardware ID. A fourth, focused
review of those changes, approved by John past the three-round cap, found two
P2s, now integrated. Phases 1 (the client patches) and 2 (the host feed, the
scale task, the panel and the docs) are done and reviewed (three rounds).
Phase 3 step 1 passed on 2026-11-23: Lanai recovered 3 of 3 forced hangs with
no help. It also found the leak. John chose on 2026-11-23 to add the guard
(part E) and to report the leak upstream (decision 4). Part E passed three design
review rounds (reject, then approve with changes twice), all integrated.
Phase 4 (the guard's code) is done. Phase 5 passed on 2026-11-23 and 24,
including step 3's gate for the routine rule (both runs, with John at the
screen), so routine restarts stay on. The implementation review of phases 4
and 5 ran two rounds (Codex, then Opus), both approve with changes, all
fixed or logged below.

## Problem

Sometimes the Windows window freezes. The picture stops, the cursor may not draw,
and Windows itself keeps running: the guest agent answers, QEMU reports the VM
running, and the driver's heartbeat in shared memory keeps ticking. It happened
on John's desktop on 2026-11-19 and again on 2026-11-21, when a script forced it.

The reproduced trigger is two or more resizes of the window within a second or
two. Each resize that holds for 500 ms becomes an ask to Windows (the
window-size message). For each ask, the IDD unplugs its virtual monitor and
plugs in a new one with the new mode (a replug). Both freezes came on a replug
1 to 2 s after the previous one. Each time, the IDD stopped at a different step,
waiting for a Windows callback that never came, and the IDD's wait has no
timeout. So part A below is a mitigation whose
effect is still to be measured, and part C is the recovery.

Phase 3 found why Windows stops in the 2026-11-21 state (an unfinished
replug): the IDD leaks memory. Each replug leaves about
one old swap chain's buffers (two to three frames, 16 to 36 MB at the sizes
tested) and about 50 handles in the driver's host process, `WUDFHost.exe`.
Nothing frees them until the driver restarts. On the 8 GB copy, the leak filled
Windows' commit limit (32.7 GB, with the page file grown to its maximum) after
several hundred replugs (about 750 in the run before hang 3). Then `dwm.exe` crashed in a loop with `0xc00001ad` (out
of memory), and the IDD hung in an unfinished replug. A commit sampler
recorded this for phase 3's hang 3. Windows' event log shows the same
out-of-memory events, with `WUDFHost.exe` as the top user, at phase 3's hangs 1
and 2 and phase 0's hangs 2 and 3. John's live freeze on 2026-11-21 (12:16 EST,
the same state) also came with a low-memory event and two `dwm.exe` crashes,
though WSL was the top user there. So exhaustion is the working explanation
for every hang in that state, and hang 3 proves it for one. Phase 0's hang 1,
in the 2026-11-19 state (a new monitor with no swap chain), had no low-memory
event, so that state still has no known cause; parts A and C stay its answer.
A driver restart freed 29 GB at once. Quick resizes are the fastest way to many replugs, but the leak does not
need them: slow resizes leak the same amount, and so does every monitor wake
that ends in an ask. Part E guards against the leak itself. See the phase 3 result for the
evidence.

The usual source of quick resizes is the monitor itself. John's LG 48" OLED
sleeps on its own, and Omarchy's lock and stay-awake can't stop it. When it
sleeps or wakes, HDMI drops, and Hyprland moves the window to a fallback output
and back. On 2026-11-21 at 14:28:59 EST one wake resized the window three times
in 1.5 s, and the client asked Windows for each size. TVs used as monitors often
drop HDMI like this, so the bug is not John's alone.

### Evidence

Driver log times are Windows' clock, in UTC. Windows' clock ran about 10 s behind
the host on 2026-11-21.

**2026-11-19, first freeze.** After a monitor dropout, three replugs ran within
about 2 s. On the third (16:04:21Z), Windows created the monitor and committed
its modes, but no swap chain assignment was logged. The IDD waited for one.
After 34 minutes, Win+Ctrl+Shift+B made Windows assign a swap chain, and the
picture came back.

**2026-11-21, forced freeze.** A script resized the floating window in bursts of
2 or 3 sizes, each held 0.6 to 1.3 s. Burst 161 hung, after 423 replugs:

```
17:16:35Z ReplugMonitor                       (ask for 2200x1600)
17:16:35Z Swap chain assigned ... (twice)
17:16:35Z IddCxSwapChainSetDevice Failed (0x887A0026 ... The keyed mutex was abandoned.)
17:16:36Z Swap chain assigned / Swap chain device set   (it recovered; a frame came)
17:16:37Z ExtraMode: 1920x1200@60*
17:16:37Z ReplugMonitor                       (and nothing after it)
17:16:42Z ExtraMode: 1920x1200@60*           (retries: mode loaded, no replug)
```

A good replug logs `Swap chain unassigned` and `Creating monitor` right after
`ReplugMonitor`. This one logged nothing. In the pinned IDD,
`CMonitorManager::Replug` logs `ReplugMonitor`, calls `IddCxMonitorDeparture`,
and sets `m_waitForSwapChainRelease`. Only `OnSwapChainReleased` clears it and
queues the new monitor. No release was logged, and every later ask loaded its
mode and then returned at `if (m_waitForSwapChainRelease) return NONE`. The
client logged five asks and then `Resize: Windows did not take 1920x1200`.

Win+Ctrl+Shift+B, sent three times, did not help. Neither did Ctrl+Alt+Del, then
Esc. A clean shutdown and start of Windows did.

Over the 423 replugs of the test:

| Time since the previous replug | Replugs | Hangs |
| ---: | ---: | ---: |
| 0-1 s | 240 | 0 |
| 2 s | 70 | 1 |
| 3-4 s | 109 | 0 |
| 6 s or more | 3 | 0 |

34 replugs hit the abandoned-mutex error and recovered. Two freezes are too few
to name a safe gap, which is why this plan has both a mitigation and a recovery.

For the 160 bursts that did not hang, the frame at the new size came 600 ms after
the client's last ask at the median, 800 ms at the 95th percentile, and 2.5 s at
the most.

Raw material: the driver logs `looking-glass-idd.txt` (2026-11-19) and
`looking-glass-idd.1.txt` (2026-11-21) in the shared folder, and the test script
and its record in the session scratchpad. Phase 1 copies the relevant parts into
`docs/plugin/proofs.md`.

## Requirements

### A. Fewer and calmer replugs (client patches 0004 and 0005)

1. The client asks Windows for a new size only after the window has not changed
   size for 2 s (`RESIZE_SETTLE_US`). The clock starts at each raw size change,
   where `core_updatePositionInfo` posts it, not when upstream `message.c` hands
   the size on after its 500 ms debounce. So a size still waiting in that
   debounce holds back an ask for the older size, and a continuous drag makes no
   ask until it stops. A burst of resizes, such as a monitor wake, makes one ask,
   for the last size.
2. Two asks in a display session are at least 4 s apart (`RESIZE_GAP_US`),
   whether for a new size or a retry of the same size. A new session starts
   afresh (requirement 3): it follows a driver or host restart, so the last
   ask's replug is gone. The first retry wait grows from 2 s to 4 s, and the
   rest of the retry table (5, 10, 20 s) stays.
3. A window size below the floor, a new session, and the "did not take" give-up
   behave as today.
4. Tradeoff, accepted by John: after a drag resize, Windows follows the window
   about 2 s after the drag stops, not about 0.6 s. The constants live in
   `resize.h`.

### B. Notice the hang (client patches 0004 and 0005)

5. The client counts every frame it receives, not only format changes, and
   keeps the time of the last one.
6. A stall is either of these:
   - An ask is outstanding (the window and Windows differ, and at least one ask
     went out in this sequence), and no frame has arrived for 10 s
     (`RESIZE_STALL_US`), counted from the later of the sequence's first ask and
     the last frame. Retries do not move this deadline.
   - A display session started, and no frame has arrived for 10 s since its
     start. This covers a client that starts or restarts while the display is
     already hung, when no ask can go out (an ask waits for a frame).
7. On a stall the client logs one line, `Resize: no frame from Windows for 10 s
   (<reason>)`, once per stall. The stall lasts until a frame arrives, in this
   session or a later one: a new session during a stall, such as after a driver
   restart, does not end it. The first frame after a stall logs
   `Resize: frames from Windows again`. That line is the only end of a stall that
   the client reports.
8. A Windows that refuses a mode but keeps drawing is not a stall: any frame
   resets the count. A refusal on a still desktop does look like a stall: in
   phase 0, Windows refused 5200x2900 and sent no frame for 38 s. The client
   cannot tell the two apart, so it reports both, and the scale task confirms
   the hang before it restarts anything (requirement 13).

### C. Recover from the hang (host and scale task)

9. The scale feed, Lanai's only writer on the scale channel, follows
   `client.log`. It keeps its state in `$RUN/display-recovery.json`, which
   `vm_exec` deletes at each VM start, so a supervised restart of the feed
   resumes with the same state, and a new VM run starts clean. The state holds:
   - the client generation and the byte offset read so far in it. The
     generation is a unique ID that `lanai-client-exec` writes on the log's
     second line (`lanai: client id <uuid>`, from
     `/proc/sys/kernel/random/uuid`). The first line stays as it is, because
     `log_client_start` and `version_check` parse it strictly
     (`lib/client.sh:103`, `:170`). A new ID starts a new generation at offset 0,
     so a same-second restart, a truncate-and-regrow between polls and a
     rotation are all caught, and lines from an earlier client are never
     replayed. A log shorter than the offset also starts again at offset 0;
   - whether a recovery is pending, when it started, and the time of each send
     for it;
   - each restart seen in this VM run (requirement 11), with its time.

   The feed writes the state to a temporary file and renames it over the old
   one, so an interrupted write leaves the old state whole.
10. A stall line makes a recovery pending. These end it: a `frames from Windows
    again` line, a new client generation, the client unit not running (the
    feed checks it at each poll; a `systemctl` that fails or times out leaves
    the state unknown, which neither ends a recovery nor sends), or the end of
    the VM.
11. While a recovery is pending, the feed sends `lanai-display-restart` only when
    QEMU reports the scale port's guest side open (`frontend-open` on `scale0`,
    as setup's step 6 check reads it). So a stall before the scale task starts,
    such as before sign-in, waits instead of being lost. Scale lines keep
    flowing as today while a recovery waits.

    The channel stays one-way (spec 27), so the feed never learns whether
    Windows restarted its display or declined (requirement 13). It treats each
    send's outcome as unknown and retries within two limits:
    - Per recovery: at most 3 sends. Any two sends in the VM run are at least
      60 s apart, also across recoveries, so a guest that forges new
      recoveries in the client's log gets one line a minute.
    - Per VM run: at most 3 restarts seen. A restart seen is a send that a new
      client session (`Starting session`, upstream's line) followed within
      60 s. The feed judges this when it reads the line: the first pass that
      ends more than 60 s after the send stops watching for it, after it reads
      the new lines. So a late pass counts a session it missed rather than
      lose it. A driver restart ends the client's session, and phase 0 saw the new
      one 2 to 6 s after each restart. A declined send restarts nothing, so it
      costs no restart seen; an unrelated reconnect after a send counts as one,
      which errs toward fewer restarts.

    Before each write, the feed records the send in the state file, so every
    send counts against both limits it can, whether the write succeeds, fails
    or is cut off. With either limit spent, it sends nothing more for this
    recovery.

    While a recovery has been pending for 60 s or more, `lanai status` notes
    that Windows has sent no picture for that long and that, if the window is
    frozen, a restart of Windows fixes it. The note does not say the display is
    stuck: a refused size on a still desktop also sends no picture (requirement
    8). Whatever ends the recovery clears the note.
12. The scale task accepts the exact line `lanai-display-restart` and nothing
    longer or different. Restart lines and scale lines are separate kinds in a
    drained batch:
    - Scale lines keep today's rule: one valid scale line applies, and two or
      more are stale and dropped.
    - One or more restart lines in a batch, in any order with scale lines, make
      one restart.
13. On a restart line, the task first confirms the hang from the driver's own
    log, because a refused size on a still desktop looks the same from the host
    (requirement 8). The check and the restart run in one child process with a
    45 s limit, so neither can stop scale handling. The check reads the last
    1 MiB of `%ProgramData%\Looking Glass (IDD)\looking-glass-idd.txt`, opened
    for shared read, since the driver keeps writing it. It skips the first line
    of the tail and any last line with no newline, since either may be cut. A
    candidate is the last complete line from `CMonitorManager::Replug` that ends
    `| ReplugMonitor`, with no later complete line that ends
    `| Swap chain device set` or contains `IddCxMonitorDeparture Failed` (the
    driver's path that keeps the old monitor and stays healthy). The check
    reads the log twice, 10 s apart by a monotonic timer, not by the log's
    times, so a clock step cannot fake the wait. The display counts as hung
    only when both reads find a candidate at the same byte offset in the file.

    Anything else, including no candidate, a missing or unreadable log, or a
    file that shrank between the reads, logs "Display hang not confirmed
    (<reason>); no restart." and does nothing. The driver starts a new log at
    each start, so the current file holds only the running driver's events; a
    hang whose replug line is gone gets no automatic restart, which errs toward
    fewer restarts.

    The check proves an unfinished replug, not a hung display. The evidence
    makes that a close stand-in. Phase 0's and John's driver logs hold 2,119
    distinct replugs and no departure failure. 2,114 finished in 3 s or less.
    The other five were all hangs: hangs 1-3, the live 2026-11-21 freeze, and
    the live 2026-11-19 replug that stayed unfinished for 33 minutes until
    John's graphics reset.
    Accepted risk: a healthy replug slower than 10 s after a 10 s stall gets one
    needless restart, one display flicker. The strings and their meaning belong
    to the pinned IDD; a pin change rechecks them (requirement 18).

    For a restart, the task selects the Looking Glass display adapter by its
    hardware ID, `Root\LGIdd`, which is the same on every install. The instance
    ID (`ROOT\DISPLAY\0000` in phase 0) is not, so it is read each time. It acts
    only when exactly one present device has that hardware ID, and logs and does
    nothing for none or several. It runs
    `C:\Windows\System32\pnputil.exe /restart-device <instance ID>` with the
    instance ID as one argument, and matches the hardware ID without regard to
    case. It logs the exit code. Exit code 3010 (reboot needed) and any other
    failure are logged, not retried by the task: the host's next send is the
    retry. It starts at most one child a minute, so two restarts come at least
    25 s apart (a child restarts once, after its 10 s check, and is stopped at
    45 s). At the 45 s limit the task stops
    the child with every process it started (`taskkill /T /F`), and it starts
    no new child while the last one or any `pnputil.exe` still runs, so a
    pnputil that cannot be stopped never gets a second one beside it.
14. An install whose scale task predates the restart handler gets the same
    treatment as an old scale task today: the panel says to run setup again and
    names the fix. Setup records the new task version.

### D. Specs and docs

15. `docs/plugin/spec.md`, with the amendments logged in its review log:
    - Requirement 12, asks: Lanai asks once the window size has held for 2 s,
      then retries after waits of 4, 5, 10 and 20 s, and two asks are at least
      4 s apart. A window resize, or a burst of them, is matched within 7 s of
      its last raw size change, not 5 s of the event. That fits the settle and
      the gap: a size that arrives just after an ask can wait until 4 s after
      that ask, and the frame takes up to 2.5 s. Sizes the window passes through
      during a drag or a burst need no match. An event with no window size
      change, such as a resolution picked in Windows' Display settings, is
      matched within 7 s of that event; the window has not changed, so the
      settle is already met, and only the gap can delay the ask. The existing
      exception for a Windows that keeps leaving the size within 60 s of the
      last ask stays.
    - Requirement 12, exceptions: matching may also wait while Lanai has
      detected a stall (part B) and is recovering (part C), until frames return
      or recovery gives up.
    - Requirement 12, patch scope: the patches may also count frames, detect a
      stall, and log the two stall lines. They still add no message and change no
      message's format.
    - Requirement 27: the scale channel carries a scale step and a save number,
      or the fixed line `lanai-display-restart`, and nothing else. The scale task
      acts on that line only by restarting the Looking Glass display adapter,
      and only after the driver's log shows the hang. The channel stays
      one-way. The task also restarts that adapter on its own when the
      driver's memory passes part E's limit; no message from the host and
      nothing the guest writes to the client's log can start a guard restart.
16. `README.md` names the freeze, the monitor-sleep trigger and the automatic
    recovery, and says that a restart of Windows is the fallback. It also says
    that the display driver leaks memory at each resize, that the scale task
    restarts it when the leak grows large, after 5 minutes with no keyboard or
    mouse input, and that the display flickers once when it does. It says that
    a video or slideshow watched with no input may see that flicker, and that
    a much larger leak, or Windows running low on memory, restarts the driver
    at once, input or not.
17. The panel's old-client and old-task messages name the freeze fix (the
    pattern 0003 set: "may", one item per fix).
18. `CLAUDE.md`'s pin rule adds a recheck of what requirement 13 reads, in the
    new IDD's source: it still logs `ReplugMonitor` from
    `CMonitorManager::Replug` before the departure, `Swap chain device set` when
    a new swap chain is ready, and `IddCxMonitorDeparture Failed` on the path
    that keeps the old monitor, with no other path that ends a replug without
    one of those lines. The log keeps its path and starts a new file at each
    driver start, and the adapter keeps the hardware ID `Root\LGIdd`. Spec 12's
    sign-in bullet, which the rule cites, gets the same note. The rule also
    rechecks what part E reads: the driver is `LGIdd.dll`, loaded from inside
    System32 and hosted in System32's `WUDFHost.exe` under a service account, and its GPU memory shows in
    `Win32_PerfRawData_GPUPerformanceCounters_GPUProcessMemory` rows named
    `pid_<id>_...`; and whether the new IDD still leaks (phase 3's
    Win+Ctrl+Shift+B repro), since a fixed leak lets the guard go.

### E. Guard against the driver's leak (scale task)

19. The measure. A collector in its own runspace, beside the port reader,
    takes a sample every 10 s and hands it to the main loop through a shared
    table, so a slow or stuck query never holds up scale handling or the
    restart child's 45 s stop. Each WMI query has a 20 s timeout
    (`OperationTimeoutSec`). A sample holds:
    - the driver's GPU memory: the sum of `TotalCommitted` over the rows of
      `Win32_PerfRawData_GPUPerformanceCounters_GPUProcessMemory` whose
      `Name` starts with `pid_<id>_`. `<id>` is the one process that a
      service account (LocalSystem, LocalService or NetworkService) runs
      from `%SystemRoot%\System32\WUDFHost.exe`, with `LGIdd.dll` (matched
      without regard to case) loaded from inside System32, found again at
      each sample. No user can run a program as a service account, so a
      program a user runs, even the real `WUDFHost.exe` with a DLL of that
      name from a System32 folder users can write, is skipped before its
      modules are read and cannot hide the real host. A process that ends
      during the read is skipped: a driver restart can move the driver to a new host
      process (it did in phase 3). The query escapes the underscores
      (`pid[_]1204[_]%`), since `_` alone matches any character in WQL and
      would also take process 12048's rows; the collector checks each row's
      prefix again;
    - Windows' free commit, `ullAvailPageFile` from `GlobalMemoryStatusEx`;
    - when it was taken, on the task's monotonic clock.

    A sample counts only when exactly one such process exists, it has at
    least one row, and the same process (ID and start time) still exists
    after the query. No rows means no measure, not zero. The main loop uses
    only a sample under 30 s old. A collector that gives no usable sample for
    5 minutes is logged once, until a usable one comes.

    WMI's class and property names stay the same in every Windows language;
    the counters' display names do not. If the class is missing or a query
    fails, the guard does nothing and the hang recovery (part C) stays the
    backstop. Phase 3 measured the GPU memory against the leak: 285 MB at
    the first reading (after a few replugs), then 562, 865 and 1,023 MB after
    8, 8 and 10 more, and up 39 MB after 5 graphics resets. Windows' commit
    grew by the same amounts. The first query took 804 ms, later ones 12 ms.
20. The limit is 1/8 of the VM's memory, at least 1 GiB (`ullTotalPhys`
    from `GlobalMemoryStatusEx`, read once at start): 1 GiB on 8 GB, 2 GiB on
    16 GB. A healthy driver stays far under it. Lanai's frame memory is a
    fixed 128 MiB, which caps the mode the driver accepts (it refused
    5200x2900 in phase 0). Phase 3 measured a freshly restarted driver at
    136 MB at 1280x800 and 191 MB at 3840x2160. The software adapter
    disables HDR, so HDR adds nothing. The leak reaches 1 GiB after about 10
    replugs at the largest sizes, or about 60 at small ones.
21. When the guard restarts:
    - Routine: over the limit, with no keyboard or mouse input to Windows
      for 5 minutes, and at least 30 minutes after the last guard restart.
      Idle time is `GetTickCount` minus `GetLastInputInfo`'s tick, as an
      unsigned 32-bit difference, so the tick's wrap after 49.7 days does
      not break it. The input tick is read first, so input between the two
      reads cannot look like 49.7 days of quiet. Phase 5 checks that keys and mouse moves through the
      Looking Glass window reset it. A restart flickers the display for 1 to
      2 s, so it waits for a time when nobody is likely to see it.
    - Emergency: over twice the limit, or over 512 MiB with less than 4 GiB
      of free commit. It ignores input and the 30 minutes, and a restart the
      child rules hold back is tried again at each 250 ms tick until they
      allow it. Production asks come at most every 4 s (requirement 2), and a
      replug at the largest accepted size leaks about 100 MiB (one swap
      chain's buffers, about 2.5 frames of 33 MB), so the leak grows at most
      about 1.5 GiB a minute. 4 GiB of free commit leaves about 2.5 minutes,
      against 10 s between samples, up to 60 s of child rules and a few
      seconds for the restart. 512 MiB keeps a healthy driver out of it when
      other programs fill memory.
    - Accepted tradeoff: no input is not the same as nobody watching. A video,
      a slideshow or a game played only with a controller can run 5 minutes
      with no keyboard or mouse input, and then see one flicker. Phase 3 found
      no signal the task could use: a test request to keep the display on did
      not show in `CallNtPowerInformation` or in `powercfg /requests`. That
      test request may never have taken effect, and a real video player is
      not tested. A routine flicker happens only when the leak is over the
      limit, and at most once in 30 minutes. An emergency restart (above)
      can come during input and sooner; it trades a flicker for a hang.
22. A guard restart uses the hang restart's child (requirement 13) with
    `-LeakRestart` in place of `-DisplayRestart`. It skips the driver log
    check, selects the adapter by hardware ID the same way, runs pnputil and
    logs its exit code. One set of child rules serves both kinds: at most one
    child a minute, none while the last child or any `pnputil.exe` runs,
    stopped at 45 s with what it started. So a guard restart cannot replace
    the driver log while a hang check reads it. A routine restart that the
    rules hold back waits for the next sample; an emergency one, for the next
    tick.
23. Limits, so a guard that misreads cannot flicker the display all day:
    - Freed: after a child exits with code 0, the first usable sample taken
      after the exit decides, and it must come within 60 s. The restart
      freed the leak when that sample's host process differs from the one
      that leaked (another ID or start time), or when its measure is under
      half the measure that started the restart, or under 512 MiB,
      whichever is larger. A new host process is the main sign: in every
      restart traced so far it changed (phase 3's hangs and the guard tests
      on 2026-11-23: 1084 to 7224, 1204 to 2736 to 1796), and the old
      process's memory goes with it, however fast the new one grows. The
      measure is the fallback for a host that stays; the first sample after
      the exit comes at most 10 s later, when at most 3 replugs (about
      300 MiB) can have added to a fresh driver's 191 MiB, still under
      512 MiB. If neither holds, the restart did not free the leak, and the
      guard stops until the scale script starts again (a sign-in, a Windows
      start, or the task's 5-minute trigger after the script ended). It logs
      that once. No usable sample in the 60 s counts as a failed child
      (below). Growth after the deciding sample is new leak and starts the
      rules over.
    - Any other end of a guard child restarted nothing: a nonzero exit code
      (2 for no single adapter, 3010, any pnputil failure) or the 45 s stop.
      After 3 such guard children in a row, the guard stops the same way. A
      freed restart resets the count.
24. The task logs each guard restart with its kind (routine or emergency),
    the measure, the limit, the free commit and the minutes since the last
    input, so `lanai-scale.log` explains every flicker.
25. The restart child's own error line is written with retries, as its other
    lines are (`Write-RestartLog`). In phase 3 hang 1, the first child exited
    with code 1 during the memory exhaustion, and its error line was lost.

The host needs no change. A guard restart ends the client's session; phase 3
saw the new session's first frame about 2 s after each restart, inside the
10 s stall rule. If no frame comes in 10 s, the stall reaches the hang check,
which finds no unfinished replug in the new driver log and declines. One
interaction is accepted: a guard restart within 60 s of a host send counts as
a restart seen (requirement 11), as any unrelated reconnect does, which errs
toward fewer restarts.

Known interaction: John's 2026-11-23 freeze was a client render stall while
the window sat on a hidden Hyprland workspace. A routine restart comes at idle,
which is when the window is most likely hidden or the monitor asleep. If the
client stalled after such a restart, John would come back to a frozen window
that the hang recovery declines to touch, since the driver is fine. On
2026-11-23 two driver restarts with the copy's window on a hidden workspace
left the client healthy: a new session each time, input and clipboard back
on LGMP within 0.3 s of it, no bad subscriber bit, and the render thread waiting normally. Phase 5
makes this a gate: if a routine restart with the window hidden leaves a frozen
picture or a dead mouse when the window is shown, routine restarts stay off
(emergency only) until the client fix on its own branch lands.

## Acceptance

- Client tests, each failing without the change. Module cases in
  `resize_test.c`, and glue cases in `config_message_test.c` where `message.c`'s
  debounce takes part:
  - A burst of three window sizes 0.7 s apart makes exactly one ask, for the
    last size, 2 s after the last raw change.
  - Size A, then size B 1.8 s later: no ask for A, and one ask for B 2 s after B
    (glue case, with the real debounce).
  - A continuous drag, a raw change every 0.3 s for 10 s: no ask until 2 s after
    it stops.
  - No two asks are closer than 4 s, for both a new size and a retry.
  - The window holds one size for 100 s, then Windows changes to another
    resolution: the client asks at once (the settle is met), and no later than
    4 s after its previous ask.
  - An ask, one frame 1 s later, then silence: the stall line comes 10 s after
    that frame (11 s after the ask), once. Retries in between do not move it.
  - A frame of any size before the deadline means no stall line. A frame after a
    stall logs `frames from Windows again`.
  - A new session with no frame for 10 s logs the session stall line.
  - A stall, then a new session, then a frame: one stall line and one
    `frames from Windows again`, and no second stall line.
  - The existing cases pass. Any case whose timing changes on purpose says so in
    a comment.
- Host tests in `test/scale-feed.bats`, with a fake `client.log` and a fake QMP
  answer for `frontend-open`:
  - A stall line with the port open sends `lanai-display-restart` once.
  - A stall line with the port closed sends nothing, then sends once the port
    opens.
  - With no `frames again` line, it sends again 60 s after each send, whether
    or not a session followed, and stops after the third send for one
    recovery.
  - Restarts seen: a send followed by `Starting session` within 60 s counts
    one. After three in a VM run, a new stall sends nothing. Sends with no
    session after them (a declined check, a failed restart) do not count, so a
    refused size that stalls on every idle minute never spends the run's
    restarts. A session that comes after a pass more than 60 s after the send
    does not count; an unrelated session after a declined send does. A session
    soon after a send that a late pass first reads still counts, so a feed
    that misses passes cannot get a fourth restart.
  - A new client that replaces the log while a pass reads it or asks QMP gets
    no send from that pass.
  - A write that fails, and a feed killed between recording a send and
    writing: each counts as a send. A feed restart while it waits to learn
    whether a session follows keeps the send and its time.
  - `frames again` without a new session ends the recovery and counts no
    restart.
  - `frames again`, a new client generation, or the client unit stopping ends
    the recovery: nothing more is sent. A `systemctl` that fails or times out
    neither ends it nor sends.
  - A guest that forges a new recovery on each pass gets one send a minute.
  - The status note shows once a recovery has been pending for 60 s, never
    says "stuck", and clears when the recovery ends. The panel shows the same
    note.
  - Two client starts in the same second, with the new log regrown past the old
    offset before the next poll: the new ID starts a new generation, and the old
    stall line is not acted on. The same holds for a rotated log.
  - A feed restart (a new process with the same `display-recovery.json`)
    neither sends again for an old stall nor resets the attempt count. A new VM
    run starts with no state.
- `test/client.bats`: the log's first line is
  unchanged, its second line holds a new ID at each start, and
  `log_client_start` and `version_check` read the log as before.
- Guest tests in `test/guest.bats` (pwsh, local):
  - The exact line calls the restart once with the selected instance ID. A
    longer line or extra words do nothing.
  - Batches: restart then scale, scale then restart, two scale lines plus a
    restart (the restart runs, the scale lines are stale), and two restart lines
    (one restart).
  - A second restart within a minute does nothing.
  - No matching device or two matching devices: logged, no restart.
  - The hang check, on trimmed copies of the phase 0 driver logs in
    `test/fixtures/`, with the 10 s wait shortened by a test hook: hangs 1-3
    (including hang 3's same-second replug) and the live 2026-11-21 freeze
    restart; the healthy log with five refusals does not. No restart for: a
    missing log; no `ReplugMonitor` in the tail; `IddCxMonitorDeparture Failed`
    after the last replug; a `Swap chain device set` that appears between the
    two reads; a new replug line at another offset on the second read; a file
    that shrank between the reads; and a tail cut through the candidate line
    or ending in a partial line. A log the driver holds open is still read.
  - Selection: one present device whose hardware ID list holds `root\lgidd`
    in any case, under another instance suffix, is restarted with its instance
    ID as one argument.
  - A nonzero exit and exit 3010 are logged. A check and restart that run past
    45 s are stopped with what they started, and scale handling goes on
    meanwhile, also when the stop's log line fails. A request while a stopped
    child or any pnputil still runs starts nothing.
- Guard tests in `test/guest.bats` (pwsh, local), with the samples, the idle
  time, the clock and the child faked:
  - Under the routine limit and neither emergency condition: no restart,
    whatever the idle time. On an 8 GiB VM, 600 MiB with 3.9 GiB of free
    commit is an emergency restart, though it is under the 1 GiB limit.
  - Routine: over the limit, no restart with input 4 minutes ago; a restart
    with no input for 5 minutes. A second routine restart within 30 minutes
    waits, and comes after them.
  - Emergency: over twice the limit, a restart with input a second ago and
    10 minutes after the last guard restart. Over 512 MiB with 3.9 GiB of
    free commit, the same. At 400 MiB with 1 GiB of free commit, nothing. An
    emergency held back by a hang child 20 s old starts at the first tick
    after the minute, not at the next sample.
  - The limit: 1 GiB for 4 GB and 8 GB of memory, 2 GiB for 16 GB.
  - Freed: a new host process at the first sample after the exit keeps the
    guard on, even when that sample already reads 591 MiB after a 600 MiB
    trigger (round 3's sequence). The same host with a drop under half keeps
    it on, and a new crossing a minute later restarts again (emergency). The
    same host from 600 MiB to 400 MiB counts as freed (under 512 MiB). No
    usable sample within 60 s of the exit counts as a failed child. No drop: the guard stops and logs once, and a later sample
    over twice the limit restarts nothing. Three failed children in a row
    (exit 2, exit 3010, the 45 s stop) stop it the same way; a freed
    restart in between resets the count.
  - Idle: a last-input tick just before the 32-bit wrap and a current tick
    just after it give the right idle time.
  - Samples: a sample 31 s old is not used. No usable sample for 5 minutes
    is logged once, and the log clears when one comes. A collector that
    never returns leaves scale handling and the 45 s stop of a running
    child working.
  - Sample validity, on the real collector with faked process and WMI
    reads: exactly one System32 `WUDFHost.exe` that a service account runs,
    with System32's `LGIdd.dll` (any case); none or two, no sample. Beside
    the real host, a look-alike `WUDFHost.exe` and `LGIdd.dll` from a user
    folder, or the real `WUDFHost.exe` run by a user with an `LGIdd.dll`
    from `System32\spool\drivers\color`: the real host is sampled, and the
    user's process is not read. A host with no known owner, the real host
    with `LGIdd.dll` only from outside System32, or a path with `..`: no
    sample. The query for process 12 escapes its underscores, and
    rows for `pid_12_` count for it while `pid_123_` and `pid_1204_` rows do
    not. Two rows for the process (two adapters) are summed. No rows: no
    sample. A host whose ID or start time changes during the query: no
    sample. A failed module read for one process, or a failed query: no
    sample.
  - The child rules hold across both kinds: a routine restart within a
    minute of a hang restart, or while its child or any pnputil runs, waits
    for the next sample, and an emergency one starts at the first tick the
    rules allow; a hang request while a guard child runs starts nothing. The
    child with `-LeakRestart` restarts the selected adapter with no driver
    log check.
  - Each guard restart's log line holds its kind, the measure, the limit,
    the free commit and the idle minutes.
  - The child's error line is retried when the log is busy.
- Every patch applies exactly, the client builds, and its tests pass
  (`test/client-patches.bats` with `LANAI_TEST_LG_TARBALL`). The bats suite,
  `bin/check` and CI pass.
- Phase 0, phase 3 and phase 5 proofs below pass on a reflink copy.
- John's hand checks on his live install after the copy passes:
  - Normal wakes: let the monitor sleep and wake five times. Each wake makes one
    ask, and Windows shows the desktop at the window's size within 7 s of the
    last resize the wake caused. A wake that hangs is not counted here; it falls
    under recovery.
  - Recovery is checked on the copy (phase 3), not live, because forcing a hang
    takes hours of resizes.

## Constraints

- The pin and the IDD stay as they are. 0004 and 0005 apply exactly after
  0001-0003.
- Nothing new runs as admin in Windows. The scale task already runs with the
  setup user's admin rights (spec 27). It gets one more fixed action, through the
  one exclusive reader it already has, and the guard, which reads Windows'
  counters and uses the same action.
- No network listener and no change to the guest agent's allow-list.
- Agents test on a reflink copy, not on John's live VM, unless John gives a go
  for that step.
- Out of scope:
  - The 2026-11-19 afternoon freeze, which had no resize (the client was dropped
    and no ask was involved).
  - The RDP rescue port.
  - The upstream bug report (decision 4). The agent drafts it; John posts it.
    It leads with the leak and phase 3's repro (each Win+Ctrl+Shift+B grows
    the driver host's GPU memory and handles, with no Lanai involved), and
    shows the hang as its consequence, with the log excerpts above.

## Plan

### Phase 0: prove the recovery by hand (before any code)

On a reflink copy of the live disk, booted with `proof-vm` and Lanai's patched
client:

1. Record the Looking Glass display adapter's instance ID, its hardware IDs and
   the Windows build. Check that the ID pattern fits requirement 13 and that
   `pnputil /restart-device` exists on this build.
2. Arm the recovery by hand: an admin PowerShell in the copy waits for a file in
   the shared folder, then runs `pnputil /restart-device <id>` and writes its
   exit code to the shared folder.
3. Force the hang with the burst script (expected: a few hundred bursts). Save
   the driver log and identify which state it reproduced: the 2026-11-21 state
   (no release after `ReplugMonitor`) or the 2026-11-19 state (no swap chain
   assigned after a new monitor).
4. Create the file from the host. Pass: a new frame arrives within 15 s without
   a Windows restart, the desktop returns at the window's size, keyboard and
   mouse work, and a later resize works.
5. Repeat until three forced hangs have been recovered.
6. Static desktop: with the desktop idle, ask for a size Windows refuses, if one
   exists, and record whether frames stop for 10 s (requirement 8).

The recovery claim covers only the states phase 0 reproduced. If the restart
does not bring the picture back, stop and bring the result to John. Part C
changes, and parts A and B still stand.

#### Phase 0 result (2026-11-21)

Run on `~/lanai-proofs/resize-hang-copy`, a `lanai-copy` of the live disk, next
to the live VM. The copy had 8 GB, the live VM's scale port and SMBIOS line,
and its network link cut. Lanai's B7-826-236efcb1 client drove a window on a
hidden workspace; frames arrive there as on screen. The evidence is in
`~/lanai-proofs/resize-hang-phase0/`.

- Windows 11 Pro 25H2, build 26200.9168. The adapter is `ROOT\DISPLAY\0000`,
  "Looking Glass Indirect Display Device", hardware ID `Root\LGIdd`, driver
  1.27.7.771. The design's example (`SWD\LGIDD\`) was wrong. A root-
  enumerated instance number is not stable across installs, but the hardware
  ID is. Requirement 13 now selects by it.
- Baseline on a healthy driver: pnputil exit 0 in 404 ms, and a frame at the
  window's size within 1 s.
- Hangs came at bursts 85, 300 (after a clean run of 274, cut short when the
  harness stopped the copy's QEMU) and 304:

  | Hang | State | pnputil | First frame at the window's size |
  | --- | --- | --- | --- |
  | 1 | 2026-11-19: new monitor, modes committed, no swap chain | exit 0, 1.6 s | about 2 s after the restart began |
  | 2 | 2026-11-21: `ReplugMonitor`, then nothing | exit 0, 5.9 s | about 6 s |
  | 3 | 2026-11-21 | exit 0, 2.0 s | about 2 s |

  Each time the desktop came back at the window's size, the Windows key opened
  and closed Start, and the next three bursts all took. In hang 3 the client
  had already logged "did not take"; the new session asked again by itself.
  Hang 3's last replug came in the same second as the one before it.
- Static desktop (step 6): with all windows minimized, Windows sent one frame
  in 20 s (the taskbar clock's minute). The driver refuses 5200x2900 ("Refusing
  resolution 5200x2900: configured frame capacity must be at least ... MiB")
  and sends the refusal to its helper pipe, not to the client. After the
  client's fifth ask, no frame came for 38 s. So requirement 8's risk is real:
  as written, the detector restarts the driver for a refused size. A window
  larger than the shared memory allows, such as a full-screen window on a 5K
  monitor, refuses on every ask, so every VM run would spend its 3 attempts.
  The client cannot predict the refusal: the driver's rule
  (`CLGMPFrameCaps::CanUseMode`) uses a frame memory offset and buffer count
  that only the driver knows.
- The driver log tells the two apart. In every hang log, the last
  `ReplugMonitor` has no `Swap chain device set` after it: hangs 1-3 and the
  live 2026-11-21 freeze. In the refusal log, it has one. A refusal also logs
  `Refusing resolution`. John accepted a check on this signature (decision
  3), now in requirements 8, 10, 11, 13 and 18.

### Phase 1: client patches 0004 and 0005, test first

Cases first, then in `resize.c`: the settle clock fed by raw size changes, the
gap, the stall detector, and the frame counter. Then the hooks: raw size changes
from `core_updatePositionInfo`, and a per-frame call in `main_frameThread`
beside the format-change hook. Add the cases to `RESIZE_CASES` and the glue
cases to `config-message-tests`. Write the patch with 0003's header style, and
update `test/client-patches.bats` for 0004. Copy the evidence above into
`docs/plugin/proofs.md`.

A test-only build switch turns off the settle and gap rules and keeps the
stall detector, so phase 3 can force hangs with the new detector.

#### Phase 1 result (2026-11-21)

The change is two patches, not one. 0004 touches only the files 0001 creates
(`resize.c`, `resize.h`, `resize_test.c`), so CI applies 0001 and 0004 to an
empty folder and runs every module case on each push. 0005 holds the glue
(`core.c`, `core.h`, `message.c`, `main.c`, the glue tests and
`tests/CMakeLists.txt`), which only the local tarball test builds.

- The raw size comes from `lgMessage_process`, which hands each posted size to
  the module with the time `core_updatePositionInfo` posted it. That is the raw
  change time, read on the main thread, so the module stays single-threaded.
  The debounce can hand an older post back after a newer one, so the module
  ignores a post older than the last change.
- The frame counter is a separate atomic beside `g_state.frameCount`, which the
  FPS timer resets every 500 ms.
- The stall line reads `Resize: no frame from Windows for 10 s (asked for
  <w>x<h>)` or `(new session)`; the end reads `Resize: frames from Windows
  again`. Phase 2 parses these.
- Tests: 30 module cases (10 new) and 19 glue cases (2 new). The cases whose
  timing changed on purpose say so in a comment. Each new case fails when its
  rule is removed: without the settle (`burst`, `drag`, `raw-order`), without
  the gap (`gap`, `new-window`), with the old 2 s first retry
  (`windows-change` and ten older cases), without the stall detector (the five
  stall cases), without the later-of rule (`stall`, `frames-again`), without
  the raw feed in `message.c` (`resize-settle`) and without the frame count in
  `core.c` (`resize-seen`). The five stall cases also pass in a
  `-DRESIZE_NO_SETTLE` build, and `burst` fails there, as it should.
- `test/client-patches.bats` with `LANAI_TEST_LG_TARBALL`: all five patches
  apply with no offset or fuzz, the client builds with no warnings, and the 69
  resize, config-message and mouse tests pass.

### Phase 2: host feed and scale task, test first

The client ID line in `client_exec`. The follower, its state file and the send
rules in `lib/vm.sh`, with the `frontend-open` and client unit checks. The
per-recovery and per-run limits with restarts seen, and the no-picture note.
The hang check and the restart handler in `guest/lanai-scale.ps1`, with
trimmed phase 0 driver logs as fixtures, the task version in setup, and the
panel messages.
Then the spec, README and CLAUDE.md updates.

#### Phase 2 result (2026-11-21)

- Host (`lib/client.sh`, `lib/vm.sh`, `lib/lanai.sh`): `client_exec` writes
  `lanai: client id <uuid>` as the log's second line. `display_recovery_step`
  runs in each feed pass, before the scale line, and keeps
  `$RUN/display-recovery.json` as requirement 9 lists it, with `watch` for the
  last send no session has followed yet. It asks QMP on `qmp-cli.sock`, as
  `lanai status` does, only when a send is due. `lanai status` reports
  `LanaiNoPicture` and the note "Windows has sent no picture for N minutes. If
  the Windows window looks frozen, restart Windows to fix it." The panel shows
  the same note. `last` keeps the run's last send for the run-wide gap. All
  recovery times are seconds since boot (`boot_seconds`), so a wall clock
  step cannot move them.
- Guest (`guest/lanai-scale.ps1`): the restart child is the same script with
  `-DisplayRestart`, so setup copies no new file. The child is started with
  `Start-Process` in the start program's job. At 45 s the task stops it with
  `taskkill /T /F`, which also stops the pnputil it started, and keeps the
  child until it has exited. No new child starts while the last one or any
  `pnputil.exe` runs. The stop comes before its log line, which can fail
  when it meets the child's write. The child starts before the task compiles
  its display API, which it does not use, and the task keeps its process
  handle so its exit code is known. Both processes write `lanai-scale.log`;
  the child retries a write that meets the task's.
- Setup and panel (requirement 14): step 6 records `display_restart`
  (`LANAI_DISPLAY_RESTART`, 1), and `display_restart_missing` reads it. Without
  the sign-in step, the freeze is one more item in the Run setup again message
  ("all four" at most). With the step, it is its own Run setup again message
  after any update words.
- Tests: 19 host cases in `test/scale-feed.bats`, the ID line in
  `test/client.bats`, the VM start cleanup in `test/vm.bats`, 8 guest cases on
  the phase 0 driver logs in `test/fixtures/idd/`, the mark in `test/ui.bats`
  and `test/setup.bats`, and the panel words and note in `test/panel.bats`. Each rule
  was removed in turn, and a test failed each time. The tests fake Windows'
  processes and devices, so the real `Start-Process`, `taskkill`,
  `Get-PnpDevice` and pnputil behavior is for phase 3 to prove.

### Phase 3: proof on a copy

1. Recovery: with the test-only build (settle and gap off, detector on), force
   the hang, and check that Lanai recovers it with no help, as phase 0's pass
   defines it. Do this three times.
2. Soak: moved to phase 5, since the leak makes any long burst run hang
   without the guard.

#### Phase 3 result, step 1 (2026-11-23)

Run on the phase 0 copy (`~/lanai-proofs/resize-hang-copy`, 8 GB, network
link cut) at commit 719f043, with Lanai's own code aimed at the copy: its
`lib/` with `run_dir`, `state_dir`, `settings_file` and the client unit
pointed at proof paths, a throwaway client unit, the feed and the test build
(settle and gap off, detector on). Both builds came from Lanai's
`patches_apply`: all five patches applied with no offset or fuzz. The
evidence is in `~/lanai-proofs/resize-hang-phase3/`.

| Hang | Burst | Miss to picture | Sends | Notes |
| --- | ---: | ---: | ---: | --- |
| 1 | 315 | 78 s | 2 | The first child exited with code 1, its error line lost; the feed's second send 60 s later restarted the driver (pnputil exit 0) |
| 2 | 633 | 18 s | 1 | pnputil exit 0 |
| 3 | 939 | 21 s | 1 | pnputil exit 0 |

Each time the stall line came 10 s after the last frame, the feed sent
within a pass, and the child confirmed the hang and restarted the driver. A
new session followed, with a frame at the window's size. After each recovery,
the Windows key opened Start (screenshots), a mouse move advanced the pointer
queue, and later bursts worked. The run's three restarts were then spent, as
requirement 11 sets.

Before the hangs, a restart line on a healthy display logged "Display hang not
confirmed (the last replug finished); no restart." in 0.4 s.

The leak. A sampler in the copy logged Windows' commit once a second. Before
hang 3, commit climbed about 1.4 GB a minute, to 32,715 MB of a 32,763 MB
limit, while the bursts ran. Then `dwm.exe` crashed with `0xc00001ad`. Windows' event log has the same signs at hangs
1 and 2, before the sampler ran: `dwm.exe` crashing with `0xc00001ad`, and
Resource-Exhaustion-Detector event 2004 (low virtual memory) naming
`WUDFHost.exe` as the top user, at 19:13 and 19:36. It has event 2004 with
`WUDFHost.exe` on top at phase 0's hangs 2 and 3 too (2026-11-21 19:28 and
19:50). The exports are `events-phase3-dwm.txt` and
`events-exhaustion-summary.txt` in the evidence folder. The driver restart
dropped commit to 3,773 MB, and the two `WUDFHost.exe` processes together to
11 MB private and 49 MB working set. In the two `WUDFHost.exe` processes together, the working set sat near 5 GB,
while their private bytes grew only about 0.7 MB a replug: the leaked memory is shared
GPU memory, which the software render adapter keeps in sections.

Measured later on the same copy, with each size held until a frame at that
size came, plus 2 s:

| Step | Driver GPU memory (`TotalCommitted`) | Handles | Windows commit |
| --- | ---: | ---: | ---: |
| First reading, after a few replugs (3816x2106) | 285 MB | 623 | 3,516 MB |
| 8 replugs, large sizes | 562 MB | 1,061 | 3,805 MB |
| 8 more | 865 MB | 1,448 | 4,098 MB |
| 10 replugs between 1920x1200 and 1280x800 | 1,023 MB | 1,919 | 4,248 MB |
| 5 graphics resets (Win+Ctrl+Shift+B), no replug | 1,062 MB | 2,044 | 4,269 MB |

A driver restart then measured 136 MB at 1280x800, with the driver in a new
host process, and a second restart 191 MB at 3840x2160: a fresh driver's
size. So the leak follows replugs, not new sizes, and a graphics reset leaks
too. The
driver log counts 108 swap chains assigned and 72 unassigned. In 35 of the
assignments, Windows assigned a new swap chain while the old one was still
assigned, with no unassign first: one per replug (29), one per reset (5) and
one at start. The leak matches that count. The driver's
`CMonitorContext::AssignSwapChain` tears the old processor down itself in that
case, and a read of the driver's source found every frame-sized object freed
on that path, so the leak may sit in Windows' IddCx or in how the old swap
chain is released. The upstream report carries the repro.

### Phase 4: the guard, test first

The guard cases first (acceptance), then in `guest/lanai-scale.ps1`: the
collector runspace beside the port reader, the limit, the idle time
(`GetLastInputInfo` in the task's compiled helper), the guard step in the main
loop beside the restart step, the `-LeakRestart` child and the retried error
line. The task version setup
records (`LANAI_DISPLAY_RESTART`) is new on this branch, so the guard ships
under it with no new mark. Then the spec, README, the panel's old-task
words, and `CLAUDE.md`'s pin rule (requirement 18).

### Phase 5: proof on a copy

1. Collector, in the real elevated task: the log shows usable samples (a
   debug line during the proof only), with the measure matching a separate
   `Get-CimInstance` read within 5%, also after a driver restart moves the
   driver to a new host process.
2. Input: with the measure over the limit, a key or a mouse move through the
   Looking Glass window every 4 minutes holds back the routine restart for
   15 minutes.
3. Routine: replug until the measure passes the limit, then leave Windows with
   no input. Pass: within 7 minutes the task logs a routine guard restart
   with its numbers, the host process changes, the measure falls near a
   fresh driver's (record it at the window's size), Windows' commit falls
   by about as much as the measure, a frame at the window's size follows,
   and the Windows key and a mouse move work.
   Once with the window on a hidden workspace; record whether the picture
   returns when the window is shown.
   This step is a gate for the routine rule (see "Known interaction"
   under part E), run twice more: once with the window hidden for the 5
   idle minutes and the restart, then shown; and once with the host monitor
   off (`hyprctl dispatch dpms off`) through them, then on. That blanks
   John's screen, so it runs only with his go, or he runs it by hand. Each
   time the picture is live and the Windows key and a mouse move work. If
   not, routine restarts stay off until the client fix lands.
4. Emergency: replug with a mouse move every 30 s. Pass: a restart at the
   first sample over twice the limit, not before, and within 30 minutes of
   the last guard restart.
5. Low commit: a test process in Windows commits memory it never touches
   (commit charge, no RAM) until Windows has about 3.5 GiB of commit free,
   and holds it. Then replug for 30 minutes with a mouse move every 30 s.
   Pass: emergency restarts come on the free-commit rule, Windows' free
   commit never drops under 1 GiB, and no hang comes. Then stop the process.
   (A fixed small page file was the first plan. The copy's next restart
   hung, so the test holds commit instead; see the phase 5 result.)
6. Soak: the burst script runs for 2 hours with the production build and the
   commit sampler. Expected: no hang, each burst makes one ask, Windows'
   commit stays under its level after start plus twice the limit, and each
   guard restart is in the log. This supports part A but does not prove it,
   because the old rate was about one hang per 400 replugs.

#### Phase 4 result (2026-11-23)

The guard is in `guest/lanai-scale.ps1`, with 10 new cases in
`test/guest.bats` (120 in the file). Removing or weakening each of 35 rules
in a copy of the task, one at a time, made a case fail each time
(`~/lanai-proofs/resize-hang-phase3/phase4-rule-removal.txt`, after the
implementation review's fixes). The panel needs no new
words: the old-task message already says the window may freeze after quick
resizes, and the guard ships under the same task mark.

#### Phase 5 result, steps 1 to 5 (2026-11-23 and 24)

Run on the phase 3 copy (8 GB, limit 1 GiB) with the guard's task plus a
debug line for each sample. Steps 1 to 6 ran the script from before the
implementation review's fixes (the idle read order, the freed check's
60 s bound, and the host's owner and path checks); step 1 then ran again on
the final script (below). The evidence is in
`~/lanai-proofs/resize-hang-phase3/p5/`.

1. Collector: a sample matched a separate `Get-CimInstance` read exactly
   (200,671,232 bytes, host 1796), and after each driver restart the samples
   followed the new host process. Again on the final script (2026-11-24,
   `step1-final.txt`): 999,145,472 bytes at host 11064 in both reads; after
   a `pnputil` restart, 163,807,232 bytes at the new host 12428 in both.
2. Input: with the measure at 1,246 MB, a Shift key every 4 minutes held the
   restart back for 15 minutes.
3. Routine: the restart came 5 minutes 6 s after the last key. The host
   changed (1796 to 13956), the measure fell from 1,246 to 167 MB (1,079
   MB), and Windows' free commit rose by about as much, from 14,356 MB in
   the restart line to 15,437 MB in the next sample (1,081 MB). With the
   window hidden, a new session
   and a frame at the window's size followed, the client's threads waited
   normally with no bad subscriber bit, input and clipboard went back to
   LGMP, the Windows key opened Start, and a mouse move advanced the pointer
   queue.
   The gate's two runs ran on 2026-11-24 on the final script with the debug
   line (`p5/gate-hidden/`, `p5/gate-dpms/`). Hidden: the restart came 5
   minutes 2 s after the last key (1,179 to 153 MB, host 1160 to 11040), and
   a new session and a frame at the window's size followed while the window
   stayed hidden. When John showed it 16 minutes later, the picture was
   live, the Windows key opened Start and the mouse moved the pointer.
   Monitor off: workspace 9 was shown and the monitor turned off at the last
   key. The restart came 5 minutes 4 s later (1,204 to 153 MB, host 1192 to
   4284). When the monitor came back on, the picture, the Windows key and
   the mouse worked, the client's threads waited normally, and input and
   clipboard were on LGMP. The gate passes, so the routine rule stays on.
   One child was slow in the monitor-off run: its PowerShell engine started
   37.6 s after the guard's decision, and pnputil ran at 40.9 s, 4 s inside
   the 45 s stop. The other 57 guard restarts in the copy's log took 4 s or
   less, three test starts just after took 0.26 to 0.66 s, and no event in
   Windows' logs explains it (`p5/gate-dpms/child-start-events.txt`). A stop
   at 45 s would have counted one failure (requirement 23).
4. Emergency: with a mouse move every 30 s, samples from 1,070 to 1,812 MB
   brought no restart. The first sample over 2 GiB (2,109 MB) restarted the
   driver in the same second, 4 minutes after the routine restart. The
   driver went to a new host at 264 MB.
5. Low commit: a test process held 11,776 MB of commit, which left Windows
   3,637 MB free. In 30 minutes of replugs the guard made 30 emergency
   restarts, one a minute as the child rules allow, all on the free-commit
   rule (the first at 601 MB, under the 1 GiB limit, with 2,993 MB free).
   Each one freed the memory. Free commit never dropped under 1,899 MB, and
   no hang came. Between restarts the measure climbed from about 300 to
   1,400 MB a minute at back-to-back replugs of large sizes, which is near
   the 1.5 GiB a minute that part E plans for. Five restarts also logged
   `QueryDisplayConfig failed` from the scale task's display read during the
   restart; the task has logged that line 19 times since 2026-10-12, so it is
   not new.

The fixed small page file was tried first, with an 800 MB page file. The
copy's next restart hung at the boot logo. With a VGA device added to see
the screen, Windows' repair found no cause, and every boot hung while
Windows' hypervisor was on (the VirtualMachinePlatform feature turns it on).
With the hypervisor off, Windows booted. With the hypervisor back on and the
VGA device removed, it booted too, so VGA with the hypervisor caused the
later hangs. The first hang came before VGA was added, so its cause is not
proven; the small page file under the hypervisor is the likely one. Lanai's
VM has no VGA device.

#### Phase 5 result, step 6 (2026-11-24)

Soak, 01:15 to 03:15, with the production build, the feed, the commit
sampler and phase 3's bursts, the window on a hidden workspace and no
input. Pass on each point:

- No hang: 1,276 of 1,276 bursts brought a frame at the final size, in
  about 2 s each, with no stall line.
- One ask a burst: the client asked 1,281 times, each a first try, with no
  repeat; the 5 more than the bursts follow new sessions.
- Commit: from 4,602 MB at start, it peaked at 5,977 MB, under the
  6,650 MB line (start plus twice the limit).
- Guard: 24 restarts, each logged with its numbers, each freed (to 147 to
  275 MB), with no failure.

All 24 restarts were emergencies at about 2 GiB, one each 4 to 5 minutes,
and none was routine: each came within 30 minutes of the one before, so
the routine rule's 30-minute gap held it back, as part E intends. Under
steady replugs the emergency rule does the work, and the driver holds up
to twice the limit between restarts. Each line also gives 4 or 5 minutes
with no input, counted from the restart before it: a driver restart resets
Windows' idle time (`GetLastInputInfo`). That does not change the outcome
here, since the 30-minute gap alone blocks a routine restart.

## Decisions

John accepted both on 2026-11-21:

1. The 2 s settle (requirement 4): Windows follows a drag resize about 1.4 s
   later than today.
2. The restart line on the scale channel (requirements 12 and 15): it widens what
   the scale task does with its existing admin rights. The other choice was a
   separate admin task in Windows with its own port, which means a second admin
   piece for setup to install and keep whole.

John accepted this one on 2026-11-21, after phase 0:

3. The scale task confirms the hang from the driver log before it restarts
   (requirement 13). This ties Lanai to the wording of the pinned IDD's log,
   which a pin change rechecks (requirement 18). The other choice was to accept
   false restarts: a window larger than the driver allows, such as a
   full-screen window on a 5K monitor, would cost 3 display flickers in every
   VM run.

John chose this on 2026-11-23, after phase 3 step 1 found the leak:

4. Add the guard (part E) and report the leak upstream. The guard restarts the
   driver before the leak fills Windows' memory, at a time with no input,
   or at once in an emergency (even during input, and even within 30
   minutes of the last one), and the hang recovery stays as the backstop. The other choices were to ship
   without a guard (the leak still fills memory over days of use, and each
   hang then costs a stall and a restart), or to wait for an upstream fix (no
   date, and the IDD stays pinned until then).

## Review log

| Stage | Round | Findings | Result |
| --- | ---: | ---: | --- |
| design (gpt-6.1-sol, high, blind) | 1 | 9 | Two P1 and seven P2, all confirmed against the files and integrated: a defined stall lifecycle, including a client that starts on a hung display (B6-B8); a pending recovery that waits for the scale port and resends within limits (C10-C11); the settle clock fed by raw size changes (A1); restart-safe follower state (C9); spec 12's timing amended (D15); the cause stated as provisional (Problem); phase 3 on a test build with the detector, and phase 0 naming the state it reproduced; a portable device selector with bounded failures (C13); and both kinds of line in a batch (C12). The review's manifest check failed only on the manifest's own entry (an author error); the 19 other inputs matched. |
| design (gpt-6.1-sol, high, follow-up with round 1 findings) | 2 | 4 | Round 1: five resolved, four partly. Four new P2, all confirmed and integrated: a stall survives a new session and ends only on a frame, and the client unit stopping ends a recovery (B7, C10); a unique client ID on the log's second line, since the first line's epoch can repeat and two readers parse that line strictly (C9); every attempt recorded before the write, an atomic state file, and a warning whenever no attempt is left (C9, C11); spec 12 measured from the last raw size change, with a stall exception (D15). Manifest: 21 of 21 matched. |
| design (gpt-6.1-sol, high, follow-up with round 2 findings) | 3 | 1 | Round 2's four and round 1's partly-resolved items: all resolved except one. One P2, confirmed and integrated: an event with no window size change, such as a resolution picked in Windows, is measured from that event, not from an older window resize (D15), with a module case for it. The author verified the fix directly against `spec.md:300-308` and `0001`'s "late-change" case. Manifest: 22 of 22 matched. The review cap of three cycles is reached; the design gate is closed. |
| design, part C changes after phase 0 (gpt-6.1-sol, high, blind; a fourth round John approved past the cap) | 4 | 2 | Approve with changes. Two P2, both confirmed against the source and integrated. (1) A missing `Starting session` cannot prove a declined send: upstream's connect loop has no 30 s deadline, and an unrelated reconnect can log one. Each send's outcome is now unknown; sends retry within a per-recovery limit (3, 60 s apart), and only sends a session followed within 60 s count toward the run's 3 restarts, so declines cost nothing. The "stuck" warning became a neutral no-picture note (C9-C11). (2) The driver-log rule detects an unfinished replug, not a hang, and `CMonitorManager.cpp:241-255` shows a departure failure that logs `ReplugMonitor` and stays healthy. Now a departure failure cancels a candidate; the check reads complete lines only and confirms the same candidate twice, 10 s apart by a monotonic timer, not log times; a missing replug means no restart; the risk of a healthy replug slower than 10 s is stated and accepted, with the author's measurement: of 2,119 distinct replugs in the logs, 2,114 finished in 3 s or less and the other five were all hangs, including a 33-minute unfinished replug that was the 2026-11-19 freeze (C13, C18, acceptance). The adapter selector had no finding; case-insensitive matching and one-argument passing were added. Manifest: 28 of 28 matched at start and end. |
| implementation, phases 1 and 2 (gpt-6.1-sol, high, blind, on a snapshot of 7da5c15 with the patched pinned source) | 1 | 3 | Approve with changes. Three P2, all confirmed against the code and fixed, each with a test that fails when its fix is removed. (1) The 45 s stop killed only the child powershell.exe, so a blocked pnputil ran on and a second could start beside it: the task now stops the child with `taskkill /T /F`, keeps it until it exits, and starts no child while it or any `pnputil.exe` runs (C13). (2) A session counted only when read within 60 s of the send, so a feed that missed passes for a minute lost restarts and could send a fourth: a session now counts whenever it is read while the send is watched, and a pass clears the watch only after it reads the new lines (C11). (3) A new client log between the ID read and the send could get one send meant for the old client: the feed reads the ID again after the QMP call and sends nothing when it changed. Security, client timing, the hang rule, the adapter selector, docs and panel words had no finding. Manifest: 1,459 of 1,459 matched at start and end. |
| implementation, phases 1 and 2, second provider (claude-opus-5-5, high, blind, on a snapshot of the round 1 fixes with round 1's log row removed) | 2 | 11 | Approve with changes. Three P2 and eight P3; all checked against the code. Fixed, each with a test that fails when its fix is removed: (1) the 45 s stop came after its log line, so a failed write skipped the stop and blocked every later restart; the stop now comes first. (2) The panel never showed the no-picture note that spec 12 and the README promise; it now does. (3) A slow or failed `systemctl` ended a live recovery for good, since the client logs a stall once; that state is now unknown and neither ends a recovery nor sends. (7, P3) A guest that forges client log lines could start a recovery each pass with an immediate send; any two sends in a run are now 60 s apart, and spec 27 names every guest string and effect. Fixed without a new test: (4) the child's exit code could read as empty in Windows PowerShell 5.1; the task keeps its handle (phase 3 checks the log line). (8) The child compiled the unused display API; it now starts before the compile. (11) The gap case comment and the host case count. Wording only: (5) the task limits child starts, so two restarts come at least 25 s apart, now stated; (6) the 4 s gap holds within a display session, as requirement 3 keeps a new session's behavior; README says about half a minute. Not changed: (9) a hang with no ask outstanding gets no stall line, which matches requirement 6; (10) the feed's wall clock (changed in round 3, below). Manifest: 1,458 of 1,458 matched at start and end. |
| implementation, follow-up on both rounds' fixes (gpt-6.1-sol, high, with both results and the dispositions) | 3 | 3 | Approve with changes. Round 1's findings 2 and 3 and round 2's findings 1-5, 7-9 and 11 resolved; round 1's finding 1 and round 2's finding 6 partly; round 2's finding 10 not resolved. Fixed, each with a test that fails when its fix is removed: (1, P2) round 2's finding 10 was wrongly declined: a forward wall clock step during a recovery cleared the watch before the new session came, so a restart went uncounted and a fourth send could follow. The recovery now times sends, watches, gaps and the note by seconds since boot (`boot_seconds`, `/proc/uptime`), in the feed and in `lanai status`. (2, P3) The guest tests replaced the stop and the pnputil lookup: a new case runs the real helpers and checks `taskkill /PID <id> /T /F` and the lookup by name. The stop of a real blocked pnputil on Windows is for phase 3. (3, P3) Spec 12 now says the 4 s gap holds within a display session. Manifest: 1,461 of 1,461 matched at start and end. This is the third and last review cycle. |
| design, part E (gpt-6.1-sol, high, blind, on 719f043 with the part E draft) | 1 | 6 | Reject. One P1, four P2 and one P3, all checked and integrated. (1, P1) The 30-minute gap could block a restart while memory ran out: an emergency rule now ignores input and the gap, at twice the limit or with under 2 GiB of free commit, with the growth rate and margin stated (requirement 21). (2) The 2-minute success check could read new growth as a failed restart: the check now uses the first sample 10 s after the child exits and asks for a drop under half (23). (3) A stuck WMI query could stall the scale loop and the 45 s stop: a collector runspace takes the samples, and the loop uses only fresh ones (19). (4) No input is not the same as nobody watching: tested in the copy, neither `CallNtPowerInformation` nor `powercfg /requests` showed another program's display request, so the flicker during a video or slideshow is stated as an accepted tradeoff, and the README names it and the emergency rule (16, 21). (5) Sample validity: one host, found again each sample, the same ID and start time after the query, no rows means no sample; the healthy margin rests on the fixed 128 MiB frame memory; a missing class leaves part C as the backstop (19, 20). (6, P3) The hang claims now cite the event log exports for hangs 1 and 2 and phase 0's hangs 2 and 3, and the sampler for hang 3. Also stated: a guard restart near a host send counts as a restart seen. The reviewer read the live checkout's instruction files before reading the isolation rule; it changed nothing. Manifest: 294 of 294 matched at start and end. |
| design, part E, second provider (claude-opus-5-5, high, blind, on the round 1 fixes with round 1's log row removed) | 2 | 9 | Approve with changes. Four P2 and five P3, all checked and integrated. (1) The leak explains the unfinished-replug hangs only: phase 0's hang 1, in the 2026-11-19 state, had no low-memory event, and John's live 2026-11-21 freeze did (Problem). (2) The 285 MB baseline was taken after replugs: a fresh driver now measured 136 MB at 1280x800 and 191 MB at 3840x2160, and freed means under half the trigger or under 512 MiB (20, 23). (3) The leak rate was an average, not the maximum: about 100 MiB a replug at the largest size, so up to 1.5 GiB a minute; samples now come every 10 s, an emergency is retried each tick, and its free-commit line is 4 GiB, with a low-commit run in phase 5 (19, 21). (4) A routine restart comes when the window is likely hidden: two hidden restarts on the copy left the client healthy, and phase 5 makes it a gate, with routine restarts off until the client fix if it fails (part E, phase 5). P3: the display-request test is stated as weak; WQL underscores escaped, the DLL matched without regard to case, a monotonic clock, an unsigned idle difference, WMI timeouts and `GlobalMemoryStatusEx` for memory and free commit (19-21); every failed child ending named, and when the guard's stop resets (23); the pin rule covers what part E reads (18); wording (a wake that ends in an ask, the two hosts' sums, about 750 replugs, no Windows 10 version claim, no error 1450 claim). Manifest: 296 of 296 matched at start and end. |
| design, part E, follow-up on both rounds (gpt-6.1-sol, high, with both results and the dispositions) | 3 | 3 | Approve with changes. Of the 15 prior findings, 10 resolved and 5 partly; the partly resolved ones are closed by the fixes below or by the phase 5 gates. Fixed: (1, P2) the freed check could still read growth during the 10 s wait as a failed restart (a modeled 600 MiB trigger, a 191 MiB fresh driver and four quick replugs give 591 MiB): freed now rests first on a new host process, which every traced restart produced (1084 to 7224, 1204 to 2736 to 1796), with the measure as the fallback at the first sample after the exit, within 60 s (23); the modeled sequence is a test case. (2, P2) Two acceptance cases contradicted the emergency rule: the under-limit case now excludes the emergency conditions and adds 600 MiB with 3.9 GiB free on 8 GiB, and the shared child case separates routine waits from emergency retries. (3, P3) The tradeoff and decision 4 now say that emergencies can come during input and within 30 minutes. Also added from the table: phase 5 checks the host change, the measure's fall and Windows' commit fall together, and the gate runs with the monitor off, with John's go. The author checked each fix against the plan text. Manifest: 298 of 298 matched at start and end. This is the third and last review cycle; the design gate for part E is closed. |
| implementation, phases 4 and 5 (gpt-6.1-sol, high, blind, on a snapshot of 719f043 plus the working tree, with the phase 5 evidence) | 1 | 5 | Approve with changes. Four P2 and one P3, all confirmed against the code; the code ones fixed, each with a case that failed before its fix. (1) The idle time read the clock before the last input, so input between the two reads gave 49.7 days: the input tick is now read first. (2) The freed check took a sample from after its 60 s bound: it now takes only one taken within 60 s of the exit. (3) A look-alike `WUDFHost.exe` or `LGIdd.dll` a user starts could hide the real host and blind the guard: the host must now be System32's program with System32's `LGIdd.dll` (round 2 found this not enough). (4) The gate for routine restarts has not run: it waits for John. (5) Some phase 5 claims had no record, and the step 3 commit rise was wrong (1.8 GB; it is 1,081 MB): the claim is corrected, and the records and the rule-removal output are saved. Manifest: 168 of 168 matched at start and end. |
| implementation, phases 4 and 5, second provider (claude-opus-5-5, high, blind, on a snapshot with round 1's fixes and with round 1's log row absent) | 2 | 6 | Approve with changes. Four P2 and two P3, all confirmed. (1) A user can run the real System32 `WUDFHost.exe` and load an `LGIdd.dll` from a System32 folder users can write, so the path check could not keep the real host visible: the host must now be run by a service account (LocalSystem, LocalService or NetworkService; the copy's runs as LocalService), checked before any module read, and a process that ends during the read is skipped. (2) The phase 5 runs used the script before round 1's fixes: step 1 ran again on the final script (an exact match, and again after a driver restart moved the host), and the plan says which script each step ran. (3) The routine gate: as round 1's (4), it waits for John. (4) Rules with no failing case (any pnputil running, the minute after a guard child that ends at once, an emergency starting the 30-minute gap, a reused process ID, the guard's error catch), and four more from the reviewer's own removals: each now has a case; 35 of 35 rule removals fail a case. (5) A failed idle read stopped an emergency: the emergency now starts and logs that the input time could not be read. (6) The soak's routine restarts were held back by the 30-minute gap, not the idle reset: the result and `proofs.md` say so, and no change is needed. Manifest: 176 of 176 matched at start and end. |
