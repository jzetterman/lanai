# Phase 1 proofs: runbook and results

Plan: [plan.md](plan.md), "Phase 1". Spec: [spec.md](spec.md).

These four proofs settle the riskiest unknowns before the VM work builds on them. You run
all of them by hand. Each proof runs on a full reflink copy of `~/.windows`, never on
`~/.windows` itself. If a proof fails, stop and record why. Phase 4 (VM lifecycle) waits.

Record every time with its timezone, for example `2026-09-28 14:00 EDT`. Paste command
output into the Result sections as it printed.

## The kit

| File | What it does |
|---|---|
| `bin/lanai-copy` | Makes the verified reflink copy. Holds QEMU's lock on the source disk while it copies. |
| `docs/plugin/proof-kit/proof-vm` | Builds and runs the proof VM from the spike's `vm_args` and the captured `omarchy-windows-vm` command line (`spike/test/fixtures/dockur-cmdline.txt`), plus each proof's devices. Refuses `~/.windows`, and refuses a copy that holds a symlink, a hard link, or a file that is the live one. `proof-vm help` lists its commands. `proof-vm args <copy> [options]` prints the QEMU line without starting anything. |
| `docs/plugin/proof-kit/lanai-proof.service`, `proof-unit-start`, `proof-unit-stop` | Proof 4's throwaway unit and its start and stop scripts. |
| `guest/lanai-scale.ps1` | Proof 1's scale script (first draft). |
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
| WinFsp MSI | 2.1.25156 (release v2.1, "WinFsp 2025") | `https://github.com/winfsp/winfsp/releases/download/v2.1/winfsp-2.1.25156.msi` | `073a70e00f77423e34bed98b86e600def93393ba5822204fac57a29324db9f7a` (matches GitHub's published digest) |
| QEMU guest agent MSI | qemu-ga-win 110.2.3-2.el10 (the target of virtio-win's `latest-qemu-ga` link) | `https://fedorapeople.org/groups/virt/virtio-win/direct-downloads/archive-qemu-ga/qemu-ga-win-110.2.3-2.el10/qemu-ga-x86_64.msi` | `19dcf8abc30f70c2eb6e87282601fd0476e4e0b19936f63d9c80be30db0796ed` |
| virtio-win ISO | 0.1.302-1 (the target of virtio-win's `stable-virtio` link) | `https://fedorapeople.org/groups/virt/virtio-win/direct-downloads/archive-virtio/virtio-win-0.1.302-1/virtio-win-0.1.302.iso` | `303f7ae40dad495d6ae474fdc571df58958a4dbc5c37a522d80f9a203867949d` |

The ISO holds the viofs driver and `virtiofs.exe` in `viofs\w11\amd64\`. Its
`guest-agent\qemu-ga-x86_64.msi` is byte for byte the qemu-ga MSI above. The
Looking Glass IDD (`B7-826-236efcb1`) and the SPICE agent (0.10.0) come from the spike's
pins, already fetched into `spike/work/setup/`.

## Before you start

1. Use the main checkout on branch `plugin/v1`. The kit reuses the spike's built client
   and downloads from `spike/work/`, which only that checkout has. Save the paths the
   runbook uses in a small file, so every terminal can load them:

   ```sh
   cd ~/Development/github/jzetterman/windows-on-omarchy
   git switch plugin/v1
   mkdir -p ~/lanai-proofs    # scratch; must be on the same btrfs filesystem as ~/.windows
   printf 'R=%q\nK=%q\nS=%q\n' "$PWD" "$PWD/docs/plugin/proof-kit" ~/lanai-proofs \
     >~/lanai-proofs/env
   source ~/lanai-proofs/env
   ```

   **In every new terminal, and after every log-in, run `source ~/lanai-proofs/env`
   first.** `$R` is the checkout, `$K` the kit and `$S` the scratch folder.

2. Check the spike's parts are there: `$R/spike/work/build/looking-glass-client` (from
   `spike/lgtest build`) and `$R/spike/work/setup/looking-glass-idd-setup.exe` (from
   `spike/lgtest fetch`). Check that `/usr/lib/virtiofsd --version` prints a version.
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

- Date and time:
- `lanai-copy` last line, and how long it took:
- `media` last line:

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

- Date and time:
- Anything unexpected:

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

- Date and time:
- OEM strings:
- Script output (step 2):
- Applied at once, no sign-out (yes/no):
- After resize (resolution, scale):
- After restart, before the script (scale):
- Script output after restart:
- 250% at small window (resolution, output, scale shown):
- 300% at small window (resolution, output, scale shown):
- `PerMonitorSettings` output:
- `lanai-scale.log`, if the script failed:
- Pass (yes/no), and why:

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

- Date and time:
- virtiofsd owner (`ps`):
- viofs driver present before step 2 (output):
- Service start output:
- Drive letter:
- Round trip (both files, host owner and mode):
- Step 7 outputs:
- Pass (yes/no), and why:

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

- Date and time:
- `BINARY_PATH_NAME` before and after:
- `guest-exec` replies:
- `set-time` replies:
- Clock difference before suspend:
- Right after wake:
- 60 s after wake:
- `sleep-watch.log`:
- Pass (yes/no), and why:

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

- Date and time:
- Lingering at the start:
- `InhibitDelayMaxUSec`:
- `TimeoutStopUSec` of `user@<uid>.service`:
- Logout path used:
- A1 logout (lingering off): unit log, ordering lines, logind lines:
- A2 reboot (lingering off): unit log, inhibitor lines, seconds to `QEMU exited`:
- B1 logout (lingering on):
- B2 reboot (lingering on):
- Sign-in screen:
- Locked session:
- Idle Windows shutdown time for the README:
- Pass (yes/no), and why:

## After the proofs

Keep `$S/lanai-proof` until every result is recorded. It shares its blocks with
`~/.windows`, so it costs little space at first and grows as the copy's Windows changes.
Delete it with `rm -rf "$S/lanai-proof"`. Phase 8's rehearsal makes a fresh copy.
