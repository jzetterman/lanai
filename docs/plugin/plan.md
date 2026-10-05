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
  - `ExecStart=lanai-vm-exec`: create and check `$RUN` (below) and build QEMU's
    arguments (`vm_plan`, which `boot_vm` also runs as a dry run before it starts the
    unit); remove stale sockets and a stale `ivshmem`, and truncate `client.log`; start
    in the background virtiofsd, the shutdown inhibitor, the sleep watcher and the event
    logger (one cgroup; with the default `KillMode` systemd kills them only after
    `ExecStop` returns); wait for a fresh `virtiofs.sock`; write the "running" marker;
    exec QEMU. The scale and boot mode come from `$XDG_STATE_HOME/lanai/boot.json`, which
    `boot_vm` writes.
  - `ExecStop=lanai-vm-stop`: systemd runs it after every stop. When QEMU has already
    exited (`$EXIT_CODE` set) it goes straight to the final wait. Otherwise (a session
    end or the inhibitor, req 19) it sends QMP `system_powerdown` on `qmp.sock`, and again
    every 10 s while QEMU runs (a stop during early boot), and waits for the process to
    exit. Both paths end with the same wait of up to 2 s for this
    run's `last-shutdown` record, so the event logger is not killed before it writes.
  - Three QMP sockets, each with one owner: `qmp.sock` (the unit's stop path),
    `qmp-events.sock` (the event logger, connected for the VM's life), and `qmp-cli.sock`
    (the CLI; every call connects, reads with a timeout, and disconnects, because QEMU
    serves one client per socket at a time). The inhibitor never uses QMP; it runs
    `systemctl --user stop --no-block lanai-vm.service`. Both logind watchers match
    `sender='org.freedesktop.login1'`, and act only on a broadcast: a user's
    `dbus-monitor --system` falls back to eavesdropping, where a signal sent to its own
    name (which any local process may send) passes the match rule, so a header with a
    destination other than `(null destination)` is ignored. dbus-monitor also prints
    string arguments raw, newlines included, so a unicast signal can carry lines that
    look exactly like a broadcast; its output is therefore only a trigger. Before
    acting, each watcher asks logind itself (`busctl get-property
    org.freedesktop.login1 /org/freedesktop/login1 org.freedesktop.login1.Manager`):
    the shutdown watcher stops the unit only when `PreparingForShutdown` is `b true`,
    the sleep watcher syncs the clock only when `PreparingForSleep` is `b false`. When
    busctl does not answer, it does nothing and logs why.
  - The event logger retries its connection until QEMU creates `qmp-events.sock`, then
    records each QMP `SHUTDOWN` event (`guest`, `reason`) to
    `$XDG_STATE_HOME/lanai/last-shutdown`, stamped with the unit's `$INVOCATION_ID`
    (systemd gives `ExecStart` and `ExecStop` the same value, so "this run's record"
    means a matching stamp). "Clean" (spec: a guest-initiated shutdown) means that event
    with `"guest": true`, nothing else. Once QEMU answers on the socket, the logger also
    writes `$XDG_STATE_HOME/lanai/started` with the invocation id: the run really
    started.
  - Run bookkeeping has one owner, `record_previous_run`, called by every path that
    starts the unit (`lanai start`, `lanai setup-guest`, setup's step 6 boot) before
    starting it. It turns the previous run's markers into a verdict in
    `$XDG_STATE_HOME/lanai/last-run` (forced when the "forced" marker exists, which takes
    precedence even over a guest `SHUTDOWN` event that arrived just before the kill;
    else, for a "running" marker whose invocation also has the "started" stamp, clean
    when a matching guest `SHUTDOWN` record exists and forced otherwise; a "running"
    marker without the stamp is a start that failed, not a forced stop), then deletes
    the "running" marker, the stamp, the "forced" marker, `last-shutdown` and
    `stop-requested`. `lanai-vm-exec` only writes the "running" marker, with
    `$INVOCATION_ID`, right before it execs QEMU. `status_map` reads `last-run`, and the
    panel clears it once it has shown a forced-stop notice, so each is shown once. The
    notice names a locked Windows, an open Windows security screen, or a shutdown that
    did not finish in time as likely causes (spec req 19).
- **Stopping from the UI never uses `systemctl stop`** (req 16). `lanai stop` sends
  `system_powerdown` on `qmp-cli.sock` and records the request time (`stop-requested`:
  the invocation id and the time; a repeated stop keeps the first time); the unit stays
  active until QEMU exits by itself. After 2 minutes the panel offers the forced stop.
  `lanai force-stop --confirm` writes the "forced" marker, then
  `systemctl --user kill --signal=SIGKILL lanai-vm.service`.
- **The Looking Glass client runs as its own unit** (`systemd-run --user --collect
  --unit=lanai-client …`), outside Hyprland's cgroup. `lanai open` focuses the window
  with `hyprctl dispatch focuswindow` when the unit is already active, so there is never
  a second client.
- **Paths.** Settings: `$XDG_CONFIG_HOME/lanai/settings.json`. Setup state and markers:
  `$XDG_STATE_HOME/lanai/` (`setup.json`, whose `"done": true` marks finished setup
  for the storage location it records (phase 6); `setup-reply.json`, `lanai setup`'s
  last reply; `setup-media/`, the setup disk's folder; `guest-version`;
  `boot.json`; `running`, `started`, `forced`, `last-shutdown`, `last-run`,
  `stop-requested`, `restore-in-progress`, and `lock`, which `lanai start`, `setup`,
  `setup-guest`, `snapshot` and `restore` hold with `flock` so they never overlap).
  Settings keys: `storage`,
  `memory_gib`, `cores`. Builds and runtime copies: `$XDG_DATA_HOME/lanai/`. Runtime:
  `$RUN=$XDG_RUNTIME_DIR/lanai/`, created by `lanai-vm-exec` (or `boot_vm`'s dry run)
  with mode 0700; refuse if
  it exists and is a symlink, is not a directory, is not owned by the user, or has any
  mode other than 0700 (checked before any runtime file is created). It holds
  `qmp.sock`, `qmp-events.sock`, `qmp-cli.sock`, `spice.sock`, `qga.sock`, `virtiofs.sock`, `ivshmem`,
  passt's pid file, `client.log`, `qga-open-since`, `qga-closed-since` (setup's step 6,
  phase 6), and a pid file per helper (`virtiofsd.pid`,
  `shutdown-watch.pid`, `sleep-watch.pid`, `event-log.pid`). Not `RuntimeDirectory=`,
  which would delete the
  client log at stop.
- **VM hardware.** `lib/dockur-6.05.args` is a static template from the spike's capture
  (committed as `spike/test/fixtures/dockur-cmdline.txt`), filled with the user's `windows.mac`, storage
  path, memory and cores. Inputs are validated before use: the storage path must not
  contain a comma (refused; QEMU option syntax); the MAC must match
  `^([0-9A-Fa-f]{2}:){5}[0-9A-Fa-f]{2}$`; memory must be 1 to 512 GiB and cores 1 to 64,
  as integers. The passt line's `dns-forward=` is the host's IPv4 default gateway (from
  `ip -j -4 route`); with no default route it is left out and Windows boots without a
  network (passt starts in local mode; `lanai start` says so; John to confirm).
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
| read-only vvfat USB; `-vga virtio -display gtk,window-close=off` only when `boot.json` asks for QEMU's window (phase 6 decides) | setup boot only |

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

Results (2026-09-28): all four pass, apart from proof 4's locked session, where Windows
drops the power button. John chose to turn off the Windows lock (spec req 7). The other
proof findings are folded into phases 4 to 7 below.

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
  after a fresh sync) accepts only `{"return":{}}`; refusal mode (after a fresh sync,
  used only by setup's step 6) passes only on an error of class `CommandNotFound`
  whose text says the command has been disabled, and fails on any `{"return":...}`.
  All three reject
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

### As built (2026-09-28)

Where the code differs from the text above, the code and this list win:

- `preflight` checks the unit first: while it is not stopped (active, starting, or
  still shutting down) it refuses before `record_previous_run`, so a second start
  cannot delete a live run's markers. An unreachable user manager refuses too.
- `boot_vm <setup true|false>` is the one start path (`lanai start` now; phase 6's
  `lanai setup-guest` and step 6 boot). Under the `lock` flock it runs `preflight`,
  the scale step, a dry run of `lanai-vm-exec`'s own checks (`vm_plan`: `$RUN`, the
  settings, `windows.mac`, the gateway, `vm_args`), so a refusal is explained instead
  of showing as a failed unit; then the runtime copy (`bin/` and `lib/`; every step's
  failure stops it), `boot.json`, and `systemctl --user start`.
- Setup counts as finished when `setup.json` has `"done": true` (phase 6 writes it);
  phase 6 adds that its recorded storage location must match `storage_dir`.
- The unit carries `XDG_CONFIG_HOME`, `XDG_STATE_HOME` and `XDG_DATA_HOME` as
  `Environment=`; those paths and the runtime copy's path may hold only
  `A-Z a-z 0-9 . _ / @ + : , ~ = -` (anything else is refused rather than quoted).
- virtiofsd runs once, not under the restart loop: QEMU's vhost-user device never
  reconnects, so a restarted virtiofsd would serve nothing. Its pid file goes when it
  exits, and status warns. The other helpers restart as planned. Each pid file holds
  the supervisor's (or virtiofsd's runner's) pid; status counts a helper alive only
  when that pid is in `lanai-vm.service`'s cgroup and is not a zombie.
- Status: before setup is done, a booted VM is "setup needed" even with an agent port
  open (a guest agent from an earlier setup run, or one the user installed). A unit
  that failed with
  `Result=timeout` (a stop that ran out of time, as at logout with lingering) is
  "stopped", not "failed". The forced-stop `notice` comes only from `last-run` (the
  next start's verdict), so the panel can show it once and clear it; a forced stop
  the next start has not recorded yet shows as `forced_pending: true`.
- The logind watchers treat dbus-monitor's output only as a trigger and confirm with
  logind's own `PreparingForShutdown` / `PreparingForSleep` property (via `busctl`)
  before they act, since a unicast signal's string argument can forge a broadcast
  (see Architecture).
- `lanai-vm-exec` repeats `restore_pending` and `share_check` (in `vm_plan`), since a
  direct `systemctl --user start lanai-vm` skips `preflight`. `lanai-vm-stop` counts a
  zombie `MAINPID` as exited.
- `vm_args` checks the template for container paths before the user's paths are
  filled in (a storage location may well contain `storage`), and also refuses passt's
  `tcp-ports=`, `udp-ports=` and `param=`.
- `guest-set-time` carries `@NOW_NS@`, which `qga_reply` fills with the host clock as
  the command goes out, after the sync. The resume retry stops after 60 s.
- Snapshots record their source: a `SOURCE` file beside `COMPLETE` holds the storage
  location's real path, and only snapshots of the current location are listed,
  restored or cleaned (`.partial` leftovers of this location, or with no `SOURCE` yet;
  the flock means none is being built). A snapshot place is used, listed or resumed
  from only when it is a real folder owned by the user with no group or other write
  (`own_dir`; new ones are made 0700), and each snapshot folder must be the user's.
  A snapshot takes install files only: dockur's `setup.img` leftovers or a restore's
  temp files must be deleted first, and the folder must pass `layout_check` (so
  `windows.mac`, the reflink probe file, exists). Success is reported only after the
  tree is flushed before its rename and the snapshot place and final name after it, so
  a crash cannot leave a reported snapshot named `*.partial` for the next snapshot to
  remove. `lanai snapshots` lists them.
- Restore touches only an existing storage folder that holds nothing but regular files
  named in `layout_check`'s allow-list, dockur's `setup.img` leftovers and its own
  `.lanai-restore.*` temp files; anything else (a folder, a symlink, a user's file)
  refuses the restore, since Lanai's storage may point at the wrong place. Before it
  writes, it checks every file of the snapshot against `COMPLETE`, and refuses an
  empty snapshot disk or a NOCOW difference between the two `data.img` files, which
  `ficlone.py` could not clone (a marker it could never finish). It removes only
  extras a restore may remove, with `rm -f`; any other file that appears while it
  runs is kept, named, and the restore stays unfinished. The marker holds the snapshot and the storage
  location, is flushed to disk before any write, and resumes only for that location;
  when its snapshot is gone or damaged, `lanai restore <other>` replaces it. Files go
  in name order with `data.img` last. Lock order: when `data.img` exists, QEMU's write
  lock is taken right after the cheap read-only checks and held to the end, through
  the minutes of hashing too (req 7), so no container VM or direct start of
  `lanai-vm` can boot meanwhile; a refusal after it (a damaged snapshot) releases it
  and leaves no marker and nothing written. The marker is written before the first
  write to the storage folder. When `data.img` is missing, the order is marker, then
  the disk put back, then the lock; if either fails, the marker stays, `lanai start`
  keeps refusing, and `lanai restore` finishes it once the other VM is stopped.
- `ficlone.py` cuts a larger `data.img` to the snapshot's size before the clone, not
  after (btrfs refuses to clone a source that ends mid-block into a larger file); it
  never cuts to zero, refuses an empty source, symlinks, and two files that differ in
  NOCOW.
- Phases 6 and 7 must run `lanai snapshot` and `lanai restore` detached from the QML
  call: they read the whole disk (minutes), far past the 10 s deadline.
- For phase 7: a Shut down click during early boot, before Windows handles the ACPI
  button, is lost, and status then offers the forced stop after 2 minutes. The
  panel's Shut down must stay usable while the state is stopping; each `lanai stop`
  sends `system_powerdown` again and keeps the first request's time.

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
  change updates the guest by rerunning `lanai setup` with the new media; until
  then the old build keeps the window working. Once the guest has the new IDD,
  `guest-version` holds the new pin, so the next `lanai open` picks the new build
  (phase 6 records it from step 6's pinned client log).
  `build_select` gets bats tests (match, no record, no matching build, and the record
  written by setup step 6).
- `lanai open`: start or focus the `lanai-client` unit and return at once (the QML
  deadline is 10 s, and a first boot can take longer). The unit's `ExecStart` is a small
  wrapper, `lanai-client-exec`, that retries on `qmp-cli.sock` until QEMU answers a
  command: each try connects, reads the greeting, sends `qmp_capabilities` then
  `query-status`, and succeeds only on a `return` that holds `status` (the handshake
  of the extra check in `proofs.md`). Each try uses a short connect and read timeout (2 s) and
  closes its connection; a missing socket, a refused connect or a read timeout means
  retry, since QEMU serves one client per socket and a status poll may hold it. The
  60 s cap covers the whole wait, then it fails with a message. It closes the QMP
  connection before it execs the client, since a leftover connection would be the
  only client QEMU serves on that socket and would block `lanai status` and `lanai
  stop`. Only then does it exec the client, redirecting its output to `$RUN/client.log`
  itself (not `StandardOutput=file:`, which fails when `$RUN` does not exist yet). The
  timeout message goes to the unit's journal; `status_map` reads only the latest
  invocation (`journalctl --user -u lanai-client -I "$(systemctl --user show -p
  InvocationID --value lanai-client.service)"`), so an old message does not linger. The QMP greeting does not count: only the command reply does. QEMU creates
  `memory-backend-*` objects after chardevs and runs QMP commands only from its main
  loop, after every backend exists (tested 2026-09-28, recorded in `proofs.md`). So the
  client never opens a stale `ivshmem` left by an earlier run; proof 4 hit that race,
  when the client found the old file and the new VM then replaced it. The client runs
  with `-f $RUN/ivshmem spice:host=$RUN/spice.sock spice:port=0 win:setGuestRes=yes`.
  Closing it does not stop the VM.
- `version_check` (tests first, with trimmed fixtures from the spike's
  `spike/work/client-*.log`): parse `Version  :` after `Guest Information:`; normalize
  `B7-826-236efcb1` and `B7-826-g236efcb155` to tag, count and hash prefix; an
  `Incompatible` line is a hard mismatch; `transport source is not available` for 30 s
  means the IDD is missing. Wire it into `status_map`.

### As built (2026-09-29)

Where the code differs from the text above, the code and this list win. The code is
in `lib/client.sh`; the commands are in `lib/lanai.sh`.

- `lanai setup-host` never runs sudo. It checks the list with `pacman -T` (deptest,
  which honours provides, so `jq-git` counts for `jq`) and, only when a package is
  missing, runs `setsid -f omarchy launch terminal -- bin/lanai-setup-host` and
  returns the missing packages and the exact command. `setsid -f` returns once it has
  forked, so Lanai cannot see the window: it fails only when that launch fails, and
  otherwise says a terminal should open and names `bin/lanai-setup-host` (full
  path) to run by hand if none appears. In that terminal,
  `lanai-setup-host` refuses unless stdin and stdout are a terminal, checks again,
  prints the command, runs `sudo pacman -S --needed <missing packages>` from the same
  array (never the whole list, which would offer to replace a `-git` provider), and
  waits for Enter. Every package name exists in the Arch repositories (`pacman -Si`,
  2026-09-29); the clean-container check before release is still open.
- `lanai build-client`: the tarball has no `.gitmodules`, so `lib/pins.sh` pins the
  six submodule folders (`LG_SUBMODULES`), and a missing or empty one stops the
  build. The USB audio check reads cmake's feature summary and needs
  `ENABLE_USB_AUDIO` among the enabled features, which also catches audio turned off
  as a whole. The client has no version flag, so `client_version` reads the
  `Looking Glass (<build>)` line it logs first, also for `--help`; the installed
  binary must report the pin. Downloads go to `$XDG_CACHE_HOME/lanai/downloads/`,
  the build to a work folder there (removed after), the output to
  `$XDG_STATE_HOME/lanai/build-client.log`. A cached download is used only when it
  still matches the pin, else it is fetched again; curl gives up on a connect over
  20 s or a transfer under 1 KiB/s for 60 s, so a stalled download cannot hold the
  lock. It installs through `<build>.partial/`, holds `build.lock`, and does nothing
  when the pinned build is already installed. Older builds are removed only by `build-client`, once
  `guest-version` matches the pin. One real run on 2026-09-29: the download matched
  the pinned SHA-256, and the build took 22 s and reported `B7-826-236efcb1`.
- `lanai open` needs the VM unit active. It focuses with `hyprctl dispatch
  focuswindow pid:<MainPID>` (`lanai-client-exec` execs the client, so the unit's
  main pid is the client), not by app id, which every Looking Glass client shares.
  Before it starts the unit it records the guest version the last client log names.
  `systemd-run` passes `WAYLAND_DISPLAY` and the `XDG_*` folders with `--setenv`,
  since the user manager may lack them, and `--expand-environment=no`, so a `$` in a
  path stays literal. It sets `PartOf=lanai-vm.service`: every stop of the VM unit
  stops the client too, even when ExecStop is killed at `TimeoutStopSec`, and unlike
  `Requires=` or `BindsTo=` it never starts the VM. It runs in `session.slice`, like
  the VM, since Omarchy has oomd kill in `app.slice` under memory pressure.
- `lanai-client-exec`'s wait runs one `qmp_call` per try. `qmp_call` always closes its
  connection, even after a reply without a status; the 2 s budget
  (`LANAI_QMP_BUDGET`) only bounds how long a try takes. A test on a one-client
  socket checks it.
- Status reads the client's result from `$RUN/client.log`, not from `journalctl -I`:
  with `--collect`, a failed transient unit is unloaded, so its invocation id is gone.
  `lanai-client-exec` rewrites the log on each start (a `lanai: client started at
  <epoch>` line, then the client's output, appended so an emptied log stays whole),
  or writes the timeout message as its only line; the message also goes to the
  journal. So the log always holds the latest try only. Accepted risk: the log has no
  size cap. It sits in `$XDG_RUNTIME_DIR` (tmpfs) and is read on every status poll,
  but a new client or VM start empties it, and the spike's 8-minute session logged
  under 100 lines.
- `version_check` prints `match`, `mismatch`, `idd-missing`, `waiting` or `unknown`,
  plus the guest's version when the log names one. The latest event wins (a guest that
  comes back after a mismatch counts). A guest version the client reports as
  `unknown` is a mismatch. The 30 s count needs the start line, since the client's log
  times count from its own start; only the log's first line counts as the start
  line, since the guest can put text at the start of a later line through its
  version string. The client logs "transport source is not available" only on its
  first wait, so a missing IDD is detected for the first session of each client, not
  after a guest restart mid-session. `guest_version_set` records only what
  `lg_version_key` can read.
- `status_map`: a stop in progress and a QEMU error come before a mismatch, so the
  forced stop is still offered (spec 16). Then a mismatch is `version-mismatch`. A
  missing IDD counts only while the client unit runs (a log whose window was closed
  is stale) and once Windows has booted (QMP running, the agent's port open, setup
  done), since a client opened at boot waits for the IDD too; it is `failed`, with
  the client log as `logs` and the `omarchy-windows-vm` fallback. A client that gave
  up waiting is a warning, but not while a new client waits.
- `lanai status` and `lanai open` record the guest version a client log names only
  when that client started (the log's first line) no earlier than the record was
  written (`guest-version`'s mtime), and never from a log without that line. So the
  pin setup step 6 records (phase 6) is not undone by this run's older client
  log, which would bring back the old build and the "run setup again" warning.
  `guest_version_set` always rewrites the file, so its mtime is the record's time.
- A pin bump the guest has not caught up with (req 8): when the recorded guest version
  is not the pinned build, `build_select` keeps the old build, so the window works,
  and status adds a warning in every state but `version-mismatch`: the driver's
  version, the pin, and "run Lanai setup again to update it".
- Added: `lanai-vm-stop` stops the client unit once QEMU is gone (a QEMU that exits on
  its own starts no stop job, so `PartOf=` does not cover it), so a client never holds
  an old run's shared memory, and `lanai open` never focuses a dead window. It then
  waits up to 3 s for the unit to leave active, activating or deactivating, so a
  quick Start then Open starts a client for the new VM; a client that ignores SIGTERM
  costs at most those 3 s before ExecStop goes on (systemd kills it later).
- For phase 6: step 6 records the pin from its pinned client's log
  (`guest_version_note`, phase 6); step 2 uses `host_packages_missing`, step 4 `client_version`, and step 6
  `version_check`.

## Phase 6: Guest setup media and the setup flow

- `guest/setup.cmd` self-elevates once. Before the prompt it reads the signed-in user's
  SID (`whoami /user /fo csv /nh`, which does not depend on the Windows language) and
  passes it to the elevated stage, which refuses, with a clear message, if its own SID
  differs (a standard user who typed an administrator's credentials: `HKCU` would then
  be the administrator's hive). The elevated stage runs from System32, so it calls
  every file by `%~dp0`. After the SID check and before the media check, it tries
  `set "WTEST=.lanai-wtest-%RANDOM%%RANDOM%%RANDOM%"`, then
  `copy /y nul "%~dp0%WTEST%" >nul 2>&1`. Each run uses an unpredictable name so
  another account cannot defeat the probe by pre-planting a read-only file at its
  old fixed name. If the copy succeeds,
  it deletes the same test file with `del "%~dp0%WTEST%" >nul 2>&1`
  and stops: "Lanai setup: run setup.cmd from Lanai's read-only setup drive,
  not from a copy." The real drive is a read-only vvfat disk; a writable NTFS volume,
  virtio-fs share or UNC copy can let other accounts swap an installer or plant a
  DLL. No localized text is parsed. The different-account refusal also explains
  that Windows' Administrator protection, when on, causes this. Then it checks
  that every media file is there, and, in order:
  - installs the SPICE vdagent MSI;
  - installs the qemu-ga MSI, then sets the allow-list with the literal command from
    proof 3, which is fixed by the pinned MSI and safe to rerun:
    `sc.exe config QEMU-GA binPath= "\"C:\Program Files\Qemu-ga\qemu-ga.exe\" -d
    --retry-path --allow-rpcs=guest-sync,guest-sync-delimited,guest-set-time"` (in
    `cmd`, where the nested quotes survive). Only a reinstall or repair of the MSI
    resets it; rerunning `setup.cmd` sets it again;
  - installs the WinFsp MSI;
  - always installs the pinned `viofs` driver from the setup media with `pnputil
    /add-driver %~dp0viofs\w11\amd64\viofs.inf /install`. Exit codes 0 and 3010 are
    success, and 259 means the driver is already current; anything else stops setup
    and shows the code. dockur's older driver fails with virtio-win 0.1.302's
    `virtiofs.exe` (proof 2);
  - checks `VirtioFsSvc` with `sc.exe query`. If it exists (not 1060), it runs `net
    stop VirtioFsSvc`, which waits for the stop, and ignores its result (the exit code
    is 2 both for "not started" and for real failures, and the message is localized).
    On a rerun the service holds Lanai's own `virtiofs.exe` open. It then creates
    `C:\Program Files\Lanai` if missing and copies
    `%~dp0viofs\w11\amd64\virtiofs.exe` there; a failed copy (for example, the file
    is still held) stops setup and shows the error. Then it runs `sc.exe create
    VirtioFsSvc` if the service was missing, or `sc.exe config VirtioFsSvc` when dockur
    already made it, both with
    `binPath= "\"C:\Program Files\Lanai\virtiofs.exe\"" start= auto depend= "WinFsp.Launcher/VirtioFsDrv"`
    (proof 2's values, with the path quoted inside as for QEMU-GA: a LocalSystem
    service with an unquoted path that holds a space is CWE-428);
  - copies `lanai-scale.ps1` into `C:\Program Files\Lanai\` (standard users cannot
    write there, so no other account can swap the script; a folder under `C:\` would
    need an ACL race), then adds the logon task running it, its path quoted in the
    task's argument;
  - runs `call "%~dp0lanai-lock.cmd"` (spec req 7; without `call`, control never returns
    to `setup.cmd`). `lanai-lock.cmd` never relaunches itself, so the one administrator
    prompt stays the only one (spec req 7) and every write finishes in the caller's
    process: if it is not elevated (`fltmc` fails; it needs the administrator token
    and, unlike `net session`, not the Server service), it prints a message and runs
    `exit /b 1`, and it always ends with `exit /b`, never `exit`. `setup.cmd` stops if
    it returns non-zero. With `reg add /f` and `reg delete /f`,
    which are safe to rerun, it sets `DisableLockWorkstation` REG_DWORD 1 under
    `HKCU\Software\Microsoft\Windows\CurrentVersion\Policies\System` (removes Lock
    from Start and Ctrl+Alt+Del, and turns off Windows key + L); `HideFastUserSwitching`
    REG_DWORD 1 under `HKLM\SOFTWARE\Microsoft\Windows\CurrentVersion\Policies\System`
    (Switch user leaves the session behind the sign-in screen, the same state as a
    lock); and `ScreenSaverIsSecure` REG_SZ "0" under `HKCU\Control Panel\Desktop`; and
    deletes `InactivityTimeoutSecs` under that HKLM key, only when `reg query` finds it
    (`reg delete` exits 1 on an absent value, the normal case). It does not print or
    keep the old values: setup keeps no record of them, and the README's restore steps
    bring back Windows' defaults (spec req 32). Sign-in on wake and Dynamic Lock cannot
    fire in this VM (the template sets `disable_s3=1`
    and `disable_s4=1`, and the VM has no Bluetooth), so it leaves them alone; the lock
    proof confirms both. Last, if `(Get-CimInstance Win32_ComputerSystem).PartOfDomain`
    is true, `dsregcmd /status` reports `AzureAdJoined : YES` or `WorkplaceJoined :
    YES`, or a subkey of `HKLM\SOFTWARE\Microsoft\Enrollments` holds a non-empty
    `DiscoveryServiceFullURL` or `UPN` (an MDM enrollment; each found with `reg query
    ... /s /v <name>` piped to `findstr /r "^ *<name>  *REG_SZ  *[^ ]"`), it prints
    that a policy may turn the lock back on, and that shutdowns may then end in the
    forced stop. `ProviderID` alone does not count: stock Windows 11 has built-in
    `Enrollments` subkeys that hold one. `LANAI_FAKE_MANAGED=1` makes that check
    report membership, for row 7b; self-elevation drops the caller's environment, so it
    must be set in an elevated prompt that runs `lanai-lock.cmd` directly;
  - immediately before the IDD install, sets `LANAI_IDD` to
    `%~dp0looking-glass-idd-setup.exe` and uses PowerShell to read its Authenticode
    signature from that environment variable. Only a `Valid` signature with a signer
    certificate is added to `LocalMachine\TrustedPublisher`, the same as choosing
    "Always trust software from HostFission", to avoid a second publisher prompt.
    This is best effort: on failure, print that Windows may ask to trust the Looking
    Glass driver's publisher and to choose Install, then continue (the host already
    checks the installer's pinned SHA-256);
  - installs the Looking Glass IDD last (`/S /ivshmem`, exit code checked), because it
    turns the setup display black (Step 1 of `proofs.md` ordered it last for the same
    reason), so nothing after it may need the user's eyes or a key press;
  - then `shutdown /s /t 10` (a full shutdown: without `/hybrid`, `/s` bypasses fast
    startup), so QEMU exits and `lanai setup` starts the normal boot (the one restart).
    No service is restarted before that: both services start automatically, so the next
    boot applies their new settings, and step 6 checks them.
- Lock proof (done 2026-10-01: passed; `proofs.md` Proof 5 holds the results and the
  notes folded in below), with John at the keyboard. It uses the existing
  test copy `$S/lanai-proof` and the proof kit. First write `guest/lanai-lock.cmd`,
  since the proof runs the real file. Extend `proof-vm client` to wait on the kit's
  only QMP socket, `qmp.sock`, with the same handshake as `lanai-client-exec` (greeting,
  `qmp_capabilities`, then a `query-status` reply that holds `status`), and to
  disconnect before it execs the client, so it never opens a stale `ivshmem` and the
  send-key command below can be the only client on that socket. The copy already has the IDD, which leaves QEMU's own window black, so
  every step runs through the Looking Glass client: start it with `"$K/proof-vm"
  client` once the VM is up, and again after each guest restart. Extend `proof-vm
  media` to copy `lanai-lock.cmd` into the setup disk, then rerun `"$K/proof-vm" media
  "$S/kit"` so the setup disk holds it.
  Boot with `"$K/proof-vm" run "$S/lanai-proof" --setup "$S/kit/setup"`. Sign back in
  after every control that locks, before the next one. The Windows key + L control
  (not a warm-up) is this command, which holds the connection open, since QEMU drops
  requests still queued when the client disconnects; it must print `{"return": {}}`
  twice:

  ```sh
  { printf '%s\n' '{"execute":"qmp_capabilities"}' \
      '{"execute":"send-key","arguments":{"keys":[{"type":"qcode","data":"meta_l"},{"type":"qcode","data":"l"}]}}'
    sleep 1; } | socat - "UNIX-CONNECT:$XDG_RUNTIME_DIR/lanai-proof/qmp.sock"
  ```

  Send Ctrl+Alt+Del the same way, with the qcodes `ctrl`, `alt` and `delete`.
  1. Positive controls, each on its own. Confirm each of these locks Windows or leaves
     it at the sign-in screen: Lock in Start; Lock in Ctrl+Alt+Del; Windows key + L sent
     as above; `rundll32 user32.dll,LockWorkStation` (the call apps use); Switch user;
     a 1-minute secure screen saver alone, set in Settings (so a screen saver program is
     chosen, and "On resume, display logon screen" is ticked); then, with the screen
     saver off, the inactivity limit alone, set with `reg add
     HKLM\SOFTWARE\Microsoft\Windows\CurrentVersion\Policies\System /v
     InactivityTimeoutSecs /t REG_DWORD /d 60 /f`, after a restart. If a control does
     not lock, fix the control before step 2. A path with no working control counts as
     unproven. Then turn on the 1-minute secure screen saver and `InactivityTimeoutSecs`
     60 together, as a user's earlier settings.
  2. Run `lanai-lock.cmd` elevated, then restart Windows (some values load at sign-in).
  3. Leave the settings as the script left them, and do not open the screen saver
     dialog (saving it can write `ScreenSaverIsSecure` back). Confirm with `reg query`
     that `InactivityTimeoutSecs` is gone, `ScreenSaveTimeOut` is still 60 and
     `ScreenSaverIsSecure` is "0". Repeat every manual path from step 1; none may lock
     Windows. Idle 3 minutes or more and confirm Windows is still unlocked. Run
     `powercfg /a` and `Get-PnpDevice -Class Bluetooth`: if any sleep state is
     available or any Bluetooth device exists, stop and take it to John (spec row 7b
     requires both paths unable to fire).
  4. In an elevated prompt, `set LANAI_FAKE_MANAGED=1`, run `lanai-lock.cmd` again,
     and confirm it prints the policy warning (row 7b).
  5. With the 1-minute screen saver (now not secure) showing, run `"$K/proof-vm" stop`.
     Pass: it prints `QEMU exited`, which after `system_powerdown` happens only when
     the guest powers off. Repeat once with the Ctrl+Alt+Del screen left open, and
     record the result either way.
  Record the results in `proofs.md`. If any lock path survives, stop and take it to
  John.
- Row 7b's different-account refusal runs in phase 8 on a copy that has not been
  through setup (a fresh `lanai-copy` of the test install, or a restored snapshot).
  Boot it with the setup media attached (`lanai setup-guest`, or `proof-vm run
  --setup`). dockur signs in the administrator automatically, so first take the
  inventory: `EnableLUA` (the check needs UAC on, so that the standard user gets an
  administrator credential prompt; proof 5 found `0x1` on John's install, while
  dockur's stock install may leave `0x0`). If it is `0x0`, record that, set it to 1
  and restart before the inventory, as a test-only change. The lock
  values (`reg query`), installed drivers (`pnputil
  /enum-drivers`), services (`sc.exe qc` for `QEMU-GA` and `VirtioFsSvc`), installed
  programs and scheduled tasks. Then create a standard local account, sign out, sign
  in as it, run `setup.cmd` from the setup disk, and approve the prompt with the
  administrator account. Setup must refuse before changing anything: the same
  inventory matches (any guest agent or file-sharing service already there stays as
  it was; dockur 6.05 installs no guest agent, hands-on run 2026-10-04), and the Looking Glass IDD and the scale task are absent.
- `guest/lanai-scale.ps1` fix (proof 1): it sometimes logs the current scale as blank
  (at 100%, and once at 125%), because `curScaleRel` can point outside the step list.
  Log the raw `minScaleRel`, `curScaleRel` and `maxScaleRel`, and route all four
  `$Steps[...]` lookups through one guarded `StepName($i)` helper that returns
  `unknown` when the index is below 0 or above the last step; PowerShell wraps negative
  indexes silently (`$Steps[-1]` is 500), and `$recommended` and `$maxIdx` can also go
  out of range. The apply path uses only `minScaleRel` and `maxScaleRel`, so this is a
  logging fix only.
- `lib/pins.sh` holds URL and SHA-256 for the Looking Glass source and IDD, SPICE
  vdagent 0.10.0 (from the spike), and qemu-ga, virtio-win and WinFsp (from phase 1's
  `proofs.md`).
- `lanai setup-guest` builds the setup media: download each pinned guest file into
  `$XDG_CACHE_HOME/lanai/downloads/`, verify its SHA-256 (a mismatch deletes the file
  and stops), unpack where needed (the IDD zip; and from the verified virtio-win ISO,
  which is too big for QEMU's FAT disk, only `viofs\w11\amd64\`: the ISO's w11 files are hard links to the 2k25
  copies, and other viofs folders link into `fwcfg` (found in the hands-on run,
  2026-10-04), so `bsdtar` unpacks `viofs/2k25/amd64` and `viofs/w11/amd64` beside
  the media, keeps `viofs/w11/amd64` and removes the rest; the ISO's folders are
  read-only, so cleanup makes them writable first),
  then copy only verified files plus
  `guest/setup.cmd`, `guest/lanai-lock.cmd` and `guest/lanai-scale.ps1` into
  `$XDG_STATE_HOME/lanai/setup-media/`, which the setup boot exposes as the read-only
  vvfat USB disk. Then `preflight` and the `--setup` boot. Tests: a wrong checksum for
  each pinned file stops the build and leaves no unverified file in the media folder;
  the media holds `viofs\w11\amd64\` and never the ISO itself.
- The setup boot's display (proof 5): when Windows has the IDD, QEMU's window adds a
  second screen. Windows extends the desktop across both, the pointer goes missing in
  Looking Glass, and QEMU's screen goes black once Windows drops it. So the setup disk
  and QEMU's window become two separate choices in `boot.json` and `vm_args`. The
  setup boot always attaches the disk. Lanai cannot see inside the disk, so it guesses
  from the guest version record (`guest_version_get`), and the user can override the
  guess either way:
  - No record (a fresh dockur install): QEMU's window (`-vga virtio -display
    gtk,window-close=off`) and no client. QEMU needs `WAYLAND_DISPLAY` for this window
    (the user manager may lack it; the proofs ran the window only from a terminal).
    `boot_vm` writes the caller's value into `boot.json` beside the window flag, and
    `lanai-vm-exec` exports it only for a window boot, before it execs QEMU; `boot_vm`
    refuses a window boot with a message when it is unset. While the unit is active,
    `lanai status` reports `window: true` from `boot.json`, and `lanai open` refuses
    with a message, since a client would show nothing; the bar and panel hide Open.
  - A record: `-vga none -display none`, as a normal boot does, then `lanai open`,
    whose `build_select` picks the client build that matches the guest's IDD.
  - The override: `lanai setup --window` (passed on to `setup-guest`) forces QEMU's
    window and keeps the guest version record unchanged;
    `--no-window` forces the client. A wrong guess shows nothing useful (an empty
    client window, or a QEMU window that is black or shows a second desktop). During
    the step 5 boot the panel shows Shut down. Status reports `active: true` or
    `false` beside `window` (the state name cannot say it: an active VM also reads
    `setup-needed` before setup is done). Once `active` is false, the panel calls
    `lanai setup`, whose resume either goes on to step 6 or replies that step 5 did
    not finish, with two buttons: "Start setup on QEMU's screen" (`--window`) and
    "Start setup in the Windows window" (`--no-window`), each with one line saying
    when to use it. The panel advances setup automatically at step 5's end and
    during step 6, following the serialized calls in "For phase 7" below.
  - Setup state follows the disk. `setup.json` holds `location` (`storage_dir`'s
    output, the real path, so a symlinked `~/.windows` matches), `snapshot` (`taken`
    or `declined`, step 3), `step5` (true once its boot ended as below) and `done`.
    `setup_done` (phase 4) also requires `location` to match, so `lanai start` refuses
    a disk that setup has not seen. One function, `setup_reset`, first runs
    `record_previous_run` (so markers from an earlier boot cannot mark step 5 done on
    the new state), then removes `setup.json`, `setup-reply.json` and
    `guest-version`. It needs the lock and a stopped unit, so it runs only where
    the lock is already held: in `lanai setup`'s resume, which takes the lock in a
    subshell that exits before it calls `boot_vm` (a second `lanai_flock` in one process
    fails); and in `lanai restore`. Setup resume calls it when `setup.json` is
    missing, has no `location`, or names another one, and only after `layout_check`
    passes on the current location (an unmounted drive behind a symlink must not wipe
    setup state). `lanai restore` calls it after every restore, and its next step
    becomes "run Lanai setup": a snapshot from step 3 predates any Lanai boot, and
    setup is idempotent for a later one. Setup then starts again at step 1: phase 8's
    rehearsal on a copy never marks the live install as set up or skips its snapshot
    offer, and step 3 finds the existing snapshot, so the offer is not repeated.
  - Step 5's verdict has the same owner as the rest of the run bookkeeping:
    `record_previous_run`, which already reads these markers. When `boot.json` says
    `setup: true`, the verdict is clean and no `stop-requested` exists for that
    invocation, it sets `step5` in `setup.json`. Nothing else: a panel Shut down or a
    forced stop never counts, and a Start-menu shutdown or a session-end stop does,
    which step 6 catches.
  - Step 6's boot rechecks setup state under `boot_vm`'s own lock, after `preflight`:
    `setup.json` must exist, its `location` must match `storage_dir`, and `step5`
    must be true. If a restore reset it after setup's resume released the lock,
    Lanai refuses with "Lanai setup changed while it was starting Windows." and
    the next step "run setup again", and starts nothing. Ordinary `lanai start`
    also rechecks `setup_done` under that lock after `preflight`; a restore reset
    after its first check refuses with "Lanai setup has not finished." and starts nothing.
  - The pin is recorded from evidence, not from step 5. Step 6 starts the pinned
    client directly, bypassing `build_select`. On `match`, `guest_version_note`
    records the pin from step 6's own log (the client starts after the record, so the
    mtime rule allows it). Only `idd-missing` or `mismatch` is an IDD failure and sends
    setup back to step 5, leaving the record as it was, so the retry's guess stays
    right: no record on a fresh install (QEMU's window), the old version on a pin bump
    (the old client still matches the old IDD). A client that closes during step 6
    (`unknown`, `waiting` or `idd-missing`) is reopened for a fresh 30 s, not counted;
    `mismatch` stays decisive.
  - Pin bumps go through `lanai setup` (spec req 8: the window keeps working
    throughout). `lanai setup` reopens at step 5 whenever `guest_version_behind` prints
    a version, even with `done: true`; status already says "run Lanai setup again".
    `lanai setup-guest` alone records nothing.
  - Two screens remain possible when the guess is wrong the other way (no record, but
    an IDD in Windows: a disk set up earlier, then restored or switched back to). The
    `--no-window` button is the way out.

  The proof kit keeps `--setup DIR` as it is (disk and window): reproducing the
  two-screen case, as proof 5 did, needs both. Tests: `vm_args` with the disk and no
  window, and with both; a setup boot with no record (window, no client), with a
  record (client, no window), with `--window` and a record (window, record unchanged),
  and with `--no-window` and no record (client); a window boot with `WAYLAND_DISPLAY`
  unset refuses, and with it set `boot.json` carries it and `lanai-vm-exec` exports
  it, while a client boot exports nothing; status reports `window` and `active`, and
  `lanai open` refuses during a window boot; a `setup.json` for another location, or
  with none, fails `setup_done`, and setup resets it and removes `guest-version`; a
  symlinked storage path matches its recorded real path; a dangling one resets
  nothing; `lanai restore` resets both; a restore or a storage change after a clean
  setup boot leaves `step5` unset and no `guest-version`; `record_previous_run` sets
  `step5` after a clean setup boot, and not after a panel Shut down, a forced stop,
  a crash/systemd kill without shutdown or forced markers, or a clean normal boot; setup state reset between resume and step 6's boot (missing
  file, wrong location, false or missing `step5`) refuses and starts nothing;
  setup reset between `lanai start`'s check and its lock refuses and starts nothing;
  a step 6 boot that never started reports its logs once, clears the unit's failed
  state and retries on the next call;
  step 6 records the pin on `match`, keeps the old record on
  `idd-missing` or `mismatch`, and reopens a closed client; `lanai setup` with `done:
  true` and a guest version behind the pin resumes at step 5. Existing fixtures that
  write `{"done": true}` (`test/lifecycle.bats`) gain `location`. The panel's buttons
  are QML, so phase 8 checks them.
- Host keys never reach Windows (proof 5): Hyprland takes Super shortcuts, and
  Omarchy's Ctrl+Alt+Del closes every host window. Setup and the README never ask the
  user to press either. Where Windows needs one, they give a click path inside Windows
  or a Lanai route (QMP `send-key`, or the client's own key binding, checked on the
  pinned build first).
- `lanai setup` is a resumable state machine; each step's state lives in
  `$XDG_STATE_HOME/lanai/setup.json`, and each is detected, not assumed:

| Step | Done when |
|---|---|
| 1. Checks | `layout_check`, `share_check` and `container_running` pass |
| 2. Host packages | `host_packages_missing` (phase 5, `pacman -T`) prints nothing; the snapshot needs `qemu-img` |
| 3. Snapshot offer | the user accepted (a snapshot with a valid `COMPLETE` exists) or declined (recorded); always before any Lanai boot |
| 3a. Normalize base | if `windows.base` is empty or missing (a missing file counts as empty everywhere, as it does for dockur's `readBase`), write the same name dockur's `readBase` would write, so a later container start rewrites nothing, and tell the user. Runs after the snapshot, so a restore returns the original empty file; `layout_check` itself stays read-only. Tested: restore after normalizing an empty base matches the pre-adoption hashes |
| 4. Client build | `client_version` (phase 5) reports the pinned version for the pinned binary |
| 5. Guest setup boot | `record_previous_run` set `step5`: the setup boot ended in a clean guest shutdown that was not the panel's Shut down or a forced stop (`setup.cmd`'s shutdown, or another the user started, which step 6 catches) |
| 6. Normal boot | each guest component is checked, not assumed: the pinned client, started directly, logs `match` (`version_check`, phase 5), and that log records the pin; the guest agent answers a sync and a `guest-set-time` to the current host time (the channel's allowed use, which also proves the clock path), and refuses an argument-free `guest-exec` with `CommandNotFound ... has been disabled`, the reply proof 3 recorded (the allow-list took effect; spec req 27; without arguments the command could not run anything even if the allow-list had failed); QMP `query-chardev` shows `frontend-open: true` for the SPICE agent's port (`vdagent`), as it does for the guest agent; the panel asks the user two one-click questions: does `~/Windows` show in Explorer, and does Windows' text look the right size (the scale task). Any missing component sends setup back to step 5 with "setup did not finish: run setup.cmd again"; `setup.cmd` is idempotent (each installer skips what is already installed at the pinned version). Tests cover a shutdown after a partly failed `setup.cmd` |
| 7. Done | all of the above |

  A step 6 start failure reports "Windows did not start." and points to the logs.
  After reporting it, setup runs `systemctl --user reset-failed lanai-vm.service`
  (ignoring its result), so systemd's failed state does not block the next boot retry.
  Before reopening a closed client, step 6 queries QMP and checks the guest
  agent's port timers. A port still closed past `LANAI_SETUP_BOOT_LIMIT` sends
  setup back to step 5 even if the client keeps closing. Once the port has been
  open for `LANAI_SETUP_GRACE`, a client verdict still `unknown` or `waiting`
  is a host client failure: step 6 replies `ok: false`, "The Windows window did
  not stay open long enough to check the display driver.", with next step
  "see the logs with journalctl --user -u lanai-client, then run setup again".
  That call stays at step 6 and does not reopen the client.

  bats tests interrupt the flow after each step and check that `lanai setup` resumes at
  the right step.

### As built (2026-10-01)

Where the code differs from the text above, the code and this list win. The setup
code is in `lib/setup.sh`; the tests are in `test/setup.bats` and `test/guest.bats`.

- The guest writable-copy probe uses `.lanai-wtest-%RANDOM%%RANDOM%%RANDOM%` in
  `WTEST`; both the copy and cleanup use that variable. A successful probe still
  means writable and refuses setup. `setup.cmd` retains CRLF endings.
- `lanai setup` options: `--no-snapshot` declines step 3, `--window` and
  `--no-window` pick step 5's display, and `--share-ok yes|no --scale-ok yes|no`
  answer step 6's two questions (two yeses finish setup; a lone no sends it back).
  Replies carry `step` (`"1"` to `"7"`, or `"3a"`) except option errors and
  setup resume's own lock or user-manager refusals, which precede step detection.
  Refusals from `setup_guest` or `boot_vm` on the setup-boot path go through
  `setup_with_step` and carry a step, including lock and user-manager failures.
  Setup runs the client build, the media build and
  both boots itself; for packages and the snapshot it names the command to run
  (`lanai setup-host`, `lanai snapshot`), and an existing snapshot of the location
  counts as taken. If recording either snapshot decision fails, step 3 replies
  `ok: false`, "Lanai cannot record its setup state.", and stops. Step 3a writes
  the name and stops with a note; the next call goes on.
- Step 1 also refuses an unfinished restore (`restore_pending`) and a container VM
  that is only preparing (`container_blocked`, which covers `container_running`).
- `step5` has three values: absent (no setup boot yet, so the next one boots with the
  guess), `false` (written when a setup boot starts or an explicit display choice
  is made; still `false` once it has ended means it did not finish, and setup asks for `--window` or `--no-window`
  instead of booting), and `true`. A failed guest check in step 6 removes it, so
  the retry boots with the guess; the host client failure below keeps it true.
  Finishing setup removes it too, so a later pin bump starts
  step 5 afresh while `done` stays true and `lanai start` keeps working. With the
  unit stopped, an explicit `--window` or `--no-window` sets it to `false` and starts
  a setup boot whatever it said, even on a finished install (the way out of a
  step 6 that cannot finish). The explicit choice bypasses step 7's finished shortcut. When
  `false` belongs to a run that never started, setup says "Windows did not start."
  and points to the logs. `record_previous_run` prints `nostart` for a "running"
  marker without its matching "started" stamp, clears the markers and leaves
  `last-run` unchanged. Resume consumes that verdict; its only fallback is a failed
  unit's `Result=exit-code`. With `step5: true`, `nostart` gives an `ok: false`
  step 6 reply pointing to `$LANAI_LOGS` once, then clears the unit's sticky failure
  with `systemctl --user reset-failed lanai-vm.service` (ignoring its result);
  the next call retries the boot.
  An explicit display choice that fails before starting (downloads or a missing
  `WAYLAND_DISPLAY`) keeps `step5: false`, so the next call offers both choices,
  even on an already finished install: the finished shortcut respects `step5: false`.
- `--window` keeps the guest version record unchanged; step 6 records the pin only
  from its own `match`, so a failed QEMU boot cannot lose the old client selection.
- `setup.json` gains a fifth key, `round`: a setup boot sets it to true before
  starting the unit, and only step 7 removes it (with
  `step5`); `setup_reset` removes it with the rest. While a round is open, `lanai
  setup` does not report a `done` setup as finished: a round's step 6 may have
  recorded the pin before a later check failed, so "behind the pin" alone could not
  tell. `setup_done`, and so `lanai start`, ignore
  it (spec 8: the window keeps working during a pin bump).
- `lanai setup` runs `record_previous_run` and `setup_follow` itself, under the lock
  and only with the unit stopped, so step 5's verdict is there without a new boot.
- Setup boots recheck `setup_current` for `storage_dir` and a snapshot decision of
  `taken` or `declined`, without resetting or changing state. Step 6 uses the same
  read-only helpers for the location and `step5: true`. `setup_reset` is called
  only through setup resume's `setup_follow` and after restore, under the lock.
- Step 6's boot rechecks `setup.json`, its storage location and `step5: true` under
  `boot_vm`'s lock after `preflight`; a reset between resume and boot refuses without
  starting the VM or client. Ordinary `lanai start` also rechecks `setup_done`
  under that lock after `preflight`, using its existing setup-needed reply when a
  restore reset setup after the initial check.
- A setup boot in client mode does not open the client: its reply says "open the
  Windows window", and the panel calls `lanai open`.
- Step 6 queries QMP and checks the port timers before reopening the client.
  The pinned client must be the one logging. A client of another build (an
  Open during step 6) is stopped and the pinned one started; within the timer
  bounds below, a client that closed while its verdict is `unknown`, `waiting`
  or `idd-missing` is reopened for a fresh 30 s (`match` and `mismatch` stand).
  A failed QMP call means try again, never a missing part. Step 6 stamps the
  first time it sees the guest agent's port open in `$RUN/qga-open-since`, and
  removes the stamp whenever the port is closed (a Windows restart keeps the same
  QEMU); `lanai-vm-exec` removes both agent stamps at each start. Every grace counts
  from the open stamp (`LANAI_SETUP_GRACE`, 60 s): a guest part that has not
  answered by then is missing. A client that is not running, with its verdict
  still `unknown` or `waiting` after that grace, is a host client failure (a
  running client still in its own 30 s, as after a reopen, is waited for): an
  `ok: false` step 6 reply says
  "The Windows window did not stay open long enough to check the display driver."
  and "see the logs with journalctl --user -u lanai-client, then run setup again".
  That call neither goes back to step 5 nor reopens the client.
  The client starts its 30 s count when QEMU starts, so firmware and boot time use
  it up; `idd-missing` counts only once the guest agent's port has been open for the
  grace, and means wait before that. `mismatch` sends setup back at once. The first
  poll that sees the port closed stamps `$RUN/qga-closed-since`; seeing it open
  removes that stamp. A port still closed after `LANAI_SETUP_BOOT_LIMIT` (300 s)
  from that stamp sends setup back to step 5: "Windows did not finish starting,
  or its guest agent is missing". A Windows restart gets a fresh boot limit,
  regardless of the client's start time, whether its start line exists, or whether
  it keeps closing. The guest agent is asked only while its port is open (a sync
  on a closed port waits 5 s).
  A lone `--share-ok no` or `--scale-ok no` sends setup back too.
- `lanai setup-guest` refuses until step 3 has a decision for this location. It holds
  the lock, with the VM stopped, for the whole media build (downloads included), and
  removes the old media first, so a failed build leaves none. The media use fixed
  names (`spice-vdagent.msi`, `qemu-ga.msi`, `winfsp.msi`). `bsdtar` also unpacks
  the IDD zip, so `unzip` is not a dependency (`bsdtar` comes with `libarchive`,
  which pacman needs). Every symlink anywhere in the assembled media is refused;
  the setup-media path also refuses `:` because QEMU's `fat:` parser treats it
  specially.
- `setup.cmd`, from the first build's reviews (the text above says the same): the
  scale script lives in `C:\Program Files\Lanai\` beside `virtiofs.exe`, and there is
  no `C:\Lanai` at all (a folder under `C:\` raced its ACL against other accounts);
  `VirtioFsSvc`'s path is quoted inside; after the SID check it refuses any writable
  setup folder with the write probe above, then checks every media file before
  changing Windows. Stage 1 reads the elevated stage's exit code exactly: a declined prompt is 1223 (the PowerShell call catches the cancel,
  which Windows PowerShell 5.1 raises as a non-terminating error), and only it and a
  missing SID pause; an IDD failure exits 2 and nothing pauses on a display that may
  be black. The sign-in task is registered with PowerShell's `Register-ScheduledTask`
  as "Lanai display scale" (interactive logon, no stored password). Each MSI passes
  on exit code 0 or 3010 only. Immediately before the IDD install, PowerShell adds
  the installer's signer certificate to `LocalMachine\TrustedPublisher` only when
  its Authenticode signature is `Valid`. The path comes from `LANAI_IDD`, set from
  `%~dp0looking-glass-idd-setup.exe`, rather than being inserted into PowerShell code.
  This avoids the HostFission publisher prompt; if it fails, setup prints a note to
  choose Install if Windows asks and continues to the pinned installer.
- `lanai-vm-exec` unsets `WAYLAND_DISPLAY` for a boot without QEMU's window. Status's
  `active` is true while the unit is active, activating, deactivating or reloading;
  `window` is true only while the unit runs.
- Tests: `isolate_home` unsets `WAYLAND_DISPLAY`. `fake-qga` gains `allowlist`, `open` and
  `notime` replies, `fake-qmp` a `FAKE_QMP_VDAGENT` knob. The `lanai-scale.ps1` tests
  need `pwsh` and skip without it (CI has none).
- For phase 7: the panel calls only `lanai setup`; `lanai setup-guest` remains a
  CLI command. The display buttons call `lanai setup --window` or
  `lanai setup --no-window`. Setup can run for minutes (the client build, downloads
  or a boot), and a step 6 call can pass 10 s (QMP and two guest agent exchanges,
  each with a 5 s limit). Run setup detached, past QML's 10 s deadline, and read
  its reply from `$XDG_STATE_HOME/lanai/setup-reply.json`, written atomically using
  a unique temporary file per call and removed on failure. Concurrent CLI calls
  can publish either complete reply without sharing a temp file; the panel never
  runs two setup calls at a time. It calls on a click; automatic calls require
  the last reply to be `ok: true` and say to wait. For step 5, the panel watches
  the setup boot until status shows the unit inactive, then calls setup; for
  step 6, it calls while the reply says to wait. "Step 6 waiting" means the
  setup reply, not status. Automatic calls happen at most once every 10 s.
  After any `ok: false` reply, and after step 5's display choices, the panel
  waits for a click. These calls advance step 6's timers without clicks.
  Status wins over a stale `setup-reply.json`.
  The panel reads reply detail keys `choices` (step 5), `questions` (step 6),
  `missing`/`command` (step 2), `active`/`window` (step 5 while running), and
  `window` (boot replies), alongside `ok`, `step`, `message` and `next`.
- Both client build callers use `build_client_locked` for `build.lock` and `flock`.
  A build still reporting the wrong version stops with an `ok: false` step 4 reply
  instead of looping. Only `cmd_setup` marks its emitted reply in the parent shell.
- Open for phase 8: whether `msiexec` returns 1638 over dockur's own qemu-ga or SPICE
  agent; whether `/S /ivshmem` is the IDD installer's exact silent syntax; whether
  `windows.base` should end in a newline (3a writes one).

## Phase 7: QML UI and README

Implementer (John, 2026-10-04): gpt-6.1-sol, by John's choice, although the global
routing asks for taste 7 or more for user-facing work and sol scores 6. Claude's
reviews look hard at the panel's wording, layout and states.

- First, two short checks, recorded in `proofs.md`:
  - Resize (proof 1 finding): resizing the Looking Glass window with a Hyprland mouse
    drag grows it faster than the mouse moves. On the phase 6 test copy, run `lanai
    start` and attach the pinned client with each option below. Reproduce it, then retry
    with one client option changed at a time: `wayland:warpSupport=no`, then
    `input:captureOnly=yes`, then `win:setGuestRes=no` (to rule out a resize feedback
    loop). On the pinned client, `input:captureOnFocus` is already off and
    `input:rawMouse` applies only in capture mode. A fix changes phase 5's client flags;
    if nothing fixes it, add a README note.
  - Scale timing: dockur signs in automatically at boot, possibly before the client
    attaches and sizes the display, so the logon task may see the IDD's default
    resolution and cap the scale (proof 1: 125% at about 1024x768). On a test copy that
    finished phase 6 setup, with the focused monitor at 150% or more, run `lanai start`
    and wait, without attaching the client, until `lanai status` says running (the
    guest agent answers), which is when a user would click Open. Then `lanai open`, and
    read the "allowed" line in `%LOCALAPPDATA%\Lanai\lanai-scale.log`. Run a second
    trial with `lanai open` right after `lanai start`. If either trial caps the scale,
    take it to John before writing any README note.

- `Widget.qml`: a Lanai glyph distinct from the four Windows plugins; the tooltip shows
  state, cause and next step as text (req 10). Primary click starts Windows, or opens
  its window if running (reqs 11, 17); secondary click opens the panel. Keyboard
  reachable where the shell allows.
- Panel: Start, Open window, Shut down; the forced stop only after 2 minutes of a
  pending shutdown, with a second confirming click; setup steps with progress (step 5
  shows Shut down, then the two display buttons when `lanai setup` asks for them, and
  Open is hidden while status reports `window: true`; see phase 6's setup boot
  display; step 6 asks its two questions, sent as `--share-ok` and `--scale-ok`.
  The panel calls only `lanai setup`, detached, on clicks. Automatic calls require
  an `ok: true` reply that says to wait: at step 5, watch the setup boot until
  status shows the unit inactive, then call setup; at step 6, call while the
  setup reply says to wait (not status). Call at most every 10 s and never two
  at a time. After any `ok: false` reply, and after step 5's display choices,
  wait for a click. Display buttons use `lanai setup --window|--no-window`;
  `lanai setup-guest` is a CLI command. It reads `setup-reply.json`, with status
  winning over a stale reply, and the detail keys `choices`, `questions`,
  `missing`/`command`, `active`/`window` and boot `window` as listed in phase 6's
  "For phase 7" contract); settings
  (memory, cores); the error view with cause, next step, log path and the
  `omarchy-windows-vm` fallback.
- Guest-controlled text (from phase 5 review): show `client.log`, the guest's driver
  version and any other text from the guest or its logs with `Text.PlainText`, never
  QML's default `AutoText`, which would render markup the guest wrote.
- Polling: `lanai status` every 2 s while the panel is open or the VM is starting or
  stopping, every 15 s otherwise; 10 s deadline per call; QML calls never block on stop.
- README rules from phase 6: no step asks the user to press Super shortcuts or
  Ctrl+Alt+Del (the host keys bullet), and it says that a restore means running setup
  again.
- README: install; removal (first shut Lanai's VM down with
  `systemctl --user stop lanai-vm.service`, then start Windows with
  `omarchy-windows-vm` and connect over RDP; every Windows removal step runs in that
  RDP session, since removing the IDD or SPICE vdagent can remove Lanai's display or
  input and a normal Lanai boot has no QEMU display. In an administrator Command
  Prompt as the same Windows user
  (some settings are in `HKCU`): restore Windows' default lock settings with `reg delete
  HKCU\Software\Microsoft\Windows\CurrentVersion\Policies\System /v
  DisableLockWorkstation /f`, `reg delete
  HKLM\SOFTWARE\Microsoft\Windows\CurrentVersion\Policies\System /v
  HideFastUserSwitching /f` and `reg delete "HKCU\Control Panel\Desktop" /v
  ScreenSaverIsSecure /f` (`InactivityTimeoutSecs` is absent by default, so nothing is
  written back; the same three commands are how to turn the lock back on), then undo
  each other change setup made, or say why it can stay: the SPICE vdagent, qemu-ga with
  its allow-list, WinFsp, the newer `viofs` driver, the `VirtioFsSvc` settings, the
  Looking Glass IDD, the logon task ("Lanai display scale") and `C:\Program Files\Lanai`
  (`virtiofs.exe` and `lanai-scale.ps1`); remove HostFission's certificate from
  Trusted Publishers (`certlm.msc`, Trusted Publishers). Then shut Windows down
  from its Start menu, since a restored lock can drop the stop request (the container
  does not restart by itself: `omarchy-windows-vm` sets `restart: "no"`)); verified
  Omarchy and dockur versions; the remaining risks from req 5a
  (including the disk-size check skipped when the compose is unreadable); the clipboard
  exposure (req 29); the publisher trust exposure: setup adds HostFission's signing
  certificate to the machine's Trusted Publishers, so Windows then accepts any
  driver HostFission signs without asking; the DNS-client note (req 24); the measured
  reboot shutdown time (req 19: phase 8 measures it; proof 4's reboots took 7 s and its logouts 11 to 13 s
  for an idle Windows); the coexistence note (req 30); the Windows lock (req 7): it is
  off for the Windows user who ran setup, and two of the settings (Switch user, the
  inactivity limit) apply to every account on that Windows; why; what that exposes:
  dockur already signs in automatically at every boot, RDP and the web console at
  `127.0.0.1:8006` both ask for the Windows password (`omarchy-windows-vm` sets
  `PROTECT: "Y"`), and any process running as the user can read the stored password,
  which does not change; what changes: Windows no longer locks itself or on request, so
  an unattended, unlocked Linux session leaves Windows open for as long as the VM runs,
  and the user has to lock Linux to cover it; that setup replaced any lock settings the
  user had, and that the restore steps bring back Windows' defaults, not those settings;
  that turning the lock back on, or a domain or MDM lock policy, brings back the forced
  stop, as can any Windows security screen left open (such as a UAC prompt); and how to
  turn the lock back on.

### Amendment: the panel view (John, 2026-10-05)

Why: four Opus rounds and two Codex rounds of the phase 7 diff gate each found new
should-fix bugs in the same place: `LanaiModel.qml` and `LanaiPanel.qml` decide what
to tell the user by merging cached setup replies, the job file and status reads,
about 400 lines of QML with no test in the repo. Each fix added conditions, and the
next round found a new clash. This amendment moves every decision into bash, where
bats tests can cover it, and makes the QML a renderer.

- `lanai panel` (new, `lib/panel.sh`) prints one JSON object, the view. It reads, in
  one call and with no side effects: what `lanai status` computes (`status_facts`
  and `status_map`), `setup.json`, `setup-reply.json`, the panel job file
  (`panel-job.json`, from `lib/ui.sh`) and `last-run`. It fits the 10 s deadline (the
  same QMP budget as status). The view holds:
  - `label`, `headline`, `cause`, `next`: the state in plain words, why, and the
    next step, written for a user who is not an engineer (no CLI text, no internal
    codes);
  - `notice`, `warning`: the forced-stop notice and status warnings, plain text;
  - `busy`: whether a job runs, and the one line to show while it does
    (click-started jobs and automatic waits get different lines);
  - `buttons`: for every control the panel has (start, open, stop, force stop,
    dismiss notice, continue setup, install in a terminal, take snapshot, skip
    snapshot, the two display choices, send answers, finish restore, take or list or
    restore snapshots, save settings), `show` and `enable`, plus the label where it
    varies;
  - `setup`: whether the section shows, `finished`, the current step, the lines to
    show, and the step 6 questions or the step 5 display choices when they apply;
  - `result`: the last action's outcome to show beside the control that ran it,
    rewritten for the panel (a successful restore reads "Restore finished. Windows
    now matches the snapshot.");
  - `auto`: true only when the panel should call `lanai setup` by itself now (the
    "For phase 7" rule: after an ok:true wait reply, by step and status, never by
    text, never after a failure, not while a job runs).
- Every panel action leaves a record. The panel runs every command, direct or
  detached, through `lib/ui.sh`: direct ones (`start`, `stop`, `open`,
  `notice-seen`, `settings`) through a new `lanai ui-run <token> <command...>`,
  which runs the command and saves its reply; detached ones (`setup`, `snapshot`,
  `restore`) through `lanai ui-job` as now. Both write one record, `panel-job.json`:
  the token, the command, its arguments, when it started and ended, and the reply.
  `lanai panel` reads that record for `result`, so a failed Shut down shows beside
  Shut down even when nothing else changed.
- Freshness has two rules, both in `lanai panel`:
  - What to show: status, computed in the same call, always wins. The last setup
    reply's lines show only while they still describe the current state (its step
    agrees with status and `setup.json`); otherwise the setup lines come from status
    and `setup.json` alone.
  - When to continue by itself (`auto`): only after an ok:true wait reply for step 5
    or 6, and only for that reply's expected next state: step 5's reply allows one
    call once the unit is inactive (Windows shut down, as setup.cmd does); step 6's
    reply allows one call while the unit is active. Never after a failure, never
    while a job runs, never when a panel action started after that reply, never by
    text. A test covers the step 5 active-to-inactive transition.
- The QML keeps exactly two values of its own, and passes both to `lanai panel`: the
  token of a launch it started and when (`--pending <token> <epoch>`), and whether
  automatic progress is paused (`--paused`). If no record with that token appears
  within 10 s, the view reports the launch as failed (with the job log path), and
  `auto` stays false. The QML sets paused after a failed or timed-out launch and
  clears it on the user's next click. It caches nothing else about setup or jobs.
- The QML (`LanaiModel.qml`, `LanaiPanel.qml`, `Widget.qml`) polls `lanai panel`
  (2 s while the panel is open or a job or boot is in flight, 15 s otherwise; a 10 s
  deadline; a tick is skipped while a call runs, and an action asks for exactly one
  fresh call after it ends). It renders the view's fields as plain text
  (`Text.PlainText`), shows and enables controls from `buttons`, and runs commands
  only through the existing paths (`lanai start|stop|open|notice-seen|settings`
  directly; `setup`, `snapshot`, `restore` detached through `ui-job`). When `auto`
  is true it launches `lanai setup` detached once and waits for the next view.
  `SetupCalls.js` goes away; its rule lives in bash.
- The widget's tooltip and the panel use the same `label`, `headline` and `next`.
- Tests: bats tests for `lanai panel` over fixture status replies, setup.json,
  setup-reply.json, job files and last-run, covering every state `status_map` can
  return, every setup step (including step 5 during and after the setup boot, step
  6 waiting, questions, display choices, a back-to-step-5 failure), job running and
  interrupted, a pending restore (stopped, setup-needed, in-use), a restore success
  and failure, the forced-stop notice, a stale reply that status contradicts, and
  `auto` true only in its allowed cases. The open phase 7 findings (gate rounds
  b 1-4, a 4) become test cases where they concern a decision. QML stays small enough
  to read in one sitting; `qmllint` must pass.

### As built (2026-10-04)

- `Widget.qml` follows the shell's BarWidget/BarIconButton contract and forwards
  open/close/opened/popout switching to `LanaiPanel.qml`. An L-in-a-monitor glyph identifies
  Lanai; primary click starts or opens, secondary click opens the panel. All status
  text, causes, next steps, warnings and logs use plain text. The heading and tooltip
  share readable state labels; section headings and setup guidance use plain language.
  Status `window: true` hides Open and routes the primary click to the panel during
  a QEMU setup boot. The bar widget owns the popout so the shell's open-panel dot
  follows it. The mismatch label reads "Display driver needs an update".
  The tooltip includes notices and warnings. Failed glyph starts/opens and starts
  that report a forced previous run open the panel. Force-stop guidance names the
  button below in the panel and points to the panel from the tooltip.
- `LanaiModel.qml` owns status polling (2 s with the panel open or while starting or
  stopping, 15 s otherwise) and literal-argv Processes with a hard 10 s deadline.
  Opening the panel reads settings through a separate Process, including while a
  user action is running. Read failures appear under Settings. Reads update sizing,
  settings readiness and their own reply; user
  actions and job results own `actionReply`, so reopening preserves snapshot and
  restore results, guidance and failures. Settings saves remain user actions.
  Opening the panel resets unsaved field edits to the model's settings. Routine
  polls and panel opening skip an in-flight status read. Only a refresh after an
  action or finished job discards that older result and reads again, so start,
  stop and notice dismissal keep their merged state until the fresh result.
  `LanaiPanel.qml` uses KeyboardPanel, Button, NumberField, PanelSectionHeader,
  PanelSeparator and the shell's theme tokens. Tab/Shift+Tab and Enter/Space reach
  its controls; Escape dismisses it. Force stop appears only for status's
  `force_stop: true` while stopping, with a second confirmation and cancel.
  Disabled buttons dim. Shut down stays available while starting and stopping;
  the CLI retains the first request's time.
- Setup runs only through detached `lanai setup`. Replies are read from
  `$XDG_STATE_HOME/lanai/setup-reply.json` only after the corresponding job finishes,
  and successful replies must agree with that job's CLI reply. Failed setup jobs
  show their own reply directly. A stale file cannot authorize a call.
  On attach, finished jobs are ignored unless they match this panel's pending launch;
  running jobs remain watched. Failed polls also enforce the 10 s launch deadline;
  a launch timeout pauses automatic progress until a click, even with a previous
  successful wait reply.
  Its error is separate from polling errors and survives successful polls until
  the next launch. Paused guidance asks for Continue setup instead of promising
  automatic checks. Continue setup stays enabled during automatic waits; launch
  still refuses overlapping work.
  `SetupCalls.js` decides automatic progress without matching English: any
  successful step 5 reply requires an inactive setup-needed status; a successful
  step 6 reply without questions requires an active VM. Automatic calls are
  at least 10 s apart across monitors, including after a display choice. Failures
  and display choices themselves require a click. Automatic wait jobs show steady
  guidance and leave unrelated controls enabled; click-started jobs show Working.
  Job status is polled only with the panel open or a pending/active job, and poll
  failures have their own reply rather than replacing action results.
  Status gates Open, display choices and the two final questions. The UI shows the
  seven steps while setup is underway, then "Setup is finished" and Run setup again.
  A successful step 7 reply shows completion immediately. A successful status
  read begun after that reply clears the cached completion if `setup_done` is
  false; an older read or failed read cannot clear it. After a shell restart,
  completion requires status's `setup_done: true`; an empty reply asks the user to
  click Continue setup to see where setup stands.
  A missing install asks for installation first. During setup boots the top guidance
  points to Setup; a stopped step 6 wait asks to start Windows again.
  Panel instructions refer to its buttons. A stopped setup boot takes precedence
  over a stale step 5 reply; only a successful active setup boot shows the setup-drive
  instruction. A failed step 5 check asks for shutdown and another pass. Snapshot
  success appears at step 3 with its path and deletion guidance, followed by Continue
  setup. Its snapshot choices disappear after success; the generic Continue setup
  is hidden there until success. Snapshot and restore jobs show progress notes in
  Snapshots and step 3. Empty snapshot lists say "No snapshots yet." The panel uses
  restore buttons and file-manager deletion guidance instead of CLI instructions.
  Action replies appear under VM controls, Settings or Snapshots as appropriate.
  Display choices hide Continue setup; the shutdown retry note requires an active
  VM. The active step 5 setup-drive note replaces the reply and automatic-wait
  text, and hides during the next setup job. Ordinary start/open/stop/dismiss
  successes add no reply text, except a start without a network. Next-step hints
  name panel controls, and settings success says only "Saved." Help excludes the
  expected package/snapshot offers and names service and panel-job logs. Snapshot
  and restore completion refreshes the list without replacing the action reply;
  counts read "1 snapshot" or "N snapshots".
  The panel shows the detached operation log;
  the existing backend emits no incremental build/download progress percentages.
- Small backend additions in `lib/ui.sh` (sourced by `lib/lanai.sh`): `lanai settings`
  reads/writes memory and cores, using vm_args' exact integer syntax and ranges,
  preserving storage and other keys, under the operation lock with atomic writes.
  `lanai ui-job` serializes detached setup/snapshot/restore across monitors and
  publishes an atomic `panel-job.json`; `lanai ui-job-status` detects an interrupted
  worker from its lock, rereading the marker under that lock so a just-finished job
  keeps its real reply. The log retains only the last run. `lanai notice-seen`
  takes the operation lock, replies busy on contention, and atomically sets
  last-run to clean; the forced-stop notice's Dismiss button calls
  it with literal argv. Status includes `setup_done` and `restore_pending`. An
  unfinished restore blocks Start, shows guidance at the top, and offers Finish the
  unfinished restore outside in-use. Stopped and setup-needed status explain that
  an unfinished restore prevents starting Windows; the panel adds just the button
  hint. Setup flags use jq's `--`
  separator and reach the CLI literally.
  These additions make detached completion and settings writes reviewable and
  testable without shell interpolation in QML. They are the
  backend scope additions; snapshots and restores still use phase 4's commands.
  Snapshot results outside setup retain their location/delete guidance. Restore needs a second
  click; interrupted restore can resume. Failed restores point to Finish the
  unfinished restore only when status reports `restore_pending: true`, including
  interrupted jobs. A refusal with no pending restore keeps its cause and message
  without recovery button guidance. Restoring requires running setup again.
- README documents installation, dependencies, RDP-only Windows removal after
  shutting Lanai's VM down, and literal registry restoration commands,
  guest components/service/task removal or reasons
  to keep them, publisher/lock/clipboard exposures, DNS, coexistence, remaining
  dockur risks, host key handling, read-only media and pending measurements.
- Departures/deferred checks: at John's explicit instruction the two hands-on checks
  (resize drag and scale timing) were not run: they require a person and a running
  Windows test copy. No client flags changed. The proof records do not name an exact
  Omarchy version, so README marks that as a phase 8 release item; 4.0.0.alpha is the
  installed API reference only. The four marketplace Windows plugins are not
  installed here, so the icon uses a custom L-in-a-monitor mark rather than a stock
  monitor or Windows-logo glyph. Final reboot timing and spike
  measurements remain explicit placeholders, not inferred results.
- Validation: `test/ui.bats` was written before implementation and exercises settings
  bounds, preservation/refusal, literal detached arguments, failures, concurrent
  jobs, interrupted jobs and the one-JSON CLI contract. All 21 tests pass, including
  notice dismissal under contention, unfinished-restore guidance, snapshot count
  wording, status's `setup_done` and SetupCalls' successful-wait rules. The setup flag test
  reproduced the missing field before the backend change. The SetupCalls test runs
  the real functions with Node and skips cleanly if that runtime is unavailable.
  The 12 socket-free `status_map` tests in touched `test/lifecycle.bats` also pass,
  including the panel's Force stop hint. Other lifecycle tests were not run because
  this sandbox blocks Unix sockets. All scratch stayed under `.btrfs-test/`.
  `/usr/bin/qmllint` passes `LanaiPanel.qml`, `LanaiModel.qml` and `Widget.qml` with
  the shell import path. The complete project shellcheck command passes.
  A temporary source-based harness passes 12 checks for status refresh races,
  setup completion, restore blocking and snapshot copy. A standalone Qt 6 test
  verifies that reopening resets both settings fields and restores their bindings.
  Follow-up fixes pass 17 checks in a temporary Qt 6 harness loading the real
  model with inert Process/FileView stubs and the panel's completion binding and
  guidance functions: slow polls accept replies, actions discard older reads,
  later status clears cached step 7 completion, and restore failure guidance
  follows `restore_pending`. `test/ui.bats` passes with its Node check skipped
  because Node is unavailable; all 12 socket-free `status_map` tests pass.
  QML lint with the shell import path and the complete shellcheck command pass.
  The follow-up harness and all scratch were removed from `.btrfs-test/`.
  Both harnesses were removed after validation.
  A further temporary harness passes 11 behavioral checks for glyph feedback,
  persistent launch timeouts, paused and active setup copy, automatic waits,
  display choices, Help, completion, action hints and snapshot-list refreshes.
  It was removed after validation.
  Earlier temporary harnesses verified launch timeouts and settings reads during
  actions. No VM, shell, real units, plugin installation or review stage ran.

## Phase 8: Acceptance

- Memory: before the rehearsal, the first Lanai boot on John's machine, set memory to
  12 GiB in Lanai's settings (shared by the rehearsal and the live install): the proof
  sessions ran dockur's 16 GiB and caused memory pressure on his 32 GiB machine (proof
  5). John kept the default as it is (2026-10-04): 12 GiB is his setting.
- **Rehearsal on a copy** (agent or John): point Lanai's storage at a fresh
  `lanai-copy` and run every spec acceptance row that does not start the container.
- **Test install** (rows 3, 4, 30-32): a separate machine or VM running Omarchy with
  `omarchy-windows-vm` and a copy of a Windows install. John picks the machine.
- **Live install** (John only, after the rehearsal passes).
- Client timing check (phase 5 review): open the client right at `lanai start` and
  note whether the guest agent's port opens before the IDD first reports. If it does,
  status shows a brief false "IDD missing" (failed) until the IDD answers; record how
  long, and take it to John if it is more than a poll or two.
- Disconnected session (proof 5, `tsdiscon`): it leaves Windows at a sign-in screen
  that `lanai-lock.cmd` does not prevent; proof 5 signed back in from QEMU's screen,
  which a normal boot does not have. Run `tsdiscon` and record whether the sign-in
  screen shows in the Looking Glass window (if not, the README needs a recovery
  route). Then Shut down from the bar, and record whether Windows shuts down or needs
  the forced stop. If it needs the forced stop, the README names it among the likely
  causes.
- Setup display buttons (QML, phase 6): after a step 5 boot stopped from the panel,
  the two buttons appear, and each starts step 5 again with the chosen display; after
  a step 5 boot that `setup.cmd` finished, setup goes on to step 6 and shows neither.
- Client closes (proof 5): the Looking Glass window closed on its own several times
  while QEMU kept running. Record each unexpected close during acceptance with the
  time and the last lines of `client.log`, and take a repeat to John.
- Checklist for rows 10-17 and 20, recorded in `docs/plugin/acceptance.md`:

| Row | Check |
|---|---|
| 10 | Each state appears with its text, cause and next step: not installed (empty storage copy), setup needed, stopped, starting, running, stopping, in use by `omarchy-windows-vm` (test install), version mismatch (older client build), failed (kill QEMU) |
| 11 | Start, open and shut down from the bar and panel; panel actions by keyboard |
| 12 | Tile, fullscreen, resize; desktop follows; scale matrix through `scale_step` tests plus two real host scales |
| 13 | Typing, mouse, clipboard text both ways, a file both ways, a system sound; a file copied in Windows appears on the host in the Looking Glass client's read-only FUSE folder under `/run/user/<uid>/` (the spike saw `looking-glass-clipboard-*`, `ro,nodev,nosuid,noexec`), checked with `findmnt` (spec req 29) |
| 14 | Sign-in with the user's password (dockur signs in automatically, so first sign out from Start, as proof 4 did); `grep` for a sentinel password in Lanai's files and logs finds nothing |
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
| plan amendment (proof findings) | a | 1 (delta, heavy) | 0 blockers, 9 should-fix, 6 nits; all confirmed and integrated (Switch user; a lock proof with positive controls that runs the real `lanai-lock.cmd`; SID check; no before-file, the README restores defaults; `C:\Lanai` ACL; literal service commands, no restarts; client wait in a unit wrapper; README lists every Windows change; scale-timing check). Heavy round: one more full round follows |
| plan amendment (proof findings) | a | 2 (full) | 0 blockers, 8 should-fix, 7 nits; 14 integrated. Item 7 (turn off wake and Dynamic Lock too) resolved by the spec's round 2 wording (they must be unable to trigger, and the lock proof confirms it). Also folded in the spec's round 2 changes: README exposure text corrected (`PROTECT: "Y"`), removal restores the lock inside Windows first, domain/MDM warning, forced-stop notice names likely causes |
| plan amendment (proof findings) | a | 3 (delta) | 0 blockers, 5 should-fix, 8 nits; all confirmed and integrated (lock proof keeps setup's end state; VirtioFsSvc stop waits and handles a missing service; send-key holds the connection; README matches spec reqs 7 and 32; absent-value handling in `lanai-lock.cmd`; `C:\Lanai` junction guard; MDM enrollment check; rewraps) |
| plan amendment (proof findings) | a | 4 (delta, cap) | 0 blockers, 2 should-fix, 5 nits; all integrated (send-key in a fenced block; `net stop` result ignored, a failed copy stops setup; `C:\Program Files\Lanai` created; empty-folder check after the ACL; lock values handed back in variables; removal undoes every Windows change before the shutdown; rewraps). Stage a closed |
| plan amendment (proof findings) | b Grok (substitute) | 1 (full) | Codex out of credits. 7 P2, 2 P3; all confirmed and integrated (`call` for `lanai-lock.cmd`; IDD installed last because it blanks the setup display, so no pause or printed values; `C:\Lanai` without recursive deletes; `dir` judged by output; client wrapper closes QMP before exec, per-try timeouts; `qga_reply` refusal mode; literal README restore commands; lock proof sign-in between controls; stop on any sleep state or Bluetooth; resize check names its VM). README exposure text matches the spec's Grok round |
| plan amendment (proof findings) | b Grok (substitute) | 2 (full) | 5 P2, 1 P3; all confirmed and integrated (lock proof runs through the Looking Glass client, and `proof-vm client` waits for a QMP reply; scale timing tested at the late attach a user makes, plus a fast trial; step 6 checks the refusal with an argument-free `guest-exec`, as proof 3 recorded; `lanai-lock.cmd` never relaunches and exits with `exit /b`; the refusal test runs on a pre-setup copy and checks every guest change; the client wrapper's QMP handshake named). Also matched the forced-stop notice to spec round 2 |
| plan amendment (proof findings) | b Grok (substitute) | 3 (full, cap) | 2 P2, 2 P3; all confirmed and integrated (the kit's client waits on `qmp.sock` and disconnects before exec, so send-key can use it; the refusal test boots with the setup media, signs out of auto sign-in and compares an inventory, matching spec row 7b; a runnable `journalctl -I` command; a step for the domain/MDM warning). Stage closed at the cap |
| diff (phase 4) | a | 1 (panel: correctness, security, reliability, testing, maintainability) | 1 blocker (restore not tied to its storage location, could delete unrelated files), 29 should-fix, about 23 nits; all integrated. Heavy round: one more full round |
| diff (phase 4) | a | 2 (full, 3 reviewers) | 1 blocker (CI hang: a zombie under the job container's non-reaping PID 1), 9 should-fix, 12 nits; all integrated. CI green after `--init` and per-test timeouts |
| diff (phase 4) | a | 3 (delta) | 1 should-fix (a forged logind signal inside a string argument), 2 nits; integrated: logind's own property confirms before acting |
| diff (phase 4) | a | 4 (delta) | clean; logind ordering checked against systemd v262 source. 2 nits taken (5 s busctl timeout, sleep-check comment). Stage a closed |
| diff (phase 4) | b Grok (substitute), part A (lifecycle, about 3,300 lines) | 1 (full) | no findings |
| diff (phase 4) | b Grok (substitute), part B (snapshot and restore) | 1 (full) | 2 P2, 1 P3; all confirmed and integrated (restore marks before recreating a deleted disk; snapshots flushed before success; layout check before snapshot) |
| diff (phase 4) | b Grok (substitute), part B | 2 (full) | 1 P2; integrated (restore holds the disk lock while it hashes the snapshot) |
| diff (phase 4) | b Grok (substitute), part B | 3 (full, cap) | 1 P2, 1 P3; integrated by Claude, test-first (sync -f after a snapshot, since XFS does not flush clones on fsync of other files; cp errors shown). Not re-reviewed: at the cap |
| diff (phase 5) | a | 1 (panel: correctness+reliability, security+supply chain, testing+maintainability) | 0 blockers, 6 should-fix, about 12 nits; all integrated. Heavy round: one more full round |
| diff (phase 5) | a | 2 (full, 2 reviewers) | 0 blockers, 3 should-fix, 8 nits; all integrated |
| diff (phase 5) | a | 3 (delta) | clean; 3 nits, 2 taken by Claude test-first (a missing pacman counts all missing; no empty install command). Stage a closed |
| diff (phase 5) | b Grok (substitute) | 1 (full) | 1 P2 (VM stop returned before the client unit left, so a quick Start then Open could focus the old window), 1 P3 (setup-host claimed a terminal opened); both integrated |
| diff (phase 5) | b Grok (substitute) | 2 (full) | no findings (reboot timing budget weighed). Gate closed |
| plan amendment (proof 5) | a Grok (substitute) (grok-4.6) | 1 (full) | Codex out of credits. 2 P2, 2 P3; all confirmed and integrated (the guest version record is per user, not per disk, so a stale record falls back to QEMU's window once the agent answers and the IDD is missing; row 7b's kit boot adds `--window`; the device table names `boot.json`, not a guest fact; 12 GiB before the live boot) |
| plan amendment (proof 5) | a Grok (substitute) (grok-4.6) | 2 (full) | 1 P2, 1 P3; both confirmed and integrated (an absent IDD needs 60 s of an open agent port with no guest session, since the agent can answer first; `setup-guest` waits for the unit itself, since `lanai stop` returns at once) |
| plan amendment (proof 5) | a Grok (substitute) (grok-4.6) | 3 (full, cap) | 2 P2, 1 P3; all confirmed and integrated (the absent-IDD test matches `version_check`'s 30 s `waiting` phase; the fallback stop writes `stop-requested`, so the panel's forced stop is offered; test knobs for the new waits). Stage closed at the cap |
| plan amendment (proof 5) | b single (opus-5.5) | 1 (full) | 6 should-fix, 6 nits; all confirmed. Seven (the self-lock on a second `boot_vm`, a closed client read as a missing IDD, outcomes with no screen, "one fallback", how a long watch runs, the stop wait, a redundant check) came from the automatic fallback, so Claude replaced it with a manual override: `setup-guest --window` behind a panel prompt. Also integrated: setup state follows the disk (`setup_done` checks the storage location; restore clears `done`); `WAYLAND_DISPLAY` for the window boot; the kit keeps `--setup`; the two-screen fix is verified on the proof copy; row 7b records `EnableLUA` |
| plan amendment (proof 5) | b single (opus-5.5) | 2 (full) | 5 should-fix, 8 nits; all confirmed. Integrated: one `setup_reset` for a storage change and every restore; the override works both ways (`--window` removes the record, `--no-window`), as two panel buttons after Shut down; step 5 ignores a panel Shut down or forced stop, and records the pin only then; `WAYLAND_DISPLAY` travels in `boot.json`; row 7b turns UAC on for the test if it is off; Open hidden during a window boot; definitions and fixtures follow the storage location; a `tsdiscon` check in phase 8. Not taken: showing the buttons only on a detected wrong guess (simpler to always show them). Taken to John: spec row 7's "one administrator prompt" when UAC is off, and whether 16 GiB stays the default on a 32 GiB host |
| plan amendment (proof 5) | b single (opus-5.5) | 3 (full, cap) | 4 should-fix, 6 nits; all confirmed and integrated by Claude, not re-reviewed: at the cap. The display buttons wait for an inactive unit (status reads `setup-needed`, never `stopped`, during setup); step 5's verdict and the pin record move into `record_previous_run`, which phase 5's "when `setup-guest` succeeds" now means; step 5 keeps the record it replaces, and step 6 puts it back on an IDD failure; status reports `window: true` and `lanai open` refuses during a window boot, with phase 7's panel and README pointing here; `setup_reset` runs after `layout_check`, under the lock, and on a missing location; restore's next step is setup; the Win+P check dropped; 12 GiB before the rehearsal |
| plan amendment (proof 5) | b single (opus-5.5) | 4 (full, John's extra round) | 3 should-fix, 6 nits; all confirmed and integrated. The display buttons come from `lanai setup`'s resume reply, with `active` in status (an active VM also reads `setup-needed`); pin bumps go through `lanai setup`, and step 6's pinned client records the pin from its own log, which removes round 3's kept record and its put-back; `setup_reset` runs `record_previous_run` first and only where the lock is already held; `setup.json` keys named; step 6 reopens a closed client; proofs.md's UAC line scoped; `tsdiscon` and the QML buttons checked in phase 8. Not re-reviewed: John closed the gate on 2026-10-01 |
| diff (phase 6) | a Grok (substitute) (grok-4.6) | 1 (full) | Codex out of credits. 2 P2, 0 refuted, 0 downgraded to nit; both confirmed and integrated (a declined administrator prompt exited 0; an IDD failure still paused in stage 1). Before the gate, Claude also took the implementer's own finding: `C:\Lanai` is made anew every run, since `/inheritance:r` keeps a planted explicit ACE |
| diff (phase 6) | a Grok (substitute) (grok-4.6) | 2 (full) | 1 P2, 0 refuted, 0 downgraded to nit; confirmed and integrated (the step 7 shortcut fired during an open round on an install already set up; `setup.json` now holds `round` until step 7) |
| diff (phase 6) | a Grok (substitute) (grok-4.6) | 3 (full, cap) | 1 P2, 0 refuted, 0 downgraded to nit; confirmed and integrated (step 6 called the IDD missing before Windows had booted; `idd-missing` now counts only once the guest agent's port has been open for `LANAI_SETUP_GRACE`). Stage closed at the cap |
| diff (phase 6) | b panel (opus-5.5): correctness+reliability, security, testing, architecture+maintainability | 1 (full) | 11 should-fix, 19 nits, 0 refuted, 0 downgraded to nit; 30 integrated, 4 maintainability nits not taken (setup-boot rules out of `boot_vm`, `setup_done` into setup.sh, other duplicates, a re-entrant `lanai_flock`). Security: the scale script moves under `C:\Program Files\Lanai` (a `mkdir`/`icacls` race let a standard account swap it), VirtioFsSvc's path is quoted, setup refuses the system drive. Step 6 times every grace from a per-boot agent stamp with a 300 s limit; `--window`/`--no-window` always restart step 5; a structural test pins every Windows change's exit check; `setup-reply.json` for phase 7 |
| diff (phase 6) | a (gpt-6.1-sol) | 4 (full; John approved a round past the cap, Codex back) | 4 P2, 0 refuted, 0 downgraded to nit; all confirmed and integrated (fixes by Codex): the boot limit timed a missing client start line as expired and ignored a Windows restart, now timed from `$RUN/qga-closed-since`; `--window`/`--no-window` bypass the step 7 shortcut; each setup call writes its reply through its own temporary file |
| diff (phase 6) | a (gpt-6.1-sol) | 5 (full) | 2 P2, 0 refuted, 0 downgraded to nit; both confirmed and integrated (fixes by Codex): `--window` no longer removes the guest version record (it could be lost when QEMU failed after the unit started); step 6's boot rechecks setup state under the boot lock, so a restore in between refuses the boot |
| diff (phase 6) | a (gpt-6.1-sol) | 6 (full) | 1 P2, 0 refuted, 0 downgraded to nit; confirmed and integrated (fix by Codex): a storage change during the media build let a setup boot reach a disk with no snapshot decision; a setup boot now refuses unless `setup.json` holds this location's decision |
| diff (phase 6) | a (gpt-6.1-sol) | 7 (full) | clean: no findings, 0 refuted, 0 downgraded to nit. Stage a clean on 45bfebb; stage b round 2 (a panel) is next |
| diff (phase 6) | b panel (opus-5.5): correctness+reliability, security, testing, architecture+maintainability | 2 (full) | 9 should-fix, 21 nits, 0 refuted, 0 downgraded to nit; 26 integrated (fixes by Codex), 4 maintainability nits not taken (inline `log_client_start`, one `--window` parser, the Windows-restart cadence note beyond the phase 7 contract, the `dl-ignore` test). Two findings conflicted (keep vs test the `step5` removal on an explicit choice); resolved by setting `step5` to false. Security: setup runs only from a drive it cannot write to |
| diff (phase 6) | a (gpt-6.1-sol) | 8 (full, the rerun on the final diff) | 1 P1, 2 P2, 0 refuted, 0 downgraded to nit; all confirmed and integrated (fixes by Codex): a fixed write-probe name let a planted file pass a writable copy; a failed step 6 start stuck as "did not start"; an ordinary start skipped `setup_done` under the lock. Above nit, so stage b runs again, then stage a |
| diff (phase 6) | b single (opus-5.5) | 3 (full, cap; single by John's call to save Claude usage, where the mode rule picks a panel) | 2 should-fix, 5 nits, 0 refuted, 0 downgraded to nit; all integrated (fixes by Codex): step 6 could reopen a dying client forever and wait unbounded on `unknown`/`waiting`; the phase 7 auto-call rule looped failed boots. Claude caught that Codex's fix failed a freshly reopened client and limited the failure to a client that is not running. Stage closed at the cap |
| diff (phase 6) | a (gpt-6.1-sol) | 9 (full, the rerun on the final diff) | 1 P2, 0 refuted, 1 downgraded to nit: a copied folder whose ACL denies the administrator file creation but lets another account modify files passes the write probe. Downgraded: an account that can set that ACL controls the folder, so it can already rewrite `setup.cmd` itself, which no check inside the script can stop; the comment scopes the probe to that limit, and the README sends users to the read-only setup drive. A disk read-only check (`Get-Disk` `IsReadOnly`) is a candidate for the hands-on Windows run. Nits only, so no further rerun. Gate closed |
| diff (phase 7) | a (gpt-6.1-sol) | 1 (full) | 1 P1, 4 P2, 1 P3, 0 refuted, 0 downgraded to nit; all confirmed and integrated (fixes by Codex): jq read the panel's setup options as its own; Shut down was disabled while stopping; a finished job could replay and boot Windows unasked; a completion race read as interrupted; a failed launch kept the panel busy; raw state codes shown to users. Claude's own copy notes went in with them |
| diff (phase 7) | a (gpt-6.1-sol) | 2 (full) | 2 P2, 0 refuted, 0 downgraded to nit; both confirmed and integrated (fixes by Codex): a failed launch let the panel relaunch setup without a click; the README's removal could cut off its own screen or input inside Lanai's window, so removal runs over RDP |
| diff (phase 7) | a (gpt-6.1-sol) | 3 (full, cap) | 2 P2, 0 refuted, 0 downgraded to nit; both confirmed (reproduced against the model) and integrated (fixes by Codex): a settings read hid a finished operation's result, and was dropped during another action. Stage closed at the cap; stage b reviews the fixes |
| diff (phase 7) | b single (opus-5.5) | 1 (full; single by John's Claude-usage rule, where the mode rule picks a panel) | 13 should-fix, 8 nits, 0 refuted, 0 downgraded to nit; all integrated (fixes by Codex). Correctness: step 5 auto-advance keyed on English and stalled after a Windows-window setup boot; the setup.cmd note showed without a setup drive; the forced-stop notice was never cleared (new `lanai notice-seen`). UX: CLI hints shown to users, a Setup section that never closed, results far from their buttons, a restore button with nothing to restore (new `restore_pending` in status), step 6 flicker, popout owner for the shell's open-panel dot, rewritten copy |
| diff (phase 7) | b single (opus-5.5) | 2 (full) | 10 should-fix, 10 nits, 0 refuted, 0 downgraded to nit; all integrated (fixes by Codex). It reversed round 1's "disable Shut down while starting", which left no way to stop a boot whose agent never answers. Others: invisible disabled state, no progress for long jobs, a wrong "Setup is finished" (new `setup_done` in status), stale status overwriting an action, unfinished restore not blocking Start, copy rewrites; the SetupCalls safety test now runs in CI (nodejs) |
| diff (phase 7) | b single (opus-5.5) | 3 (full, cap) | 8 should-fix, 8 nits, 0 refuted, 0 downgraded to nit; all integrated (fixes by Codex): silent glyph failures and missing tooltip notices; a false "start Windows" with a restore pending; a lost launch-timeout error; Help during normal setup steps; repeated and flashing setup notes; CLI hints in results; a README snapshot-deletion contradiction; `notice-seen` without the lock. Stage closed at the cap; John approved the stage a rerun on the final diff |
| diff (phase 7) | a (gpt-6.1-sol) | 4 (full, the rerun on the final diff, approved by John) | 3 P2, 0 refuted, 0 downgraded to nit; all confirmed (one reproduced headless) and integrated (fixes by Codex): routine polls discarded every slow status read; a cached step 7 reply outlived a restore; restore failure advice ignored `restore_pending`. Above nit, so stage b and stage a run again; stage b is at its cap, so John decides |
| diff (phase 7) | b single (opus-5.5) | 4 (full, John's extra round) | 6 should-fix, 4 nits, 0 refuted, 0 downgraded to nit; all confirmed, none integrated: the step 5 note during step 6's boot, guidance from status read before the newest reply, a successful restore saying "try again", contradictory unfinished-restore hints, "Setup is finished" over a driver update, no checked-in test for the model. Claude diagnosed the pattern (every round finds new clashes in the QML's decisions) and John chose to move every decision into bash (`lanai panel`, amendment above); the round's findings become its test cases |
| plan amendment (panel view) | a (gpt-6.1-sol) | 1 (full) | 3 P2; all confirmed and integrated: direct action results had no record (every panel action now goes through `lib/ui.sh` and leaves one); the freshness rule would have rejected step 5's wait reply right when it must authorize the next call (separate rules for what to show and when to continue); a launch that never started was untracked (the QML keeps a pending token and a paused flag and passes them to `lanai panel`) |
