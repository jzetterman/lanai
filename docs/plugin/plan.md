# Plan: Lanai v1

Governing spec: [spec.md](spec.md). Status: approved 2026-09-28.

Each phase is self-contained: a fresh session can run it from this document, the spec,
`CLAUDE.md` and the code on the branch. Every phase ends with `bats spike/test` (and
`bats test` once `test/` exists) green, `shellcheck` clean, and its own commit(s) on
branch `plugin/v1`. Tests that need btrfs read `LANAI_TEST_BTRFS_DIR` and skip only when
it is unset or not on btrfs (bats redirects `HOME`, and `/tmp` is tmpfs here).

**Hard rule for every phase:** no agent or automated test boots, modifies or experiments
on John's live `~/.windows`. Experiments use a full-directory reflink copy (see "Test
copies"). bats `setup` points `HOME` and every `XDG_*` variable at temp directories, so
the `~/.windows` default can never resolve to the live install in a test. John runs live
checks himself, by hand, in phase 8.

**Test copies.** `spike/lgtest prepare` copies only the disk, firmware, variables and
MAC, so Lanai's own checks would reject it (no `windows.boot`). Use instead
`bin/lanai-copy <src> <dst>`: take QEMU's write lock on the source `data.img` with a
held `qemu-io -f raw` (the same lock as snapshots; opening it fails while any VM runs,
and it keeps any VM from starting during the copy); copy every file with
`lib/copy.sh`'s `reflink_tree` (create each file, `chattr +C` first when the source has
it, then `cp --reflink=always`; source and destination must share a filesystem); verify
the copy's file list, sizes and SHA-256 against the source while the lock is still
held; then release it. `reflink_tree` is the shared core that snapshot and restore also
use.

## Architecture

- **Plugin at the repo root.** `manifest.json`, `Widget.qml` and panel QML, `bin/`,
  `lib/`, `guest/`, `systemd/` and `test/` sit beside `docs/` and `spike/`.
- **One-shot CLI backend, `bin/lanai`,** in Bash. Each call prints one JSON object
  (`ok`, `state`, `message`, `next`, plus details) via `jq` and exits. The QML UI polls
  `lanai status`. Functions live in `lib/lanai.sh`; the spike's tested functions
  (`disk_locked`, `qemu_cmdlines`, `verify_sha256`, the `vm_args` rewrite rules) move
  there with their tests.
- **Stable runtime copy.** Setup (and every Lanai update, on the next `lanai start`
  while the VM is stopped) copies `bin/` and `lib/` into
  `$XDG_DATA_HOME/lanai/runtime/<version>/`. The unit points there, so a plugin update
  or removal mid-run cannot break a clean stop (req 18, 32). A refresh rewrites the unit
  and runs `systemctl --user daemon-reload`.
