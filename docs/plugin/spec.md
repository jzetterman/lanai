# Plugin spec: Lanai v1 (Windows through Looking Glass)

Tier: Full. Background: [spike spec](../spike/spec.md) and
[spike results](../spike/results.md).

## Problem

Omarchy users who need Windows apps, such as Office, or Windows-only admin tools, such as
the Active Directory PowerShell modules, run Windows with `omarchy-windows-vm`. It shows
Windows over RDP: a remote session with encoding lag and an RDP client's quirks. Looking
Glass can show the same VM through shared memory, without GPU passthrough, as an
ordinary resizable window. Nothing packages that for Omarchy.

## Goal

Lanai (plugin id `io.github.jzetterman.lanai`) is an Omarchy shell plugin. It runs the
user's existing `omarchy-windows-vm` install in plain QEMU as the desktop user and shows
it through Looking Glass. A user who already has Windows from `omarchy-windows-vm` can
install the plugin, finish a one-time setup, and use Windows from their bar.

## Users

- Office users who need Windows desktop apps a few times a week.
- Sysadmins who need Windows-only tools and reach internal systems through the host's
  network, VPN or Tailscale.

Neither needs GPU acceleration.

## Requirements

### Adopting the existing install

1. Lanai runs the Windows install that `omarchy-windows-vm` created: the same disk and
   firmware state in `~/.windows`. It does not convert the disk.
