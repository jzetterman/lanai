# Lanai proofs: runbook and results

Plan: [plan.md](plan.md), "Phase 1" and "Phase 6". Spec: [spec.md](spec.md).

Proofs 1 to 4 (phase 1) settled the riskiest unknowns before the VM work built on them.
Proof 5 is phase 6's lock proof, which runs before the rest of phase 6. You run all of
them by hand. Each proof runs on a full reflink copy of `~/.windows`, never on
`~/.windows` itself. If a proof fails, stop and record why. The work that depends on it
waits: phase 4 (VM lifecycle) for proofs 1 to 4, and the rest of phase 6 for proof 5.

Record every time with its timezone, for example `2026-09-28 14:00 EDT`. Paste command
output into the Result sections as it printed.

## The kit

| File | What it does |
|---|---|
| `bin/lanai-copy` | Makes the verified reflink copy. Holds QEMU's lock on the source disk while it copies. |
| `docs/plugin/proof-kit/proof-vm` | Builds and runs the proof VM from the spike's `vm_args` and the captured `omarchy-windows-vm` command line (`spike/test/fixtures/dockur-cmdline.txt`), plus each proof's devices. Refuses `~/.windows`, and refuses a copy that holds a symlink, a hard link, or a file that is the live one. `proof-vm help` lists its commands. `proof-vm args <copy> [options]` prints the QEMU line without starting anything. |
| `docs/plugin/proof-kit/lanai-proof.service`, `proof-unit-start`, `proof-unit-stop` | Proof 4's throwaway unit and its start and stop scripts. |
| `guest/lanai-scale.ps1` | Proof 1's scale script (first draft). |
| `guest/lanai-lock.cmd` | Proof 5's script: turns off locking inside Windows. `setup.cmd` will run the same file. |
| `lib/pins.sh` | The pinned downloads below. |

The proof VM differs from the spike VM in three ways. Its name is `lanai-proof`. It has
no serial monitor on the terminal, so you stop it with `proof-vm stop` or from Windows.
Its runtime files live in `$XDG_RUNTIME_DIR/lanai-proof/`. Like the spike, it forwards
host `127.0.0.1:13389` to the guest's RDP port.

## Pinned downloads

`proof-vm media` downloads these and checks each SHA-256. A mismatch deletes the file
and stops. Recorded 2026-09-28.

