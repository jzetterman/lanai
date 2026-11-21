# Windows freezes after quick resizes

Combined spec and plan for two changes. The first is a new Looking Glass client
patch, `patches/looking-glass/0004-client-resize-settle.patch`. The second is a
recovery path: the client notices the hang, the host passes it on, and the scale
task in Windows restarts the Looking Glass display driver.

Status: design reviewed (three rounds), 2026-11-21. No code yet. Phase 0 is next.

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
timeout. Why Windows stopped is not known. So part A below is a mitigation whose
effect is still to be measured, and part C is the recovery.

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

### A. Fewer and calmer replugs (client patch 0004)

1. The client asks Windows for a new size only after the window has not changed
   size for 2 s (`RESIZE_SETTLE_US`). The clock starts at each raw size change,
   where `core_updatePositionInfo` posts it, not when upstream `message.c` hands
   the size on after its 500 ms debounce. So a size still waiting in that
   debounce holds back an ask for the older size, and a continuous drag makes no
   ask until it stops. A burst of resizes, such as a monitor wake, makes one ask,
   for the last size.
2. Two asks are at least 4 s apart (`RESIZE_GAP_US`), whether for a new size or a
   retry of the same size. The first retry wait grows from 2 s to 4 s, and the
   rest of the retry table (5, 10, 20 s) stays.
3. A window size below the floor, a new session, and the "did not take" give-up
   behave as today.
4. Tradeoff, accepted by John: after a drag resize, Windows follows the window
   about 2 s after the drag stops, not about 0.6 s. The constants live in
   `resize.h`.

### B. Notice the hang (client patch 0004)

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
   resets the count. A refusal on a desktop that draws nothing for 10 s can look
   like a stall. Phase 0 checks whether that happens, and the cost of a false
   restart is one display flicker, within the limits of requirement 11.

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
   - whether a recovery is pending, and when it started;
   - each restart attempt in this VM run, with its time.

   The feed writes the state to a temporary file and renames it over the old
   one, so an interrupted write leaves the old state whole.
10. A stall line makes a recovery pending. These end it: a `frames from Windows
    again` line, a new client generation, the client unit not running (the
    feed checks it at each poll), or the end of the VM.
11. While a recovery is pending, the feed sends `lanai-display-restart` only when
    QEMU reports the scale port's guest side open (`frontend-open` on `scale0`,
    as setup's step 6 check reads it). So a stall before the scale task starts,
    such as before sign-in, waits instead of being lost. It tries again while
    the recovery stays pending, at most once every 60 s and at most 3 attempts in
    one VM run. Before each write, it records the attempt in the state file, so
    every attempt counts, whether the write succeeds, fails or is cut off: the
    count errs toward fewer restarts. Whenever a recovery is pending and no
    attempt is left (after 60 s with no frames for the third attempt, or a fourth
    stall after three recoveries), it sends nothing more, and `lanai status`
    warns that Windows' display is stuck and that a restart of Windows fixes it.
    Scale lines keep flowing as today while a recovery waits.
12. The scale task accepts the exact line `lanai-display-restart` and nothing
    longer or different. Restart lines and scale lines are separate kinds in a
    drained batch:
    - Scale lines keep today's rule: one valid scale line applies, and two or
      more are stale and dropped.
    - One or more restart lines in a batch, in any order with scale lines, make
      one restart.