2. The guest sees the same virtual hardware it had under `omarchy-windows-vm`: CPU model
   and flags, disk controller, NIC model and MAC (`windows.mac`), UEFI firmware and
   variables, and a real-time clock in the host's time zone. Windows boots without
   driver errors, and its activation state is unchanged. The allowed differences are the
   display path, the network backend, the file-sharing path, the devices Looking Glass
   needs, a setup-only display and read-only setup media, and the SMBIOS serial (dockur
   copies the host's serial, which only root can read).
3. Lanai and `omarchy-windows-vm` never run the VM at the same time, and Lanai never
   runs two copies of its own VM.
   - Lanai refuses to start while the container VM runs. It detects that without Docker
     access and without any password prompt.
   - While Lanai's VM runs, a container start never boots Windows and never changes the
     disk's contents, the firmware, the firmware variables or the MAC. Lanai cannot stop
     a root container from running, so the plan lists every file the verified dockur
     version can write before its VM starts, and shows each write is blocked or leaves
     Windows' data unchanged.
4. After the user stops Lanai's VM, `omarchy-windows-vm` works as before. RDP remains a
   fallback on the same install.
5. Lanai recognizes only the `omarchy-windows-vm` layouts and boot modes it was verified
   against. For anything else (no install yet, a TPM or Secure Boot install, a legacy
   layout), it refuses with a clear message and points to the fix. It does not install
   Windows in v1. The README names the Omarchy and dockur versions Lanai was verified
   against.
5a. Lanai does not gate on the dockur version, just as `omarchy-windows-vm` does not
   (John, 2026-09-28). Requirement 3's "a container start changes nothing" is shown for
   the verified dockur versions. For any version, Lanai checks at every start that the
   firmware, firmware variables and MAC files are present and the disk is at its full
   configured size, which closes every pre-boot write path known in dockur. The panel
   may show the dockur version when it can read it, as information only. The README
   names the remaining risk: do not start `omarchy-windows-vm` while Lanai runs Windows.
6. Lanai keeps its own VM settings (memory and CPU cores). Setup fills them from
   `omarchy-windows-vm`'s settings when it can read them without a prompt. Otherwise it
   uses half the host's memory, at most 16 GiB, and half the host's CPU threads, at
   most 8. From those settings it reads only the memory and core values; it
   never keeps, logs, shows or passes on the Windows password stored beside them. The
   user can change the settings in the panel. They apply at the next start.
6a. Lanai's storage location defaults to `~/.windows` and can point at a copy, so every
   check can be rehearsed without touching the user's only install. Everything Lanai
   does to VM storage (checks, snapshot, restore, boot) uses the configured location.

### One-time setup

7. The panel guides the user through a one-time setup that:
   - before the first Lanai boot, with both the container VM and Lanai's VM stopped,
     offers an instant snapshot of the configured storage
     location (a copy that shares its data blocks, such as a btrfs or XFS reflink copy)
     where that location's filesystem supports it, so a bad first boot can be undone. It
     says where the snapshot lives, that it grows as Windows changes, and how to delete
     it. Where the filesystem cannot make one, setup says so and suggests a backup
     instead. Restoring the snapshot also requires both VMs to be stopped. Lanai refuses
     to snapshot or restore while either VM runs, and holds the disk lock QEMU uses for
     the whole operation, so a container VM cannot boot while it runs;
   - installs the host packages Lanai needs, in a terminal that shows the exact command
     before it runs, with the system's normal password prompt;
   - installs one pinned Looking Glass client build, verified by checksum;
   - installs the matching Looking Glass IDD, the SPICE guest agent and, for the clock
     sync in requirement 21, the QEMU guest agent inside Windows;
   - asks the user to restart Windows once after the guest install. The spike showed that
     Looking Glass input does not work until that restart.
8. The Looking Glass client on the host and the IDD in the guest come from the same
   pinned build. Lanai detects a mismatch and says how to fix it. When a Lanai update
   changes the pin, the update keeps the user with a working Windows window throughout,
   or shows the exact steps to restore one. When Looking Glass cannot show Windows at all
   (a failed IDD, a mismatch, a recovery screen), the fallback is to stop Lanai and use
   `omarchy-windows-vm` (RDP or its web console), and Lanai says so.
9. Setup can be rerun safely. A partly finished setup is detected and resumed or
   repaired.

### Daily use

10. The bar widget shows the VM's state as text or tooltip, not color alone: not
    installed, setup needed, stopped, starting, running, stopping, in use by
    `omarchy-windows-vm`, version mismatch, or failed. Each non-running state names its
    cause and one next step. "Failed" also says where the logs are and names the
    `omarchy-windows-vm` fallback (requirement 8).
11. From the bar and panel, the user can start Windows, open the Windows window, and shut
    Windows down. The panel also holds setup, settings, errors and the forced stop.
    Panel actions are reachable from the keyboard where the Omarchy shell allows it.
12. The Windows window behaves like any Omarchy window. It tiles, goes fullscreen and
    resizes, and the Windows desktop follows its size. At start, Windows uses the display
    scale step (100 to 250 in steps of 25, then 300 to 500 in steps of 50) nearest the
    focused monitor's scale, with ties rounded down (John, 2026-09-28). A host scale
    change applies at the next Windows start or sign-in.
13. Keyboard, mouse, clipboard (both ways) and audio output work in the Windows window.
14. At the Windows sign-in screen, the user types the password they chose when
    `omarchy-windows-vm` installed Windows. Lanai never reads the stored credentials file
    and never handles the password (requirement 6).
15. The user can move files between Linux and Windows through a folder they can find on
    both sides. `~/Windows`, the folder `omarchy-windows-vm` already shares, is
    preferred. This requirement may move to v2 if the plan finds no mechanism that runs
    as the user (John, 2026-09-28). Clipboard transfer (requirement 13) stays in v1.
16. Shutting down from the bar is a clean Windows shutdown. If it has not finished
    within 2 minutes (for example, Windows is installing updates), the panel offers the
    forced stop. The forced stop needs a confirmation and is never the default.
17. Closing the Windows window does not stop the VM. The bar reopens it.

### VM lifetime

"Clean shutdown" means Windows shuts itself down (QEMU reports a guest-initiated
shutdown), and after the next boot Windows logs no unexpected-shutdown event (Event 41
or 6008).

18. The VM's lifetime is tied to the user's graphical session, not to the shell or the
    plugin. Restarting the Omarchy shell, or reloading, updating or disabling the
    plugin, never stops the VM. The bar finds a running VM again and shows its true
    state.
19. When the user logs out, a running VM gets a clean shutdown, whether or not the user
    has lingering services enabled. The host waits up to 2 minutes for it. On reboot or
    power-off, Lanai starts the clean shutdown the moment the host begins shutting down
    and gets as long as Omarchy's shutdown window allows (about 20 s today), without
    changing system settings (John, 2026-09-28). If either wait expires, the VM is
    force-stopped, and Lanai reports that at the next start.
20. The VM survives the host screen locking and unlocking: within 10 s of unlock, with no
    user action, the window shows a live desktop, typing and mouse work, and a system
    sound plays. A reconnect counts as a fail.
21. After host suspend and resume, the same holds, and within 60 s of resume the Windows
    clock is within 2 s of the host's.

### Networking and security

22. Nothing in Lanai runs as root after setup. The VM, its network backend and the
    Looking Glass client run as the desktop user.
23. The guest reaches the internet and everything the host can reach, including VPN and
    Tailscale destinations. It cannot reach services bound to the host's loopback.
    Services the host exposes on its other addresses stay reachable, as they are to any
    machine on the network.
24. The guest resolves names through the host's resolver, including Tailscale MagicDNS
    and the host's search domains. The README notes that a DNS client installed inside
    Windows (such as Cloudflare WARP or a corporate agent) overrides this.
25. Lanai opens no network listeners. Its control channels and shared memory are
    reachable only by the desktop user.
26. Every file Lanai fetches itself is pinned and checked before use: by SHA-256 for
    files, and by commit plus the SHA-256 of the fetched source (submodules included) for
    source builds. System packages come from the signed Arch repositories.

### Trust model

27. The guest is untrusted. Besides the baseline emulated hardware that requirement 2
    keeps (CPU, disk controller, NIC, firmware, clock, USB controller and tablet), the
    accepted guest-to-host surfaces are: the frames and cursor
    data the Looking Glass client reads from shared memory; SPICE (input, audio and
    clipboard); the network backend; the file share, if present; and a time-sync-only
    guest agent channel, if the plan needs one for requirement 21. Nothing else.
28. The file share, if present, is confined to `~/Windows`. The guest cannot reach any
    other host path through it, including through symlinks or `..`.
29. The README states the clipboard exposure: while the Windows window runs, the guest can
    read anything copied on the host.

### Coexistence and presentation

30. Lanai's display name, glyph and VM process name differ from the four existing Windows
    plugins and from `omarchy-windows-vm`'s container, so users can tell them apart. The
    README says that those plugins show "stopped" while Lanai runs the VM, and that
    starting the container then fails safely (requirement 3).
31. Lanai meets the Omarchy plugin marketplace's submission rules: manifest, README with
    install and removal steps, license, and documented dependencies. Because setup uses
    the package manager and a native build, the expected listing is a manual-setup,
    maintainer-reviewed one, not a one-click install.
32. Removing Lanai leaves the Windows install and `omarchy-windows-vm` working. The README
    lists what setup installed and how to remove it, and its removal steps first stop
    the VM with a command that works without the plugin.

## Acceptance criteria

Every check is first rehearsed with Lanai pointed at a reflink copy of `~/.windows`
(requirement 6a). Destructive checks run only on a copy or a test install. John runs the
non-destructive checks on his live install only after the rehearsal passes.

`omarchy-windows-vm` always uses the calling user's `~/.windows`, so checks that start
its container (rows 3, 4 and 30-32) run on a test install: a separate machine or VM whose
`~/.windows` is a copy. Not another account on John's machine: `omarchy-windows-vm`
keeps one system-wide compose file, container name and port set. Row 3 never runs
against the live install.

"No disk damage" means: with Lanai's VM paused (disk flushed, locks and files still
held), the storage location's full file list, and every file's size and SHA-256, are the
same before the container start attempt and after the container has exited or been
stopped; Windows then resumes, boots after a restart, and `chkdsk` reports no errors.

