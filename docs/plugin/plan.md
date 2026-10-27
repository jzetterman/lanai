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
  `$XDG_DATA_HOME/lanai/runtime/<version>-<content-sha256>/`. The unit points
  there, so a plugin update or removal mid-run cannot break a clean stop (req 18, 32). A refresh rewrites the unit
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
  phase 6; superseded by step 6's own records, see "Follow-on: setup checks (John,
  2026-10-17)"), and a pid file per helper (`virtiofsd.pid`,
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
- `.github/workflows/test.yml`: `ubuntu-24.04`, `container: archlinux:latest`,
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
| `scale_target` (was `host_scale`) | the scale of the window's monitor, else the focused one, else the first listed, from `hyprctl monitors -j`; at `lanai start` and in the scale feed (one rule for both since the live-scale review) | 12 |
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
  restored or cleaned (`.partial` leftovers with SOURCE matching this location;
  unknown locations are left alone, and the flock means none is being built).
  A snapshot place is used, listed or resumed from only when it is a real folder owned by the user with no group or other write
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
  with `-f $RUN/ivshmem spice:host=$RUN/spice.sock spice:port=0 win:setGuestRes=yes
  wayland:warpSupport=no` (the last flag since 2026-10-23, from phase 7's resize check).
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
- Outside the client's capture mode, host keys never reach Windows (proof 5;
  capture is in `docs/plugin/client-warp/plan.md`): Hyprland takes Super
  shortcuts, and Omarchy's Ctrl+Alt+Del closes every host window. Setup and the
  README never ask the user to press either. Where Windows needs one, they give a click path inside Windows
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
| 6. Normal boot | each guest component is checked, not assumed: the pinned client, started directly, logs `match` (`version_check`, phase 5), and that log records the pin; the guest agent answers a sync and a `guest-set-time` to the current host time (the channel's allowed use, which also proves the clock path), and refuses an argument-free `guest-exec` with `CommandNotFound ... has been disabled`, the reply proof 3 recorded (the allow-list took effect; spec req 27; without arguments the command could not run anything even if the allow-list had failed); QMP `query-chardev` shows `frontend-open: true` for the SPICE agent's port (`vdagent`), as it does for the guest agent; the panel asks the user two one-click questions: does `~/Windows` show in Explorer, and does Windows' text look the right size (the scale task). Any missing component sends setup back to step 5 with "setup did not finish: run setup.cmd again"; `setup.cmd` is idempotent (each installer skips what is already installed at the pinned version). Tests cover a shutdown after a partly failed `setup.cmd`. Superseded: step 6 asks no question, and a part that does not answer stops at step 6; see "Follow-on: setup checks (John, 2026-10-17)" |
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
  That call stays at step 6 and does not reopen the client. (Superseded: the port
  timers are gone, and one deadline from the boot's start covers these checks; see
  "Follow-on: setup checks (John, 2026-10-17)".)

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
  (Superseded: the answer options are gone; see "Follow-on: setup checks (John,
  2026-10-17)".)
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
  A lone `--share-ok no` or `--scale-ok no` sends setup back too. (Superseded:
  step 6's limits and answers are in "Follow-on: setup checks (John, 2026-10-17)".)
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
  (Superseded: `questions` is gone, and step 6 time-outs carry `stop` and
  `parts`; see "Follow-on: setup checks (John, 2026-10-17)".)
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
    if nothing fixes it, add a README note. Ran on October 23, 2026, on John's install:
    `wayland:warpSupport=no` fixed it, and the later options were not needed
    (`docs/plugin/client-warp/plan.md`; `proofs.md`, "Resize drag (2026-10-23)").
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
  `omarchy-windows-vm` fallback. (Superseded: step 6 asks no question; see
  "Follow-on: setup checks (John, 2026-10-17)".)
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
to tell the user, and when to call setup again, by merging cached setup replies, the
job file and status reads, about 400 lines of QML with no test in the repo. This
amendment moves every decision into bash, where bats tests cover it, and makes the
QML a renderer. It supersedes, for the panel, the earlier phase 7 bullets and Phase
6's "For phase 7" contract where they tell the panel to read `setup-reply.json` or to
decide itself when to call setup again; the rest of that contract (setup runs
detached, at most every 10 s, never two at a time, never after a failure, never keyed
on text) still holds, now kept by the setup job.

**`lanai panel`** (new, `lib/panel.sh`) prints one JSON object, the view. Its only
write is the one `lanai status` already makes (`guest_version_note`); it acts on
nothing. Inputs, in one call: the shared facts (below) and `status_map`'s result,
`setup_plan`'s decision, the panel's group records, `last-run` (the forced-stop
notice comes only from `last-run`, never from `run_verdict`), `settings.json` and
the snapshot list. `setup-reply.json` stays for the CLI and is not an input; a test
pins that the view ignores it. The view holds:
- `label`, `headline`, `cause`, `next`: the state in plain words, why, and the next
  step, for a user who is not an engineer (no CLI text, no internal codes); the
  widget's tooltip uses the same fields;
- `notice`, `warning`: the forced-stop notice and status warnings, plain text;
- `busy`: whether a long job runs, and its one line (a click-started step, or the
  setup job following Windows' boot, get different lines);
- `buttons`: for every control (start, open, stop, force stop, dismiss notice,
  continue setup, install in a terminal, take snapshot, skip snapshot, the two
  display choices, send answers, finish restore, take and restore snapshots, save
  settings), `show` and `enable`, plus the label where it varies; the snapshot list
  comes with every view, so there is no list control;
- `setup`: whether the section shows, `finished`, the current step, its lines, the
  step 6 questions and the step 5 display choices when they apply; (superseded: no
  questions or answer controls, and at a step 6 time-out with Windows off, the two
  display buttons, which the time-out's words name; see "Follow-on: setup checks
  (John, 2026-10-17)")
- `result`: per control group, an outcome that the state cannot say by itself,
  shown beside its controls (below);
- `settings` (memory, cores, or the read error), `snapshots` (names, or the read
  error), `logs` (the VM and client log paths status names, and the panel's job and
  command logs).

**Panel words.** `lib/panel.sh` turns every reply into panel words from a table keyed
on the command, `ok`, `step` and the reply's detail keys, never on its English text.
Where one key has several causes that need different words, the CLI reply gains a
`reason` code: step 1's problems, setup's back-to-step-5 reasons, and the snapshot
offer when the filesystem cannot snapshot. The CLI's own message appears at most as a
details line. Snapshot results still say where the snapshot lives, that it grows, and
how to delete it, in panel words (spec 7).

**Shared facts.** One small gatherer reads the facts both status and setup need: the
container (running or preparing), the layout check, the unit's state and `Result`,
and restore pending. `status_facts` and `setup_resume` both call it; it makes no QMP
call and writes nothing. Its container check reads cgroup files with bash builtins
(no `grep` per /proc pid, which costs about 0.55 s of CPU per call on John's machine)
and is skipped while Lanai's unit is active (status ignores it then, and Lanai's
QEMU holds the disk lock); `setup_resume` skips it in the same case, so the two
agree.

**Setup's step comes from durable state.** `setup_resume` is split. A read-only
`setup_plan` decides the step and what it needs (an action such as a package install
or the snapshot offer, the step 5 display choices, a boot to wait for, step 6's
checks or its questions, done; superseded: step 6 has no questions, see "Follow-on:
setup checks (John, 2026-10-17)"). `setup_resume` becomes: lock, `record_previous_run`,
`setup_follow`, the shared facts, `setup_plan`, then act. Because the panel calls
`setup_plan` without the first two, `setup_plan` applies their pending effects to
what it reads, without writing:
- the ended run (only while the unit is inactive or failed, as in `setup_resume`):
  `record_previous_run`'s rule moves into a pure `run_verdict` over the run markers
  (`running`, `started`, `last-shutdown`, `forced`, `stop-requested`, `boot.json`),
  which both call; it reads `running` last (`record_previous_run` deletes it first),
  so a present `running` proves the other reads came before any deletion. It returns the verdict (clean,
  forced, nostart, or none) and whether it completes step 5 (a clean setup boot that
  no stop request asked for). The markers stay on disk until the next start consumes
  them, so the view sees the ended run before any command. `setup_plan` reads the
  markers before `setup.json` (`record_previous_run` writes `step5` before it
  deletes them), so a setup call in between cannot yield "step5 false, no markers";
- a changed storage location (`setup_follow`'s reset) and step 3's automatic
  "taken" when snapshots exist.
`finished` follows step 7's rule (setup done for this location, no open round,
`step5` not false, the guest not behind the pin, step 4's stamp current); step 1 and 2 problems show only
while setup is not finished, since the VM state already covers in-use and a pending
restore. Step 4 checks the pinned client by a stamp file inside its build folder
holding `LG_BUILD` (so a rebuild or `builds_prune` removes it with the binary), never
by running the binary; an existing install without the stamp takes one quick step 4,
in which `build_client`'s check writes it. Step 6's questions are durable:
`setup_step6` writes `$RUN/step6-asked` when it asks them; the QMP event logger, which
already records SHUTDOWN events, deletes it on any `RESET` event (a Windows restart);
`vm_exec` removes it at each start. `setup_plan` shows the questions while that file
exists and the plan is at step 6 (step5 true, the unit active, not a setup boot), so a
"no" answer that sends setup back to step 5 hides them. Step 6's other verdicts
(waiting, back to step 5) need QMP and the guest agent, so they come from the setup
job's own result, not from `setup_plan`. (Superseded: `step6-asked` is gone, and
`setup_plan`'s scale wait comes from `step6-checked`; see "Follow-on: setup checks
(John, 2026-10-17)".) A bats test pins that `setup_plan` and
`setup_resume` agree on the step, action and JSON reply reason for every fixture,
both with the markers still on disk (as the view sees them) and consumed (as setup sees them), including a panel
Shut down during the setup boot (a clean guest shutdown with a matching stop request
gives the display choices, and the setup job stops following).

**The setup job follows its own waits.** The panel never decides when to call setup
again. `ui-job setup` runs `lanai setup` with the click's arguments (a display choice,
answers, `--no-snapshot`); while the reply is an ok:true wait (step 5, or step 6 with
no questions; step 3a's and step 7's ok:true replies are not waits; superseded: every
ok:true step 6 reply is a wait, and there are no answers, see "Follow-on: setup checks
(John, 2026-10-17)"), the job checks
every 2 s for that wait's expected next state (an activating unit counts as active)
and then calls `lanai setup --follow <step> <invocation>` again, never repeating
the click's arguments (a repeated `--window` would start another setup boot):
- step 5: `run_verdict` says that run ended and completes step 5, and the unit is
  inactive or failed; if the run ended any other way (a panel Shut down, a forced
  stop), the job stops and the view offers the display choices;
- step 6: the unit is still active with the same invocation and no stop request for
  it; the next call comes 10 s after the last reply; if the unit stops or changes,
  the job stops.
The follow-up carries only its expected step and invocation. Setup revalidates
that expectation under its own operation lock, before bookkeeping or any action:
step 5 needs the same ended run completing step 5; step 6 needs the same active
invocation with no matching stop request. A changed expectation returns an inert
`follow_stopped` reply, so a stop between the worker probe and setup cannot boot
Windows again.
A busy reply from setup resume's own operation lock retries after two seconds,
keeping the last wait visible; setup rechecks the same expectation under its lock
on each retry. A busy reply from the later boot lock ends following, since the
resume may already have consumed the run markers.
It writes the setup group's record after every completed setup call and ends on any
reply that is not a wait, on any failure except this initial-lock contention, or when the
expected state does not come. So setup runs at most
every 10 s, never two at a time, never after a failure, keyed on step and state, and
it keeps going with the panel closed. Open, notice dismissal and settings saves do
not stop it; Shut down and Force stop end it through the expected-state check. The
job holds `panel-job.lock` while it follows, which only blocks snapshot and restore,
and those refuse while the VM runs anyway; the view disables the long-job controls
while the lock is held. `ui-job` starts through `systemd-run --user --collect` in
`session.slice`, as `client_start` does, so a shell restart or plugin reload does not
end it (spec 18). A client-mode setup boot starts its own client: `setup_command`
runs `client_start` with `build_select`'s build after it, as the step 6 boot starts
the pinned client, so no panel call is needed.

**Records.** The panel runs every command it offers through `lib/ui.sh`, never
directly. Through a new `lanai ui-run`, which the QML runs as a `Process` without a
deadline (never killed partway) and refreshes when it exits: `start`, `open`, `stop`,
`force-stop`, `notice-seen`, `settings`, `setup-host`. Through `lanai ui-job`
(detached, as above): every `lanai setup` call (including step 3's skip, the display
choices and the answers; superseded: no answers, see "Follow-on: setup checks (John,
2026-10-17)"), `snapshot` (including step 3's take) and `restore`. Groups:
`vm` (start, open, stop, force-stop, notice-seen), `setup` (setup, setup-host),
`settings` (settings), `snapshots` (snapshot and restore). Each group has one record, `panel-result-<group>.json`, written by
atomic rename: the token, the command and its arguments, the VM's `InvocationID`,
the start and end times, and the reply. `ui-job` writes a started record (no end, no
reply) at launch, holds `panel-job.lock` while it runs, writes each result before it
releases the lock, and on exit writes the final record before it releases. A record
is started (no reply), following (a reply, no end) or ended (an end). There is no
separate job file: the running job is the started or following record whose lock is
held. The view reads the records while holding a shared non-blocking probe on
`panel-job.lock` (only for the read, well under `ui-job`'s `flock -w 1`): if it gets
the lock, no job runs and the records are final, and a started or following record
then reads as interrupted, with Continue setup offered; if it does not, a job runs. A
launch refused by `flock -w 1` writes no record (so it cannot overwrite the running
job's); the pending token then times out. `ui-run` writes its record when its command
ends, with the unit's `InvocationID` read at that moment, and its stderr goes to
`panel-run.log` (the long jobs' go to `panel-job.log`). A result shows only when it
says something the state and `setup_plan` cannot: an `ok: false` failure (for setup,
only while its reply step matches the current plan; otherwise until the next action
in its group), start's no-network message (while that run is active), the snapshot
success text spec 7 requires, and a restore's outcome (both until the next
action in their group). Offers, waits and other successes map to nothing in the words
table, because the state already shows them; a stepless failure (the lock busy, the
user manager unreachable) stays until the next action in its group. A setup result
with the same reason as the current plan is hidden to avoid repeated guidance.

**During setup** (John, 2026-10-05, after the first panel test): the view hides
controls during first-time setup and setup boots, and draws the eye to what needs
the user.
- Start Windows and Open window are hidden only when setup has never finished for
  this storage location, or while a setup boot or final check boot is running.
  Setup starts Windows and opens the right window itself during those boots.
  A working install keeps Start Windows and Open window when an update or an
  unfinished setup round is pending, with the pending step in Setup beside them.
  This includes an outdated client build stamp after a Lanai update and a guest
  driver behind the pin. The top guidance agrees with the visible controls.
  When the usual window controls are hidden and the Looking Glass window closes,
  Setup offers "Reopen the Windows window", including after step 6 rolls back to
  step 5. It is hidden for QEMU's basic window and while Windows shuts down.
- The Snapshots section is hidden while setup boots or checks Windows (the unit is
  active); it shows again when Windows is off, so step 3's offer and recovery
  restores still work.
- Shut down stays during the setup boot. Use Shut down only if setup.cmd stops
  responding. The first request asks for a second click with "Shutting down now
  stops setup. You'll choose how to continue." A request already sent for this boot
  or a shutdown in progress needs no further confirmation. Arming Shut down clears
  Force stop's confirmation, and arming Force stop clears Shut down's confirmation.
- Settings stay: they apply at the next start.
- `setup.attention` is true when the user must act (an action such as Continue
  setup, the snapshot offer, the display choices, running setup.cmd, the step 6
  questions, or a failure; superseded: no questions, and a step 6 time-out is a
  failure, see "Follow-on: setup checks (John, 2026-10-17)") and false while Lanai
  works by itself, including every
  shutdown wait regardless of the setup reason. QML changes the Setup section's
  accent border and light background while keeping its inset constant. It uses
  the shell's selected accent fill when available, else a light accent fill.
Once setup is finished, every control shows as before. Tests cover each rule.

**The QML.** It polls `lanai panel` every 2 s while its own panel is open, and every
15 s otherwise (the tooltip), whatever the state; only the bar whose panel is open
polls fast. It has a 10 s deadline, skips a tick while a call runs, and an
action asks for exactly one fresh call after it ends. It renders the view's fields as
plain text (`Text.PlainText`), shows and enables controls from `buttons`, and runs
every command through `ui-run` or `ui-job`. Besides moment-to-moment input that
decides nothing on its own (the selected answers, gone since "Follow-on: setup
checks (John, 2026-10-17)"; unsaved settings edits, an armed
second-click confirmation for the forced stop or a restore, whose controls and labels
come from the view), it keeps one value: the token and time of a long job it launched
(`--pending <token> <epoch>`), passed to `lanai panel` until its record appears
or the next long job starts. Long-job clicks within the first 10 s of a pending
launch are ignored; short actions preserve the pending token and time. If no
started record with that token appears within 10 s, the view reports the launch as
failed (with the job log path). `SetupCalls.js` goes away.

**Performance.** One view makes at most one 5 s QMP session (status's), reads the
shared facts once, runs no client binary and no per-pid `grep`; it fits the 10 s
deadline in the worst case.

**Tests** (bats, over fixtures for the shared facts, `setup.json`, the run markers,
the group records and lock, `last-run`, settings and snapshots): every state
`status_map` can return; every setup step, including step 5 during and after the
setup boot, step 6 waiting, questions, a restart that retires them and a "no" answer
that hides them (superseded by the time-out and wrong-answer cases in "Follow-on:
setup checks (John, 2026-10-17)"), the display choices, and a back-to-step-5
failure; a finished
install with omarchy-windows-vm running or `~/Windows` missing (still finished); a
job running, interrupted and never started; a pending restore (stopped,
setup-needed, in-use); a restore success and failure; the forced-stop notice; Shut
down shown and enabled while stopping; Force stop only when `force_stop` is true,
with its armed second click in the QML; result currency (a setup result after a
restore, a vm result after the VM stopped, a wait reply after a Shut down ended its
job); the step 5 transition after a clean setup shutdown started from a `--window`
click (the follow-up carries only its expected step/invocation); a finished install
with `step5` false after a failed explicit display choice (not finished); a record read racing a launch and an
end; every reply-to-words table entry and its
`reason` codes; and that `setup-reply.json` is ignored. The setup job's following:
the step 5 transition after a clean setup shutdown (one more call), a panel Shut down
during the setup boot (stops), step 6 waits spaced 10 s apart, a stop during step 6
(stops), a failure (stops), and the record written before the lock is released. The
open phase 7 findings (gate rounds b 1-4, a 4) become test cases where they concern a
decision. The QML stays small enough to read in one sitting; `qmllint` must pass.

### Amendment: scale, progress and clicks (John, 2026-10-05)

This implements the approved spec changes to reqs 7, 11 and 12 and acceptance
rows 7 and 10-17. It supersedes the earlier scale and widget click rules. The
2026-10-05 spec review rows explain the proof and click cases John accepted.
Risk order: B, A, C. Start B's storage proof first. A's guest script and B's storage
helper can run in parallel. Integrate their shared bash, QML and test files in
turn. C follows B's operation-lock and progress contract.

Each phase starts with failing bats tests. Keep strict mode in bash entry points
(`set -euo pipefail`), preserve callers' options in sourced libraries, and pass
ShellCheck. Bash decides the `lanai panel` view; QML renders it. Keep all agent
scratch in the repository, including isolated HOME/XDG paths and `.btrfs-test/`.
Agents never touch John's live `~/.windows`. John runs the Windows checks on a
rehearsal copy and records them in `proofs.md` before phase 8's acceptance gate.

**Phase A: display scale (req 12).** Windows' scale changed with the Looking Glass
window's size (125% full screen, 175% at a quarter). `lanai-scale.ps1` currently
runs once at sign-in. Its API stores steps from Windows' recommended scale, which
changes with resolution. Keep the chosen absolute step through those changes.

- Tests first: extend `test/ui.bats`, `test/lifecycle.bats`, `test/checks.bats`,
  `test/guest.bats`, `test/panel.bats` and `test/panel-qml.bats`. Cover every valid
  step, `"auto"`, a missing key, invalid types and values, old two-argument saves,
  preserved settings keys, fixed boots without a monitor query, and automatic
  boots with the existing nearest-step matrix and 100% fallback. Invalid scale
  values refuse boot and show a panel error, as invalid memory and cores do
  today. Test the boot refusal and panel error. Test unsaved scale edits across
  polls, successful and failed saves, and reopening. Extract
  the guest's pure scale decision through its PowerShell AST, as StepName tests
  do; skip without pwsh. Cover caps, recovery, a moved recommended step, an
  unchanged display, and a display that appears after sign-in. Pin task flags.
  Add `powershell-bin` to CI only if it enters Arch's official repos.
  [ArchWiki](https://wiki.archlinux.org/title/PowerShell) lists it in the AUR,
  so guest scale tests skip in CI and must run locally with pwsh.
- Files: `lib/ui.sh`, `lib/lanai.sh` (`boot_vm`), `lib/vm.sh` as needed for a shared
  settings reader, `lib/panel.sh`, `LanaiPanel.qml`, `LanaiModel.qml`,
  `guest/lanai-scale.ps1`, `guest/setup.cmd` and `README.md`.
  `settings.json` gains `windows_scale`: `"auto"` by default, or a valid integer
  step (100 to 250 by 25, then 300 to 500 by 50). `lanai settings` reads it and
  accepts it as an optional third save argument; old saves preserve it. Validate
  it in bash, including at boot; refuse invalid values. `boot_vm` uses the fixed
  step or samples the focused monitor for `"auto"`, then passes the resolved
  step through boot.json and the existing SMBIOS string. Changes apply at the
  next start.
- The Settings view supplies the value and labeled choices for "Windows scale",
  starting with "Match my monitor". Windows' own "Text size" setting is different.
  QML keeps only the unsaved choice and sends it with memory and cores. Extend
  the settings-saved transport too.
  The guest applies the target at sign-in, then checks the current display path,
  resolution and scale range every 2 s. Recompute the target's relative steps
  each time and set only when its absolute scale differs. Cap at Windows' limit
  and recover when it grows. Checking the range as well as resolution catches
  Windows updating its recommendation later. Retry while the display is absent;
  log actual changes and errors without repeating unchanged polls. Exit at
  sign-out. Register the task with no execution time limit and
  `MultipleInstances IgnoreNew`, so it lasts past 72 hours without duplicates.
- Verify: run the named bats suites, ShellCheck and `test/qml-lint`. John reruns
  setup on the test copy to install the script, then checks fixed 125% from a
  quarter-size window to full screen, caps and recovery, two host scales, and
  both late and immediate client attachment from the earlier scale-timing check.
  Record the Windows scale and guest log. README tells existing users to click
  "Run setup again" after this update. Both "Match my monitor" and a fixed step
  resolve to one target at boot. README says the guest loop reverts manual scale
  changes in Windows Settings within 2 s for both choices.

**Phase B: snapshot and restore (req 7).** Clone first, then hash once. Every
allocated block must be shared before the read. On tested btrfs modes, a later
write to either file moves a shared block, including NOCOW's first write to a
shared extent; compressed clones share the encoded extent. An unchanged copy
map that still matches the other file proves the hashed data stayed shared.
Preallocated UNWRITTEN extents pass too. Dockur opens data.img with
`discard=unmap,detect-zeroes=on` (`lib/dockur-6.05.args`). QEMU turns guest zero
writes into fallocate zero ranges, which btrfs reports as UNWRITTEN. John's disk
likely has these extents. A clone reports them as shared and unwritten. A write
into a shared unwritten extent moves the block in both COW and NOCOW files, so
the same proof holds.

- Before building B, add `docs/plugin/proof-kit/count-image-extents.py`, a small
  read-only script that counts FIEMAP extent classes and flags without reading
  image data. John runs it on his rehearsal copy and records the counts in
  `proofs.md`. Agents never run it on `~/.windows`.
- Tests first: extend `test/snapshot.bats`, `test/lanai-copy.bats`,
  `test/panel.bats` and `test/panel-qml.bats`. Use real reflinks under
  `LANAI_TEST_BTRFS_DIR=$REPO/.btrfs-test`, with normal, NOCOW (`chattr +C`),
  compressed (`chattr +c`) and mixed-extent images. Set attributes before filling
  files. Use `chattr +m` or incompressible data for normal images and assert no
  ENCODED extents. Assert ENCODED extents for compressed images, and both plain
  and ENCODED extents for mixed images. Check NOCOW through the file attribute.
  Add `fallocate -z` regions to every mode and assert UNWRITTEN extents. Run the
  same mutation hooks on those regions as on the other allocated extents.
  For each mode and each operation, a test-only environment hook changes one
  allocated block of the clone after its first map, before hashing. A second
  hook changes the original source or snapshot after hashing, before proof.
  Both restore size and mtime. Each must reject completion with a clear message;
  snapshots leave no COMPLETE snapshot and restores keep recovery possible.
  Also change the actual read file at the second hook. Change the original
  snapshot after cloning and before proof while the hashed clone still matches
  COMPLETE. Only the map check before and after hashing can catch that case.
  Add a restore hook after ficlone onto data.img and before the final map
  compare; changing an allocated block there must reject completion. Removing
  either map check must fail its test. Cover sparse maps, map failures, partial
  files, damaged manifests, deleted disks, inode preservation, resumable markers,
  late stray files, locks, progress and cleanup on failure. For a deleted disk,
  assert data.img exists and holds the disk lock before hashing starts. Test a
  contender creating data.img before publication: never replace its inode.
  A lock failure on the temporary inode must leave data.img absent.
  A failed proof keeps the marker. Resume with a stale `.lanai-restore.data.img`
  whose NOCOW attribute differs; remove it and clone afresh with the right flag.
  Restore over an existing disk with rejected extent classes; only its btrfs
  filesystem and NOCOW match gate that destination. Gate refusals create no
  restore marker or partial snapshot folder. Test root fallback on EXDEV and
  EINVAL, partial-folder cleanup, and refusal on other clone errors. Test each
  small restore file's temporary hash before its rename.
  Plain-copy shims may test errors, but cannot establish a successful proof.
- Files: `lib/snapshot.sh`, `lib/copy.sh`, `lib/ficlone.py`, a new
  `lib/image-proof.py`, `lib/lanai.sh` (`layout_check`, `shared_facts`,
  `cmd_snapshot`, `cmd_restore`), `lib/panel.sh`, `LanaiPanel.qml`, `LanaiModel.qml`,
  `test/helpers.bash` (`LANAI_REQUIRE_BTRFS`),
  `docs/plugin/proof-kit/count-image-extents.py`, `.github/workflows/test.yml`
  and `README.md`. Keep generic `tree_manifest` for
  `lanai-copy`; snapshot/restore use manifests that hash data.img only once.
- Use Python's FIEMAP ioctl, alongside the existing Python FICLONE helper.
  It adds no filefrag dependency and avoids parsing tool output. Define the
  provability gate: statfs must report btrfs magic (`0x9123683e`). Synchronize
  allocations and collect the complete map, including holes and EOF. Python's
  `os.statvfs` has no `f_type`; use ctypes statfs or `stat -f -c %t`.
  Loop over FIEMAP batches with `fm_extent_count` as the capacity. Read each
  batch's `fm_mapped_extents` entries and continue until LAST or EOF. A compressed
  64 GiB image can map to about 500k extents. Measure map time, record it in
  `proofs.md`, and show this work under the "checking" progress phase.
  Every allocated extent must be plain, ENCODED (compressed) or UNWRITTEN
  (`FIEMAP_EXTENT_UNWRITTEN`, preallocated). Apart from SHARED and LAST
  bookkeeping, allow only ENCODED and UNWRITTEN; reject all other flags,
  including inline, unknown and delalloc still present after sync. Read NOCOW
  from the file attribute, not the extent flags. Omarchy mounts btrfs with `compress=zstd`,
  so an image with no attributes can have both plain and ENCODED extents. That
  mix passes. Compare logical offset, physical offset, length and ENCODED and
  UNWRITTEN flags. Equal physical offsets in two inodes prove sharing; drop the
  separate SHARED flag check. Reject ioctl errors. Open files without
  following symlinks; map and read the same open files and reject path
  replacement. Size only bounds the map; size and timestamps never prove data
  equality. Only btrfs with these extent classes and the tested NOCOW modes
  passes. XFS and every unprovable mode get the existing unsupported-snapshot
  response and backup advice, even if reflink itself succeeds.
- Threat model of the proof: it catches accidental writes, crashes and ordinary
  tools that change either file after the clone. Deliberate re-cloning or
  reference juggling by a same-user process is out of scope in every mode:
  unshare, write in place, clone back or other reference changes. For a
  compressed extent, FIEMAP reports the encoded extent's start but not the offset
  of a file's slice inside it, so a same-user process that deliberately clones a
  different slice of the same extent into the same position would not change the
  map. Compressed slices are one instance of the broader exclusion. The same
  process could rewrite COMPLETE or the snapshot's files outright. Say so in a
  comment at the comparison.
- Remove `snapshot_root`'s probe and probe cleanup, FICLONERANGE code and probe
  tests. Under the operation lock, retain the sweep of stale partial snapshot
  folders whose SOURCE matches this storage location; leave unknown or other
  locations alone. Record and flush SOURCE before cloning so interrupted copies
  can be reclaimed after power loss too. Remove newly created empty roots after failed clone attempts and
  stale image-map records whose owner pid is dead. Under the disk lock, apply
  the statfs and extent-class gate first. Try the real clone into the first snapshot root's partial folder, with
  NOCOW matched. On EXDEV or EINVAL, remove that folder and try the next root.
  Other clone errors fail the operation. If no root works, say this location
  cannot make an instant copy and suggest a backup.
- Snapshot: retain the partial folder, SOURCE, COMPLETE format, rename and flush
  rules. Apply the provability gate before creating the partial folder. Clone
  the install, record both image maps and require equality. Hash the clone once,
  then require both maps to equal that saved map. Hash small
  files from the clone and byte-compare them to the source; check the exact file
  list too. Only then write COMPLETE and publish. Failure removes the partial
  snapshot and says nothing was kept. Reading the shared clone hashes the
  source's data while keeping the single read easy to count.
- Restore: retain validation, NOCOW refusal, the operation and disk locks,
  resumable marker, stray-file check and flush rules. Apply the full provability
  gate to the snapshot image before the marker. For an existing storage disk,
  check only statfs for btrfs and NOCOW match, not its extent classes. FICLONE
  replaces all its extents; the final map check compares data.img with the saved
  temporary map. A gate failure is a clean refusal. When data.img exists, hold
  its disk lock, clone snapshot data.img to `.lanai-restore.data.img` in storage
  with NOCOW matched, record
  equal maps, hash that file once against COMPLETE, then require both maps to
  equal the saved map. A resumed restore removes the stale temporary file and
  re-clones it with the snapshot's NOCOW attribute matched.
  Clone each small file to `.lanai-restore.<name>`, hash that temporary file
  against COMPLETE, then rehash it immediately before its rename after the image
  proof. Drop the separate byte check; small files may be read a few times.
  The marker must precede the storage temporary files. With an existing disk,
  any failure before the first install
  file is replaced (a clone error such as EXDEV, or a failed verification) is a
  clean refusal: it removes the temporary files and any newly created marker; preserve an
  older unfinished marker.
  Interruption keeps the marker. After proof, clone the verified temporary file
  onto data.img with `ficlone.py`, keeping QEMU's locked inode. Compare the final
  map with the saved temporary map, rename the verified small files and remove
  the temporary image before the stray-file check. Never run a final image hash.
  When data.img is absent, write the marker, clone snapshot data.img into
  `.lanai-restore.data.img` with NOCOW matched. Take `lock_disk` on that temporary
  inode before publishing it as data.img. QEMU's OFD locks stay with the inode,
  so data.img holds the disk lock the moment it appears. Publish with ctypes
  `renameat2(RENAME_NOREPLACE)`. Never use `mv -n` or `mv -f -T`: dockur may have
  created a disk in the meantime. Lock failure stops before publication; drop
  the branch for locking failure after publication. Before publishing, clone each
  small file to `.lanai-restore.<name>` and hash it against COMPLETE (a second or
  less). Right after publishing data.img, rehash and rename those small files into
  place, so dockur's start check finds an existing install and does not run its
  cleanup, which deletes disk files whatever their locks. Only then record equal
  maps, hash and prove data.img in place against COMPLETE and the saved maps.
  Retain fresh small-file clones after the early renames; rehash them against
  COMPLETE immediately before the final renames after the image proof.
  Never replace this locked inode later. A test starts a fake container check
  during the image hash and asserts it finds `windows.boot`. A failed proof keeps the marker;
  the disk was already gone, so nothing is lost. This path changes storage before
  the hash. It is a deliberate exception to req 7's "before anything changes",
  justified by its disk-lock clause: the disk was already gone. John approved it
  on 2026-10-05 (spec review log). Keep the marker
  if publication or locking fails too. On success, clear the marker and reset
  setup only after completion.
  Preserve today's messages' intent, including damage before replacement and
  recovery guidance after a partial replacement.
- One chunked hashlib reader in `image-proof.py` reads image data. Fold the
  first-100-KiB nonzero adoption check into that pass for snapshots.
  `layout_check` currently reads those bytes separately; split its structural
  checks from that data check. Snapshot uses the structural checks first, and
  panel polls omit the image read while the operation lock is held. Normal boot
  checks stay complete. Test this with a panel opened during both operations.
- Publish `<state>/image-progress.json` by atomic rename, about once a second:
  operation, phase, bytes done, total and owner pid. Bash publishes cloning,
  checking and finishing phases too. Initialize and remove it inside the
  operation lock for CLI and panel starts. Keep completion below 100% until
  proof and flush succeed. "Held" means a FLOCK entry for `<state>/lock`'s dev:ino
  in `/proc/locks`; use `lib/lanai.sh`'s existing device and inode parser near
  line 140. "Owner" means the progress file's pid is alive and has `<state>/lock`
  open, checked by comparing each `/proc/<pid>/fd/*` target's device and inode
  (`stat -L`) with `<state>/lock`'s, so a symlinked state folder still matches. `lanai_flock` runs external
  `flock -n "$fd"`, so `/proc/locks` names the short-lived flock process, not the
  holder. Do not compare that pid with the progress owner. `lanai panel` requires
  both checks, then returns `progress: {label,percent}` or null. Never probe with
  flock: even a brief probe can make concurrent `lanai_flock` (`flock -n` on
  `<state>/lock`) fail as busy. Use this activity for busy controls even without
  a panel-job record. Ignore stale, dead-owner and
  malformed files; polling writes nothing. Supply null in initial/error views.
  QML shows a progress bar and the percentage as plain text in Snapshots. Test
  advancing progress, a newly opened
  panel, CLI starts, failure, interruption and stale records. Test the real
  external flock case after flock exits, a live pid without the lock file open,
  a dead owner, a held lock on another inode and an open file without a held lock.
- Verify the read budget with `strace -f -yy`, summing successful read/pread and
  readv/preadv variants on storage, snapshot and temporary-copy files across all
  children. Also fail if mmap, sendfile, splice or copy_file_range touches a
  counted file. Start concurrent panel polls only after the operation holds its
  lock, for example once its progress file appears. Keep fixture preparation and
  independent outcome hashes outside the trace. Image reads must total at most
  one logical image size. For a one-snapshot fixture, cap small-file reads at
  `4*S + (P+1)*64 KiB`: S is the sum of install files other than data.img, P is
  the fixed number of panel polls, and 64 KiB covers SOURCE/COMPLETE reads.
  Report image and small-file counts separately. Add strace to CI and require
  the measurement there. CI keeps its privileged container's loop-mounted
  btrfs folder (`LANAI_TEST_BTRFS_DIR`, `.github/workflows/test.yml`) and adds
  strace to its packages. CI also sets `LANAI_REQUIRE_BTRFS=1`, which makes
  `btrfs_tmp` in `test/helpers.bash` fail instead of skip when the folder is
  missing or not btrfs. Local runs keep skipping without it. Skip locally if
  unavailable and report the skip.
  This observes reads outside the helper and cannot hide a second pass in page
  cache. Run the named bats suites, ShellCheck and `test/qml-lint`; CI must run
  all four real btrfs fixtures. Record row 7's hashes, traces and proof fixtures in
  `proofs.md`. Use mocked lock contenders in agent runs; John checks the real
  container-start refusal on a separate test install. README explains progress
  and the fallback for an unprovable filesystem.

- Unfinished restores (John, 2026-10-05, from the diff gate's stage b round 3):
  `lanai restore` with no name resumes the marker's snapshot, as before.
  `lanai restore <name>` naming a different valid snapshot always replaces an
  unfinished marker and starts over, since a restore replaces the whole disk.
  There is no separate "verification failed" marker state. While a restore is
  unfinished, the panel offers Finish the unfinished restore and every other
  snapshot's Restore control; its words say either works. A failed check never
  says "Nothing was changed" once an earlier run has changed the disk.

**Phase C: icon clicks (req 11).** Change the icon's clicks and leave the panel's
Start, Open and Shut down controls in place.

- Tests first: extend `test/panel.bats` for all nine req 10 states, finished and
  unfinished setup, setup and check boots, snapshot/restore from CLI and panel,
  an unfinished restore, and running with the window open or closed. Assert
  `right_click` and its tooltip words. Extend `test/panel-qml.bats` to load
  `Widget.qml` with inert bar/button types too. Test left click, Enter and Space
  opening and closing the panel, Menu toggling it, right-click dispatch,
  unknown/missing actions opening the panel, and literal `ui-run` argv without a
  real service or shell. Cover a stopped install with a pending update step:
  right click opens the panel and Start stays enabled.
  Test running with a closed window during a blocking operation: right click
  still opens the window, as the panel's Open button does.
- Files: `lib/panel.sh`, `Widget.qml`, `LanaiModel.qml` and `README.md`.
  Bash returns `right_click: "start"` only for stopped, finished setup with no
  blocking operation or unfinished restore; `"open"` only for running, finished
  setup with its window closed; otherwise `"panel"`.
  Use `panel.sh`'s `$p.finished` for current setup completion.
  This is stricter than dailyControls' `setup_done` for a stopped VM, on purpose.
  A right click on a working install with a pending update step opens the panel;
  its Start still works. Bash supplies a tooltip line naming "Right click" and
  the action; `LanaiModel.qml` includes that line. Widget left click, Enter (Return and keypad
  Enter, `Keys.onReturnPressed` and `Keys.onEnterPressed`), Space and the Menu key
  toggle the panel in every state. Right click dispatches
  the supplied start/open action through `ui-run`, or opens the panel. It never
  decides from status or control enablement. Keep command-side guards for
  changes since the last poll.
- Verify: run both named bats suites, ShellCheck and `test/qml-lint`. John checks
  clicks and keyboard input on the rehearsal copy using the row 10-17 matrix,
  then checks shut down and close/reopen (rows 16-17). README names both clicks,
  Enter, Space and the Menu key. Rows 10 and 13-17 keep their other phase 8 checks.

**Review.** Put the plan amendment's gate rows in this document's Review log.
The orchestrator runs the gate; delegates run no review stage.

### As built (2026-10-05)

- **Display scale (amendment Phase A):** Settings now read and save
  `windows_scale` as `"auto"` or a validated Windows step; old two-argument saves
  preserve it and other keys. Boot validates the setting and resolves a fixed
  step without querying a monitor, or uses the existing nearest-step rule and
  100% fallback. Bash supplies the panel's labeled choices, and QML preserves
  unsaved scale edits through polls and failed saves, accepts the successful save
  reply and resets on reopen. The guest recomputes the relative offset from the
  current display path, resolution and DPI range every 2 s, sets only actual
  changes, caps and recovers, retries late attachment and suppresses repeated
  errors. An unchanged failing scale decision backs off to one attempt per minute
  and logs that decision once; a new display, range or target still applies at
  once. Pre-attempt logs are best effort, so a failed log write cannot prevent
  the scale API attempt. The retry deadline starts only after that attempt.
  A failing log write inside error handling cannot end the loop. Its
  sign-in task has no execution limit and ignores duplicate starts.
  README documents rerunning setup, next-start choices and manual Windows scale
  changes reverting within 2 s. Tests were written first, including PowerShell
  AST decision and late-display fixtures run locally with pwsh. All 14 new Bats
  cases and the added QML test function pass. Outside the agent sandbox (which denies
  Unix socket binds), Claude ran the full suite: 640 of 640 pass, one locale skip. QML lint,
  the full ShellCheck command and `git diff --check` pass. No plan deviation;
  John's Windows checks and proof log on a rehearsal copy remain pending.
- **Phase B, snapshot and restore:** FIEMAP gates btrfs images and proves equal
  shared maps before and after the one image hash, with a final map after restore
  FICLONE. Each small temporary file is rehashed against COMPLETE immediately
  before every rename. A refusal before publication removes staged files and a
  new marker, preserving any older marker. Deleted
  disks publish the locked inode with renameat2 no-replace and install boot files
  before hashing, using John's approved req 7 exception, then retain fresh small-file clones for
  final verification and replacement after the image hash. Any unfinished
  restore can resume its snapshot, with no name or the same name, or start over
  with a different valid named snapshot on either disk path. The marker records
  only the snapshot and storage location; staged images are removed on failure.
  Hash damage advises restoring another snapshot by name. Refusals claim nothing
  changed only when no older marker existed and this attempt changed no install
  file. The panel offers finishing or restoring any other snapshot and explains
  both choices while Windows is stopped. CLI and panel
  operations publish phases, byte progress and owner under the operation lock;
  QML renders the percentage with a comma after the label, showing the label
  once and keeping "Keep Windows stopped until it finishes." visible during
  restore and "You can close this panel." visible during a snapshot. (Superseded:
  no busy line shows beside progress or a running restore, and no busy line says
  "You can close this panel."; see redesign/stopped-copy.md.) Labels say
  "Taking a snapshot: making an instant copy" and include the articles in the
  checking and reading phases. Checks are labeled before cloning starts;
  replacing the disk covers
  the in-place clone and its final map. The panel reads activity once per poll
  and reuses it for shared facts. Only validated activity from a live snapshot or restore owner skips
  the panel image read; setup's own operation lock still checks the first 100 KB
  for nonzero data. Proof and gate failures keep details in stderr and show plain
  reasons with final periods; snapshot backup advice appears once in the next
  step. Restore refusals have a separate reason and panel words explaining the
  unsupported storage without claiming the disk is unchanged. All clone and
  publication errors use the same mapping, with details kept in the operation
  log. A successful proof's manifest
  is separate from later small-file failure reasons. Under the lock, stale
  partials matching SOURCE and dead-owner image maps are swept. SOURCE precedes
  cloning and is flushed with its directory before a clone can pin blocks;
  failed fallback attempts remove newly created empty roots.
  Snapshot validation relies on the exact sorted file list to reject duplicate
  manifest names, restore reuses its parsed small-file hashes, and the unused
  snapshot manifest helper and unused image-map attribute query are removed.
  Non-object progress JSON is ignored as malformed, leaving panel progress null.
  Real normal, NOCOW, compressed, mixed and UNWRITTEN mutation fixtures cover the
  proof, plus sparse pagination, recovery and publication races. CI requires btrfs
  and strace; the read-budget test includes concurrent panel polls. Deviation:
  this PID namespace hides /proc/locks entries after external flock exits even
  while the lock remains held. In that case the reader checks the matching
  owner's kernel FLOCK entry in /proc/<pid>/fdinfo, without probing the lock.
  The existing read-only extent census gains map timing and JSON output; no
  duplicate script was needed. Outside the sandbox the full suite passes 650 of 650 (locale and strace
  skips). Local strace measurement skips when unavailable;
  John's rehearsal-image timing and container-start check remain manual proofs.

- **Unfinished restore checks (2026-10-05):** Tests first reproduced a deleted
  disk's non-hash proof failure blocking named and unnamed retries, an
  interrupted replacement followed by snapshot image damage hiding the way
  out, and another named snapshot being refused with the disk still missing.
  Recovery checks cover both disk paths, exact restored manifests and marker
  removal. Older-marker refusals cover the image gate, destination filesystem,
  disk lock, NOCOW, empty image and damaged small files without claiming Windows
  was unchanged. Tests through `lanai panel` cover both recovery choices and
  persistent snapshot progress guidance. The PowerShell log-failure fixture
  checks the scale attempt before logging recovers. The obsolete marker-state
  assertion and tautological awk test are removed; appended snapshot and restore
  failure cases now sit in their behavior groups. With scratch HOME and XDG
  folders, 77 snapshot cases, 93 panel cases and 26 guest cases pass. The
  read-budget case skips because strace is unavailable; six QEMU lock cases
  were excluded under the no-VM instruction. No socket tests failed. QML lint,
  the full ShellCheck command and `git diff --check` pass.

- **Checks after the confirmed findings (2026-10-05):** Tests first reproduced
  both deleted-disk damage paths, unsupported restore wording, repeated snapshot
  advice, raw helper errors, early clone progress, duplicate activity calls and
  the guest log backoff. The firmware-byte and image-byte fixtures each try the
  bad snapshot, an unnamed restore and the good named snapshot, then check the
  cleared marker and exact good manifest. Older markers survive clean refusals.
  Cases from `test/review-fixes.bats` now live in the snapshot and adoption suites
  with behavior names; the obsolete lock shim and that file are removed.
  New-file clone cases live with snapshot's existing clone cases. Lifecycle's
  automatic scale boot test uses representative values; adoption tests keep the
  full rounding matrix. The clone helper names its set-flags ioctl and documents
  snapshot use too. The touched suites cover 327 distinct cases: 323 pass,
  three lifecycle fake-QMP cases fail because the sandbox denies socket binds,
  and the read-budget case skips because strace is unavailable. Passing cases
  by suite: snapshot 73, panel 91, guest 26 (including pwsh), adoption 62,
  copy 27 and lifecycle 44. All four btrfs mutation modes pass. Under the
  delegate's scope limits, 48 cases are omitted: 14 paused-QEMU probes, 33
  compose-file cases and one /dev/shm write. The corrected cleanup and copy
  expectations pass on rerun. QML lint, the full ShellCheck command and
  `git diff --check` pass. Scratch is removed.
  The delegate runs no review stage; the orchestrator owns the gate and John's
  manual rehearsal proofs remain pending.

- **Icon clicks (amendment Phase C):** Bash supplies the right-click action and
  tooltip: Start only for a stopped install with current setup finished and no
  blocking operation or unfinished restore; Open for a running, finished install
  with its window closed, including during a blocking operation; otherwise open
  the panel. Pending update steps keep the panel's Start available while the icon
  opens the panel. Left click, Return, keypad Enter, Space and Menu toggle the
  panel; right click dispatches literal `ui-run` argv or opens the panel, with
  existing command guards retained. Tests first cover the nine states, setup and
  check boots, CLI and panel operations, recovery, window state, keyboard input,
  fallback actions and tooltips using inert QML bar/button types. README names
  both clicks and keyboard keys. No plan deviation; John's rehearsal-copy click,
  keyboard, shutdown and close/reopen checks remain pending.

- **During setup:** Start and Open hide only before setup has finished for the
  current storage location or while a setup boot or final check boot is active.
  Working installs keep their daily controls beside pending build, driver and
  unfinished setup steps. Final check boots record their mode in the boot record;
  an ordinary start clears it. A completed round stops treating that boot as a
  final check boot, even if an update becomes pending while Windows stays running.
  Setup offers Reopen the Windows window only while the usual window controls are
  hidden, a client-mode boot's unit is active (not activating or reloading), the
  client is not running, and shutdown is not in progress, including after a step 6
  failure or no answer rolls back to step 5. (Superseded: only a wrong answer rolls
  back; see "Follow-on: setup checks (John, 2026-10-17)".)
  Boot flags also cover activation before status reports the display.
  Reopen uses `ui-run open`. `snapshots.show` and its control descriptors hide
  the section only when the usual controls are hidden with an active unit;
  working installs keep Snapshots during ordinary boots with a pending update.
  Settings stay.
  Shut down during the setup boot supplies a confirmation control and the warning
  “Shutting down now stops setup. You'll choose how to continue.” The second click
  uses `ui-run stop`; Cancel, closing the panel or a view that no longer needs
  confirmation clears it. An existing request for the current boot and any
  shutdown in progress bypass confirmation. Shut down and Force stop cannot both
  be armed. Both setup client starts accept a window already opened by Reopen.
  Step 5 says "Use Shut down only if setup.cmd stops responding."
  `setup.attention` marks user actions, setup failures, interrupted work, a failed
  launch and a closed client window. It clears during automatic work and shutdown
  waits regardless of the reason. A setup boot needs attention once QEMU reports
  running, even if the setup drive is not yet available.
  Regression tests cover rollback with a closed client and all step 6 rollback
  reasons during unit deactivation, requested shutdown and guest shutdown.
  Guidance follows the visible controls, including the cause in the top block.
  QML keeps Setup's inset constant and uses an accent border and the shell's
  `Style.selectedAccentFill`, falling back to `Util.alpha(Color.accent, 0.10)`,
  following shell theme changes. Finished setup retains its usual controls and has
  no attention highlight. An empty Setup section hides its padding too.
  A pending launch with no record now supplies progress without indexing a missing
  command. Nineteen new Bats cases cover every setup step, worker and idle attention,
  both boot displays and client states, section visibility, confirmation and finished
  controls. The inert QML test also covers confirmation, cancellation and resets,
  daily shutdown, Reopen transport, section visibility, empty Setup content and
  live theme colors.
  Earlier validation for this addition: `bats test/panel.bats test/panel-jobs.bats
  test/panel-qml.bats test/ui.bats` runs 105 cases with one comma-locale skip.
  These review fixes pass 89 cases in `test/panel.bats`, `test/panel-qml.bats` and
  `test/ui.bats`, with one comma-locale skip; the renderer runs 16 QML test functions.
  `test/qml-lint` passes all three QML
  files, and the complete project ShellCheck command including both fake servers
  and `test/qml-lint` passes. Tests were written first and failed before the changes.
  Scratch stayed under `.btrfs-test/` and was removed. No VM, real units, shell,
  review stage or commit ran.
- **View and words:** `lanai panel` in `lib/panel.sh` returns one complete view,
  including controls, setup, results, settings, snapshot names and logs. It never
  acts and ignores `setup-reply.json`; status's existing `guest_version_note` is
  its sole permitted write. Status and reply tables supply plain text rather than
  CLI messages. Structured `reason` codes distinguish step 1 problems,
  back-to-step-5 failures, failed snapshot-choice writes and unsupported snapshots.
  A failed snapshot-choice write carries `reason: record` with no `step`, so an
  existing snapshot advancing the plan to step 4 or 5 cannot hide the failure.
  It persists until the next setup action and tells the user to check home folder
  space, then click Continue without a snapshot or take a snapshot again when the
  plan is at step 3, or click Continue setup otherwise. The snapshot offer stays
  silent.
  Snapshot success keeps its location, growth and file-manager deletion guidance.
  Snapshot outcomes also show below the step 3 snapshot controls. The Setup
  header shows whenever Continue setup shows. Missing-install guidance appears
  only in the top block when the plan repeats that state. Shared-folder advice
  explains that Windows must be a real folder in the home folder, owned by the user.
  Offers, successful waits
  and ordinary successes produce no result text. Setup failures with a step show
  only at the current plan's step; duplicate plan reasons are hidden. Stepless
  failures and other groups' failures persist until the next action in their group;
  start's network warning requires the same active invocation; snapshot and restore
  outcomes persist until another action in that group. Settings/list read errors
  are separate data, and warnings use status's structured details, joined without
  leading spaces or a repeated driver warning during a version mismatch. Logs
  name each file: Windows window log, setup/snapshot/restore log, and button actions
  log. The VM log points to the user journal under `lanai-vm`; an unavailable
  runtime omits the Windows window log. Reply words use those same names.
  Restore success says only "The snapshot was restored.", so its persistent
  outcome cannot keep asking for setup after setup finishes again.
  Step 5 and 6 waiting words require a setup job holding `panel-job.lock`;
  without one they ask the user to click Continue setup. The step 5 drive
  instructions still require the setup boot. While step 6 is stopping, its line
  asks the user to wait for shutdown, then click Continue setup; the button stays
  disabled until shutdown ends. Continue setup is disabled for `no-media` and
  `active` at every step, whose next step is shutdown.
  Restore labels include the snapshot name before "and replace Windows".
  Armed Run setup again shows "Choose how Windows should show during setup."
  and a Cancel button that clears the armed state.
- **Shared facts:** `shared_facts` supplies layout, storage, container, unit state,
  `Result`, invocation and restore pending. A layout result of 2 gets reason
  `missing` and tells the user to install Windows with Omarchy before setup;
  an incomplete or unsupported install keeps reason `layout`.
  Status and setup each gather once.
  Container detection scans cgroups and command lines with bash builtins and is
  skipped for an active unit. The gatherer makes no QMP call or write. The complete
  view uses status's one bounded QMP session and never executes a client binary.
- **Durable setup:** `setup_plan` selects every step without acting. It reads the
  pure `run_verdict` before setup state, overlays clean setup shutdown, changed
  storage and existing snapshots, and implements step 7's finished rule including
  `step5 != false`. `record_previous_run` shares the verdict; `running` is read
  last and deleted first, with step 5 written before deletion. A build-local
  `build-stamp` containing `LG_BUILD` replaces binary execution during planning;
  verified existing installs and new builds get the stamp, and pruning removes it
  with the build. Step 6 writes its question marker, RESET events retire it, and
  VM startup clears it. A negative answer hides the questions by returning to
  step 5. (Superseded: the markers are now step 6's limit stamps; see "Follow-on:
  setup checks (John, 2026-10-17)".) Plan/resume agreement tests cover both present and consumed markers,
  early and active phases, and a panel-requested shutdown, comparing steps,
  actions and JSON reply reasons. Both agreement tests include runs that started
  then failed with `Result=exit-code`, with `step5` true and false. Resume passes
  its consumed verdict, using `none` for empty output, into planning; the same
  effective verdict decides whether Windows never started.
- **Following jobs:** the setup worker owns all follow-up calls. Two-second checks
  require the expected unit/invocation state; follow-ups carry only
  `--follow <step> <invocation>`; completed setup calls are at least ten seconds
  apart, with busy setup-resume lock attempts retried after two seconds. Setup
  rechecks that expectation under its operation lock before bookkeeping or any
  action; stale expectations return an inert reply, covering the stop race
  between the worker probe and setup's fact gather. A clean automatic setup
  shutdown advances once; a deactivating unit keeps the worker waiting until
  inactive or failed, before it evaluates the ended run. Panel shutdown,
  force stop, invocation changes, failures and terminal replies end
  following. Only a busy reply from setup resume's initial lock, marked
  `follow_retry: true`, retries after two seconds without replacing the wait.
  A later `boot_vm` lock refusal ends following and exposes Continue setup:
  a step 5 resume has already consumed the run markers by then, so replaying
  its guard would stop without retrying the boot. Settings saves and notice
  dismissal do not end step 6 checks. Step 6 also checks matching stop requests. Long jobs run through
  `systemd-run --user --collect` in `session.slice`, with
  `PartOf=graphical-session.target` and `After=graphical-session.target`, and
  hold `panel-job.lock`. The setup worker checks that target is active before
  every setup call and during waits; logout ends following even with lingering
  enabled. A first call outside the desktop session records a visible failure.
  Result timestamps use a local C locale so decimal commas cannot break JSON.
  The locale test skips when no comma-decimal locale is installed.
  Closing the panel or reloading the shell does not end them. Client-mode setup
  boots start the selected client themselves; step 6 starts the pinned client.
- **Records:** `ui-run` records direct actions when they end, with the current
  invocation and stderr in `panel-run.log`. `ui-job` serializes setup, snapshot
  and restore, and atomically writes one `panel-result-<group>.json` for each of
  vm, setup, settings and snapshots. It publishes started, following and ended
  records, writing the final record before releasing its lock. Refused workers
  leave the owner's record untouched and append their refusal to `panel-job.log`,
  so the launch-failure log contains the reason. The view probes the existing
  lock read-only with a shared lock before reading records and keeps a successful probe
  throughout the reads. Concurrent bars do not report each other as workers;
  unfinished records without a held lock become interrupted. Interrupted setup
  always offers Continue setup. A pending token with no record after ten seconds
  reports a launch failure. The view returns `pending_ack` when that token's
  record appears; its bar clears the pending token, so a later action from
  another bar replacing the group's record cannot revive a launch failure.
  Pending long-job clicks within ten seconds are ignored. Short actions preserve
  the pending token and time, including a launch failure; the next long job replaces
  them. Backend and QML tests cover rapid clicks, short actions after a failed
  launch and both monitors' launch/acknowledgment sequence.
  High-resolution start times select the newest
  outstanding record when an older interrupted record belongs to another group.
  The old `panel-job.json` and `ui-job-status` path is removed.
- **Runtime updates:** the stable runtime revision combines `LANAI_VERSION`
  with a SHA-256 of the relative filenames and contents in `bin/` and `lib/`.
  A stopped install replaces the legacy version-only copy and reloads its unit
  after any code change, including RESET handling and VM startup cleanup;
  identical content reuses the copy without a reload.
- **CI result reporting:** sourced libraries preserve the caller's shell
  options; the CLI entry points own strict mode. `lib/ui.sh` no longer enables
  nounset in Bats, which otherwise makes Bats 1.14.0 timeout cleanup abort on
  `BATS_killer_pid` after a failed assertion and lose the result line. The
  unstamped-client test isolates its build/`timeout` call in a fresh Bash process
  with the test's HOME/XDG paths. The original CI assertion failure remains
  unconfirmed; its result-suppression mechanism was reproduced locally.
- **Renderer:** `LanaiModel.qml` polls only `lanai panel`, every two seconds while
  its own panel is open and every fifteen seconds otherwise, with a ten-second
  deadline. It skips routine overlapping calls and requests one fresh read after
  an action, discarding an older in-flight read. Direct `ui-run` actions use a
  Process without a deadline; `ui-job` launches are detached so pending-token
  checks remain possible even if launch stalls. QML retains transient answers
  (gone since "Follow-on: setup checks (John, 2026-10-17)"), unsaved settings, second-click confirmations and the pending token/time, with
  transport state only for serializing reads/actions. It renders plain text and
  backend control descriptors; `SetupCalls.js` and its test are deleted. Settings
  fields freeze their transient input on the SpinBox's `valueModified`
  signal, so real keyboard edits survive polls; reopening loads current settings,
  and a successful Save resets the fields to the submitted values. Failed saves
  keep the edits. On a finished install, Run setup again reveals the backend's two
  display choices and their hints, only while Windows is off. While Windows runs,
  the disabled button says to shut it down first. After an interrupted re-run,
  Run setup again also reveals the choices first. Each choice launches an explicit
  `setup --no-window`
  or `setup --window` job, bypassing the finished shortcut. Only that reveal is
  transient; reopening clears it, and the backend still enables each choice.
  Basic-window and step 5 guidance use plain words, including the automatic
  shutdown and restart for checks. Progress distinguishes setup completion from
  checking Windows; interruption words name setup, snapshots or restore.
  The widget retains its L-in-a-monitor glyph, shell-owned popout and primary-click
  start/open behavior. Force stop and restore both require a second click.
- **Documentation:** README describes autonomous setup, current guidance,
  snapshot refreshes, result logs and the Qt 6 renderer test. CLAUDE's layout now
  names the view, transport and per-group records, and `test/qml-lint` resolves
  imports against the installed shell types with a temporary local `qs` mapping.
  CI no longer installs Node for
  the deleted JavaScript test.
- **Interpretations:** setup samples the shared facts immediately after taking
  its lock, before consuming markers and following storage, to guard those writes
  with the unit state and validated layout without a second gather. Mutation
  order remains record, follow, then act; planning uses that same sample. VM logs
  live in the journal, so the view names the session service rather than inventing
  a filesystem path or exposing a CLI command. The shell's Qt 6 types use
  `ComponentBehavior: Bound`; Qt 6 lint is authoritative, since this machine's
  legacy `/usr/bin/qmllint` (1.0) exits silently on that pragma. No other amendment
  departures are intended.
- **Validation:** tests were added before implementation. All 75 tests in
  `test/panel.bats`, `test/panel-jobs.bats`, `test/panel-qml.bats` and `test/ui.bats`
  pass. The QML test loads the real files with inert shell/Process types and checks
  both monitors' polling cadence, refresh races, direct and detached literal
  arguments, launch tracking, settings edits with a real Qt SpinBox and keyboard
  input across polls, failed/successful saves and reopen, both repair display
  choices with their hints, and both confirmations. Launch acknowledgment is
  tested across both monitors before one replaces the other's group record.
  Worker tests check the graphical-session unit properties, refusal outside
  the session, logout during a wait and after its probe, and step 5 waiting
  through deactivation before checking the ended run, plus saves and notice
  dismissal during step 6 and a busy follow-up retry after two seconds. Tests
  also pin setup result currency, duplicate-reason suppression, warning spacing,
  journal labels, missing runtime paths and the local C timestamp guard (no comma
  locale is installed here). The QML checks the disabled re-run button's hint.
  This follow-up ran 142 passing tests: those 75, all 22 guest tests, 23 selected
  client tests and 22 selected spike tests. The unchanged spike live-flock test
  still fails at line 190; without Bats' timeout it reports the assertion normally.
  With the timeout it loses its result line during cleanup. The setup regression also
  checks both failed snapshot-decision writes (taken and declined) and both
  explicit displays after finished setup. The earlier socket-free selections also
  passed in
  `test/lanai.bats`, `test/checks.bats`, `test/vm.bats`,
  `test/client.bats`, `test/setup.bats`, `test/lifecycle.bats`,
  `test/proof-kit.bats`, `test/lanai-copy.bats` and `test/snapshot.bats`; all of
  `test/guest.bats` passed. That earlier socket-free selection totaled 387 passes, three
  filesystem skips and one failure: 44 of 45 selected `spike/test/lgtest.bats`
  tests pass, but its unchanged live-flock test does not find the held lock in
  `/proc/locks` here (line 190). Qt 6 `qmllint` passes
  all three QML files with the installed shell imports (a repository-local `qs`
  import mapping supplies the installed shell's namespace), and the complete
  project ShellCheck command passes. Socket-dependent tests could not run in this sandbox;
  paused-QEMU and compose-reading tests were excluded by the task constraints.
  Scratch stayed in the repository and was removed. No VM, real units, Omarchy
  shell, plugin installation, review stage or commit ran.
- **Deferred acceptance:** scale timing still requires a person and a running
  Windows test copy, and no client flags changed then. (The resize drag was
  settled on 2026-10-23 by `docs/plugin/client-warp/plan.md`, which adds
  `wayland:warpSupport=no`.) The proof records do not establish an exact
  supported Omarchy release; README keeps that and reboot timing/spike
  measurements as phase 8 items. The custom glyph remains because
  marketplace Windows plugins are not installed here.

## Follow-ons after v0.1.0

John's calls from the phase 7 hands-on run (2026-10-05). Each goes through the usual
spec, plan and review gates before it is built.

- **Looking Glass resize on first open.** The client sends the window size once per
  size; a display driver restart during Windows' boot loses it, and the client's
  `lastWindowSize` (client/src/message.c) then skips the resend. Specified as req 12's
  size rule (spec amendment of 2026-10-12) and planned in
  [Follow-on: resize](#follow-on-resize-john-2026-10-12), which also offers the fix
  upstream.
- **Icon color by health.** Today the icon turns the shell's urgent color (red in John's
  theme) whenever the VM runs, because `active` uses `Color.urgent`. Wanted: green when
  running and healthy, amber when running with a problem, red when running with a major
  issue, and no color (the normal foreground) when Windows is not running. Bash decides
  the level in the panel view; the tooltip keeps the words (req 10: never color alone).
- **Continue setup shown before the host packages are installed.** Seen by John on a
  second machine (2026-10-06): at setup's host-package step the panel says to click
  Install in a terminal and then Continue setup, but Continue setup already shows
  beside Install. Wanted: while packages are missing, show only Install in a terminal;
  show Continue setup once they are present (or after the terminal closes), so the
  order of the two clicks is the only one the panel offers.
- **Rename "Continue setup" to "Windows Setup".** John's call (2026-10-06): "Continue
  setup" reads as unclear to new users. Rename the button, and every panel line and
  README step that tells the user to click it, in one change; decide then whether "Run
  setup again" follows the same wording.
- **Resize at the sign-in screen.** John's call (2026-10-13): worth adding in a later
  PR. While no one is signed in to Windows, Looking Glass runs no display helper (its
  service starts the helper only with a signed-in user's token,
  `LGIddHelper/main.cpp:1806`), so Lanai's asks change the frame but not the sign-in
  screen's size, and small sign-in fields can be hard to read (`proofs.md`, "Resize
  hands-on, phase E", the signed-out case). Wanted: a privileged SYSTEM service in
  Windows that sets the Looking Glass display to the driver's stored size on the
  sign-in desktop. It is new security surface inside Windows (requirement 27), so it
  gets its own spec, plan and gates. Offer the same fix upstream first: the helper
  could run on the sign-in desktop as SYSTEM, as Looking Glass's capture host does.

- **Move the scale script into the start program.** John's call (2026-10-14):
  the scale script still loads in PowerShell 10 to 14 s after the sign-in, so
  scale work that starts at a sign-in has a 20 s bar (spec 12). Moving it into
  `lanai-start.cs` would bring that to about 7 s and drop the run-time
  `Add-Type`. About 1,000 lines of PowerShell; its own plan and gates.
  Measured on phase H's build (phase G, 2026-10-17): the program is up 7.4
  to 8.5 s after the sign-in and switches the resolution 0.2 s later, but
  the scale script opens its port 3.6 to 4.0 s after that and applies the
  scale at +12.7 to +13.3 s. John sees the resolution change as the desktop
  appears and the scale change seconds later. John's call (2026-10-17): on
  hold, not a major issue.

- **Rebuild the client by itself after a plugin update.** John's calls
  (2026-10-25): `omarchy plugin update` runs no plugin step (it pulls, validates
  and rescans), so Lanai acts when the panel reloads. It sees that the client's
  patch hash no longer matches and starts the rebuild in the background, with no
  click. When the Windows window is open, the panel says to close and open it
  again; Lanai never reopens it by itself. Patch 0003 shipped first, with the
  update button (v0.3.2).
- **Show VM updates in Windows, and cut the panel's status text.** John's call
  (2026-10-26): when Lanai updates something for Windows, show it the way Windows
  does, with an installer-style window in Windows that says what is happening.
  In the panel, replace the wall of status messages: it is hard to tell which are
  new and which were always there. At most, the panel shows an action button when
  Windows needs an update, or a status with a spinner while something happens to
  the VM. Open design questions for its spec: which work can show in Windows (the
  client rebuild runs on Linux, and Windows may be off), how Lanai would drive a
  window in Windows (requirement 27's trust limits apply), and which panel
  messages still need words.

## Follow-on: live scale (John, 2026-10-10)

This implements the spec amendment of 2026-10-10: reqs 2, 4, 6, 7, 9, 12 and 27,
"Out of scope for v1", and rows 4, 6, 7b, 12 and 22/25. It supersedes phase 7's
"Phase A: display scale" where they differ: the scale no longer waits for the next
start, and the guest no longer undoes every change made in Windows.

Branch `plugin/live-scale`. Phases run in order; each starts from the previous
phase's commit and is self-contained. Order: phase 0 parts (1)-(5), phase A,
phase B, phase 0 parts (6)-(7), phase C. Bash: `set -euo pipefail` in entry points,
callers' options kept in sourced libraries, clean under ShellCheck. Bash decides
the panel view; QML renders it. Tests first (bats; guest logic through pwsh where
it is installed, skipped in CI as today). Agents never touch John's live
`~/.windows` or `~/.local/state/lanai`; the proof and hands-on checks run on the
rehearsal copy (`~/lanai-proofs/lanai-setup-test`, where John's Lanai settings
already point).

### Design

**The channel.** One virtio-serial port, like the guest agent's:
`-chardev socket,id=scale0,path=$RUN/scale.sock,server=on,wait=off` and
`-device virtserialport,chardev=scale0,name=io.lanai.scale.0`, added in `vm_args`
(`lib/vm.sh`, which `vm_plan` calls) beside `qga0`. The socket is inside the 0700 runtime folder (req 25).
QEMU is the server and accepts one client. Messages are one ASCII line each:

    lanai-scale <step> <save>

`<step>` is a listed step (100 to 500); `<save>` is the save number, a decimal
integer below 10^9. Nothing else goes on the line (req 27). Windows' driver opens
ports only to SYSTEM and Administrators (`SDDL_DEVOBJ_SYS_ALL_ADM_ALL` in
virtio-win's `vioserial/sys/Port.c`), so the scale task runs elevated (req 27,
John's call).

**The save number.** `settings.json` gains `scale_save`, a non-negative integer
written in the same atomic write as `windows_scale`. `cmd_settings` (`lib/ui.sh`)
increments it on every scale save (three arguments, even when the step is
unchanged); two-argument saves keep it. A missing key counts as 0; a present but
invalid value refuses the save and the boot, as an invalid scale does today. The
guest treats any change of the number as a save (req 27), so even a lost counter
cannot strand a pick: the next save writes a number the guest has not seen.

**The boot record.** `boot_vm` already resolves the step and writes `boot.json`.
It also writes `scale_save` and the focused monitor's name (`boot_monitor`). This
reverses today's "no monitor reads for a fixed setting" (`lib/vm.sh`, and
`test/lifecycle.bats`' "every fixed step boots without querying a monitor"):
update both, and a failed monitor read never blocks a fixed boot (it leaves
`boot_monitor` empty). QEMU gets a second OEM string beside the first:
`-smbios type=11,value=lanai-scale=<step>,value=lanai-scale-save=<n>`. `vm_args`
gains the `<save>` argument, and so does `vm_plan` (`vm_plan <scale> <save>
<media> [<window>]`), which both `vm_exec` (reading `boot.json`) and `boot_vm`'s
dry run call; the existing `vm_args` calls in `test/vm.bats` gain it too; like every
other `vm_args` input it is checked (`^[0-9]{1,9}$`), since it lands in a
comma-separated value. The old task
matches only `lanai-scale=*`, so it keeps working unchanged.

**The feed (host).** A new supervised helper, `lanai-vm-helper scale-feed`, started
in `vm_exec` beside `event-log` (`supervise scale-feed ...`). It needs no shell or
panel, so following works with the panel closed and through shell restarts. The
user manager's environment may lack the session's (`lib/client.sh`), so `boot_vm`
writes `hyprland_instance_signature` into `boot.json` and the feed checks it
(`^[A-Za-z0-9_]+$`) and exports it before calling `hyprctl` (an empty or invalid
one is logged); a failing `hyprctl` is logged once, not silently. As built
(implementation review): `hypr_signature` uses the boot record's instance only if
it answers, else the inherited one if it answers, else the only live instance
(Hyprland leaves dead instance folders and sockets behind); while `hyprctl` keeps
failing, the feed looks again about every 30 s and logs only a changed instance.
Every 2 s, measured start to start (`LANAI_SCALE_INTERVAL`), with a 1 s timeout
on each `hyprctl` call, it:

1. Reads `settings.json` once and takes the setting and the save number from that
   one snapshot (a shared reader, `vm_scale_settings`, which replaced `vm_windows_scale`; `boot_vm` uses the same
   reader), so a save landing between reads cannot pair a new number with an old
   step.
2. Finds the client window in `hyprctl clients -j` by the client unit's MainPID
   (the pid `lanai open` focuses), maps its numeric `monitor` id to a name through
   `hyprctl monitors -j`, and records the name in `$RUN/scale-monitor` (on change
   only) whenever the window is open, whatever the setting, so a later switch to "match my
   monitor" knows the monitor since the VM started. `boot_vm` records the focused
   monitor's name (`boot_monitor`) for every boot, fixed or auto.
3. Computes the target. A fixed step is the target. For `"auto"`, the monitor that
   counts is the client window's monitor; with no window, the remembered monitor; with none
   remembered yet, `boot.json`'s `boot_monitor`. If that monitor is not in
   `hyprctl monitors -j`, the focused monitor counts; then the first one listed;
   with no monitors, the last target stays. The step is `scale_step` of that
   monitor's current scale (ties round down), so a scale change on the boot monitor
   or the remembered one is followed too. `vm_exec` deletes `$RUN/scale-monitor`
   at each start, so nothing carries over between VM runs.
4. Sends `lanai-scale <target> <save>` on every loop (every 2 s), changed or not.
   QEMU serves one client per QMP socket and all three are taken, so the feed
   cannot watch `VSERPORT_CHANGE`; the steady resend meets "the latest target
   whenever the task starts or reconnects" by construction. The backlog it builds
   while nobody reads is bounded by the socket buffers, and the guest's drain
   handles it (phase 0 (6)).

The feed keeps working while the shell or plugin is down (req 12, as amended).

Sending never blocks the loop. Each send is its own short connection:
`printf '\n%s\n' "$line" | timeout "$LANAI_SCALE_SEND_TIMEOUT" socat -u -
UNIX-CONNECT:$RUN/scale.sock` (deadline 1 s by default). It is one-way, never
`sock_open`, whose socat reads the socket. A send that misses the deadline is
killed; the next loop sends again. The leading newline ends any line a killed
send cut short, so the next line arrives whole; the guest ignores empty lines.
A failed send is logged once, and again only when sending recovers, so hours of
a signed-out guest do not flood the journal. The feed seeds its last target from
`boot.json`'s `scale`; if `settings.json` turns unreadable or invalid mid-run, it
keeps sending the last good line and logs once. Lines that were accepted but not yet read may still reach the guest later;
the guest makes that harmless by draining before it acts (below), and phase 0
proves it on the real channel. The feed never reads from the
socket; whatever the guest writes stays unread and is dropped when the connection
closes (req 27). Pure functions (target choice, line format) are unit-tested with
fixture `hyprctl` JSON; the loop is tested against a fake server that never reads.

**The scale task (guest).** `guest/lanai-scale.ps1` keeps its 2 s loop and its
`ScaleDecision` cap logic. Changes:

- Start: no `lanai-scale` OEM string means Lanai is not running this VM; exit at
  once and change nothing (req 4, as today). Otherwise the OEM step is the first
  target.
- A reader runspace opens `\\.\Global\io.lanai.scale.0` and loops on blocking
  reads, putting each complete line and its arrival time into a
  `ConcurrentQueue`. It keeps the handle open across the feed's connects and
  disconnects: a 0-byte read or a read error reads again after 250 ms, and the
  handle is reopened only when it is invalid or the open itself fails (retry every
  2 s). As built: only error 1450 (no host connected, phase 0 proof 3) reads again
  after 250 ms; any other read error closes the handle so the open runs again, and
  open and read errors are logged once each. The main loop never
  touches the port, so a silent port never blocks it. The main loop acts on the
  queue only once no line has arrived for 300 ms (a backlog arrives at full speed,
  so a quiet gap means it is drained), then dequeues everything. The feed sends
  one line per connection, so a fresh batch holds one valid line. A batch with
  more than one valid line is a stale backlog and is dropped whole: after a stall
  the port delivers its oldest unread lines, and lines sent while its buffer is
  full are lost (phase 0 proof 4). The next fresh line comes within one feed
  period. Empty lines are ignored; malformed ones are dropped (logged once).
- The main loop ticks every 250 ms, so the quiet gap is checked on its own
  clock, never only at a display poll. It observes the display every 2 s, and
  also on any tick that has a drained line to process.
- Each pass that processes a line, or observes the display, runs in this order: observe the display and detect a pick; then
  process the drained line; then apply. A save received in a pass therefore
  clears a pick seen in the same pass.
- State: `want` (the step from Lanai), `lastSave`, `pick` (null or a step). At
  start, `want` and `lastSave` come from the two OEM strings; the task waits for
  a first line before applying the OEM step, so a sign-in after a mid-run save
  does not change the scale twice. The wait ends at the first valid line, or one
  feed period plus the send deadline after the port opens (3 s by default), or 5 s
  after the task starts, whichever comes first; a port that never opens (an older
  host, or a failed open) still gets the OEM step within 5 s. As built: any
  arrival before the first line (a line waiting for its quiet gap, or a stale
  batch) moves the fallback to 2.5 s after it, so a fresh line applies alone
  and the boot step never flashes first. The OEM values
  give the baseline before any pick and before the channel connects. A line whose
  save number differs from `lastSave` is a scale save: set `want`, clear `pick`, set
  `lastSave`. A line with the same number updates `want` (a follow update) and
  keeps `pick`.
- Pick: the task keeps two values. `confirmed` is the last step it observed with
  the recommended step and resolution at that moment. `pending` is a step it asked
  Windows for and has not yet observed (null when none). On a poll, a current step
  equal to `pending` confirms it (`confirmed` = it, `pending` = null). A current
  step equal to `confirmed` while `pending` is set means Windows has not applied
  the request yet: not a pick; retry once a minute, as today. A current step that
  equals neither, with the same recommended step and a resolution unchanged for at
  least 5 s, is a pick: `pick` = it, `confirmed` = it, `pending` = null. A moved
  recommended step or resolution is never a pick; the task updates `confirmed` and
  reapplies the applied scale. A pick right after the task's own change counts,
  since that change is already in `confirmed`. As built (implementation review):
  the task reads the scale back right after each set and confirms it at once; it
  also keeps `requested`, every step asked for since the last confirmation, and a
  step in it is never a pick (an older request that lands late); a display change,
  a missing display, or a decision that needs no change drops an unapplied
  request.
- The first observation after the task starts, and the first after the Looking
  Glass display path appears or changes (`monitorDevicePath`), sets `confirmed`
  and is never a pick. A step that equals neither value, seen within 5 s of a
  resolution or display-path change, updates `confirmed` and reapplies; it never
  ripens into a pick later. Without a `lanai-scale-save` OEM string (a host older
  than this change), `lastSave` starts empty and the first line sets it without
  clearing anything.
- Target = `pick` if set, else `want`; applied = `ScaleDecision` cap of the target.
  The pick lives only in the task's memory, so sign-out, a Windows restart and a VM
  stop end it; at the next sign-in the feed's next line brings the latest target.

Because the task runs elevated, nothing it uses may be writable by the
non-elevated user. Before its first `Add-Type` or cmdlet, it sets
`$env:PSModulePath` to the system module folders (the user's
`Documents\WindowsPowerShell\Modules` would otherwise autoload first) and
`$env:TMP` and `$env:TEMP` to `C:\Program Files\Lanai\tmp` (PowerShell 5.1's
`Add-Type` compiles through files in the temp folder, then loads the DLL it built).
It logs to `C:\Program Files\Lanai\lanai-scale.log`. Both live in the folder
setup.cmd already creates elevated for the script, where standard users cannot
create anything and inherit read and execute only, so no ACL repair is needed (a
folder under ProgramData or `C:\` would race its ACL, as phase 6 found for
`C:\Lanai`). setup.cmd creates `tmp` there. The task action names
`%SystemRoot%\System32\WindowsPowerShell\v1.0\powershell.exe` by absolute path,
expanded when setup.cmd registers the task.
One residual stays, recorded for John: a highest-privileges sign-in task
runs with the user's environment variables (HKCU\Environment), a known UAC-bypass
class. For example, `COR_ENABLE_PROFILING` and `COR_PROFILER_PATH` there make the
elevated powershell.exe load a DLL at start, so the pins above stop an attacker
who can only write files (a planted module in a synced Documents folder), not
code already running as the user. With UAC on, as on John's install, malware already running as the user could
use it to gain admin; Microsoft does not treat UAC as a security boundary, and the
same malware has other ways to the same end. In PowerShell 5.1 a `FileStream` will
not open a `\\.\` device path, so the reader calls `CreateFile` through the
script's `Add-Type` block and wraps the handle; phase 0's script does the same.

`guest/setup.cmd` registers the task with `-RunLevel Highest` in its principal, under
the same name with `-Force`, so a rerun leaves exactly one task (req 9). The script
stays in `C:\Program Files\Lanai\` (administrator-only writes).

**The setup record.** In phase B, together with the new task. Step 6
(`setup_step6`, `lib/setup.sh`) already reads `query-chardev` and checks
`chardev_open qga0` and `vdagent`; it also checks `chardev_open scale0`, since only
the new elevated task opens that port. That is QEMU's port state, not data from
the guest (req 27). As built (implementation review): the task starts only at
sign-in, so the port is judged after the user answers the two step 6 questions
(they must be signed in to answer), not at the boot grace; until then the
questions ask a user with a password to sign in first. With both answers yes and
the port still closed after `LANAI_SETUP_SCALE_GRACE` (60 s, timed from the
answers kept in `$RUN/step6-answered`), setup goes back to step 5 with its own
reason, naming the task, the setup user and the task's log. `missing` keeps its
two items. When setup finishes (`setup_patch '{"done": true, ...}'`) with
the port open, it writes `"scale_task": 2`. A user who boots "Run setup again" and
shuts down without running setup.cmd therefore never gets the marker. A record
without it means the old task (req 12's last rule). (Superseded: the scale task's
port is awaited once the other checks pass, with no questions, for 120 s; see
"Follow-on: setup checks (John, 2026-10-17)".)

**Panel and words.** `cmd_settings` returns structured fields; `panel_words` turns
them into words (below), and for a scale save the CLI's own message says the same (a memory-and-cores save prints a full sentence where the panel shows "Saved."). `LanaiPanel.qml` tracks `scaleTouched` (set by the dropdown's
`changed`, cleared only when the panel opens, so every save in that panel session
counts as a scale save) and runs `settings <mem> <cores>` when
untouched, `settings <mem> <cores> <scale>` when touched. `lib/panel.sh` adds a note
under the scale list while Windows runs with the new task: "Saving a scale replaces
one you picked in Windows." The panel shows `result.settings`. Added in the
implementation (John's 2026-10-11 test): a click the model drops because another
action still runs shows "The last action is still running. Try again in a
moment." in a notice pinned over the panel's bottom edge for 2 to 5 s; before,
such a click (a scale save among them) vanished with no word. Today `panel_words` (`lib/panel.sh`) returns nothing for
a settings reply, and the Settings view hardcodes "Changes apply the next time
Windows starts." The reply gains structured fields (`scale_saved`, `running`,
`scale_task`; as built `scale_task_kind`, so it is not confused with the setup
record's `scale_task` 2), `panel_words` maps them to the words below, and the Settings view's
fixed line becomes "Memory and cores apply the next time Windows starts." The
settings words clear when the VM unit's invocation differs from the record's
(`ui_record` stores it), or once a running save's unit is no longer active (a
failed unit keeps its invocation), so "within 5 seconds" never outlives the run it
was about. The exact words below are as planned; the shipped ones were reworded in
review (`lib/panel.sh`):

- Scale save, VM running, new task: "Saved. Windows uses the new scale within 5
  seconds if you're signed in, or when you next sign in."
- Scale save, VM running, old task: "Saved. Windows uses the new scale the next time
  it starts. For changes while Windows runs, click Run setup again (it also turns the
  Windows lock off again). Until then, Windows undoes scale changes made in its own
  settings, and Match my monitor does not follow the window while Windows runs."
- VM stopped, or memory and cores only: "Saved. Changes apply the next time Windows
  starts." (memory and cores: "Memory and cores apply ..."). On an old install the
  stopped words add the Run setup again sentence too.
- While setup is unfinished (no marker yet, and none expected), every scale save
  uses the stopped words: the old-task words do not fit a first setup.

The words above are drafts; the phase A implementer has the taste bar (>= 7) and
may sharpen them, keeping each fact.

### Phase 0: channel proof (John and Claude, test copy)

Answer before building, and stop if (1) or (6) fails: (1) does an elevated process in the setup user's session
open `\\.\Global\io.lanai.scale.0`, and does a non-elevated one get access denied;
(2) do lines written to `scale.sock` arrive in order; (3) does a read with no host
client connected block, return 0 bytes, or fail; (4) with the guest not reading,
does a host write stall after the socket buffer fills, and after the host
reconnects does the guest receive the old unread lines or only new ones; (5) the feed's connection model: the host connects, writes one line and
disconnects every 2 s for 5 minutes; record each line's send and arrival times;
every line arrives within 1 s and none is lost, and the reader neither stalls nor
spins at each disconnect; (6) latest
only: with the guest paused (not reading), the host sends saves 1, 2 and 3 with
different steps, then reconnects and sends 3 again; when the guest resumes and
drains, the last line it acts on is save 3. Run it with the shipped feed command
and cadence, not hand-sent lines. If (4) shows QEMU delivering old unread lines
at the port's open, the first-line wait collects for at least one feed period plus
the send deadline and uses the last line. Run (6) with the phase B reader and
quiet-gap rule itself, and once more with a backlog of 10,000 lines (larger than
one read buffer); the task must never apply an earlier step first. (7) Flood: a
guest process writes to the port as fast as it can for 10 minutes while the feed
runs and John moves the window and saves twice; the panel, bar and following stay
responsive, and the resident memory of the feed, QEMU and the shell grows by no
more than 20 MB each. Phase 0 runs (6) and (7) after phase B's script exists, as
phase B's last step; (1)-(5) run first.

- Add `docs/plugin/proof-kit/proof-scale-port.ps1` (opens the port, prints each
  line with a timestamp, reports open errors) and a `--scale-port` flag to
  `proof-vm` that adds the chardev and port. Claude boots the test copy with it and
  drives the host side with `socat`; John runs the script in an elevated and a
  normal PowerShell. Record results in `proofs.md`.
- Results for (1)-(5), 2026-10-11 (`proofs.md`): all pass. The port was hotplugged
  into the running test copy over QMP instead of a `proof-vm` boot, so no reboot
  was needed. A read with no host connected fails at once with "Insufficient
  system resources" (error 1450), handled by the 250 ms retry above. Lines sent
  while no guest holds the port open are lost, and so are lines sent while its
  buffer is full; after a stall the guest gets the oldest unread lines, which is
  why a multi-line batch is dropped as stale.
- If (1) fails for the elevated process, stop and bring it to John (the SYSTEM
  relay he declined becomes the fallback). If (5) shows lost or late lines, stop
  and revise the connection model before phase A. (3) and (4) confirm the task's
  read handling above.

### Phase A: host and panel (TDD)

- Tests first: `test/ui.bats` (save number: three-argument saves increment, also
  for an unchanged step; two-argument saves do not; a missing key counts as 0; an
  invalid one refuses the save; the reply's structured fields for each case),
  `test/panel.bats` (`panel_words` for a live, stopped, memory-only and old-task
  save; the Settings view's line), `test/vm.bats` (the chardev and port in
  `vm_args`; socket path inside `$RUN`; a save argument holding a comma is
  refused), a new `test/scale-feed.bats` (target
  choice for fixed and auto across window present, closed with a remembered
  monitor, gone monitor, no focus, no monitors; line format; a resend every loop, changed or not;
  a fake server that never reads: with `LANAI_SCALE_INTERVAL` and `LANAI_SCALE_SEND_TIMEOUT`
  shortened for the test (a QEMU-like server queues later connects, so each send
  can take the whole deadline), the loop keeps its cadence and its RSS (from `/proc/<pid>/status`) stays
  within 2 MB over 1,000 sends (as built: 500 measured sends after a 50-send warm-up, bounded at 90 s so CI's 120 s limit never cuts it); a cut write followed by a full line; a flooding guest is never read; the boot monitor's scale
  change and unplug before the window opens; `scale-monitor` cleared between
  runs; the monitor recorded under a fixed setting counts after a switch to auto
  with the window closed; settings replaced between two reads cannot pair a new
  save number with an old step, because the feed reads once), `test/lifecycle.bats` (the helper is supervised and stops with the unit;
  `boot.json` carries the save number, boot monitor and Hyprland signature, and the
  second OEM string the save number; a fixed boot with a failing monitor read
  still boots),
  `test/panel.bats` (the note shows only while running with the new task),
  `test/panel-qml.bats` (an untouched list sends two arguments; choosing the shown
  entry sends three; two saves after one selection both send three; reopening
  clears the touch), and the old-task words name the lost following.
- Files: `lib/vm.sh` (`vm_args`, with the save argument and its check; `vm_exec`, whose stale-socket loop gains
  `scale`; `LANAI_HELPERS` gains `scale-feed` with its lost-function words, "the
  Windows scale does not follow saves or monitors"; the feed),
  `lib/lanai.sh` (`boot_vm`), `bin/lanai-vm-helper`, `lib/ui.sh`, `lib/panel.sh`,
  `LanaiPanel.qml` (the touched-list rule).
- Verify: `bats test spike/test` (TMPDIR under `$XDG_RUNTIME_DIR`), CI's ShellCheck
  line, `test/qml-lint`.

### Phase B: guest task and setup record (TDD where pwsh runs)

- Shape the script so its logic is pure and testable: `Step-ScaleState` takes the
  state, one display observation and the time, and returns the new state and an
  action (none, set a step, or retry); `Get-DrainedLine` takes the queued lines and
  the time and returns "wait", "stale" (more than one valid line) or the one
  valid line; `ConvertFrom-ScaleLine`
  parses one line. The main loop only wires them to the clock, the reader queue and
  `SetScale`.
- Tests first: `test/guest.bats` extracts those functions from `lanai-scale.ps1`
  through the PowerShell AST, as the StepName tests do: line parsing (valid,
  malformed, oversize, unlisted step, huge number), the save rule (greater, equal,
  lower, first line), the pick rule (each condition alone fails to make a pick;
  a recommended-step move is not a pick; the task's own set is not a pick), target
  and cap; the baseline from the OEM strings, with a pick before the channel
  connects and a save made in the meantime (the save clears it); a pick right
  after a host-driven change; an unobserved pick followed by a save in the same
  pass ends with the save applied; a drained batch of one valid line is used, a
  batch of two or more is dropped as stale (empty and malformed lines do not
  count), and a line that arrives inside the 300 ms gap delays acting; a resend every 2 s aligned
  just after each display poll is still processed within one tick of its gap; a
  set Windows accepts but does not apply is retried and never becomes a pick,
  while a real pick right after it still counts. Pin the task
  registration flags in `setup.cmd` (`-RunLevel Highest`, same name, `-Force`), the
  absolute powershell.exe path, the log and `tmp` paths under
  `C:\Program Files\Lanai\`, and that the script assigns `PSModulePath`, `TMP` and
  `TEMP` before its first `Add-Type`. A port that never opens still gets the OEM
  step within 5 s.
  `test/setup.bats`: `scale_task` written only when the new task opened its port:
  step 6 with `scale0` closed after the grace period
  reports the missing task and writes no marker; with it open, the marker is
  written (fake QMP). As built: a slow sign-in past the boot grace still asks, a
  closed task after the answers is waited for and then named, and the task opening
  after the answers finishes setup with its mark. (Superseded: no answers; see
  "Follow-on: setup checks (John, 2026-10-17)".)
- Files: `guest/lanai-scale.ps1`, `guest/setup.cmd`, `lib/setup.sh`, `README.md`
  (live scale, picks, custom scaling, apps that redraw only after restart, "Run
  setup again" for existing installs).
- Verify: the suites above.

### Phase C: hands-on (John, test copy)

Run setup again on the test copy, then walk row 12 on two monitors and row 4's
RDP check on the test install when phase 8 reaches it. Record results in
`proofs.md`. Phase 0's part (7) is the measured flood check; phase A's tests cover the
never-read feed. The hands-on adds the two-monitor, pick, cap, sign-out and
restart cases.

Results (2026-10-11): `proofs.md`, "Live-scale hands-on". All one-monitor cases
passed; the two-monitor cases and RDP wait. Three fixes follow (Phase D).

### Phase D: hands-on fixes (TDD where pwsh runs)

From the hands-on (John's calls, 2026-10-11). The README stays a user manual: none
of this goes into it.

1. **Cap line.** When Windows' range caps the target (target step above
   `maxIdx`), the task logs one line naming the target, the capped step and the
   resolution, for example "Windows allows at most 150% at 1901x1046; using 150%
   until the window grows (target 175%)." It logs whether or not a set follows,
   once per change of (target, capped step, resolution), and again only after a
   pass without a cap. Today a capped target that is already applied logs
   nothing.
2. **Custom scaling line.** When `curScaleRel` falls outside `minScaleRel` to
   `maxScaleRel`, the task logs once: "Windows reports the current scale out of
   range (curScaleRel <n>). Custom scaling is probably on (Settings > System >
   Display); Lanai's scale has no effect until it is off." Logged again only after
   a pass with an in-range value. Behavior stays as it is.
3. **Restart a dead task.** Task Scheduler's `RestartCount` covers a failed start
   only (hands-on). Give the sign-in trigger a 5-minute repetition with no end;
   `MultipleInstances IgnoreNew` already makes a start a no-op while the task
   runs, so a dead task comes back within 5 minutes. Drop `RestartCount` and
   `RestartInterval`, which do nothing here. A start that ends the same way as the
   run before must not grow the log every 5 minutes: the "No lanai-scale OEM
   string" exit and the "Error:" exit skip their line when the log's last line
   carries the same message.

- Tests first (`test/guest.bats`, pwsh): the cap line (capped and already
  applied, capped with a set, unchanged on the next pass, again after an uncapped
  pass, a new resolution); the custom scaling line (out of range once, quiet
  while it stays, again after an in-range pass; a value below `minScaleRel` counts);
  the repeated exit lines (the same message twice adds one line; a different one
  adds it). Pin the trigger's repetition in `setup.cmd` (5 minutes, no
  duration) and the absence of `RestartCount`.
- Files: `guest/lanai-scale.ps1`, `guest/setup.cmd`, `test/guest.bats`, this plan.
- Hands-on (John): Run setup again; `(Get-ScheduledTask -TaskName 'Lanai display
  scale').Triggers.Repetition` shows `PT5M` and no duration; a task killed with
  `Stop-Process` is back within 5 minutes and applies the latest save.
- As built: `Get-CapLine` (pure, through `ScaleDecision`) builds the cap line,
  and `Step-ScaleState` returns the uncapped `Target`. Only a pass that made a
  decision logs or clears the cap (`LoggedCap`); a pass before the first-line
  wait ends, or with no display, does neither.
- As built: `Write-RangeOnce` checks every display observation before
  `Step-ScaleState` runs, so the custom scaling line is logged even when that
  pass then fails. `minScaleRel` and `maxScaleRel` themselves are in range. A
  new out-of-range value does not log again; only an in-range one rearms it.
- As built: a pick must be a listed step (0 <= current < `$Steps.Count`).
  Before, an out-of-range current that moved at a settled resolution became a
  pick outside the list, and `ScaleDecision` threw on every pass until the
  next save.
- As built: `Write-ExitLog` compares the text after the timestamp on the log's
  last line, exactly. A skipped line still goes to the console, for a run by
  hand. An unreadable log counts as a different line.
- As built: setup.cmd builds the repetition as a client-only
  `MSFT_TaskRepetitionPattern` CIM instance with `Interval = 'PT5M'` and no
  `Duration` (Task Scheduler's schema: no duration repeats indefinitely). It
  does not copy the pattern from `New-ScheduledTaskTrigger -Once
  -RepetitionInterval`, since what that cmdlet writes for an omitted
  `-RepetitionDuration` has differed across Windows versions. Not yet run on
  Windows: the hands-on check above settles it.

### Routing

Phase 0: Claude with John. Phases A and B: an Opus 5.5 implementer in a worktree
(the step-up: concurrency in the feed and the pick rule; phase A also carries UI
words, which need taste >= 7). Claude verifies, signs, and runs the diff gate.

## Follow-on: resize (John, 2026-10-12)

This implements the spec amendment of 2026-10-12: req 12's size bullets ("Size"
through "An install whose client was built without the current patches"), the
scale bullet "A resolution change never changes the target", the patch mentions
in reqs 7 and 8, and row 12b. Where the spec is silent, the plan takes the
simplest design and says so.

Branch `plugin/resize`. Phases run in order; each starts from the previous
phase's commit and is self-contained. Bash: `set -euo pipefail` in entry
points, callers' options kept in sourced libraries, clean under ShellCheck.
Bash decides the panel view; QML renders it. Tests first in every code phase.
Agents never touch John's live `~/.windows`, `~/.local/state/lanai` or his
installed client; real builds go to scratch XDG folders, and the hands-on runs on
the rehearsal copy (`~/lanai-proofs/lanai-setup-test`).

### Design

**The bug.** The client sends the window size only when it changes
(`lastWindowSize` in `client/src/message.c`), and `core_onWindowSizeChanged`
(`client/src/core.c`) drops it when Windows' size already matches or the
transport is not ready. A display driver restart during Windows' boot starts a
new session at the driver's default size, and nothing sends the size again. A
size Windows changes on its own is never corrected either.

**Patches.** They live in `patches/looking-glass/`, named `NNNN-<topic>.patch`
and applied in name order (`LC_ALL=C`), each made with `diff -Naur` between a
pristine and a working copy of the pinned tree, so `-p1` strips the top folder.
Each starts with a short header: subject, what it changes and why, and
`SPDX-License-Identifier: GPL-2.0-or-later`. `patch` ignores the header, so no
header line may look like the start of a diff: none begins with `--- `, `+++ `,
`*** `, `diff `, `Index:` or `Prereq:`. Two patches:

- `0001-client-resize-module.patch` adds new files only: `client/src/resize.h`,
  `client/src/resize.c` and `client/tests/resize_test.c`. Because it creates
  files only, it applies to an empty folder, which is how CI tests it (below).
- `0002-client-resize-hooks.patch` wires the module in: `client/CMakeLists.txt`
  (adds `src/resize.c`), `client/src/core.c` and `core.h` (the glue),
  `client/src/main.c` (four one-line hooks), `client/tests/CMakeLists.txt`
  (the `resize-tests` target and its cases; every test target that compiles
  `../src/core.c` also compiles `../src/resize.c`) and
  `client/tests/config_message_test.c` (cases updated for the new send rule,
  plus glue cases).

`message.c` stays as it is: its filter forwards each change of the window size,
which is exactly the window trigger, and the module does every resend. The IDD
stays the pinned build. No KVMFR or LGMP message is added or changed; the glue
sends the same `LG_TRANSPORT_CONTROL_WINDOW_SIZE` control the client sends today.

**Exact apply.** `patches_apply <src> <log>` (`lib/client.sh`) runs, for each
patch, `LC_ALL=C patch -d <src> -p1 --forward --batch --fuzz=0
--no-backup-if-mismatch --reject-file=- -i <patch>` (`LC_ALL=C` keeps the
`Hunk` text English), appending its output to the build log. A patch
fails when `patch` exits non-zero, prints any line starting with `Hunk `, or
patches no file (no `patching file` line: GNU patch exits 0 on an empty file):
GNU patch 2.8 prints nothing per hunk for an exact apply, and `Hunk #n succeeded
at L (offset k lines).` for an offset (checked on 2026-10-12; `--fuzz=0` makes a
fuzzed hunk fail outright). A failure stops the build with "the Lanai patch
<name> does not apply exactly to Looking Glass <build>; see <log>". `patch` comes
with `base-devel`, already a host package.

**Identity and the stamp.** `patches_list` is the one list both use: the
basenames of the `[0-9][0-9][0-9][0-9]-*.patch` files in `LANAI_PATCHES`, found
with `nullglob` and sorted with `LC_ALL=C`. No folder or no match is an empty list, checked
explicitly, never left to fail under `pipefail`. `patches_apply` applies that
list in order. `patches_id` prints the hash of

    (cd "$LANAI_PATCHES" && sha256sum -- "${list[@]}") | sha256sum

or, for an empty list, the hash of empty input. It covers each patch's name,
order and content, so a patch whose content changed gets a new id. `COPYING` is
not part of it. From phase B on, an empty list is a build error ("Lanai's
Looking Glass patches are missing from <dir>; reinstall Lanai"), so a broken
install never stamps an unpatched client as current. The
build folder stays `<data>/looking-glass/<build>/`, and the client still reports
the pinned build, so `lg_same_build`, `build_select` and `builds_prune` (req 8's
same-build check) do not change. `build-stamp` does not change either. The
patch id goes in its own file beside it, `build-patches`, holding the id alone.

- `build_stamp_current` does not change, so an install from before this change
  still counts as the pinned build: setup stays finished and the window keeps
  working (req 12's upgrade rule).
- `build_patches_current` (new) is true only when `build-patches` holds
  `$(patches_id)`. A missing file is false.
- `build_client` returns early only when `build_patches_current` holds and the
  binary reports the pin. Today it writes a fresh stamp for any binary that
  reports the pin; without `build-patches` that path would mark an unpatched
  client as current, so it now needs the file too. Otherwise it
  rebuilds in this order: unpack, check submodules, start `build-client.log`
  once (`: >"$log"`), `patches_apply`, cmake configure (now `>>"$log"`, so the
  apply lines survive; `usb_audio_enabled` still reads the same log), build,
  install through `.partial` (the old folder, and its `build-patches`, go with
  it), then write `build-stamp` and `build-patches`, using the id it computed
  before applying.
- `LANAI_PATCHES` (default `$LANAI_LIB/../patches/looking-glass`) lets tests
  point at fixture patches. `patches_apply` resolves it to an absolute path and
  passes each patch to `-i` by absolute path, since GNU patch changes to `-d`'s
  folder before it opens the `-i` file.
- Rollback: a Lanai from before this change never reads `build-patches` and
  keeps the patched client, because its `build_client` stamps any binary that
  reports the pin. That is harmless (the client still matches the IDD) and
  silent; upgrading again finds `build-patches` still current.

**The module (`resize.c`).** Pure C: standard headers only, no `g_state`, no
transport, no clock. Its caller passes the time in microseconds, a `send`
callback (returns true when the ask went out) and a `log` callback. The state
struct is in the header, so the glue keeps one static instance. API (names are the
implementer's call):

    void resize_init   (ResizeState *, ResizeSendFn, ResizeLogFn, void * opaque);
    void resize_session(ResizeState *);  /* a new display session */
    void resize_window (ResizeState *, unsigned w, unsigned h, uint64_t now);
    void resize_frame  (ResizeState *, unsigned w, unsigned h, unsigned changes,
                        uint64_t now);
    void resize_update (ResizeState *, uint64_t now, bool responding);

State: the window size (kept across sessions; 0 until known), Windows' size and
whether a frame was seen (both cleared by `resize_session`), `asks` (0 to 5),
the time of the last ask (or none), and whether "did not take" was logged.
Rules, each from req 12:

- `resize_window` with a new size logs `Resize: window is <w>x<h>` and starts a
  new sequence (`asks` = 0, "did not take" cleared). The same size again does
  nothing. Under the floor (`w < 640 || h < 480`), the line reads `Resize:
  window is <w>x<h>, under 640x480, not asking`, and `resize_update` never asks
  while the window size stays there.
- `resize_session` clears Windows' size, the frame flag and the sequence, and
  forgets the last ask. The first `resize_frame` after it is the session's first
  frame: it records Windows' size and starts a new sequence.
- `changes` is how many format changes the frame thread accepted since the last
  call. A later `resize_frame` is a change of Windows' size when the size differs
  from the last one it saw, or when `changes` >= 2 (Windows left a size and came
  back between two polls). Two format changes that are not size changes (for
  example an HDR switch and back) also count; that is accepted, since it costs at
  most one ask sequence, bounded like any other. Within 60 s of the last ask it
  continues the sequence (`asks` and the last ask stay); otherwise it starts a
  new one. A call at the same size with `changes` < 2 is no change. Phase 0 saw
  most resizes show a short-lived frame of another size 50-100 ms before the
  asked one, so one taken ask often reaches here as `changes` = 2; Windows then
  matches the window, so nothing is asked.
- `resize_update` asks when all hold: a frame was seen this session, the window
  size is known, Windows' size differs from it, `responding` is true, `asks` < 5,
  and either `asks` is 0 or `now` >= last ask + wait, where the wait after ask
  1, 2, 3 and 4 is 2, 5, 10 and 20 s (phase E; it was 5, 10, 20 and 40 s). An
  ask sends the window size as it is now, so a newer size replaces a waiting
  one. When `send` returns true: `asks`++,
  last ask = now, and it logs `Resize: asking Windows for <w>x<h> (<n> of 5)`.
  When it returns false, nothing counts and the next update tries again.
- A match (Windows' size equals the window's) asks nothing. It does not clear
  the sequence, so a change within 60 s of the last ask still continues it.
- With `asks` = 5, Windows still different, and `now` >= last ask + 5 s, it logs
  `Resize: Windows did not take <w>x<h>` once for that sequence. The spec's "5
  seconds after its last ask" is read as after the fifth ask; a sequence that a
  trigger replaces earlier logs nothing.

So a sequence asks at most 5 times, at 0, 2, 7, 17 and 37 s when Windows never
answers with the size, and a Windows that keeps leaving the size cannot cause a
loop.

**The glue (`core.c`, patch 0002).** It owns the static state, one control token
and one `atomic_uint_least64_t` that holds Windows' size and a count of accepted
format changes together, as `w << 48 | h << 32 | count` (size 0: no frame this
session). One value means the main thread always reads a size with its own count,
and a size that changes and changes back between two polls still moves the
count. Only the frame thread writes it; the count wraps, and the main thread uses
the difference modulo 2^32.

- `core_resizeInit()`: called once in `main()`, beside `lgMessage_init()`.
- `core_resizeSession()`: called at the `restart:` label of `lg_run`, which
  runs before the first connect and after every host restart. The frame thread
  is stopped there (not yet started, or stopped by `core_stopVideoThreads`
  before `goto restart`), so storing 0 races with no writer. It stores 0, sets
  the main thread's last-polled count to the same 0, forgets the token and calls
  `resize_session`. The window opening, Windows starting or restarting and the
  driver restarting each come through here (phase 0 confirms the last two).
- `core_resizeFrame(w, h)`: called in `main_frameThread` in the
  `if (formatChanged)` block that sets `g_state.formatValid = true` (about line
  1655), after the frame is accepted and queued, with `rendererFormat.screenWidth`
  and `screenHeight`, the size the old code compared through `srcSize`. It stores the
  new size with the count plus 1, in one store. The first frame of a session always changes the format, since
  `lgInit` clears `formatValid`.
- `core_onWindowSizeChanged(w, h)`: now only calls
  `resize_window(..., microtime())`, with no transport check, so no size is lost
  while Windows is away.
- `core_resizeUpdate()`: called in the main loop beside
  `frameScheduler_update()`, about every 100 ms and only while the session is
  valid. It loads the value once and, when the count moved since its last poll,
  calls `resize_frame` with that size and the difference as `changes`.
  `responding` is true when the transport handle is set, the session has
  `LG_TRANSPORT_FEATURE_WINDOW_SIZE`, and there is no token or
  `controlStatus(token)` returns `LG_TRANSPORT_OK` (the IDD read the last ask), as
  `frame_scheduler.c` does, and no failed send happened in the last second. Then
  it calls `resize_update`. Its `send` callback calls `sendControl` and keeps the
  token on `LG_TRANSPORT_OK`. On another status it warns once until a send
  succeeds again (like `frame_scheduler.c`'s `enqueueFaulted`; no warning for
  `UNAVAILABLE`, as today) and sets the next try 1 s later, so a failing
  transport is not retried on every main-loop pass. Its `log` callback is
  `DEBUG_INFO("%s", line)`.

All module state is touched only on the main thread; the frame thread writes only
the atomic. "Shown a frame" means the frame thread accepted the session's first
frame and handed it to the renderer. Rotation is ignored, as in the old
comparison (Lanai never rotates).

**Tests of the C change.** Two layers, both in the patches, so an upstream offer
carries them:

- `resize_test.c` drives the pure module with a fake clock, a recording `send`
  and a recording `log`. It includes only `resize.h` and standard headers, with
  its own `CHECK`, so it builds without the rest of the tree. It runs one case by
  name, as Looking Glass's tests do, and lists its cases with `--list`.
- `config_message_test.c` (already a synthetic transport with a fake
  `clock_gettime`) gains `controlStatus` in its fake and covers the glue: no ask
  before a frame, one unread ask at a time, the token read, a session reset, and
  two format changes (away and back to the same size) between two polls after an
  exhausted sequence, more than 60 s after the last ask, starting a new sequence;
  and a size and count written between two polls reaching `resize_frame` together
  (the packed value, never a size with another write's count); one format change,
  a session reset, then the new session's first frame asks (the last-polled count
  was reset with the value); a failing send warns once over several polls, is
  tried again no sooner than 1 s later, and warns again only after a success.
  Its existing cases change where the rule changed: a send now waits for a frame,
  and a failed send is not counted.

`test/client-patches.bats` runs them:

- In CI and locally: point `LANAI_PATCHES` at a temp folder holding only 0001,
  apply it to an empty folder through `patches_apply`, build `resize.c` and
  `resize_test.c` with `cc -std=gnu11 -Wall -Wextra -Werror`, and run every case
  `--list` names. CI gains `gcc` and `patch` in its package line.
- Locally only, when `LANAI_TEST_LG_TARBALL` names the pinned source tarball (for
  example the one in `~/.cache/lanai/downloads/`): check its SHA-256 against
  `LG_SOURCE_SHA`, unpack it under the test's temp folder, apply every patch
  through `patches_apply` (each must apply exactly), configure with
  `-DENABLE_X11=no -DENABLE_TESTS=ON -DWESTON_EXECUTABLE=/usr/bin/true`, build the
  `resize-tests`, `config-message-tests` and `mouse-tests` targets (`mouse-tests`
  also compiles `core.c`), and run `ctest -R '^(resize|config-message|mouse)-'`.
  It also checks that `resize-tests --list` names the same cases as
  `RESIZE_CASES` in `client/tests/CMakeLists.txt`. `ENABLE_TESTS` needs GoogleTest
  (installed on John's machine) and looks for Weston, which only the render tests
  use, hence the stand-in. Checked on 2026-10-12 with the unpatched tree: configure
  passes, and both targets build and pass in seconds. Skipped in CI, which has
  neither the tarball nor the client's build dependencies, as the pwsh tests are
  today.

**Upgrade path.** A finished install whose stamp is the pin but whose patches are
not current keeps working: setup stays finished, `lanai start` and `lanai open`
use the installed client. `cmd_panel` computes `clientOld`: setup finished (the
plan's step 7, `$p.finished`), `build_stamp_current`, not `build_patches_current`, and `guest_version_behind`
empty. When `guest_version_behind` is not empty (an older pin's build is in use),
req 8's existing words ("The Windows display driver needs an update. Shut down
and continue setup.") are the one next step, and the resize warning stays hidden.
"The resize warning" names the new line; "the notice" stays the forced-stop
notice. The resize warning joins `.warning` on purpose, so it also shows in the
bar's tooltip, which `LanaiModel.qml` builds from `view.warning`.

- New scale task (`scale_task_kind` new): the panel shows the resize warning and a button,
  Update the Windows window, which runs `lanai build-client` as a panel job
  (`ui-job` and `ui-job-worker` accept `build-client`). `panel_group` maps it to
  a new `client` group (added to `panel_records`' groups), so an interrupted
  update never arms `$interruptedSetup` or Run setup again; it says "The update
  did not finish. Click Update the Windows window again." The failed and
  interrupted words show only while `clientOld` holds. While the job runs, its
  panel lock disables Start Windows, as any panel job does; the busy line says
  so. It works whether
  Windows runs or not, and changes nothing in Windows: no administrator prompt,
  no restart, no lock change. The running client keeps its open binary; the next
  `lanai open` runs the new one. The panel shows the done words until a client
  starts after the job's `ended` time (`client.log`'s first line holds the
  client's start epoch), so a success with the window closed still shows its
  words. `cmd_build_client` always ends with "If the Windows window is open,
  close it and open it again." Its failure next step names `build-client.log`,
  not "run setup again". Failure words name `build-client.log`, which joins the
  panel's logs block; `panel-job.log` holds nothing useful for it.
  `build_client_locked`'s rc 3 (another build running) replies with its own
  reason, `build-busy`, and its own panel words.
- Old scale task: the resize warning names Run setup again only, and no update button
  shows. `setup_plan`'s step 4 check becomes `! build_stamp_current || !
  build_patches_current`. The "done" check above it stays pin-only, so only a
  setup round (Run setup again, or a first setup) reaches step 4 and builds. Run
  setup again restarts Windows in step 5, so the Windows window that reopens runs
  the fixed client; its last message stays "Lanai setup is finished."

Draft words (the phase C implementer has the taste bar and may sharpen them,
keeping each fact):

- Resize warning, new task: "Windows may start at, or change to, the wrong size until
  you click Update the Windows window. This changes nothing in Windows."
- Resize warning, old task, varying on running state as `old_task_note` does: "Windows
  may start at, or change to, the wrong size until you click Run setup again."
  While Windows runs: "... until you shut Windows down and click Run setup
  again."
- Busy line: "Updating the Windows window. This may take several minutes. You
  can start Windows when it finishes. You can close this panel." (Superseded:
  the line drops "You can close this panel."; see redesign/stopped-copy.md.)
- Another build running (`build-busy`): "Another build is running. Try again
  when it finishes."
- Done (panel and `lanai build-client`): "The Windows window is updated. If the
  Windows window is open, close it and open it again."
- Interrupted: "The update did not finish. Click Update the Windows window
  again."
- Failed: "The Windows window could not be updated. Check the Windows window
  build log (build-client.log), then try again."

**Licensing.** `patches/looking-glass/COPYING` is the GPL-2.0 text, copied byte
for byte from the pinned tree's `LICENSE` (SHA-256
`8177f97513213526df2cf6184d8ff986c675afb514d4e68a404010521b880643`). The new
files in 0001 carry `Copyright (C) 2026 John Zetterman` with the usual
GPL-2.0-or-later notice text, not "The Looking Glass Authors". The README's
license paragraph says Lanai is MIT except the patches in
`patches/looking-glass/`, which carry Looking Glass's license, GPL-2.0-or-later,
with the text in `COPYING` beside them. `manifest.json`'s `license` becomes the
SPDX expression `MIT AND GPL-2.0-or-later`: the field is a free string (the
installed shell never reads it), and an SPDX expression is as close as it can say
"except". The root `LICENSE` stays the MIT text.

**Refused sizes.** The hands-on uses a floating window of 600x400 monitor pixels:
below Windows' 800x600 minimum and below the pinned IDD's own 640x480 mode floor.
The IDD keeps each ask in one `ExtraMode` registry value (`CSettings::SetExtraMode`,
`idd/LGIdd/config/CSettings.cpp` about 96-121), so a refused ask replaces the window's previous
mode. `LoadModes` then drops the 600x400 mode (`ParseModeString`'s floor, about
line 338), and the replug leaves only the default list, whose preferred mode is
1920x1080 (`DefaultPreferredDisplayMode`, `idd/LGCommon/DefaultDisplayModes.h:37`). Phase 0
(4) confirmed it: Windows moved to 1920x1080 (`proofs.md`, "Resize phase 0").
John's call: the client never asks for a size under the IDD's floor, 640 wide
or 480 high (`width < 640 || height < 480`, the same per-side test as
`CSettings.cpp:338`), so Windows keeps its size and the client scales the
picture into the window. Phase 0 found 640x480, 720x540 and 800x600 all taken
exactly, so the floor is the IDD's, not Windows' 800x600. Too large: the IDD's
`SetResolution` returns `TOO_LARGE` when the mode does not fit the frame memory
(128 MiB in `vm_args`; a 4K frame takes about 32 MiB of it;
`idd/LGIdd/display/CDisplayConfiguration.cpp:180`), and
`CDeviceContext::SetResolution` (`idd/LGIdd/display/CDeviceContext.cpp:490`)
sends `ResolutionRejected` to the helper (the Windows notice) and does not
replug. Reaching that needs a monitor well past 4K or a smaller
frame memory, a test-only change to the VM's hardware, so this case is checked by
review: the IDD path above, plus the client's generic refusal path, which the unit
tests cover (Windows' size never changes, so at most 5 asks and one "did not
take" line).

**The scale.** "A resolution change never changes the target" is already how the
scale task works (live scale's `ScaleDecision` caps per resolution on every 2 s
poll). No guest change is planned; row 12b's scale case checks it, and a failure
there gets its own fix phase.

### Phase 0: log proof (John and Claude, test copy)

With today's client, on the test copy: (1) resize the floating window three
times, one of them to an odd width, and once on a monitor with a fractional scale
(such as 1.5 or 1.25); (2) restart the Looking Glass display driver in Device
Manager; (3) disable it, wait 10 s, enable it; (4) on a monitor at scale 1,
float the window at 600x400 monitor pixels and wait a minute. Read `client.log`.
Pass: (1) gives a `Format:` line per size, each equal to round(`hyprctl` size ×
scale), the size the client asks for (`core_updatePositionInfo`, `core.c` about
459-466), and no `Waiting for the host to restart`; (2) and (3) each give `Waiting for the
host to restart`, then a new session's `Format:` line. (4) records the `Format:`
lines, any session restart, and the size Windows ends at; "Refused sizes" in
Design depends on it. Stop rules, each to John before phase B: (1) restarts the
session (an ask Windows refuses would then start a new session and a new
sequence every time); a (1) size is not that rounded size (the module would
never see a match; bring a tolerance or rounding rule); (2) or (3) does not
restart the session (the session hook would miss the driver restart); (4)
restarts the session (an endless ask loop otherwise); (4) ends with Windows at
another size than before (the spec wording, per "Refused sizes"). Row 12b's
1 px allowance applies only to phase D's evidence. Record results in
`proofs.md`.

### Phase A: exact apply, patch id and stamp (TDD)

- Tests first: `test/client.bats` with `LANAI_PATCHES` pointing at fixture
  patches built in the test (a two-file tree and patches made with `diff -Naur`):
  `patches_apply` applies an exact patch; an offset hunk, a fuzzed hunk, a failed
  hunk and an already-applied patch each fail and name the patch; order follows
  the names; a patch that only creates files applies to an empty folder.
  `patches_id`: stable for the same files; changes when a patch's content changes,
  when one is renamed, added or removed; ignores `COPYING`.
  `build_patches_current`: false for a missing `build-patches`, a stale id, or a
  missing binary; true for the current id. `patches_list`: basenames only; no
  folder and no match are empty lists without an error under `set -euo
  pipefail`. New `build_client` cases go in `test/client.bats` on its
  `lg_source` helper, which already makes a fixture tarball behind `curl` and
  `cmake` shims; `lg_source` also writes a fixture patch that applies exactly to
  its tree and points `LANAI_PATCHES` at it. Cases: an installed binary with a
  current `build-patches` needs no download; one without it rebuilds and writes
  `build-stamp` and `build-patches`; a patch that does not apply stops the build
  with its message and leaves no `.partial` or work folder; `build-client.log`
  keeps the apply lines and the configure output. `test/panel.bats`' "client
  stamp: an installed unstamped client takes a quick build check before setup
  continues" changes with the rule: an unstamped client without
  `build-patches` now rebuilds, so the case writes the current files first, or
  moves to `client.bats` on `lg_source`. A new `test/helpers.bash` helper writes
  the current `build-stamp` and `build-patches`; `test/setup.bats` uses it where
  it writes a one-line stamp today (about lines 607, 851 inside its
  `build_client` stub, and 1543). Wherever `build_stamp_current` is stubbed
  (`test/panel.bats`, `test/panel-jobs.bats`, `test/setup.bats`), stub
  `build_patches_current` beside it, true unless the case is about stale
  patches.
  `test/setup.bats`: a finished setup with stale patches still plans step 7; a
  setup round (`--no-window`) with stale patches plans step 4 `build`.
- Files: `lib/client.sh` (`LANAI_PATCHES`, `patches_list`, `patches_apply`,
  `patches_id`, `build_patches_current`, `build_client`), `lib/setup.sh` (step 4
  check), `lib/lanai.sh` (`setup_command`'s second-build message, about lines
1466-1468,
  fits a step 4 repeated for patches: "The Looking Glass client still is not
  built from $LG_BUILD with Lanai's current patches."), `test/helpers.bash`, `lib/pins.sh` (comment: on a pin change, the patches must apply
  exactly to the new source), `.github/workflows/test.yml` (`gcc patch`). The
  patches folder comes in phase B; until then `patches_id` hashes an empty list
  (no folder, or no patches, is the hash of empty input).
- Verify: `bats test spike/test` (TMPDIR under `$XDG_RUNTIME_DIR`), CI's
  ShellCheck line.

### Phase B: the client patches (TDD, C)

- Set up: a fresh worktree has an empty `spike/work/`. Get the verified tarball
  there: copy `~/.cache/lanai/downloads/looking-glass-$LG_BUILD-source.tar.gz`
  if it exists, else download it with `fetch_verified "$LG_SOURCE_URL" <dst>
  "$LG_SOURCE_SHA"` (sourcing `lib/lanai.sh`); either way check it with
  `verify_sha256`. Unpack it twice under `spike/work/` (pristine and working),
  and build only out of tree (`cmake -B` outside both), so `diff -Naur` picks up
  no build output. Each patch is made against the tree with the patches before it
  applied: write the three new files into working first and make 0001 with
  `diff -Naur pristine working` from their parent folder while working holds only
  those files as changes (or diff only those three files); then apply 0001 to
  pristine (exactly, as the build does), add the hooks in working, and make 0002
  the same way, so 0002 holds only the hook edits. Add the header to each. Check the
  pair by applying both, in order, to a fresh unpack.
- Tests first, in `resize_test.c`: no ask before a frame or before the window size
  is known; a first frame that differs asks at once, one that matches asks
  nothing; Windows never taking the size gives asks at 0, 2, 7, 17 and 37 s
  (phase E's times; phase B built 0, 5, 15, 35 and 75 s), "did not take" once
  at 42 s, then nothing for 10 minutes; a match stops the asks;
  `responding` false holds the ask and a later true sends it at once, with the next
  wait counted from that send; a window size that changes while an ask waits is
  the size sent, in one ask; a failed `send` is not counted; a new window size
  starts over (asks at once, 1 of 5); a window of 639x800 or 800x479 never asks
  and logs the "not asking" line once, 640x480 asks, and growing from under the
  floor to an allowed size asks at once; a session reset starts over at its first
  frame; the six-pick case from row 12b (asks 2, 5, 10 and 20 s apart, the sixth
  pick stays and logs "did not take"); a Windows change more than 60 s after the
  last ask starts over; the same frame size twice with `changes` < 2 is no
  change, and with `changes` >= 2 is a change; a sequence replaced before its
  fifth ask logs no "did not take"; log lines: one per new window size, one per
  ask with its size and number. In `config_message_test.c`: the glue sends
  nothing before `core_resizeFrame`; sends the window size after it; holds a
  second ask while `controlStatus` reports the token unread; sends it once read;
  `core_resizeSession` drops the token and waits for a new frame; features
  without `WINDOW_SIZE` or no handle sends nothing; plus every glue case in
  Design, "Tests of the C change". `test/client.bats` (on `lg_source`): with an
  empty `LANAI_PATCHES` folder, `build_client` fails with the missing-patches
  message and writes no `build-stamp` or `build-patches`.
- Then `test/client-patches.bats` as in Design (the CI case and the tarball case).
- Files: `patches/looking-glass/0001-client-resize-module.patch`,
  `patches/looking-glass/0002-client-resize-hooks.patch`,
  `patches/looking-glass/COPYING`, `lib/client.sh` (empty list is an error),
  `test/client-patches.bats`, `test/client.bats`, `.gitattributes`
  (`patches/** -text`, so git never rewrites a patch's bytes), `manifest.json`
  (license), `README.md` (license paragraph).
- Verify: `bats test spike/test`; `LANAI_TEST_LG_TARBALL=<tarball> bats
  test/client-patches.bats`; one real build into scratch folders
  (`XDG_DATA_HOME`, `XDG_CACHE_HOME` and `XDG_STATE_HOME` under `spike/work/`):
  `bin/lanai build-client` succeeds, `build-stamp` and `build-patches` are
  written, the binary reports
  the pin, and `build-client.log` shows each patch applied with no `Hunk ` line.

### Phase C: panel, upgrade words and README (TDD)

- Tests first: `test/panel.bats`: with `clientOld` and the new task, the resize
  warning (also in the tooltip text) and an enabled Update the Windows window
  button, while Windows runs and while stopped; with the old task, the resize
  warning names Run setup again and no update
  button shows; with an older pin's build in use, only req 8's words; with current
  patches or an unfinished setup, neither; while busy, the button shows disabled;
  the old-task resize warning while running and while stopped; `panel_words`
  for a `build-client` reply, ok, failed (the failure names `build-client.log`,
  and the logs block lists it) and `build-busy`; the done words show after a
  success with the window closed, and go once a client starts after the job's
  `ended` time; an
  interrupted `build-client` record shows the interrupted words and does not arm
  `$interruptedSetup` or Run setup again; the failed and interrupted words go once
  `clientOld` no longer holds; the busy line for a `build-client` job.
  `test/panel-jobs.bats`: `ui-job` and `ui-job-worker` accept `build-client`,
  record it in the `client` group, and refuse other commands as before.
  `test/panel-qml.bats`: the button runs `["build-client"]` as a long job; a
  Note shows `view.result.client`; the Logs list shows the build log line.
  `lanai build-client`'s CLI tests, in `test/client.bats` (about lines 876-895)
  and `test/setup.bats` (about line 1733): its last message, its failure next
  step, and the rc 3 reason.
- Files: `lib/panel.sh` (`clientOld`; the resize warning joins `.warning`; the
  button, words, busy line, the done words' client-start check; `client` in both group loops,
  `panel_records`' and `cmd_panel`'s `for group in vm setup settings snapshots`,
  about lines 92 and 135; a `build` key for `build-client.log` in the logs
  block), `lib/ui.sh` (job allow-lists, `panel_group`), `lib/lanai.sh`
  (`cmd_build_client` message, failure next step and rc 3 reason),
  `LanaiPanel.qml` (the button beside the resize warning;
  a Note for `view.result.client` in the top column, about lines 110-133, beside
  `result.vm`; `logs.build` in the Logs Repeater's model, about line 308),
  `README.md` (Daily use: Windows follows the window, and to change Windows'
  resolution, resize the window; for a window under 640x480 or a fullscreen too
  large for Windows' frame memory, Windows keeps its last size and the picture is
  scaled to fit, the too-large case may flicker or show a notice while Lanai asks,
  and resizing the window or leaving fullscreen fixes it; for installs from before this change, "Update the Windows window",
  which changes nothing in Windows, then close and reopen the window; or, when the
  panel names it instead, Run setup again, which restarts Windows as setup always
  does), `CLAUDE.md` (layout:
  `patches/looking-glass/`, `test/client-patches.bats`; Tests: `LANAI_TEST_LG_TARBALL`;
  rule: the client changes only through those patches, applied exactly), this plan.
- Verify: `bats test spike/test`, ShellCheck, `test/qml-lint`.
- As built: the button is `buttons.update_client`. `result.client` shows right under
  it, above the busy line, not beside `result.vm`, so the update's words sit with its
  button. The busy line drops "You can start Windows when it finishes." while
  Windows runs. `build-busy` reads "Another build of the Windows window is running.
  Try again when it finishes." `lanai build-client`'s success message is the done
  words; its failure next step names `build-client.log`. The README's "Known issue"
  paragraph about the boot resolution is gone.

### Phase D: hands-on (John, test copy)

Walk row 12b on the rehearsal copy and record it in `proofs.md`, "Resize
hands-on". Evidence: `client.log`'s `Resize:` and `Format:` lines (their times
count from the client's start, written on the log's first line) against
`hyprctl clients -j` size times the monitor's scale. Each `Resize: window is`
line lands at least 0.5 s after the real window event (`message.c`'s debounce).
Windows-side events (sign-in, picks, driver restarts) are made more than 60 s
after the last ask, so each starts a fresh sequence, except the quick picks in
(4), which test the continued one.

1. Upgrade first, while the old client is still installed (the real pre-fix
   case): the panel shows the resize warning and the button; start and open still work;
   click it: no Windows prompt, no restart, the last message says to close and
   reopen; reopen.
2. Session starts: a driver restart with the window open (the deterministic
   case), 10 starts from the bar, 3 starts from the bar after the window's size
   changed while Windows was off, a Windows restart (once with the window's
   size changed while Windows restarts), closing and reopening the window.
   Each matches within 5 s of the session's first frame.
3. During a session: sign-out and sign-in, tile, fullscreen and back, a resize, a
   move to a monitor with another scale. If no second monitor is set up, record
   the move as not run and bring it to John.
4. Picks: 5 resolutions picked in Display settings, each more than a minute after
   the last ask; then the 6 quick picks: the first more than 60 s after the last
   ask, and each later one after Windows has taken the previous ask and within
   60 s of it, kept with "Keep changes" (row 12b; phase E runs this case again).
5. Scale: 300% target, large window, driver restart.
6. Refusal: a floating window of 600x400 monitor pixels; the log names the size
   with "not asking" and shows no ask, Windows keeps its size and the scale holds
   for a minute; then resize to an allowed size, which matches within 5 s.
7. Driver disabled: no ask until enabled.
8. Repeatable upgrade fixture: add a word to 0002's header (the text before its
   first diff line, following the header rule in Design, "Patches"); the resize
   warning comes back; with an old scale task fixture
   (`scale_task` removed from the test copy's setup record), only Run setup again
   is named. Restore both after.
9. Patches review, recorded in `proofs.md`: the files 0001 and 0002 touch show no
   new `LG_TransportControl` type and no KVMFR or LGMP struct change; the IDD pin
   in `lib/pins.sh` is unchanged; `COPYING`'s SHA-256 matches the one in Design,
   "Licensing"; the README license paragraph and `manifest.json`'s license read
   as planned.

The too-large case is reviewed, not run (Design, "Refused sizes"). Fixes found
here get their own phase, planned from the results, before the diff gate closes.

### Phase E: first wait 2 s (TDD, C)

From the hands-on (John's call, 2026-10-13; `proofs.md`, "Resize hands-on").
Three starts from the bar after the window's size changed while Windows was off
each matched 5.8 s after the session's first frame, past the 5 s bar. After a
boot, Windows' display helper does not switch the desktop to the first ask's
size: Windows shows the smallest built-in mode that fits the old desktop
(1400x1050, 3840x2160 and 1600x1200 in the three starts) and stays there, and
the ask 5 s later works. The slowest switch after a taken ask was 1.26 s, so the
first wait becomes 2 s, not 1 s.

- `resizeWait` in `resize.c` becomes 2, 5, 10 and 20 s. The comments in
  `resize.c` and `resize.h` and 0001's header text that name the waits change to
  match. Nothing else changes: at most 5 asks, the 60 s continuation, and the
  5 s "did not take" wait after the fifth ask.
- Tests first, in `resize_test.c` (line numbers are 0001's). With only the
  waits changed, 8 of the 16 cases fail (review b found it by building them),
  so retime each one to the new schedule, comments included:
  - `never-takes`: asks at 0, 2, 7, 17 and 37 s, "did not take" once at 42 s.
  - `six-picks` (688-729): asks 2, 5, 10 and 20 s apart (`askAt` 0, 2, 7, 17,
    37); Windows takes each ask 0.5 s after it and the next pick lands 1 s
    after it (today 1 s and 3 s, which lands after the new 2 s wait), so every
    pick comes before its wait ends; "did not take" at t1+42 and the final run
    to t1+37+600.
  - `match-stops` (517): the match comes at 1 s, before ask 2 is due at 2 s.
  - `responding` (540-556): rebuild the hold-while-due part around asks at 0,
    2, 7, 17 and 37 s from the send.
  - `send-fails` (591-599): the next ask 2 s after the first.
  - `new-window` (609-619), `session` (681-684) and `replaced` (786-796): their
    counts and times follow the new schedule.
  - `late-change` (742-753), and 0002's `testResizeReturn`, still pass but
    drift far past the 60 s boundary; retime them to 61 s after the new
    last-ask times so they keep testing near it (in `late-change`, the check at
    746 moves with 742; the second boundary becomes T0+63+37+61).
  Then add two cases. The boot case: the first ask is answered at 0.5 s by a
  frame at another size (`changes` 1, no match), ask 2 goes out at 2 s, and a
  match then stops the asks; it fails against the old waits. The slow switch: a
  taken ask whose match arrives 1.3 s later sends no second ask; it already
  passes against the old waits and guards against a first wait under 1.3 s.
  Keep today's six-pick timing (take at +1 s, pick at +3 s) as a third case:
  each pick after the first lands after its wait ends, so its ask goes out at
  once with the next number, as row 12b expects for picks made by hand. Name
  cases with lowercase letters and hyphens only (for example `boot`,
  `slow-switch`, `late-picks`): `test/client-patches.bats` reads
  `RESIZE_CASES` with `[a-z-]*`. The other cases pass unchanged.
- Register the new cases in `RESIZE_CASES` (`client/tests/CMakeLists.txt`,
  patch 0002), since the tarball test checks that `resize-tests --list` names
  the same cases. Regenerate 0001 against the pinned source and 0002 against
  the tree with 0001 applied, as in phase B. Check the pair on a fresh unpack,
  and run `test/client-patches.bats` with `LANAI_TEST_LG_TARBALL`. The patch id
  changes, so the installed copy shows the update warning again.
- In 0002's `config_message_test.c`, `testControl` asserts that the ask after
  the first one of a sequence waits 5 s; make it 2 s, with its comment.
- Files: `patches/looking-glass/0001-client-resize-module.patch`,
  `0002-client-resize-hooks.patch` (the case list and `testControl`), this
  plan, `proofs.md`.
- Hands-on (John, test copy): click Update the Windows window, then reopen. 3
  starts from the bar, each after the window's size changed while Windows was
  off, to a smaller, a larger and a differently shaped size: each matches
  within 5 s of the session's first frame, with ask 2 about 2 s after ask 1
  when ask 1 does not take. Record each start's ask 2 time and match time.
  One Windows restart with the window's size changed while Windows restarts:
  it matches within 5 s of the session's first frame. A start that still
  misses 5 s goes to John, as in phase D.
  Then row 12b's full pick case, which phase D only partly ran: 5 picks in
  Display settings, each more than a minute after the last ask, each undone
  within 5 s; then 6 picks: the first more than a minute after the last ask,
  each later one after Windows has taken the previous ask (the size snapped
  back) and within 60 s of it, each kept with "Keep changes" before its
  countdown ends while no ask has undone it. Expected: ask 1 at once, and
  each later ask when its wait (2, 5, 10, 20 s) ends or at once for a pick
  made after that, so ask 5 comes at least 37 s after ask 1; the sixth pick
  gets no ask and its size holds for at least 60 s. A dialog frozen by an ask
  does not fail the case: minimize and restore Settings. Record in
  `proofs.md`, "Resize hands-on".
- As built: 10 of the 19 cases fail against the old waits (`never-takes`,
  `boot`, `responding`, `send-fails`, `new-window`, `session`, `six-picks`,
  `late-picks`, `late-change`, `replaced`), and so do 0002's `control` and
  `resize-return`. `match-stops` and `slow-switch` pass against both. Today's
  six-pick timing (take at +1 s, pick at +3 s) does not put each pick after
  its wait under the new waits: only the 2 s wait ends before +3 s. So
  `late-picks` keeps the take at +1 s and puts each later pick 1 s after its
  wait ends (picks at 0, 3, 9, 20 and 41 s, each asked at once with the next
  number; the sixth at 44 s, "did not take" at 46 s). `resize-return` asks 5
  times in 37 s, then its frames come 61 s after the last ask.

### Phase F: the sign-in step (TDD, PowerShell and bash)

From the phase E hands-on (spec amendment 3, John's call, 2026-10-13;
`proofs.md`, "Resize hands-on, phase E"). After a boot, Windows' display
helper cannot switch the desktop until the signed-in desktop is up (about
6.7 s after the first frame with automatic sign-in), and it gives up after 20
tries 100 ms apart. When the smallest built-in mode that fits the old desktop
is the window's size, ask 1's frame matches the window while the desktop keeps
the old size, and Lanai stops asking. A prototype logon task
(`docs/plugin/proof-kit/display-backstop.ps1`) fixed that case 4.6 s after the desktop came up. Phase
E's asks stay: on a normal start, ask 3 matches about 1 s after the desktop
comes up.

**Where.** In the scale task, `guest/lanai-scale.ps1`: no new task, no new
`setup.cmd` line (setup already copies the script to the administrator-only
`C:\Program Files\Lanai`, and requirements 7, 9 and 27 already cover the
task). The step runs after the OEM check, so under `omarchy-windows-vm` (no
`lanai-scale` string) the task still exits before it (requirement 4).

**When.** Once per sign-in. Windows rebuilds `HKCU\Volatile Environment` at
each sign-in and drops it at sign-out. On its first tick, inside the guarded
tick (never before the loop), the step reads the value `LanaiSigninStep`
there. Absent: it sets the value and runs. Present: this task start is not the
first since the sign-in (for example the 5-minute repetition after the task
exited), so it logs `Sign-in step: skipped (already ran since sign-in)` with
`Write-Log` and does nothing. So a resolution kept in Display settings after
Lanai's fifth ask is not undone mid-session. A failed read or write logs once
and skips. The step's first line also gives the time since the task started
and the process's start time (`Sign-in step: started`, with
`[Diagnostics.Process]::GetCurrentProcess().StartTime.ToString('o')`; the
loop's clock starts only after PowerShell's start-up, the C# compile and
`Get-CimInstance`), so phase G sees the task's full start delay.

**How.** Tick-driven inside the main loop, with no new thread: each pass of
the 250 ms loop calls `Invoke-SigninTick`, which acts at most every 500 ms
and does nothing once the step has ended. Like `Invoke-ScaleTick`, it changes
its context and returns nothing (pipe stray output to `Out-Null`), since
`Write-Log` writes to the output stream. Its state lives in a new field of
the context `New-ScaleContext` builds, and it takes `$Now` from the loop's
`$clock`, as `Invoke-ScaleTick` does. Each try reads `ExtraMode`
(`HKLM\SOFTWARE\LookingGlass\IDD`, written by the pinned driver as
`<w>x<h>@<refresh>[*]`) through `Get-StoredMode`, and the Looking Glass
display's current desktop through `Size`, then asks the pure function
`Get-SigninAction` what to do. The gate uses `Get-SigninMark` and
`Set-SigninMark`. Tests replace all four; the registry does not exist under
Linux pwsh. The wrappers use `[Microsoft.Win32.Registry]::CurrentUser` or
`::LocalMachine`, `.OpenSubKey(...)` and `.GetValue(...)`, which return
`$null` for a missing key or value: a missing value is `$null`, and only a
real error throws. (`Get-ItemPropertyValue` throws on a missing value under
`$ErrorActionPreference = 'Stop'`, which would make the gate skip every time
and turn "no stored size" into a 2-minute retry.)

| Input | Action |
|---|---|
| 120 s since the step started | stop: `gave up after 2 minutes`, with what it changed (nothing, or the switches) |
| `ExtraMode` missing or not `<w>x<h>@...` with w, h > 0 | stop: `no stored size; changed nothing` |
| no attached display whose `DeviceString` contains `Looking Glass` | wait; log `no Looking Glass display` once (a replug can hide it for a moment; the 2-minute stop ends it) |
| desktop equals the stored size | stop: `desktop <w>x<h> matches after <n> switches`, with the time since the step started (0 switches: it found the desktop already matched) |
| the last switch returned `DISP_CHANGE_BADMODE` (-2) for the size just read (the step keeps each switch's size with its result) | stop: `Windows does not support <w>x<h>`; a -2 for an older size does not count, and the step switches to the new one |
| 3 switches returned success (0) and each was followed, at least 2 s later, by a desktop that still differs | stop: `3 switches did not take` |
| a switch returned success less than 2 s ago | wait (the change is asynchronous; a switch took 1.26 s in phase D) |
| otherwise | switch to the stored size; log the desktop, the stored size and the result when that line differs from the last one |

A switch is `ChangeDisplaySettingsEx(<device>, mode, NULL, CDS_UPDATEREGISTRY,
NULL)` with only `DM_PELSWIDTH | DM_PELSHEIGHT` set on the current mode (the
helper also sets the frequency; the prototype's call without it worked).
Every result other than success and -2 retries.

`ExtraMode` is untrusted input: the IDD installer lets any interactive user
write that key (`LGIddInstall.c:407-412`). The only effect of a bad value is
a resolution change, which any user can make anyway. Still,
`ConvertFrom-ExtraMode` accepts only 1 to 5 ASCII digits per side, so an
overlong number is "no stored size", not an `[int]` overflow, and the step
logs the parsed size, never the raw value.

**Failures stay inside the step.** `Invoke-SigninTick` catches everything it
calls, `Write-Log` included. The display can vanish between `Find()` and
`Size()` or `Apply()` during a replug, and today the main loop's outer `catch`
ends the whole task, which would stop live scale until the 5-minute restart.
An exception counts as a failed try: the step logs it once per distinct
message (a failed log write is dropped) and retries until a stop rule ends
it. Nothing the step does ends the task.

**C#.** Add a class to the existing `Add-Type` block: `Find()` (the device
name, or null), `Size(device)` (`"<w>x<h>"` from `EnumDisplaySettings` with
`ENUM_CURRENT_SETTINGS`) and `Apply(device, w, h)` (the result code). Its
structs are public, so the size test can reach them. All struct handling
stays in C#: the prototype's
PowerShell `[ref]` struct calls to `EnumDisplayDevices` failed on the first
call. Use the prototype's struct layouts (`DISPLAY_DEVICE`, `DEVMODE`, 220
bytes), which worked on Windows 11 26200. Windows PowerShell 5.1 compiles C#
5 only: no `$"..."`, `out var`, `?.` or `nameof`. Linux pwsh accepts newer C#,
so a test compiles the block as C# 5 (below). A compile error before the
`try` would end the task at every sign-in with no log line.

**Log.** `Write-Log` already stamps each line with `Get-Date -Format o`
(sub-millisecond), which row 12b's timing needs. Every step line starts
`Sign-in step:`.

**Scale.** The switch changes the resolution, and the task's existing tick
already re-caps the applied scale on a resolution change (requirement 12's cap
rule). Nothing to add; phase G checks it.

**Script header.** Update the `.DESCRIPTION` comment of `lanai-scale.ps1` to
describe the sign-in step.

**Host side.**
- `lib/setup.sh`: step 6 records `signin_step: 1` beside `scale_task: 2`
  (the scale task now carries the sign-in step); the comment at the top names
  it. A separate key leaves `scale_task` and `scale_task_kind` as they are,
  so a Lanai from before this change still reads the record right (rollback:
  it shows no sign-in warning, as before).
- `lib/ui.sh`: a new `signin_step_missing` is true when setup is done, no
  round runs, and `signin_step` is not 1.
- `lib/panel.sh`, the resize warning: with the client old and the sign-in
  step present, today's words and the **Update the Windows window** button.
  With the sign-in step missing, one message that names **Run setup again** (with "shut Windows
  down and" while running, as today), says what it fixes (the wrong size
  after an update or a resize, when the client is old too; and staying at
  the old size after Windows starts until the window is resized), and says
  that it turns the Windows lock
  off again. No Update button then. Requirement 8's update message still
  replaces the warning. With the live-scale task old too (no mark), that one
  message also says what Run setup again fixes for the scale (from
  `old_task_note`), and the standing note under the scale list
  (`panel.sh`, `old) note=...`) is not shown, so the panel names Run setup
  again once (spec 12, the upgrade bullet). A scale save's reply keeps its
  words, `oldtask` included: it answers the save, and the live-scale bullet
  requires it.
- `README.md`, the resize section: after Windows starts, Lanai sets the size
  when the user who ran setup signs in; another Windows user may need to
  resize the window once; the upgrade step's words as the panel's. Also fix
  README:182-185 ("within 5 seconds", "also holds after Windows restarts":
  starts and restarts now match within 15 s of the sign-in) and README:236-238
  (the old-task note "under the scale list" moves into the warning).
- Fixtures: test fixtures that mean "a current install" (the uses of mark 2,
  found with `grep -n scale_task test/*.bats`, and the `state
  '{"done":true}'` uses in `panel.bats` that mean current) gain both
  `scale_task: 2` and `signin_step: 1`, since a step without the live task
  cannot happen; for example `panel.bats:1933-1935` asserts no warning
  with mark 2. Leave it out on purpose in `panel.bats:1922` ("older pin's
  build", the requirement 8 guard) and in the new missing-step cases. Rewrite
  `panel.bats:112-126` (the standing old-task note) for the new rule. When
  requirement 8's message replaces the warning, the note under the scale list
  shows again (it is then the only place that names the scale fix).

**Tests first.**
- `test/guest.bats` (pwsh, as the existing scale cases): `Get-SigninAction`
  for each table row; a stored size that changes between two calls makes the
  next switch use the new size, also right after a -2 for the old size; 2 switches that did not take still switch, the
  third stops; `ConvertFrom-ExtraMode` accepts `1600x1000@60*` and
  `1600x1000@59.94` and rejects empty, `x@60`, `0x0@60`, `1600x1000`, and
  non-ASCII digits, and more than 5 digits a side.
  Tick level, with `Get-StoredMode`, `Find`, `Size`, `Apply`,
  `Get-SigninMark`, `Set-SigninMark` and `Write-Log` replaced by fakes: the happy path (a
  switch, then a match, then a stop with no further `Find`, `Size` or `Apply`
  calls); the 500 ms pacing (two ticks 250 ms apart make one try); the stored
  size read again on each try; fakes that throw (the tick returns, the next
  tick retries, the 2-minute stop still ends it, and an `Invoke-ScaleTick`
  call after the throwing tick still runs); a repeated result (`Apply`
  returning -1) and a repeated exception each log once over many ticks; the
  gate (mark absent: sets it and runs; present: skips with its line; a
  throwing read or a throwing `Set-SigninMark` skips); `no Looking Glass
  display` logs once over many ticks. A static check that the wrappers use
  `[Microsoft.Win32.Registry]` and `.GetValue`, not `Get-ItemPropertyValue`.
- `test/guest.bats`, compile: pull the `Add-Type` here-string out of the
  script's AST and compile it with `Add-Type -TypeDefinition $src
  -CompilerOptions '-langversion:5'` (today's block passes; an interpolated
  string fails with CS8026); assert `Marshal.SizeOf` of `DEVMODE` (220) and
  `DISPLAY_DEVICE` (840). A static check that `Invoke-SigninTick` is called only in
  the main loop, after the OEM exit (requirement 4).
- `test/setup.bats`: a finished step 6 records `scale_task` 2 and
  `signin_step` 1.
- `test/ui.bats` or `test/panel.bats`: the warning for each case (client old
  with the step present, missing, or no mark at all; client current with the
  step missing or no mark; running and
  stopped), the Update button only with the client old and the step present,
  and the
  live-scale save messages unchanged with and without `signin_step`. With no
  mark (old task): the warning names Run setup again once with both fixes, the standing
  note under the scale list is absent, and a scale save's reply still carries
  `oldtask`.

- Files: `guest/lanai-scale.ps1`, `lib/setup.sh`, `lib/ui.sh`,
  `lib/panel.sh`, `README.md`, `test/guest.bats`, `test/setup.bats`,
  `test/ui.bats`, `test/panel.bats`.
- Verify: the focused bats files, then `bats test spike/test` with a short
  `TMPDIR` and `LANAI_TEST_BTRFS_DIR` (CLAUDE.md); CI's ShellCheck line; the
  C# 5 compile case. The pwsh cases, the compile included, skip in CI and
  must run locally. A `-langversion:5` compile does not catch APIs found only
  in .NET Core, so keep the C# to .NET Framework 4.x APIs, as the prototype
  does. Then the diff gate.
- As built (2026-10-13): 827 tests, 0 failed, 3 skipped (no pinned tarball,
  no strace, no comma-decimal locale); ShellCheck clean; the C# compiles as C#
  5 (`DEVMODE` 220, `DISPLAY_DEVICE` 840). Choices the table left open: a
  throwing read is a "wait, log `error: <msg>` once" row after the 2-minute
  row; "3 switches did not take" counts successful switches at least 2 s old
  whose size is not the desktop now; the match line counts every `Apply`
  call; `Set-SigninMark` throws (and the step skips) when `HKCU\Volatile
  Environment` is missing, since a key Lanai made would not be volatile; the
  sign-in warning also needs a finished setup plan, like `clientOld`, so a
  pending update step (requirement 8 included) shows only its own step and
  the old-task note returns under the scale list. Phase G's tools are in the
  proof kit: `stamp-client-log`, `size-window-on-open`, `clock-ping` and
  `pong.ps1`.

### Phase G: hands-on (John and Claude, test copy)

Paused after step 2's first three starts (2026-10-14): phase F's step loaded
too slowly at sign-in and showed a window (`proofs.md`, "Resize hands-on,
phase G"). It resumes from step 1 on phase H's build, with these changes:
the step's log is `C:\Program Files\Lanai\lanai-signin.log`; step 1 upgrades
from phase F's record (`signin_step` 1), so the warning shows first; then Run
setup again once more on that build, so the rename meets a running program
(spec row 9), and after the restart the new program runs (the running
`lanai-start` process's path ends in `lanai-start.exe`, not `old-<n>`, and
that file's last write time is after the rerun); at every timed sign-in John
also confirms that no window appeared, and more than 10 minutes after one
sign-in Claude has John list the scale task's processes (one
`lanai-start.exe`, one `powershell.exe` running `lanai-scale.ps1`, and the
hidden `conhost.exe` under it, which has no window); the start delay comes
from the `Start program: started` line; step 5's plain sign-out and sign-in
(no resize, no ask) takes its evidence from the client log (no new frame size
since before the sign-out) plus the step's `matches after 0 switches` line,
since the program's own start delay can put that line more than 5 s after
the sign-in; the record ends at `signin_step` 2; step
3's scale check counts from the later of 5 s after the switch and 20 s after
the sign-in (spec 12); step 8's guard review reads `lanai-start.cs`. Also, by
fixture (spec row 7b): make Windows refuse to start
`C:\Program Files\Lanai\lanai-start.exe` on the test copy, then Run setup
again: setup stops at step 6 with the blocked-program message; remove the
fixture and run setup again. The fixture is an Image File Execution Options
`Debugger` value for `lanai-start.exe` that names a missing file (every start
then fails, as a policy block does); if that does not stop the start, an
AppLocker executable deny rule (with AppIDSvc running); if neither works,
record that and review the check instead. Before resuming, John removes the probe
tasks in an admin PowerShell: `powershell -NoProfile -ExecutionPolicy Bypass
-File <share>\lanai-proof\probe-exe.ps1 -Remove` (a scratch probe in the
share, not in the proof kit). The process list: `$all = Get-CimInstance
Win32_Process; $s = $all | Where-Object { $_.CommandLine -like
'*lanai-scale.ps1*' }; $all | Where-Object { $_.Name -like 'lanai-start*' -or
$s.ProcessId -contains $_.ProcessId -or ($_.Name -eq 'conhost.exe' -and
$s.ProcessId -contains $_.ParentProcessId) } | Select-Object ProcessId,
ParentProcessId, Name, CommandLine` (the admin PowerShell it runs in is not
listed, and a running `lanai-start.old-<n>.exe` is).

Before it: Claude confirms that the installed Lanai's storage location (from
`lanai status` or the panel) is the rehearsal copy, not `~/.windows`, and
stops otherwise; phase G boots Windows about 20 times and reruns setup. John
runs `powershell -NoProfile -ExecutionPolicy Bypass -File
C:\ProgramData\LanaiProof\display-backstop.ps1 -Remove` in an admin
PowerShell, so only Lanai's step runs. The client log's times count from a start time in
whole seconds, which is too coarse. Claude writes three proof-kit tools
before phase G and commits them: `stamp-client-log` (`tail -F` the client
log and prefix each line with the host's `date +%FT%T.%N%:z` as it arrives),
`size-window-on-open` (step 3: float the Looking Glass window and set its
exact size as soon as it appears, before the first frame), and
`pong.ps1` (the guest side of the clock exchange below, so John runs a file
rather than typing a loop: `powershell -NoProfile -ExecutionPolicy Bypass
-File <share>\lanai-proof\pong.ps1`). Claude keeps the stamper's output per case. Each timed case starts its clock at the later of the session's first frame
and the sign-in, which is the first `Using Clipboard: LGMP` line after the
display session starts, or after the clipboard last fell back to SPICE (spec
row 12b); both times are recorded. It reads the match time from the scale task's
log (`C:\Program Files\Lanai\lanai-scale.log`; John pastes it). Offset, by a two-way exchange through the share: in each timed case, after
the desktop is up, John starts a PowerShell loop that waits for each new line
in `<share>\lanai-proof\ping.txt` (polling every 10 ms) and writes it back to
`pong.txt` with `Get-Date -Format o` appended. Claude writes 10 pings, each
with its number, noting the host time T1 as it writes and T2 as the matching
pong lands. For each, the offset is the guest time minus (T1 + T2) / 2, bounded
by plus or minus (T2 - T1) / 2; Claude uses the sample with the smallest bound
and records the offset and the bound. A case whose result is within that bound
(plus 0.1 s for the stamper) of its bar (15 s, or 5 s for the scale cap
and the plain sign-in) is run again; a rerun that also lands within the bound
goes to John. A `matches after 0
switches` line counts as matched no later than its time.

1. Update the installed plugin to the branch. The panel shows the Run setup
   again message (the setup record has no `signin_step`). Check its words and
   the lock note. Run setup again; the record then has `signin_step` 1, the
   warning is gone, and
   the Windows lock is off again.
2. 10 starts from the bar with the window's size unchanged, then 3 after the
   window's size changed while Windows was off (smaller, larger, another
   shape). Each matches within 15 s of the sign-in, by the scale task's log,
   and John confirms the size in Display settings. Phase D's 10 starts were
   judged by frames only, so they do not count here.
3. The made stuck case, on a start from the bar and on a restart. Claude first
   sets the floating window to an old size A, mid-session, and Windows
   matches. Then, while Windows is off or restarting, Claude sets the window to
   B: A fits inside B, and B is no larger than the smallest built-in mode that
   A fits inside (the phase E pair: A 1594x990, B 1600x1000). On the start from the bar, Claude's
   script floats and sizes the window as it appears, before the first frame.
   Expected: one ask, a frame at B, the step's switch, matched within 15 s of
   the sign-in. On the start from the bar, John sets a scale target that A
   caps lower than B, and the applied scale moves from the cap at A to the
   cap at B within 5 s of the switch; record the scale task's ready time
   (its first channel line) beside the switch time. Claude picks A and B before phase G,
   from the driver's built-in modes (`LGCommon/DefaultDisplayModes.h`) and
   Windows' Scale list at each size. If the built-in modes leave no such pair,
   that check goes to John before phase G, not a weaker check.
4. Automatic sign-in off: John sets `AutoAdminLogon` to `0` under
   `HKLM\SOFTWARE\Microsoft\Windows NT\CurrentVersion\Winlogon` in an admin
   PowerShell, and back to `1` at the end. Two starts from the bar: one after
   the window changed to B (with the desktop at A), one after it changed to
   another size. John signs in only after the client's log shows Lanai's asks
   ended. Each matches within 15 s of the sign-in.
5. Resize at the sign-in screen after a sign-out (the phase E case): the
   client's log shows at most 5 asks and one "did not take" line before the
   sign-in, and Windows matches within 15 s of the sign-in, by the scale
   task's log, which shows `Sign-in step: started`, not `skipped`. Also a
   plain sign-out
   and sign-in with no resize and no ask at the sign-in screen: matched within
   5 s of the sign-in (row 12b's "during a display session"), by the scale
   task's log.
6. Restarts from the Start menu: one with the window unchanged and one with
   the window resized while Windows restarts (an ordinary size, not the made
   stuck pair). Each matches within 15 s of the later of the sign-in and the
   first frame, by the scale task's log.
7. Driver disabled across a sign-in. With `-vga none`, a disabled display
   driver leaves no picture, so: John disables the Looking Glass display
   driver in Device Manager, shuts Windows down from the panel (the shutdown
   request needs no picture), and starts it from the bar, so automatic
   sign-in is the sign-in. After 2 minutes he shuts down from the panel again
   and re-enables the driver from a session with a picture on the test copy
   itself: `docs/plugin/proof-kit/proof-vm` on the rehearsal copy (it refuses
   `~/.windows`), through its RDP or display (Claude checks `proof-vm help`
   first), then Device Manager and the scale task's log. Never
   `omarchy-windows-vm`: it boots the live `~/.windows`. Expected in the log: `no
   Looking Glass display`, then `gave up after 2 minutes`, changed nothing.
8. Guard review: Claude reads the built `lanai-scale.ps1` against the table
   (no other display, no stored size, the size read again at each try, the
   early stops, the 2-minute limit, the logon-age gate) and records it in
   `proofs.md`, as phase D did for its patches.
9. Phase E's open case: the full pick case of row 12b (5 slow picks, then 6
   quick picks kept with "Keep changes"; ask 5 at least 37 s after ask 1; the
   sixth pick stays for at least 60 s). Run it in a session whose sign-in
   step logged `matches`, so frames count as evidence again (spec 12): not
   after step 7.

In every timed boot case (steps 2 to 6), John also confirms the final size
in Display settings. A start that misses 15 s goes to John. Record each step in `proofs.md`, "Resize
hands-on, phase G". If the cold-start stuck case takes more than about 12 s,
bring the 15 s bar back to John (spec review log).

Done (2026-10-17) on phase H's build `de0273b`: steps 1 to 9, the row 7b
fixture and the 10-minute process list all passed (`proofs.md`, "Resumed
on phase H's build"). The boot starts matched 5.1 to 7.9 s after the
sign-in, the stuck cases 9.3 s (start) and 8.2 s (restart). Step 3 used A
1434x894 and B 1440x900, since the phase E pair caps both sizes at 150%.
For a rerun of step 4: `AutoAdminLogon` 0 alone still signs in at boot
through Windows' automatic restart sign-on (turn off "Use my sign-in info
to automatically finish setting up after an update" too), and turning
automatic sign-in back on needs the password stored again (`netplwiz`).

### Phase H: the start program (TDD, C#, PowerShell and bash)

From phase G's first starts (spec amendment 4, John's call, 2026-10-14;
`proofs.md`, "Resize hands-on, phase G"). At sign-in, Windows PowerShell took
10.2 to 12.8 s to load in the scale task, so phase F's sign-in step first
checked the desktop 11.3 to 14.1 s after the sign-in, at or past the 15 s bar.
On the same boot a small C# program built with Windows' `csc.exe` reached its
code 6.7 s after the sign-in, and `cmd.exe` ran at 4.5 s. The task's console
window also showed until PowerShell loaded and hid it (`-WindowStyle Hidden`
acts only then). Phase G resumes from step 1 on this phase's build.

**What.** A small windowless program, `guest/lanai-start.cs`, that setup
builds into `C:\Program Files\Lanai\lanai-start.exe`. The scale task runs it,
with no arguments, instead of `powershell.exe`. Build it `/target:winexe`, so
Windows gives it no console. `Main` is one call: `return Run(args,
RealDeps())`. `Run(string[] args, Deps deps)` holds everything below, and its
whole body is one `try`; its `catch (Exception e)` logs `Start program:
error: <msg>` and returns 1. An unhandled exception would go to Windows Error
Reporting, which can show a "stopped working" dialog (a window, spec 7) and
keep the process, and so the job, alive while it collects a dump. No static
initializers and nothing else in `Main`: a type-load failure there would
escape the `try`. `Deps` holds delegates for the OEM read, the job, the
script start, the step, the wait and the log, so tests drive every path with
fakes. `Run`, in order:
1. With the one argument `/check`: return 0 at once, before any log or
   start. Setup's self-check (spec 7, row 7b): it changes nothing and starts
   nothing. Any other argument: return 2.
2. Requirement 4: read the SMBIOS table (below) and look for a type 11 string
   that starts with `lanai-scale=`, ignoring case
   (`StringComparison.OrdinalIgnoreCase`), as `Get-OemBaseline`'s `-like
   'lanai-scale=*'` does. The script keeps the only copy of the value's
   validation, so a malformed value still reaches the script, which throws on
   it as today.
   - Read and parsed, no such string: log `Start program: not Lanai's VM;
     changed nothing` and return 0, with no job, no script and no step, so
     under `omarchy-windows-vm` each task start ends within seconds (row 4),
     not after PowerShell's 10 s load. The 5-minute repetition would add a
     line each time, so this line follows `Write-ExitLog`'s rule: it is not
     written when the log's last line already carries it.
   - A failed read: log `Start program: error: <msg>`, skip the step (step 5),
     and still start the script (step 4); it reads the OEM strings itself and
     exits when they are not Lanai's.
3. Log `Start program: started <s> s after the process started at <time>`
   (`Process.GetCurrentProcess().StartTime.ToString("o")`), so phase G sees
   the start delay.
4. Make a job object, `CreateJobObject(IntPtr.Zero, null)`: no security
   attributes, so its handle is not inheritable (`Process.Start` with
   `UseShellExecute = false` passes inheritable handles to the child, and a
   script that held the job's handle would keep the job open after the
   program died). Set `JOB_OBJECT_LIMIT_KILL_ON_JOB_CLOSE` through
   `JOBOBJECT_EXTENDED_LIMIT_INFORMATION` (144 bytes on x64). Declare
   `CreateJobObject` to return `IntPtr`, store the handle in a static field
   and never close it: a `SafeHandle` held in a local could be finalized after
   its last use under `/optimize`, and closing the job's last handle would
   kill the program and the script at a random moment. Put the program itself in the job
   (`AssignProcessToJobObject(job, GetCurrentProcess())`; Windows 8 and later
   nest jobs, so this works inside Task Scheduler's own job). Only then start
   the scale script, which is born in the job: there is no moment when it
   runs outside it. `powershell.exe` by absolute path from
   `Environment.SystemDirectory` (`WindowsPowerShell\v1.0\powershell.exe`),
   arguments `-NoProfile -NonInteractive -ExecutionPolicy Bypass -File
   "<folder>\lanai-scale.ps1"` with `<folder>` the program's own folder
   (`AppDomain.CurrentDomain.BaseDirectory`), `UseShellExecute = false`,
   `CreateNoWindow = true` (Windows still gives the script a hidden
   `conhost.exe`, with no window). When the program ends for any reason, Task
   Scheduler's stop included, Windows closes the job's last handle and ends
   the script too, so a 5-minute repetition never finds a script without its
   program (spec 27, one copy). If the job cannot be made, set or joined, the
   program logs `Start program: error: <msg>`, starts no script, runs the
   step, and returns 1: an unprotected script could outlive a crashed
   program, and the 5-minute repetition tries again. A failed script start
   logs `Start program: error: <msg>`, the step still runs, and the program
   returns 1 after it.
5. Run the sign-in step (below) on the main thread.
6. Wait for the script to exit and return its exit code. The task lives as
   long as the script, so `IgnoreNew` and the 5-minute repetition work as
   today: if the script ends, the program ends; if the program ends, the job
   ends the script; either way the next repetition starts both.

**SMBIOS.** `GetSystemFirmwareTable(0x52534D42, 0, ...)` (the provider `'RSMB'`
as a big-endian number; `'BMSR'` is the wrong byte order), called once for the
size and once for the data. The parser is a pure function over the buffer it
returns, with three results: found, not found, failed read. First the 8-byte
`RawSMBIOSData` header (calling method, major, minor, DMI revision, then the
table's length as a 32-bit little-endian number); a buffer shorter than 8
bytes, or a length that runs past the buffer, is a failed read. Then, within
that length, walk each structure (type, length, handle): skip its formatted
area, read its strings up to the double NUL, and stop (not found, unless found
already) at type 127, at a length byte under 4, or at anything that runs past
the end. (WMI's `System.Management` does not compile under Linux pwsh, and the
WMI service is busy at sign-in.)

**The step.** Phase F's design moves to C# unchanged: the `HKCU\Volatile
Environment` gate (`LanaiSigninStep`), `ExtraMode` as untrusted input (1 to 5
ASCII digits a side), the decision table, the 500 ms pacing, the stop rules,
failures that stay inside each try (one log line per distinct message), and
every log line's words. After the gate passes, the step logs `Sign-in step:
started`; a skip logs `Sign-in step: skipped (already ran since sign-in)` as
today, so phase G step 5's check (`started`, not `skipped`) keeps its meaning.
A class `SigninStep` takes its inputs as delegates (read and set the mark,
read `ExtraMode`, `Find`, `Size`, `Apply`, the clock, the log), so tests drive
it with fakes; `Tick(now)` returns whether the step has ended. `RealDeps`
wires the real ones (`Microsoft.Win32.Registry`, the display calls from phase F's
`LanaiDesktop`, a `Stopwatch`); its step delegate calls `Tick` every 250 ms until it ends.
`RealDeps` only builds delegates: it opens no file or key, so `/check` still
changes nothing;
the 2-minute stop rule bounds it. Remove the step from `lanai-scale.ps1`:
`Invoke-SigninTick`, its helpers, the `LanaiDesktop` class, the `Signin`
context field; update the `.DESCRIPTION`. The script's own `Add-Type` stays:
it is built at run time under the same rules (spec 27), with `TMP` pinned, as
today.

**Log.** The program writes `C:\Program Files\Lanai\lanai-signin.log`, not the
script's log: two processes appending to one file can collide, and a failed
`Add-Content` ends the script. Same format: `DateTime.Now.ToString("o")`, a
space, the message. Open, append, close per line, `FileShare.Read`; a failed
write is dropped. The writer is a static function that takes the path, the
message and whether to skip a line equal to the last one (the not-Lanai
line's rule), so tests run it on a temp file.

**Setup (`guest/setup.cmd`).**
- The up-front checks (before any change, beside the SID, writability and
  media checks) gain the compiler: `csc.exe` in the folder that
  `[Runtime.InteropServices.RuntimeEnvironment]::GetRuntimeDirectory()`
  returns in Windows PowerShell (the .NET Framework 4.x that every Windows 10
  and 11 carries). Missing: refuse with a line that names the compiler and its
  path, before any change, through its own label that ends in `pause` and
  `exit /b 1`, as `:media_broken` does (spec 7, row 7b by review).
- Step 6, after the `:scale_task` label and before the task registration (a
  rerun jumps past the `tmp` folder's `mkdir` to that label, so anything
  before it would be skipped on every rerun): copy `lanai-start.cs`
  beside the script. Delete every `lanai-start.old-*.exe` (ignore failures:
  one may still run after a setup that stopped before its restart; this is
  the one change with no exit code check, so the exit-code test exempts it as
  it does the publisher trust line). If `lanai-start.exe` exists, rename it to
  `lanai-start.old-<n>.exe`, with `<n>` a fresh number (the time in ticks): on
  a rerun the old program still runs (the task started at sign-in), and
  Windows lets a running program be renamed but not replaced or deleted (spec
  row 9). The old one runs until setup's restart.
- Every new elevated PowerShell one-liner (the compiler check, the rename,
  the build, the self-check) first pins `$env:PSModulePath` to the system
  module folders, as `lanai-scale.ps1` does, or uses only .NET calls
  (`[IO.File]::Exists`, `[IO.File]::Move`, `[DateTime]::UtcNow.Ticks`):
  cmdlets autoload modules, and the elevated stage runs with the user's
  environment.
- Build, from a PowerShell one-liner like the task's: working folder
  `C:\Program Files\Lanai`; `TMP` and `TEMP` set to its `tmp`; `LIB` cleared
  (csc searches the working folder, then the framework folder, then `LIB`);
  `PATH` set to `[Environment]::SystemDirectory` only (the .NET Framework
  `csc.exe` is a native program that loads its DLLs from its own folder and
  System32, so this is belt and braces); the compiler by its full path;
  `/nologo /noconfig /target:winexe /optimize /r:System.dll
  /out:lanai-start.exe lanai-start.cs`. A failed build fails the step.
- The self-check, in the same kind of one-liner, with `$ErrorActionPreference
  = 'Stop'`: `try { $p = Start-Process -FilePath 'C:\Program
  Files\Lanai\lanai-start.exe' -ArgumentList '/check' -Wait -PassThru; if
  ($null -eq $p.ExitCode) { exit 1 }; exit $p.ExitCode } catch { exit 1 }`.
  Not `&`: PowerShell
  does not wait for a windows program and sets no `$LASTEXITCODE`, so the
  check would pass when it should fail. A blocked start throws. Non-zero
  fails the step; the message says that Windows blocked the program and what
  to change per cause: with an App Control or AppLocker policy, allow
  `C:\Program Files\Lanai\lanai-start.exe`; Smart App Control allows no
  single program, so it has to be turned off (Windows Security > App & browser
  control), which on many Windows versions only a reinstall undoes; then run
  setup again (spec 7). Check the words against the test copy's Windows build.
- The task's action becomes the program: `-Execute` with its full path in
  quotes (`[char]34`, as the script path is quoted today; an unquoted path
  with a space is CWE-428), no arguments. The rest of the registration stays.
- Comments say why each part is there.

**Host side.**
- `lib/setup.sh`: the setup media gain `lanai-start.cs`; step 6 records
  `signin_step: 2` (the form with the program). The header comment says to
  bump it with any change to `lanai-start.cs` that an install must pick up.
- `lib/ui.sh`: `signin_step_missing` is true unless `signin_step` is 2, so the
  test copy's phase F record shows the warning. Keep the current mark in one
  constant that both files read, so a bump touches one line. Panel words:
  unchanged.
- `README.md`:
  - the sign-in step's log is `lanai-signin.log`;
  - scale work that starts at a sign-in finishes within 20 s of it:
    README:221 ("or when you next sign in") and the pick paragraph
    (README:225-233); README:184's 5 s is the resolution and stays;
  - the symptom and fix when Windows blocks the program later (spec 7: the
    scale and the size at sign-in stop following; allow the program under App
    Control or AppLocker, or turn Smart App Control off, which on many Windows
    versions only a reinstall undoes; then Run setup again);
  - the security paragraph (README:284-289): the program, its source, the
    build and the logs sit in `C:\Program Files\Lanai`, where only
    administrators can write;
  - uninstall (README:357-366): `schtasks /End /TN "Lanai display scale"`
    before `schtasks /Delete` (ending the program ends the job, and the job
    ends the script; a running program would make `rmdir` fail), and "This
    removes..." names `lanai-start.exe`, `lanai-start.cs`, `lanai-signin.log`
    and any `lanai-start.old-*.exe`.
- Fixtures: `signin_step: 1` becomes 2 wherever it means current; a case with
  1 shows the warning.
- `CLAUDE.md`: `guest/` gains `lanai-start.cs`.

**Tests first.**
- `test/guest.bats` (pwsh): compile `lanai-start.cs` with `Add-Type
  -TypeDefinition (Get-Content -Raw ...) -CompilerOptions '-langversion:5'`
  (`Main` is not called); `Marshal.SizeOf` of `DEVMODE` 220,
  `DISPLAY_DEVICE` 840 and `JOBOBJECT_EXTENDED_LIMIT_INFORMATION` 144. Port
  phase F's `Get-SigninAction`, `ConvertFrom-ExtraMode` and tick cases to
  `SigninStep`, with the same expectations, the `Sign-in step: started` line
  after the gate included.
- The SMBIOS parser, on whole `RSMB` buffers (the 8-byte header, then the
  table): a type 11 `lanai-scale=100` string (found); `LANAI-SCALE=100`
  (found); `lanai-scale=x` (found: the script validates); a realistic table
  (type 0 and type 1 with strings, a structure with no strings, that is its
  formatted area then `00 00`, a type 11 with `lanai-scale-save=5` first and
  `lanai-scale=150` second, a second type 11, then type 127: found); other type 11
  strings only (not found); an empty table (not found); a buffer under 8
  bytes, and a header length past the buffer (failed read); a structure whose
  length runs past the end, a length byte under 4, a string set with no double
  NUL, and an end-of-table structure before a type 11 (no throw; not found).
- The log writer on a temp file: the format, the last-line rule (two equal
  lines with the rule leave one; without it, two), and an unwritable path
  dropped with no throw.
- The start order, through `Run` with fakes: `/check` returns 0 with no log
  and no other call; another argument returns 2; no OEM string returns 0 with no job, script or step, and two such
  starts leave one log line; a failed read starts the script and skips the
  step; a failed job starts no script, runs the step and returns 1; a failed
  script start runs the step and returns 1; the happy path joins the job, then
  starts the script, then runs the step, then waits; an exception in any fake
  is logged and returns 1.
- Static checks on `lanai-start.cs`: `Main` holds only `return Run(args,
  RealDeps())`; `Run`'s body is one `try` with a `catch (Exception`; `CreateNoWindow = true`, `UseShellExecute = false`,
  `KILL_ON_JOB_CLOSE`; `CreateJobObject(IntPtr.Zero, null)`; the program
  joins the job before `Process.Start`; `powershell.exe` from
  `Environment.SystemDirectory`; the script path from the program's folder;
  the provider `0x52534D42`; the job handle is an `IntPtr` in a static field,
  with no `SafeHandle` and no `CloseHandle` on it; no `using System.Linq` and
  no other assembly than `mscorlib` and `System.dll` (the Windows build has
  only `/r:System.dll`, while Linux pwsh references everything); the mark key
  opened with `OpenSubKey("Volatile Environment", true)`, never
  `CreateSubKey` (phase F's rule: a key Lanai made would not be volatile).
  On `lanai-scale.ps1`: no `Invoke-SigninTick` and
  no `LanaiDesktop`.
- `setup.cmd` (static, as the existing cases): the compiler check in the
  up-front checks, before the first change; in step 6, after `:scale_task`,
  the copy, the delete,
  the rename, the build (`/target:winexe`, `/noconfig`, the working folder,
  `TMP`, `TEMP`, `LIB`, `PATH`), the self-check as the exact `Start-Process
  ... -Wait -PassThru` one-liner with the null-exit-code guard, and no `&`
  call of `lanai-start.exe` (`-PassThru` then `WaitForExit()` can leave
  `ExitCode` null on Windows PowerShell 5.1, which would fail every setup), then the task with the quoted
  program path as its action; every change but the old-program delete
  followed by its exit code check; the media list includes `lanai-start.cs`.
- Existing tests that change (a cold session will meet them):
  `guest.bats:135` (every change has its exit code check) gains the rename,
  build and self-check in `CHANGE_RE`, its change count moves, and the delete
  gets an exemption; `guest.bats:1190` (the task's `powershell.exe` action) asserts
  the program instead; `guest.bats:1276-1517` (the sign-in step's
  PowerShell cases) and `guest.bats:1519` (its registry wrappers) move to the
  C# class; `guest.bats:1541` (the step's place in the main loop) goes; `guest.bats:1569` (the script's C# 5 compile with the `LanaiDesktop`
  sizes) keeps the compile and drops the sizes, which move to
  `lanai-start.cs`'s case.
- `test/setup.bats`: the media; step 6 records `signin_step` 2.
- `test/ui.bats` / `test/panel.bats`: `signin_step` 1 shows the warning, 2
  does not.

**Files.** `guest/lanai-start.cs` (new), `guest/lanai-scale.ps1`,
`guest/setup.cmd`, `lib/setup.sh`, `lib/ui.sh`, `README.md`, `CLAUDE.md`,
`test/guest.bats`, `test/setup.bats`, `test/ui.bats`, `test/panel.bats`.

**Verify.** As phase F, plus the C# 5 compile of `lanai-start.cs`. A Linux
compile does not catch an API found only in .NET Core: keep to .NET Framework
4.x APIs. Phase G's step 1 builds it in Windows. Row 4's checks under
`omarchy-windows-vm` (each task start ends within 10 seconds, no window, and
`lanai-signin.log` says `not Lanai's VM`) run on phase 8's **Test install**
(a separate machine or VM), as row 4 always has; never on John's host, where
`omarchy-windows-vm` boots the live `~/.windows`. Then the diff gate (with
phases A to F).

### Upstream offer (John)

After the hands-on passes, offer each patch to Looking Glass (github.com/gnif/
LookingGlass): one issue that shows the bug with the client log excerpt, and the
two patches rebased onto upstream's current `master` as a pull request, the
tests included. John posts it, or gives Claude a go to post it. Record the link
here. For the pull request, consider also dropping the `transportFeatures` gate in
`core_updatePositionInfo`, which posts the window size only once a session has
set the features. Lanai is unaffected: its VM runs `-vga none`, so no fallback
display shows frames before the session. If upstream takes an equivalent fix, the next pin that includes it drops
the patch.

Also offer, as issues with the phase E evidence (`proofs.md`, "Resize
hands-on, phase E"):
- The display helper drops a mode after 20 tries 100 ms apart
  (`CPipeClient.cpp`, `DisplayModeThread`), so after a boot it fails while the
  signed-in desktop is not yet up. Retrying until the desktop takes the mode,
  or again when the session's desktop becomes ready, would make Lanai's
  sign-in step unneeded; the next pin with that fix drops the step.
- The helper starts only with a signed-in user's token (`main.cpp`,
  `WTSQueryUserToken`), so no ask reaches the sign-in screen. Running it on the
  sign-in desktop as SYSTEM, as the capture host does, would cover the
  follow-on "Resize at the sign-in screen".

John's lock idea (offer only the window's size) is not offered yet. Its
prototype failed at a boot, the same way as the helper above, so it is not
proven to need a driver change. Retest it after phase G, with the sign-in
step in place; offer it upstream only if the retest shows it needs one.

### Risks

- Known gap: CI never applies the patches to the real pinned source (the
  tarball case runs only locally), so a pin bump that breaks 0002 shows only in
  a local run or a real build.
- The 15 s bar from sign-in: phase H's program reached its code 6.7 s after
  the sign-in on one boot (PowerShell took up to 12.8 s more). One sample;
  phase G's starts measure it.
- No test has yet nested a job inside Task Scheduler's job on this Windows
  (the probe program used no job). If joining fails, the program starts no
  script, and phase G step 1 shows `Start program: error` in
  `lanai-signin.log`.
- Smart App Control, an App Control or AppLocker policy, or Defender can
  block an unsigned program built in Windows. Setup's self-check catches it at
  setup; later, the README names the symptom and the fix.
- The sign-in step's switch and the script's scale ticks now run in two
  processes, so a scale set can race the switch; the script re-caps on its
  next observation, and phase G step 3 watches it.
- The sign-in step relies on where the pinned driver stores the ask
  (`ExtraMode`); a pin change rechecks it (spec 12).
- The gate's `HKCU\Volatile Environment` value is exported as an environment
  variable to the user's new processes (`LanaiSigninStep` shows in `set`), a
  small side effect beyond the resolution. If Windows kept the user's hive
  loaded across a quick sign-out and sign-in, the value would survive and the
  step would skip; the helper still applies the last ask after a sign-out
  (phase E), and phase G step 5 checks for `started`.
- The scale script still loads in PowerShell, 10 to 14 s after the sign-in,
  so scale work that starts at a sign-in has a 20 s bar (spec 12). Phase G
  records the script's ready time beside the step's switch.

### Routing

Phase 0: Claude with John. Phase A: the bulk implementer (gpt-6-luna, `codex
exec`) in a worktree: clear, mechanical bash. Phase B: the step-up (opus-5.5) in a
worktree: a state machine across two threads, and README license words. Phase C:
opus-5.5 in a worktree: panel and README words need taste >= 7. Claude verifies,
signs, and runs the diff gate. Phase D and the upstream offer: John. Phase E:
opus-5.5 in a worktree: eleven C test cases to retime with care, and both patches
regenerated and checked against the pinned source. Phase F: opus-5.5 in a
worktree: Windows display APIs through C# in PowerShell, pwsh tests, and
panel and README words that need taste >= 7. Phase H: opus-5.5 in a
worktree: Windows APIs in C# 5, a job object, the setup build, and README
words. Phase G: John with Claude.

## Follow-on: setup checks (John, 2026-10-17)

This implements the spec amendment of 2026-10-17: requirement 7's last bullet,
requirement 27's two additions (the refused guest-agent command and the IDD's
reported build) and row 7's closing clauses. Setup asks no question at its end.
It supersedes the earlier text about step 6's two questions where they differ:
lines 132, 918, 944-946, 1029, 1076, 1115-1130, 1211-1212, 1236-1240, 1261-1268,
1274-1298, 1316, 1364-1366, 1378, 1394, 1864, 1955-1958, 2028, 2361-2373 and
2522-2523 (as of `main` 7f24300). Phase B points each of them here.

### The design

**In Windows: setup.cmd.** Two changes:

- In step [4/8], `net stop VirtioFsSvc >nul 2>&1` is added before `pnputil`, so
  the driver update never meets a running service (dockur's, on a first setup).
  The stop before the copy in [5/8] stays, in case the service started again in
  between. Both results stay ignored.
- In step [5/8], after the service is set, setup.cmd prints "Checking that the
  shared folder from Linux appears in Windows (up to 30 seconds)...", starts the
  service (`net start VirtioFsSvc >nul 2>&1`, result ignored: the check covers
  it), then runs a new script from the setup drive,
  `guest/lanai-share-check.ps1`.

The script waits up to 30 s, polling every second, for a ready drive
(`IsReady` true; a drive that throws while being read counts as not matching)
that matches the share's identity: its drive type and file system name, which
phase 0 measures. It then lists the drive's root
(`Get-ChildItem -LiteralPath <root> -Force`), and on a failed listing keeps
trying each second until the deadline. Exit codes: 0 found and listed; 10 no
such drive in 30 s; 11 a matching drive appeared but never listed. A share that
hangs `IsReady` or the listing can hold the script past 30 s; Risks names it. PowerShell
itself exits 1 for a parse error, an unhandled exception or a blocked script,
so setup.cmd treats every code other than 0, 10 and 11 as "the check could not
run". The script ignores every other drive. The share's drive is mounted by a
LocalSystem service, so it lives in Windows' global namespace, which the user's
non-elevated session sees; phase 0 confirms it from a normal PowerShell.

A non-zero exit goes to a new stop, `:share_missing`, shaped like
`:start_blocked` (`echo.`, the words, `pause`, `exit /b 1`). Its words for code
10:

```
Lanai setup stopped: the shared folder from Linux did not appear in Windows
as a drive.
To fix this:
- Restart Windows from the Start menu. The setup drive stays attached.
- If setup stopped here before, shut Windows down from the Lanai panel
  instead, and choose a display there. Lanai then checks the folder on Linux.
Then run setup.cmd again.
```

(As built: the panel fallback moved into the steps, so the words end with
running setup.cmd again, as requirement 7 and this section require. The step
names the panel's buttons: "shut Windows down from the Lanai panel instead,
then click Set up in a basic window or Set up in the Windows window. Lanai then
checks the folder on Linux." setup.cmd calls `net` and `powershell` by their
bare names, like the lines around them: a bare name resolves from System32,
the elevated stage's working folder, while `%SystemRoot%` comes from the user's
environment.)

Code 11 says "appeared as a drive, but Windows could not read it". Any other code
says "Lanai setup stopped: the check for the shared folder could not run (exit
code N)" with the same steps. Phase A may tighten the words; they must say what
to do and end with running setup.cmd again. (A panel shutdown during the setup
boot leaves `step5` false, so the panel offers the two display buttons, and the
next setup boot runs `share_check` on Linux first.)

**Host: step 6 (`lib/setup.sh`, `setup_step6`).** It takes no answers. The checks
and their order stay: the pinned client's verdict on the IDD, the SPICE agent's
port, the guest agent (clock set, then the refused command), then the scale
task's port.

- **Time-outs stay at step 6.** A new `setup_stop6 <reason> <msg> [parts]`
  replaces `setup_back5` for every time-out. It replies `ok:false`, step `6`, with details `{reason, stop: "timeout"}`, plus
  `parts` (a list of names) for `agents`. Because the reply's step matches the
  plan's step 6, the panel shows its words (panel.sh:188-192 drops a failed
  reply whose step differs). The panel reads the stop from its setup job
  record, as it reads every result: `reply.stop`. Every step 6 `ok:false`
  reply, the time-outs and the other failures below alike, writes
  `$RUN/step6-stopped`, so the next Continue gets fresh limits.
- **Time-outs** keep `step5` true, so Continue setup checks
  again, and with Windows stopped takes the existing `normal-boot` path, which
  boots Windows first. Reasons, in the order step 6 reports them at the
  deadline: `qmp` (QMP never answered), `guest-boot` (the guest agent's port
  never opened), `window-closed` (the pinned client would not stay open; `client`
  keeps its meaning, "could not open"), `idd-missing`, `agents` (with `parts`:
  "the SPICE agent", "the QEMU guest agent"), then `scale-task` at its own limit.
  `next` is "continue setup to check again (lanai setup), or shut Windows down
  and run lanai setup --window or --no-window to repeat the Windows install".
  The pinned client open but its verdict still `unknown` or `waiting` at the
  deadline counts as `idd-missing`. A failed `query-chardev` past the deadline
  stops as `qmp` only when the call before it also failed
  (`$RUN/step6-qmp-failed`, touched on a failure and removed on a success),
  since the panel's status shares QEMU's one client socket. Every time-out
  message ends with "If Windows' setup window
  stopped with a message, follow it first." The scale task's also says "If
  Windows is at its sign-in screen, or another user is signed in, sign in as
  the Windows user who ran setup first." (As built: at step 6 the setup drive
  is not attached, so setup.cmd cannot run again from there. Every CLI
  time-out message ends "If setup.cmd stopped with a message in Windows, shut
  Windows down and repeat the Windows install." The scale task's adds, before
  it: "It starts at sign-in: if Windows is at its sign-in screen, or another
  user is signed in, sign in as the Windows user who ran setup. If it still
  does not start, see lanai-signin.log and lanai-scale.log in C:\Program
  Files\Lanai.")
- **Wrong answers stop at once and repeat the install,** through the existing
  `setup_back5`, unchanged: it clears `step5` and replies step 5, so the plan
  moves to `5 problem no-media` while Windows runs and `5 setup-boot` once it is
  off, and Continue setup then repeats the Windows install. Reasons: `mismatch`
  (the IDD build differs from `LG_BUILD`; requirement 8's words, as today) and a
  new `allowlist` (the guest agent answered the refused command with anything
  but its `CommandNotFound ... has been disabled` reply). Its panel words: "The
  QEMU guest agent in Windows is missing its allow-list. Shut down and set up
  Windows again." (As built: `allowlist` and `mismatch` end "Shut Windows down,
  then click Continue setup to set up Windows again.", as the README says.)
  The existing old-driver words (panel.sh:365, lanai.sh:951)
  stay true. To tell a wrong answer from no answer, `qga_reply` in `refusal` mode
  returns 2 for a well-formed reply that is not the refusal and 1 for no reply,
  as now. The command stays `{"execute":"guest-exec"}` with no arguments:
  without a path it runs nothing, even when an agent accepts it (requirement
  27).
- **Other step 6 failures** keep their current replies and buttons: "XDG_RUNTIME_DIR
  is not set" (setup.sh:336), "could not open the Windows window" (setup.sh:371,
  no reason), "cannot record its setup state" (setup.sh:457) and normal-boot's
  client failure (lanai.sh:1511, reason `client`).
- **Time limits.** Two limits, each counted from a record in `$RUN`.
  `LANAI_SETUP_LIMIT` (300 s) covers every check before the scale task, from
  `step6-since`: the check boot's start, which `vm_exec` writes when the VM
  starts, or a Continue after a stop. A step 6 check that finds no stamp, or
  one that is not a number, writes one. Each write goes to a temporary file,
  then `mv`, like the other stamps. `LANAI_SETUP_SCALE_LIMIT` (120 s) covers the
  scale task's port, from `step6-checked`, which step 6 writes the first time
  the other checks pass. Once `step6-checked` exists, step 6 skips the earlier
  checks and the 300 s limit and waits only for the scale task's port. So a
  short-lived fault while the user signs in cannot stop setup with the wrong
  reason, and a Windows that restarts in a loop after the checks pass stops at
  the scale limit. A Windows restart (QMP `RESET`) resets nothing. Port state
  starts or resets no timer: the `qga-open-since` and `qga-closed-since`
  stamps, `LANAI_SETUP_GRACE` and `LANAI_SETUP_BOOT_LIMIT` go. The old worst
  case was about 360 s (300 s for the port, then 60 s of grace); phase G's
  boots reached the sign-in within about 30 s of the client's start, so 300 s
  from the boot leaves room, and phase C records each step 6 boot's time. Every
  waiting path checks the limit, the failed `query-chardev` path included.
  While it waits, the reply and the panel say: "Waiting for the display scale
  task. It starts when the Windows user who ran setup signs in. If Windows asks
  for a password, sign in within 2 minutes."

  As built (diff gate, simplified on John's call of 2026-10-18): step 6 keeps
  four records, owned by `lib/setup.sh`: `step6-since` and `step6-checked`
  (one epoch each), and the `step6-stopped` and `step6-qmp-failed` markers.
  `step6_start` writes `step6-since` and removes the other three; `vm_exec`
  calls it at the VM's start, and step 6 for a Continue after a stop.
  `step6_checked` reads `step6-checked` for `setup_plan`'s `scale_wait` and for
  step 6 alike. `lib/vm.sh` names no step 6 file, and `event_record` ignores a
  `RESET`. A record that cannot be written stops step 6 with reason `record`:
  a stamp, Continue's reset, the `step6-qmp-failed` marker (so a QMP that never
  answers cannot wait forever) and the `step6-stopped` marker (its failure
  replies `record` instead of the original stop). `vm_exec` prints a `lanai:`
  line when its write fails, and the VM does not start. The time-out order
  stays: `qmp`, `guest-boot`, `window-closed`, `idd-missing`, `agents`, then
  `scale-task`. Diff-gate rounds 1 to 3 had made a restart start the checks
  again, with a boot token, an outer limit of 3 x `LANAI_SETUP_LIMIT` and a
  restart wait; the simplification removed them. Risks names its costs.
- **Continue setup gets fresh limits.** A step 6 `lanai setup` call without
  `--follow` that finds `$RUN/step6-stopped` removes it, `step6-checked` and
  `step6-qmp-failed` and rewrites `step6-since` before it checks, so each limit
  counts again from the click. Without a stop, a call leaves the records alone,
  so a command-line user who runs `lanai setup` again and again still meets the
  limits. With Windows stopped, Continue boots it, and the VM start stamps the
  new boot.
- **Removed:** `step6-asked`, `step6-answered`, the questions reply, and
  `--share-ok`/`--scale-ok` in `lib/lanai.sh` (the panel is the only caller, and it
  ships with the CLI). `setup_plan` drops its `questions` decision; its
  `scale_wait` comes from `step6-checked`. `event_record`'s RESET cleanup
  (`lib/vm.sh`) goes: a RESET touches no step 6 record. `vm_exec`'s start
  cleanup covers the new files and writes `step6-since`.

**Panel (`lib/panel.sh`, `LanaiPanel.qml`, `lib/ui.sh`).**

- Remove `share_question`, `scale_question`, `questions`, the `answer_yes`,
  `answer_no` and `send_answers` controls, and `shareAnswer`/`scaleAnswer` with
  their questions block.
- A step 6 time-out needs attention and shows its words, built from the reason
  (the reasons table) and, for `agents`, from `parts`, so the panel names what
  did not answer. New or changed words: `qmp`, `guest-boot`, `window-closed`,
  `idd-missing`, `agents`, `scale-task` (time-outs, at step 6) and `allowlist`
  (at step 5, beside `mismatch`). Drafts (phase B may tighten them):
  - `qmp`: "Lanai could not reach Windows' virtual machine to check it."
  - `guest-boot`: "Windows did not finish starting, or its guest agent did not
    start."
  - `window-closed`: "The Windows window kept closing, so Lanai could not check
    the display driver."
  - `idd-missing`: "The display driver in Windows did not answer."
  - `agents`: "In Windows, <parts joined with "and"> did not answer."
  - `scale-task`: "The display scale task in Windows did not start. It starts
    when the Windows user who ran setup signs in. If Windows is at its sign-in
    screen, or another user is signed in, sign in as that user first."

  Every time-out's words then add "If Windows' setup window stopped with a
  message, follow it first." and end "Continue setup checks again. To install
  Lanai's parts in Windows again, shut Windows down and choose a display
  below." So the panel itself carries both of the spec's conditions. Delete the
  `answers` words. (As built: every time-out's words end "Click Continue setup
  to check again. If setup.cmd stopped with a message in Windows, or to install
  Lanai's parts in Windows again, shut Windows down, then click Set up in a
  basic window or Set up in the Windows window." The setup drive is not
  attached at step 6, so a setup.cmd that stopped is run again through the
  display buttons. The words show under the buttons, so they name them.
  `window-closed` says "The Windows window did not stay open long enough to
  check the display driver.", as the CLI does. The scale task's words: "The
  display scale task in Windows did not start. It starts at sign-in: if Windows
  is at its sign-in screen, or another user is signed in, sign in as the
  Windows user who ran setup. If it still does not start, see lanai-signin.log
  and lanai-scale.log in C:\Program Files\Lanai.")
- `continue_setup` keeps its current rules and label.
- At a step 6 time-out (the setup job record's `reply.stop` is `timeout`, its
  step 6 matching the plan) with Windows off, the panel also shows the two
  display buttons (`window`, `no_window`) directly, under a new view field,
  `setup.repeat_line`, shown as a Note in LanaiPanel.qml: "Or install Lanai's
  parts in Windows again: choose how Windows should show." They send `setup
  --window` or `setup --no-window`, which makes `setup_plan` take `5
  setup-boot` (setup.sh:530). No arming step: `setupAgainArmed` stays for a
  finished setup only. (As built: no `repeat_line`; the time-out's words name
  the buttons.)
- The job worker (`lib/ui.sh`) follows step 6 while replies are `ok:true`; drop
  its "no questions" condition.

**README.** Replace "In File Explorer, select This PC ... Answer that question
and whether text looks the right size." (README.md:115-117) with what the user
now sees: setup checks itself; the scale task starts at sign-in; a stop names
what failed. **Continue setup** checks again. To install Lanai's parts in
Windows again, shut Windows down and click **Set up in a basic window** or **Set
up in the Windows window**. When the panel says Windows' driver or guest agent
is wrong, shut Windows down and click **Continue setup**, which sets Windows up
again. After "Use Shut down only if setup.cmd stops responding."
(README.md:112), add one sentence: if setup.cmd stops because the shared folder
did not appear, restart Windows and run setup.cmd again. (As built: Shut down
from the panel is also for when the share check says so; the README covers
the check's three stops (the folder did not appear, Windows could not read it,
the check could not run) and the panel buttons that follow. Its time-out words
match the panel's, and an unfinished setup boot shows both display buttons.)

### Phase 0: share identity and first install (John and Claude, test copy)

The test copy must be running and set up. Claude sends no QMP command beyond
`query-status` and `query-chardev` (experimental `x-` commands once aborted QEMU).

1. In a normal PowerShell, then an admin one, John runs
   `[IO.DriveInfo]::GetDrives() | Where-Object IsReady | Format-Table Name, DriveType, DriveFormat, VolumeLabel`
   and, in the normal one, `Get-ChildItem Z:\ | Select-Object -First 3` (with
   the share's letter). Record the share's line in both, and that the normal
   session lists it. If the normal session does not see or list the share,
   stop: the visibility design needs John.
2. In the admin PowerShell:
   `net stop VirtioFsSvc; $t = Get-Date; net start VirtioFsSvc; while (-not (Test-Path Z:\) -and ((Get-Date) - $t).TotalSeconds -lt 60) { Start-Sleep -Milliseconds 100 }; ((Get-Date) - $t).TotalSeconds`.
   Record the seconds; the 30 s wait must be at least 5 times that.
3. `net stop VirtioFsSvc`, run step 1's command again, and confirm the share's
   line is gone; then `net start VirtioFsSvc`.
4. First install: Claude confirms that Lanai's storage is the test copy, then
   makes a fresh reflink copy of the test copy's pre-setup snapshot (`lanai
   snapshots` names it). The image must never have run setup.cmd: no `C:\Program
   Files\Lanai`, with dockur's own virtio-fs driver and service. If no such
   image exists, stop for John. Claude boots it with `proof-vm run <copy>
   --share <scratch dir> --setup <media>`, where `<media>` is a scratch copy of the folder Lanai builds its
   setup drive from (`$XDG_STATE_HOME/lanai/setup-media`). In an admin prompt,
   John runs the steps in the new order: [3/8]'s WinFsp install, `net stop
   VirtioFsSvc`, [4/8]'s `pnputil`, [5/8]'s copy and service set, then `net
   start VirtioFsSvc`, step 1's command and `Get-ChildItem` on the share. Record
   whether the share appears and lists without a restart, and `pnputil`'s exit
   code. If it needs a restart, stop: the in-setup check needs John's call
   before phase A.

Record the results in `proofs.md` ("Setup checks, phase 0"). The drive rule for
phase A is the share's DriveType plus DriveFormat; if DriveFormat is empty or
generic (such as "NTFS"), bring it to John before phase A.

Done (2026-10-17): the share is `Fixed`, `VirtIO-FS`, label `lanai` (Lanai's
virtio-fs tag), seen and listed by the normal session; it returns 0.18 s after
a service start; and on a Windows that never ran setup.cmd, the new order
mounted it 0.69 s after the start with no restart (`pnputil` 0). Phase A's rule:
DriveFormat `VirtIO-FS` and VolumeLabel `lanai`.

### Phase A: the check in Windows (TDD, PowerShell and cmd)

- Files: new `guest/lanai-share-check.ps1`; `guest/setup.cmd` (the added `net stop`
  in [4/8], the [5/8] check, the file list at line 67, a `:share_missing`
  stop); `lib/setup.sh` (the media copy at line 182 and any media file list or
  manifest that names the guest files); `test/guest.bats`; `CLAUDE.md` layout
  (the new guest file).
- The script: `param([int]$TimeoutSec = 30)`. Its polling is one function,
  `Find-Share`, that takes four delegates (`$GetDrives`, `$Now`, `$Sleep`,
  `$ListRoot`) and returns 0, 10 or 11; the script's body calls it with the real
  ones. Tests load the function through the script's AST, as the
  `lanai-scale.ps1` tests do (test/guest.bats:417). The script pins
  `PSModulePath` and starts with `$ErrorActionPreference = 'Stop'`, as
  `lanai-scale.ps1` does, writes one line saying what it found, and uses only
  Windows PowerShell 5.1 APIs.
- setup.cmd: the progress line, then `net start VirtioFsSvc >nul 2>&1`, then
  `"%SystemRoot%\System32\WindowsPowerShell\v1.0\powershell.exe" -NoProfile
  -NonInteractive -ExecutionPolicy Bypass -File "%~dp0lanai-share-check.ps1"`,
  `set "RC=%errorlevel%"`, and on non-zero `goto :share_missing`, which jumps
  by `RC` with one `goto` per code (10, 11, other), so no word sits inside an
  `if ( )` block where a `)` would end it. The "could not run" words add: "If a
  security tool blocks scripts, allow Windows PowerShell to run
  lanai-share-check.ps1 from the setup drive." (As built: bare `net` and
  `powershell`, like the lines around them; see the design's code 10 note.)
- Tests first:
  - pwsh unit cases for `Find-Share`: the drive is present at once (0); it
    appears on the third poll (0); it never appears (10 after the limit, with the
    fake clock); it appears but the listing throws (11); other drives,
    including one of another format, are ignored; a drive that is not ready, or
    whose `DriveFormat` throws, is skipped; an empty share lists fine (0); a
    listing that fails once and then works gives 0; a
    `$GetDrives` that throws makes `Find-Share` throw. The fake `$ListRoot`
    returns items, and each case asserts the function's output is exactly one
    integer (a stray item or log line would make it an array). One run of the
    whole script under pwsh with `-TimeoutSec 0`, where no drive matches,
    exits 10.
  - Structural cases in `test/guest.bats`: `net stop VirtioFsSvc` comes before
    `pnputil` in [4/8], and again before the copy in [5/8]; the progress line and `net start` follow the service set
    and come before the check; the check's exit code goes to `:share_missing`,
    whose words cover 10, 11 and any other code and end with running setup.cmd
    again; the file list includes the script; update the step-order anchor
    list and the `VFS_NEW` `net stop` order case (guest.bats:317-321); the "18
    changes" case gets a `:share_missing` exemption like `:start_blocked`'s.
- Verify: `bats test/guest.bats` locally with pwsh (CI skips the pwsh cases),
  shellcheck, then the full suite.

### Phase B: host and panel (TDD)

- Files: `lib/setup.sh`, `lib/vm.sh` (`qga_reply` exit 2; the VM-start
  stamp; as built, no RESET hook), `lib/lanai.sh` (flags and doc), `lib/panel.sh`, `LanaiPanel.qml`,
  `lib/ui.sh`, `README.md`, `docs/plugin/plan.md` (the superseded lines above),
  and tests in `test/setup.bats`, `test/vm.bats`, `test/panel.bats`,
  `test/panel-jobs.bats`, `test/panel-qml.bats`, plus fakes in
  `test/fixtures/fake-qga` (a reply to `guest-exec` that is not the refusal,
  such as `GenericError` "Parameter 'path' is missing").
- Tests to rewrite: the question tests (setup.bats 1109, 1227, 1239, 1248, 1277,
  1295, 1456, 1475; panel.bats 85, 374, 753, 964, 1260; panel-jobs.bats 42,
  189, 252, 260-284) and the tests that use the removed stamps, limits or step
  6 rollback: setup.bats's `step6_running` helper (643-646) and its users, 1136,
  1184, 1250, 1264, 1325, 1352-1427, 1560-1566 and 1605-1612; panel.bats
  513-540, 676-695, 773, 1080-1092 and 1343-1380 (these call `setup_back5` for
  a step 6 time-out and assert step 5; only `mismatch` and `allowlist` keep
  that path); panel.bats 374 (`event_record`'s RESET case) and 773 (`vm_exec`'s
  start case). The fake guest agent's existing `open` mode already answers
  `guest-exec` with the "Parameter 'path' is missing" `GenericError`; reuse it.
- New cases, tests first:
  - A match with all agents and an open scale port finishes at step 7 with the
    marks, and asks nothing.
  - A closed scale port waits with the sign-in words, then stops at 120 s from
    `step6-checked` with the scale-task words.
  - Each time-out stops at step 6, kind timeout, `step5` still true, at the
    deadline from `step6-since`, and in the stated order when several parts
    are missing at once: `qmp`, `guest-boot`, `window-closed`, `idd-missing`,
    `agents` (once with the SPICE agent, once with the guest agent, once with
    both, each named in `parts`).
  - `mismatch` and `allowlist` stop at once through `setup_back5` (step 5,
    `step5` cleared), and the panel shows their words while Windows runs and
    after it shuts down.
  - The pinned client open with `unknown` or `waiting` at the deadline stops
    as `idd-missing`; one failed `query-chardev` past the deadline waits, and a
    second stops as `qmp`.
  - `qga_reply refusal` returns 0 for the refusal, 2 for a `GenericError`
    reply, and 1 for no reply.
  - A guest agent port that opens and closes again does not move the deadline,
    a QMP socket that never answers stops at it, and RESETs in a loop stop at
    the outer limit as `guest-boot`. (As built: a RESET leaves step 6's records
    as they were; a wait 10 s before each limit and a stop just after pin both
    limits.)
  - With `--follow`, a first check that comes late still stops at the deadline
    from the VM start.
  - Repeated plain `lanai setup` calls without a stop do not reset the stamps
    and reach the deadline.
  - Continue setup after a stop resets the stamps, so a check that passes on
    the next try finishes; a time-out, then a `RESET`, then a Continue well
    after it gets limits from the click. (As built: a RESET changes nothing, so
    the Continue alone gives the fresh limits.)
  - Continue setup with Windows stopped boots by `normal-boot` and checks.
  - A "could not open the Windows window" failure (setup.sh:371), a wait past
    the limit, then Continue: the check gets fresh limits and passes.
  - During the scale wait, an earlier check that fails (a client back to
    `waiting`, the guest agent busy, the SPICE port closed) does not stop
    setup; after a `RESET` they are checked again. (As built: a restart loop
    after the checks pass keeps waiting only for the scale task, and stops
    120 s after `step6-checked`.)
  - A `--follow` call that finds `step6-stopped` does not reset the stamps.
  - The job worker keeps following through the scale wait and ends on the
    stop.
  - The panel: at a time-out with Windows on, Continue setup enabled and the
    time-out words; with Windows off, Continue setup plus the two display
    buttons; `agents` words name each part; `qmp` has its own words; every
    time-out's words end with the setup.cmd condition and name both display
    buttons, and the scale task's carry the sign-in condition; the display
    buttons stay hidden for a step 6 failure that is not a time-out, and for an
    old time-out record once setup is back at step 3; the step 6 wait line
    comes from `scale_wait`.
  - Records that cannot be written stop step 6 with reason `record`:
    Continue's reset, the `step6-qmp-failed` marker and the `step6-stopped`
    marker (in step 6 and in `normal-boot`); `vm_exec` prints a `lanai:` line.
  - QML: no questions block; at a time-out stop with Windows off, the two
    display buttons send `setup --window` and `setup --no-window` without an
    arming step.
- Verify: the focused bats files, `test/qml-lint`, shellcheck, then
  `bats test spike/test` with a short `TMPDIR` (CLAUDE.md).

### Phase C: hands-on (John and Claude, test copy)

On phases A and B's build, installed on the test copy. Claude confirms that
Lanai's storage is the test copy first. A finished setup does not reopen step 6
on a restart, and setup.cmd repairs what it installs, so each fault case below
starts with Run setup again, injects its fault in the setup boot before John
runs setup.cmd, and uses a fault setup.cmd leaves alone (an Image File
Execution Options `Debugger` value naming a missing file).

1. Run setup again, no fault: setup.cmd shows its check line and passes [5/8],
   and setup finishes with no question.
2. Shared folder: Run setup again; in the setup boot, add the IFEO value for
   `virtiofs.exe`, then run setup.cmd. It stops at [5/8] with the code 10 words.
   Remove the value and run setup.cmd again in the same boot: it finishes, and
   so does setup.
3. Automatic sign-in off (`AutoAdminLogon` 0 and the restart sign-on setting
   off, per phase G's note), then Run setup again; John signs in to run
   setup.cmd. At the step 6 boot, John stays at the sign-in screen: the panel
   shows the sign-in wait words, and step 6 stops at 120 s with the scale-task
   words. John shuts down from the panel: the two display buttons appear beside
   Continue setup. John clicks Continue setup: Windows starts, the limits count
   from that boot, John signs in, and setup finishes. Turn automatic sign-in
   back on (`netplwiz`).
4. Guest agent: Run setup again; in the setup boot, add the IFEO value for
   `qemu-ga.exe`, then run setup.cmd. If setup.cmd stops at its guest agent step
   instead, record that and leave the case to phase B's tests. Otherwise the
   agent never opens its port, and step 6 stops at its deadline as
   `guest-boot`, with its words. Remove the value (`reg
   delete` in an admin PowerShell), restart Windows, and click Continue setup:
   setup finishes.
5. Record each step in `proofs.md`.

By test, not by hand: the IDD mismatch (bats fixture `other-build.log`, as no
other IDD build is installed), a guest agent without its allow-list (setup.cmd
always writes the `--allow-rpcs` argument back, so the fake guest agent's
non-refusal reply covers it), the `idd-missing`, SPICE agent and `qmp`
time-outs, a drive that appears but cannot be listed (phase A's pwsh case), and
Run setup again after a scale-task stop.

### Risks

- A Continue click that comes after a panel job ended without a stop (a killed
  worker, a failed systemctl call), more than 300 s into the check boot, can stop
  at once with a time-out: only a stop marker gives the next Continue fresh
  limits. The stop writes the marker, so a second click gets them.

- First install: phase 0's step 4 settles whether the share mounts before a
  restart on a fresh Windows. If it does not, the in-setup check would stop every
  first setup, and the design goes back to John.
- The drive rule depends on phase 0's DriveFormat. A generic value would let
  another drive pass; phase 0 stops for John in that case.
- A share that hangs `IsReady` or the listing holds the script, and setup.cmd's
  window, past its 30 s. Accepted: the user can still close the window and
  use Shut down in the panel, as the README says for a setup.cmd that stops
  responding.
- Host sleep counts against step 6's limits: they count wall-clock seconds, so a
  laptop suspend during step 6 can cause a time-out. Accepted: Continue setup
  recovers with fresh limits.
- A Windows restart during step 6 resets nothing (John, 2026-10-18). A restart
  in the middle of the checks gets only what is left of the 300 s; Continue
  setup gives fresh limits. A restart after the checks pass does not prove the
  IDD and the agents again; they were proven on the same disk minutes before.
  Accepted for the simpler step 6: four records, two limits.

### Routing

Phase 0 and C: John with Claude. Phase A: the step-up (opus-5.5) in a worktree:
Windows scripting where a wrong stop blocks every setup, and words a user acts
on (taste >= 7). Phase B: opus-5.5 in a worktree: a state change across setup,
the job worker and the panel, and user-facing words. Claude verifies, signs,
and runs the diff gate.

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
| 12 | Tile, fullscreen, resize; desktop follows; scale matrix through `scale_step` tests plus two real host scales; a fixed 125% scale setting holds from a quarter-size window to full screen (or caps and recovers where Windows' limit applies) |
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
| plan amendment (panel view) | a (gpt-6.1-sol) | 2 (full) | 4 P2; all confirmed and integrated: a reloaded panel could act on an old reply (records carry the panel session and VM invocation; only this session's results authorize); Shut down could overwrite a running job's tracking (running job and last results in separate files); the view lacked settings, snapshots and log data (added); the reply-freshness rule was not implementable (setup's step now comes from a read-only `setup_plan` split from `setup_resume`, not from replies) |
| plan amendment (panel view) | a (gpt-6.1-sol) | 3 (full, cap) | 1 P1, 3 P2; all confirmed and integrated: `auto` after step 5 waited on bookkeeping only the next setup call does (a pure `run_verdict` over the markers still on disk); a Windows restart could revive step 6's questions (the event logger counts QMP RESET events); transient input had no home (exempted, decides nothing); direct commands routed inconsistently (every panel command through ui-run or ui-job). Stage closed at the cap |
| plan amendment (panel view) | b single (opus-5.5) | 1 (full; single by John's Claude-usage rule) | 5 should-fix, 6 nits, 0 refuted; all integrated in a rewrite of the amendment: `setup_plan` applies `record_previous_run`'s and `setup_follow`'s pending effects through a pure `run_verdict` (and agrees with `setup_resume` in both marker states); `auto` keeps the 10 s spacing and a precise wait definition; one result file per control group; step 6's questions from a `$RUN/step6-asked` file the event logger deletes on RESET (replacing the reset counter); no duplicated /proc scan or client run per poll, 15 s polling unless something is happening; session per bar instance passed to ui-run and ui-job; no list control; named Shut down and Force stop tests |
| plan amendment (panel view) | b single (opus-5.5) | 2 (full) | 8 should-fix, 9 nits, 0 refuted; all integrated in a second rewrite. The main one simplifies: the setup job follows its own waits, so session ids, the `auto` field and its rules, and the paused flag go away (and clicking Open no longer cancels progress). Also: one record per group with a started record at launch (no separate job file), a fixed write and read order, result currency rules, panel words from a table with `reason` codes, `finished` by step 7's rule, one shared fact gatherer with a builtin cgroup scan skipped while the VM runs, 2 s polling only on the monitor whose panel is open, and the superseded contract lines named |
| plan amendment (panel view) | b single (opus-5.5) | 3 (full, cap) | 9 should-fix, 4 nits, 0 refuted; all integrated: follow-up setup calls are bare (a repeated `--window` looped setup boots); results show only what the state cannot say (failures, spec 7's snapshot text, a restore's outcome), since wait replies and systemd's kept InvocationID made currency rules leak; `finished` needs `step5` not false; the view reads records while holding the lock probe, with three named record states; `ui-job` runs as a systemd user unit (spec 18); a client-mode setup boot starts its own client; `ui-run` has no deadline; `run_verdict` reads `running` last; the overlay applies only while the unit is inactive or failed; job polling 2 s; only the open panel's bar polls fast. Stage closed at the cap; the amendment's gate is closed |
| diff (phase 7, panel view) | a (gpt-6.1-sol) | 1 (full) | 3 P2, 0 refuted, 0 downgraded to nit; all confirmed and integrated (fixes by Codex): polls wiped unsaved settings edits; "Run setup again" did nothing on a finished install (now offers the two display choices); a failed snapshot-choice save showed nothing |
| diff (phase 7, panel view) | a (gpt-6.1-sol) | 2 (full) | 3 P2, 0 refuted, 0 downgraded to nit; all confirmed and integrated (fixes by Codex): a follow-up could boot Windows after it stopped (setup now revalidates `--follow` under its lock); existing installs never got the new VM helpers (runtime revision now hashes bin/ and lib/); concurrent readers saw a phantom job (shared reader lock). Also fixed: CI lost one test's result because lib/ui.sh set shell options when sourced |
| diff (phase 7, panel view) | a (gpt-6.1-sol) | 3 (full, cap) | 1 P1, 3 P2, 0 refuted, 0 downgraded to nit; all confirmed and integrated (fixes by Codex, the test stub by Claude, who found it from CI first): with lingering on, a setup worker could start Windows after logout (now PartOf graphical-session.target, checked before each call); deactivation ended step 5's following; a replaced record made a seen launch read as failed; a test lost its package stub when it re-sourced client.sh. Stage closed at the cap |
| diff (phase 7, panel view) | b single (opus-5.5) | 1 (full; single by John's Claude-usage rule) | 5 should-fix, 7 nits, 0 refuted, 0 downgraded to nit; all integrated (fixes by Codex): a setup failure outlived a restore; busy replies got the wrong words and stopped following; agreement tests could not tell a boot from an offer; timestamps broke under comma locales; "Run setup again" dead-ended while Windows ran; plus copy, warnings, logs and the QML lint invocation (test/qml-lint) |
| diff (phase 7, panel view) | b single (opus-5.5) | 2 (full) | 4 should-fix, 7 nits, 0 refuted, 0 downgraded to nit; all integrated (fixes by Codex): steps 5 and 6 promised automatic progress with no job running; a restore success told the user to continue setup for days; unlabelled log paths; a README button name. Nits: a `missing` reason, busy-retry scope, the refused worker's log line, restore and re-run control wording, Continue setup disabled where it does nothing, a locale test that skips |
| diff (phase 7, panel view) | b single (opus-5.5) | 3 (full, cap) | 3 should-fix, 6 nits, 0 refuted, 0 downgraded to nit; all integrated (fixes by Codex): plan and resume disagreed after a started run that failed; a double-click gave a false launch failure; a snapshot refusal showed far from step 3's controls; plus stopping, shared-folder and not-installed copy, gating and the README lint line. Stage closed at the cap; stage a's rerun on the final diff waits for John |
| diff (phase 7, panel view) | a (gpt-6.1-sol) | 4 (full, the rerun on the final diff, approved by John) | 1 P2, 1 P3, 0 refuted, 0 downgraded to nit; both confirmed and integrated (fix by Codex): a failed snapshot-choice save could vanish once the plan moved past step 3 (now stepless); its retry text named a hidden button. Both stages are at their caps; John decides whether to accept or run one more round |
| diff (phase 7, panel view) | John | 2026-10-05 | John accepted the gate with round 4's fixes unreviewed, both stages at their caps. Next: the hands-on test in the bar on the test copy |
| diff (phase 7, during setup) | a (gpt-6.1-sol) | 1 (full) | 2 P2, 0 refuted, 0 downgraded to nit; both confirmed and integrated (fixes by Codex): Reopen vanished after a step 6 rollback; the accent stayed on while Windows shut down |
| diff (phase 7, during setup) | b single (opus-5.5) | 1 (full; single by John's Claude-usage rule) | 1 should-fix, 1 test gap, 6 nits, 0 refuted, 0 downgraded to nit; integrated (fixes by Codex) except one accepted nit: Start and Open hid on a working install with a pending update step (spec 8); untested client timeout warnings; one Cancel at a time; no confirm once a stop is under way; setup accepts a window already open; constant Setup inset; step 5 copy. Accepted: the highlight lights before the setup drive is visible (no guest signal before setup) |
| diff (phase 7, during setup) | b single (opus-5.5) | 2 (full; single by John's Claude-usage rule) | 0 should-fix, 7 nits, 0 refuted, 0 downgraded to nit; all integrated (fixes by Codex, the log rows by Claude): Snapshots stay for a working install with a pending update; Reopen only on an active unit; truthful attention note; a guard comment; no empty Setup band on a finished install; test counts; these log rows. Stage closed clean |
| diff (phase 7, during setup) | a (gpt-6.1-sol) | 2 (full, the rerun on the final diff) | 0 findings, 0 refuted, 0 downgraded to nit. Clean; its sandbox could not run bats, so Claude ran the full suite on 1563c2b (626 pass, 1 locale skip). The gate is closed |
| plan amendment (scale, progress, clicks) | a (gpt-6.1-sol) | 1 (full) | 1 P1, 1 P2, 0 refuted; both integrated: the compressed-extent limit of the FIEMAP proof is stated as out of the threat model (a same-user process that clones a chosen slice could rewrite COMPLETE anyway; flagged to John); CI gets a host-made btrfs folder and fails, not skips, without it. Round 2 showed the CI premise was wrong (CI already loop-mounts btrfs in a privileged container); that finding is refuted on recheck, so the count is 1 confirmed, 1 refuted |
| plan amendment (scale, progress, clicks) | a (gpt-6.1-sol) | 2 (full) | 1 P2, 0 refuted; integrated: round 1's host-step CI fix could not run (job-level container); the plan keeps CI's existing loop-mounted btrfs, adds strace, and fails rather than skips without btrfs in CI |
| plan amendment (scale, progress, clicks) | a (gpt-6.1-sol) | 3 (full, cap) | 0 findings. Stage a clean |
| plan amendment (scale, progress, clicks) | b single (opus-5.5) | 1 (full) | 4 should-fix, 6 nits, 0 refuted; all integrated (by Codex): a restore onto a deleted disk installs and locks the clone before hashing; provability defined by statfs and extent classes, with mixed plain and compressed extents (Omarchy mounts compress=zstd) and a fixture each; a one-extent probe with no write; a hook for restore's final map compare; threat model covers deliberate re-cloning in any mode; strace also rejects mmap/sendfile/splice/copy_file_range and polls start after the lock; the progress lock is read from /proc/locks; a resumed restore re-clones a stale temp; invalid windows_scale refuses boot like memory/cores, label "Windows scale"; right click uses $p.finished on purpose, Menu key toggles |
| plan amendment (scale, progress, clicks) | b single (opus-5.5) | 2 (full) | 1 blocker, 2 should-fix, 8 nits, 0 refuted; all integrated (by Codex): unwritten (preallocated) extents count as provable, since dockur's detect-zeroes and discard make them (verified), with zero-range fixtures and a read-only extent count John runs on the rehearsal copy first; the existing disk needs only btrfs and a NOCOW match; the progress owner is the pid holding the lock file open (/proc/locks names the short-lived flock process, verified); no probe, the real clone falls back to the next root; the deleted-disk clone is locked before it appears; small files cloned then hashed once; no separate SHARED check; right-click open needs no idle lock; pwsh tests skip in CI (AUR only); README covers both scale choices; ctypes statfs/renameat2, FIEMAP batching, map timing, helpers.bash |
| plan amendment (scale, progress, clicks) | b single (opus-5.5) | 3 (full, cap) | 1 should-fix, 4 nits, 0 refuted; nits integrated by Claude: any failure before the first install file is replaced is a clean refusal (a clone error included); the progress owner compares device and inode, not a path; the helper is `btrfs_tmp`; keypad Enter handled too. The should-fix (the deleted-disk restore changes storage before the hash, against req 7's literal "before anything changes", and dockur's cleanup ignores the disk lock) waits for John |
| plan amendment (scale, progress, clicks) | John | 2026-10-05 | John chose option 1 for round 3's should-fix: on a deleted disk, publish and lock data.img, then put back the verified small files at once, then hash; the exception to req 7's "before anything changes" is logged in the spec. Gate closed |
| diff (scale, progress, clicks) | a (gpt-6.1-sol) | 1 (full) | 1 P1, 1 P2, 0 refuted, 0 downgraded to nit; both reproduced by the reviewer, confirmed and integrated (fixes by Codex): restore installed small files hashed before the minutes-long image proof without a recheck (now rehashed just before each rename, on both paths); a non-object progress record failed the whole panel view. Also fixed by Claude from CI: a test used rg, absent from CI |
| diff (scale, progress, clicks) | a (gpt-6.1-sol) | 2 (full) | 1 P2, 0 refuted, 0 downgraded to nit; confirmed (reproduced on tmpfs) and fixed by Claude: a NOCOW image whose first snapshot root cannot hold NOCOW (XFS, tmpfs) failed instead of falling back to the root beside storage; ficlone.py now returns the fallback code, with a test that fails without it |
| diff (scale, progress, clicks) | a (gpt-6.1-sol) | 3 (full, cap) | 1 P2, 0 refuted, 0 downgraded to nit; confirmed and fixed by Claude: a staged small file swapped for a symlink to the snapshot copy passed the hash (sha256sum follows links) and was installed as a link while the restore reported success; restore_small_file now refuses non-regular files before and after the rename, with a test that fails without it. Stage closed at the cap with this fix unreviewed by stage a |
| diff (scale, progress, clicks) | b single (opus-5.5) | 1 (full; single by John's Claude-usage rule until 09:00 EDT 2026-10-06, though this gate's findings above nit call for a panel) | 1 should-fix, 5 nits, 0 refuted, 0 downgraded to nit; all integrated (fixes by Codex): setup under its own lock skipped the blank-disk check (only a live image operation now skips it); prove output leaked into later failure reasons, raw helper text and a doubled backup hint; stale .partial folders, empty fallback roots and dead-owner map files are swept again; plain progress text without an em dash or a repeated label; the guest scale loop backs off and survives log failures; dead code |
| diff (scale, progress, clicks) | b single (opus-5.5) | 2 (full; single by John's Claude-usage rule) | 2 should-fix, 6 nits, 0 refuted, 0 downgraded to nit; all integrated (fixes by Codex): a deleted-disk restore from a damaged snapshot deadlocked (a mismatch before publication is now a clean refusal; after it, the marker records the failed snapshot and a named other snapshot may replace it); a refused restore showed the setup step's snapshot advice (own reason and words); run-on CLI messages; raw helper errors; progress labels per step; scale backoff after the attempt; tests regrouped by behavior; named ioctl, docstring, README and one activity call per poll. The reviewer briefly took a flock on the real ~/.local/state/lanai/lock (no file changed; later prompts forbid it) |
| diff (scale, progress, clicks) | b single (opus-5.5) | 3 (full, cap; single by John's Claude-usage rule) | 3 should-fix, 4 nits, 0 refuted, 0 downgraded to nit; all reproduced by the reviewer: any proof failure (not only a hash mismatch) marked a deleted-disk restore's snapshot failed, leaving no way out; an interrupted existing-disk restore whose snapshot later failed its hash deadlocked the same way; the panel could not show the failed state. Nits: a log failure before the scale set, a tautological awk test, article-less progress copy, a lost "You can close this panel." line |
| diff (scale, progress, clicks) | John | 2026-10-05 | John chose to simplify instead of patching: a named different snapshot always replaces an unfinished restore, the failed-verification state goes away, and the panel offers every snapshot while a restore is unfinished (plan, phase B). One more stage b round, past the cap, on his OK |
| diff (scale, progress, clicks) | b single (opus-5.5) | 4 (full; past the cap on John's OK; single by his Claude-usage rule) | 1 should-fix, 2 nits, 0 refuted, 0 downgraded to nit; all fixed by Claude, each with a test that fails without it: a damaged small file in the snapshot did not say "Restore another snapshot by name." and showed the snapshot path; a progress file left by a killed run carried its counts into the next run; "Right-click" spelling. The reviewer found no failure that leaves Windows unable to start with no way out while a valid snapshot exists. Stage b closed |
| diff (scale, progress, clicks) | a (gpt-6.1-sol) | 4 (full, the rerun on the final diff, past the cap on John's OK) | 0 findings, 0 refuted, 0 downgraded to nit. Clean (its sandbox cannot bind sockets; Claude ran the full suite on 45bc98b: 707 pass). The gate is closed. Next: John's hands-on checks on the test copy |
| plan (live scale) | a (gpt-6.1-sol) | 1 (full) | 1 blocker, 7 should-fix, 0 refuted; 6 integrated in the plan (guest drains before acting and phase 0 proves latest-only delivery; boot monitor recorded and per-run monitor state reset; picks judged against the task's own expected step, no 5 s after-set window; save number in settings.json, a changed number is a save, invalid refuses; baseline from a second OEM string before any pick; marker moves to phase B with the new script; structured reply fields through panel_words and the Settings line), 1 resolved in the spec (following keeps working with the shell down, flagged to John) |
| plan (live scale) | a (gpt-6.1-sol) | 2 (full) | 5 should-fix, 0 refuted; all integrated: a reader runspace and a 300 ms quiet gap replace the pending-read drain test, proven with a 10,000-line backlog; each pass observes, then processes the line, then applies; the touched flag clears only on open; the old-task words name the lost following; a measured 10-minute guest flood in phase 0 |
| plan (live scale) | a (gpt-6.1-sol) | 3 (full, cap) | 1 blocker, 3 should-fix, 0 refuted; all integrated: a 250 ms tick checks the quiet gap on its own clock (a 2 s poll could miss every gap); the window's monitor is recorded whatever the setting, and boot_monitor for every boot; pending and confirmed steps kept apart, so a set Windows ignores is never a pick; one settings snapshot for step and save number. Stage closed at the cap with these integrations for stage b to review |
| plan (live scale) | b single (opus-5.5) | 1 (full) | 0 blockers, 6 should-fix, 9 nits, 0 refuted; all integrated: first observation and in-window changes are never picks; the setup marker needs `chardev_open scale0` in step 6; a steady 2 s resend replaces the QMP event idea (no free QMP socket); a newline on each connection recovers a cut line; the elevated task pins PSModulePath and logs to an admin-only folder, and the HKCU environment residual is recorded for John; the Hyprland signature travels in boot.json; nits (socat -u with timeout, test interval, fixed-boot contract, CreateFile for the device path, settings words cleared per run, CLI words, monitor id mapping, stale socket and helper table, wording) |
| plan (live scale) | b single (opus-5.5) | 2 (full) | 0 blockers, 3 should-fix, 8 nits, 0 refuted; all integrated: TMP and TEMP pinned to an admin-only folder before Add-Type; setup.cmd removes a planted ProgramData link and sets owner and ACL; one short connection per send, the reader keeps its handle across host disconnects, and phase 0 (5) proves that model; nits (join every missing part, vm_args as the site with a checked save argument, feed seeds and keeps the last good line, a 2.5 s wait for the first line, words for unfinished setup and stopped old installs, a send-timeout test knob, named pure functions for the guest, send failures logged once) |
| plan (live scale) | b single (opus-5.5) | 3 (full, cap) | 0 blockers, 2 should-fix, 7 nits, 0 refuted; all integrated: the log and temp folder move under C:\Program Files\Lanai (ProgramData raced its ACL, as C:\Lanai did in phase 6), dropping the ACL repair; the first-line wait is bounded from task start, so a port that never opens still gets the OEM step; nits (residual reach and absolute powershell.exe path, phase 0 (6) uses the shipped feed, start-to-start cadence and hyprctl timeout, vm_plan signature, qml-lint in phase A, signature check). Stage closed at the cap with these integrations unreviewed; John accepted the plan at the cap (2026-10-11). Phase 0 proof 4 then changed the drain rule (a multi-line batch is stale and dropped); the implementation diff gate reviews it |
| impl (live scale) | a (gpt-6.1-sol) | 1 (full) | 3 should-fix (P2), 0 refuted, 0 downgraded to nit; all integrated test-first: a set is read back and confirmed at once, so a pick of the old step before the next poll holds; a display change drops an unapplied request so it is asked again at once; a first line waiting for its quiet gap holds back the OEM fallback |
| impl (live scale) | a (gpt-6.1-sol) | 2 (full) | 3 should-fix (P2), 0 refuted, 0 downgraded to nit; all integrated test-first: a stale batch before the first line holds the OEM fallback for one feed period; a failed observation resets the baseline so a returning display never makes a pick (a pick survives); every step the task asked for since the last confirmation is never a pick |
| impl (live scale) | a (gpt-6.1-sol) | 3 (full, cap) | 1 should-fix (P2), 0 refuted, 0 downgraded to nit; integrated test-first: panel setup jobs forward HYPRLAND_INSTANCE_SIGNATURE to the detached worker, so boot_vm records it for the scale feed |
| impl (live scale) | b panel (opus-5.5) | 1 (full, 6 lenses) | 0 blockers, 13 should-fix, 30 nits, 0 refuted, 0 downgraded to nit; all integrated test-first: setup step 6 judges the scale task after the user answers (a slow password sign-in no longer loops back to step 5); the guest reader retries only error 1450, reopens on other errors and logs open and read errors once; the feed picks a live Hyprland instance (boot record, inherited, or the only one) and finds it again after hyprctl fails; the guest's first-line hold folded into one LastArrival rule and the baseline reset into Step-ScaleState; the dropped-click notice is pinned and stays 2 to 5 s; tests pin the client-unit query, the hyprctl timeout and the real display observation; panel words and README corrected. Security lens: no defects |
| impl (live scale) | b panel (opus-5.5) | 2 (full, 6 lenses) | 0 blockers, 6 should-fix, 25 nits (after merging duplicates), 0 refuted, 0 downgraded to nit; all integrated but one nit: a Hyprland instance counts only if it answers (dead instance folders and sockets stay behind; John's machine had about 48), with a search every 30 s while hyprctl fails; a SetScale error is logged once and retried at the next poll; boot and feed share one monitor rule (scale_target); the pinned notice swallows clicks and the panel can scroll under it; the RSS test is bounded under the CI limit; the task principal comes from the checked SID; step 6 has its own reason and words for a scale task that did not start; plan design text gets as-built notes. Not taken (nit): a user pick equal to an older of two unapplied requests is undone once; a second pick holds |
| impl (live scale) | b panel (opus-5.5) | 3 (full, 6 lenses, cap) | 0 blockers, 5 should-fix, 28 nits, 0 refuted, 0 downgraded to nit; all integrated: a SetScale that keeps failing logs its applying line once (the round 2 retry had made it log every 2 s); an old-task install gets a standing note under the scale list, so the Run setup again step survives shutdown; old-task words no longer use "scale changes" two ways; tests now pin the 5 s settle after a resolution change and the remembered monitor over several closed-window passes; nits (reader reopens after any throw, restarted feed resends its last line, opaque notice, step 6 words, names, host_monitors timeout). Stage closed at the cap with these integrations unreviewed; stage a has no round left for the final-diff rerun. John (2026-10-11): accept the gate, do the hands-on session (phase 0 (6)-(7), phase C) first, then one extra stage a round on the final diff, hands-on fixes included |
| impl (live scale) | a (gpt-6.1-sol) | 4 (full final diff at 71a9b71, hands-on fixes and phase D included; the extra round John called) | 0 findings, 0 refuted, 0 downgraded to nit: "The committed diff appears sound". Its sandbox could not create the test sockets, so it ran targeted tests (97 passed, 1 skipped) and ShellCheck; the full suite passed outside it (786 ok). Gate closed |
| plan (resize) | a (gpt-6.1-sol) | 1 (full) | 2 should-fix, 0 refuted; both integrated: each patch is made against the tree with the earlier patches applied (0002 holds only the hooks), and the README keeps the no-change promise for the build step, not Run setup again |
| plan (resize) | a (gpt-6.1-sol) | 2 (full) | 1 should-fix, 0 refuted; integrated: the frame thread also counts accepted format changes, so a size that changes and changes back between two main-loop polls still counts as a change of Windows' size (`resize_frame` takes the count), with a glue test |
| plan (resize) | a (gpt-6.1-sol) | 3 (full, cap) | 1 should-fix, 0 refuted; integrated: size and change count are one packed 64-bit atomic (w << 48, h << 32, count), written only by the frame thread, so the main thread never pairs a size with another write's count. Stage closed at the cap; the fix is reviewed by stage b |
| plan (resize) | b single (opus-5.5) | 1 (full) | 0 blockers, 5 should-fix, 9 nits, 0 refuted; all integrated: a session reset also resets the polled change count (else a driver restart at boot could go unseen); build order unpack, submodules, apply, configure with the apply lines kept in build-client.log; the update failure words name build-client.log; build-client gets its own panel group, so an interrupted update never names Run setup again and the done words show only while a stale client runs; a failed send warns once and waits 1 s; nits (shared nullglob patch list, no patches is a build error after phase B, mouse-tests and CI case set-up, test stubs, frame hook in the formatValid block, CLI message varies on a running client, old-task wording, John's copyright line, rollback note) |
| plan (resize) | b single (opus-5.5) | 2 (full) | 0 blockers, 4 should-fix, 9 nits, 0 refuted; all integrated: build tests on client.bats lg_source with a fixture patch, and a helper for the setup.bats stamps; phase C names the QML result Note, the build log key and both group loops; a refused small ask may erase the IDD's one custom mode, so phase 0 probes where Windows ends and the spec words go to John if it does not keep its size; phase 0 requires exact pixel matches (odd width, fractional scale) or a rounding rule from John; nits (patch id in its own build-patches file so rollback is silent, client words gated on a stale client, one CLI message, non-size format changes accepted, more module cases, LC_ALL=C patch and basenames and .gitattributes, phase D timing notes, setup message, out-of-tree builds, upstream gate note) |
| plan (resize) | b single (opus-5.5) | 3 (full, cap) | 0 blockers, 2 should-fix, 9 nits, 0 refuted; all integrated: phase 0 compares each Format size to round(hyprctl size × scale), the size the client asks for; phase D gains a patches review step; nits (a session restart from a refused ask is a stop rule, test locations, setup_command, absolute patch paths, header lines that look like diffs, making 0001 cold, resize warning naming and tooltip, done words until the next client starts, phase D monitor and pick timing, IDD anchors, a busy-build reply, the CI pin-drift gap under Risks). Stage closed at the cap with these integrations unreviewed |
| plan (resize) | John | 2026-10-12: accepted the plan gate at the cap with round 3's integrations unreviewed; phase 0 runs next |
| plan (resize) | John | 2026-10-12: phase 0 ran; (1)-(3) pass, (4) fired its stop rule (Windows moved to 1920x1080). John's call: never ask under 640x480. Design "Refused sizes", the module rule and tests, the README words and phase D (6) changed to match; the spec changed with it |
| plan (resize) | John | 2026-10-13: phase D ran (`proofs.md`, "Resize hands-on"): starts with a changed window size fail (5.8 s, 3 of 3); the monitor move with another scale was not run (no second real monitor); the pick case was partly run (1 of 5 slow picks; the quick picks never reached the fifth ask); the other steps pass. John's call: first wait 2 s (waits 2, 5, 10 and 20 s). Design's wait rule and sequence times, the module tests and phase D (2) and (4) changed to match; phase E added |
| plan (resize, phase E) | a (gpt-6.1-sol) | 1 (full) | 0 blockers, 3 should-fix, 0 nits, 0 refuted; all integrated: the six-pick fixture's match and pick events are retimed so picks land before the 2 s wait ends; new cases are registered in `RESIZE_CASES` and 0002 is regenerated; phase E's hands-on runs row 12b's full pick case, and the phase D log row states what was not run |
| plan (resize, phase E) | a (gpt-6.1-sol) | 2 (full) | 0 blockers, 2 should-fix, 0 nits, 0 refuted; both integrated: 0002's `testControl` asserts the old 5 s wait and is retimed to 2 s; the hands-on quick picks each follow Windows taking the previous ask, as row 12b says, not a fixed 3 s apart. (A first round-2 run used a stale live-scale prompt by Claude's error and was discarded; it is not counted) |
| plan (resize, phase E) | a (gpt-6.1-sol) | 3 (full, cap) | 0 findings: "The amendment is sound". Stage closed |
| plan (resize, phase E) | b single (opus-5.5) | 1 (full) | 0 blockers, 1 should-fix, 6 nits, 0 refuted; all integrated. The reviewer built 0001 and both patches with the new waits: 8 of 16 resize cases fail, 6 of them not named; phase E now lists every case with its new times, retimes two boundary cases, says the slow-switch case passes before the change, gives the Windows restart an expected result and a stop rule, carries the restart case into phase D (2), and states the routing reason |
| plan (resize, phase E) | b single (opus-5.5) | 2 (full) | 0 blockers, 0 should-fix, 6 nits, 0 refuted; nits only, stage stopped and all 6 integrated (case count, the late-change check at 746, a late-picks case for picks after their wait, phase B's times marked as phase E's, phase D (4) in the log row, case names the bats list check reads). The reviewer built both patches as phase E says: all resize and config-message tests pass with the new waits |
| plan (resize, phases F and G) | a (gpt-6.1-sol) | 1 (full) | 0 blockers, 5 should-fix, 0 nits, 0 refuted; all integrated: the step's failures stay inside its tick (a replug can throw between calls, and the loop's outer catch would end live scale), with tick tests; with the live-scale task old too, one warning names Run setup again and the note under the scale list is not shown; the clock offset is measured through the share (guest writes, host stamps); phase G adds the 10 plain starts and a Display settings check per timed boot case; the cap transition runs on the start from the bar, and a missing size pair goes to John. "No separate confirmed defect was found in the amended spec wording" |
| plan (resize, phases F and G) | a (gpt-6.1-sol) | 2 (full) | 0 blockers, 2 should-fix, 0 nits, 0 refuted; both integrated: a start is timed from the later of the sign-in and the first frame (row 12b now says so, as requirement 12 does; flagged in the spec log); the clock offset comes from a two-way ping and pong through the share, bounded by half the round trip |
| plan (resize, phases F and G) | a (gpt-6.1-sol) | 3 (full, cap) | 0 blockers, 2 should-fix, 0 nits, 0 refuted; both integrated: the unsupported-size stop applies only to the size that switch tried, with a test; the spec's frame-evidence exception ends only when the step has seen the desktop match (flagged in the spec log). Stage closed at the cap with these integrations for stage b to review |
| plan (resize, phases F and G) | b single (opus-5.5) | 1 (full) | 0 blockers, 9 should-fix, 7 nits, 0 refuted; all integrated: a C# 5 compile test for the `Add-Type` block (Windows PowerShell 5.1; a compile error would end the task silently); a switch counts as not taken only 2 s after success (the helper waits 2 s; a switch took 1.26 s); the logon-age gate runs inside the guarded tick, with the `WTSINFOW` layout given and failures skipping; fixtures that mean "current install" move to mark 3 and the old-task note test is rewritten; README:182-185 and 236-238; phase G adds the plain sign-out and sign-in, two restarts and a guard review, and runs the pick case only after a step that logged a match; the client log is stamped with host time as it arrives; `Get-StoredMode` and the happy-path and pacing tick tests; the driver-disabled case shuts down and starts from the bar and re-enables through RDP; nits (the helper also sets the frequency, `ExtraMode` is untrusted and bounded to 5 digits, the matches line counts switches, the skip line repeats without growing the log, Files and Verify bullets, a static loop check, the tick returns nothing, the lock idea leaves the offer until retested). The two spec edits flagged to John check out against the plan |
| plan (resize, phases F and G) | b single (opus-5.5) | 2 (full) | 1 blocker, 1 should-fix, 13 nits, 0 refuted; all integrated. Blocker (phase G only): the driver-disabled case recovered through `omarchy-windows-vm`, which boots the live `~/.windows`; it now recovers on the test copy with `proof-vm`. Should-fix: the logon-age signal was undefined; replaced by the reviewer's simpler gate, a value in `HKCU\Volatile Environment` (rebuilt at each sign-in), with no WTS struct. Nits: the skip line uses `Write-Log`; repeated results log once; public structs and the prototype committed before phase F; the script's header; "until the window is resized" in the panel words; a separate `signin_step` key instead of mark 3 (an older Lanai still reads the record); "A fits inside B"; the stamper, window-sizing and pong tools in the proof kit, with dated, zoned stamps; the re-run rule covers the 5 s bars; step 5 checks the bounded asks; a risk and a ready time for the scale cap check; the spec log's flagged rows moved below John's acceptance |
| plan (resize, phases F and G) | b single (opus-5.5) | 3 (full, cap) | 0 blockers, 3 should-fix, 7 nits, 0 refuted; all integrated: the registry wrappers return `$null` for a missing value (`Get-ItemPropertyValue` would throw and make the gate always skip), with a static check; the `started` line logs the process start time (the loop's clock starts after PowerShell's start-up and the C# compile); phase G first confirms Lanai's storage is the rehearsal copy, not `~/.windows`; nits (the How paragraph rewritten, the context field and `$Now`, the volatile value's side effects as a risk and step 5 checks `started`, the 2 s wait justified by phase D alone, the fixture grep and both keys, "no larger than" the smallest mode, exact commands for John, a rerun within the bound goes to John, a log-once test for no display, CI skips the pwsh cases, .NET Framework APIs only). Stage closed at the cap with these integrations unreviewed; the gate waits for John |
| plan (resize, phases F and G) | John | 2026-10-13 | Accepted the gate at the cap with b round 3's integrations unreviewed; the diff gate checks the build against them |
| plan (resize, phase H and G changes) | a (gpt-6.1-sol) | 1 (full) | 0 blockers, 1 should-fix, 0 nits, 0 refuted; integrated: the program joins its kill-on-close job before it starts the script, so no moment exists where the script runs outside the job (Codex proposed a suspended start; joining first is simpler); a failed join still starts the script |
| plan (resize, phase H and G changes) | a (gpt-6.1-sol) | 2 (full) | 0 blockers, 2 should-fix, 0 nits, 0 refuted; both integrated: a failed job starts no script (an unprotected script could outlive a crashed program; the 5-minute repetition retries), with a fake-driven test; with no Lanai OEM string the program exits at once, with no script, so a task start under `omarchy-windows-vm` ends within seconds (row 4), while a failed read still starts the script |
| plan (resize, phase H and G changes) | a (gpt-6.1-sol) | 3 (full, cap) | 0 blockers, 2 should-fix, 0 nits, 0 refuted; both integrated: the SMBIOS parser unwraps the 8-byte `RawSMBIOSData` header and checks its length, with whole-buffer fixtures and three results (found, not found, failed read); row 4's checks go to phase 8's separate test install, not the rehearsal copy (on John's host `omarchy-windows-vm` boots the live `~/.windows`). Stage at the cap with round 3's integrations unreviewed by stage a |
| plan (resize, phase H and G changes) | b single (opus-5.5) | 1 (full) | 0 blockers, 4 should-fix, 11 nits, 0 refuted; all integrated: the self-check runs through `Start-Process -PassThru` and `WaitForExit` (`&` does not wait for a windows program); `Main` is one `try`, so no error dialog shows; the not-Lanai line follows the last-line rule and comes before `started`; README's uninstall ends the task first and names the new files, and its security paragraph names the program; nits: a `Start program:` prefix keeps `Sign-in step: started` meaning the gate passed, a non-inheritable job handle, the job struct's size, the `RSMB` value and a length under 4, the OEM prefix rule only (the script validates), the quoted task path, the existing tests that change, `PATH` set for the build, phase G's process check and fixture (an IFEO `Debugger` value), and two test and risk gaps |
| plan (resize, phase H and G changes) | b single (opus-5.5) | 2 (full) | 0 blockers, 4 should-fix, 10 nits, 0 refuted; all integrated: a realistic multi-structure SMBIOS fixture (a double-NUL slip would read every real table as not Lanai's); the job handle an `IntPtr` in a static field, never a `SafeHandle` a finalizer could close; per-cause words for a blocked program (Smart App Control allows no single program, only off); phase G step 5's plain sign-in takes its evidence from the unchanged frame plus the 0-switch line; nits: `Run(args, deps)` with a wait delegate and the return-2 case, the other phase F tests that move, no LINQ, the exit-code test's pattern and count, `PSModulePath` pinned in the one-liners, a null exit code fails the check, README pointers, exact commands for John, a race risk, one constant for the mark |
| plan (resize, phase H and G changes) | b single (opus-5.5) | 3 (full, cap) | 0 blockers, 2 should-fix, 6 nits, 0 refuted; all integrated: the static checks match the design (`Main` calls `Run`, whose body is the `try`; `RealDeps` wires the real step and opens nothing); the self-check test asserts the exact `-Wait -PassThru` one-liner (`-PassThru` then `WaitForExit()` can leave a null exit code on 5.1 and fail every setup); nits: the new step 6 lines go after `:scale_task` (a rerun skips what comes before), a log writer tested on a temp file, every new elevated one-liner pins `PSModulePath` or uses .NET calls, the compiler refusal's label, a misplaced risk sentence, a process list that skips John's own PowerShell and shows an old program, and softer Smart App Control words to check against the build. Stage at the cap with round 3's integrations unreviewed |
| plan (resize, phase H and G changes) | John | 2026-10-14 | Accepted the gate at the cap with b round 3's integrations unreviewed; the diff gate checks the build against them |
| diff (resize, phases A-C, E, F, H) | a (gpt-6.1-sol) | 1 (full, `plugin/live-scale...plugin/resize`) | 0 blockers, 1 should-fix (a test gap), 0 nits; 0 refuted, 0 downgraded to nit. Fixed: the offset fixture put the shift in the patch's base, so GNU patch failed outright and the test passed without the hunk check; the target is now shifted, a dry run proves GNU patch alone takes it with an offset, and removing the check makes the test fail |
| diff (resize, phases A-C, E, F, H) | b panel (opus-5.5), 6 lenses | 1 (full) | 0 blockers, 6 should-fix (a failed update named a stale build log, found by two lenses; a hash rule for a blocked program breaks on each rebuild; three elevated one-liners load modules from the user's path; start program errors go to a log the panel does not name; the kill-on-close check passed without the flag; the 60 s continuation was pinned only to about 21 s), about 20 nits, 0 refuted, 0 downgraded to nit. All should-fix and 12 nits integrated. Not taken: a log-only nit (mark the sequence given up when the fifth ask matches), which would break phase B's six-pick rule; and the last-line rule for repeated start-program errors, which cannot work while another line always sits between two repeats (accepted: the log grows only if the job or the SMBIOS read fails at every start). Skipped as style: enums for the C# string tags, a nullglob subshell, the job list in three places, the panel's redundant guards |
| diff (resize, phases A-C, E, F, H) | b panel (opus-5.5), 6 lenses | 2 (full) | 0 blockers, 7 should-fix (build failures after cmake and offset patches still left no reason in the build log, found by two lenses; the blocked-program message missed antivirus; a client build that fails during Run setup again got the setup words; test gaps: a stale patch id on the quick path, a failed update keeping the old client, `main.c` never compiled in the tarball case), about 20 nits, 2 refuted (the 60 s window and the give-up reset are tested: mutations to 59, 45 and 30 s and a dropped reset each fail `late-change`), 0 downgraded to nit. All should-fix and 15 nits integrated; skipped: the panel's redundant checks next to `.finished`, which the plan names |
| diff (resize, phases A-C, E, F, H) | b panel (opus-5.5), 6 lenses | 3 (full, cap) | 0 blockers, 7 should-fix (an interrupted Run setup again named "Continue setup"; the run-time Add-Type working folder was not really pinned, found by two lenses; a zero-byte patch counted as applied; no pin-change reminder for where the IDD stores the ask; docs did not say CI skips the pwsh tests; test gaps: a one-side resize, and a setup round with stale patches), about 20 nits, 0 refuted, 0 downgraded to nit. All should-fix and 15 nits integrated; skipped: enums for the C# string tags, a parser check of setup.cmd's one-liners. Stage at the cap with round 3's fixes unreviewed by stage b |
| diff (resize, phases A-C, E, F, H) | a (gpt-6.1-sol) | 2 (rerun on the final diff, 06c8416) | 0 findings, 0 refuted, 0 downgraded to nit: "The committed diff is sound; no actionable defects found across the requested scope". Gate closed |
| plan (setup checks) | a (gpt-6.1-sol) | 1 (full) | 2 P2, 0 refuted; both integrated: one deadline (300 s) from the step 6 boot's first check or the Continue click, checked on every waiting path (QMP failure and a restarting guest agent included), replacing the port-based grace and boot limit; phase C injects each fault in a Run setup again boot before setup.cmd, with faults setup.cmd leaves alone, and the allow-list, mismatch and scale-task Run setup again cases go to tests |
| plan (setup checks) | a (gpt-6.1-sol) | 2 (full) | 2 P2, 0 refuted; both integrated: the deadline counts from the boot's start (`vm_exec` at VM start, `event_record` at each RESET, Continue at the click), so a late first check and a Continue after a Windows restart both get the spec's limits; tests for each |
| plan (setup checks) | a (gpt-6.1-sol) | 3 (full, cap) | 1 P2, 0 refuted; integrated, not reviewed again by stage a: every step 6 call without `--follow` resets the limits from the click, with no dependence on the stop marker, so a Continue after a Windows restart gets its full limits; test for a late click after a RESET |
| plan (setup checks) | b single (opus-5.5) | 1 (full) | 0 blockers, 9 should-fix, 8 nits, 0 refuted; all integrated (section rewritten): Continue resets the limits only after a stop, which RESET keeps, so repeated command-line calls still meet them; a wrong answer clears step5 so Continue (labelled Run setup again) repeats the install and the old-driver words stay true; Continue hides only for a wrong answer, and other step 6 failures keep their buttons; at a time-out with Windows off the two display buttons show directly (no arming); agents words name each part from the reply's parts, and qmp has words; the check's codes are 0, 10 and 11, with any other code "could not run"; drives not ready are skipped; the first-install trial moves into phase 0, and net stop moves before pnputil; the share stop's words point to the panel's display buttons; an outer limit for restart loops; phase 0 lists the share from the normal session and its loop has a timeout; tests that seed the removed stamps named; the time-out order stated; window-closed instead of client; stamps written by temp file and mv; README anchors |
| plan (setup checks) | b single (opus-5.5) | 2 (full) | 1 blocker, 4 should-fix, 7 nits, 0 refuted; all integrated: wrong answers keep `setup_back5` (step 5 reply, step5 cleared), since the panel drops a failed reply whose step differs from the plan's, and only time-outs use the new step 6 stop, read by the panel from its job record's reply.stop; a client open with unknown or waiting at the deadline is idd-missing, and qmp needs two failed calls; phase 0's first-install trial uses the new net stop order, lists the drive and names the media folder; Find-Share's tests assert one integer with items from the fake listing, a throw, and one whole-script run; the tests that use the removed stamps or the step 6 rollback named; references corrected; the CLI's next names the flags; the time-out words point to the display buttons, with a repeat_line field; :share_missing jumps by code and adds a hint when the check could not run; more superseded lines; the 300 s limit set against phase G's boot times |
| plan (setup checks) | b single (opus-5.5) | 3 (full, cap) | 0 blockers, 6 should-fix, 6 nits, 0 refuted; all integrated, not reviewed again: every step 6 failure writes the stop marker, so Continue always gets fresh limits; once the other checks pass, step 6 waits only for the scale task, so a short fault while the user signs in cannot stop setup; the panel words carry both spec conditions, with drafts for each time-out; the README names the buttons the panel shows; the share check retries a failed listing until its deadline; the first-install trial needs an image that never ran setup.cmd; nits: guest-boot named for phase C case 4, the net stop before the copy kept, a hung share accepted as a risk, step6-qmp-failed reset, test anchors and four more panel and worker cases |
| plan (setup checks) | John | 2026-10-17 | Accepted the plan gate at stage b's cap, with round 3's edits integrated and not reviewed again |
| diff (setup checks, phases A-B) | a (gpt-6.1-sol) | 1 (full) | 2 P2, 0 refuted, 0 downgraded to nit; both confirmed and integrated by Claude, test first: step6-checked now holds the boot stamp it ran under and counts only while that stamp is current, so a check still running at a RESET cannot carry its results into the new boot (reproduced before the fix: setup finished on the old boot's results); a step 6 stamp that cannot be written stops with reason record instead of waiting without a limit |
| diff (setup checks, phases A-B) | a (gpt-6.1-sol) | 2 (full) | 2 P2, 0 refuted, 0 downgraded to nit; both confirmed and integrated by Claude, test first: step 6 checks that the boot stamp is unchanged after its QMP call and again before it records its results, so a RESET during a QMP or guest-agent call cannot finish setup on the old boot (reproduced before the fix; the test fails with either check removed); step6_stamp writes through its own mktemp file, so Continue and a RESET writing the same stamp cannot collide |
| diff (setup checks, phases A-B) | a (gpt-6.1-sol) | 3 (full, cap) | 3 P2, 1 refuted, 0 downgraded to nit; 2 confirmed and integrated by Claude, test first: a boot token (step6-boot, new at VM start and at each RESET) replaces the whole-second boot stamp for telling boots apart, so a RESET in the same second still counts; the outer limit also ends the scale wait, so a restart loop that passes the other checks each boot stops. Refuted: "a RESET after the final check, during the stamp write, finishes setup on pre-reset states": every result that call uses (the ports, the agents' replies) was read in one boot, before the restart, so the checks did pass in that boot. Full suite 886/886 |
| diff (setup checks, phases A-B) | b panel (opus-5.5), 6 lenses | 1 (full) | 0 blockers, 7 should-fix, 25 nits, 0 refuted, 0 downgraded to nit (correctness and security: sound, nits only). Integrated (fixes by an opus-5.5 implementer, verified by Claude): the boot token merged into step6-since as one record written by one mv, with the step 6 file lifecycle and the one step6-checked reader in lib/setup.sh; the scale wait bounded at 3 x LANAI_SETUP_LIMIT + the scale limit, and restart waits past the outer limit stop as guest-boot; tests for the refusal's no-answer case, the deadline's closed-client and other-build reasons, the outer limit's guest-boot override and four more, each failing without its code; the time-out words name the two display buttons (repeat_line dropped), the scale words give the log files and "sign in within 2 minutes", README and setup.cmd words aligned; net.exe qualified; LANAI_SETUP_SCALE_LIMIT; deletion-guard tests removed; plan line 132 and as-built notes. Not taken: host sleep counting against the limits (a Risk; Continue recovers), an in-call QMP retry in place of the marker, agent ids in place of names. Full suite 894/894 |
| plan (setup checks) | John | 2026-10-18 | Step 6 simplified: a Windows restart during step 6 resets nothing; one limit from the check boot or the Continue, then the scale limit from when the other checks passed |
| diff (setup checks, phases A-B) | b panel (opus-5.5), 6 lenses | 2 (full) | 0 blockers, 6 should-fix, 17 nits, 0 refuted, 0 downgraded to nit (correctness, security and reliability: sound, nits only). John's call on the architecture should-fix (2026-10-18): simplify, a Windows restart during step 6 resets nothing; that removed the boot token, step6-run-since, the outer limit and the restart waits (net 154 lines fewer). Integrated with it (fixes by an opus-5.5 implementer, verified by Claude): the scale words name the Windows user who ran setup; one time-out ending that sends a setup.cmd stop to the display buttons; Shut Windows down, then Continue setup for wrong answers; window-closed words; README and setup.cmd name the buttons; bare net and powershell again in setup.cmd; every record write failure stops with record; tests that pin both limits from both sides, the panel's step guard, the share check's catch and its words, each failing without its code. Spec requirement 7 updated to match. Full suite 892/892 |
| diff (setup checks, phases A-B) | b panel (opus-5.5), 6 lenses | 3 (full, cap) | 0 blockers, 3 should-fix, 22 nits, 0 refuted, 0 downgraded to nit (correctness, security, reliability, architecture: sound, nits only). Integrated by Claude, not reviewed again: the panel's step 5 line adds the README's shared-folder clause; the README's security summary names the guest agent's refused command; a test that the scale task still gets its wait when the other checks first pass after the boot's limit (fails on the mutation that passed the scale call the boot's lateness). Nits taken: the time-out ending split into two sentences, the scale words in the order the user acts, setup.cmd's comment on how powershell resolves, spec 27 on how the IDD build is used, a Risk on a Continue after a job ended without a stop. Full suite 893/893 |
| diff (setup checks, phases A-B) | John | 2026-10-18 | Accepted stage b at its cap with round 3's fixes integrated and not reviewed again; approved one more stage a round (a 4th, past the cap) on the final diff |
| diff (setup checks, phases A-B) | a (gpt-6.1-sol) | 4 (full, rerun on the final diff, approved by John past the cap) | 1 P2, 0 refuted, 0 downgraded to nit; confirmed and integrated by Claude, test first: step6-checked is stamped when the other checks pass, not with the time read before slow QMP and guest-agent calls, so the scale task keeps its full 2 minutes (the new test fails on the old code). Full suite 894/894 |
| diff (setup checks, phases A-B) | John | 2026-10-18 | Closed the diff gate with the round 4 fix (one word, with its test) integrated and not reviewed again |