- **One VM unit, `lanai-vm.service`,** a systemd user unit installed to
  `~/.config/systemd/user/` with absolute paths filled in. `PartOf=` and
  `After=graphical-session.target`, `Slice=session.slice` (Omarchy has oomd kill
  `app.slice` under pressure; `session.slice` is not managed), `Type=exec`,
  `TimeoutStopSec=2min`, no `[Install]` section.
  - **Why logout gets the full 2 minutes despite Omarchy's 5 s cap.** The 5 s cap is
    `user@.service`'s stop timeout, which applies only when the system stops the user
    manager (reboot, power-off, or the last session closing). At logout, `uwsm stop`
    stops the compositor unit; `graphical-session.target` stops first, and with
    `PartOf=`/`After=` ordering the VM unit stops before it, so Hyprland (and with it
    `uwsm start`, which holds the login session open) waits for the VM's `ExecStop`.
    The user manager is not stopped while that session is open, lingering on or off.
    Proof 4 verifies this. If it fails, the 2-minute logout requirement cannot be met
    as designed, and that goes to John as a spec question before phase 4.
  - `ExecStart=lanai-vm-exec`: create and check `$RUN` (below); remove stale sockets
    and truncate `client.log`; start in the background virtiofsd, the shutdown
    inhibitor, the sleep watcher and the event logger (one cgroup; with the default
    `KillMode` systemd kills them only after `ExecStop` returns); wait for a fresh
    `virtiofs.sock`; write the "running" marker; exec QEMU.
  - `ExecStop=lanai-vm-stop`: systemd runs it after every stop. When QEMU has already
    exited (`$EXIT_CODE` set) it goes straight to the final wait. Otherwise (a session
    end or the inhibitor, req 19) it sends QMP `system_powerdown` on `qmp.sock` and waits
    for the process to exit. Both paths end with the same wait of up to 2 s for this
    run's `last-shutdown` record, so the event logger is not killed before it writes.
  - Three QMP sockets, each with one owner: `qmp.sock` (the unit's stop path),
    `qmp-events.sock` (the event logger, connected for the VM's life), and `qmp-cli.sock`
    (the CLI; every call connects, reads with a timeout, and disconnects, because QEMU
    serves one client per socket at a time). The inhibitor never uses QMP; it runs
    `systemctl --user stop --no-block lanai-vm.service`.
  - The event logger retries its connection until QEMU creates `qmp-events.sock`, then
    records each QMP `SHUTDOWN` event (`guest`, `reason`) to
    `$XDG_STATE_HOME/lanai/last-shutdown`, stamped with the unit's `$INVOCATION_ID`
    (systemd gives `ExecStart` and `ExecStop` the same value, so "this run's record"
    means a matching stamp). "Clean" (spec: a guest-initiated shutdown) means that event
    with `"guest": true`, nothing else.
  - Run bookkeeping has one owner, `record_previous_run`, called by every path that
    starts the unit (`lanai start`, `lanai setup-guest`, setup's step 6 boot) before
    starting it. It turns the previous run's markers into a verdict in
    `$XDG_STATE_HOME/lanai/last-run` (forced when the "forced" marker exists, which takes
    precedence even over a guest `SHUTDOWN` event that arrived just before the kill;
    else clean when a matching guest `SHUTDOWN` record exists; else forced when a
    "running" marker exists), then deletes the "running" marker, the "forced"
    marker and `last-shutdown`. `lanai-vm-exec` only writes the "running" marker, with
    `$INVOCATION_ID`, right before it execs QEMU. `status_map` reads `last-run`, and the
    panel clears it once it has shown a forced-stop notice, so each is shown once.
- **Stopping from the UI never uses `systemctl stop`** (req 16). `lanai stop` sends
  `system_powerdown` on `qmp-cli.sock` and records the request time; the unit stays
  active until QEMU exits by itself. After 2 minutes the panel offers the forced stop.
  `lanai force-stop --confirm` writes the "forced" marker, then
  `systemctl --user kill --signal=SIGKILL lanai-vm.service`.
- **The Looking Glass client runs as its own unit** (`systemd-run --user --collect
  --unit=lanai-client …`), outside Hyprland's cgroup. `lanai open` focuses the window
  with `hyprctl dispatch focuswindow` when the unit is already active, so there is never
  a second client.
- **Paths.** Settings: `$XDG_CONFIG_HOME/lanai/settings.json`. Setup state and markers:
  `$XDG_STATE_HOME/lanai/`. Builds and runtime copies: `$XDG_DATA_HOME/lanai/`. Runtime:
  `$RUN=$XDG_RUNTIME_DIR/lanai/`, created by `lanai-vm-exec` with mode 0700; refuse if
  it exists and is a symlink, is not a directory, is not owned by the user, or has any
  mode other than 0700 (checked before any runtime file is created). It holds
  `qmp.sock`, `qmp-events.sock`, `qmp-cli.sock`, `spice.sock`, `qga.sock`, `virtiofs.sock`, `ivshmem`,
  passt's pid file and `client.log`. Not `RuntimeDirectory=`, which would delete the
  client log at stop.
- **VM hardware.** `lib/dockur-6.05.args` is a static template from the spike's capture
  (`spike/work/dockur-cmdline.txt`), filled with the user's `windows.mac`, storage
  path, memory and cores. Inputs are validated before use: the storage path must not
  contain a comma (refused; QEMU option syntax); the MAC must match
  `^([0-9A-Fa-f]{2}:){5}[0-9A-Fa-f]{2}$`; memory and cores must be integers in range.
  Rewrites: `-name Lanai,process=lanai` (req 30), guest RAM as
  `-object memory-backend-memfd,id=mem,size=<RAM>,share=on -machine memory-backend=mem`
  (not `-numa`, which adds guest-visible tables), `-serial mon:stdio` dropped. The
  template's devices and how each maps to spec req 2:

| Device or option | Req 2 item |
|---|---|
| `-machine q35,smm=off,hpet=off,vmport=off,...`, ICH9 `disable_s3`/`disable_s4`, `kvm-pit` policy | chipset (baseline hardware) |
| `-cpu host,...` (dockur's flags), `-smp` | CPU model and flags (cores from settings) |
| `virtio-scsi-pci` + `scsi-hd`, `rotation_rate=1`, `bootindex=3` | disk controller |
| `virtio-net-pci,romfile=,mac=<windows.mac>` | NIC model and MAC |
| pflash `windows.rom` (read-only) + `windows.vars` | UEFI firmware and variables |
| `-rtc base=localtime,clock=host,driftfix=slew` | clock in the host's time zone |
| `qemu-xhci` + `usb-tablet`, `virtio-rng-pci`, `-fw_cfg` entry, `-smbios type=1,serial=...` | baseline hardware (serial allowed to differ) |
| passt, `ivshmem-plain`, SPICE + `usb-redir`, `virtio-serial-pci` with the SPICE and QEMU guest agent ports, `vhost-user-fs-pci`, `-smbios type=11,value=lanai-scale=<step>` | allowed additions |
| `-vga virtio -display gtk,window-close=off` + read-only vvfat USB | setup boot only |

  No port forwards and no other listeners (req 25).

## dockur pre-boot writes (spec req 3)

Every file dockur 6.05 can write under the storage location before its VM starts, and
what covers it. Source: dockur 6.05 scripts (`init.sh`, `boot.sh`, `network.sh`,
`disk.sh`, `install.sh`, `power.sh`), extracted with
`docker run --rm --entrypoint sh dockurr/windows -c 'cat /run/<file>.sh'`.

| Write | Condition | Covered by |
|---|---|---|
| `rm -rf tmp/` | every start | harmless: not Windows data; `layout_check` refuses a `tmp/` Lanai did not expect so the hash check stays exact |
| `rm setup.img`, `setup.img.tmp` | every start | harmless: not Windows data; `layout_check` refuses a stray one so the file list stays exact |
| `chown` of the disk | every start | no change when the owner is already the user (checked) |
| `chown` of rom, vars | only when dockur recreates them | covered by the rows below |
| delete or recreate `windows.rom`, `.vars`, `.tpm` | `CLEAR` set | README risk |
| recreate `windows.rom` / `.vars` | missing or empty | req 5a check |
| write `windows.mac` | missing or empty | req 5a check |
| create, convert or grow the disk | missing, empty, format change, `DISK_SIZE` larger | req 5a checks (present, not empty, one disk file, size when readable); README risk for format and size changes |
| rewrite `windows.base` | value lacks `.iso` | req 5a check |
| delete `data.*`, `windows.*`, rom, vars (`cleanupStorage`); move to `backups/` (`backupPrevious`); `discardPrevious` | dockur's `needsInstall`: a base mismatch (version or language changed), a `custom.iso` / `boot.iso`, or not (`hasData` and `hasBootMarker`), which covers a missing `windows.boot` or a zeroed disk start | req 5a checks; README risk for settings and mounts |
| delete `$STORAGE/<base>` (`cleanupSource`) | base starts with `windows.` | req 5a base check |
| boot a second QEMU on the disk; `qemu-img convert` | any start while Lanai runs | QEMU's image lock on the disk (convert fails on it too); raw growth uses `fallocate` / `truncate`, which no lock stops, so it is covered by the disk-size README risk |

## Phase 1: Proofs on a test copy

Goal: settle the riskiest unknowns before building on them. First write
`bin/lanai-copy`, `lib/copy.sh` and `test/lanai-copy.bats` (its `setup` points `HOME`
and `XDG_*` at temp directories). Then each proof is a throwaway experiment against a
full reflink copy (`bin/lanai-copy ~/.windows <btrfs scratch>/lanai-proof`), using the
spike harness or a hand-written QEMU line. Record each result, with commands, output, and the URL and SHA-256 of every
download, in `docs/plugin/proofs.md`. If a proof fails, stop and take it to John.

1. **Display scale.** Boot with `-smbios type=11,value=lanai-scale=150`. A PowerShell
   script, committed as `guest/lanai-scale.ps1`, reads the SMBIOS OEM strings and sets
   the Looking Glass monitor's scale with `DisplayConfigSetDeviceInfo` (relative DPI).
   Pass: 150% applies without a sign-out, holds after the Looking Glass window is
   resized to a different resolution, and survives a reboot. Also try 250% and 300% at
   a small window, where Windows caps DPI by resolution, and record what happens. Fallback to record:
   `PerMonitorSettings\<id>\DpiValue`, applied at the next sign-in.
2. **virtiofs.** Run `/usr/lib/virtiofsd --socket-path=$RUN/virtiofs.sock --shared-dir
   <scratch folder> --sandbox namespace` as the user. Boot with the memfd backend and
   `vhost-user-fs-pci,chardev=vfs,tag=lanai`. In the guest, check for the `viofs`
   driver (`pnputil /enum-drivers`); install pinned WinFsp; start `VirtioFsSvc`. Pass:
   files round-trip; `..` and a planted host symlink pointing outside the share cannot
   be followed from the guest.
3. **QEMU guest agent and clock.** Install the pinned qemu-ga MSI with a config allowing
   only `guest-sync`, `guest-sync-delimited` and `guest-set-time`.
   **John runs this one** (it suspends his machine): suspend for 2 minutes, resume,
   and confirm a user-level `dbus-monitor --system` sees logind's `PrepareForSleep`
   and that `guest-set-time` brings the guest within 2 s of the host within 60 s.
   Also confirm a disallowed command (`guest-exec`) is refused.
4. **Shutdown paths. John runs this one** (it logs him out and reboots). Use a
   throwaway unit `lanai-proof.service` in `~/.config/systemd/user/`: `Type=exec`,
   `PartOf=` and `After=graphical-session.target`, `Slice=session.slice`,
   `TimeoutStopSec=2min`; `ExecStart` a script that starts
   `systemd-inhibit --what=shutdown --mode=delay` running a `dbus-monitor --system`
   loop that calls `systemctl --user stop --no-block lanai-proof.service` on
   `PrepareForShutdown(true)`, then execs the spike's QEMU line on the test copy with
   an extra `-qmp unix:$RUN/qmp.sock,server=on,wait=off`; `ExecStop` a script sending
   `qmp_capabilities` and `system_powerdown` on that socket, logging every event it
   reads (the observer for `SHUTDOWN` `"guest": true`), and waiting for exit.
   Delete the unit afterwards. With lingering off, then on:
   (a) logout gives the VM its stop timeout, with `uwsm start` staying alive until the
   VM unit stops, and the result is a clean shutdown (QMP `SHUTDOWN` with
   `"guest": true`); (b) at reboot, the delay inhibitor starts Windows' shutdown, and
   the time an idle Windows takes is recorded for the README. Also confirm
   `system_powerdown` shuts Windows down at the sign-in screen and in a locked session.

## Phase 2: Repo layout, CLI skeleton and CI

- `manifest.json`: `schemaVersion: 1`, `id: io.github.jzetterman.lanai`, `name: Lanai`,
  `version`, `kinds: ["bar-widget"]`, `entryPoints.barWidget: "Widget.qml"`,
  `barWidget.displayName: "Lanai"`, `defaultSection: right`, category System. Follow
  agent-desk's manifest (`~/.config/omarchy/plugins/io.github.jzetterman.agent-desk`).
- `LICENSE` (MIT). `README.md` stub (phase 7 fills it).
- `bin/lanai` dispatches to `lib/lanai.sh`; every path prints one JSON object.
- `test/lanai.bats` (bats-support, bats-assert); move the spike's reusable functions
  and their tests; `spike/` stays unchanged.
- `.github/workflows/test.yml`: `ubuntu-latest`, `container: archlinux:latest`,
  `timeout-minutes: 20`. `pacman -Syu --noconfirm bats bats-assert bats-support
  shellcheck ffmpeg jq socat e2fsprogs diffutils qemu-system-x86 qemu-img` (the lock
  tests run QEMU under TCG with `-S`, no KVM needed). Checkout with
  `persist-credentials: false`. Then `bats test spike/test` as an unprivileged user
  `tester` (via `runuser`, with its own `XDG_RUNTIME_DIR`), so the tests of unreadable
  files run, and `shellcheck -x bin/* lib/*.sh spike/lgtest test/*.bats
  test/helpers.bash spike/test/*.bats docs/plugin/proof-kit/proof-vm
  docs/plugin/proof-kit/proof-unit-start docs/plugin/proof-kit/proof-unit-stop`.
  Actions pinned by full SHA. btrfs-only tests skip on overlayfs.

## Phase 3: Adoption checks and settings (TDD)

Tests first, against fixture directories, for each function:

| Function | Behavior | Spec |
|---|---|---|
| `storage_dir` | configured location, default `~/.windows` only when no settings file exists; a symlinked settings file (dangling or not), or one that cannot be read or parsed, fails and never falls back; a symlinked storage folder resolves to its target | 6a |
| `compose_file` | `/var/lib/omarchy/windows/docker-compose.yml`, else legacy `~/.config/windows/docker-compose.yml`; readable or not. Values are read (`compose_value`) only in the map form `KEY: value` that `omarchy-windows-vm` writes: a key line in any other form, or the key in the list form (`- KEY=value`), is "cannot interpret KEY", and the checks that use it refuse; there is no list-form parser (John's decision) | 5, 6 |
| `layout_check <dir>` | the top level must hold exactly the allow-list `data.img`, `windows.base`, `windows.boot`, `windows.mac`, `windows.rom`, `windows.vars`, `windows.ver`, each a regular file; anything else is refused with its name, which covers `windows.mode` (Secure Boot or legacy), `*.tpm`, `data.qcow2`, dockur's hardware override files (`windows.{hv,vga,usb,sound,net,port,cpu,type,bios,flag,args,old,system,img}`), `custom.iso`, `boot.iso`, `tmp/`, `setup.img`, `backups/` (left by dockur's
`backupPrevious`; the refusal says so), and anything unknown. Then: no install when empty; `windows.rom`, `.vars`, `.mac` not empty; the disk not empty and its first 100 KB not zero; `windows.base` empty or equal to the image dockur 6.05 derives from the compose's VERSION and LANGUAGE when the compose is readable (an absent key gets dockur's default; a key it cannot interpret refuses), else from `omarchy-windows-vm`'s fixed values (VERSION 11, no LANGUAGE: `win11x64.iso`) per spec 5a | 5, 5a |
| `disk_size_check` | when the compose is readable, the disk is at least `DISK_SIZE` (normalized as dockur does); a dynamic size (`max` or `half`), a value that is not a size, or a line it cannot interpret refuses (John's decision); only when the compose cannot be read, skip and report "not checked" (spec 5a, John's decision; the README names the risk) | 5a |
| `share_check` | `~/Windows` exists, is a directory, not a symlink, owned by the user | 28 |
| `container_running` | a `/proc` process with argv0 `qemu-system-x86_64` in a cgroup whose path contains `docker` (systemd `docker-<id>.scope` or cgroupfs `/docker/<id>`) | 3 |
| `container_preparing` | a process in a `docker` cgroup whose argv shows dockur's entry script, with no QEMU yet (best effort; the image lock is the backstop) | 3 |
| `disk_locked <img>` | from the spike | 3 |
| `settings_seed` | only `RAM_SIZE` and `CPU_CORES` from a readable compose; else half the host's memory (at most 16 GiB) and half its threads (at most 8); never read `PASSWORD` or the credentials file. Test with a sentinel password in a fixture compose: it never appears in output, files, logs, or (through PATH shims) any child process's arguments or environment | 6 |
| `host_scale` | focused monitor's scale from `hyprctl monitors -j`, computed at `lanai start` | 12 |
| `scale_step <scale>` | nearest of 100-250 by 25 and 300-500 by 50, ties down, clamped; tested with the spec's matrix | 12 |
| `dockur_version` | the image version when readable without a prompt, for display only | 5a |

## Phase 4: VM lifecycle (TDD)

Tests first:
- `vm_args`: every req 2 item from the device table; every allowed addition; the
  `-name` rewrite; memfd backend sized from settings; nothing else (no `hostfwd`, no
  TCP or UDP listener options, no `/storage` or `/run/shm` paths, no `mon:stdio`).
- `record_previous_run`: "clean" only when `last-shutdown` records `"guest": true`
  with the same `$INVOCATION_ID` as the "running" marker; a "running" marker without
  it means forced; no marker means nothing to report. It always ends with the markers
  and `last-shutdown` deleted. Test every branch: guest shutdown, crash, external
  SIGTERM (forced, because it is not guest-initiated), force-stop, SIGKILL at reboot,
  a start that failed before the "running" marker (no false report, no double
  report), and a `last-shutdown` with another run's stamp (does not count).
- `lanai-vm-stop`: with `$EXIT_CODE` set it skips the powerdown; unset, it sends
  `system_powerdown`; both end with the bounded wait for a matching record (test both,
  QMP stubbed).
- `status_map`: fixture `systemctl --user show` output plus marker and setup-state
  combinations map to the spec's states (req 10) with cause and next step. "Starting"
  means the unit is active and QMP `query-status` reports running, but the guest
  agent's port is not open yet; "running" means QMP reports running and QMP
  `query-chardev` shows `frontend-open: true` for the guest agent's chardev (Windows'
  qemu-ga service opened its port early in boot). QEMU reports the open state itself;
  no data crosses the agent channel, which spec req 27 limits to the clock. Before
  guest setup installs the agent, the state after boot is "setup needed". The
  version-mismatch input is stubbed until phase 5.
- `qga_reply`: two modes. Sync mode sends a 0xFF byte first (to flush a half-read
  request), then `guest-sync-delimited` with a fresh random id, skips to the 0xFF in
  the reply, discards replies carrying any other id (a stale reply from an earlier,
  abandoned connection), and accepts only `{"return":<that id>}`; command mode (always
  after a fresh sync) accepts only `{"return":{}}`. Both reject
  replies over 4 KiB, junk and wrong JSON, and time out at 5 s.
- `vm_args` input validation: a storage path with a comma, a malformed MAC, and
  out-of-range memory or cores are each refused.
- `run_dir_check`: `$RUN` as a symlink, a file, or owned by another user is refused.
- `lanai start` refusals (each check, with PATH shims for `systemctl` and a fixture
  `/proc`); `run_dir_check` with an existing 0755 or 0777 directory refuses;
  `record_previous_run` with both a guest `SHUTDOWN` record and the "forced" marker
  reports forced; `lanai force-stop` without `--confirm` refuses; stale-socket cleanup; the
  runtime-copy refresh (version change triggers copy and `daemon-reload`); `lanai start`
  refuses while setup is incomplete.

Then:
- `preflight`: one function that every path runs immediately before
  `systemctl --user start lanai-vm.service` (`lanai start`, `lanai setup-guest`,
  setup's step 6 boot). It runs `record_previous_run`, then refuses with a reason on:
  an unfinished restore, `layout_check`, `disk_size_check`, `share_check`,
  `container_running`, `container_preparing`, `disk_locked`, or an active unit. Tests
  run each refusal through each entry point.
- `lanai start`: refuses while setup is incomplete; runs `preflight`; refreshes the
  runtime copy if the plugin version changed; computes the scale step; starts the unit.
- `lanai-vm-exec`, `lanai-vm-stop`, `lanai stop`, `lanai force-stop --confirm`,
  `lanai status` as described in the architecture.
- Helper supervision: the shutdown inhibitor, sleep watcher, event logger and
  virtiofsd each run under a small restart loop in `lanai-vm-exec` (restart with 1 s,
  2 s, 4 s backoff, at most 5 restarts a minute) and write their pid to `$RUN`.
  `lanai status` checks each pid; a missing helper shows as a warning on the running
  state, naming what is lost (for example "clock sync after suspend is off") and the
  next step ("shut Windows down and start it again"). Tests cover a dead helper in
  `status_map`.
- Shutdown inhibitor (background helper in the VM unit): holds
  `systemd-inhibit --what=shutdown --mode=delay`; on `PrepareForShutdown(true)` from
  `dbus-monitor --system`, runs `systemctl --user stop --no-block lanai-vm.service`.
- Sleep watcher (background helper): on `PrepareForSleep(false)`, sends
  `guest-sync-delimited` (sync mode) then `guest-set-time` with the host's nanoseconds
  (command mode) on `qga.sock`, using `qga_reply`; it retries within 60 s if the socket
  is busy (only the sleep watcher and setup's step 6 check use it).
- Event logger (background helper): holds `qmp-events.sock` and writes each `SHUTDOWN`
  event to `last-shutdown`.
- virtiofsd (background helper): `/usr/lib/virtiofsd --sandbox namespace
  --shared-dir ~/Windows --socket-path=$RUN/virtiofs.sock`.
- Snapshot and restore (req 7): `lanai snapshot` and `lanai restore` refuse while either
  VM runs. For the whole operation they hold QEMU's write lock on `data.img` by keeping
  `qemu-io -f raw data.img` open read-write with no commands and stdin held (`qemu-io
  -r` takes only a shared read lock and does not block a container's QEMU; tested in
  review round 3). Opening it also fails while any VM holds the disk, a free extra
  check. No lock can protect `windows.vars` (QEMU's pflash device shares every
  permission), so it is copied like the other unlocked files. The copy uses
  `reflink_tree` (not `lanai-copy`, whose own lock check would see Lanai's `qemu-io`).
  - Snapshots are atomic: `reflink_tree` builds into `<timestamp>.partial/`, then the
    copy's file list and every file's size and SHA-256 are checked against the source
    (held under the lock), a `COMPLETE` file with the manifest is written, and the
    directory is renamed to `<timestamp>/`. Only a directory with a valid `COMPLETE`
    counts: setup's step 3 and `lanai restore` ignore or refuse anything else, and
    leftover `.partial` directories are removed. Tests interrupt the copy at each stage.
  - Snapshot location: `$XDG_DATA_HOME/lanai/snapshots/<timestamp>/` when it shares a
    filesystem with the storage location, else a sibling folder
    `<storage>.lanai-snapshots/<timestamp>/`. Setup probes with a real reflink of a
    small file; if neither place can reflink, it says so and suggests a backup (req 7). Setup and the README state where it is,
    that it grows as Windows changes, how to delete it, and the restore command.
  - Restore: every file except `data.img` goes through a temp file plus `rename`.
    `data.img` is cloned in place without truncation, so it is never empty and the
    locked inode is the one written: `lib/ficlone.py` (a few lines of `python3`) opens
    it `O_WRONLY` without `O_TRUNC`, runs the `FICLONE` ioctl from the snapshot's disk,
    then truncates to the snapshot's size if the file was larger. (`cp` would truncate
    first, and a container starting in that window would see an empty disk and trigger
    dockur's `cleanupStorage`.) Files not in the snapshot are removed, so the result
    matches the pre-adoption hashes. Test under `LANAI_TEST_BTRFS_DIR`: FICLONE into a
    non-empty, larger and smaller file, with the SHA-256 matching the source after.
  - Restore is resumable: it first writes `$XDG_STATE_HOME/lanai/restore-in-progress`
    (naming the snapshot), then replaces files, then verifies the storage location's
    file list, sizes and SHA-256 against the snapshot's manifest, and only then deletes
    the marker. While the marker exists, `lanai start` and setup refuse ("a restore did
    not finish: run lanai restore again"), and `lanai restore` resumes the same
    snapshot. The README says not to start `omarchy-windows-vm` during a restore.
    Tests interrupt the restore after each replacement step, then rerun it.
  - Tests use `LANAI_TEST_BTRFS_DIR` for reflink; the lock test (a real
    `qemu-system-x86_64` start that must fail on `qemu-io`'s lock) runs on any
    filesystem, in CI too.

## Phase 5: Looking Glass client and host setup (TDD for the parsers)

- `lanai setup-host`, in a terminal opened by the panel (`omarchy launch terminal --
  …`), prints the exact command, then runs `sudo pacman -S --needed qemu-system-x86 qemu-img virtiofsd python
  qemu-ui-spice-core qemu-chardev-spice qemu-hw-usb-redirect qemu-ui-gtk
  qemu-hw-display-virtio-vga qemu-hw-display-virtio-gpu passt socat jq diffutils base-devel cmake
  spice-protocol libdecor usbredir fontconfig fuse3 libunwind libelf wayland
  libxkbcommon libglvnd nettle libpipewire libpulse libsamplerate`. Before release,
  confirm the whole package list (QEMU set and client build dependencies) once in a clean
  `archlinux` container.
- `lanai build-client`: fetch the pinned tarball (`lib/pins.sh` records build
  `B7-826-236efcb1`, commit `236efcb155f952f5d7d9fcd5891a3060ad254e68`, and the
  tarball's SHA-256; looking-glass.io's per-build tarball includes every submodule's
  tree, so that one hash covers the whole build input, spec req 26), verify SHA-256,
  check that the extracted tree has every submodule directory populated, build `client` with
  `-DENABLE_X11=no`, install to `$XDG_DATA_HOME/lanai/looking-glass/B7-826-236efcb1/`;
  fail if USB audio is disabled. Keep older builds until the guest IDD matches (req 8):
  `lanai open` picks the build whose version matches the guest version recorded from the
  last client log (`$XDG_STATE_HOME/lanai/guest-version`), else the pinned build. A pin
  change updates the guest by rerunning `lanai setup-guest` with the new media; until
  then the old build keeps the window working. When `setup-guest` succeeds it writes
  the installed pin to `guest-version`, so the next `lanai open` picks the new build.
  `build_select` gets bats tests (match, no record, no matching build, and the record
  written by `setup-guest`).
- `lanai open`: start or focus the `lanai-client` unit; the client waits for `ivshmem`,
  runs with `-f $RUN/ivshmem spice:host=$RUN/spice.sock spice:port=0
  win:setGuestRes=yes`, logs to `$RUN/client.log`. Closing it does not stop the VM.
- `version_check` (tests first, with trimmed fixtures from the spike's
  `spike/work/client-*.log`): parse `Version  :` after `Guest Information:`; normalize
  `B7-826-236efcb1` and `B7-826-g236efcb155` to tag, count and hash prefix; an
  `Incompatible` line is a hard mismatch; `transport source is not available` for 30 s
  means the IDD is missing. Wire it into `status_map`.

## Phase 6: Guest setup media and the setup flow

- `guest/setup.cmd` self-elevates once, then installs in order: SPICE vdagent MSI,
  qemu-ga MSI with its allow-list config, WinFsp MSI, the `viofs` driver if missing,
  `VirtioFsSvc`, the Looking Glass IDD (`/S /ivshmem`, exit code checked), and the
  logon task running `guest/lanai-scale.ps1`; then `shutdown /s /t 10` (a full
  shutdown: without `/hybrid`, `/s` bypasses fast startup), so QEMU exits and
  `lanai setup` starts the normal boot (the one restart).
- `lib/pins.sh` holds URL and SHA-256 for the Looking Glass source and IDD, SPICE
  vdagent 0.10.0 (from the spike), and qemu-ga, virtio-win and WinFsp (from phase 1's
  `proofs.md`).
- `lanai setup-guest` builds the setup media: download each pinned guest file into
  `$XDG_CACHE_HOME/lanai/downloads/`, verify its SHA-256 (a mismatch deletes the file
  and stops), unpack where needed (the IDD zip), then copy only verified files plus
  `guest/setup.cmd` and `guest/lanai-scale.ps1` into
  `$XDG_STATE_HOME/lanai/setup-media/`, which the setup boot exposes as the read-only
  vvfat USB disk. Then `preflight` and the `--setup` boot. Tests: a wrong checksum for
  each pinned file stops the build and leaves no unverified file in the media folder.
- `lanai setup` is a resumable state machine; each step's state lives in
  `$XDG_STATE_HOME/lanai/setup.json`, and each is detected, not assumed:

| Step | Done when |
|---|---|
| 1. Checks | `layout_check`, `share_check` and `container_running` pass |
| 2. Host packages | every package in the list is installed (`pacman -Q`); the snapshot needs `qemu-img` |
| 3. Snapshot offer | the user accepted (a snapshot with a valid `COMPLETE` exists) or declined (recorded); always before any Lanai boot |
| 3a. Normalize base | if `windows.base` is empty or missing (a missing file counts as empty everywhere, as it does for dockur's `readBase`), write the same name dockur's `readBase` would write, so a later container start rewrites nothing, and tell the user. Runs after the snapshot, so a restore returns the original empty file; `layout_check` itself stays read-only. Tested: restore after normalizing an empty base matches the pre-adoption hashes |
| 4. Client build | the pinned client binary exists and reports the pinned version |
| 5. Guest setup boot | `lanai setup-guest` booted with `--setup` and QEMU exited after `setup.cmd`'s full shutdown |
| 6. Normal boot | each guest component is checked, not assumed: the client log shows the matching IDD version; the guest agent answers a sync and a `guest-set-time` to the current host time (the channel's allowed use, which also proves the clock path); QMP `query-chardev` shows `frontend-open: true` for the SPICE agent's port (`vdagent`), as it does for the guest agent; the panel asks the user two one-click questions: does `~/Windows` show in Explorer, and does Windows' text look the right size (the scale task). Any missing component sends setup back to step 5 with "setup did not finish: run setup.cmd again"; `setup.cmd` is idempotent (each installer skips what is already installed at the pinned version). Tests cover a shutdown after a partly failed `setup.cmd` |
| 7. Done | all of the above |

  bats tests interrupt the flow after each step and check that `lanai setup` resumes at
  the right step.

## Phase 7: QML UI and README

- `Widget.qml`: a Lanai glyph distinct from the four Windows plugins; the tooltip shows
  state, cause and next step as text (req 10). Primary click starts Windows, or opens
  its window if running (reqs 11, 17); secondary click opens the panel. Keyboard
  reachable where the shell allows.
- Panel: Start, Open window, Shut down; the forced stop only after 2 minutes of a
  pending shutdown, with a second confirming click; setup steps with progress; settings
  (memory, cores); the error view with cause, next step, log path and the
  `omarchy-windows-vm` fallback.
- Polling: `lanai status` every 2 s while the panel is open or the VM is starting or
  stopping, every 15 s otherwise; 10 s deadline per call; QML calls never block on stop.
- README: install; removal (first `systemctl --user stop lanai-vm.service`, which works
  without the plugin; then the list of what setup installed and where); verified
  Omarchy and dockur versions; the remaining risks from req 5a (including the disk-size
  check skipped when the compose is unreadable); the clipboard exposure (req 29); the
  DNS-client note (req 24); the measured reboot shutdown time (req 19); the coexistence
  note (req 30).

## Phase 8: Acceptance

- **Rehearsal on a copy** (agent or John): point Lanai's storage at a fresh
  `lanai-copy` and run every spec acceptance row that does not start the container.
- **Test install** (rows 3, 4, 30-32): a separate machine or VM running Omarchy with
  `omarchy-windows-vm` and a copy of a Windows install. John picks the machine.
- **Live install** (John only, after the rehearsal passes).
- Checklist for rows 10-17 and 20, recorded in `docs/plugin/acceptance.md`:

| Row | Check |
|---|---|
| 10 | Each state appears with its text, cause and next step: not installed (empty storage copy), setup needed, stopped, starting, running, stopping, in use by `omarchy-windows-vm` (test install), version mismatch (older client build), failed (kill QEMU) |
| 11 | Start, open and shut down from the bar and panel; panel actions by keyboard |
| 12 | Tile, fullscreen, resize; desktop follows; scale matrix through `scale_step` tests plus two real host scales |
| 13 | Typing, mouse, clipboard text both ways, a file both ways, a system sound; a file copied in Windows appears on the host in the Looking Glass client's read-only FUSE folder under `/run/user/<uid>/` (the spike saw `looking-glass-clipboard-*`, `ro,nodev,nosuid,noexec`), checked with `findmnt` (spec req 29) |
| 14 | Sign-in with the user's password; `grep` for a sentinel password in Lanai's files and logs finds nothing |
| 15 | A file round-trips through `~/Windows` |
| 16 | Shut down from the bar is clean; a guest held busy past 2 minutes gets the forced-stop offer; it needs a confirmation |
| 17 | Close the window; the VM keeps running; the bar reopens it |
| 20 | Lock and unlock: within 10 s, live desktop, typing, mouse and sound, no reconnect |

- The release gate (spike measured sessions) stays separate and still applies.

## Risks

- A phase 1 proof fails: stop and take the spec change to John.
- A future dockur changes its startup: req 5a's checks, the pre-boot write table and the
  README cover known paths; the verified version is named in the README.
- Omarchy changes its shutdown timeouts or session model: proof 4 and the req 19 checks
  catch it; the README states what was measured.

## Review log

| Gate | Stage | Round | Findings |
|---|---|---|---|
| plan | a | 1 (full) | 2 blockers, 14 should-fix, 10 nits; all integrated (compose unreadable: skip the disk-size check, Claude's call per John's no-gate rule) |
| plan | a | 2 (full) | 1 blocker, 13 should-fix, 9 nits; all integrated (clean shutdown now recorded from QEMU's SHUTDOWN event) |
| plan | a | 3 (delta) | 1 blocker (tested: `qemu-io -r` does not block a container), 6 should-fix, 6 nits; all integrated; S3 resolved inside the spec (status uses QMP only; setup verifies the agent with `guest-set-time`) |
| plan | a | 4 (delta, cap) | 3 should-fix, 3 nits; John adjudicated (take all three recommendations): run bookkeeping via `record_previous_run` and `$INVOCATION_ID`; "running" needs the agent port open (`frontend-open`); restore clones `data.img` without truncation. Stage a closed. |
| plan | b | 1 (full) | 3 blockers, 3 should-fix; all confirmed. Blockers 1-2 (unreadable compose) resolved by John's spec 5a amendment (use `omarchy-windows-vm`'s fixed values, skip the size check); atomic snapshots; step 6 verifies each guest component; pins record the LG commit; row 13 checks the clipboard folder |
| plan | b | 2 (full) | 2 blockers, 3 should-fix. Blocker 1 (logout vs 5 s cap) partly confirmed: the mechanism was already researched; the plan now states it and the fallback. Blocker 2 (empty base rewrite) confirmed: setup normalizes it. Should-fix all confirmed: supervised helpers with status warnings; `lanai-copy` holds the lock and verifies; resumable restore with a marker |
| plan | b | 3 (full, cap) | 1 blocker, 5 should-fix; all confirmed (item 5 was a regression from the round-1 rewrite); John adjudicated: integrate all. Shared `preflight` before every unit start; base normalized after the snapshot; `$RUN` must be 0700; forced marker wins; `setup-guest` builds verified media; step 6 checks the SPICE agent and asks about text size. Gate closed. |
| diff (phases 1-3) | a | 1 (panel: correctness, security, testing, maintainability) | 0 blockers, 7 should-fix, ~20 nits (after dedupe); all integrated. A reviewer read the real compose file once against instructions (read-only; only memory and cores printed); disclosed to John |
| diff (phases 1-3) | a | 2 (delta) | 0 blockers, 0 should-fix, 4 nits (3 integrated, 1 negligible); stage a clean |
| diff (phases 1-3) | b | 1 (full) | 1 blocker (readable but uninterpretable compose fell back to defaults), 1 should-fix (read-only folders); both confirmed and integrated |
| diff (phases 1-3) | b | 2 (full) | 0 blockers, 2 should-fix in the proof kit (unverified cached installers; newline paths); both confirmed and integrated |
| diff (phases 1-3) | b | 3 (full, cap) | 2 blockers, 1 should-fix, all fail-open cases (list-form compose keys, DISK_SIZE max/half, symlinked settings file); John ruled: refuse all three (no list-form parser); integrated. Gate closed. |