13. For a restart, the task selects the Looking Glass display adapter by its
    device ID pattern, which phase 0 records and must be the same on every
    install (for example, an instance ID under `SWD\LGIDD\`). It acts only when
    exactly one device matches, and logs and does nothing for none or several.
    It runs `C:\Windows\System32\pnputil.exe /restart-device <instance ID>` in a
    child process with a 30 s limit, so a stuck restart cannot stop scale
    handling. It logs the exit code. Exit code 3010 (reboot needed) and any
    other failure are logged, not retried by the task: the host's next send
    is the retry. It restarts at most once a minute.
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
      acts on that line only by restarting the Looking Glass display adapter.
16. `README.md` names the freeze, the monitor-sleep trigger and the automatic
    recovery, and says that a restart of Windows is the fallback.
17. The panel's old-client and old-task messages name the freeze fix (the
    pattern 0003 set: "may", one item per fix).

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
  - With no `frames again` line, it tries again after 60 s. After the third
    attempt and 60 s with no frames, it sends nothing more, and the status
    warning appears.
  - Three stalls that each recover, then a fourth stall: nothing is sent, and
    the warning appears.
  - A write that fails, and a feed killed between recording an attempt and
    writing: each counts as an attempt.
  - `frames again`, a new client generation, or the client unit stopping ends
    the recovery: nothing more is sent.
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
  - A nonzero exit and exit 3010 are logged. A restart that runs past 30 s is
    stopped, and scale handling goes on meanwhile.
- Every patch applies exactly, the client builds, and its tests pass
  (`test/client-patches.bats` with `LANAI_TEST_LG_TARBALL`). The bats suite,
  `bin/check` and CI pass.
- Phase 0 and phase 3 proofs below pass on a reflink copy.
- John's hand checks on his live install after the copy passes:
  - Normal wakes: let the monitor sleep and wake five times. Each wake makes one
    ask, and Windows shows the desktop at the window's size within 7 s of the
    last resize the wake caused. A wake that hangs is not counted here; it falls
    under recovery.
  - Recovery is checked on the copy (phase 3), not live, because forcing a hang
    takes hours of resizes.

## Constraints

- The pin and the IDD stay as they are. 0004 applies exactly after 0001-0003.
- Nothing new runs as admin in Windows. The scale task already runs with the
  setup user's admin rights (spec 27). It gets one more fixed action, through the
  one exclusive reader it already has.
- No network listener and no change to the guest agent's allow-list.
- Agents test on a reflink copy, not on John's live VM, unless John gives a go
  for that step.
- Out of scope:
  - The 2026-11-19 afternoon freeze, which had no resize (the client was dropped
    and no ask was involved).
  - The RDP rescue port.
  - The upstream bug report. John posts it, with the two log excerpts above.

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

### Phase 1: client patch 0004, test first

Cases first, then in `resize.c`: the settle clock fed by raw size changes, the
gap, the stall detector, and the frame counter. Then the hooks: raw size changes
from `core_updatePositionInfo`, and a per-frame call in `main_frameThread`
beside the format-change hook. Add the cases to `RESIZE_CASES` and the glue
cases to `config-message-tests`. Write the patch with 0003's header style, and
update `test/client-patches.bats` for 0004. Copy the evidence above into
`docs/plugin/proofs.md`.

A test-only build switch turns off the settle and gap rules and keeps the
stall detector, so phase 3 can force hangs with the new detector.

### Phase 2: host feed and scale task, test first

The client ID line in `client_exec`. The follower, its state file and the send
rules in `lib/vm.sh`, with the `frontend-open` and client unit checks. The
status warning. The restart handler in `guest/lanai-scale.ps1`, the task
version in setup, and the panel messages.
Then the spec, README and CLAUDE.md updates.

### Phase 3: proof on a copy

1. Recovery: with the test-only build (settle and gap off, detector on), force
   the hang, and check that Lanai recovers it with no help, as phase 0's pass
   defines it. Do this three times.
2. Soak: the burst script runs for 2 hours with the production build. Expected:
   no hang, and each burst makes one ask. This supports part A but does not
   prove it, because the old rate was about one hang per 400 replugs.

## Decisions

John accepted both on 2026-11-21:

1. The 2 s settle (requirement 4): Windows follows a drag resize about 1.4 s
   later than today.
2. The restart line on the scale channel (requirements 12 and 15): it widens what
   the scale task does with its existing admin rights. The other choice was a
   separate admin task in Windows with its own port, which means a second admin
   piece for setup to install and keep whole.

## Review log

| Stage | Round | Findings | Result |
| --- | ---: | ---: | --- |
| design (gpt-6.1-sol, high, blind) | 1 | 9 | Two P1 and seven P2, all confirmed against the files and integrated: a defined stall lifecycle, including a client that starts on a hung display (B6-B8); a pending recovery that waits for the scale port and resends within limits (C10-C11); the settle clock fed by raw size changes (A1); restart-safe follower state (C9); spec 12's timing amended (D15); the cause stated as provisional (Problem); phase 3 on a test build with the detector, and phase 0 naming the state it reproduced; a portable device selector with bounded failures (C13); and both kinds of line in a batch (C12). The review's manifest check failed only on the manifest's own entry (an author error); the 19 other inputs matched. |
| design (gpt-6.1-sol, high, follow-up with round 1 findings) | 2 | 4 | Round 1: five resolved, four partly. Four new P2, all confirmed and integrated: a stall survives a new session and ends only on a frame, and the client unit stopping ends a recovery (B7, C10); a unique client ID on the log's second line, since the first line's epoch can repeat and two readers parse that line strictly (C9); every attempt recorded before the write, an atomic state file, and a warning whenever no attempt is left (C9, C11); spec 12 measured from the last raw size change, with a stall exception (D15). Manifest: 21 of 21 matched. |
| design (gpt-6.1-sol, high, follow-up with round 2 findings) | 3 | 1 | Round 2's four and round 1's partly-resolved items: all resolved except one. One P2, confirmed and integrated: an event with no window size change, such as a resolution picked in Windows, is measured from that event, not from an older window resize (D15), with a module case for it. The author verified the fix directly against `spec.md:300-308` and `0001`'s "late-change" case. Manifest: 22 of 22 matched. The review cap of three cycles is reached; the design gate is closed. |
