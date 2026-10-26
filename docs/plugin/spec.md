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
   carries the display scale and its save number (requirements 12 and 27), the scale
   channel (requirement 27), and the SMBIOS serial (dockur copies the host's serial,
   which only root can read).
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
   lock stays off. RDP remains a fallback on the same install. Under
   `omarchy-windows-vm`, the scale task changes no scale and no resolution, and keeps
   nothing running.
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
6. Lanai keeps its own VM settings (memory, CPU cores and Windows' display scale,
   requirement 12). Setup fills them from
   `omarchy-windows-vm`'s settings when it can read them without a prompt. Otherwise it
   uses half the host's memory, at most 16 GiB, and half the host's CPU threads, at
   most 8. From those settings it reads only the memory and core values; it
   never keeps, logs, shows or passes on the Windows password stored beside them. The
   user can change the settings in the panel. Memory and cores apply at the next start;
   the scale applies as requirement 12 states.
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
     the whole operation, so a container VM cannot boot while it runs. While a snapshot
     or restore runs, the panel shows what it is doing and how far it has got, as a
     progress bar with a percentage in text; that includes a panel opened partway
     through and a snapshot or restore started from the command line. Each reads the
     disk image's data once: a snapshot reads the source once and records its hashes as
     the snapshot's manifest; a restore reads the snapshot once and checks it against
     that manifest before anything changes. Neither reads the data a second time to
     check the finished copy. Instead each proves the copy holds exactly the data that
     was read and hashed, by a check of shared storage for the disk image (a byte
     compare is only for the small files), never metadata such as size and timestamps.
     The proof also covers a change to the file being read (the source, or the
     snapshot) after its read and before the proof. Lanai treats a filesystem and file
     mode as provable only when row 7's fixtures pass on it; any other counts as
     unprovable. When the
     proof fails, a snapshot keeps no complete snapshot and a restore does not finish,
     and each says so. Where a filesystem can make instant copies but Lanai cannot prove
     them this way, setup treats it as one that cannot make an instant copy;
   - installs the host packages Lanai needs, in a terminal that shows the exact command
     before it runs, with the system's normal password prompt;
   - installs one pinned Looking Glass client build, verified by checksum, with Lanai's
     patches (requirement 12);
   - installs inside Windows, with at most one administrator prompt (none when UAC is
     off): the matching Looking Glass IDD, the SPICE guest agent, the QEMU guest agent
     with an allow-list of only the commands Lanai uses (clock sync, requirement 21),
     the file-sharing client (requirement 15), and the scale task, which shows no
     window and applies the display scale at sign-in and whenever Lanai sends a new
     one, and at sign-in the desktop size from Lanai's latest ask that the display
     driver took (requirement 12). The same prompt also
     turns off locking inside Windows for the Windows user who runs setup; two of the
     changes, Switch user and the machine inactivity lock, apply to every account on
     that Windows. Setup refuses, before changing anything in Windows, if the
     administrator prompt is approved with a different account, or if the compiler
     that comes with Windows (requirement 27) is missing, and says which. If Windows
     will not run the program setup built for the scale task, setup stops at that step
     and its message names what to change. If Windows blocks or removes the program
     later, the scale and the size at sign-in stop following; the README names that
     symptom and the fix (allow the program, or turn off the Windows feature that
     blocks it, then Run setup again). After setup,
     until the user or a policy turns it back on, nothing can lock that user's session: not the Lock or Switch user commands, not an
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
     Looking Glass input does not work until that restart;
   - checks its own work and asks the user no question at its end. While file sharing
     is part of setup (requirement 15), setup checks inside Windows, before the guest
     install finishes, that the shared folder appears as a drive that the user's own,
     non-elevated session can see, and can be listed; if not, setup stops at that
     step, and its message, in Windows' setup window, says what to do, then to run
     setup.cmd again. On the boot after that restart, Lanai checks from the host,
     within requirement 27's limits: the Looking Glass IDD (the pinned client
     connects and reports the IDD's build, which must match the pin, requirement 8),
     the SPICE agent, the QEMU guest agent and its allow-list, and then the scale
     task. The scale task counts as working once its channel's port opens, a state
     QEMU reports, not data from Windows. The task opens it when the Windows user who
     ran setup signs in, and while setup waits for it, the panel says so. Setup does
     not check the applied scale: a text size the user does not like is a setting
     (requirement 12), not a setup failure. A check that gets a wrong answer stops
     setup at once and says what is wrong: an IDD build that does not match the pin
     gets requirement 8's message, and a guest agent that accepts the command its
     allow-list must refuse is named as missing its allow-list, with Run setup again
     as the way on. That command changes nothing and starts nothing in Windows, even
     when an agent accepts it. Each check also has a time limit, stated in the plan
     and counted from that boot's start (for the scale task, from when the other
     checks passed). A check that runs out of time stops setup, and its message names
     what did not answer and offers two ways on: Continue setup, which runs the
     checks again with fresh time limits, counted from the click (or from the boot it
     starts, when Windows is stopped), without repeating the guest install; and Run
     setup again, which repeats it. The message also says, as a condition, that if
     setup.cmd stopped in Windows with a message, the way on is to repeat the guest
     install, where setup.cmd runs again. A Windows restart during these checks resets
     no time limit. For the
     scale task, it also says to sign in to Windows first, as the Windows user who
     ran setup, if Windows is waiting at its sign-in screen or another user is signed
     in; Lanai cannot see that screen, so the message says it as a condition.
8. The Looking Glass client on the host and the IDD in the guest come from the same
   pinned build (a client built from the pinned source with Lanai's patches counts;
   requirement 12). Lanai detects a mismatch and says how to fix it. When a Lanai update
   changes the pin, the update keeps the user with a working Windows window throughout,
   or shows the exact steps to restore one. When Looking Glass cannot show Windows at all
   (a failed IDD, a mismatch, a recovery screen), the fallback is to stop Lanai and use
   `omarchy-windows-vm` (RDP or its web console), and Lanai says so.
9. Setup can be rerun safely. A partly finished setup is detected and resumed or
   repaired. A rerun leaves exactly one scale task in Windows.

### Daily use

10. The bar widget shows the VM's state as text or tooltip, not color alone: not
    installed, setup needed, stopped, starting, running, stopping, in use by
    `omarchy-windows-vm`, version mismatch, or failed. Each non-running state names its
    cause and one next step. "Failed" also says where the logs are and names the
    `omarchy-windows-vm` fallback (requirement 8).
11. From the bar and panel, the user can start Windows, open the Windows window, and shut
    Windows down. Left-clicking the bar icon opens the panel, or closes it when open, in
    every state. Right-clicking it starts Windows when the state (requirement 10) is
    stopped and nothing blocks a start (setup not finished, a snapshot or restore
    running, an unfinished restore); opens the Windows window when the state is running,
    setup is finished and the window is closed; and otherwise opens the panel, so a
    failed, blocked or unfinished state always shows its cause first. The icon's
    tooltip names what a right click will do in the current state. Enter or Space on the
    focused icon acts like a left click. The panel also holds setup, settings, errors
    and the forced stop. Panel actions are reachable from the keyboard where the
    Omarchy shell allows it.