| Requirement | Check |
|---|---|
| 1-2 | Lanai's VM configuration matches the verified `omarchy-windows-vm` configuration in every item requirement 2 lists, apart from the allowed differences; inside Windows, the MAC, CPU model and disk device match their values recorded before adoption; Device Manager shows no errors; activation state is unchanged |
| 3 | Starting the container while Lanai runs does not boot Windows and causes no disk damage; starting Lanai while the container runs is refused with a clear message; starting Lanai while the container is still preparing (before its VM process exists) does not boot a second VM; a second Lanai start is refused |
| 4 | After Lanai stops, `omarchy-windows-vm` boots and RDP works |
| 5 | A fixture of each unsupported layout (none, TPM, Secure Boot, legacy) gets its refusal message |
| 5a | With a firmware, variables or MAC file missing, or the disk below its configured size, Lanai refuses to start and says why; the README states the remaining risk |
| 6 | Settings seed from `omarchy-windows-vm` when readable, and otherwise from the stated host-relative defaults, with no prompt; with a sentinel password set on the test install, the sentinel never appears in Lanai's files, logs, setup terminal output, or any child process's arguments or environment; changed settings take effect at the next start |
| 6a | Lanai pointed at a reflink copy boots the copy and never opens the live `~/.windows` |
| 7 | On a machine with a working `omarchy-windows-vm` install, a user who follows the README reaches a working Windows window from the bar; setup shows one package-manager password prompt and asks for one Windows restart; where the storage location's filesystem can make an instant copy, setup offers the snapshot, and restoring it returns the storage location to its pre-adoption hashes; where it cannot, setup says so and suggests a backup; snapshot and restore are each refused while either VM runs; a container start attempted during a snapshot or restore does not boot a VM, and the snapshot still matches its source |
| 8 | A deliberate client/IDD mismatch is detected and named; a simulated pin change keeps or restores a working window |
| 9 | Interrupting setup at each step, then rerunning it, ends in a working install |
| 10-17, 20 | Each passes a scripted or checklist test (list in the plan); requirement 12 is checked with a scale matrix: each step, a value just above and below each boundary, a tie (for example 112.5% gives 100%, 275% gives 250%), the 250-300 gap, and values below 100% and above 500% (clamped to the nearest end). If requirement 15 is moved to v2 (recorded in this spec before the release gate), its check and the requirement 28 check are skipped |
| 18 | Shell restart, plugin reload, plugin update and plugin disable each leave Windows running, and the bar shows its true state afterwards |
| 19 | Logout ends in a clean shutdown, with lingering both enabled and disabled; a guest that ignores shutdown at logout is force-stopped after 2 minutes and reported at the next start; on reboot and power-off, Windows' shutdown starts when the host's does, an idle Windows shuts down cleanly within the window, and a forced stop is reported at the next start |
| 21 | After suspend and resume, the requirement 20 check passes, and the guest clock is within 2 s of the host's within 60 s |
| 22, 25 | While the VM runs: no Lanai process runs as root; no new listening TCP or UDP socket appears; Lanai's Unix control sockets and runtime files, including the shared-memory file, are mode 0600 or inside a 0700 directory owned by the user |
| 23-24 | The spike's security check passes against Lanai's VM: the host-loopback probe is blocked after a positive control; a web page loads; on a guest without its own DNS client, a MagicDNS name and a short name through the host's search domain resolve through Windows' default resolver; the same names resolve when queried at the gateway (the diagnostic for guests with a DNS client such as WARP); a VPN destination and a host service on a non-loopback address are reachable |
| 27 | A review of QEMU's command line and device tree (QMP `info qtree`) shows only the baseline hardware from requirement 2 plus the listed channels, and nothing else |
| 29 | The README states the clipboard exposure |
| 26 | Setup refuses a download or source with a wrong checksum |
| 28 | From the guest, attempts to leave `~/Windows` through `..` and a planted symlink fail |
| 30-32 | Review against the marketplace rules; removal steps from the README, run on a test install, leave `omarchy-windows-vm` working |

