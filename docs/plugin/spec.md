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
   display path, the network backend, the file-sharing device and path, the devices
   Looking Glass needs, the guest agent channels (SPICE agent and QEMU guest agent), a
   setup-only display and read-only setup media, a host-to-guest SMBIOS text field that
   carries the display scale (requirement 12), and the SMBIOS serial (dockur copies the
   host's serial, which only root can read).
3. Lanai and `omarchy-windows-vm` never run the VM at the same time, and Lanai never
   runs two copies of its own VM.
   - Lanai refuses to start while the container VM runs. It detects that without Docker
     access and without any password prompt.
   - While Lanai's VM runs, a container start never boots Windows and never changes the
     disk's contents, the firmware, the firmware variables or the MAC. Lanai cannot stop
     a root container from running, so the plan lists every file the verified dockur
     version can write before its VM starts, and shows each write is blocked or leaves
     Windows' data unchanged.
4. After the user stops Lanai's VM, `omarchy-windows-vm` works as before. The guest
   changes from requirement 7 stay; the one the user will notice is that the Windows
   lock stays off. RDP remains a fallback on the same install.
5. Lanai recognizes only the `omarchy-windows-vm` layouts and boot modes it was verified
   against. For anything else (no install yet, a TPM or Secure Boot install, a legacy
   layout), it refuses with a clear message and points to the fix. It does not install
   Windows in v1. The README names the Omarchy and dockur versions Lanai was verified
   against.
5a. Lanai does not gate on the dockur version, just as `omarchy-windows-vm` does not
   (John, 2026-09-28). Requirement 3's "a container start changes nothing" is shown for
   the verified dockur versions. For any version, Lanai checks at every start that none
   of dockur's known destructive or rewriting paths can trigger: the firmware, firmware
   variables and MAC files exist and are not empty; the disk dockur would select is at
   least its configured size and its first 100 KB are not all zero, and there is only
   one disk file (not both `data.img` and `data.qcow2`); the install-complete marker
   (`windows.boot`) exists; `windows.base` is empty, or names the image dockur derives
   from the container's Windows version and language settings, in its `.iso` form; and
   no `custom.iso` or `boot.iso` sits in the storage location. When Lanai cannot read
   `omarchy-windows-vm`'s settings without a prompt, it compares `windows.base` with the
   image for the values `omarchy-windows-vm` always sets (Windows 11, no language) and
   skips the disk-size check (John, 2026-09-28); growing the disk only adds space and
   never overwrites Windows data. If any check fails, Lanai refuses to start and says
   why. The panel may show the dockur version when it
   can read it, as information only. The README names the remaining risks: do not start
   `omarchy-windows-vm` while Lanai runs Windows, and do not change its container
   settings (Windows version, language, disk size or format, CLEAR, custom ISO mounts)
   while Lanai is in use.
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
   - installs inside Windows, with one administrator prompt: the matching Looking Glass
     IDD, the SPICE guest agent, the QEMU guest agent (clock sync, requirement 21), the
     file-sharing client (requirement 15), and the sign-in task that applies the display
     scale (requirement 12). The same prompt also turns off locking inside Windows for
     the Windows user who runs setup; two of the changes, Switch user and the machine
     inactivity lock, apply to every account on that Windows. Setup refuses, before
     changing anything in Windows, if the administrator prompt is approved with a
     different account. After setup, until the user or a policy turns it back on,
     nothing can lock that user's session: not the Lock or Switch user commands, not an
     idle or screen-saver lock; wake from sleep and Dynamic Lock must be unable to
     trigger. A locked Windows ignores the shutdown request Lanai sends, so a locked VM
     would be force-stopped (phase 1, proof 4). The Linux session's lock protects an
     open Windows window instead (John, 2026-09-28). What changes: Windows no longer
     locks itself or on request, so an unattended, unlocked Linux session leaves Windows
     open for as long as the VM runs, and the user has to lock Linux to cover it. What
     does not change: dockur already signs Windows in automatically at every boot, RDP
     and the container's web console both still ask for the Windows password, and any
     process running as the user can already read the stored password. Setup replaces
     any lock settings the user had. If Windows is joined to a domain or enrolled in
     MDM, setup says that a policy may turn the lock back on, and that shutdowns may
     then end in the forced stop. The README says the lock is off, why, what changes and
     what does not (as above), and that Switch user and the inactivity lock are off for
     every account; that setup replaced any lock settings the user had, and that the
     restore steps bring back Windows' defaults, not those settings; that turning it
     back on, or a policy, brings back the forced stop; that any Windows security screen
     left open (such as a UAC prompt) may also need the forced stop; and how to turn the
     lock back on;
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
    change applies at the next start of Lanai's VM.
13. Keyboard, mouse, clipboard (both ways) and audio output work in the Windows window.
14. When Windows asks for a password (dockur normally signs in automatically), the user
    types the one they chose when `omarchy-windows-vm` installed Windows. Lanai never
    reads the stored credentials file and never handles the password (requirement 6).
15. The user can move files between Linux and Windows through a folder they can find on
    both sides. `~/Windows`, the folder `omarchy-windows-vm` already shares, is
    preferred. Research found a mechanism that runs as the user (virtiofs), so this
    requirement is in v1. It may still move to v2 only if that mechanism fails its
    checks (John, 2026-09-28). Clipboard transfer (requirement 13) stays in v1.
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
    changing system settings (John, 2026-09-28). This is best effort: the README states
    how long Windows took on John's machine. If either wait expires, the VM is
    force-stopped, and Lanai reports that at the next start, naming a locked Windows, an
    open Windows security screen, or a shutdown that did not finish in time as likely
    causes.
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
    machine on the network. Windows also starts when the host has no network, for
    example on a plane. It then has no network until Lanai's VM next starts, and Lanai
    says so when it starts it (John, 2026-09-28).
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
    accepted guest-to-host surfaces are: the frames, cursor data, and clipboard contents
    (text, images and files) the Looking Glass client exchanges over shared memory; SPICE
    (input, audio and clipboard); the network backend; the file share; and the QEMU
    guest agent channel, which Lanai uses only to set the guest clock (requirement 21).
    Nothing else.
28. The file share, if present, is confined to `~/Windows`. The guest cannot reach any
    other host path through it, including through symlinks or `..`.
29. The README states the clipboard exposure: while the Windows window runs, the guest can
    read anything copied on the host, including files, and files copied in Windows appear
    on the host in a read-only folder under the user's runtime directory.

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
    lists what setup installed or changed in Windows and how to undo it. Its removal
    steps first restore Windows' default lock settings inside Windows, under Lanai or
    over RDP under `omarchy-windows-vm` (setup keeps no record of earlier values). Then
    they shut Windows down from its Start menu, since a restored lock can drop the stop
    request, and, if Lanai's VM still runs, stop it with a command that works without
    the plugin.

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
| 4 | After Lanai stops, `omarchy-windows-vm` boots and RDP works; in that session, Lock in Start, Windows key + L and idling past the leftover screen-saver timeout still do not lock Windows |
| 5 | A fixture of each unsupported layout (none, TPM, Secure Boot, legacy) gets its refusal message |
| 5a | A fixture for each failing check (missing or empty firmware, variables or MAC file; disk below its configured size; zeroed first 100 KB; both `data.img` and `data.qcow2` present; missing `windows.boot`; a `windows.base` that does not match the configured version and language; a `custom.iso` or `boot.iso` present) makes Lanai refuse to start and say why; the README states the remaining risks |
| 6 | Settings seed from `omarchy-windows-vm` when readable, and otherwise from the stated host-relative defaults, with no prompt; with a sentinel password set on the test install, the sentinel never appears in Lanai's files, logs, setup terminal output, or any child process's arguments or environment; changed settings take effect at the next start |
| 6a | Lanai pointed at a reflink copy boots the copy and never opens the live `~/.windows` |
| 7 | On a machine with a working `omarchy-windows-vm` install, a user who follows the README reaches a working Windows window from the bar; setup shows one package-manager password prompt and one Windows administrator prompt, and asks for one Windows restart; where the storage location's filesystem can make an instant copy, setup offers the snapshot, and restoring it returns the storage location to its pre-adoption hashes; where it cannot, setup says so and suggests a backup; snapshot and restore are each refused while either VM runs; a container start attempted during a snapshot or restore does not boot a VM, and the snapshot still matches its source |
| 7b | Before setup, each lock path locks Windows or leaves it at the sign-in screen: Lock in the Start menu and in Ctrl+Alt+Del, Switch user, Windows key + L sent with QMP `send-key`, and each automatic lock the VM can trigger, turned on at a 1-minute timeout (secure screen saver, machine inactivity limit). After setup, with the screen-saver timeout still at 1 minute (setup leaves it set but not secure) and the inactivity limit as setup left it, none of them does; Windows is still unlocked after idling past every timeout; Windows reports no sleep state it could wake from, and row 27 shows no Bluetooth device. A shutdown with the Ctrl+Alt+Del screen left open is recorded (clean, or the README names it). Setup's domain or MDM warning appears when its membership check reports membership (simulated). Approving the prompt with a different administrator account makes setup refuse; afterwards nothing differs from the before-setup inventory (dockur already installs some pieces, such as its own file-sharing service and guest agent): the lock controls still lock, the Looking Glass IDD and the scale sign-in task are absent, the guest agent's allow-list is not applied, and Lanai has not added or replaced any file-sharing piece. The README states the lock note from requirement 7 |
| 8 | A deliberate client/IDD mismatch is detected and named; a simulated pin change keeps or restores a working window |
| 9 | Interrupting setup at each step, then rerunning it, ends in a working install |
| 10-17, 20 | Each passes a scripted or checklist test (list in the plan); requirement 12 is checked with a scale matrix: each step, a value just above and below each boundary, a tie (for example 112.5% gives 100%, 275% gives 250%), the 250-300 gap, and values below 100% and above 500% (clamped to the nearest end). If requirement 15 is moved to v2 (recorded in this spec before the release gate), its check and the requirement 28 check are skipped |
| 18 | Shell restart, plugin reload, plugin update and plugin disable each leave Windows running, and the bar shows its true state afterwards |
| 19 | Logout ends in a clean shutdown, with lingering both enabled and disabled, including with row 7b's 1-minute screen saver still set (no longer secure) and running at logout; a guest that ignores shutdown at logout (fixture: turn the Windows lock back on and lock Windows, or leave open a security screen that row 7b recorded as ignoring shutdown, then log out) is force-stopped after 2 minutes and reported at the next start, naming a locked Windows, an open security screen, or a shutdown that did not finish in time as likely causes; on reboot and power-off, with lingering both enabled and disabled and an idle, unlocked Windows, Windows' shutdown starts when the host's does, the time Windows took is measured and written in the README, and the next start reports no forced stop; with the logout fixture above, a reboot whose wait expires ends in a forced stop that the next start reports |
| 21 | After suspend and resume, the requirement 20 check passes, and the guest clock is within 2 s of the host's within 60 s |
| 22, 25 | While the VM runs: no Lanai process runs as root; no new listening TCP or UDP socket appears; all of Lanai's Unix sockets (control, file sharing, guest agent) and runtime files, including the shared-memory file, are mode 0600 or inside a 0700 directory owned by the user |
| 23-24 | The spike's security check passes against Lanai's VM: the host-loopback probe is blocked after a positive control; a web page loads; on a guest without its own DNS client, a MagicDNS name and a short name through the host's search domain resolve through Windows' default resolver; the same names resolve when queried at the gateway (the diagnostic for guests with a DNS client such as WARP); a VPN destination and a host service on a non-loopback address are reachable; with the host's network off, Windows starts, and Lanai's start reply says it has no network |
| 27 | A review of QEMU's command line and device tree (QMP `info qtree`) shows only the baseline hardware from requirement 2 plus the listed channels, and nothing else |
| 29 | The README states the clipboard exposure |
| 26 | Setup refuses a download or source with a wrong checksum |
| 28 | From the guest, attempts to leave `~/Windows` through `..` and a planted symlink fail |
| 30-32 | Review against the marketplace rules; removal steps from the README, run on a test install, leave `omarchy-windows-vm` working; after the README's restore steps, Lock in Start and Windows key + L lock Windows again, Switch user is offered again and leaves the session at the sign-in screen, and a secure screen saver, once the tester turns it on, locks at its timeout |

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
| spec | amendment | 2026-09-28 | From plan research: req 5a covers dockur's destructive paths (delete on missing `windows.boot` or zeroed disk start; move on a custom or boot ISO, or a changed version or language); req 12 scale applies at next VM start via an SMBIOS text field (Claude's call, flagged to John); req 15 in v1 via virtiofs; req 7 lists all guest installs; reqs 27 and 29 include clipboard files |
| spec | amendment review | 2026-09-28 | 0 blockers, 6 should-fix, 4 nits; all integrated (clipboard channel confirmed LGMP from the spike's client log) |
| spec | amendment | 2026-09-28 | From plan Codex round 1: req 5a, when the settings are unreadable, uses `omarchy-windows-vm`'s fixed values for the base check and skips the size check (John's decision) |
| spec | amendment | 2026-09-28 | From the phase 1 proofs: a locked Windows drops the ACPI power button (proof 4), so req 7 turns off locking inside Windows (John's choice over a guest-agent forced shutdown); req 32 and rows 7 and 19 follow |
| spec | amendment review (a) | 2026-09-28 | Delta round: 0 blockers, 5 should-fix, 2 nits; all confirmed and integrated (lock stays off under `omarchy-windows-vm`, removal restores it, positive controls in row 7, domain/MDM note, wording, req 14 auto sign-in) |
| spec | amendment review (a) | 2026-09-28 | Round 2 (full): 0 blockers, 8 should-fix, 5 nits; all confirmed and integrated. Item 1 corrected a false claim: `omarchy-windows-vm` sets `PROTECT: "Y"`, so the web console asks for the password too. Req 32 restores the lock inside Windows before the stop; req 7 states the result and the small real exposure; row 7b split out |
| spec | amendment review (a) | 2026-09-28 | Round 3 (delta): 2 should-fix, 5 nits (one plan-side); all confirmed and integrated (README restore-to-defaults note; row 7b's after-state stated; scope and refusal; removal order; forced-stop causes checked in row 19) |
| spec | amendment review (a) | 2026-09-28 | Round 4 (delta, cap): 1 should-fix, 2 nits; all integrated (the different-account refusal happens before any change and row 7b tests it; row 30-32 wording; rewrap). Checked: `omarchy-windows-vm` sets `restart: "no"`, so a Start-menu shutdown leaves the container down. Stage a closed |
| spec | b Grok (substitute) | 2026-09-28 | Codex out of credits. Round 1 (full): 3 P2, 1 P3; all confirmed and integrated (the real change stated plainly: an unattended, unlocked Linux session leaves Windows open; row 19 names a force-stop fixture; row 7b's refusal checks that nothing was installed; the two machine-wide changes named) |
| spec | b Grok (substitute) | 2026-09-28 | Round 2 (full): 2 P2, 2 P3; all confirmed and integrated (row 4 checks the lock stays off under `omarchy-windows-vm`; row 7b's refusal checks every guest change; forced-stop causes include a slow shutdown; row 30-32 checks Switch user) |
| spec | b Grok (substitute) | 2026-09-28 | Round 3 (full, cap): 2 P2, 1 P3; all confirmed and integrated (row 19 splits the clean reboot from the forced-stop fixture; row 7b's refusal compares against the before-setup inventory, since dockur already installs its own file-sharing service and guest agent; row 4 parenthetical dropped). Stage closed at the cap |
| spec | amendment | 2026-09-28 | From the phase 4 review: req 23 lets Windows start with no host network (passt's local mode; checked by two reviewers), and row 23-24 tests it (John's decision) |
