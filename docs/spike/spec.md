# Spike spec: Looking Glass software mode vs RDP

Tier: Full. Plan: [plan.md](plan.md).

## Problem

The plugin idea rests on one unmeasured claim. gnif says Looking Glass IDD software mode
is "far better than libvirt/vnc/rdp" (Level1Techs, 2026-07-25). No one has published
numbers, and the project's own docs call software mode a slower, SDR-only fallback. If
it does not clearly beat RDP, a plugin adds complexity for nothing, because
`omarchy-windows-vm` already gives users RDP.

## Question

On the same Windows 11 VM, does Looking Glass software mode feel clearly better than
Omarchy's current RDP setup for office and admin work, at an acceptable host CPU cost?

## Requirements

1. Both transports run against one guest, one VM configuration and one host, one at a
   time. Only the transport differs.
2. RDP uses Omarchy's client setup: the same FreeRDP flags minus the credentials, the
   same scale logic, the same Kerberos workaround and the same window title. The
   forwarded port may differ.
3. The VM matches what `omarchy-windows-vm` runs (dockur's QEMU flags plus Omarchy's
   compose settings, including 16 GiB RAM and 6 cores). The only allowed differences:
   - the display path (Looking Glass shared memory and IDD, SPICE for audio and clipboard)
   - the network backend (passt, run by QEMU as the user, instead of dockur's tap NAT in
     a container)
   - the guest setting that lifts Windows' default 30 fps cap on RDP sessions, so RDP
     is measured at its best
   - the SMBIOS serial (dockur copies the host serial, which only root can read)
4. The Looking Glass client and IDD come from one pinned build, `B7-826-236efcb1`. Every
   download is verified by SHA-256.
5. Spike tooling never writes to the live `omarchy-windows-vm` disk. The spike boots a
   copy taken while that VM is stopped, and it refuses to copy while any QEMU holds the
   disk. Calibration uses the live VM the normal way, as John does every day.
6. No spike tooling runs as root. Calibration runs `omarchy-windows-vm` the way users
   run it today, including its root Docker daemon and polkit prompt; that is the
   baseline being measured, not spike tooling.
7. Every run records host CPU time, rendered resolution and Windows display scale.

## Security surface

The spike adds a shared-memory path that carries guest video and cursor data, SPICE
and QMP control sockets (SPICE carries keyboard and mouse input), and a networked VM.
Sockets and the shared-memory file live in the user-only `$XDG_RUNTIME_DIR`. RDP is
forwarded on `127.0.0.1` only.

User-mode networking usually maps the guest's gateway to the host's loopback, which
would let the guest reach every host service bound to `127.0.0.1`. The spike turns that
mapping off. Acceptance check: first confirm a service listens on the host's loopback
only (CUPS on port 631 today; a temporary test listener if not). Then, from the guest,
that service is unreachable, while web browsing and DNS still work.

## Test protocol

**Setup for every session:**
- Boot the VM. Wait until the guest is idle (Task Manager under 5% CPU for a minute).
  The first boots on new virtual hardware run driver installs.
- Match the guest display for each paired test. In both transports the guest desktop
  resolution equals the viewer window size (both resize the guest to the window), and
  the Windows scale matches what RDP gets from its scale logic. The two viewer windows
  have the same size and position. Both run the guest at 60 Hz, and the animation runs
  at the same cadence in both. Record guest resolution, scale and refresh rate.
- Use the same content and actions for every pair: one named web page, one named Excel
  workbook, one fixed PowerShell command and one video, all fixed in the plan. One
  person rates every session. The transport tested first alternates from pair to pair.
- Make the Looking Glass window opaque, as Omarchy already does for the RDP window.
- Select the Looking Glass audio device as the Windows output when using Looking Glass.

**Modes:** run each task fullscreen on the 4K monitor, then as a tiled window about half
the screen.

