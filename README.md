<p align="center"><img src="docs/assets/lanai-wordmark.jpg" alt="Lanai" width="540"></p>

# Lanai

Run Windows in a window on Omarchy, through [Looking Glass](https://github.com/gnif/LookingGlass).

Lanai is an early 0.x release. Setup offers to take a snapshot before Windows first
starts under Lanai. Where it cannot, make a backup first.

## Requirements

- Omarchy 4.0 with its plugin API. If `omarchy plugin` is not a command, your Omarchy
  is too old. Lanai targets the shell API of Omarchy 4.0.0.alpha. No exact tested
  build is recorded: Lanai was built on a desktop that runs an Omarchy dev build.
- A UEFI Windows install from `omarchy-windows-vm install`, finished to the Windows
  desktop.
- Access to `/dev/kvm` as your user.
- Enough memory for Windows and Linux. Lanai starts with the container's memory size
  when it can read the container's settings. Otherwise it uses half the host's
  memory, at most 16 GiB. You can change it in Settings.
- About 1 GB of downloads during setup, plus the Arch packages.

Lanai does not install Windows. It does not support TPM, Secure Boot or legacy
layouts.

Setup installs Arch packages with `sudo pacman`, in a terminal it opens for you: QEMU
and its modules, virtiofsd, passt, socat, jq, Python, diffutils and the Looking Glass
build tools. [`LANAI_HOST_PACKAGES`](lib/client.sh) has the exact list. Setup also
builds the Looking Glass client.

## Install

Finish the `omarchy-windows-vm` install first. Then run:

```sh
omarchy plugin add https://github.com/jzetterman/lanai.git --enable
```

It asks you to confirm, then asks once where in the bar to put Lanai's glyph.

Stop the container before setup:

```sh
omarchy-windows-vm stop
```

## First setup

Left-click Lanai's glyph in the bar (an L in a monitor) to open the panel, then click **Continue setup**.
Setup has six steps. After most steps, click **Continue setup** to move on.

1. **Check.** Lanai checks the Windows install. Wait.
2. **Packages.** Click **Install in a terminal**. Type your password, accept pacman's
   prompts, and press Enter when it ends.
3. **Snapshot.** Click **Take a snapshot**, then **Save snapshot** (the name is
   optional). If you have a backup, you can click **Continue without a snapshot**
   instead.
4. **Prepare.** Wait while Lanai builds the Windows window. This takes several
   minutes.
5. **Drivers.** Lanai downloads the drivers (about 900 MB). Then Windows opens in a
   basic window. In Windows, open Lanai's setup drive in Explorer and run
   `setup.cmd`. Approve the administrator prompt as the signed-in Windows user;
   approval from another account is refused. Windows then shuts down by itself,
   and Lanai starts it again. Do not click **Shut down** unless `setup.cmd` or the
   panel tells you to.
6. **Verify.** Wait while Lanai checks Windows. If Windows waits at its sign-in
   screen, sign in as the user who ran setup.

When setup finishes, the panel returns to its daily view and Windows runs in the
Windows window.

Setup turns off the Windows lock, trusts the Looking Glass driver's publisher and
installs Lanai's services. Windows can also read what you copy on Linux. The
[user guide](docs/guide.md#windows-lock-and-trust-exposure) explains each change.

## Daily use

- Left-click the glyph to open the panel. Right-click it to start Windows, or to
  open the Windows window when Windows runs.
- Closing the Windows window leaves Windows running. Right-click the glyph to open
  it again.
- To stop Windows, click **Shut down** in the panel. If Windows does not stop, the
  panel offers **Force stop** in **More actions** after 15 seconds. A forced stop
  loses unsaved work.
- Never start `omarchy-windows-vm` while Lanai runs Windows. Leave the container's
  Windows version, language, disk size or format, `CLEAR` and ISO mounts unchanged.
  To use the container over RDP instead, shut Windows down in Lanai first, then run
  `omarchy-windows-vm launch`.
- Outside capture mode, Ctrl+Alt+Del goes to Omarchy and closes all windows, the
  Windows window too. Windows keeps running.
- Press Scroll Lock to enter capture mode. The mouse, the keyboard and Omarchy's
  shortcuts then go to Windows. Press Scroll Lock again to leave. On a laptop, you
  often reach Scroll Lock with Fn and another key.
- Resize the window to change Windows' resolution.
- The shared folder is `~/Windows` on Linux and a drive in Windows Explorer.
- **Settings** in the panel sets memory, cores and Windows' scale. Memory and cores
  apply at the next start.
- **Snapshots** in the panel lists your snapshots. Take or restore one while Windows
  is shut down. After a restore, run setup again.

The [user guide](docs/guide.md#daily-use) has the detail.

## Updating

```sh
omarchy plugin update
omarchy-restart-shell
```

Lanai updates the Windows window by itself. If the panel names **Run setup again**,
shut Windows down, open **More actions** and click **Run setup again**.

## Removal

These are the short steps. The [user guide](docs/guide.md#removal) has the full
steps.

1. Let any setup, snapshot, restore or update in the panel finish. Then stop
   Lanai's VM:

   ```sh
   systemctl --user stop lanai-vm.service
   ```

2. Run `omarchy-windows-vm launch` to start Windows, and connect over RDP. There,
   open an administrator Command Prompt as the Windows user who ran setup. Restore
   Windows' default lock settings:

   ```bat
   reg delete HKCU\Software\Microsoft\Windows\CurrentVersion\Policies\System /v DisableLockWorkstation /f
   reg delete HKLM\SOFTWARE\Microsoft\Windows\CurrentVersion\Policies\System /v HideFastUserSwitching /f
   reg delete "HKCU\Control Panel\Desktop" /v ScreenSaverIsSecure /f
   ```

   Then undo the other changes as the guide says: the apps, the scale task and
   service, and the publisher certificate.

3. Shut Windows down from its Start menu.
4. Remove the plugin:

   ```sh
   omarchy plugin remove io.github.jzetterman.lanai
   ```

## More

- [User guide](docs/guide.md): each setup step, snapshots, the panel, what setup
  changes in Windows, networking and the full removal steps.
- [Development](docs/development.md): the background, the file layout and the tests.
- Specs: the [plugin spec](docs/plugin/spec.md) and the
  [spike spec](docs/spike/spec.md).

## License

Lanai is MIT licensed (see [LICENSE](LICENSE)), except the patches to the
Looking Glass client in `patches/looking-glass/`. Those carry Looking Glass's
license, GPL-2.0-or-later, and its full text is in
[COPYING](patches/looking-glass/COPYING) beside them.
