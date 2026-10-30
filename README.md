<p align="center"><img src="docs/assets/lanai-wordmark.jpg" alt="Lanai" width="540"></p>

# Lanai

Use Windows in a window on Omarchy, through [Looking Glass](https://github.com/gnif/LookingGlass).
The Windows window is the Looking Glass window that shows Windows.

Lanai is new, and its version is 0.x. Before Windows starts with Lanai for the
first time, setup lets you make a snapshot. If setup cannot make a snapshot, make a
backup first.

## Requirements

- Omarchy 4.0 or newer, with its plugin API. If `omarchy plugin` is not a command,
  you must have a newer Omarchy version. Lanai is for the shell API of Omarchy
  4.0.0.alpha. We did not record the accurate Omarchy build that we used for
  tests. We made Lanai on a desktop with an Omarchy dev build.
- A completed UEFI installation of Windows, from `omarchy-windows-vm install`.
- Access to `/dev/kvm` for your user.
- Sufficient memory for Windows and Linux. The container is the Windows VM that
  `omarchy-windows-vm` operates. If Lanai can read the settings of the container, it
  starts Windows with the same quantity of memory as the container. If Lanai cannot
  read these settings, it uses half the memory of the host, to a maximum of 16 GiB.
  You can change the memory in Settings.
- Setup downloads approximately 1 GB, plus the Arch packages.

Lanai does not install Windows. It cannot use TPM, Secure Boot or legacy layouts.

Setup opens a terminal for you, where you type your password. In this terminal, setup
installs the Arch packages: QEMU and its modules, virtiofsd, passt, socat, jq, Python,
diffutils and the Looking Glass build tools. [`LANAI_HOST_PACKAGES`](lib/client.sh) has
the accurate list. Setup also builds the Looking Glass client.

## Install

Complete the `omarchy-windows-vm` installation first. Then run this command:

```sh
omarchy plugin add https://github.com/jzetterman/lanai.git --enable
```

The command shows a prompt for your approval. Then, one time, it shows a prompt
where you select the position of Lanai's glyph in the bar.

Before setup, stop the container:

```sh
omarchy-windows-vm stop
```

## First setup

Setup makes changes to Windows. It disables the Windows lock, and it does not save your
previous lock settings. Thus, Windows stays unlocked when Linux stays unlocked. To put
the Windows window behind the Linux lock screen and prevent access to it, lock Linux.

Setup also makes Windows accept all drivers from the publisher of the Looking Glass
display driver, and it installs Lanai's services. The
[user guide](docs/guide.md#windows-lock-and-trust-exposure) tells you about each change.

Windows can read the data that you copy on Linux. This includes files.

Lanai's glyph in the bar is an L in a monitor. To open the panel, left-click the
glyph. Then click **Continue setup**.

Setup has six steps. At each step, the panel gives the instructions. After most
steps, click **Continue setup** to go to the next step.

1. **Check.** Lanai does a check of the Windows that you installed. Wait.
2. **Packages.** Click **Install in a terminal**. Type your password. Accept
   pacman's prompts. When the installation stops, press Enter to close the terminal.
3. **Snapshot.** Click **Take a snapshot**. A name for the snapshot is optional. Then
   click **Save snapshot**. If you have a backup, you can click **Continue without a
   snapshot** as an alternative.
4. **Prepare.** Wait while Lanai builds the Looking Glass client. This step continues
   for some minutes.
5. **Drivers.** Lanai downloads approximately 900 MB of drivers. Then Windows starts
   in a basic window.

   In Windows, open Lanai's setup drive in Windows Explorer. Run `setup.cmd`. During
   this step, do not click **Shut down** unless `setup.cmd` or the panel tells you to
   click it. In the administrator prompt, give your approval as the signed-in Windows
   user. Setup does not accept an approval from a different account.

   Then Windows shuts down automatically, and Lanai starts it again.
6. **Verify.** Wait while Lanai does a check of Windows. If Windows stays at its
   sign-in screen, sign in as the Windows user who ran setup. Then the panel
   changes to its usual header, and Windows operates in the Windows window.

## After setup

- To open the panel, left-click the glyph. To start Windows, right-click the glyph.
  When Windows operates, right-click the glyph to open the Windows window.
- When you close the Windows window, Windows continues to operate. To open the
  window again, right-click the glyph.
- To stop Windows, click **Shut down** in the panel. If Windows does not stop after
  15 seconds, the panel shows **Force stop** in **More actions**.
- **Caution:** If you click **Force stop**, Windows does not keep the work that you
  did not save.
- While Lanai operates Windows, do not start `omarchy-windows-vm`. Do not change these
  settings of the container: the Windows version, language, disk size or format,
  `CLEAR` or ISO mounts.
- To use the container through RDP, shut down Windows in Lanai. If a snapshot or
  restore is in progress, wait until its end. If the panel shows a snapshot or
  restore that stopped before its end, complete it in the panel. Then run
  `omarchy-windows-vm launch`.
- To start capture mode, press Scroll Lock. In capture mode, the mouse, the keyboard
  and Omarchy's shortcuts go to Windows. To stop capture mode, press Scroll Lock again.
  On many laptops, to get Scroll Lock, press Fn and a different key.
- When you are not in capture mode, Ctrl+Alt+Del goes to Omarchy and closes all
  windows. This includes the Windows window. Windows continues to operate.
- To change Windows' resolution, resize the Windows window.
- The shared folder is `~/Windows` on Linux and a drive in Windows Explorer.
- In the panel, **Settings** sets the memory, the cores and the scale of Windows.
  Lanai uses changes to memory and cores when Windows starts the next time.
- In the panel, **Snapshots** shows your snapshots. Before you make or restore a
  snapshot, shut down Windows. After a restore, setup starts again. Click **Continue
  setup**.

The [user guide](docs/guide.md#daily-use) has more information.

## Updates

To update Lanai, run these commands:

```sh
omarchy plugin update io.github.jzetterman.lanai
omarchy-restart-shell
```

Lanai updates the Looking Glass client automatically. If the panel shows **Run setup
again**, shut down Windows. Then open **More actions**. Click **Run setup again**.

## Removal

The [user guide](docs/guide.md#removal) has the full steps.

1. If a setup, snapshot, restore or update in the panel is in progress, wait until
   its end. To stop setup before its end, click **Shut down** in the panel. Then
   click it again to give your approval. After this, stop Lanai's VM:

   ```sh
   systemctl --user stop lanai-vm.service
   ```

2. Run `omarchy-windows-vm launch`. This command starts Windows and opens an RDP
   window. In the RDP window, open an administrator Command Prompt as the Windows
   user who ran setup. Set the lock settings of Windows to the defaults:

   ```bat
   reg delete HKCU\Software\Microsoft\Windows\CurrentVersion\Policies\System /v DisableLockWorkstation /f
   reg delete HKLM\SOFTWARE\Microsoft\Windows\CurrentVersion\Policies\System /v HideFastUserSwitching /f
   reg delete "HKCU\Control Panel\Desktop" /v ScreenSaverIsSecure /f
   ```

   Then do steps 3 and 4 in the [Removal section of the guide](docs/guide.md#removal).
   These steps remove the apps, the scale task and service, and the publisher certificate.

3. From the Windows Start menu, shut down Windows.
4. Remove the plugin:

   ```sh
   omarchy plugin remove io.github.jzetterman.lanai
   ```

## More

- [User guide](docs/guide.md): each setup step, snapshots, the panel, the changes
  that setup makes in Windows, the network and the full removal steps.
- [Lanai development](docs/development.md): the background, the file layout and the
  tests.
- Specs: the [plugin spec](docs/plugin/spec.md) and the
  [spike spec](docs/spike/spec.md).

## License

Lanai has the MIT license. Refer to [LICENSE](LICENSE). But the patches to the
Looking Glass client in `patches/looking-glass/` have the license of Looking Glass,
GPL-2.0-or-later. The file [COPYING](patches/looking-glass/COPYING) in the same
folder has the full text of this license.
