# Lanai user guide

The [README](../README.md) tells you how to start. This guide gives more
information about each setup step, snapshots, the panel and the Windows window. It
also tells you about the changes that setup makes in Windows, and it gives the full
removal steps.

- [Install and setup](#install-and-setup)
  - [Setup steps](#setup-steps)
  - [Snapshots](#snapshots)
  - [Setup in Windows](#setup-in-windows)
- [Daily use](#daily-use)
  - [Settings](#settings)
  - [Logs](#logs)
  - [The bar glyph](#the-bar-glyph)
  - [Shut down and Force stop](#shut-down-and-force-stop)
  - [Keyboard, capture and the pointer](#keyboard-capture-and-the-pointer)
  - [Resolution](#resolution)
  - [Updates](#updates)
  - [Display scale](#display-scale)
- [Windows lock and trust exposure](#windows-lock-and-trust-exposure)
- [Networking and coexistence](#networking-and-coexistence)
- [Removal](#removal)

## Install and setup

The README gives the [necessary conditions](../README.md#requirements) and the
[command that installs Lanai](../README.md#install). Before the plugin can go into the
marketplace, a manual setup and an inspection by a maintainer are necessary.

If `${XDG_CONFIG_HOME:-$HOME/.config}/lanai/settings.json` has no `storage` value,
Lanai uses `~/.windows`. The values for memory and cores in this file are optional. If
the file does not have these values, setup gives them initial values. If Lanai can
read the settings of the container, setup uses the values of the container. If Lanai
cannot read these settings, setup uses these values:

- For memory, half the memory of the host, to a maximum of 16 GiB
- For cores, half the CPU threads of the host, to a maximum of 8.

### Setup steps

To open the panel, left-click Lanai's glyph. The glyph is an L in a monitor. Then
click **Continue setup**.

The panel shows Step N of 6: Check, Packages, Snapshot, Prepare, Drivers and Verify.
In **Prepare**, Lanai prepares the storage and builds the pinned client. **Drivers**
includes the installation in Windows. Then **Verify** does a check of the result. At
the end of setup, the panel changes to its usual header.

In **Packages**, **Install in a terminal** opens a terminal. The terminal shows the
accurate command that installs the packages. Then it shows the usual password prompt
for pacman. No other part of Lanai gets administrator access.

[`LANAI_HOST_PACKAGES`](../lib/client.sh) has the list of the dependencies:

- QEMU and its GTK, SPICE and device modules
- Python, virtiofsd, passt, socat, jq and diffutils
- The Looking Glass build libraries and tools.

Lanai downloads some files directly. [`lib/pins.sh`](../lib/pins.sh) pins each of
these files with a SHA-256 hash. The client and the IDD use the same build.

### Snapshots

Setup lets you make a snapshot before the first boot. Accept this snapshot. As an
alternative, make a backup. Then tell setup to continue without a snapshot. If the
filesystem cannot make a snapshot, setup tells you that a backup is necessary before
you continue without a snapshot.

A snapshot uses the same disk blocks as the Windows disk. At first, it uses a small
quantity of space. When Windows changes, the snapshot becomes larger.

To see the path of a snapshot, expand the Snapshots section. Then click **Show
details**. To copy the path, click the icon adjacent to it. The panel updates the list
after Lanai makes, deletes or restores a snapshot. It also updates the list each time
that the panel reads its data again.

Each **Take a snapshot** button first opens the field **Snapshot name (optional)**,
where you can type a name. The button then changes to **Save snapshot**.

- To make the snapshot, click **Save snapshot** or press Enter in the field.
- To close the field, click **Cancel** or press Escape. The panel keeps your text for
  the next time.
- To close the panel, press Escape a second time.
- To make a snapshot from a terminal, run
  `~/.config/omarchy/plugins/io.github.jzetterman.lanai/bin/lanai snapshot "<name>"`.
- For a snapshot with no name, keep the name empty.

A held Enter key does not send the name.

A snapshot name has these limits:

- It is one line, with a maximum of 64 characters.
- It has no `<` or `>` characters, no control characters and no characters that you
  cannot see.
- It can have the usual space character, but no other space characters.
- Lanai removes spaces and new-line characters at the start and at the end of a name.

If Lanai rejects a name, the panel shows the cause below the field. Your text stays in
the field, where you can correct it. If you closed the panel before this message came,
the field opens again and shows the message.

You can give a name to a snapshot only when you make it. Lanai always identifies a
snapshot by its UTC time, and this time is also the name of its folder. Thus, two
snapshots can have the same name. When you restore or delete a snapshot, Lanai always
uses the time.

The list shows the newest snapshot first. Its dates and times are easy to read, and
each time shows UTC. The panel shows the name of a snapshot above its date. If two
snapshots with the same name have the same minute, their times also show the seconds.
The panel counts only the correct snapshots for this storage location.

Each row has **Delete** and **Restore** controls.

**Caution:** When you restore a snapshot, Windows does not keep the changes that
occurred after that snapshot.

- To restore a snapshot, click its restore control. The panel tells you about this
  risk. To give your approval for the snapshot that you selected, click **Restore
  now**.
- To delete a snapshot, click its delete control. To give your approval, click
  **Delete snapshot**. Windows does not change.
- To stop before you give your approval, click **Cancel** below the row.

The panel accepts your approval only after a short time. Thus, a held key cannot
select the control and give the approval at the same time. When Lanai deletes a
snapshot, the panel removes it from the list and shows no other message.

You can delete a snapshot while Windows runs, or while a different VM uses the Windows
installation. You cannot delete a snapshot while a different operation runs, or while
there is an unfinished restore.

During a snapshot or a restore, the panel shows the phase in progress and its measured
percentage. It also shows them when you open the panel during the work, or when you
start the work from the CLI. If a part of the work has no measured total, the panel
shows a busy indicator.

During a restore, the panel identifies the snapshot above the controls. For an
unfinished restore, it also identifies the snapshot if the record of the restore is
correct. If the record is not correct, it shows a general text for the restore.

You can close the panel during a snapshot. Do not start Windows until the end of a
restore.

While there is an unfinished restore, Lanai does not let you start Windows. To
continue the restore, click **Finish the unfinished restore**. To start again, restore
a different saved snapshot. If a restore stops before its end, the panel opens the
Snapshots section to show these controls.

Lanai first tries to keep snapshots in `snapshots/` in the Lanai data directory. If
this is not possible, it tries `<storage>.lanai-snapshots/` on the storage filesystem.

Before a snapshot or a restore, make sure that the two VMs are off. Lanai disables
**Take a snapshot** in these conditions, but you can see the button:

- Windows runs.
- A different VM uses the Windows installation.
- There is an unfinished restore.
- A different operation is in progress.

Before Lanai makes a new snapshot, it removes the folders of snapshots that stopped
before their end. It removes a folder only if the recorded storage location of the
folder is the storage location of this installation. This releases the disk blocks
that these folders and the Windows disk use together. Lanai does not change the
folders of other locations, or folders that have no recorded location.

After a restore, it is necessary to run Lanai setup again.

In each operation, Lanai first makes a clone and reads the image one time. Then it
makes sure that the btrfs extents that the clone and the image use together did not
change. This check is possible for these types of extents:

- Regular extents
- Compressed extents
- NOCOW extents
- Preallocated unwritten extents.

For other filesystems and other types of extents, Lanai tells you to make a backup.

This check finds usual writes to the image. It also finds an operation that stopped
before its end. But the check cannot find these changes when a different process that
uses your user account tries to make them:

- A new clone of the extents
- Changes to the extent references
- Slices of compressed extents that the process replaces.

If the disk is there, it keeps its locked inode during the restore. If dockur deleted
the disk before the restore, Lanai first puts these items in their positions:

- Its locked clone of the disk
- The boot files, after it makes sure that they are correct.

Then Lanai reads the clone.

You can try an unfinished restore again with the same snapshot. You can also replace
it with a different saved snapshot. If the image of a snapshot has damage, restore a
different snapshot by its name. If a check finds a problem before Lanai puts the disk
in its position, Lanai removes the temporary files. Windows stays the same only if
there was no previous unfinished restore.

### Setup in Windows

In the setup window, open Lanai's setup drive in Explorer. Run `setup.cmd`. In the
administrator prompt, give your approval with the account of the same Windows user.
Setup does not accept an approval from a different account.

The setup drive must stay read-only. Do not attach setup media that Windows can write
to. Do not replace the files on the setup drive with files that Windows wrote.

At the end of the installation in Windows, setup shuts down Windows. Wait for the end
of this shutdown. Shut down in the panel does not give the same result.

**Caution:** While setup.cmd runs, click **Shut down** only if setup.cmd does not
continue or its shared-folder check tells you to click it. A shutdown from the panel
stops setup, and then you must select how to continue.

setup.cmd makes sure that the shared folder from Linux is a drive in Windows, and that
Windows can read it. It stops in these conditions:

- Windows does not show the folder.
- Windows cannot read the folder.
- The check cannot run.

If the check could not run and a security tool does not let scripts run, do these
steps:

1. Let Windows PowerShell run `lanai-share-check.ps1` from the setup drive.
2. Restart Windows from the Start menu.
3. Run setup.cmd again.

If setup.cmd stopped at this check before, do not restart Windows. From the Lanai
panel, shut down Windows. Then click **Set up in a basic window** or **Set up in the
Windows window**. Lanai then does a check of the folder on Linux.

While a setup operation runs, the panel continues setup after Windows shuts down. If
no setup operation runs, click **Continue setup** at the end of the setup script. If
Windows stops during the last checks, click **Continue setup** to start Windows again.

**Verify** shows the rows Display driver, Windows agents and Scale task. Each row
shows Not checked, Waiting, Done or Failed. This value comes only from the checks that
ran. Windows agents shows Done only if all these checks are satisfactory:

- The SPICE agent check
- The guest-agent clock check
- The allow-list check.

Done gives only the result of those checks at that time. It does not tell you that the
parts continue to operate correctly. The scale row makes sure only that the task
opened its port. It does not make sure that Windows applied the scale, or that you can
see the desktop.

The scale task starts when the Windows user who ran setup signs in. Lanai cannot see
the sign-in screen, and it cannot identify the signed-in user. If Windows tells you to
type a password, sign in with the account of the user who ran setup.

While setup waits for the scale task, the panel shows a countdown of the remaining
time for the sign-in. The countdown uses the time limit that the backend records. The
default limit is 2 minutes. If `LANAI_SETUP_SCALE_LIMIT` changes the limit, the setup
worker records this value. The panel uses this recorded value, also when the
environment variable of the panel has a different value.

The countdown does not start again when you open the panel again, or when the shell or
Windows restarts. If the time data is missing or not correct, the panel shows no
countdown.

If you continue setup after it stops, Lanai does the checks again. If they are
satisfactory, Lanai waits for the scale task again, with a new countdown. If a part
does not give a result in the time limit, setup stops, and the panel identifies the
part. To do the checks again, click **Continue setup**.

To install Lanai's parts in Windows again, shut down Windows. Then click **Set up in a
basic window** or **Set up in the Windows window**. Also do these steps if setup.cmd
stopped and showed a message in Windows.

The panel can tell you that an update of the display driver in Windows is necessary.
It can also tell you that the QEMU guest agent in Windows does not have its
allow-list. In these conditions, shut down Windows. Then click **Continue setup** to
prepare Windows again.

If a setup boot stopped before its end, the panel shows **Set up in a basic window**
and **Set up in the Windows window**. Until the Lanai display driver is in Windows,
use the basic window. After the installation of this driver, use the Windows window.

The panel always shows **Start Windows** and **Open window**, but not in these
conditions:

- Before the end of the first setup for this location
- During a setup boot or a boot for the last checks.

For these boots, Lanai starts Windows and opens its window automatically. After the
first setup, the panel keeps these controls when an update of the client or the driver
waits, or when setup must continue. Setup shows the step that waits, adjacent to these
controls. If the panel does not show the usual controls and the Windows window closes,
click **Reopen the Windows window** in the Setup section. At the end of setup, the
panel shows the usual controls again.

While Windows runs during setup, the panel does not show **Snapshots**. When Windows
is off, the panel shows it again. The Settings section stays available.

When you must do something, the setup card uses the accent color of your theme. While
Lanai does work automatically, the card does not use this color. The inset of the card
stays the same.

During the setup boot, **Shut down** tells you to click it again to give your
approval. It also shows this message:
“Shutting down now stops setup. You'll choose how to continue.”

If a shutdown for this boot is in progress, or you started one before, it is not
necessary to click again. When you click Shut down or Force stop for
the first time, the panel cancels the approval that the other control waits for.

Setup continues its checks when the panel is not open, and when the shell restarts.
When you open the panel again, it shows the step in progress and the operations that
run. The panel tells you about the end of setup only after Lanai records it for this
disk.

If an operation stops with an error or before its end, the panel tells you to continue
or to try again. To continue, click **Continue setup**. After the shell restarts, this
button first finds the step that setup is at.

- If Windows runs without the setup drive, shut down Windows before you continue.
- During the last checks, wait for the end of a shutdown before you continue setup.

To run setup again after its end, shut down Windows. Then open **More actions**. Click
**Run setup again**. Select how Windows shows during setup. If you do not want to run
setup again, click **Cancel**.

When a restore is satisfactory, the panel shows a message. The message stays until you
make, restore or delete a snapshot again. The Setup section tells you if setup must
continue.

## Daily use

Left-click the glyph to open or close the panel in every state. Enter (including
keypad Enter), Space and the Menu key on the focused glyph also toggle the panel.
Right-click starts Windows only when stopped with setup finished and no blocking
operation or unfinished restore. It opens the Windows window when running with
setup finished and the window closed; otherwise it opens the panel. A pending
display driver update opens the panel, where **Start Windows** remains available
for a working install. Closing the Looking Glass window leaves Windows running;
right-click to reopen it. The tooltip names the state and the right-click action.
When the panel holds more, such as a warning or a forced-stop notice, the tooltip
says to open the panel for details. The panel keeps **Start Windows**, **Open window**
and **Shut down** controls. Panel controls support Tab, Shift+Tab, Enter and Space;
Escape closes it.
If starting or opening fails, the glyph opens the panel to explain why. It also
opens the panel when a start reports that the previous run was forced to stop.
The daily header shows saved memory, cores and scale. Draft edits do not change
that line, and it does not describe the running VM's allocation. The divided
**Settings**, **Snapshots** and **Logs** rows open one section at a time.
**More actions** holds Run setup again, updates, notice dismissal and Force stop
when the backend permits them. Failed opens Logs with the cause and recovery
actions. It does not skip the Force stop wait.

### Settings

Settings accept whole numbers: 1–512 GiB and 1–64 cores. Memory and cores apply
at the next start. Windows scale is “Match my monitor” (the default) or a fixed
percentage: 100–250 in steps of 25, then 300–500 in steps of 50. **Save**
saves the scale only when you chose an entry in the scale list since you opened
the panel or last used Reset, even the entry already shown; otherwise it saves
memory and cores only. **Unsaved** marks changed drafts or a scale selection
since the last successful save. Polls, section changes and failed saves preserve
the drafts. A refused save keeps its result in Settings. **Reset** restores the
current saved values locally and clears scale selection intent. It saves nothing
and does not restore defaults. A clean panel
shows disabled **Saved** and hides Reset and Unsaved.
Typing a changed memory or CPU value makes Save available immediately; clicking
Save commits that text without requiring Enter first.
After a successful scale save, Save and Reset stay available without Unsaved.
Another save still saves scale, even if its value is unchanged. Reset or reopening
the panel clears that intent. Reopening also discards unsaved settings edits.
The CLI equivalent is
`~/.config/omarchy/plugins/io.github.jzetterman.lanai/bin/lanai settings <GiB> <cores> [auto|percentage]`.
Three arguments always save the scale; two keep the scale choice.

### Logs

Logs has copy buttons for VM, Window, Build, Jobs and Actions when available.
The VM button copies the user-journal command; file rows copy their full paths.
The shortened display names do not shorten the copied text. Copy runs no log
command. **Copied** confirms success. An inline failure keeps the button available
for retry.

Lanai's logs and where they are:

- The Actions log, `panel-run.log`, and the Jobs log, `panel-job.log`, in Lanai's
  state directory (`~/.local/state/lanai`).
- The Windows window build log, `build-client.log`, in the same directory.
- The Windows window log, `client.log`, in `$XDG_RUNTIME_DIR/lanai`.
- The Windows VM log, in your user journal under lanai-vm
  (`journalctl --user -u lanai-vm`).

### The bar glyph

The glyph uses the normal foreground when stopped, an accent and underline while
starting, running or stopping, and a progress underline while busy. Without
measurable progress, a fixed-width segment moves across the underline. A badge
marks your turn or a failure. Failure takes priority, then attention, busy, active
and stopped. The normal Drivers wait for setup.cmd keeps the active glyph while
Windows runs. Recovery and failures keep their priority.

### Shut down and Force stop

Shut down is available while Windows starts and shuts down. It asks Windows to
shut down cleanly and returns immediately. If Windows ignores the request while
starting, click Shut down again. After 15 seconds from
the first request, the panel offers Force stop, followed by a separate confirming click.
Unsaved work is lost on a forced stop. If the display fails or builds mismatch,
read the panel's cause, next step and named logs. Stop Lanai before using
`omarchy-windows-vm` through RDP or its web console as the fallback.

### Keyboard, capture and the pointer

Outside capture mode (below), Omarchy's Super shortcuts do **not** reach Windows;
use Windows' onscreen menus. Outside capture, Ctrl+Alt+Del is Omarchy's shortcut to
close all windows: it closes the Windows window too, though Windows keeps running.
The shared folder is `~/Windows` on Linux and the virtiofs drive in Windows Explorer.

Capture mode gives the mouse and keyboard to Windows; Omarchy's shortcuts go to
Windows instead. Press Scroll Lock to enter it and Scroll Lock again to leave (many
laptops reach Scroll Lock with Fn and another key);
Looking Glass shows Capture Enabled or Capture Disabled. Scroll Lock with another key
runs one of Looking Glass's own commands, such as Scroll Lock+F for fullscreen. Hold
Scroll Lock to list them.

Over the Windows window, Looking Glass hides your Linux pointer and shows the
Windows cursor in its place. Lanai stops the Looking Glass client from moving your
hidden pointer, so the window's edge follows the mouse when you drag it. That has
two costs:

- Outside capture, after the window changes size without the mouse, such as a
  resize from the keyboard, the Windows cursor can show away from the hidden
  pointer. A click lands at the hidden pointer, so move the
  mouse before you click.
- In capture, the hidden pointer stays at the point in the window where capture
  began. When capture ends, the Windows cursor jumps back to that point. A change of
  window size during capture, such as Scroll Lock+F or a monitor or scale change,
  also moves it there.

### Resolution

Windows' resolution follows the Windows window. When the window opens, resizes,
tiles, goes fullscreen or moves to a monitor with another scale, Windows matches it
within 5 seconds. This also holds after Windows' display driver restarts. Windows
cannot change its desktop size before you sign in. So when Windows starts or
restarts, it matches the window within 15 seconds of your sign-in: when the
Windows user who ran setup signs in, Lanai's scale task sets the size. Its log is
`C:\Program Files\Lanai\lanai-signin.log`. If you sign in as another Windows user,
you may need to resize the window once. To change Windows' resolution, resize the
window. A resolution you pick in Windows' Display settings does not stay: Lanai
sets the window's size again.

Two sizes are exceptions. Lanai never asks for a size under 640 wide or 480 high,
the smallest Windows' display driver takes. Windows also refuses a size too large
for the display memory Lanai gives it, such as fullscreen on a very high-resolution
monitor. Lanai asks a few times, so the screen may flicker or Windows may show a
notice, and then stops. In both cases Windows keeps its last size and the picture
is scaled to fit the window. Resize the window or leave fullscreen to fix it.

### Updates

Installs set up with an earlier version of Lanai keep working, but Windows may not
match the window, and after the computer wakes from sleep, the mouse may reach only
part of Windows. When only the Windows window needs an update, Lanai updates it by
itself, with no click, after `omarchy plugin update`, a shell restart or a sign-in.
The first plugin update to this version starts it only at the next shell restart
(`omarchy-restart-shell`) or sign-in; until then the panel names **Update the
Windows window** in More actions.
The update takes several minutes, works whether Windows runs or not, and changes
nothing in Windows. You can start and use Windows during the update, and the update
gets less CPU than Windows. If a Windows window that opened before the update
finished is still open, the panel says to close it and open it again, and the bar's
tooltip points to the panel. If the update fails, cannot start, or stops twice before it finishes (for
example at a logout), the panel says what may go wrong and names **Update the
Windows window** in More actions. When a log holds the reason, the panel also names
that log: the Windows window build log or the Jobs log. When the scale task in
Windows was set up without the sign-in step, Windows may stay at its old size after
it starts, until you resize the window. Lanai then does not update the window by
itself, and the panel names **Run setup again**. It updates the Windows window too,
turns the Windows lock off again, and restarts Windows as setup always does. If
setup cannot update the window, the panel points to the same build log.

### Display scale

Windows' display scale changes while Windows runs, without a restart or sign-out.
“Match my monitor” uses the Windows step nearest the scale of the monitor the
Windows window is on, with ties rounded down. When the window moves to a monitor
with another scale, or that monitor's scale changes, Windows follows within 5
seconds, also while the panel is closed or the shell restarts. While the window is
closed, the monitor it was last on counts; before it first opens, the monitor
focused at start. If that monitor is gone, the focused monitor counts, then the
first one Hyprland lists. Without any monitor the scale stays as it was (100% at
start).

A scale save while Windows runs reaches Windows within 5 seconds if you are signed
in, or within 20 seconds of your next sign-in. Lanai cannot see which, so the panel
says both. A save while Windows is stopped applies at the next start.

You can also pick a scale in Windows, under Settings > System > Display > Scale.
Your pick holds until your next scale save, a sign-out, a Windows restart or the VM
stopping, and the panel notes that saving a scale replaces it. While it holds,
“Match my monitor” does not follow the window. A pick never changes Lanai's
setting. Windows changes its recommended scale when the resolution changes;
the scale task sets it back to your pick, or to the scale you saved in Lanai when
you have no pick. The scale holds as the window resizes: Lanai caps it at
Windows' limit for the current resolution, and it goes back up when the window
grows. The scale task starts more slowly at a sign-in. So the scale changes a
sign-in brings (the scale after a pick ends, and the scale for the size Lanai
sets) finish within 20 seconds of it, not 5.

This is Windows' display scale, separate from its “Text size” setting. While
Windows' custom scaling is on (a percentage that needs a sign-out to apply), it
overrides the scale Lanai sets; turn it off under Settings > System > Display >
Scale, then sign out. Some Windows apps redraw at a new scale only after they
restart. If Windows accepts a change but leaves the scale unchanged, the scale
task tries again once a minute. Its log is
`C:\Program Files\Lanai\lanai-scale.log`.

The scale task runs a small program that setup builds in Windows,
`C:\Program Files\Lanai\lanai-start.exe`. If Windows blocks or removes it later
(for example, antivirus quarantines it, or Smart App Control or an App Control or
AppLocker policy is turned on), the scale and the size at sign-in stop following
Lanai. To fix it, allow the program by its path,
`C:\Program Files\Lanai\lanai-start.exe`, in your antivirus or in the App Control
or AppLocker policy. A rule by file hash stops working, because setup builds the
program again on each run. Or turn Smart App Control off under Windows Security >
App & browser control. Smart App Control allows no single program, and on many
Windows versions only a reinstall turns it back on. Then click **Run setup
again**. Setup checks that Windows runs the program, and stops with these steps
if it does not.

Installs set up before live scale keep the old scale task: a scale save applies at
the next start, the old task undoes scale changes made in Windows, and “Match my
monitor” does not follow the window while Windows runs. The panel's warning says
that scale saves apply only the next time Windows starts, beside the size fix.
The words after a scale save say the same three things. To get live scale, shut
Windows down and click **Run setup again**; it also turns the Windows lock off
again. After you update Lanai while Windows runs, the panel may say some of
Lanai's helpers stopped until Windows next starts. The
[rehearsal checklist](plugin/proofs.md)
covers resizing, scale limits and reconnecting the display.
Host locking, suspend and session shutdown are covered by the
[phase 8 checks](plugin/plan.md#phase-8-acceptance), which remain pending.

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
the confined `~/Windows` share, the QEMU guest agent channel (the clock, plus one
command at setup that its allow-list must refuse) and the
scale channel. The scale channel runs one way: each message holds a scale step and
a save number, and Lanai never reads what Windows writes to it.

Windows opens the scale channel only to administrators, so the scale task runs at
your sign-in with your administrator rights and no prompt. Its program, the
program's source, its script, logs and temp folder sit in `C:\Program Files\Lanai`,
where only administrators can write. Setup builds the program there from Lanai's
source with the C# compiler that comes with Windows, so no prebuilt Lanai program
enters Windows. Such a task still starts with your Windows user's environment
variables and registry settings, so malware already running as that user could use
it to gain administrator rights. With UAC on, that malware has other ways to the
same end.

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
[proofs](plugin/proofs.md). The exact Omarchy build used for those proof sessions
was not recorded: **phase 8 must record it before release**. Phase 7 targets the
installed shell API from Omarchy **4.0.0.alpha**; this is an API reference, not a
claim of Windows acceptance on that version.

Reboot/power-off shutdown is best effort within Omarchy's approximately 20-second
window; logout allows up to two minutes. **Phase 8 measurement pending: Lanai's clean
Windows shutdown time on John's machine at reboot.** Earlier proof 4 sessions with
idle Windows took 7 seconds at reboot and 11–13 seconds at logout. They do not replace
the final measurement. If the wait expires, the next start reports the forced stop.

## Removal

1. First, let any detached setup, snapshot, restore or Windows window update finish.
   To stop setup partway, click **Shut down** in the panel and confirm. Then shut
   Lanai's VM down. This Linux command works even without the plugin:

   ```sh
   systemctl --user stop lanai-vm.service
   ```

   It waits for shutdown and can force-stop at the timeout. Once Lanai's VM
   is stopped, start Windows with `omarchy-windows-vm launch` and connect over RDP.
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
   schtasks /End /TN "Lanai display scale"
   schtasks /Delete /TN "Lanai display scale" /F
   sc.exe stop VirtioFsSvc
   sc.exe delete VirtioFsSvc
   rmdir /S /Q "C:\Program Files\Lanai"
   ```

   Ending the task ends its program, and the program's end ends the script, so
   `rmdir` can remove them. A task or service already stopped needs no further
   stop. This removes Lanai's `virtiofs.exe`, the scale task's `lanai-start.exe`,
   `lanai-start.cs` and any `lanai-start.old-*.exe`, `lanai-scale.ps1`, the logs
   `lanai-scale.log`, `lanai-signin.log` and `lanai-signin.log.old`, the temp
   folder, and the service's auto-start, dependency and executable-path
   settings. An install set up before live scale also kept the scale log in
   `%LOCALAPPDATA%\Lanai`; delete that folder too. If another workflow depended on a pre-existing
   `VirtioFsSvc`, reinstall/configure its own virtiofs tools before using it;
   setup did not save its previous settings. WinFsp and the newer signed `viofs`
   driver can stay: without that service they do not create Lanai's share, and
   another virtiofs workflow may need them. If unused, uninstall WinFsp in Installed
   apps and uninstall the VirtIO FS device/driver in Device Manager, selecting driver
   removal only after checking that no other device uses it. Container RDP and its
   normal file share do not require Lanai's virtiofs service or scale task.

3. Run `certlm.msc`, open **Trusted Publishers → Certificates**, and remove the
   **HostFission** signing certificate setup added. This removes the permission to
   install any HostFission-signed driver without a publisher prompt. From the
   administrator prompt instead, run `certutil -store TrustedPublisher`, find the
   certificate whose Subject names HostFission, and delete it by its `Cert Hash(sha1)`
   value:

   ```bat
   certutil -delstore TrustedPublisher <Cert Hash(sha1) value>
   ```

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
   no longer need them. To delete one, remove its folder, at the path Lanai showed
   when it took the snapshot.
   Windows' disk and firmware are kept, and `omarchy-windows-vm` remains available.
   Host packages may stay for other apps; remove only dependencies you know are unused.
