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
  - UX: resizing the Looking Glass window with Shift + right-drag accelerates instead of tracking the mouse. Likely the client's pointer warping or confinement confusing Hyprland's drag. Investigate client pointer options before phase 7.
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
    menu).
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


## After the proofs

Keep `$S/lanai-proof` until every result is recorded. It shares its blocks with
`~/.windows`, so it costs little space at first and grows as the copy's Windows changes.
Delete it with `rm -rf "$S/lanai-proof"`. Phase 8's rehearsal makes a fresh copy.
