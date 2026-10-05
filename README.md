# Lanai

Run Windows in a window on Omarchy, through [Looking Glass](https://github.com/gnif/LookingGlass).

Status: the spike is done except its measured sessions, and the Lanai plugin is being
built. Phase 7 adds the bar and panel; acceptance and the measured spike sessions
still gate release. The install steps below are for rehearsals on a copy.

## Why

Omarchy's built-in `omarchy-windows-vm` runs Windows in Docker and connects over RDP.
This project tests a different path: a plain QEMU VM that runs as your user, with the
Windows screen shared into Linux through Looking Glass.

Looking Glass's new IDD (Indirect Display Driver) can render in software, so it works
without GPU passthrough. The target users need Windows apps such as Office, or
Windows-only admin tools such as the Active Directory PowerShell modules. Neither needs
a GPU.

## Plan

1. **Spike:** measure Looking Glass software mode against RDP on the same Windows VM.
   See the [spec](docs/spike/spec.md), [plan](docs/spike/plan.md) and
   [results](docs/spike/results.md). The measured sessions have not run yet.
2. **Lanai**, an Omarchy plugin for [plugins.omarchy.org](https://plugins.omarchy.org),
   is being built on the assumption that Looking Glass wins. See its
   [spec](docs/plugin/spec.md). It will not be released until the spike's measured
   sessions pass.

Out of v1: GPU passthrough, and a dedicated partition or NVMe for Windows.

## Lanai

Lanai is an Omarchy bar plugin (id `io.github.jzetterman.lanai`) that runs your
`omarchy-windows-vm` Windows install in plain QEMU, as your user, and shows it in a
Looking Glass window. The plugin sits at the repository root: `manifest.json`, `bin/`,
`lib/`, `systemd/`, `guest/`, `Widget.qml`, `LanaiPanel.qml`, `LanaiModel.qml`
and `test/`. It is under construction; see the
[plan](docs/plugin/plan.md).

## Install and setup

Lanai requires Omarchy's Quickshell plugin API, an existing supported UEFI Windows
install from `omarchy-windows-vm`, `/dev/kvm` access as your user, and enough memory
for Windows and Linux. It does not install Windows or support TPM, Secure Boot or
legacy layouts. Setup installs Arch packages and builds a native client. The plugin
will need manual setup and a maintainer review before it joins the marketplace.

First rehearse on a reflink copy, as described in the [acceptance plan](docs/plugin/plan.md#phase-8-acceptance).
Stop the container VM before setup. For the released plugin, the host commands are:

```sh
omarchy plugin add https://github.com/jzetterman/lanai.git
omarchy plugin enable io.github.jzetterman.lanai --section right
```

Before enabling it for a rehearsal, set `storage` in
`${XDG_CONFIG_HOME:-$HOME/.config}/lanai/settings.json` to the copy's absolute path.
Without that setting Lanai uses `~/.windows`. Memory and cores are optional; setup
seeds them from the container's settings when readable, otherwise from half the
host's memory (at most 16 GiB) and half its CPU threads (at most 8).

Right-click Lanai's L-in-a-monitor glyph to open the panel, then click **Continue setup**.
The panel walks through checking the install, installing host packages, offering a
snapshot, building the pinned client, installing in Windows, restarting and checking
the result. At the package step, **Install in a terminal** opens a terminal which
shows the exact install command before the normal package-manager
password prompt. Nothing else in Lanai escalates. Dependencies are listed in
[`LANAI_HOST_PACKAGES`](lib/client.sh): QEMU and its GTK/SPICE/device modules,
virtiofsd, passt, socat, jq, Python, diffutils and the Looking Glass build libraries
and tools. Files Lanai downloads itself are pinned with SHA-256 in
[`lib/pins.sh`](lib/pins.sh); the client and IDD use the same build.

Accept the snapshot offer before the first boot, or make a backup and explicitly
continue without a snapshot. A snapshot shares disk blocks, takes little space
initially and grows as Windows changes. The panel reports its path and explains
how to delete the snapshot folder. Restore buttons appear after **List snapshots**.
Snapshot and restore jobs show a note while they run. You can close the panel
during a snapshot. Keep Windows off until a restore finishes. Lanai blocks Start
while a restore is unfinished; use **Finish the unfinished restore** to resume it.
It tries the Lanai data directory's `snapshots/`, then
`<storage>.lanai-snapshots/` on the storage filesystem. Both VMs must be stopped for
snapshot or restore. A restore requires running Lanai setup again.

In the setup window, open Lanai's setup drive in Explorer and run `setup.cmd`. Approve
the administrator prompt as the same Windows user; approval as a different account
is refused. The setup drive must stay **read-only**: do not attach writable setup
media or substitute files written by Windows. Setup shuts Windows down when the guest
install finishes. Let that shutdown finish; Shut down from the panel does not count.
The panel continues setup after Windows shuts down. If Windows stops during the
final checks, click **Continue setup** to start it again. In File Explorer, select
This PC and check for a drive with the files from Linux's `~/Windows` folder.
Answer that question and whether text looks the right size. If a setup boot stopped unfinished,
the panel offers **Set up in QEMU's screen** until the Lanai display driver is installed,
or **Set up in the Windows window** afterward. Open window is hidden while QEMU's
setup window is in use. Reopening the panel watches setup that is still running;
it does not resume setup from a result left by an earlier session. The panel says
setup is finished only when Lanai has recorded its completion for this disk.

## Daily use

Left-click the glyph to start Windows, or open/focus its window while it runs.
Closing the Looking Glass window leaves Windows running; click the glyph to reopen
it. Right-click opens the panel. Panel controls support Tab, Shift+Tab, Enter and
Space; Escape closes it. Settings accept whole numbers: 1–512 GiB and 1–64 cores,
and apply at the next start. Reopening the panel discards unsaved settings edits.
The CLI equivalent is `bin/lanai settings <GiB> <cores>`.

Shut down is available while Windows starts and shuts down. It asks Windows to
shut down cleanly and returns immediately. If Windows ignores the request while
starting, click Shut down again. After two minutes from
the first request, the panel offers Force stop, followed by a separate confirming click.
Unsaved work is lost on a forced stop. If the display fails or builds mismatch,
read the panel's cause, next step and log path. Stop Lanai before using
`omarchy-windows-vm` through RDP or its web console as the fallback.

Omarchy's Super shortcuts and Ctrl+Alt+Del do **not** reach Windows; use Windows'
onscreen menus. The shared folder is `~/Windows` on Linux and the virtiofs drive in
Windows Explorer. Display scale follows the focused monitor at the next VM start.
Host locking, suspend and session shutdown are covered by the
[phase 8 checks](docs/plugin/plan.md#phase-8-acceptance), which remain pending.

## Windows lock and trust exposure

Setup turns locking off for the Windows user who runs it because a locked Windows
ignores Lanai's clean shutdown request. Switch user and the machine inactivity limit
are also off for **every account** on that Windows. Setup replaces any previous lock
settings without saving them. Turning the lock back on uses the three registry
commands in Removal below; they restore Windows' defaults, not your earlier settings.
A domain or MDM policy may turn locking back on. Either that or restoring the lock can
bring back the forced stop, as can a Windows security screen left open, such as UAC.

Dockur already signs Windows in automatically at every boot. RDP and the web console
at `127.0.0.1:8006` still ask for the Windows password (`PROTECT: "Y"`), and any
process running as your Linux user can already read the stored password. Those facts
do not change. Windows now no longer locks itself or on request: an unattended,
unlocked Linux session leaves Windows open for as long as the VM runs. Lock Linux to
cover the Windows window. Lanai never reads or handles the stored Windows password.

Guest setup adds HostFission's signing certificate to the machine's Trusted
Publishers to avoid the Looking Glass driver's publisher prompt. Windows then
accepts **any driver HostFission signs** without asking. Remove that certificate
during removal as described below.

While the Windows window runs, Windows can read **anything copied on Linux,
including files**. Files copied in Windows appear on Linux in a read-only folder
under your runtime directory. This is an accepted guest-to-host exposure alongside
Looking Glass's frames and cursor, SPICE input/audio/clipboard, the network backend,
the confined `~/Windows` share and the clock-only QEMU guest agent channel.

## Networking and coexistence

DNS uses the host resolver, including search domains and Tailscale MagicDNS. A DNS
client inside Windows, such as Cloudflare WARP or a corporate agent, overrides that.
Windows can reach destinations the host can reach, including VPNs, but cannot reach
services bound only to host loopback. Host services on other addresses remain
reachable. Booting without a host default route starts Windows without networking;
it stays offline until the VM next starts.

The four container-based Windows plugins show **stopped** while Lanai runs plain
QEMU. Lanai uses its own name, L-in-a-monitor glyph and `Lanai,process=lanai` VM name.
A container start then fails safely under the verified dockur behavior. Still,
**do not start `omarchy-windows-vm` while Lanai runs Windows**, and do not change the
container's Windows version, language, disk size or format, `CLEAR`, or custom ISO
mounts while using Lanai. Its known pre-boot write paths are checked at every start;
future dockur changes remain a risk. When container settings are unreadable, Lanai
compares `windows.base` against the normal Windows 11/no-language image and skips
the disk-size check. A container may then grow the disk, adding space without
overwriting Windows data. Unknown layouts are refused.

Verified dockur baseline: **6.05**, captured in `lib/dockur-6.05.args` and the
[proofs](docs/plugin/proofs.md). The exact Omarchy build used for those proof sessions
was not recorded: **phase 8 must record it before release**. Phase 7 targets the
installed shell API from Omarchy **4.0.0.alpha**; this is an API reference, not a
claim of Windows acceptance on that version.

Reboot/power-off shutdown is best effort within Omarchy's approximately 20-second
window; logout allows up to two minutes. **Phase 8 measurement pending: Lanai's clean
Windows shutdown time on John's machine at reboot.** Earlier proof 4 sessions with
idle Windows took 7 seconds at reboot and 11–13 seconds at logout. They do not replace
the final measurement. If the wait expires, the next start reports the forced stop.

The resize-drag and scale-timing checks at the top of phase 7 still need a person and
a running Windows test copy. No client flag changes or timing claims have been made
from those checks.

## Removal

1. First, shut Lanai's VM down. This Linux command works even without the plugin:

   ```sh
   systemctl --user stop lanai-vm.service
   ```

   It waits for shutdown and can force-stop at the timeout. Let any detached setup,
   snapshot or restore operation finish before removing its code. Once Lanai's VM
   is stopped, start Windows with `omarchy-windows-vm` and connect over RDP.
   **Do every Windows removal step below in that RDP session**: uninstalling the
   IDD or SPICE vdagent can remove Lanai's display or input, and a normal Lanai boot
   has no QEMU display. Open an administrator Command Prompt as **the same Windows
   user who ran setup** (`HKCU` is account-specific). Restore Windows' default lock
   settings:

   ```bat
   reg delete HKCU\Software\Microsoft\Windows\CurrentVersion\Policies\System /v DisableLockWorkstation /f
   reg delete HKLM\SOFTWARE\Microsoft\Windows\CurrentVersion\Policies\System /v HideFastUserSwitching /f
   reg delete "HKCU\Control Panel\Desktop" /v ScreenSaverIsSecure /f
   ```

   An already absent value needs no deletion. `InactivityTimeoutSecs` is absent by
   default, so nothing is written back. These commands also turn the lock back on
   while keeping Lanai installed. Restart Windows for settings that load at sign-in.

2. Undo the other guest changes before removing the plugin. In Installed apps,
   uninstall the Looking Glass IDD and the QEMU guest agent if no other workflow uses
   them. Removing qemu-ga removes Lanai's clock-only
   `--allow-rpcs=guest-sync,guest-sync-delimited,guest-set-time` service configuration;
   no earlier service configuration was saved. The SPICE vdagent can stay if used by
   the container or another SPICE connection; otherwise uninstall it there too.
   Remove Lanai's scale task and virtiofs service from the administrator prompt:

   ```bat
   schtasks /Delete /TN "Lanai display scale" /F
   sc.exe stop VirtioFsSvc
   sc.exe delete VirtioFsSvc
   rmdir /S /Q "C:\Program Files\Lanai"
   ```

   A service already stopped needs no further stop. This removes Lanai's
   `virtiofs.exe`, `lanai-scale.ps1` and the service's auto-start, dependency and
   executable-path settings. If another workflow depended on a pre-existing
   `VirtioFsSvc`, reinstall/configure its own virtiofs tools before using it;
   setup did not save its previous settings. WinFsp and the newer signed `viofs`
   driver can stay: without that service they do not create Lanai's share, and
   another virtiofs workflow may need them. If unused, uninstall WinFsp in Installed
   apps and uninstall the VirtIO FS device/driver in Device Manager, selecting driver
   removal only after checking that no other device uses it. Container RDP and its
   normal file share do not require Lanai's virtiofs service or scale task.

3. Run `certlm.msc`, open **Trusted Publishers → Certificates**, and remove the
   **HostFission** signing certificate setup added. This removes the permission to
   install any HostFission-signed driver without a publisher prompt.

4. Shut Windows down from its **Start menu**. Restored locking can drop Lanai's
   shutdown request. The container does not restart automatically
   (`omarchy-windows-vm` uses `restart: "no"`).

5. Remove the plugin on Linux:

   ```sh
   omarchy plugin remove io.github.jzetterman.lanai
   ```

   Reloading, disabling or removing the plugin alone does not stop its VM. With the
   VM and panel operations stopped, optionally remove its persistent VM unit and
   reload the user manager:

   ```sh
   rm -f "${XDG_CONFIG_HOME:-$HOME/.config}/systemd/user/lanai-vm.service"
   systemctl --user daemon-reload
   ```

   Settings, downloaded builds, runtime copies and setup state remain in the Lanai
   directories under XDG config/data/state/cache. Keep snapshots until you know you
   no longer need them; use the exact snapshot deletion command Lanai reported.
   Windows' disk and firmware are kept, and `omarchy-windows-vm` remains available.
   Host packages may stay for other apps; remove only dependencies you know are unused.

## Tests

Run `bats test spike/test`. Tests that need btrfs read `LANAI_TEST_BTRFS_DIR` (for
example `LANAI_TEST_BTRFS_DIR=$PWD/.btrfs-test`, which git ignores) and skip when it is
unset or not on btrfs; CI runs them on a loop-mounted btrfs image. No test boots Windows
or talks to your systemd user manager; QEMU runs only paused (TCG) on 1 MiB scratch
disks for the lock tests. No test downloads or builds the Looking Glass client, runs
sudo, or opens a window: curl, cmake, pacman, sudo, omarchy, systemd-run and hyprctl
are stand-ins. Lint with
`shellcheck -x bin/* lib/*.sh spike/lgtest test/*.bats test/helpers.bash spike/test/*.bats
docs/plugin/proof-kit/proof-vm docs/plugin/proof-kit/proof-unit-start
docs/plugin/proof-kit/proof-unit-stop test/fixtures/fake-qmp test/fixtures/fake-qga`.

Lint each QML file with `/usr/bin/qmllint -I /usr/share/omarchy/shell -I /usr/lib/qt6/qml
Widget.qml LanaiModel.qml LanaiPanel.qml SetupCalls.js`. Panel settings/job tests use a fake CLI,
without sockets or a VM.

Lanai is MIT licensed; see [LICENSE](LICENSE).