| File | Version | URL | SHA-256 |
|---|---|---|---|
| Looking Glass IDD zip | `B7-826-236efcb1` (the spike's pin; the client comes from the same build) | `https://looking-glass.io/artifact/B7-826-236efcb1/idd` | `34daa6ddb403c1f503fb2ace94360159818fda1795fc5c2be5cec1f4391d5d57` |
| SPICE guest agent MSI | 0.10.0 (the spike's pin) | `https://www.spice-space.org/download/windows/vdagent/vdagent-win-0.10.0/spice-vdagent-x64-0.10.0.msi` | `77629435705bc27dd7d2525e9d2084f72dbab5fdbf310e812f91332fe18d00eb` |
| WinFsp MSI | 2.1.25156 (release v2.1, "WinFsp 2025") | `https://github.com/winfsp/winfsp/releases/download/v2.1/winfsp-2.1.25156.msi` | `073a70e00f77423e34bed98b86e600def93393ba5822204fac57a29324db9f7a` (matches GitHub's published digest) |
| QEMU guest agent MSI | qemu-ga-win 110.2.3-2.el10 (the target of virtio-win's `latest-qemu-ga` link) | `https://fedorapeople.org/groups/virt/virtio-win/direct-downloads/archive-qemu-ga/qemu-ga-win-110.2.3-2.el10/qemu-ga-x86_64.msi` | `19dcf8abc30f70c2eb6e87282601fd0476e4e0b19936f63d9c80be30db0796ed` |
| virtio-win ISO | 0.1.302-1 (the target of virtio-win's `stable-virtio` link) | `https://fedorapeople.org/groups/virt/virtio-win/direct-downloads/archive-virtio/virtio-win-0.1.302-1/virtio-win-0.1.302.iso` | `303f7ae40dad495d6ae474fdc571df58958a4dbc5c37a522d80f9a203867949d` |

The ISO holds the viofs driver and `virtiofs.exe` in `viofs\w11\amd64\`. Its
`guest-agent\qemu-ga-x86_64.msi` is byte for byte the qemu-ga MSI above. `media`
unpacks `looking-glass-idd-setup.exe` from the verified IDD zip on every run, and
copies the verified SPICE agent into the setup disk; it never reuses the spike's copies.

## Before you start

1. Use the main checkout on branch `plugin/v1`. The kit reuses the spike's built
   Looking Glass client from `spike/work/`, which only that checkout has. Save the paths
   the runbook uses in a small file, so every terminal can load them:

   ```sh
   cd ~/Development/github/jzetterman/lanai
   git switch plugin/v1
   mkdir -p ~/lanai-proofs    # scratch; must be on the same btrfs filesystem as ~/.windows
   printf 'R=%q\nK=%q\nS=%q\n' "$PWD" "$PWD/docs/plugin/proof-kit" ~/lanai-proofs \
     >~/lanai-proofs/env
   source ~/lanai-proofs/env
   ```

   **In every new terminal, and after every log-in, run `source ~/lanai-proofs/env`
   first.** `$R` is the checkout, `$K` the kit and `$S` the scratch folder.

2. Check that the spike's client is there: `$R/spike/work/build/looking-glass-client`
   (from `spike/lgtest build`). Check that `/usr/lib/virtiofsd --version` prints a
   version. Paths you give the kit must not contain a comma or a newline; it refuses
   them.
3. Stop the container VM with `omarchy-windows-vm stop`. Then `omarchy-windows-vm status`
   shows it stopped.

## Step 0: make the test copy and the setup media

```sh
"$R/bin/lanai-copy" ~/.windows "$S/lanai-proof"
"$K/proof-vm" media "$S/kit"
```

`lanai-copy` refuses while any VM holds the disk. It reads the whole disk twice, once
from the source and once from the copy, to compare them. That takes several minutes. It
ends with `copied ... verified N entries by size and SHA-256`. `media` fills
`$S/kit/setup/` (the setup USB disk) and downloads the ISO to
`$S/kit/virtio-win-0.1.302-1.iso`.

### Result

- Date and time: 2026-09-28 15:30-15:36 EDT
- `lanai-copy` last line, and how long it took: `copied /home/john/.windows to /home/john/lanai-proofs/lanai-proof; verified 7 entries by size and SHA-256`, 279 s
- `media` last line: `media ready: /home/john/lanai-proofs/kit/setup and /home/john/lanai-proofs/kit/virtio-win-0.1.302-1.iso` (downloads verified)

## Step 1: install the display pieces in the copy

The copy has Windows as the container left it, without the Looking Glass IDD. You install
it once; proofs 1-4 all use it.

```sh
"$K/proof-vm" run "$S/lanai-proof" --setup "$S/kit/setup"
```

A QEMU window opens. Sign in to Windows. From the USB drive in Explorer:

1. Run `looking-glass-idd-setup.exe`. Include the IVSHMEM driver. In the IDD helper, set
   Default refresh to 60.
2. Run `spice-vdagent-x64-0.10.0.msi` with the defaults.
3. Make the folder `C:\Lanai` and copy `lanai-scale.ps1` into it.
4. Shut down: Start, Power, Shut down. QEMU exits. This counts as the restart the IDD
   needs (the spike found that its input does not work before one).

### Result

- Date and time: 2026-09-28 15:37-16:15 EDT
- Anything unexpected:
  - Order changed on purpose: SPICE agent and `C:\Lanai\lanai-scale.ps1` first, the IDD last, because installing the IDD turns the setup display black (spike finding). Default refresh left alone: it is already 60 (checked in the IDD source during the spike).
  - Looking Glass input worked at once after the IDD install, before any restart (`Using Input: LGMP`). The spike had needed a restart first.
  - `proof-vm stop` (QMP `system_powerdown`) was ignored for 300 s because the IDD installer's final dialog was still open. After closing it, Start > Power > Shut down worked and QEMU exited 0. Lanai's `setup.cmd` runs every installer silently, and the bar's forced stop covers a guest that ignores shutdown.

## Proof 1: display scale

The VM starts with the SMBIOS OEM string `lanai-scale=150`. `lanai-scale.ps1` reads it
and sets the Looking Glass monitor's scale with `DisplayConfigSetDeviceInfo` (relative
DPI).

```sh
"$K/proof-vm" run "$S/lanai-proof" --scale 150    # terminal 1
"$K/proof-vm" client                              # terminal 2
```

In the Looking Glass window:

1. Sign in. Open Windows PowerShell (not as administrator) and check the OEM string:
   `(Get-CimInstance Win32_ComputerSystem).OEMStringArray`. It lists `lanai-scale=150`.
2. Run `powershell -ExecutionPolicy Bypass -File C:\Lanai\lanai-scale.ps1`. Copy what it
   prints: each display's name and path, the recommended, current and allowed scale, and
   `Scale is now ...`.
3. Check that text got bigger at once, and that Windows did not ask you to sign out.
   Settings, System, Display, Scale shows 150%.
4. Resize the Looking Glass window so Windows changes resolution: make it float and drag
   a corner, or tile it beside another window. Settings, Display resolution shows the new
   size. Scale still shows 150%.
5. Restart Windows (Start, Power, Restart). Sign in. Do not run the script. Check Scale.
   Then run the script again and copy its output.
6. Make the window small, about 1024x768 (float it and drag). Run
   `powershell -ExecutionPolicy Bypass -File C:\Lanai\lanai-scale.ps1 -Scale 250`, then
   the same with `-Scale 300`. Copy the output of each and what Scale shows.
7. For the fallback, copy the output of
   `reg query "HKCU\Control Panel\Desktop\PerMonitorSettings" /s`.
8. Shut down from Windows, or run `"$K/proof-vm" stop`.

If the script prints `Error:`, copy `%LOCALAPPDATA%\Lanai\lanai-scale.log` into the
Result. To try a fixed script, get the new `guest/lanai-scale.ps1` into the checkout, run
`"$K/proof-vm" media "$S/kit"` again (it copies the script into the setup disk), start
the VM with `--setup "$S/kit/setup"` as in step 1, and copy the script from the USB drive
to `C:\Lanai`, replacing the old one.

Pass: 150% applies without a sign-out, holds after the Looking Glass window is resized to
a different resolution, and survives a reboot. Also try 250% and 300% at a small window,
where Windows caps DPI by resolution, and record what happens. Fallback to record:
`PerMonitorSettings\<id>\DpiValue`, applied at the next sign-in.

### Result

- Date and time: 2026-09-28 16:15-16:45 EDT
- OEM strings: `lanai-scale=150`
- Script output (step 2):
  ```
  Display: name 'Looking Glass', path '\\?\DISPLAY#LGD1DDD#1&28a6823a&0&UID256#{e6f07b5f-ee97-4a90-b076-33f57bf4eaa7}'
  Recommended 100%, current %, allowed 100% to 350%; want 150%
  Scale is now 150%.
  ```
- Applied at once, no sign-out (yes/no): yes. A controlled redo with `-Scale 100` then `-Scale 150` changed Settings to 100%, then 150%, with no sign-out prompt.
- After resize (resolution, scale): John set 125% by hand (it looked best). Scale stayed 125% through every resize; the Windows resolution followed the window within about 1 s.
- After restart, before the script (scale): 125% (survived the restart).
- Script output after restart: `Recommended 100%, current %, allowed 100% to 250%; want 150%` then `Scale is now 150%.` (the allowed maximum fell with the smaller window).
- 250% at small window (about 1024x768): `allowed 100% to 125%; want 250%`, `Windows allows at most 125% at this resolution; using that.`, `Scale is now 125%.`
- 300% at small window: same cap, `Scale is now 125%.`
- `PerMonitorSettings` output: `HKCU\Control Panel\Desktop\PerMonitorSettings\LGD1DDD1_01_07EA_BC^589876EA6875D582DD89E909A215592A`, `DpiValue REG_DWORD 0x1` (one step above recommended, 125%).
- `lanai-scale.log`, if the script failed: not needed.
- Pass (yes/no), and why: **yes.** Applies at once without a sign-out, holds across resizes, survives a restart, and clamps cleanly to Windows' resolution cap.
- Notes for later phases:
  - Bug: the script prints `current %` blank in some states (at 100%, and once at 125%); it printed `current 125%` correctly in another. Cosmetic; fix the current-scale lookup.
  - Windows caps the scale by resolution. Lanai applies the scale at sign-in at the window's size then; enlarging the window later does not raise it. Acceptable for v1 (the window normally opens fullscreen or tiled).
  - UX: resizing the Looking Glass window with Shift + right-drag accelerates instead of tracking the mouse. Likely the client's pointer warping or confinement confusing Hyprland's drag. Investigate client pointer options before phase 7. (Omarchy's resize binding is Super and the right mouse button, not Shift. Settled by `wayland:warpSupport=no`: see [Resize drag (2026-10-23)](#resize-drag-2026-10-23).)
  - Kit: `proof-vm client` has no wait for the VM's shared-memory file (the harness's `client` does), so starting it right after `run` can fail with "Invalid path to the shared memory file". Start it once the VM is up.

## Proof 2: virtiofs file sharing

virtiofsd runs as you and shares a scratch folder (not `~/Windows`) as the tag `lanai`.
The QEMU line adds the shared-memory RAM backend and `vhost-user-fs-pci`.

Prepare the share, with an escape route for the guest to try:

```sh
mkdir -p "$S/share" "$S/outside"
echo from-linux >"$S/share/from-linux.txt"
echo secret >"$S/outside/secret.txt"
ln -s "$S/outside" "$S/share/escape-abs"      # absolute symlink out of the share
ln -s ../outside "$S/share/escape-rel"         # relative symlink out of the share
ln -s /etc/hostname "$S/share/hostname-link"   # symlink to a host file
```

Start the VM with the share, the setup disk and the virtio-win ISO:

```sh
"$K/proof-vm" run "$S/lanai-proof" --share "$S/share" --setup "$S/kit/setup" \
  --iso "$S/kit/virtio-win-0.1.302-1.iso"                       # terminal 1
"$K/proof-vm" client                                            # terminal 2
ps -o user,pid,args -C virtiofsd                                # terminal 3: owner
```

In Windows, open an administrator Command Prompt. `D:` below is the virtio-win CD; use
the letter Explorer shows.

1. Check for the driver: `pnputil /enum-drivers | findstr /i viofs`. Copy the output.
2. If it lists nothing, run `pnputil /add-driver D:\viofs\w11\amd64\viofs.inf /install`.
   Device Manager, System devices, then shows "VirtIO FS Device" without a warning sign.
3. Run `winfsp-2.1.25156.msi` from the USB drive with the defaults.
4. Install the service:

   ```bat
   mkdir "C:\Program Files\Lanai"
   copy D:\viofs\w11\amd64\virtiofs.exe "C:\Program Files\Lanai\"
   sc create VirtioFsSvc binpath= "C:\Program Files\Lanai\virtiofs.exe" start= auto depend= "WinFsp.Launcher/VirtioFsDrv" DisplayName= "Virtio FS Service"
   sc start VirtioFsSvc
   ```

5. Explorer shows a new drive (usually `Z:`). Note its letter.
6. Round trip: open `Z:\from-linux.txt` (it says `from-linux`). Make `Z:\from-windows.txt`
   with some text. On the host, run `cat "$S/share/from-windows.txt"` and
   `stat -c '%U %a' "$S/share/from-windows.txt"`.
7. Try to leave the share, and copy each result:

   ```bat
   dir Z:\..
   type Z:\..\outside\secret.txt
   dir Z:\escape-abs
   type Z:\escape-abs\secret.txt
   type Z:\escape-rel\secret.txt
   type Z:\hostname-link
   ```

8. Shut down from Windows.

Pass: files round-trip; `..` and a planted host symlink pointing outside the share cannot
be followed from the guest.

### Result

- Date and time: 2026-09-28 16:30-17:00 EDT
- virtiofsd owner (`ps`): `john`, `/usr/lib/virtiofsd --socket-path=/run/user/1000/lanai-proof/virtiofs.sock --shared-dir /home/john/lanai-proofs/share --sandbox namespace`. Its warnings (no root uid/gid, file handles disabled, fd limit 524288) are normal for an unprivileged run.
- viofs driver present before step 2 (output): `Original Name: viofs.inf` (dockur installed it). The VirtIO FS Device showed Status OK.
- Service start output: `VirtioFsSvc` already existed with the runbook's settings and showed RUNNING, but no drive appeared. Running `virtiofs.exe -d -1 -D -` by hand showed the cause: after the FUSE INIT request it failed with `The service VirtIO-FS has failed to start (Status=c0000002)` (not implemented). **dockur's older viofs driver does not work with virtio-win 0.1.302's `virtiofs.exe`.** After `pnputil /add-driver E:\viofs\w11\amd64\viofs.inf /install` (driver installed on the device, no restart needed), the same run printed `Init: MaxWrite 1048576 bytes, MaxPages 256` and `The service VirtIO-FS has been started.`
- Drive letter: `Z:`
- Round trip (both files, host owner and mode): `Z:\from-linux.txt` read `from-linux`; `Z:\from-windows.txt` appeared on the host as `hello from windows`, owner `john`, mode 664.
- Step 7 outputs: `dir Z:\..` listed the share's own root; `type Z:\..\outside\secret.txt`, `type Z:\escape-abs\secret.txt` and `type Z:\escape-rel\secret.txt` each failed with "Cannot find path"; `dir Z:\escape-abs` listed only the link itself; `type Z:\hostname-link` failed ("syntax is incorrect"). `secret.txt` on the host is unchanged.
- Pass (yes/no), and why: **yes.** Files round-trip as the user, and neither `..` nor planted symlinks leave the share.
- Notes for later phases:
  - **setup.cmd must always install the pinned viofs driver** (`pnputil /add-driver ... /install`), not only "if missing": dockur's older driver fails with the current `virtiofs.exe`. Plan phase 6 needs this change.
  - dockur already creates a `VirtioFsSvc` service; setup must update its settings (`sc.exe config`), not only create it.
  - Runbook: in PowerShell use `sc.exe` (`sc` is Set-Content); the virtio-win CD's letter varies (E: here). Check at the next boot that the service mounts `Z:` by itself.

## Proof 3: QEMU guest agent and clock

**Step 8 suspends your computer. Save your work first.**

The VM gets the guest agent channel (`org.qemu.guest_agent.0` on
`$XDG_RUNTIME_DIR/lanai-proof/qga.sock`). The agent may run only `guest-sync`,
`guest-sync-delimited` and `guest-set-time`.

```sh
"$K/proof-vm" run "$S/lanai-proof" --qga --setup "$S/kit/setup"   # terminal 1
"$K/proof-vm" client                                              # terminal 2
```

In Windows, open an administrator Command Prompt:

1. Run `qemu-ga-x86_64.msi` from the USB drive with the defaults.
2. Run `sc qc QEMU-GA`. Copy `BINARY_PATH_NAME`.
3. Add the allow-list to the service's command line. Keep every argument step 2 showed,
   and add only `--allow-rpcs=...`. With the usual arguments (`-d --retry-path`):

   ```bat
   sc config QEMU-GA binPath= "\"C:\Program Files\Qemu-ga\qemu-ga.exe\" -d --retry-path --allow-rpcs=guest-sync,guest-sync-delimited,guest-set-time"
   sc stop QEMU-GA
   sc start QEMU-GA
   sc qc QEMU-GA
   ```

On the host:

4. A refused command: `"$K/proof-vm" qga '{"execute":"guest-exec","arguments":{"path":"cmd.exe"}}'`.
   The second reply is an error saying the command is disabled. Copy both replies.
5. An allowed command: `"$K/proof-vm" set-time`. The second reply is `{"return": {}}`.
6. Start the watcher as your user, in terminal 3:
   `"$K/proof-vm" sleep-watch | tee "$S/sleep-watch.log"`.
7. Show both clocks in UTC, side by side. Host, terminal 4:
   `while :; do printf '\r%s ' "$(date -u +%T.%1N)"; sleep 0.1; done`.
   Windows PowerShell:
   ``while ($true) { Write-Host -NoNewline ("`r" + [DateTime]::UtcNow.ToString('HH:mm:ss.f')); Start-Sleep -Milliseconds 100 }``.
   Take a screenshot with both in view. Note the difference.
8. Suspend: `systemctl suspend`. Wait 2 minutes by a timer. Wake the computer.
9. Take a screenshot at once, then one 60 s after the wake. Note the difference in each.
10. Copy `$S/sleep-watch.log`. It shows `PrepareForSleep(true)`, `PrepareForSleep(false)`
    and the `set-time` replies, with UTC times.
11. Stop the watcher (Ctrl-C). Shut down from Windows.

Pass: a user-level `dbus-monitor --system` sees logind's `PrepareForSleep`, and
`guest-set-time` brings the guest within 2 s of the host within 60 s of resume. A
disallowed command (`guest-exec`) is refused.

### Result

- Date and time: 2026-09-28 17:00-17:17 EDT
- `BINARY_PATH_NAME` before and after: before `"C:\Program Files\Qemu-ga\qemu-ga.exe" -d --retry-path`; after `"C:\Program Files\Qemu-ga\qemu-ga.exe" -d --retry-path --allow-rpcs=guest-sync,guest-sync-delimited,guest-set-time`. The `sc config` line must run in Command Prompt: PowerShell mangles its nested quotes.
- `guest-exec` replies: `{"error": ... "JSON parse error, stray '\uFFFD'"}` (the agent's reply to the 0xFF flush byte, expected), `{"return": 18457}` (sync), `{"error": {"class": "CommandNotFound", "desc": "Command guest-exec has been disabled: the command is not allowed"}}`
- `set-time` replies: the same flush error, `{"return": 28158}`, `{"return": {}}`
- Clock difference before suspend: host 21:12:26.7, guest 21:12:26.6 UTC (0.1 s)
- Right after wake: no screenshot before the sync; the sync landed 3 s after wake.
- 60 s after wake: at 21:16:28.0 UTC (about 28 s after wake) host and guest both read 21:16:28.0 (0.0 s).
- `sleep-watch.log`:
  ```
  2026-09-28T21:05:52.749Z watching PrepareForSleep on the system bus
  dbus-monitor: unable to enable new-style monitoring: ... Falling back to eavesdropping.
  2026-09-28T21:13:45.983Z PrepareForSleep(true): host is suspending
  2026-09-28T21:16:00.659Z PrepareForSleep(false): host resumed; setting the guest clock
  {"error": {"class": "GenericError", "desc": "JSON parse error, stray '\uFFFD'"}}
  {"return": 2449}
  {"return": {}}
  2026-09-28T21:16:03.663Z set-time done
  ```
  Host suspend (logind and kernel): 17:13:46 to 17:16:00 EDT (2 min 14 s, deep S3).
- Pass (yes/no), and why: **yes.** A user-level `dbus-monitor --system` sees logind's `PrepareForSleep` (both edges) despite falling back from monitor mode; `guest-set-time` brought the guest to 0.0 s of the host within 28 s of resume; `guest-exec` is refused by the allow-list.
- Notes for later phases:
  - `qga_reply` must expect the parse-error line the 0xFF flush produces before the sync reply (the plan's "skip to 0xFF" rule covers it).
  - The `VirtioFsSvc` share now mounts `Z:` by itself at boot, after the proof 2 driver update.
  - An idle Windows shut down cleanly in 8-9 s from QMP `system_powerdown` twice (proof 1 and proof 2 boots), well inside Omarchy's roughly 20 s reboot window.

## Proof 4: shutdown paths

**This proof logs you out twice and reboots twice. Before each, save your work, close
other apps, and save the Results you have typed so far in this file.**

The throwaway unit `lanai-proof.service` runs the proof VM the way the plan's
`lanai-vm.service` will: `Type=exec`, `PartOf=` and `After=graphical-session.target`,
`Slice=session.slice`, `TimeoutStopSec=2min`. Its start script holds a shutdown delay
inhibitor whose watcher runs `systemctl --user stop --no-block lanai-proof.service` on
`PrepareForShutdown(true)`, then runs QEMU. Its stop script sends QMP `system_powerdown`,
logs every QMP event with a UTC time, and waits for QEMU to exit. A clean shutdown is
the event `{"event": "SHUTDOWN", "data": {"guest": true, ...}}`.

Install the unit, and note the lingering setting so you can restore it at the end:

```sh
mkdir -p ~/.config/systemd/user
sed -e "s|@KIT@|$K|g" -e "s|@COPY@|$S/lanai-proof|g" "$K/lanai-proof.service" \
  >~/.config/systemd/user/lanai-proof.service
systemctl --user daemon-reload
loginctl show-user "$USER" -p Linger
```

Record the two time limits that apply, before round A:

```sh
busctl get-property org.freedesktop.login1 /org/freedesktop/login1 \
  org.freedesktop.login1.Manager InhibitDelayMaxUSec
systemctl show "user@$(id -u).service" -p TimeoutStopUSec
```

Each run starts the same way: `systemctl --user start lanai-proof.service`, then
`"$K/proof-vm" client`, then sign in to Windows and leave it idle at the desktop. Read the
unit's log with `journalctl --user -u lanai-proof -o short-iso-precise` (add `-b -1`
after a reboot).

To log out, always use the Omarchy menu: System, then Logout. It runs
`omarchy-system-logout`, which closes every window (the Looking Glass client too), and
runs `uwsm stop` 2 s after it starts.

What failure looks like: the unit's log has no `QEMU exited` line, or no `SHUTDOWN` event
with `"guest": true`. Either means QEMU was killed before Windows finished. Record the
log's last line and its time.

Round A, lingering off (`loginctl disable-linger`):

1. **Logout.** Start a run. Log out as above. Log back in and run
   `source ~/lanai-proofs/env`. Copy:
   - the unit's log for that run;
   - `journalctl --user -b -o short-iso-precise | grep -E 'lanai-proof|graphical-session.target|wayland-wm'`;
   - `journalctl -b -o short-iso-precise -u systemd-logind | tail -n 20` (the "Removed
     session" line shows when `uwsm start` exited).
2. **Reboot.** Start a run. Run `systemctl reboot`. After the reboot, log in, run
   `source ~/lanai-proofs/env`, and copy the unit's log with `-b -1` and
   `journalctl -b -1 -o short-iso-precise | grep -iE 'inhibit|lanai|shutdown'`.
   Note the time from `PrepareForShutdown(true)` to `QEMU exited`.

Round B, lingering on (`loginctl enable-linger`): repeat steps 1 and 2.

Then, with either setting:

3. **Sign-in screen.** Start the unit and the client, but do not sign in to Windows.
   Wait for the sign-in screen, then run `systemctl --user stop lanai-proof.service`.
   Copy the log.
4. **Locked session.** Start the unit and the client, sign in, lock Windows (Windows
   key + L), then run `systemctl --user stop lanai-proof.service`. Copy the log.

Clean up:

```sh
systemctl --user stop lanai-proof.service
rm ~/.config/systemd/user/lanai-proof.service
systemctl --user daemon-reload
loginctl disable-linger    # or enable-linger, to match what show-user printed
```

Pass: (a) logout gives the VM its stop timeout, with `uwsm start` staying alive until the
VM unit stops, and the result is a clean shutdown (QMP `SHUTDOWN` with `"guest": true`);
(b) at reboot, the delay inhibitor starts Windows' shutdown, and the time an idle Windows
takes is recorded for the README. Also confirm `system_powerdown` shuts Windows down at
the sign-in screen and in a locked session. If (a) fails, the 2-minute logout requirement
cannot be met as designed. Record it as a spec question; phase 4 waits for the answer.

### Result

- Date and time: 2026-09-28, from 17:19 EDT (21:19 UTC).
- Lingering at the start: `Linger=no`.
- `InhibitDelayMaxUSec`: 15000000 (15 s).
- `TimeoutStopUSec` of `user@<uid>.service`: 5s.
- Logout path used: Omarchy menu, System, Logout (`omarchy-system-logout`, then `uwsm stop`).
- A1 logout (lingering off): PASS. `uwsm stop` at 21:56:44.618 UTC; `POWERDOWN` at :44.831;
  `SHUTDOWN` with `"guest": true` at 21:56:56.509; `QEMU exited 13 s after system_powerdown`;
  unit stopped at :58.095; the compositor unit stopped at :58.824; logind removed the
  session at :58.984. The session waited for the VM. Log: `~/lanai-proofs/proof4-A1.log`.
- A2 reboot (lingering off): PASS. `PrepareForShutdown(true)` seen at 22:00:49.995 UTC (the
  eavesdropping fallback works); `POWERDOWN` at :50.024; `SHUTDOWN` with `"guest": true`
  at 22:00:57.323; `QEMU exited 7 s after system_powerdown`; about 8 s from the signal to
  the unit stopping, inside the 15 s delay. Log: `~/lanai-proofs/proof4-A2.log`.
- B1 logout (lingering on): PASS. `uwsm stop` at 22:05:35.496 UTC; `SHUTDOWN` with
  `"guest": true` at 22:05:46.309; `QEMU exited 11 s after system_powerdown`; unit stopped
  at :47.555; the compositor unit stopped at :47.815. Log: `~/lanai-proofs/proof4-B1.log`.
- B2 reboot (lingering on): PASS. `PrepareForShutdown(true)` at 22:07:21.141 UTC;
  `SHUTDOWN` with `"guest": true` at 22:07:28.248; `QEMU exited 7 s after system_powerdown`;
  unit stopped at :29.390, about 8 s after the signal. Log: `~/lanai-proofs/proof4-B2.log`.
- Sign-in screen: PASS. Windows signs in automatically (dockur sets auto-logon), so we
  reached the screen by signing out from Start. Stop at 21:21:44 UTC; `POWERDOWN` at
  :44.265; `SHUTDOWN` with `"guest": true, "reason": "guest-shutdown"` at 21:21:51.158;
  `QEMU exited 7 s after system_powerdown`; unit stopped at :52.888. The unit reported a
  16.2G memory peak and a 1006.9M swap peak. The start script's `dbus-monitor` fell back
  to eavesdropping (new-style monitoring is denied to users); rounds A2/B2 show whether it
  still sees `PrepareForShutdown`.
- Locked session: FAIL. Locked from Start > user > Lock. Stop at 21:22:51 UTC; `POWERDOWN`
  at :51.298; no `SHUTDOWN` event. At 21:24:51 systemd hit `TimeoutStopSec`, sent SIGTERM
  (`terminating on signal 15`), and the unit failed with result 'timeout'. Windows was
  cut off without a shutdown (the copy, not `~/.windows`). Swap peak 1.8G.
  Diagnosis run: locked again, `stop --no-block` at 21:34:03 UTC (`POWERDOWN` logged).
  John unlocked about 20 s later: the desktop as it was, only Teams open, no shutdown
  screen. So Windows drops the press while locked; it does not defer it to the unlock.
  A second press over QMP did not reach QEMU: the stop script held the only QMP
  connection. John then chose Start > Shut down near the limit; systemd's SIGTERM
  landed at 21:36:03.652 before any `SHUTDOWN` event, so that run proves nothing about
  Teams. Swap peak 7.3G.
  Control run: unlocked desktop, Teams open, stop at 21:38:28 UTC; `SHUTDOWN` with
  `"guest": true` at 21:38:36.073; `QEMU exited 8 s after system_powerdown`. Teams does
  not block. The lock is the cause: a locked Windows 11 drops the ACPI power button.
  Spec question for phase 4; see the plan follow-ups.
- Idle Windows shutdown time for the README: 7 to 13 s from `system_powerdown` to QEMU
  exiting, over eight clean runs.
- Pass (yes/no), and why: yes for (a) and (b): logout waits for the VM and ends in a clean
  shutdown with lingering off and on, and reboot's delay inhibitor starts the shutdown well
  inside 15 s. The sign-in screen passes. The locked session fails: a locked Windows drops
  the ACPI power button. John chose (2026-09-28) to have setup turn off the Windows lock
  (the Linux session is the lock); fold it into the spec and plan before phase 4. Kit
  note: `proof-vm client` can start against the last run's stale `ivshmem` file and fail
  with "Invalid path to the shared memory file"; Lanai's client launch must wait for the
  new VM's file, not any file. Lingering restored to `no`.

## Extra check: QMP answers only after `ivshmem` exists

Added 2026-09-28 after proof 4's client race. Question: can the client wait for a QMP
command reply instead of for the `ivshmem` file, which a crashed or earlier run may
leave behind? Run three times, each in a fresh scratch directory `$D`, no guest disk:

```sh
qemu-system-x86_64 -nodefaults -display none -machine q35 -m 256 \
  -object memory-backend-file,id=m,mem-path="$D/ivshmem",size=128M,share=on \
  -device ivshmem-plain,memdev=m -qmp unix:"$D/q.sock",server=on,wait=off &
# Poll for 10 s: note whether ivshmem exists when q.sock first appears, then send
# qmp_capabilities + query-status with socat until a "status" reply arrives.
```

Result, all three runs: `ivshmem existed when socket first seen: no` and `ivshmem
present at first reply`. QEMU creates the QMP chardev before the memory backends
(`object_create_early` leaves `memory-backend-*` for later) and runs non-OOB QMP
commands only from its main loop, after every backend exists. The greeting may come
earlier, so only a command reply counts.

## Proof 5: Windows lock off (phase 6)

Plan: [plan.md](plan.md), "Phase 6", the lock proof. Spec: requirement 7 and row 7b.

Proof 4 found that a locked Windows drops the ACPI power button. `system_powerdown` did
nothing, and systemd killed QEMU at its stop timeout. So setup turns off every way
Windows can lock (spec requirement 7), with `guest/lanai-lock.cmd`. This proof runs the
real script on the test copy. First it shows that each lock path does lock Windows
before the script (the positive controls). Then it shows that after the script and one
restart, none of them does, and a stop from the host ends in a clean shutdown.

The copy already has the Looking Glass IDD, so QEMU's own window stays black. Do every
step in the Looking Glass client. The proof runs on `$S/lanai-proof`, never on
`~/.windows`.

"Locked" below means Windows shows the lock screen or the sign-in screen, and wants the
password.

Before you start:

1. Run `source ~/lanai-proofs/env`. Switch the main checkout to the branch
   `plugin/phase6`, which holds this section and `guest/lanai-lock.cmd`:

   ```sh
   git -C "$R" fetch origin
   git -C "$R" switch plugin/phase6
   ```

   To keep `$R` on another branch instead, point `K` at a checkout of `plugin/phase6`,
   and keep the spike's client from `$R`. The env file sets `K` back, so run both lines
   after every `source ~/lanai-proofs/env`:

   ```sh
   K=<path to a checkout of plugin/phase6>/docs/plugin/proof-kit
   export PROOF_CLIENT=$R/spike/work/build/looking-glass-client
   ```

2. Refresh the setup disk, so it holds `lanai-lock.cmd`: `"$K/proof-vm" media "$S/kit"`.
   It ends with `media ready`.
3. Stop the container VM with `omarchy-windows-vm stop`.
4. Have the Windows password at hand. Most controls end at the sign-in screen.

Start the VM and the client:

```sh
"$K/proof-vm" run "$S/lanai-proof" --setup "$S/kit/setup"   # terminal 1
"$K/proof-vm" client                                         # terminal 2
```

`client` waits up to 60 s for QEMU to answer a command on `qmp.sock`, disconnects, then
starts the client. A Windows restart keeps QEMU running. If the client window closes
during a restart, run `"$K/proof-vm" client` again. In Explorer, note the setup USB
drive's letter. The steps below call it `E:`.

Two key presses go in over QMP, from terminal 3. `qmp.sock` serves one client at a
time, and `client` has already let go of it. Each command holds the connection open for
1 s, because QEMU drops requests still queued when the client disconnects. Each prints
QEMU's greeting, then `{"return": {}}` twice. Check for both.

Windows key + L:

```sh
{ printf '%s\n' '{"execute":"qmp_capabilities"}' \
    '{"execute":"send-key","arguments":{"keys":[{"type":"qcode","data":"meta_l"},{"type":"qcode","data":"l"}]}}'
  sleep 1; } | socat - "UNIX-CONNECT:$XDG_RUNTIME_DIR/lanai-proof/qmp.sock"
```

Ctrl+Alt+Del:

```sh
{ printf '%s\n' '{"execute":"qmp_capabilities"}' \
    '{"execute":"send-key","arguments":{"keys":[{"type":"qcode","data":"ctrl"},{"type":"qcode","data":"alt"},{"type":"qcode","data":"delete"}]}}'
  sleep 1; } | socat - "UNIX-CONNECT:$XDG_RUNTIME_DIR/lanai-proof/qmp.sock"
```

The starting state. In Command Prompt, record the output of:

```bat
reg query HKLM\SOFTWARE\Microsoft\Windows\CurrentVersion\Policies\System /v EnableLUA
reg query HKLM\SOFTWARE\Microsoft\Enrollments /s /v ProviderID
reg query HKLM\SOFTWARE\Microsoft\Enrollments /s /v DiscoveryServiceFullURL
reg query HKLM\SOFTWARE\Microsoft\Enrollments /s /v UPN
```

`EnableLUA` is `0x0` when dockur's unattended install turned UAC off: every Command
Prompt of the signed-in administrator then runs with full rights, and "Run as
administrator" changes nothing. Do not count on it: John's install shows `0x1` (UAC on;
see the result below), so spec requirement 7's one administrator prompt stands for
installs with UAC on; the UAC-off case is with John. The `Enrollments` queries show the real data for the
MDM check. Stock Windows 11 has built-in subkeys with a `ProviderID`, so the script
counts an enrollment only by a non-empty `DiscoveryServiceFullURL` or `UPN`. Expect
none of those on this copy.

Step 1, the positive controls. Run each one on its own. After each one that locks, sign
back in before the next.

1. Lock in Start: Start, your user icon, Lock.
2. Lock in Ctrl+Alt+Del: send Ctrl+Alt+Del with the command above, then choose Lock.
3. Windows key + L: send it with the command above. It is a control, not a warm-up.
4. The call apps use: in Command Prompt, run `rundll32 user32.dll,LockWorkStation`.
5. Switch user: from Start, your user icon, or from the Ctrl+Alt+Del screen.
6. The secure screen saver alone: Settings, Personalization, Lock screen, Screen saver.
   Choose a screen saver (Blank works), set Wait to 1 minute, tick "On resume, display
   logon screen", and choose OK. Keep your hands off the client window for 2 minutes.
   The screen saver starts. Move the mouse: Windows must be locked. Sign in, then set
   the screen saver back to (None) and choose OK.
7. The inactivity limit alone. In an elevated Command Prompt (Start, type `cmd`, Run as
   administrator):

   ```bat
   reg add HKLM\SOFTWARE\Microsoft\Windows\CurrentVersion\Policies\System /v InactivityTimeoutSecs /t REG_DWORD /d 60 /f
   ```

   Restart Windows (Start, Power, Restart). Sign in if Windows asks. Keep your hands off
   for 2 minutes: Windows must be locked.

If a control does not lock, fix the control before step 2: find out why, and try again.
For the screen saver and the inactivity limit, first run `powercfg /requests`. A
request under DISPLAY (a video or a presentation app, for example) blocks both; close
what holds it. A path with no working control counts as unproven.

Then set up a user's earlier lock settings: turn the 1-minute secure screen saver back
on, as in control 6. `InactivityTimeoutSecs` is still 60 from control 7. From here on,
Windows locks after each idle minute until step 2; sign in each time.

Step 2, run the script:

1. The refusal, from a restricted prompt. With UAC off, a normal prompt has full
   rights, so open one without them: in Command Prompt, run
   `runas /trustlevel:0x20000 cmd`. In the new window, run
   `whoami /groups | findstr S-1-5-32-544`. The Administrators group must show "Group
   used for deny only". If it does, run `E:\lanai-lock.cmd`, then `echo %errorlevel%`.
   It must print that it needs administrator rights, then `1`, and change nothing.
   Close that window. If the group is not deny-only, record that and skip this check;
   phase 8's different-account test covers the refusal.
2. From an elevated Command Prompt, run `E:\lanai-lock.cmd`, then `echo %errorlevel%`.
   It must print `lanai-lock: locking inside Windows is off.`, then `0`. This copy is
   not in a domain or MDM, so no policy warning may appear.
3. Restart Windows. Some values load only at sign-in.

Step 3, nothing locks. Leave the settings as the script left them. Do not open the
screen saver dialog: saving it can write `ScreenSaverIsSecure` back.

1. In Command Prompt:

   ```bat
   reg query HKCU\Software\Microsoft\Windows\CurrentVersion\Policies\System /v DisableLockWorkstation
   reg query HKLM\SOFTWARE\Microsoft\Windows\CurrentVersion\Policies\System /v HideFastUserSwitching
   reg query HKLM\SOFTWARE\Microsoft\Windows\CurrentVersion\Policies\System /v InactivityTimeoutSecs
   reg query "HKCU\Control Panel\Desktop" /v ScreenSaveTimeOut
   reg query "HKCU\Control Panel\Desktop" /v ScreenSaverIsSecure
   ```

   Expect `0x1`, `0x1`, an error (the value is gone), `60` and `0`.
2. Repeat controls 1 to 5 from step 1. None may lock Windows. Record what each one
   shows: Lock and Switch user should be gone from Start and the Ctrl+Alt+Del screen.
   Leave the Ctrl+Alt+Del screen with Cancel.
3. Keep your hands off the client window for 3 minutes or more. The screen saver starts
   after 1 minute. Move the mouse: the desktop must come back, not the sign-in screen.
4. In PowerShell:

   ```powershell
   powercfg /a
   Get-PnpDevice -Class Bluetooth
   ```

   `powercfg /a` must show no Standby (S1, S2, S3 or S0 Low Power Idle), Hibernate or
   Hybrid Sleep as available. `Get-PnpDevice` must list no device; an error that
   nothing matches is fine. If either finds one, stop here and record it. The script
   leaves sign-in on wake and Dynamic Lock alone because neither can fire in this VM,
   and spec row 7b needs both unable to fire.
5. An extra control, recorded but not part of the pass: in Command Prompt, run
   `tsdiscon`. Record whether it leaves the session at the sign-in screen. If it does,
   sign back in.

Step 4, the domain and MDM warning. In an elevated Command Prompt:

```bat
set LANAI_FAKE_MANAGED=1
E:\lanai-lock.cmd
```

It must print the policy warning: `lanai-lock: this Windows is joined to a domain or
enrolled in MDM.`, then that a policy may turn the lock back on and shutdowns may end in
a forced stop. `setup.cmd` elevates itself, which drops the caller's environment, so the
variable works only when set in the elevated prompt that runs the script. Close that
prompt.

Step 5, stop from the host:

`stop` sends `system_powerdown` once and waits up to 300 s. Lanai waits only 2 minutes
(`TimeoutStopSec=2min`) and sends the press again every 10 s. So time each stop: `sent
system_powerdown` and `QEMU exited` both carry a UTC time.

1. Keep your hands off the client window until the screen saver (no longer secure)
   shows. Then, in terminal 3, run `"$K/proof-vm" stop`. It must print `QEMU exited`
   within 120 s of `sent system_powerdown`. After `system_powerdown`, QEMU exits only
   when Windows powers off.
2. Start the VM and the client again, and wait for the desktop. Open the Ctrl+Alt+Del
   screen with the command above and leave it open. Run `"$K/proof-vm" stop`. Record
   the result either way, with the time from `sent system_powerdown` to `QEMU exited`.
   Note that this sends one press, where Lanai would send one every 10 s. If Windows
   ignores the stop, `stop` gives up after 300 s with `still runs after 300 s`. Then
   choose Cancel on that screen and run `"$K/proof-vm" stop` again.

What failure looks like: a path in step 3 still locks Windows, a `reg query` result
differs, Windows asks for the password after the idle wait, or step 5.1 takes more than
120 s or ends with `still runs after 300 s`. If any lock path survives, stop and record
it. The rest of phase 6 waits.

Pass: in step 1, every control locked Windows. Step 2.2 (the elevated run) exited 0 and
printed no policy warning. Where step 2.1 ran, the refusal exited 1. In step 3, none of
the controls locked, the `reg query` results match, Windows stayed unlocked through 3
minutes of idle, and there is no sleep state and no Bluetooth device. Step 4 printed the
warning. Step 5.1 printed `QEMU exited` within 120 s of `sent system_powerdown`. Step
5.2 is recorded, clean or not; if not, the README names it (row 7b).

### Result

- Date and time: 2026-10-01, 16:43 to 18:53 EDT (20:43 to 22:53 UTC).
- Branch and commit of the kit's checkout: `plugin/phase6` at a6bbc1f, used through
  `K=<worktree>/docs/plugin/proof-kit` and `PROOF_CLIENT=$R/spike/work/build/looking-glass-client`.
- Starting state, `EnableLUA`: `0x1`. UAC is on in John's install, so the runbook's
  expectation of `0x0` (taken from dockur's stock unattend file) does not hold for every
  dockur install. Spec requirement 7's one administrator prompt stands.
- Starting state, `Enrollments` queries: `ProviderID` found 3 built-in subkeys ("Deploy
  Authority", "Cloud Authority", "Local Authority"); `DiscoveryServiceFullURL` and `UPN`
  found 0. The first version of the MDM check (ProviderID alone) would have warned on
  this unmanaged copy; the shipped check does not.
- Step 1, before the script (all locked, sign-in needed after each):
  - Lock in Start: locked.
  - Lock in Ctrl+Alt+Del (sent over QMP at 20:51:22 UTC): locked.
  - Windows key + L (QMP, 20:51:47 UTC, both `{"return": {}}` lines): locked.
  - `rundll32 user32.dll,LockWorkStation`: locked.
  - Switch user: not in Start with one account; offered on the Ctrl+Alt+Del screen, and
    it left the session at the sign-in screen.
  - Secure screen saver at 1 minute: locked.
  - `InactivityTimeoutSecs` 60, after a restart: locked.
- Step 2.1, refusal: UAC is on, so a normal Command Prompt has a filtered token and
  replaced the `runas /trustlevel` check. Output `lanai-lock: needs administrator rights.
  Run it from an elevated Command Prompt.`, error level `1`. (A first attempt ran in an
  elevated prompt by mistake and applied the settings, as it should there.)
- Step 2.2, elevated: `lanai-lock: locking inside Windows is off.`, error level `0`, no
  policy warning.
- Step 3, `reg query` output, after a restart: `DisableLockWorkstation` `0x1`,
  `HideFastUserSwitching` `0x1`, `InactivityTimeoutSecs` not found, `ScreenSaveTimeOut`
  `60`, `ScreenSaverIsSecure` `0`.
- Step 3, after the script (none locked):
  - Lock in Start: gone. Switch user: gone.
  - Lock in Ctrl+Alt+Del (QMP, 21:18:47 UTC): Lock and Switch user both gone.
  - Windows key + L (QMP, 21:18:58 and 21:19:30 UTC): stayed at the desktop.
  - `rundll32 user32.dll,LockWorkStation`: stayed at the desktop.
- Step 3, idle: 15 minutes idle, still at the desktop. No screen saver ran: after
  control 6 the screen saver had been set back to (None), and choosing Blank again in
  Settings never wrote `SCRNSAVE.EXE` (still absent at the end). So the idle check proved
  the inactivity lock gone, and the screen saver check was done directly:
  `scrnsave.scr /s` started the Blank screen saver, and a key press returned to the
  desktop with no password. Before that, the user's earlier secure screen saver was set
  again and `lanai-lock.cmd` rerun (error level `0`, `ScreenSaverIsSecure` back to `0`).
- Step 3, `powercfg /a`: S1, S2, S3, S0 Low Power Idle, Hibernate, Hybrid Sleep and Fast
  Startup all "not available" (firmware does not support them).
- Step 3, `Get-PnpDevice -Class Bluetooth`: "No Win32_PnPEntity objects found".
- Step 3, extra, `tsdiscon`: the Looking Glass screen went black and the session needed
  a sign-in (done from QEMU's screen). The script does not block it, and the spec does
  not require it. Whether Windows drops the power button in that state is not tested.
- Step 4, the warning as printed: `lanai-lock: locking inside Windows is off.` then
  `lanai-lock: this Windows is joined to a domain or enrolled in MDM. A policy` / `may
  turn the lock back on, and Lanai's shutdowns may then end in a forced stop.`
- Step 5.1, stop with the screen saver showing (started with a 20 s delayed
  `scrnsave.scr /s`): `sent system_powerdown` 22:48:33.545 UTC, `QEMU exited`
  22:48:43.554 UTC, 10 s. Clean.
- Step 5.2, stop with the Ctrl+Alt+Del screen open (QMP at 22:52:16 UTC): `sent
  system_powerdown` 22:52:22.184 UTC, `QEMU exited` 22:52:29.189 UTC, 7 s. Clean.
- Pass (yes/no), and why: **yes.** Every positive control locked Windows before the
  script, none did after it and a restart, the refusal and the elevated run returned 1
  and 0, the registry holds the planned values, no sleep state or Bluetooth exists, the
  MDM warning fires only when forced, and Windows shut down cleanly from the host with
  the screen saver showing (10 s) and with the Ctrl+Alt+Del screen open (7 s).
- Notes for later phases:
  - The setup boot shows QEMU's own screen as well as the Looking Glass screen, and
    Windows extends the desktop across both. The pointer then sits on QEMU's screen and
    is invisible in Looking Glass, and QEMU's screen goes black when Windows drops it.
    Phase 6's setup boot must show QEMU's screen only while the IDD is missing, and the
    proof kit should separate the setup disk from QEMU's window. Windows key + P,
    "Second screen only", fixed it in this run.
  - Host key combinations do not reach Windows: Omarchy takes Super shortcuts, and its
    Ctrl+Alt+Del closes all host windows. Anything Lanai or its README asks the user to
    press with those keys needs another route (QMP send-key, or the client's own key
    menu). (This holds outside the client's capture mode; see
    `docs/plugin/client-warp/plan.md`, requirement 3.)
  - The Looking Glass window closed on its own several times during the run while QEMU
    kept running; `proof-vm client` reopened it each time. Watch for this in phase 8.
  - Proof sessions ran the VM with dockur's 16 GiB and caused host memory pressure on
    John's 32 GiB machine; John wants 12 GiB on his install (see the project memory).

## Phase 6 hands-on setup run (2026-10-04)

The first end-to-end `lanai setup` on a copy of John's install, with John at
the keyboard. The copy: `lanai-copy ~/.windows ~/lanai-proofs/lanai-setup-test`
(verified, 7 entries; 4 min 37 s). Lanai's settings pointed at the copy, with 12 GiB
and 8 cores. Run from the phase 6 worktree.

- Steps 1 and 2 passed. Step 3: `lanai snapshot` took the snapshot (4 min 39 s,
  mostly hashing), then setup went on.
- Step 5's first media build failed: in the pinned virtio-win ISO, the
  `viofs/w11/amd64` files are hard links to `viofs/2k25/amd64`, and other viofs
  folders link into `fwcfg`, so `bsdtar` could not unpack `viofs/w11/amd64` alone,
  nor all of `viofs`. The ISO's folders are also read-only, which broke the
  cleanup. Fixed: `bsdtar` unpacks `viofs/2k25/amd64` and `viofs/w11/amd64` aside
  and keeps only w11, and cleanup makes folders writable first. The test stand-in
  ISO now has the real layout.
- The setup boot showed QEMU's window (no guest version record). John ran
  `setup.cmd` from the setup drive and approved the one administrator prompt.
- Finding: at step 8, Windows asked "Would you like to install this device
  software? Looking Glass Display adapters, HostFission" despite the IDD
  installer's `/S`, because HostFission's certificate is not a trusted publisher.
  John clicked Install with "Always trust" ticked. No other driver prompted. This
  breaks spec req 7's one prompt and the rule that nothing after the IDD needs a
  click.
- Windows shut down by itself. `lanai setup` recorded step 5 (`last_run`
  clean), booted normally and opened the pinned client. Step 6's automatic
  checks all passed on the first poll: the IDD matches `B7-826-g236efcb155`, the
  SPICE agent's port is open, and the guest agent set the clock and refused
  `guest-exec` (the allow-list is in force).
- John's answers: `~/Windows` shows as the Z: drive; text scale looks right.
  `lanai setup --share-ok yes --scale-ok yes` replied step 7, "Lanai setup is
  finished". Status: running.
- Silent setup from Linux (John, 2026-10-04): checked and not possible on an
  adopted install. dockur 6.05 installs no QEMU guest agent (its first-logon
  script installs the balloon service and the display driver), and a setup boot
  of the restored pre-setup snapshot kept the agent port closed for over 5
  minutes while Windows ran (it then shut down cleanly on `lanai stop`). dockur
  enables neither SSH nor WinRM; RDP is on, but it needs the Windows password,
  an inbound connection Lanai's VM does not allow, and still meets UAC. So the
  one administrator prompt stays; setup.cmd now pre-trusts HostFission's
  certificate, which removes the driver prompt. A no-touch install is a v2 idea:
  Lanai installing Windows itself with its own unattended setup.

### Second run (2026-10-04, after the trust fix)

The test copy restored from the step 3 snapshot (`lanai restore`, 4 min 37 s;
setup state reset, next step "run Lanai setup"), then `lanai setup --window`.
Codex had confirmed the installer and the IDD catalogs share HostFission's signer.
John ran `setup.cmd` and approved the administrator prompt: no driver prompt and
no other prompt. Windows shut down by itself; step 6's automatic checks passed
on the first poll; John answered yes to both questions, and setup reported step
7. Pass: one prompt in total, as spec req 7 requires.

## Phase 7 panel run (2026-10-05)

John installed the `plugin/phase7` build (c48e683) into Omarchy's bar from the branch
(`git clone -b plugin/phase7 ... ~/.config/omarchy/plugins/io.github.jzetterman.lanai`,
then `omarchy plugin enable`), with Lanai's settings on the test copy.
- The copy was already set up (the second hands-on run), so the panel showed step 4:
  the client had no build stamp yet. Continue setup ran the quick check, wrote the
  stamp without rebuilding, and setup reported finished.
- Then, from the panel: Shut down, restore of snapshot `20261004T230202Z` ("The
  snapshot was restored."), and Continue setup from step 1. The setup boot opened in
  QEMU's basic window; John ran setup.cmd and approved the one prompt; Windows shut
  down by itself; the setup job started it again with no click, opened the Looking
  Glass window, and ran step 6's checks ("Checking Windows. You can close this
  panel."). The two questions appeared; John answered yes to both; setup reported
  finished.
- John's feedback: during setup, hide controls the user can trip over (he clicked
  Open window before setup needed it; it opened the Looking Glass window early), and
  color the Setup section when the user must act. Both went into the plan amendment
  ("During setup").

## Extent classes of the test copy (2026-10-05)

Before phase B of the scale, progress and clicks amendment, John ran
`docs/plugin/proof-kit/count-image-extents.py` on the test copy's
`/home/john/lanai-proofs/lanai-setup-test/data.img`, with its Windows shut down.
The script reads the extent map only.

```text
filesystem: btrfs
nocow: True
size: 274877906944 bytes
shared: 56003497984 bytes
class                        extents               bytes
plain                         318266         55666053120
unwritten                       2133           337444864
provable classes only: yes
```

Result: every extent is in a class phase B proves. The image is NOCOW, so it has no
compressed extents. It has about 320k extents, so the map read takes many FIEMAP
batches; phase B times it and shows it under "checking". Its one hash pass covers the
whole 256 GiB, but only about 56 GB comes from disk; the holes read as zeros, so
hashing speed, not the disk, sets most of the time.

## Phase B automated storage proof (2026-10-05)

Agent runs used isolated fixtures in this repository's `.btrfs-test`, never the
rehearsal image or live storage. Normal (`+m`), NOCOW (`+C`), compressed (`+c`)
and mixed images passed the real FIEMAP/reflink mutation matrix, including
`fallocate -z` UNWRITTEN regions. Mutations restore size and mtime and still
refuse completion. Independent manifests in the restore tests match the initial
install; snapshot failures publish no COMPLETE and restore failures retain
recovery markers once replacement has begun. Tests also cover changed original
snapshots while the hashed clone still matches COMPLETE, locked no-replace
publication of a deleted disk, small-file hashes before rename, and recovery.

A read-only census of a local sparse fixture (9,007,104 logical bytes,
4,505,600 allocated bytes, 1,100 plain extents, NOCOW false) took 0.002907 s;
this crosses both the census and proof helper's FIEMAP batch boundaries. This
is a small-fixture measurement, not timing for John's approximately 320k extents;
John still records that rehearsal-image measurement using the census script.

The strace read-budget test includes three concurrent panel polls and separately
reports image and small-file reads; strace is unavailable in this agent sandbox,
so that local measurement skips. CI installs it and requires both the measurement
and real btrfs fixtures. A sandbox PID namespace hides /proc/locks records after
external flock exits while the lock remains held; progress validates the matching
owner's fdinfo FLOCK record in that case. The real container-start check and
rehearsal-image traces remain John's manual row 7 proofs.

Final local verification: 24 added Bats tests (23 pass, one strace skip); the
four focused suites report 171 pass, zero fail, one skip. The required full run
schedules 650 tests: 591 pass, 56 fail because the sandbox refuses Unix-socket
binds, two skip (strace and a missing comma-decimal locale), and the existing
spike real-flock test emits no TAP result (Bats reports 649 executed). A direct
socat fixture bind confirms `Operation not permitted`. QML lint and the required
ShellCheck command pass; these environment-limited results need a full rerun
outside this sandbox before the acceptance gate.


## Live-scale channel proof, phase 0 (1)-(5) (2026-10-11)

John ran `proof-kit/proof-scale-port.ps1` in the test copy's Windows (Lanai's
storage, `~/lanai-proofs/lanai-setup-test`), from the shared folder. Instead of a
`proof-vm` boot, the port was hotplugged into the running VM over QMP
(`chardev-add` socket `scale0` at `$XDG_RUNTIME_DIR/lanai/scale.sock`, server,
no wait; `device_add virtserialport name=io.lanai.scale.0`) and removed after.
The host sent `proof <seq> <epoch ms>` lines with `socat -u`, one connection per
line, under a 1 s `timeout`.

1. Access: a normal PowerShell got `open-failed win32=5 (Access is denied)`; an
   elevated one (same user, john) got `open-ok`. Pass.
2. Order: 173 lines (seq 16-188) arrived in order, no gaps. Pass.
3. No host connected: a read fails at once with "Insufficient system resources
   exist to complete the requested service" (error 1450). It never blocked and
   never returned 0 bytes. The reader retried every 250 ms (7 or 8 failed reads
   per 2 s gap) and did not spin.
4. Guest holding the port open but not reading (90 s hold): the guest kept the
   first 130 lines of a 10,000-line single-connection burst (about 3 KB), then
   the host write stalled until its 20 s `timeout` killed it. Five single-line
   sends after that each reported success on the host and never arrived. When
   the guest read, it got lines 211-340 within about 1 s, 57 s old. Lines 1-15,
   sent before any guest opened the port, were never delivered either.
5. Connection per line every 2 s for 5 minutes: every line arrived; arrival minus
   send (which includes clock skew) ranged from -328 to -70 ms, a 258 ms spread
   that matches the retry gap. Each host send took 2-3 ms.

Plan change from (4): a drained batch with more than one line is a stale backlog
and the task drops it; the next fresh line comes within one feed period.
Proofs (6) and (7) run after phase B's script exists.

## Live-scale hands-on, phase 0 (6)-(7) and phase C (2026-10-11)

John ran these on the test copy (`~/lanai-proofs/lanai-setup-test`) with the
installed plugin on `plugin/live-scale` (d3a827e), after Run setup again. One
monitor: HDMI-A-1, 3840x2160, Hyprland scale 1. Times are EDT.

- Upgrade: Run setup again installed the new task (`scale_task: 2`) and the panel
  note changed to "Saving a scale replaces one you picked in Windows." The shell
  runs with its file watcher off, so the switch needed `omarchy-restart-shell`.
- Custom scaling: John's Windows had it on. The Scale list was greyed out and
  `GET_DPI_SCALE` returned `curScaleRel 1234568` (outside the 0 to max range),
  so the task logged the current scale as unknown and never confirmed a set.
  After "Turn off custom scaling and sign out", `curScaleRel` read true values
  and every check below used them. Phase 1's blank current-scale logs likely had
  the same cause.
- Cap: a 175% save with the window at 1901x1046 (Windows allows up to 150%,
  `maxScaleRel 2`) changed nothing and logged nothing beyond the save, because
  150% was already set. Growing the window to 3816x2106 applied 175% at once.
- Live save: saved 150% at 22:19:26; the feed sent it at 22:19:28.05; Windows
  dropped a 200% pick and applied 150% at 22:19:28.64. Pass.
- Pick: a 200% pick was logged as a pick. Shrinking the window to 1724x1045
  capped it to 150%; growing it back restored 200%. Pass.
- Match my monitor: saved, Windows went to 100% and dropped the pick. Hyprland
  scale 1 to 1.25 at 22:57:43 reached Windows (125%) at 22:57:44.04, and back to
  1 at 22:58:07 reached it (100%) at 22:58:08.22. Pass.
- VM restart: a 150% pick, then Shut down and Start Windows. Windows came up at
  150% (its own last setting); 2 s after the port opened, the task applied the
  saved 100%. Pass. The guest's first frame matched the window (3816x2106).
- Proof 6: with the task suspended in Resource Monitor, saves of 125%, 175% and
  225%, then resume: the task dropped 29 lines as one stale batch and applied
  225% only. Pass. Backlog variant (7 min suspended, 125% at 1 min, 200% at
  6 min): it dropped 128 lines (the buffer filled after about 4 minutes; later
  lines were lost) and applied 200% only, never 125%. The host never stalled.
  Pass.
- Proof 7: with the task running, an elevated `proof-scale-flood.ps1` got
  `open-failed win32=5`: the task holds the port to itself. With the task ended,
  the flood opened the port, wrote 4,093 bytes, and every later write (9,575 in
  10 minutes) failed with "cannot continue without blocking"; nothing on the host
  reads guest writes. Over 22:32-22:45, QEMU's RSS moved under 1 MB, the feed
  stayed at 2-6 MB and the shell fell from 486 to 439 MB. The feed sent three
  saves on time. Pass.
- Restart: a task killed with `Stop-Process` (exit -1) did not restart within
  4 minutes. Task Scheduler's restart on failure covers a failed start only.
  Ending the task in Task Scheduler does not restart it either. Fix in the plan's
  Phase D.
- A normal PowerShell cannot read the elevated task's command line
  (`Get-CimInstance Win32_Process` returns nothing for it).

Phase D check (2026-10-12, plugin at 238e799): Run setup again passed step 6
with the new trigger. `Triggers.Repetition` showed `Interval PT5M`, no
`Duration` and `StopAtDurationEnd False`. A task killed with `Stop-Process` came
back by itself and opened the port at 12:43:17; it applied a 125% save made
while it was down one second later. Pass.

Still to run: row 12's two-monitor cases (needs a second monitor), and row 4's
RDP check in phase 8.

## Resize phase 0: log proof (2026-10-12)

Test copy, today's unpatched client (B7-826), one 3840x2160 monitor. Claude
resized the floating window with `hyprctl` and read `client.log`; John ran (2)
and (3) in an admin PowerShell with `pnputil /restart-device` and
`Disable-PnpDevice`/`Enable-PnpDevice`. Windows' own scale stayed at 125%.

- (1) Pass, 14:52-14:56 EDT. At scale 1: 1600x900, 1201x801 and 2000x1200 each
  gave that exact `Format:` line. At scale 1.25: 2000x1200 gave 2500x1500 and
  1601x901 gave 2001x1126 (round of 2001.25x1126.25). Back at scale 1: 1601x901.
  No session restart. Most resizes also showed one short-lived frame of another
  size (1280x960, 2560x1440, 2560x1600 or 3200x2400) 50-100 ms before the asked
  size, so one resize can give two frame-size changes.
- (2) Pass, 16:21:30 EDT. `Waiting for the host to restart`, then a new session
  whose first frame was 1901x2000, the window's size.
- (3) Pass, 16:22:05-16:22:14 EDT. The same, again at 1901x2000. Both restarts
  came back at the last asked size, so neither reproduced the 1920x1080 start
  seen at boot.
- (4) Stop rule fires, 16:23:20 EDT. 1601x901 to 600x400: frames 3200x2400,
  1601x901, then 1920x1080 3 s later, and no further change in a minute. No
  session restart. Windows did not keep its size.
- Extra sizes, same window: 1200x800, 720x540, 800x600 and 640x480 each gave
  that exact frame, so the floor is the IDD's 640x480, not Windows' 800x600.
  From 640x480, an ask for 1000x470 gave no new frame: Windows stayed at
  640x480. The IDD's default mode list (`LGCommon/DefaultDisplayModes.h`, 38
  modes) ends at 640x480 and does not hold 1601x901 (corrected 2026-10-13: this
  line first said it ends at 1024x768). The IDD's floor is per side (`width < 640 || height < 480`,
  `CSettings.cpp:338`), so 1000x470 is under it too. Not yet known: why the two
  refused asks ended differently.
- The window went back to tiled at 16:26:25 EDT; the frame followed (1901x993).

## Resize hands-on (2026-10-13)

Phase D on the test copy with the patched client (patch id `415fcb25...d014`,
plugin at 2833af9). Monitor HDMI-A-1, 3840x2160 at scale 1 (DP-3 is a dummy
plug). Windows scale 100% except in (5). John ran the actions; Claude read
`client.log` against `hyprctl` and ran (6) to (9). Times are EDT. Client log
times count from the client's start.

- (1) Pass. The setup round left open on 2026-10-12 was closed on
  plugin/live-scale first, then the plugin went to plugin/resize. The panel
  showed the resize warning and Update the Windows window. Open worked. The
  build at 12:08:53 patched all 9 files, and `build-patches` matched
  `patches_id`. Warning and button then hidden. On reopen (12:11:25): first
  frame 1901x2106, window 946x1046, ask 1 at 0.787 s, match at 0.988 s.
- (2) Pass. Driver restart (12:13:36), close and reopen (12:15:23), Windows
  restart (12:16:03) and 10 starts from the bar (12:17:43-12:25:03) each
  matched, at 941x1046 or 946x1046. Only the reopen needed an ask (match
  0.6 s after the first frame). Windows started at the window's size every
  time, so these starts tested nothing hard. Most starts first showed a
  session that lost the host about 1 s in, with no frame.
- (2b) **Fail**, added. 3 starts from the bar after the window's size changed
  while Windows was off (12:27:42, 12:29:00, 12:41:07). Each time ask 1 came
  0.5 s after the first frame, and Windows went to another size and stayed:
  1400x1050, 3840x2160 and 1600x1200. Ask 2, 5 s later, was taken. Matched
  5.75, 5.82 and 5.80 s after the first frame, past the 5 s bar.
- Cause of (2b). The driver takes the ask and replugs its monitor. Windows
  then shows the smallest mode in the default list that fits the old desktop
  (946x1046 to 1400x1050, 3816x2106 to 3840x2160, 1591x1096 to 1600x1200, all
  three exact), and the driver's helper in Windows switches the desktop to the
  asked size. After a boot, that switch does not happen for ask 1. During a
  session it happens within 0.1 s, which is the short-lived frame seen in
  phase 0. Fix: phase E (first wait 2 s).
- (3) Pass, client of 12:28:55. Sign-out and sign-in at 12:32:38: no size
  change, no ask needed. Tile change, fullscreen and back, float and three
  resizes (12:33:05-12:33:24): each one ask, matched within 0.25 s. The move
  to a monitor with another scale was not run: no second real monitor.
- (4) Partly run. First try (12:41:40-12:42:40): John's 4 picks came about
  20 s apart, within 60 s of the boot's asks, so they continued that sequence
  (asks 3 to 5 with waits of 10, 20 and 40 s). Pick 3 (2880x1620) stayed until
  Windows reverted it itself at 12:42:33; ask 5 at 12:42:40 changed the size
  during pick 4's "Keep these display settings?" countdown, and that dialog
  froze. Windows stayed responsive (Start menu, guest agent); minimize and
  restore cleared it. One slow pick (12:47:53, 1600x900): undone in 0.18 s.
  The other 4 slow picks were not run. Quick picks (12:49:23-12:50:17, 7
  picks): asks at once, then after 5, 10 and 20 s; three picks went back
  without an ask (the dialog's revert) before ask 5 was due, so the 5-ask stop
  was not reached (phase 0 (4) showed it). John: after the second pick the
  size seemed not to reset anymore, which is the growing wait.
- Lock to the window's size (John's question, prototype). With `Modes` set to
  the one unparseable entry `none` under `HKLM\SOFTWARE\LookingGlass\IDD`,
  the driver offered only the window's size. A start at 12:56:43 then showed
  a 946x1246 output but a 941x846 desktop, centered with black bars, and the
  helper logged `Failed to apply Looking Glass display mode 946x1246@60 (-1)`.
  Rejected: it needs a driver change, and the IDD stays pinned. Undone with a
  driver restart at 13:04:17: the first frame was 1152x864 (the smallest
  default mode that fits the 941x846 desktop), the ask went out at once, and
  946x1246 came 1.26 s later, the slowest switch after a taken ask today.
- (5) Pass. 300% from 13:05:21. Fullscreen 3840x2160 matched in 0.29 s.
  Driver restarts at 13:06:04 and 13:06:33 came back at 3840x2160 with text
  still at 300% (John).
- (6) Pass. Claude set the floating window to 600x400 at 13:08:43: the log
  said `Resize: window is 600x400, under 640x480, not asking`, and for 63 s
  there was no ask and no frame change. Windows kept 1790x1748, scaled down
  with side bars. 1200x800 at 13:09:46 matched in 0.21 s.
- (7) Pass. Driver disabled at 13:11:12. A resize to 1400x900 at 13:11:22
  gave no ask. Enabled: session at 13:11:57, ask at once, matched 0.64 s
  after the first frame.
- (8) Pass, 13:13. A word added to 0002's subject line brought back the
  warning and button. With `scale_task` also removed from the setup record,
  the warning named only Run setup again. Both restored byte for byte.
- (9) Pass. 0001 adds `resize.c`, `resize.h` and `resize_test.c`. 0002
  touches `client/CMakeLists.txt`, `core.c`, `core.h`, `main.c`,
  `tests/CMakeLists.txt` and `config_message_test.c`. No new
  `LG_TransportControl` type (0002 uses the existing
  `LG_TransportControlToken`). No KVMFR or LGMP struct change. `lib/pins.sh`
  has no diff from main. `COPYING` SHA-256 `8177f975...0643` matches the
  plan. The README license paragraph and `manifest.json` read as planned.

## Resize hands-on, phase E (2026-10-13)

John ran the steps on the test copy, Claude read the client log, all times
EDT. Windows signs in on its own. Phase E's client (asks at 0, 2, 7, 17 and
37 s) was built at 16:45:05 with the patch id `a9602f51...` and the warning
cleared.

- Start 1 from the bar, larger window, 16:52:18. Fail, and a gap in phase E.
  First frame 965x1265, ask 1 for 1908x1305 0.5 s later, and a 1908x1305
  output 0.15 s after that. Lanai saw a match and asked no more. John's
  screenshot showed the desktop still near 946 wide, centered with black
  bars, and Settings showed 946x1246 picked with 1908x1305 "Recommended".
  Cause: the client sees only the output size. The smallest mode that fit
  the old desktop was the asked size itself, so the output matched while
  Windows' helper had not switched the desktop. A resize by hand fixed it.
- Restart from the Start menu at 17:00:35 with the desktop already matched:
  first frame 1908x1305, no ask, desktop full (screenshot).
- Starts from the bar at 17:02:23 (946x1246), 18:13:06 (946x613),
  18:14:25 (3816x2106) and a restart at 18:15:18 (1593x990). Each matched
  7.4 to 7.8 s after the first frame. Ask 1 (0.5 s) gave the smallest
  built-in mode that fits the old desktop (1920x1440, 1920x1440, 1024x768,
  3840x2160). Ask 2 (2.5 s) changed nothing. Ask 3 (7.5 s) took in 0.2 to
  0.3 s. The helper connected (`Using Clipboard: LGMP`) about 2.4 s after
  the first frame, and Windows' audio started (the desktop is up) about
  6.6 to 6.8 s after it. So Windows' helper cannot switch the desktop
  before the signed-in desktop is up, and no ask timing meets 5 s from the
  first frame on a boot: that frame is the sign-in screen.
- The IDD source (pinned build) shows a repeat ask for the same size has no
  shortcut: `SetResolution` stores the mode, replugs, and the next ready
  swap chain sends `SETDISPLAYMODE` again (`CDeviceContext.cpp:456-487`,
  `CMonitorManager.cpp:313-346`). The helper retries each mode 20 times,
  100 ms apart, then logs `Failed to apply` and drops it
  (`CPipeClient.cpp`, `DisplayModeThread`).
- Sign-in backstop prototype (`display-backstop.ps1`, a logon task for
  John's user, run level highest). It reads `ExtraMode` from
  `HKLM\SOFTWARE\LookingGlass\IDD` and, while the Looking Glass display's
  desktop differs, calls `ChangeDisplaySettingsEx` with
  `CDS_UPDATEREGISTRY`, every 0.5 s for up to 120 s. On the 4 starts above
  from 18:13 it started 14 to 20 s after boot, about 5 s after the desktop
  came up, found the desktop already matched by ask 3, and did nothing.
- Stuck case, made on purpose, 18:18:57. Desktop 1594x990, then Claude set
  the window to exactly 1600x1000 while Windows restarted (the smallest
  built-in mode that fits 1594x990 is 1600x1024). First frame 1594x990, ask
  1, a 1600x1000 output 0.12 s later, and no more asks: the trap of start 1.
  The desktop came up at about 18:19:01. The backstop started at
  18:19:05.18, found desktop 1594x990 against `ExtraMode` 1600x1000@60*,
  switched (result 0), and saw 1600x1000 at 18:19:05.75. John's call: build
  the backstop into Lanai.
- The lock prototype's failure at 12:56 above matches this boot failure (a
  start, an output at the window's size, the desktop at the old size,
  `Failed to apply`). So it does not prove that a lock needs a driver
  change. A lock may work with the backstop; retest it after the build.
- Resize while signed out (John's question). Signed out at 18:21:26 (the
  clipboard fell back to SPICE: the helper stopped). John resized the
  window to 1312x1207 at the sign-in screen at 18:21:34: ask 1 gave a
  1600x1024 output, asks 2 to 5 changed nothing, and `Windows did not take
  1312x1207` came at 18:22:16. Nothing changed at the sign-in screen
  (John). Signed in: the backstop started at 18:22:33.01 and found the
  desktop already at 1312x1207, the helper connected at 18:22:33.48, and
  the client's first 1312x1207 frame came at 18:22:33.96, with no new ask.
  So after a sign-out the helper applies Lanai's last ask as it starts;
  the failure is after a boot only. John: "adjusted immediately after I
  signed in. Very fast."

## Resize hands-on, phase G (2026-10-14)

John ran the steps on the test copy (`~/lanai-proofs/lanai-setup-test`),
Claude read the client log through `stamp-client-log`, all times EDT. The
guest-host offset comes from `clock-ping` and `pong.ps1` at each boot (guest
minus host, with its bound). Phase F's build (`89c9805`) was installed.

- Step 0: John removed the phase E prototype task (`display-backstop.ps1
  -Remove`).
- Step 1 passed. The panel showed the Run setup again message with the lock
  note. After Run setup again, the record has `"signin_step":1` beside
  `"scale_task":2`, the warning is gone, and setup reached step 7.
- Start after a shape change (1901x946 to 946x1146, which Hyprland's tiling
  gave the reopened window): offset -0.239 s, bound 0.012 s. Sign-in (first
  `Using Clipboard: LGMP`) at 17:16:48.50; asks at 17:16:47.69, 49.68 and
  54.69; frame 946x1146 at 17:16:54.89 (6.4 s). The step's first check came
  at 17:17:02.47 host time, 14.0 s after the sign-in, and found the desktop
  matched (0 switches). Display settings: 946x1146. Passed.
- Plain start 1, with the task's priority set to 4 (normal) by hand as a test:
  offset -1.520 s, bound 0.008 s. The frame was 946x1146 at 17:23:16.06,
  before the sign-in at 17:23:24.35. The step's first check came 14.1 s after
  the sign-in and found the desktop matched. Display settings: 946x1146.
  Passed.
- Plain start 2, priority back to 7: offset -0.817 s, bound 0.008 s. Frame
  946x1146 at 17:32:47.33, before the sign-in at 17:32:49.50. The step's first
  check came 11.3 s after the sign-in, matched. Display settings: 946x1146.
  Passed.

**The scale task starts slowly at sign-in.** The Windows PowerShell event log
(`probe-startup.ps1`, engine state `Available`) shows where the time goes, in
guest time:

| Boot | powershell.exe starts | Engine ready | C# compiled | Step's first check |
|---|---|---|---|---|
| 17:16 | 47.67 | 00.51 (+12.8 s) | 01.48 | 02.23 (+14.6 s) |
| 17:23 (priority 4) | 22.43 | 35.19 (+12.8 s) | 36.14 | 36.88 (+14.4 s) |
| 17:32 | 48.11 | 58.35 (+10.2 s) | 59.10 | 59.94 (+11.8 s) |

Run warm, a new `powershell.exe` takes 146 ms, 323 ms with the compile, and
231 ms with the WMI query: the task's code is fast, and the wait is
PowerShell loading while Windows signs in. Normal task priority did not help.

On the 17:32 boot, two probe sign-in tasks set up like the scale task
(`probe-exe.ps1`) wrote their start times. From the sign-in at 17:32:48.68
guest time: `cmd.exe` wrote its line at +4.5 s, and a small C# program built
with Windows' own `csc.exe` reached its code at +6.7 s. PowerShell's engine
was ready at +9.7 s and the step's first check came at +11.3 s.

So a stuck desktop would be fixed 11 to 15 s after the sign-in, at or past
the 15 s bar. John also saw a blank Windows PowerShell window at every
sign-in that closed on its own: `-WindowStyle Hidden` takes effect only once
PowerShell has loaded. John chose a small windowless program that setup
builds in Windows, which starts the scale script with no window and runs the
sign-in step itself (spec amendment 4, plan phase H). The starts above count
for phase G's record but get run again on phase H's build.

### Resumed on phase H's build (2026-10-17)

Build `de0273b` installed; storage `~/lanai-proofs/lanai-setup-test`. The
probe tasks first survived a `-Remove` run (most likely not elevated; the
scratch script hid the error) and opened two console windows at the 17:00
sign-in. John removed them in an elevated PowerShell, and only `Lanai display
scale` is left.

- Step 1 passed. With the record at `"signin_step":1`, the panel warning read
  "... To fix this, shut Windows down and click Run setup again. Running
  setup again also turns the Windows lock off again." After Run setup again,
  setup reached step 7, the record has `"signin_step":2`, and the warning is
  gone. The client rebuilt as `B7-826-236efcb1`.
- Row 9 passed. Run setup again once more, with the program running: the old
  file is `lanai-start.old-639278678123546225.exe` (16:56:28), the new
  `lanai-start.exe` was written at 17:03:32, and after the restart the
  running process is `"C:\Program Files\Lanai\lanai-start.exe"`, with one
  `powershell.exe` running `lanai-scale.ps1` and its `conhost.exe` under it.
  No window appeared at that sign-in. The two `lanai-scale.ps1` engine
  events per boot in the PowerShell log are the script's own reader runspace,
  not a second process.
- Start delays (`Start program: started`): 6.59 s, 5.93 s and 7.68 s. Each
  step matched the desktop with 0 switches within 0.4 s of the program's
  start line.
- Step 2 passed: 13 of 13 within the 15 s bar. Host times; the offset is
  guest minus host from `clock-ping` (best sample's bound in brackets). "Up"
  is when the program reached its code, after its process started; "matched"
  is the step's `matches after 0 switches` line. Every step found the desktop
  already matching (0 switches), and Display settings showed the size each
  time. In every start Windows started the program 0.1 to 0.9 s before the
  sign-in, so the program's own start (5.2 to 8.0 s) sets the time.

  | # | Case | Offset | Sign-in | Desktop at the size | Up | Matched |
  |---|---|---|---|---|---|---|
  | 1 | 946x1046, unchanged | -0.647 (0.008) | 17:07:42.74 | +5.7 s (ask 3) | 6.82 s | +7.02 s |
  | 2 | same | -0.933 (0.008) | 17:09:39.08 | first frame | 6.84 s | +6.69 s |
  | 3 | same | -0.944 (0.012) | 17:12:11.20 | first frame | 7.3 s | +7.37 s |
  | 4 | same | -0.897 (0.012) | 17:16:30.10 | first frame | 6.79 s | +6.75 s |
  | 5 | same | -1.109 (0.012) | 17:19:05.70 | first frame | 8.01 s | +7.85 s |
  | 6 | same | -0.217 (0.009) | 17:21:34.08 | first frame | 6.76 s | +7.03 s |
  | 7 | same | -0.524 (0.012) | 17:22:55.73 | first frame | 7 s | +7.14 s |
  | 8 | same | -0.250 (0.008) | 17:23:57.43 | first frame | 5.2 s | +5.46 s |
  | 9 | same | -0.501 (0.009) | 17:24:46.96 | first frame | 5.63 s | +5.12 s |
  | 10 | same | -0.346 (0.012) | 17:25:41.00 | first frame | 6.35 s | +6.44 s |
  | 11 | larger, 800x600 to 1600x1000 | -0.809 (0.011) | 17:31:30.32 | +2.91 s (ask 2) | 6.2 s | +6.24 s |
  | 12 | shape, 1600x1000 to 1400x700 | -1.115 (0.008) | 17:33:15.11 | +5.58 s (ask 3) | 7.61 s | +7.68 s |
  | 13 | smaller, 1400x700 to 800x600 | -0.511 (0.008) | 17:34:25.56 | +3.25 s (ask 2) | 7.66 s | +7.90 s |

  The three size changes used `size-window-on-open`, which floated and sized
  the new window before Windows' first frame. A first try at 800x600 does
  not count: the window opened a few seconds after Windows signed in, so
  the change met a running session (Windows matched 3.0 s after the
  window's sign-in line). During two sign-ins Windows briefly showed its
  own mode (1600x1024, 1440x900) before taking the ask. The first clock
  exchange of start 2 failed: `pong.ps1` answered the line the last run left
  in `ping.txt`. It now ignores the line it finds at its start.
- Step 3's pair: A 1434x894 and B 1440x900. The phase E pair (1594x990,
  1600x1000) leaves both sizes at a 150% cap, so it cannot show the scale
  move. 1440x900 is the smallest built-in mode that holds A. Checked live
  at 17:38 with a 150% target: at B the scale task read `maxScaleRel 2`
  (150%), at A `maxScaleRel 1`, and Settings offered 125% and 100% only.
- Step 3, start from the bar, passed. `size-window-on-open 1440 900` set
  the new window at 17:40:23.39. Offset -0.587 (0.008). First frame A at
  17:40:51.38, one ask at 51.92, a B frame at 52.05 and no more asks (the
  trap). Sign-in 52.40. The step found desktop 1434x894 against stored
  1440x900 and switched at 17:41:01.15, then matched after 1 switch at
  01.71 (+9.31 s). The scale port opened at 04.54 (the task's ready time)
  and it applied 150% over 125% at 05.12: 4.0 s after the switch, 7.3 s
  before the bar (20 s after the sign-in, the later of the two). Settings:
  1440x900, 150%.
- Step 3, restart, passed on the second try. A watcher resized the window
  to B when the client logged `Waiting for the host to restart...`
  (17:45:20.23). Offset -1.261 (0.011). First frame A at 17:45:25.90, one
  ask at 25.93, a B frame at 26.06 and no more asks. Sign-in 27.91. Switch
  at 35.52, matched after 1 switch at 36.08 (+8.16 s). The scale task
  applied 150% at 41.25. Settings: 1440x900, 150%. The first try's watcher
  never resized (its `grep` matched, but the pipeline waited on `tail`), so
  that restart had the window unchanged and counts for step 6: offset
  -1.026 (0.009), first frame 1434x894 at 17:43:18.67, sign-in 20.66,
  matched after 0 switches at 27.18 (+6.52 s). Settings: 1434x894, 125%.
- Step 4 passed, after one setup problem. With `AutoAdminLogon` set to 0,
  Windows still signed in at boot: the Security log shows a type 2 logon
  (`User32`) at 17:51:31.8 guest time, before the first frame, and John's
  password at what he took for the sign-in screen was an unlock (type 7,
  17:52:06.8). That is Windows' automatic restart sign-on ("Use my sign-in
  info to automatically finish setting up after an update"), which signs in
  and locks. The step had matched the stuck case (1 switch) 24 s before the
  unlock. With that setting off too, the password prompt had no session
  behind it (no `Using Clipboard: LGMP` line until the sign-in):
  - Made stuck size (desktop A, window set to B at 17:59:51.43). Offset
    -0.676 (0.009). One ask and a B frame at 17:59:59.42, so the asks
    ended at once. John signed in at 18:00:20.27. The step found the
    desktop already at 1440x900 (0 switches) at 24.61 (+4.34 s): at a real
    sign-in the helper applies the stored size itself, as after a sign-out
    in phase E. The trap needs a sign-in during boot. Scale 150% at 31.20.
  - Another size (window set to 1200x800 at 18:02:03.75, desktop
    1440x900). Offset -0.952 (0.012). Asks at 18:02:10.72, 12.73, 17.73,
    27.73 and 47.74, then `Windows did not take 1200x800` at 52.74; the
    sign-in screen showed black bars meanwhile. John signed in at
    18:03:06.59, a 1200x800 frame came at 07.98, and the step matched with
    0 switches at 08.84 (+2.25 s). Settings: 1200x800 at 125%, the 150%
    target capped (125% at 15.47). The program reached its code 1.15 s
    after its process started, against 5 to 9 s at boot sign-ins.
- Automatic sign-in back on: `AutoAdminLogon` 1 and the restart sign-on
  setting on still gave a password prompt (no stored password left), so
  John stored it again with `netplwiz`.
- Step 6 passed. The restart with the window unchanged is under step 3
  above (+6.52 s). Restart with the window resized from 1200x800 to
  1600x900 when the session ended (18:06:14.47), signed in by hand at the
  prompt above: offset -2.616 (0.012). First frame 1200x800 at
  18:06:21.23, asks 1 to 5 by 18:06:58.31, sign-in 18:07:02.81, `did not
  take` at 03.33, a 1600x900 frame at 03.99, matched after 0 switches at
  07.01 (+4.21 s). Settings: 1600x900, 150%.
- Step 5 passed (same boot, offset -2.618, bound 0.012). Sign-out at
  18:09:33.49; the window went from 1600x900 to 1300x850 at 33.49. Five
  asks (18:09:34.00 to 18:10:11.04) and one `Windows did not take
  1300x850` (18:10:16.05) before the sign-in at 18:10:36.15. The log says
  `Sign-in step: started`; the step found 1600x900 against the stored
  1300x850, its first switch returned -1, the second took, and it matched
  after 2 switches at 36.68 (+0.53 s). Settings: 1300x850, 125% (cap).
  Plain sign-out and sign-in: no ask and no new frame size; the step
  matched after 0 switches at 18:14:24.23, 0.5 s before the sign-in line
  (18:14:24.73). The program reached its code 0.22 to 0.3 s after its
  process started on these warm sign-ins. Two clock exchanges failed first:
  a stale `ping 1` in `ping.txt` matched the next run's first ping, which
  pong now skips. `clock-ping` now tags each run's pings with a run id and
  reports its best sample when pong stops early.
- Step 9 passed (the pick case, in the session of step 5's plain sign-in,
  which logged `matches`). Window 1300x850, picks of 1024x768 in Display
  settings. Five slow picks (18:16:30.62, 18:18:11.67, 18:20:04.36,
  18:21:13.81 and 18:22:20.66), each more than a minute after the last
  ask, were each undone in 0.14 to 0.18 s. An extra pick at 18:16:58.86,
  28 s after an ask, went out as ask 2 of 5 and was undone in 0.14 s.
  Then 6 quick picks, each made after the previous undo and kept with
  "Keep changes" where the undo left time:

  | Pick | Picked | Ask | Ask after the previous ask |
  |---|---|---|---|
  | 1 | 18:23:33.17 | 1 of 5 at 33.18 | (first) |
  | 2 | 36.54 | 2 of 5 at 36.54, at once | 3.36 s (wait 2 s over) |
  | 3 | 40.04 | 3 of 5 at 41.54 | 5.00 s |
  | 4 | 45.37 | 4 of 5 at 51.54 | 10.00 s |
  | 5 | 54.46 | 5 of 5 at 18:24:11.56 | 20.01 s |
  | 6 | 18:24:14.77 | none | |

  Ask 5 came 38.38 s after ask 1. The sixth pick stayed: 1024x768 still at
  18:25:28 (73.8 s), and John saw it hold. The client logged `Windows did
  not take 1300x850` at 18:24:16.56, 5 s after ask 5, because the frame was
  the sixth pick. The words fit a size Windows refused better than a kept
  pick; a wording note for the client patch (follow-on).
- Spec row 7b's fixture passed. An Image File Execution Options `Debugger`
  value for `lanai-start.exe` naming a missing file, then Run setup again:
  setup.cmd ran steps 1 to 5 and stopped at `[6/8] Adding the display scale
  task` with "Lanai setup stopped: Windows blocked the program setup built
  for the display scale task, C:\Program Files\Lanai\lanai-start.exe", the
  antivirus, App Control or AppLocker (by path; a hash rule breaks on each
  rebuild) and Smart App Control fixes, and "Then run setup.cmd again." The
  panel kept its setup.cmd step. With the value deleted, setup.cmd ran
  again, setup finished at step 7, and the record kept `signin_step` 2. The
  boot reached the desktop by itself (automatic sign-in back). An admin
  process list after it: `lanai-start.exe` (written 18:30:16), one
  `powershell.exe` running `lanai-scale.ps1` and its `conhost.exe`; the
  blocked run's build is `lanai-start.old-639278730159940719.exe`
  (18:28:15). A PowerShell that is not elevated shows the task's command
  lines blank, so the list needs an admin window. The same list at about
  18:53, 22 minutes after that sign-in (18:30:53 guest time), showed the
  same three processes with the same ids (6052, 10952, 10960): one program
  and one scale script.
- Step 7 passed. John disabled Looking Glass Indirect Display in Device
  Manager, shut down from the panel and started from the bar at about
  18:55; automatic sign-in signed in with no picture (the client logged
  `Waiting for the source to start...`). The log: `Start program: started
  7.13 s after the process started at 18:55:07.06`, `Sign-in step:
  started`, `no Looking Glass display` (18:55:14.46), then `gave up after 2
  minutes; changed nothing` (18:57:14.66). John shut down from the panel,
  and Claude booted the test copy with `proof-vm run` (QEMU's display off;
  RDP on 127.0.0.1:13389); John signed in over RDP with `spike/lgtest rdp`
  and enabled the driver again. That boot logged `Start program: not
  Lanai's VM; changed nothing` (18:58:46): the proof VM has no Lanai
  SMBIOS string. `proof-vm stop` shut it down at 23:01:03Z.
- Step 8, guard review of `guest/lanai-start.cs` (`SigninStep.Decide` and
  `Tick`, `LanaiRegistry`, `LanaiDesktop`):
  - No other display: `Find` returns only a display attached to the desktop
    whose adapter string names Looking Glass, and `Apply` and `Size` act on
    that device name only. With none, each try waits and logs `no Looking
    Glass display` once, until the 2-minute stop.
  - No stored size: a missing key or value, or a malformed one (not a
    string, a side of 0, or not 1 to 5 ASCII digits a side), is null, and
    the step stops with `no stored size; changed nothing`. Only the parsed
    size is logged.
  - The stored size, the display and its desktop are read again at each
    try (`Tick`, every 500 ms).
  - Early stops: a `DISP_CHANGE_BADMODE` (-2) for the stored size stops with
    `Windows does not support <size>`; 3 successful switches, each at least
    2 s old, whose size the desktop does not show stop with `3 switches did
    not take`. Other failures (such as step 5's -1) are retried each try,
    logged once per line.
  - The 2-minute limit is checked first on every try: `gave up after 2
    minutes`, with what Windows reported done.
  - The gate (the plan's "logon-age gate", built as a mark): the first task
    start since a sign-in, by a value in `HKCU\Volatile Environment`, which
    Windows rebuilds at each sign-in. A set mark, a mark that cannot be
    read, or a missing key skips; the step never creates the key, since a
    key Lanai made would outlive the sign-in. Step 5's sign-ins logged
    `started`.
  - Every call is caught per try; an exception is a failed try, logged once
    per message, and never ends the program.
  Sound against the table; no finding.
- The scale log at the 17:38 change to A said "Windows reports the current
  scale out of range (curScaleRel 2). Custom scaling is probably on". That
  is wrong: the old 150% was above the new range until the task set 125%
  in the same pass. It came again at 18:03:12, with 150% left over from
  1440x900 at a 1200x800 start. A wording fix for `lanai-scale.ps1`
  (follow-on).

## Setup checks, phase 0 (2026-10-17)

John ran the commands; Claude read the results. All times EDT.

- Share identity, on the test copy (`~/lanai-proofs/lanai-setup-test`, set up):
  `Z:\`, DriveType `Fixed`, DriveFormat `VirtIO-FS`, VolumeLabel `lanai`. The
  label is the virtio-fs tag Lanai gives the device (`tag=lanai`,
  `lib/vm.sh:151`). A normal (not elevated) PowerShell and an admin one saw the
  same line, and the normal one listed the share (`lanai-proof`). The drive
  rule for phase A: DriveFormat `VirtIO-FS` and VolumeLabel `lanai`.
- Restart time: `net stop VirtioFsSvc`, then `net start VirtioFsSvc`; the drive
  was back 0.18 s later. With the service stopped, the drive list showed only
  `C:\`.
- First install, on a fresh reflink copy of the pre-setup snapshot
  `20261004T230202Z` (never ran setup.cmd: no `C:\Program Files\Lanai`, and no
  `VirtioFsSvc` service at all), booted with `proof-vm run --share <scratch>
  --setup <copy of the setup media>`. Over RDP, in an admin PowerShell, in the
  new order: the WinFsp install (exit 0), `pnputil /add-driver ... /install`
  (exit 0, not 3010), the copy of `virtiofs.exe`, the service created, then
  started. `Z:\` (`VirtIO-FS`, `lanai`) appeared 0.69 s after the start and
  listed the scratch share's `trial.txt`. No restart was needed, so the check
  can run inside the setup boot. The copy was deleted after.
- The snapshot's `data.img` is NOCOW, and btrfs refuses a clone between a
  NOCOW file and a normal one: the trial folder was set `chattr +C` before the
  copy, and its small files were copied without a clone.

## Setup checks, phase C (2026-10-18)

John ran the steps on the test copy (`~/lanai-proofs/lanai-setup-test`) with the
branch's build (`plugin/setup-checks` c3114dc, installed from the local
checkout); Claude read the setup record, the panel and `$RUN`. All times EDT.

- Step 1, a clean Run setup again: setup.cmd printed "Checking that the shared
  folder from Linux appears in Windows (up to 30 seconds)..." and went on at
  once (John: "It immediately detected the linux drive"). Setup finished at
  step 7 at 20:05:52 with no question, the record at `signin_step` 2.
- Step 2, the shared folder: Run setup again; in the setup boot, an Image File
  Execution Options `Debugger` value for `virtiofs.exe` naming a missing file,
  then setup.cmd. It stopped at [5/8] after 30 s with "The shared folder from
  Linux did not appear as a drive in 30 seconds." and "Lanai setup stopped:
  the shared folder from Linux did not appear in Windows as a drive.", the
  restart and panel steps, and "Then run setup.cmd again." With the value
  deleted, setup.cmd ran again in the same boot, and setup finished at 20:11:48.
- Step 3, automatic sign-in off (`AutoAdminLogon` 0 and the restart sign-on
  setting off): Run setup again, John signed in to run setup.cmd, then stayed
  at the sign-in screen at the check boot. The boot started at 20:14:48
  (`step6-since`); the other checks passed at the sign-in screen at 20:14:58
  (`step6-checked`); the scale task stopped at 20:17:01 (123 s, the 120 s limit
  plus one poll) with the scale-task words, Continue setup shown, and the
  display buttons hidden while Windows ran. After Shut down from the panel,
  both display buttons showed beside Continue setup (John). Continue setup
  started Windows (`step6-since` 20:18:27), the other checks passed at
  20:18:37, John signed in, and setup finished at 20:19:09. John then stored
  the password again with `netplwiz` and turned the restart sign-on setting
  back on.
- Step 4, the guest agent: Run setup again; in the setup boot, the IFEO value
  for `qemu-ga.exe`, then setup.cmd, which finished (the agent already running
  in that boot was not restarted). The check boot started at 20:22:43; step 6
  stopped at 20:27:50 (307 s) as `guest-boot`, "Windows did not finish
  starting, or its guest agent did not start." with the time-out ending. With
  the value deleted and Windows restarted, Continue setup reset the limits
  (20:29:18) and setup finished at once, at step 7.
- By test only, as the plan says: the IDD mismatch, a guest agent without its
  allow-list, the `idd-missing`, SPICE agent and `qmp` time-outs, a drive that
  appears but cannot be listed, and Run setup again after a scale-task stop.

## Resize drag (2026-10-23)

Phase 7's resize check, on John's install, not on the phase 6 test copy. The
pinned client (B7-826-236efcb1) moved the host pointer to the Windows cursor
after every resize, and Hyprland sized the window from that pointer, so a drag
outran or lagged the mouse (docs/plugin/client-warp/plan.md). The trace is
`client.log` with `mouseTrace=yes`, and a pointer sampler ran beside it. John
dragged the window. Times are EDT.

- Warping on, client session started at 20:43: 790 resize events
  (`app.resize`) and 763 pointer moves (`core.warp send`), counted with `grep`
  while the session ran. The client's restart overwrote that log, so these
  counts cannot be checked again.
- `wayland:warpSupport=no` set by hand in `client.ini`, client session started
  at 21:04: 482 resize events, no `core.warp send` line and 463
  `core.warp drop=support` lines (warps the setting refused) at the first read.
  John: the drag felt right at once.
- The sampler polled `hyprctl cursorpos` and `hyprctl -j activewindow` about
  28 times a second. Its gap is the distance from the pointer to the window's
  right edge (window x + width - pointer x), which stays fixed when a window
  follows a bottom-right drag. A drag is a run of size changes at one window
  position with no pause over 0.3 s. The gap's range in each floating drag:
  warping on, Looking Glass, four drags: 8, 150, 175 and 195 pixels; Ghostty,
  one drag: 3 pixels; warping off, Looking Glass, two drags: 25 and 87 pixels.
  The sampler reads the pointer and the window some 15 ms apart, so a fast
  drag adds error of its own. It supports the trace; the trace and John's
  check decide.
- Pass. Lanai now passes `wayland:warpSupport=no` (`lib/client.sh`,
  `client_args`). The later options in phase 7's list,
  `input:captureOnly=yes` and `win:setGuestRes=no`, were not needed.
- Still to run: John's hand check on the shipped build (the client-warp doc's
  Acceptance section).

## After the proofs

Keep `$S/lanai-proof` until every result is recorded. It shares its blocks with
`~/.windows`, so it costs little space at first and grows as the copy's Windows changes.
Delete it with `rm -rf "$S/lanai-proof"`. Phase 8's rehearsal makes a fresh copy.