| # | Task | Measure |
|---|---|---|
| 1 | Type in Notepad | Film at 240 fps. Count frames from keypress to glyph, 10 or more keypresses per transport per mode, report the median. Rating: typing feel. |
| 2 | Scroll a long web page and a long Excel sheet; run the frame-index animation | Animation: record the host's compositor output for 10 s and count frame-index advances per second in the animation's region (below). Ratings: web scroll, Excel scroll. |
| 3 | Drag and resize a window for 10 s | Rating: window drag |
| 4 | Play one fixed 60 s segment of one YouTube video, quality locked to 1080p; confirm resolution and codec in "Stats for nerds" each run | Ratings: video smoothness, A/V sync. CPU: 3 runs alternating LG and RDP, median |
| 5 | Idle desktop for 60 s | CPU: 3 runs alternating LG and RDP, median |
| 6 | Scroll PowerShell output in Windows Terminal | Ratings: text sharpness, terminal scroll |
| 7 | Copy text both ways; play a system sound | Works yes/no |
| 8 | Leave a session open 30 min, lock and unlock the host once | Survives yes/no. Yes means: within 10 s of unlock, with no user action, the viewer shows a live desktop, typing and mouse work, and a system sound plays. A reconnect or restart counts as a fail. |

**Frame-index animation:** a page whose every frame carries a machine-readable index,
such as a block that steps through a fixed color sequence, one color per rendered
frame. The count reads the index in each recorded frame. An advance counts once; a
repeated index is a repeat, not a new frame; a skipped index counts as a missed frame.
Cursor movement and compression artifacts cannot change the count.

**Counter check:** before task 2, play the same animation natively on the host at known
30 fps and 60 fps, at the same size and position, and record it the same way. Do this
twice: once while the spike VM and one viewer run, and once while the real
`omarchy-windows-vm` and its RDP viewer run. Each count must read within 10% of the true
rate.

**Ratings:** 1-5, one per named item in the table (eight in all); they are never
combined. Anchors: 1 unusable, 2 distracting all the time, 3 noticeable but workable,
4 hard to spot, 5 indistinguishable from a native Linux app.

**CPU:** whole-host CPU time from `/proc/stat` over the run, minus a baseline taken over
the same length with no VM running. This counts every process and kernel thread the
transport uses, on both the spike VM and the real one.

**Calibration:** run tasks 1-6 on RDP against the real `omarchy-windows-vm`, CPU tasks
with 3 runs and the median. The spike VM adds overhead that the real one lacks: passt
networking on the RDP path, and any IDD work that continues while RDP is
connected. The decision rule uses the better of the two RDP results.

## Decision rule

"CPU" is the idle-subtracted whole-host measure above. "One refresh" means one refresh
interval of the host monitor (4 frames at 240 fps for a 60 Hz panel). "RDP" means, per
measure and mode, the better of spike RDP and real RDP from calibration. Go to a plugin
spec if all of these hold:

- Looking Glass rates at least equal on all eight ratings, in both modes.
- In at least one mode, Looking Glass is clearly better on a measured number, and in
  that same mode at least one rating is 1 point or more higher:
  - task 1: its median latency is lower by at least one refresh, or
  - task 2: the animation shows at least 25% more frame-index advances per second.
- Looking Glass CPU is no more than 1.5x RDP on tasks 4 and 5.
- Tasks 7 and 8 pass, or pass once a workaround is applied and shown working in the
  spike. An untested explanation counts as a fail.

Otherwise, stop. Record why.

## Out of scope

GPU passthrough, the plugin UI, the Windows install flow, and TPM or Secure Boot. The
copied VM was installed by dockur in its default `windows` boot mode, which uses
neither: the storage folder has no `windows.mode` or `windows.tpm` state.

## Carry forward to the plugin spec

- The guest must not reach services on the host's loopback. The spike proves out the
  approach (passt with that mapping off).

## Review log

Rounds 1 and 2 of stage a ran on the combined spec+plan doc, before the task moved to
the Full tier. Counts cover the whole combined doc.

| Gate | Stage | Round | Findings |
|---|---|---|---|
| spec | a | 1 (full, combined doc) | 1 blocker, 8 should-fix, 4 nits; all integrated |
| spec | a | 2 (full, combined doc) | 1 blocker, 9 should-fix, 5 nits; all integrated |
| spec | a | 3 (delta) | 2 should-fix, 3 nits; all integrated |
| spec | a | 4 (delta) | 1 should-fix, 3 nits; integrated with the reviewer's wording; stage a clean |
| spec | b | 1 (full) | 3 blockers, 3 should-fix; all confirmed and integrated |
| spec | b | 2 (full) | 2 blockers, 3 should-fix; all confirmed and integrated |
| spec | b | 3 (full, cap) | 6 should-fix; all confirmed; John adjudicated (take the recommendations); integrated. Gate closed. |