## Release gate

Lanai is not released until the spike's measured protocol has run and its decision rule
passes ([spike results](../spike/results.md), "Status"). "Released" means any of: making
the repository public, tagging a release, or submitting to the marketplace.

## Out of scope for v1

- Installing Windows without `omarchy-windows-vm` (planned for v2).
- GPU passthrough, SR-IOV, and a dedicated partition or NVMe for Windows.
- USB device passthrough, including smart cards and security keys. A likely v2 need for
  sysadmins.
- Microphone input. A likely v2 need for Teams calls.
- Starting Windows automatically at login.
- Multiple VMs, multiple monitors, and HDR.

## Review log

| Gate | Stage | Round | Findings |
|---|---|---|---|
| spec | a | 1 (full) | 1 blocker, 11 should-fix, 5 nits; all integrated |
| spec | a | 2 (full) | 8 should-fix, 4 nits; all integrated |
| spec | a | 3 (delta) | 3 should-fix, 3 nits; all integrated (scale rule: John chose nearest Windows step) |
| spec | a | 4 (delta, cap) | 1 should-fix, 3 nits; integrated with the reviewer's wording; stage a clean |
| spec | b | 1 (full) | 1 blocker, 5 should-fix; all confirmed (item 2 reframed: reflink copy, not subvolume snapshot); integrated |
| spec | b | 2 (full) | 3 blockers, 1 should-fix; all confirmed. The integration failed silently (script error), so round 3 reviewed the unchanged text; integrated after round 3 |
| spec | b | 3 (full, cap) | Reviewed the stale round-2 text: items 1-2 repeat round 2's blockers; items 3-5 new should-fix, confirmed and integrated. Unreadable dockur version: one-time confirmation (Claude's call, flagged to John) |
| spec | b | 4 (extra, approved by John after round 3 reviewed stale text) | 2 blockers, 1 should-fix; all confirmed. Dockur version: John ruled no gate and no confirmation (5a rewritten); snapshot interlock and scale matrix integrated. Gate closed. |
| spec | amendment | 2026-09-28 | Req 19 reboot/power-off changed to best effort within Omarchy's shutdown window (John's decision after research showed Omarchy caps user-session shutdown at 5 s); req 7 adds the QEMU guest agent for req 21 |