12. The Windows window behaves like any Omarchy window. It tiles, goes fullscreen and
    resizes, and the Windows desktop follows its size. Windows' display scale is a
    setting: "match my monitor" (the default) or one fixed step the user chooses (John,
    2026-10-05). Steps are 100 to 250 in steps of 25, then 300 to 500 in steps of 50.
    The scale can change while Windows runs, without a restart or sign-out (John,
    2026-10-10). Terms:
    - The setting is "match my monitor" or a fixed step. Only a scale save changes it. A
      panel save is a scale save when the user selected an entry in the scale list since
      the panel opened, even the entry already shown; otherwise it changes only memory
      and cores. `lanai settings` with three arguments is always a scale save, with two
      never.
    - A pick is a scale change the scale task did not make, at a resolution that has not
      changed for at least 5 seconds, such as a step the user picks in the Scale list of
      Windows' display settings. A change of Windows' recommended scale, even one that
      lands seconds after the resolution settles, is not a pick.
    - The target is the step of the pick while it holds; otherwise the fixed step, or
      under "match my monitor" the step for the monitor that counts.
    - The applied scale is the target capped at what Windows allows for the window's
      current resolution.

    Rules:
    - "Match my monitor" uses the step nearest the scale of the monitor the Windows
      window is on, with ties rounded down (John, 2026-09-28). When the window moves to
      a monitor with a different scale, or that monitor's scale changes, Windows follows
      within 5 seconds, also while the panel is closed and while the window is closed.
      While the window is closed, the monitor it was last on since the VM started
      counts, also across a shell or plugin restart; before it first opens, the focused
      monitor at start counts. If that monitor is gone, the focused monitor counts; if
      none is focused, the first monitor Hyprland lists; if Hyprland lists none, the
      target stays as it was. Following keeps working while the Omarchy shell or the
      plugin is not running.
    - A scale save while Windows runs sends the new target to Windows, which applies it
      within 5 seconds and drops any pick. A save that is not a scale save sends nothing
      to Windows. A `lanai settings` scale save made while the shell or plugin is down
      applies the same way.
    - A pick holds until the next scale save, a sign-out, a Windows restart, or the VM
      stopping. While it holds, the scale task does not change it back and "match my
      monitor" does not follow. A pick never changes the setting. When a pick ends
      without a save, the latest target applies within 20 seconds of the next sign-in
      (the scale task loads slowly while Windows signs in).
      The scale task changes any other scale change back to the applied scale. The scale
      applies to the Windows user who ran setup, as the lock change does (requirement
      7).
    - A resolution change never changes the target, whatever its cause (a resize, or
      the size rule below). Within 5 seconds of the last resolution change, the applied
      scale is the target capped for the new resolution: it drops when the resolution
      falls below what the target needs and goes back up when it grows. For a change in
      the first 20 seconds after a sign-in, the bar is 20 seconds from the sign-in
      instead, when that ends later.
    - The channel runs one way, from Lanai to Windows (requirement 27), so the panel
      cannot see whether anyone is signed in or what Windows applied. Near the scale
      list, the panel says that saving a scale replaces one picked in Windows. After a
      scale save while Windows runs, it shows one message: the change applies within 5
      seconds if the user is signed in to Windows, otherwise at sign-in. A save while
      the VM is stopped applies at the next start.
    - When the scale task in Windows comes from a setup run before this change, the
      panel says instead that the change applies at the next start, and that until setup
      runs again the old task undoes picks in Windows and "match my monitor" does not
      follow while Windows runs; "Run setup again" brings live changes and turns the
      Windows lock off again (requirement 7). With the old task, the follow rule above
      does not apply. Lanai decides this from its own setup record; a record without
      the new task's mark counts as old.
    - Size (John, 2026-10-12). While the window is open, Windows' resolution matches the
      window's size in the monitor's pixels, with no resize by the user. Windows'
      resolution is its desktop's size; the frame's size is evidence of it, except from
      a Windows start or a sign-out until the sign-in step has seen the desktop match
      (the sign-in bullet below); a step that stops for another reason does not show
      a match. An event that starts a new display session (the window opens or reopens;
      Windows starts or restarts; Windows' display driver restarts) is matched within 5
      seconds of the session's first frame. Windows cannot set its desktop to an asked
      size before a user signs in, so for a Windows start or restart, and for an event
      at the sign-in screen, the match comes within 15 seconds of the sign-in of the
      Windows user who ran setup instead, or of the session's first frame if that comes
      later (the README says another user may need to resize the window once). An event
      during a session (the window tiles, goes fullscreen, leaves fullscreen or resizes;
      it moves to a monitor with another scale; Windows' resolution changes for any
      other reason, including a sign-in after no window size change and no ask at the
      sign-in screen, or a resolution picked in Windows' Display settings) is matched
      within 5 seconds of the event. The window always wins; the README tells users to
      resize the window to change Windows' resolution. Matching may wait, or stop until
      the next trigger, only for a size Windows does not allow; for a Windows start or
      restart, or an event at the sign-in screen, until 15 seconds after the Windows
      user who ran setup signs in; or while Windows keeps leaving the size within a
      minute of Lanai's last ask (the asks, sign-in and floor bullets below).
    - Lanai asks for a size only while Windows responds: its display driver is
      connected, has shown a frame in the current display session, and has read Lanai's
      previous ask. At most one ask is unread at a time; a newer size replaces a waiting
      ask, and a waiting ask does not count. When a trigger finds Windows at another
      size, Lanai asks at once, then again after waits of 2, 5, 10 and 20 seconds, each
      counted from the previous ask, while Windows still differs, then stops; a match
      stops the asks. Triggers: the window's size changes, a new display session
      starts, or Windows' size changes. A change of Windows' size within 60 seconds of
      Lanai's last ask continues that sequence: its asks so far count, and its next ask
      comes when its next wait after the previous ask ends, or at once if that time has
      passed. So a Windows that keeps leaving the size cannot cause a loop. Each ask Windows takes rebuilds its
      display, a brief flicker, so a size Windows will not take costs at most 5 asks,
      and then Windows stays at its own size until the next trigger.
    - After Windows starts, its frame can reach the asked size while its desktop stays
      at the old size, so the client can see a match that is not there. So at each sign-
      in of the Windows user who ran setup, the scale task (requirement 27) also sets
      the Looking Glass display's desktop to the size Windows' display driver stored
      from Lanai's latest ask that it took (from this or an earlier run), if the desktop
      differs. It reads that size again at each try and tries until they match or 2
      minutes pass. It stops early when Windows reports that it does not support the
      size, and after 3 switches that Windows reported done while the desktop still
      differs, with a log line; it retries any other failure. It acts on no other
      display and has no size of its own: with no Looking Glass display attached (under
      `omarchy-windows-vm`, or with the driver disabled) or no stored size, it does
      nothing. It changes nothing else, and its log says what it found and did, with
      times. A pin change (requirement 8) checks the step again, since it relies on
      where the pinned display driver stores the ask.
    - Lanai never asks for a size under 640 wide or 480 high, the smallest the display
      driver takes (an ask that small moved Windows to 1920x1080 in the test, John's
      call, 2026-10-12). Windows keeps its last size and the client scales the picture
      to fit the window. Windows also refuses a size too large for the frame memory
      Lanai gives Windows (fullscreen on a very high-resolution monitor); that size gets
      the bounded asks above. For a size Windows allows, the 5 seconds above hold. The
      client's log names each window size change it sees (and, for a size under the
      floor, that it will not ask) and each ask with its size, and says once per
      sequence, 5 seconds after its last ask while Windows still differs, that Windows
      did not take the size. The README says that Windows keeps its last size in those
      two cases, may flicker or show a notice while Lanai asks for a size too large,
      and that resizing the window or leaving fullscreen fixes it.
    - Lanai changes the Looking Glass client only through patches kept in this
      repository and applied exactly to the pinned source when Lanai builds the client;
      a patch that does not apply exactly stops the build. A client built this way
      counts as the pinned build for requirement 8. The patches add no message and
      change no message's format. They change only three things: when the client sends
      the window-size message it already sends, that the pointer scale stays as it was
      across a restart of the Looking Glass host in Windows (the frame size and the
      window set the scale; a restart by itself changes neither, and a frame of a new
      size recomputes it), and what the client logs. The IDD stays the pinned build. The
      patches carry Looking Glass's license (GPL-2.0-or-later): its full text ships
      beside them, and the README and, where its format allows, the manifest say that
      Lanai is MIT except those patches. Lanai can tell whether the installed client was
      built with the current patches, including a patch whose content changed.
    - An install whose client was built without the current patches keeps working with
      that client. The panel says that after the computer wakes from sleep, the mouse
      may reach only part of Windows, and that Windows may start at, or change to, the
      wrong size, until the user runs the one step that builds the fixed client, and
      names the step. That build step changes nothing in Windows: no administrator
      prompt, no Windows restart and no change to the Windows lock. The fixed client
      takes over the next time the window opens, and the build step's last message says
      to close and reopen the Windows window. When the scale task is also old, "Run
      setup again" is the one step instead: it builds the client too, and its own
      restart of Windows brings up the fixed client. Until then the bar and the panel
      start and show Windows as before. When the client in use is an older pin's build
      (requirement 8), requirement 8's update message is the one next step instead.
    - An install whose scale task was set up by a Lanai without the sign-in step above
      (Lanai's setup record lacks its current mark) keeps working. The panel says that
      after Windows starts, Windows may stay at its old size until the window is
      resized, and names "Run setup again" as the one step, which turns the Windows lock
      off again (requirement 7). "Run setup again" also builds the fixed client, so when
      the client is old too, it replaces the build step, and the panel names what it
      fixes, including the mouse after a wake. When the live-scale upgrade message also
      applies (a scale task from a setup run before live scale, above), the panel shows
      one message that names "Run setup again" and what it fixes. Requirement 8's update
      message takes the place of this message and the build step's when it applies.
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
    within 15 seconds (for example, Windows is installing updates or has hung), the
    panel offers the forced stop (John, 2026-10-23; was 2 minutes). The forced stop needs a confirmation and is never the default.
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
    (text, images and files) the Looking Glass client exchanges over shared memory, and
    the IDD's build it reports there, which Lanai only compares with the pin, names in
    its mismatch message, and on a match records to pick the matching installed client
    (requirement 8);
    SPICE (input, audio and clipboard); the network backend; the file share; the QEMU
    guest agent channel, which Lanai uses only to set the guest clock (requirement 21)
    and, at setup's checks, to send one command that the allow-list must refuse;
    and the scale channel (requirement 12). Nothing else. The scale channel runs one
    way. Each message from Lanai holds a scale step and a save number that grows with
    each scale save, and nothing else; a message whose save number differs from the one
    before it is a scale save. A guest that never reads the channel, or floods it,
    cannot block, slow or grow the memory of any Lanai or shell process: a send that
    cannot go through is replaced by the latest one, and the scale task gets the latest
    target whenever it starts or reconnects. The save number never goes down during a VM
    run, across shell and plugin restarts, whichever command makes the save. Lanai never
    parses or acts on anything the guest writes to the channel. The scale task runs as
    the Windows user who ran setup, with that user's administrator rights (the port
    opens only to administrators) and no prompt, from files only administrators can
    change. Apart from the pinned files requirement 7 installs (requirement 26), Lanai
    puts no prebuilt program of its own in Windows: setup or the scale task builds
    any code of Lanai's that the task runs or loads, from this repository's source,
    with a compiler that comes with Windows, called by its full path. A build reads
    only files that only administrators can change, and writes only to folders that
    only administrators can change. One copy of the scale task runs at a time: one
    program and the one scale script it started. If either part ends, the task is
    whole again within 5 minutes. The channel adds no network listener, and the
    guest agent's allow-list stays as requirement 7 sets it.
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
| 4 | After Lanai stops, `omarchy-windows-vm` boots and RDP works; in that session, a scale picked in Windows stays, the scale task's log shows it changed nothing (no scale and no resolution), no scale task process remains, each scale task start in that session ends within 10 seconds (Task Scheduler's history), and no scale task window appears in that session over 10 minutes; in that session, Lock in Start, Windows key + L and idling past the leftover screen-saver timeout still do not lock Windows |
| 5 | A fixture of each unsupported layout (none, TPM, Secure Boot, legacy) gets its refusal message |
| 5a | A fixture for each failing check (missing or empty firmware, variables or MAC file; disk below its configured size; zeroed first 100 KB; both `data.img` and `data.qcow2` present; missing `windows.boot`; a `windows.base` that does not match the configured version and language; a `custom.iso` or `boot.iso` present) makes Lanai refuse to start and say why; the README states the remaining risks |
| 6 | Settings seed from `omarchy-windows-vm` when readable, and otherwise from the stated host-relative defaults, with no prompt; with a sentinel password set on the test install, the sentinel never appears in Lanai's files, logs, setup terminal output, or any child process's arguments or environment; changed memory and cores take effect at the next start |
| 6a | Lanai pointed at a reflink copy boots the copy and never opens the live `~/.windows` |
| 7 | On a machine with a working `omarchy-windows-vm` install, a user who follows the README reaches a working Windows window from the bar; a setup that does not stop partway shows one package-manager password prompt and at most one Windows administrator prompt (none when UAC is off), and no other Windows prompt (the driver-publisher prompt may appear only when Windows refuses to record the publisher's trust, which setup says on screen), and asks for one Windows restart; where the storage location's filesystem can make an instant copy, setup offers the snapshot, and restoring it returns the storage location to its pre-adoption hashes; where it cannot, setup says so and suggests a backup; snapshot and restore are each refused while either VM runs; a container start attempted during a snapshot or restore does not boot a VM, and the snapshot still matches its source; a snapshot and a restore each show a progress bar that advances while they run, also in a panel opened partway through and for one started from the command line; the bytes read from the files of the storage location, the snapshot and the copy, counted at the read calls so the page cache cannot hide a second read, total no more than one image size plus a stated allowance for the small files; two fixtures, each run for a snapshot and a restore, on each filesystem and file mode Lanai treats as provable (at least btrfs with copy-on-write, btrfs compressed, and btrfs with copy-on-write turned off): one changes one block of the copy after the clone and puts back its size and modification time, the other changes one block of the file being read (the source, or the snapshot) after it is read and before the proof: in each the restore does not finish and the snapshot is not kept as complete, and each says so; a review confirms the proof compares data or shared storage, not metadata; setup shows no question at its end; with a fixture that keeps the shared folder from appearing in Windows, and one where the drive appears but cannot be listed, setup stops at its file-sharing step with a message in Windows' setup window that says what to do, and after the fixture is removed, running setup.cmd again finishes (both while file sharing is part of setup, requirement 15); with automatic sign-in off, the panel says it waits for the scale task until the Windows user signs in, while Windows waits at the sign-in screen, setup stops at the scale task's time limit with the sign-in message, and Continue setup after the user signs in finishes it; Continue setup with Windows stopped starts it, counts the time limits from that boot, and finishes; with a fixture for each other checked component (the IDD, the SPICE agent and the guest agent) that keeps it from answering, setup stops at its time limit and names it, and after the fixture is removed, Continue setup finishes; with an IDD build that does not match the pin, and with a guest agent running without its allow-list, setup stops at once and says what is wrong, and after the fixture is removed, Run setup again finishes; after a successful setup the allow-list refuses the command; with a fixture that keeps the scale task from starting, setup stops with its message, and after the fixture is removed, Run setup again finishes |
| 7b | Before setup, each lock path locks Windows or leaves it at the sign-in screen: Lock in the Start menu and in Ctrl+Alt+Del, Switch user, Windows key + L sent with QMP `send-key`, and each automatic lock the VM can trigger, turned on at a 1-minute timeout (secure screen saver, machine inactivity limit). After setup, with the screen-saver timeout still at 1 minute (setup leaves it set but not secure) and the inactivity limit as setup left it, none of them does; Windows is still unlocked after idling past every timeout; Windows reports no sleep state it could wake from, and row 27 shows no Bluetooth device. A shutdown with the Ctrl+Alt+Del screen left open is recorded (clean, or the README names it). Setup's domain or MDM warning appears when its membership check reports membership (simulated). Approving the prompt with a different administrator account makes setup refuse; afterwards nothing differs from the before-setup inventory (dockur already installs some pieces, such as its own file-sharing service): the lock controls still lock, the Looking Glass IDD and the scale task are absent, the guest agent's allow-list is not applied, and Lanai has not added or replaced any file-sharing piece. With the compiler unavailable (by fixture or review; the plan says how), setup refuses, names the compiler, and nothing differs from the before-setup inventory. Setup runs the program it built once, in a mode that changes nothing and starts nothing, to check that Windows runs it; with a policy that blocks the program (by fixture, the plan says how, or by review), setup stops with a message that names what to change. The README states the lock note from requirement 7 |
| 8 | A deliberate client/IDD mismatch is detected and named; a simulated pin change keeps or restores a working window |
| 9 | Interrupting setup at each step, then rerunning it, ends in a working install. Run setup again on a current install while the scale task runs ends with one scale task, the newly built program in place, and that program running at the next sign-in |
| 10-17, 20 | Each passes a scripted or checklist test (list in the plan); requirement 12 is checked with a scale matrix: each step, a value just above and below each boundary, a tie (for example 112.5% gives 100%, 275% gives 250%), the 250-300 gap, and values below 100% and above 500% (clamped to the nearest end). If requirement 15 is moved to v2 (recorded in this spec before the release gate), its check and the requirement 28 check are skipped. Requirement 11's clicks: in each state requirement 10 lists, plus during setup, a snapshot or restore, and an unfinished restore, a left click, Enter and Space on the icon open the panel (and close it when open), and a right click starts Windows only when stopped with nothing blocking a start, opens its window only when running after setup with the window closed, and otherwise opens the panel |
| 12 | On two monitors with different scales, with "match my monitor": the step at start comes from the focused monitor; moving the window between the monitors changes Windows' scale within 5 seconds each way, and so does changing the window's monitor's scale, with the panel closed; with the window closed, changing its last monitor's scale applies, moving focus to the other monitor leaves the scale alone, and unplugging the last monitor applies the focused monitor's step; a move made while the shell is down applies within 5 seconds; with the window closed and the shell restarted, a scale change on its last monitor still applies; with no monitor focused, the first monitor Hyprland lists counts. A save of "match my monitor" from a fixed step starts following within 5 seconds. A panel save of a fixed step applies within 5 seconds and survives a VM restart; `lanai settings` with three arguments does the same, and a three-argument save of the current step drops a pick; a `lanai settings` scale save made while the shell is down applies within 5 seconds. Picks: a pick holds through a resize, a monitor move, a follow update and a shell restart with its catch-up; a panel save that changes memory with the scale list untouched leaves it; after a shell restart, a pick holds and the next scale save drops it; a save of the scale the panel already shows drops it, and so does a second save of the same step; a sign-out, a Windows restart and a VM restart each end it, and the latest target applies within 20 seconds of the next sign-in, including a panel save made after the VM started; a resize that moves Windows' recommended scale, including a recommendation that moves seconds after the resolution, is not a pick and leaves the applied scale at the target capped for the new size; a guest that stops reading the channel, gets several saves and follow updates, then resumes, applies only the latest target, and a save among them drops a pick. Cap: with a 300% target, shrinking the window until Windows allows at most 200% applies 200% within 5 seconds of the last size change, and growing it back applies 300%, with the setting still 300%; a 250% pick behaves the same way; a panel save or monitor move while capped applies the capped scale, then the new target once the window grows. Panel words: the note near the scale list, and the same after-save message whether or not the user is signed in; a save while the VM is stopped applies at the next start. Upgrade: on an install set up before this change, a panel save names Run setup again with the lock note and applies at the next start; after Run setup again, Windows has one scale task, a panel save applies live and a pick holds. Channel: a review shows each message carries only a step and a save number from host to guest, and that Lanai never parses or acts on what the guest writes to it; with a guest that never reads the channel and with one that floods it, the panel, the bar and following stay responsive, and over a 10-minute flood no Lanai or shell process grows by more than 20 MB. With Windows' custom scaling on, the README's words match what happens |
| 12b | Size, with the window tiled, floating and fullscreen at different sizes. Evidence: the client's log gives the time and size of each window size change it sees, each ask, and each new frame size ("Format:" line); the window's size in monitor pixels is `hyprctl` size times the monitor's scale (1 pixel of rounding allowed); Windows matches when a "Format:" line at the window's size follows the event within 5 seconds. Session starts: restarting the Looking Glass display driver in Device Manager while the window is open (the case that reproduces the bug each time) ends matched within 5 seconds of the new session's first frame, with no resize by hand, and so does closing and reopening the window. Windows starts and restarts end matched within 15 seconds of the later of the sign-in and the session's first frame (both recorded); the client's log marks the sign-in with the first "Using Clipboard: LGMP" line after the display session starts or after the clipboard last fell back to SPICE (Windows' display helper starting in the user's session), across 10 Windows starts from the bar, across 3 starts from the bar after the window's size changed while Windows was off (to a smaller, a larger and a differently shaped size), and after a Windows restart (once with the window's size changed while Windows restarts). For these, the desktop's size counts, not only the frame's: evidence for the time is the scale task's log (the desktop size it found and set, with times), and Windows' Display settings confirms the final size. The guest's times are moved to the host's clock by the guest-host offset measured at each run (the plan says how), and a log line that finds the desktop already matched counts as matched no later than its time. One start from the bar and one restart each set the window, while Windows is off or restarting, to a size that the client sees matched by its first ask while the desktop keeps the old size (the plan names the sizes; the hands-on used a 1594x990 desktop and a 1600x1000 window); each ends matched within 15 seconds of the sign-in, with no resize by hand. At every Windows start, restart and sign-in in this row, the scale task shows no window, not even briefly, and a review shows that nothing the scale task starts opens a console or a window. More than 10 minutes after one of these sign-ins, the scale task runs as one program and one scale script. With automatic sign-in off (the plan says how), two starts follow a change of the window's size while Windows was off, once to the made stuck size and once to another size that differs from the desktop; each waits at the sign-in screen until the client's log shows Lanai's asks ended (a match or the "did not take" line), and ends matched within 15 seconds of the sign-in. With the display driver disabled across a sign-in, the scale task's log says it found no Looking Glass display and changed nothing. A review of the scale task shows the sign-in step's guards: no other display, no stored size, the size read again at each try, the early stops (an unsupported size, 3 switches), and the 2-minute limit. One made stuck start has a scale target that the old size caps lower, and the applied scale is the target capped for the new size within 5 seconds of the step's switch, or within 20 seconds of the sign-in if that ends later. A resize at the sign-in screen after a sign-out gets the bounded asks, and Windows matches within 15 seconds of the next sign-in, the desktop's size counting as above. During a display session: after a sign-out and sign-in, tiling, fullscreen and back, a resize, and a move to a monitor with another scale, Windows matches within 5 seconds of the event. These 5 s timings hold for an event more than 60 seconds after Lanai's last ask; within a continued sequence, each ask comes on its schedule and Windows matches within 5 seconds of that ask. Picks: 5 resolutions picked in Windows' Display settings, each more than a minute after Lanai's last ask, are each undone within 5 seconds. Then 6 picks: the first more than a minute after Lanai's last ask, and each later one after Windows has taken the previous ask and within 60 seconds of it. A pick is kept with "Keep changes" in Windows' confirmation dialog, before its countdown ends, while no ask has undone it; the dialog's own revert is not a pick, and a revert to the window's size is a match. A dialog that freezes when an ask lands during its countdown does not fail the case; minimize and restore Settings to clear it. Expected: each ask comes when its wait (2, 5, 10 and 20 seconds after the previous ask) ends, or at once for a pick made after that, so the fifth ask comes at least 37 seconds after the first; the sixth pick, made after the fifth ask and kept, gets no ask, and the picked size stays for at least 60 seconds. Scale: with a 300% target and a large window, a driver restart that first shows the driver's default size (a "Format:" line at that size) ends at 300% within 5 seconds of the corrected resolution. Refusal: with a window under 640x480 (the plan names a size), the log names the size and shows no ask, Windows keeps its size and the applied scale, and resizing to an allowed size matches within 5 seconds. A size too large for the frame memory (on a test copy with less frame memory, or by review if that is not practical) gets at most 5 asks (at once, then 2, 5, 10 and 20 seconds apart), one line saying Windows did not take the size, then no ask until the window's size changes, a Windows notice, and no replug. With the driver disabled in Device Manager, the log shows no ask until it is enabled again. Patches: a review shows the client changes only through this repository's patches applied to the pinned source, that they add no message and change no message's format, that the IDD is the pinned build, and that the GPL-2.0 text ships beside the patches and the README says Lanai is MIT except them; a patch that does not apply exactly stops the build. Upgrade: on an install whose client was built before the fix, the panel names the step and says what it fixes, starting and using Windows still works, the step shows no Windows prompt and does not restart Windows, its last message says to close and reopen the window, and after the window reopens the checks above pass; with an old scale task as well, or with a setup record that lacks the sign-in step's current mark, the panel names only "Run setup again", with the lock note, and after it the made stuck case above ends matched within 15 seconds of the sign-in; a review shows the panel's message for a current client with the mark missing. A patch whose content changed serves as a repeatable pre-fix fixture |
| 18 | Shell restart, plugin reload, plugin update and plugin disable each leave Windows running, and the bar shows its true state afterwards |
| 19 | Logout ends in a clean shutdown, with lingering both enabled and disabled, including with row 7b's 1-minute screen saver still set (no longer secure) and running at logout; a guest that ignores shutdown at logout (fixture: turn the Windows lock back on and lock Windows, or leave open a security screen that row 7b recorded as ignoring shutdown, then log out) is force-stopped after 2 minutes and reported at the next start, naming a locked Windows, an open security screen, or a shutdown that did not finish in time as likely causes; on reboot and power-off, with lingering both enabled and disabled and an idle, unlocked Windows, Windows' shutdown starts when the host's does, the time Windows took is measured and written in the README, and the next start reports no forced stop; with the logout fixture above, a reboot whose wait expires ends in a forced stop that the next start reports |
| 21 | After suspend and resume, the requirement 20 check passes, and the guest clock is within 2 s of the host's within 60 s |
| 22, 25 | While the VM runs: no Lanai process runs as root; no new listening TCP or UDP socket appears; all of Lanai's Unix sockets (control, file sharing, guest agent, scale channel) and runtime files, including the shared-memory file, are mode 0600 or inside a 0700 directory owned by the user |
| 23-24 | The spike's security check passes against Lanai's VM: the host-loopback probe is blocked after a positive control; a web page loads; on a guest without its own DNS client, a MagicDNS name and a short name through the host's search domain resolve through Windows' default resolver; the same names resolve when queried at the gateway (the diagnostic for guests with a DNS client such as WARP); a VPN destination and a host service on a non-loopback address are reachable; with the host's network off, Windows starts, and Lanai's start reply says it has no network |
| 27 | A review of QEMU's command line and device tree (QMP `info qtree`) shows only the baseline hardware from requirement 2 plus the listed channels, and nothing else. A review of setup shows that the setup media carry no prebuilt Lanai program, that the scale task's code is built with a compiler that comes with Windows, called by its full path, from this repository's source, and that the compiler, every build's inputs, everything a build writes, and the task's files sit where only administrators can write, including inputs and outputs the environment can redirect (the working folder, and the temp and search-path variables) |
| 29 | The README states the clipboard exposure |
| 26 | Setup refuses a download or source with a wrong checksum |
| 28 | From the guest, attempts to leave `~/Windows` through `..` and a planted symlink fail |
| 30-32 | Review against the marketplace rules; removal steps from the README, run on a test install, leave `omarchy-windows-vm` working; after the README's restore steps, Lock in Start and Windows key + L lock Windows again, Switch user is offered again and leaves the session at the sign-in screen, and a secure screen saver, once the tester turns it on, locks at its timeout |

## Release gate

Lanai is not released until the spike's measured protocol has run and its decision rule
passes ([spike results](../spike/results.md), "Status"). "Released" means any of: making
the repository public, tagging a release, or submitting to the marketplace.

## Out of scope for v1

- Installing Windows without `omarchy-windows-vm` (planned for v2). v2 adds a second
  setup path, a no-touch fresh install: Lanai installs Windows itself with its own
  unattended setup, which installs everything requirement 7 lists, so the user does
  nothing inside Windows. v1's path, adopting an existing install, needs the user to
  start setup inside Windows (and approve its administrator prompt when UAC is on):
  an adopted Windows has no channel Lanai can use instead
  (dockur installs no guest agent and enables neither SSH nor WinRM; RDP needs the
  Windows password and an inbound connection). John, 2026-10-04.
- GPU passthrough, SR-IOV, and a dedicated partition or NVMe for Windows.
- USB device passthrough, including smart cards and security keys. A likely v2 need for
  sysadmins.
- Microphone input. A likely v2 need for Teams calls.
- Starting Windows automatically at login.
- Multiple VMs, multiple Windows displays, and HDR. Several host monitors are
  supported, with the one Windows window moving between them (requirement 12).
- Windows' custom scaling (any percentage, applied at sign-out). While it is on, it
  overrides Lanai's scale; the README says so and how to turn it off. The README also
  notes that some Windows apps redraw at a new scale only after they restart.

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
| spec | amendment | 2026-10-04 | From the phase 6 hands-on runs (John's decisions): req 7 and row 7 allow at most one administrator prompt (none when UAC is off) and no other Windows prompt; the v2 no-touch install is described under Out of scope |
| spec | amendment | 2026-10-05 | From the phase 7 panel run (John): Windows' scale drifted with the window size, because the sign-in task applied it once as an offset from Windows' recommended scale. Req 12 makes the scale a setting (match my monitor, or a fixed step) that Windows keeps through resizes, within Windows' cap; req 6 lists it |
| spec | amendment | 2026-10-05 | From the phase 7 panel run (John): snapshot and restore show a progress bar, and each reads the disk's data once (the second full hash pass is replaced by a check that does not re-read the data); req 11 swaps the icon's clicks (left opens the panel, right starts or opens Windows); row 7 checks the progress and the single read, row 10-17 the clicks |
| spec | amendment review a (gpt-6.1-sol) | 2026-10-05 | Progress, single read and clicks, round 1 (full): 0 findings. Stage a clean |
| spec | amendment review b single (opus-5.5) | 2026-10-05 | Round 1 (full): 4 should-fix, 5 nits, 0 refuted; all integrated: the copy check must prove the same data, not size and timestamps, and row 7's fixture keeps them; what a snapshot and a restore each read and record; the snapshot's failed check is tested too; the right click is defined for every req 10 state (failed and unfinished states open the panel); Enter matches the left click; progress shows in a panel opened partway and for command-line runs; bytes read measure the single read; a missing period; the log row's row reference |
| spec | amendment review b single (opus-5.5) | 2026-10-05 | Round 2 (full): 3 should-fix, 3 nits, 0 refuted; all integrated: the right click names what blocks a start (req 10 has no setup or busy state); the single read is counted at the read calls on the image files, with an allowance for small files; the proof covers a write to the file being read before the copy (on XFS and copy-on-write-off btrfs files an unshared block is overwritten in place, so the block map alone misses it), with a fixture; a review confirms the proof is not metadata; filesystems whose copies cannot be proven count as unable to make one; a left click toggles the panel |
| spec | amendment review b single (opus-5.5) | 2026-10-05 | Round 3 (full, cap): 1 should-fix, 5 nits, 0 refuted; all integrated: the proof fixtures run on every filesystem and file mode Lanai treats as provable (btrfs copy-on-write, compressed and copy-on-write off), and anything untested counts as unprovable (so XFS falls back to "cannot make an instant copy" until it has a fixture run); the image's proof is shared storage, a byte compare only for small files; the read count covers the storage, snapshot and copy files; the second fixture's change lands before the proof; Space is tested; the tooltip names the right click. Stage closed at the cap with these integrations unreviewed; the gate waits for John |
| spec | John | 2026-10-05 | John accepted the amendment's gate with round 3's integrations unreviewed. Next: the plan for this work and the display scale |
| spec | John | 2026-10-05 | Req 7 exception (from the plan gate): when dockur has already deleted the disk, a restore puts the cloned disk in place locked, and the verified small files right after it, before the image's one hash, so a container start cannot wipe or boot it; a failed check leaves the restore unfinished. Approved by John |
| spec | amendment | 2026-10-10 | (Two-way parts superseded by b round 1: picks no longer become the setting.) From a week of daily use (John): the scale could not change while Windows ran (the panel waited for the next start, and the sign-in task undid changes in Windows' settings), and "match my monitor" read the focused monitor at start, not the window's. Req 12 makes the scale live: "match my monitor" follows the window's monitor, a panel save applies at once, and a step picked in Windows' settings stays and becomes the setting (John's choices); req 6 and req 27 (a scale channel) follow; row 6 and row 10-17 check it |
| spec | amendment review a (gpt-6.1-sol) | 2026-10-10 | Live scale, round 1 (full): 1 blocker, 6 should-fix, 0 refuted; all integrated: the latest deliberate choice wins and late reports never replace it; target vs applied scale under Windows' cap; signed-out and earlier-setup cases each say when the setting applies; several host monitors in scope (multiple Windows displays out); a gone monitor falls back to the focused one; req 2 allows the scale channel; a valid guest message changes only the scale setting |
| spec | amendment review a (gpt-6.1-sol) | 2026-10-10 | Round 2 (full): 1 blocker, 1 should-fix, 0 refuted; both integrated: the scale channel may carry bounded fields to order choices and mark a user's pick (a bare step could not meet req 12's latest-choice rule); row 10-17 adds late-report and automatic-change fixtures |
| spec | amendment review a (gpt-6.1-sol) | 2026-10-10 | Round 3 (full, cap): 3 should-fix, 0 refuted; all integrated: a resize keeps the target and reapplies the capped scale within 5 s (the old "keeps the applied scale" contradicted growth); guest ordering fields can never stop a later panel save, and the real-order guarantee holds only for an untampered guest; a channel that stops answering shows the save as not yet applied and converges to the latest target; row 10-17 adds explicit cap values, forged-order, replay and blocked-channel cases. Stage closed at the cap with these integrations for stage b to review |
| spec | amendment review b single (opus-5.5) | 2026-10-10 | Round 1 (full): 0 blockers, 10 should-fix, 6 nits, 0 refuted. Most traced to Windows picks writing back to the host (ordering without a trusted clock, RDP picks, picks lost while the shell is down, Windows' own scale moves, custom scaling, flood writes, forged panel status). John chose the one-way design: a pick in Windows holds until the next panel scale save or the VM stops and never becomes the setting; the channel only sends from Lanai to Windows and Lanai reads nothing from it. Integrated: a save sends a scale only when one was chosen in the panel; the old task's revert is stated; the three terms (setting, target, applied scale) are defined; only picks in Windows' Scale list count; custom scaling is out of scope with a README note; following runs with the panel closed and catches up after a shell restart; fallback monitor rules; "last size change"; req 12 gets its own row; socket list in row 22, 25; req 2 and req 7 wording. Not applicable after the redesign: signed-out vs silent-channel status (the panel no longer claims "applied"), and showing the capped scale (Lanai cannot read it) |
| spec | amendment review b single (opus-5.5) | 2026-10-10 | Round 2 (full): 1 blocker, 9 should-fix, 6 nits, 0 refuted; all integrated within the one-way design: each message carries a step, a save flag and a growing save number (a bare step could not tell a save from a follow update or a resend); a pick is defined by what Windows can observe (scale change without a resolution change) and is part of the target; a sign-out, Windows restart or VM stop ends a pick and the latest target applies at the next sign-in; one panel message for signed in or not; the guest cannot block or grow the host's sending side; the scale task does nothing under omarchy-windows-vm (req 4, row 4); a setup rerun leaves one scale task (req 9); the Run setup again hint names the lock; a note near the scale list; nits (CLI saves, monitor fallbacks, plugin down, wording, README notes, superseded log row) |
| spec | amendment review b single (opus-5.5) | 2026-10-10 | Round 3 (full, cap): 0 blockers, 5 should-fix, 8 nits, 0 refuted; all integrated: a send is replaced by the latest, and the scale task gets the latest target when it starts or reconnects (dropping would lose saves made while no one reads); the save number never goes down across shell restarts; a pick excludes the task's own changes and late moves of Windows' recommended scale; a scale save is defined by input (scale list selected, or three-argument CLI); the old task neither keeps picks nor follows, and Lanai decides from its setup record; nits ("chooses", row 7b guest agent claim, cap wording, sign-in timing, flood bound, extra row cases, Lanai never parses guest writes, setup user only, last monitor across shell restarts). Stage closed at the cap with these integrations unreviewed; the gate waits for John |
| spec | John | 2026-10-10 | John accepted the live-scale gate with b round 3's integrations unreviewed. Next: the plan |
| spec | John | 2026-10-10 | From plan research: Windows' virtio-serial driver opens a port only to SYSTEM and Administrators (`SDDL_DEVOBJ_SYS_ALL_ADM_ALL`), so a task in the user's limited session cannot read the scale channel. John chose an elevated scale task (one piece, highest privileges at sign-in, no prompt) over a SYSTEM relay plus an unprivileged task; req 27 says so |
| spec | Claude (flagged to John) | 2026-10-10 | From plan writing: the save flag in req 27 was redundant, since a grown save number already marks a scale save; req 27 and row 12 drop it |
| spec | Claude (flagged to John) | 2026-10-10 | From plan review a round 1: following and CLI scale saves keep working while the shell or plugin is down (the feed runs in the VM unit; pausing would need a presence check for no user benefit); a save is a changed save number, not only a grown one, so a lost counter cannot strand a pick |
| spec | Claude | 2026-10-10 | From plan review b round 3: req 2's SMBIOS field carries the scale and its save number (the boot baseline for the scale task) |
| spec | amendment | 2026-10-12 | From the live-scale hands-on (John): Windows sometimes starts at the display driver's default size and stays there until the user resizes the window by hand. The client's log shows why: the driver restarts during boot, and the client sends its window size once per size, so it never sends it again. On 2026-10-11, Windows also changed its resolution on its own 0.7 s after a session started, and the client never corrected it. Req 12 gets the size rule (every case within 5 s, at most 3 asks for a size Windows refuses), the client-patch constraint, the upgrade rule; row 12b tests them |
| spec | resize amendment review a (gpt-6.1-sol) | 2026-10-12 | Round 1 (full): 2 should-fix, 0 refuted; both integrated: one clock for every size case (the later of the event and the first frame after it), and row 12b lets a driver restart start a fresh round of at most 3 requests |
| spec | resize amendment review a (gpt-6.1-sol) | 2026-10-12 | Round 2 (full): 0 findings: "the amendment is sound". Stage closed |
| spec | resize amendment review b single (opus-5.5) | 2026-10-12 | Round 1 (full): 0 blockers, 6 should-fix, 4 nits, 0 refuted; all integrated: refusal defined by what the client sees (no frame at the size within 5 s, or left again within 60 s) with rounds that end on a size change, driver restart or 60 s held, so a reverting Windows cannot cause a loop; the client logs each request; a new session's clock starts at its first frame, an in-session event's at the event (reconciles a round 1); the cap rule follows any resolution change, with a 12b case for a start through the driver's default size; a patched client counts as the pinned build for req 8, patches change no client-IDD messages and Lanai records which patches built the client; upgrade words say what the user loses, that the step changes nothing in Windows and when the new client takes over; nits (exact apply stops the build; upstream offer moves to the plan; a sign-in or a picked resolution is not 'on its own'; once per round; no history in the requirement; the too-large example) |
| spec | resize amendment review b single (opus-5.5) | 2026-10-12 | Round 2 (full): 0 blockers, 2 should-fix, 5 nits, 0 refuted; all integrated. The 3-ask rounds could stick after ordinary boot churn and were hard to test; John asked whether Lanai can tell when Windows responds (it can: the driver is connected, has shown a frame, and reads the ask; it cannot hear a refusal) and chose: ask only while Windows responds (a waiting ask does not count), then back off 5, 10, 20, 40 s to once a minute while a responding Windows still differs, starting over on a size change or new display session. Row 12b tests the backoff, the picks, the disabled driver and names its evidence (log asks and frame sizes, hyprctl size times scale); the driver restart is the deterministic start case; upgrade words say to reopen the window and defer to req 8 for an older pin; README notes the two refused-size cases; wording (Lanai changes, patch content, display session) |
| spec | resize amendment review b single (opus-5.5) | 2026-10-12 | Round 3 (full, cap): 0 blockers, 5 should-fix, 5 nits, 0 refuted. Each ask the IDD takes replugs Windows' monitor (a flicker), and a too-large one shows a Windows notice, so John changed the retry (at the cap): ask at once, then 5, 10, 20 and 40 s, then stop until the window's size, a new display session or Windows' size changes; a Windows change within 60 s of the last ask continues the sequence. Integrated: the 5 s promise holds for every size Windows allows; triggers and reset stated; at most one unread ask; the patches change only when the client sends its existing message; GPL-2.0-or-later named; the log names window size changes; row 12b times from the event, spaces the picks and names a refused size in the plan; one step when the scale task is old too; 'start at, or change to'. John asked for one more round on the result |
| spec | resize amendment review b single (opus-5.5) | 2026-10-12 | Round 4 (full; the extra round John called after the cap): 0 blockers, 3 should-fix, 6 nits, 0 refuted; verdict sound. All integrated: waits count from the previous ask, and row 12b's 5 s timings hold for events more than 60 s after the last ask (a continued sequence keeps its schedule); the quick-pick test spaces its picks; the GPL-2.0 text ships beside the patches and the README says Lanai is MIT except them; nits (log lines count as a patch change, wording of stop and minimum, when the 'did not take' line comes, a too-large case, scale holds through refused asks, a repeatable upgrade fixture, req 7 names the patches) |
| spec | John | 2026-10-12 | Resize amendment: accepted the gate after review b round 4 with that round's wording fixes unreviewed; the plan's gate checks them against the plan |
| spec | Claude (flagged to John) | 2026-10-12 | From plan writing: the upgrade bullet's 'changes nothing in Windows' and 'close and reopen' apply to the build step; 'Run setup again', named when the scale task is old too, restarts Windows itself and brings up the fixed client |
| spec | John | 2026-10-12 | From resize phase 0 (4): a 600x400 window moved Windows to 1920x1080, not 'keeps its last size'. John's call: never ask under 640x480 (the driver's floor), so Windows keeps its size; the too-large case keeps the bounded asks. Req 12's refusal bullet and row 12b's refusal case changed to match |
| spec | John | 2026-10-13 | From the resize hands-on (phase D): 3 of 3 starts from the bar after the window's size changed while Windows was off matched 5.8 s after the first frame, past the 5 s bar. After a boot, Windows' display helper does not yet switch the desktop to the first ask's size (Windows shows the smallest built-in size that fits the old desktop); the ask 5 s later works. The 10 starts in row 12b never needed an ask (Windows started at the window's size), so they missed this. John's call: the first wait becomes 2 s (waits 2, 5, 10 and 20 s), and row 12b adds 3 starts with a changed window size. Not 1 s: a wait shorter than Windows' switch sends a needless second ask (one more replug and flicker, and one of the 5 asks), and the slowest switch seen after a taken ask was 1.26 s (`proofs.md`, "Resize hands-on"). Not yet shown: that Windows' helper is ready for ask 2 about 2.5 s after a boot's first frame (ask 2 worked at about 5.5 s); row 12b's new case checks it. Row 12b's pick case now keeps a pick whose ask is waiting, since the hands-on saw the dialog's own revert use up picks before the fifth ask was due. (Review b round 1 added the "Not 1 s", "Not yet shown" and pick-case sentences.) John also asked to lock Windows to the window's size (offer no other resolution): with the driver's mode list cut to the window's size, the helper's switch failed (`Failed to apply Looking Glass display mode 946x1246@60 (-1)`), so it needs a driver change; the IDD stays pinned, and it goes to the upstream offer (`plan.md`, "Upstream offer (John)") |
| spec | resize amendment 2 review a (gpt-6.1-sol) | 2026-10-13 | Round 1 (full): 0 findings: "The amendment is sound". Stage closed |
| spec | resize amendment 2 review b single (opus-5.5) | 2026-10-13 | Round 1 (full): 0 blockers, 3 should-fix, 3 nits, 0 refuted; integrated: row 12b's pick case keeps each pick and states each ask's earliest time (a 2 s first interval cannot be made by hand, and the dialog's revert stopped a sequence early); the 1.26 s switch is now in `proofs.md`, and the log row says why it matters and what stays unproven; the new start case varies the size; the upstream offer is named. To John: whether the README mentions the frozen confirmation dialog |
| spec | resize amendment 2 review b single (opus-5.5) | 2026-10-13 | Round 2 (full): 0 blockers, 2 should-fix, 2 nits, 0 refuted; all integrated: the first quick pick comes more than a minute after the last ask (else it continues the slow pick's sequence and a correct build fails); only a pick whose ask is waiting is kept, and a dialog frozen by an ask does not fail the case; a Windows restart with a changed size; the 2026-10-13 John row marks the sentences review b added |
| spec | resize amendment 2 review b single (opus-5.5) | 2026-10-13 | Round 3 (full, cap): 0 blockers, 1 should-fix, 3 nits, 0 refuted; all integrated: every pick is kept before the dialog's countdown ends, and the sixth pick's check is no ask and the size held for 60 s; wording fixes. Stage at the cap with round 3's integrations unreviewed |
| spec | John | 2026-10-13 | Resize amendment 2: accepted the gate at the cap with round 3's integrations unreviewed; the plan's gate checks them against the plan |
| spec | John | 2026-10-13 | Resize amendment 3, from the phase E hands-on (`proofs.md`, "Resize hands-on, phase E"): after a boot, Windows' display helper cannot switch the desktop until the signed-in desktop is up (about 6.7 s after the first frame with automatic sign-in), so no ask timing meets 5 s from the first frame; asks 1 and 2 failed and ask 3 (7.5 s) took on 4 starts. Worse, when the smallest mode that fits the old desktop is the window's size, ask 1's frame matches while the desktop does not, and Lanai stops asking (seen at 16:52:18 and made on purpose at 18:18:57). John's calls: a sign-in step in Windows sets the driver's stored size (prototype fixed the made case 4.6 s after the desktop came up), and Windows starts and restarts are timed from the sign-in. The amendment 2 note "not yet shown: the helper is ready about 2.5 s after a boot's first frame" is now shown false. After a sign-out, the helper applied the last ask 0.5 s after sign-in |
| spec | resize amendment 3 review a (gpt-6.1-sol) | 2026-10-13 | Round 1 (full): 0 findings: "Resize amendment 3 is sound within the requested scope". Stage closed |
| spec | resize amendment 3 review b single (opus-5.5) | 2026-10-13 | Round 1 (full): 0 blockers, 9 should-fix, 5 nits; 1 premise refuted (a size too large for frame memory is never stored: the driver refuses it before `SetExtraMode`), its guard kept. Integrated: the sign-in step is part of the scale task (requirements 7, 9 and 27 cover it), acts only on the Looking Glass display, does nothing under `omarchy-windows-vm` (req 4, row 4), reads the latest stored size at each try, stops when Windows refuses, and logs; the 10 s bar becomes 15 s from the sign-in of the setup user (a cold-start stuck case would take about 11 s: the prototype task started 10.6 s after the sign-in marker), flagged to John; the "only" sentence names the sign-in wait; the marker after a sign-out; the upgrade message carries the lock note and a measurable check; row 12b adds the stuck case on a start from the bar and a password sign-in that waits over 40 s; nits (desktop vs resolution, sign-in with no change, wording) |
| spec | resize amendment 3 review b single (opus-5.5) | 2026-10-13 | Round 2 (full): 0 blockers, 4 should-fix, 7 nits, 0 refuted; all integrated: the early stop only when Windows reports the size unsupported (a failure right after a boot retries); the scale task's log times the desktop and Display settings confirms it; the password sign-in starts change the window first (the stuck size and another); a driver-disabled sign-in and a review of the step's guards; nits (req 7 names the step, "a sign-in after no window size change and no ask", resolution is the desktop's size, "for a Windows start", the wait runs to 15 s after sign-in, "display session", an ask from an earlier run, a pin change rechecks the step, one combined upgrade message, a review of the mark-only message). Note: the 15 s bar has about 4 s of margin; revisit if the plan's first cold-start stuck runs exceed about 12 s |
| spec | resize amendment 3 review b single (opus-5.5) | 2026-10-13 | Round 3 (full, cap): 0 blockers, 3 should-fix, 6 nits, 0 refuted; all integrated: the 15 s wait applies only to a start, restart or sign-in-screen event (a plain sign-in keeps 5 s); row 12b moves the guest's times to the host clock by a measured offset and counts an "already matched" line as a latest time; the sign-in step stops after 3 switches Windows reported done while the desktop still differs; nits (the stored size is the latest ask the driver took, frame evidence also fails after a sign-out, the later of sign-in and first frame, named upgrade references, the password starts wait for the asks to end in the log, a scale re-cap check). Stage closed at the cap with these integrations unreviewed; the gate waits for John |
| spec | John | 2026-10-13 | Resize amendment 3: accepted the gate at the cap with round 3's integrations unreviewed (the plan's gate checks them against the plan), and kept the 15 s bar from the setup user's sign-in |
| spec | Claude (flagged to John) | 2026-10-13 | From plan review a round 2 (resize phases F and G): row 12b measures a start from the later of the sign-in and the session's first frame, as requirement 12 says |
| spec | Claude (flagged to John) | 2026-10-13 | From plan review a round 3: the frame counts as evidence again only after the sign-in step has seen the desktop match, not merely run |
| spec | John | 2026-10-14 | Resize amendment 4, from the phase G hands-on (`proofs.md`, "Resize hands-on, phase G"): at sign-in, Windows PowerShell took 10.2 to 12.8 s to load in the scale task, so the sign-in step's first check came 11.3 to 14.1 s after the sign-in, which leaves a stuck desktop at or past the 15 s bar; normal task priority did not help. On the same boot, a small compiled program reached its code 6.7 s after the sign-in and `cmd.exe` ran at 4.5 s. The task's console window also showed at every sign-in until PowerShell loaded and hid it. John chose a small windowless program that setup builds in Windows: the scale task shows no window (requirement 7), and setup builds the program from this repository's source with a compiler Windows includes, so no prebuilt program enters Windows (requirement 27). The 15 s bar stays |
| spec | resize amendment 4 review a (gpt-6.1-sol) | 2026-10-14 | Round 1 (full): 0 blockers, 2 should-fix, 0 nits, 0 refuted; both integrated: the no-prebuilt-program rule covers only Lanai's own programs (requirement 7's pinned installers stay); the upgrade bullet keys on the current form's mark, so an install with the earlier PowerShell step is told to run setup again, and row 12b's upgrade case runs once with no mark and once with an earlier form's |
| spec | resize amendment 4 review a (gpt-6.1-sol) | 2026-10-14 | Round 2 (full): 0 findings: "Resize amendment 4 is sound within the requested scope". Stage closed |
| spec | resize amendment 4 review b single (opus-5.5) | 2026-10-14 | Round 1 (full): 0 blockers, 4 should-fix, 3 nits, 0 refuted. Integrated: requirement 27's no-prebuilt rule excepts requirement 7's pinned files (`virtiofs.exe` is one, not an installer), and the build reads and writes only where administrators alone can; row 27 reviews the build; row 12b's no-window check covers every start, restart and sign-in in the row with a review of how, and row 4 checks for no window under `omarchy-windows-vm`; setup refuses when Windows lacks the compiler. Reverted round a1's earlier-form clauses: phase F's PowerShell step ships only with this change, so no user has it, and the test copy lacks the current mark anyway. Declined the nit that the mark follow the program's source automatically (the plan bumps it with the source) |
| spec | resize amendment 4 review b single (opus-5.5) | 2026-10-14 | Round 2 (full): 0 blockers, 5 should-fix, 4 nits, 0 refuted; all integrated: requirement 27's build rule covers the scale script's run-time compile too (setup or the task builds Lanai's code, compiler by full path, admin-only reads and writes), and one copy of the scale task runs at a time and comes back within 5 minutes (row 12b checks one copy after 10 minutes); setup stops with a message if Windows will not run the program it built (Smart App Control or a policy may block an unsigned program; row 7b reviews the self-check and the missing-compiler refusal); row 9 covers Run setup again while the program runs; row 12b's no-window review is design-neutral; wording. Also Claude's own: the scale re-cap in the made stuck start counts from the later of the switch and the time the scale task can first apply a scale, since the program now switches before PowerShell has loaded |
| spec | resize amendment 4 review b single (opus-5.5) | 2026-10-14 | Round 3 (full, cap): 0 blockers, 3 should-fix, 5 nits, 0 refuted. Integrated: a copy of the scale task is one program and the one scale script it started, whole again within 5 minutes if either ends (row 12b counts both); a program Windows blocks or removes later has a README symptom and fix, and setup's stop message names what to change; the nits (a self-check that changes and starts nothing, by fixture or review; row 4 times each task start under `omarchy-windows-vm`; row 27 names redirectable inputs; wording). Open for John: the scale script still loads in PowerShell, 10 to 14 s after the sign-in, so requirement 12's 5 s scale timings that start at a sign-in cannot hold |
| spec | John | 2026-10-14 | Resize amendment 4: scale work that starts at a sign-in finishes within 20 s of the sign-in (a pick's end at the next sign-in, and a resolution change in the first 20 s, such as the sign-in step's switch); moving the scale script into the program is a follow-on. Accepted the gate at the cap with round 3's integrations unreviewed; the plan's gate checks them against the plan |
| spec | Claude (flagged to John) | 2026-10-14 | From plan review b round 2 (resize phase H): Smart App Control allows no single program, only off, so requirement 7's fix for a blocked program also names turning off the feature that blocks it |
| spec | John | 2026-10-17 | Setup-checks amendment: setup drops its two closing questions (does ~/Windows show in Explorer, does text look the right size), since both can be checked: the share inside Windows by the guest install, the rest from the host. A text size the user does not like is a setting |
| spec | setup-checks amendment review a (gpt-6.1-sol) | 2026-10-17 | Round 1 (full): 3 P2, 0 refuted; all integrated: the scale task counts as working when its port opens (QEMU's state, within requirement 27), and setup does not check the applied scale; a stated wait, then a message to sign in and continue or run setup again, with acceptance cases for automatic sign-in off and a scale task that never starts; the drive check applies only while file sharing is part of setup (requirement 15 may still defer it) |
| spec | setup-checks amendment review a (gpt-6.1-sol) | 2026-10-17 | Round 2 (full): 1 P2, 0 refuted; integrated: every host-side check after the guest install has a stated wait, and a component that does not answer stops setup, named, with run setup again; acceptance case for a component that never answers |
| spec | setup-checks amendment review a (gpt-6.1-sol) | 2026-10-17 | Round 3 (full, cap): clean, 0 findings |
| spec | setup-checks amendment review b single (opus-5.5) | 2026-10-17 | Round 1 (full): 0 blockers, 2 should-fix, 7 nits, 0 refuted; integrated: requirement 27 allows one refused guest-agent command at setup's checks, and requirement 7 names the allow-list; Continue setup (check again) and Run setup again (repeat the guest install) offered by every check that runs out of time; the host-side checks named; time limits stated in the plan, counted from the boot; the share check's message in Windows' setup window, rerun by setup.cmd, and its row 7 clause tied to requirement 15; the drive must also list; the panel says it waits for the scale task. Not taken: a host-side share check after the restart. Probed 2026-10-17: QEMU reports the vhost-user-fs device's state only through experimental `x-query-virtio-*` commands, and `x-query-virtio-status` aborted QEMU 11.1.2 (an assertion in its QAPI visitor; the test copy's VM went down); virtiofsd 1.14 logs guest requests only at debug level, one line per file operation. So Lanai has no reliable host signal for the mount, and the service starts automatically |
| spec | setup-checks amendment review b single (opus-5.5) | 2026-10-17 | Round 2 (full): 0 blockers, 4 should-fix, 4 nits, 0 refuted; all integrated: Continue setup runs the checks with fresh time limits (from the click, or the boot it starts); a wrong answer stops at once and says what is wrong (requirement 8's mismatch message; a guest agent missing its allow-list), with a fixture per checked component and a check that the allow-list refuses after setup; the refused command changes nothing and starts nothing; the wait names the sign-in, and the stop message's sign-in hint is a condition, since Lanai cannot see the sign-in screen; Run setup again named for the scale fixture; a drive that appears but cannot be listed; the IDD's build; the checks bullet follows the restart bullet; the one-prompt count holds for a setup that does not stop |
| spec | setup-checks amendment review b single (opus-5.5) | 2026-10-17 | Round 3 (full, cap): 0 blockers, 2 should-fix, 5 nits, 0 refuted; all integrated, not reviewed again: a guest agent missing its allow-list stops with Run setup again as the way on, and row 7's wrong-answer cases end with Run setup again finishing; requirement 27 lists the IDD's build the client reports, used only to compare with the pin and name it (a gap from requirement 8 that the amendment states outright); the time-out message also says to follow Windows' setup window first if setup.cmd stopped there, and names the Windows user who ran setup in the sign-in hint; the share must be visible to the user's non-elevated session; row 7's one-prompt and one-restart counts hold for a setup that does not stop; a Continue setup case with Windows stopped |
| spec | John | 2026-10-17 | Setup-checks amendment: accepted the gate at stage b's cap, with round 3's edits integrated and not reviewed again |
| spec | John | 2026-10-18 | Setup checks, from the diff gate: a Windows restart during setup's final checks resets no time limit (one limit from the check boot or the Continue, then the scale task's from when the other checks passed); and since the setup drive is not attached at that point, a setup.cmd stop is answered by repeating the guest install, not by following setup.cmd first |
| spec | John | 2026-10-25 | Pointer scale amendment, from `client-restart-scale/plan.md` (its requirement 4; reviewed in that plan's gate, which John accepted): after the computer wakes from sleep, the Looking Glass host in Windows restarts and the client reset the pointer scale to 1.0, so on a display at scale 2 the mouse reached only the top-left quarter of Windows (`proofs.md`, "Pointer scale after a host restart"). Requirement 12 now lets the patches keep the pointer scale across a host restart, and both upgrade messages for an old client name the mouse fix |
