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
- [The network and the container](#the-network-and-the-container)
- [Removal](#removal)

## Install and setup

The README gives the [necessary conditions](../README.md#requirements) and the
[command that installs Lanai](../README.md#install).

Lanai is not in the marketplace at this time. Before it can be in the marketplace, it
must have a manual setup, and a maintainer must examine it.

If `${XDG_CONFIG_HOME:-$HOME/.config}/lanai/settings.json` has no `storage` value,
Lanai uses `~/.windows`. The values for memory and cores in this file are optional. If
the file does not have these values, setup gives them initial values. If Lanai can
read the settings of the container, setup uses the values of the container. If Lanai
cannot read these settings, setup uses these values:

- For memory, half the memory of the host, to a maximum of 16 GiB
- For cores, half the CPU threads of the host, to a maximum of 8.

### Setup steps

Lanai's glyph in the bar is an L in a monitor. To open the panel, left-click the
glyph. Then click **Continue setup**.

The panel shows Step N of 6: Check, Packages, Snapshot, Prepare, Drivers and Verify.
In **Prepare**, Lanai prepares the storage and builds the pinned Looking Glass client.
**Drivers** includes the installation in Windows. Then **Verify** does a check of the
result. At the end of setup, the panel changes to its usual header.

In **Packages**, **Install in a terminal** opens a terminal. The terminal shows the
accurate command that installs the packages. Then it shows the usual password prompt
for pacman. No other part of Lanai gets administrator access.

[`LANAI_HOST_PACKAGES`](../lib/client.sh) has the list of the dependencies:

- QEMU and its GTK, SPICE and device modules
- Python, virtiofsd, passt, socat, jq and diffutils
- The Looking Glass build libraries and tools.

Lanai downloads some files directly. [`lib/pins.sh`](../lib/pins.sh) pins each of
these files with a SHA-256 hash. The Looking Glass client and the display driver use
the same build.

### Snapshots

Setup lets you make a snapshot before the first boot. Make this snapshot. As an
alternative, make a backup. Then tell setup to continue without a snapshot. If the
filesystem cannot make a snapshot, setup tells you that a backup is necessary before
you continue without a snapshot.

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
- Lanai removes space characters and new-line characters at the start and at the end
  of a name.

If Lanai rejects a name, the panel shows the cause below the field. Your text stays in
the field, where you can correct it. If you closed the panel before the panel showed
this message, the field opens again and shows the message.

You can give a name to a snapshot only when you make it. Lanai always identifies a
snapshot by its UTC time, and this time is also the name of its folder. Thus, two
snapshots can have the same name. When you restore or delete a snapshot, Lanai always
uses the time.

The list shows the newest snapshot first. Its dates and times are easy to read, and
each time shows UTC. The panel shows the name of a snapshot above its date. If two
snapshots with the same name have the same minute, their times also show the seconds.
The panel counts only the correct snapshots for this storage location.

To see the path of a snapshot, open the Snapshots section. Then click **Show
details**. To copy the path, click the icon adjacent to it.

The panel changes the list after Lanai makes, deletes or restores a snapshot. It also
changes the list each time that the panel reads its data again.

Before you make or restore a snapshot, make sure that Windows is off in Lanai and in
the container. Lanai disables **Take a snapshot** in these conditions, but you can see
the button:

- Windows operates.
- A different VM uses the Windows disk.
- There is an unfinished restore.
- A different operation is in progress.

After a restore, you must complete Lanai setup again.

Each row has **Delete** and **Restore** controls.

**Caution:** When you restore a snapshot, Windows does not keep the changes that
occurred after that snapshot.

- To restore a snapshot, click its **Restore** control. The panel tells you about this
  risk. To give your approval for the snapshot that you selected, click **Restore
  now**.
- To delete a snapshot, click its **Delete** control. To give your approval, click
  **Delete snapshot**. Windows does not change.
- To stop before you give your approval, click **Cancel** below the row.

The panel accepts your approval only after a short time. Thus, a held key cannot
select the control and give the approval at the same time. When Lanai deletes a
snapshot, the panel removes it from the list and shows no other message.

You can delete a snapshot while Windows operates, or while a different VM uses the
Windows disk. You cannot delete a snapshot while a different operation is in
progress, or while there is an unfinished restore.

During a snapshot or a restore, the panel shows the part of the work that is in
progress, and its measured percentage. It also shows them when you open the panel
during the work, or when you start the work from the CLI. If a part of the work has
no measured total, the panel shows a busy indicator.

During a restore, the panel identifies the snapshot above the controls. For an
unfinished restore, it also identifies the snapshot if the data that Lanai recorded
for the restore is correct. If this data is not correct, the panel shows a general
text for the restore.

You can close the panel during a snapshot. Do not start Windows until the end of a
restore.

While there is an unfinished restore, Lanai does not let you start Windows. To
continue the restore, click **Finish the unfinished restore**. To start again, restore
a different saved snapshot. If a restore stops before its end, the panel opens the
Snapshots section to show these controls.

You can try an unfinished restore again with the same snapshot. You can also replace
it with a different saved snapshot. If the image of a snapshot has damage, restore a
different snapshot by its name.

A snapshot uses the same disk blocks as the Windows disk. When Lanai makes a
snapshot, the snapshot uses a small quantity of space. When Windows changes, the
snapshot becomes larger.

Lanai first tries to keep snapshots in `snapshots/` in the Lanai data directory. If
this is not possible, it tries `<storage>.lanai-snapshots/` on the storage filesystem.

Before Lanai makes a new snapshot, it removes the folders of snapshots that stopped
before their end. It removes a folder only if the recorded storage location of the
folder is the storage location that Lanai uses. This releases the disk space that
only these folders use. Lanai does not change the folders of other locations, or
folders that have no recorded location.

In each operation, Lanai first makes a clone and reads the image one time. Then it
makes sure that the btrfs extents that the clone and the image use together did not
change. This check is possible for these types of extents:

- Regular extents
- Compressed extents
- NOCOW extents
- Preallocated unwritten extents.

For other filesystems and other types of extents, Lanai tells you to make a backup.

This check finds the usual changes that a process writes to the image. It also finds
an operation that stopped before its end. But Lanai does not make sure that
this check finds these changes when a different process that uses your user account
tries to make them:

- A new clone of the extents
- Changes to the extent references
- Slices of compressed extents that the process replaces.

If the disk is there, it keeps its locked inode during the restore. If dockur deleted
the disk before the restore, Lanai first puts these items in their positions:

- Its locked clone of the disk
- The boot files, after it makes sure that they are correct.

Then Lanai reads the clone.

If a check finds a problem before Lanai puts the disk in its position, Lanai removes
the temporary files. Windows stays the same only if there was no previous unfinished
restore.

### Setup in Windows

In the setup window, open Lanai's setup drive in Windows Explorer. Run `setup.cmd`. In
the administrator prompt, give your approval as the signed-in Windows user. Setup does
not accept an approval from a different account.

The setup drive must stay read-only. Do not attach setup media that Windows can write
to. Do not replace the files on the setup drive with files that Windows wrote.

At the end of the installation in Windows, setup shuts down Windows. Wait for the end
of this shutdown. If you click **Shut down** in the panel, the result is not the same.

**Caution:** During the setup boot, a shutdown from the panel stops setup, and then
you must select how to continue. Thus, click **Shut down** only in these conditions:

- The `setup.cmd` window does not change and does not accept input.
- The shared-folder check of `setup.cmd` tells you to click **Shut down**.

The `setup.cmd` script makes sure that the shared folder from Linux is a drive in
Windows, and that Windows can read it. It stops in these conditions:

- Windows does not show the folder.
- Windows cannot read the folder.
- The check cannot run.

If the check could not run and a security tool stops scripts, let Windows PowerShell
run `lanai-share-check.ps1` from the setup drive.

Then, in all of these conditions, do one of these steps:

- If this is the first time that `setup.cmd` stopped at this check, click **Restart**
  in the Start menu. Then run `setup.cmd` again.
- If `setup.cmd` also stopped at this check before this time, do not start Windows
  again. From the Lanai panel, shut down Windows. Then click **Set up in a basic
  window** or **Set up in the Windows window**. Lanai then does a check of the folder
  on Linux.

While a setup operation is in progress, the panel continues setup after Windows shuts
down. If no setup operation is in progress, the panel does not continue setup. In this
condition, wait for the end of `setup.cmd`. Then click **Continue setup**. If Windows
stops during the **Verify** checks, click **Continue setup** to start Windows again.

**Verify** shows the rows Display driver, Windows agents and Scale task. Each row
shows Not checked, Waiting, Done or Failed. Only the checks that ran set this value.
Windows agents shows Done only if all these checks are satisfactory:

- The SPICE agent check
- The guest-agent clock check
- The allow-list check.

Done gives only the result of those checks at that time. It does not tell you that the
parts continue to operate correctly. The check for the scale row makes sure only that
the task opened its port. It does not make sure that Windows applied the scale, or that
you can see the desktop.

The scale task starts when the Windows user who ran setup signs in. Lanai cannot see
the sign-in screen, and it cannot identify the signed-in user. If Windows tells you to
type a password, sign in as the Windows user who ran setup.

While setup waits for the scale task, the panel shows a countdown of the remaining
time for the sign-in. The countdown uses the time limit that the backend records. The
default limit is 2 minutes. If `LANAI_SETUP_SCALE_LIMIT` changes the limit, the setup
worker records this value. The panel uses this recorded value, also when the
environment variable of the panel has a different value.

The countdown does not start again when you open the panel again, or when the shell or
Windows starts again. If the time data is missing or not correct, the panel shows no
countdown.

If you continue setup after it stops, Lanai does the checks again. If they are
satisfactory, Lanai waits for the scale task again, with a new countdown. If a part
does not give a result in the time limit, setup stops, and the panel identifies the
part. To do the checks again, click **Continue setup**.

To install Lanai's parts in Windows again, shut down Windows. Then click **Set up in a
basic window** or **Set up in the Windows window**. If `setup.cmd` stopped and showed
a message in Windows, do the same steps to install Lanai's parts again.

The panel can tell you that an update of the display driver in Windows is necessary.
It can also tell you that the QEMU guest agent in Windows does not have its
allow-list. In these conditions, shut down Windows. Then click **Continue setup** to
prepare Windows again.

If a setup boot stopped before its end, the panel shows **Set up in a basic window**
and **Set up in the Windows window**. Until the display driver is in Windows, use the
basic window. After the installation of this driver, use the Windows window.

Only in these conditions, the panel does not show **Start Windows** and **Open
window**:

- Before the end of the first setup for this location
- During a setup boot or a boot for the **Verify** checks.

For these boots, Lanai starts Windows and opens its window automatically. After the
first setup, the panel keeps these controls when setup must continue. It also keeps them
when an update of the Looking Glass client or the display driver waits. Setup shows the
step that waits, adjacent to these controls. If the panel does not show the usual
controls and the Windows window closes, click **Reopen the Windows window** in the Setup
section. At the end of setup, the panel shows the usual controls again.

While Windows operates during setup, the panel does not show **Snapshots**. When Windows
is off, the panel shows it again. The Settings section stays available.

When you must do something, the setup card uses the accent color of your theme. While
Lanai does work automatically, the card does not use this color. The inset of the card
stays the same.

During the setup boot, **Shut down** tells you to click it again to give your
approval. It also shows this message:
“Shutting down now stops setup. You'll choose how to continue.”

If a shutdown for this boot is in progress, or you started one previously, it is not
necessary to click again. When you click **Shut down** or **Force stop** for
the first time, the panel cancels the approval that the other control waits for.

Setup continues its checks when the panel is not open, and when the shell starts again.
When you open the panel again, it shows the step in progress and the operations that
run. The panel tells you about the end of setup only after Lanai records it for this
disk.

If an operation stops with an error or before its end, the panel tells you to continue
or to try again. Before you continue, do these steps:

- If Windows operates without the setup drive, shut down Windows.
- During the **Verify** checks, wait for the end of a shutdown.

To continue, click **Continue setup**. After the shell starts again, this button first
finds the step that setup is at.

To run setup again after its end, shut down Windows. Then open **More actions**. Click
**Run setup again**. Select how Windows shows during setup. If you do not want to run
setup again, click **Cancel**.

When a restore is satisfactory, the panel shows a message. The message stays until you
make, restore or delete a snapshot again. The Setup section tells you if setup must
continue.

## Daily use

To open or close the panel, left-click the glyph. You can do this in all conditions.
When the glyph has the focus, Enter, keypad Enter, Space and the Menu key also open
or close the panel.

When you right-click the glyph, Lanai does one of these steps:

- If Windows is off after the end of setup, and no operation or unfinished restore
  prevents the start, Lanai starts Windows.
- If Windows operates after the end of setup and the Windows window is not open, Lanai
  opens the Windows window.
- In all other conditions, Lanai opens the panel.

If an update of the display driver waits, the panel opens when you right-click the
glyph. After the first setup, **Start Windows** stays available in the panel.

When you close the Windows window, Windows continues to operate. To open the
window again, right-click the glyph.

The tooltip of the glyph gives the condition of Lanai. It also tells you the step that
Lanai does when you right-click the glyph. The panel can have more information, for
example a problem or a notice about a forced stop. In this condition, the tooltip tells
you to open the panel.

The panel keeps the **Start Windows**, **Open window** and **Shut down** controls. On
the controls of the panel, you can use Tab, Shift+Tab, Enter and Space. To close the
panel, press Escape.

If Windows does not start or its window does not open, the glyph opens the panel. The
panel tells you the cause. The glyph also opens the panel when a start tells you that
Windows had a forced stop the previous time that it operated.

The usual header shows the saved values of memory, cores and scale. Drafts do not
change this line. The line does not show the memory and cores that the VM uses at
this time.

The **Settings**, **Snapshots** and **Logs** rows have lines between them. Each row
opens its section, and only one section is open at a time.

When the backend lets you use them, **More actions** has these items:

- **Run setup again**
- The updates
- **Dismiss notice**, which removes a notice
- **Force stop**.

In the Failed condition, the panel opens Logs with the cause and the steps that can
repair the problem. In this condition too, you must wait before you can use
**Force stop**.

### Settings

In Settings, the memory and the cores are integers in these ranges:

- From 1 to 512 GiB of memory
- From 1 to 64 cores.

Lanai uses changes to memory and cores when Windows starts the next time. The Windows
scale has one of these values:

- “Match my monitor”, which is the default
- A percentage that you select: 100 to 250 in steps of 25, then 300 to 500 in steps
  of 50.

**Save** saves the scale only if you selected an item in the scale list after you opened
the panel. If you clicked **Reset** after that, the selection must also be after
**Reset**. **Save** also saves the scale when you select the item that the list shows at
that time. If you did not select an item, **Save** saves only the memory and the cores.

**Unsaved** shows that you changed a draft, or selected a scale, since Lanai saved
your settings. The drafts stay in these conditions:

- The panel reads its data again.
- You open a different section.
- Lanai cannot save the settings.

If the backend rejects the settings, Settings shows an error message. The message stays
in Settings.

**Reset** sets the fields of the panel to the saved values.
After **Reset**, **Save** does not save the scale until you select a scale again.
**Reset** does not save, and it does not set the defaults.

When the panel has no changes, it shows a disabled **Saved** button. It does not
show **Reset** or **Unsaved**.

When you type a different memory or CPU value, **Save** becomes available
immediately. When you click **Save**, Lanai saves the text that you typed. It is not
necessary to press Enter first.

After Lanai saves the scale, **Save** and **Reset** stay available, and the panel
does not show **Unsaved**. If you click **Save** again, Lanai saves the scale again,
also when the scale did not change. After you click **Reset** or open the panel
again, **Save** does not save the scale. When you open the panel again, it also
discards the changes to settings that you did not save.

To do the same from a terminal, run
`~/.config/omarchy/plugins/io.github.jzetterman.lanai/bin/lanai settings <GiB> <cores> [auto|percentage]`.
With three arguments, the command always saves the scale. With two arguments, it
keeps the saved scale.

### Logs

When these logs are available, Logs has a row for each of them: VM, Window, Build,
Jobs and Actions. Each row has a button that copies text:

- The VM button copies the command that shows the user journal.
- The other buttons copy the full path of their log file.

The rows show shorter names, but Lanai copies the full text. The buttons do not run
a log command. When Lanai copies the text, the button shows **Copied**. If Lanai
cannot copy the text, the row shows the error, and the button stays available. Then
you can try again.

Lanai's state directory, `~/.local/state/lanai`, contains these logs:

- The Actions log, `panel-run.log`
- The Jobs log, `panel-job.log`
- The build log of the Looking Glass client, `build-client.log`.

The folder `$XDG_RUNTIME_DIR/lanai` contains the log of the Looking Glass client,
`client.log`. Your user journal contains Lanai's VM log, with the name `lanai-vm`. The
command `journalctl --user -u lanai-vm` shows this log.

### The bar glyph

The glyph shows the condition of Windows and of Lanai:

- When Windows is off, the glyph uses the usual foreground color.
- When Windows starts, operates or stops, the glyph uses the accent color and has an
  underline.
- While work is in progress, the underline shows the measured percentage of the
  work. If Lanai cannot measure it, a segment moves across the underline. The width
  of the segment does not change.
- A badge shows that you must do something, or that a failure occurred.

If more than one condition occurs, the glyph shows the most important one. This is
the sequence, from the most important:

- A failure
- A condition where you must do something
- Work in progress
- Windows starts, operates or stops
- Windows is off.

In the **Drivers** step, Lanai waits for `setup.cmd` while Windows operates. This is
usual, and the glyph shows that Windows operates. But if a failure occurs, or if you
must do a step to repair a problem, the glyph shows it first.

### Shut down and Force stop

**Shut down** is also available while Windows starts and while it shuts down. When you
click it, Lanai tells Windows to do a clean shutdown. The panel does not wait for the
end of the shutdown. If Windows ignores the shutdown while it starts, click
**Shut down** again.

15 seconds after Lanai first tells Windows to shut down, the panel shows
**Force stop**.

**Caution:** If you click **Force stop**, Windows does not keep the work that you did
not save.

To do a forced stop, click **Force stop**. Then click it a second time to give your
approval.

If the display does not operate or the builds do not agree, read the cause in the
panel. The panel also gives the next step and the names of the logs.

As an alternative to Lanai, you can use `omarchy-windows-vm` through RDP or through
its web console. Before you use it, stop Lanai's VM.

### Keyboard, capture and the pointer

In capture mode, Windows gets the mouse and the keyboard, and Omarchy's shortcuts go
to Windows. To start capture mode, press Scroll Lock. To stop capture mode, press
Scroll Lock again. On many laptops, to get Scroll Lock, press Fn and a different key.
Looking Glass shows Capture Enabled or Capture Disabled.

When you press Scroll Lock with a different key, Looking Glass runs one of its
commands. For example, Scroll Lock+F is the command for fullscreen. To see a list of
these commands, press and hold Scroll Lock.

When you are not in capture mode, Omarchy's Super shortcuts do not go to Windows. In
Windows, use the menus that Windows shows on its screen. When you are not in capture
mode, Ctrl+Alt+Del is Omarchy's shortcut that closes all windows. This includes the
Windows window, but Windows continues to operate.

The shared folder is `~/Windows` on Linux. In Windows Explorer, it is the virtiofs
drive.

When the mouse is on the Windows window, Looking Glass does not show your Linux
pointer. It shows only the Windows cursor. Lanai does not let the Looking Glass client
move your Linux pointer. Thus, when you drag the edge of the window, the edge follows
the mouse. But this decision also causes two problems:

- When you are not in capture mode, the window can change its dimensions without the
  mouse, for example when you resize it from the keyboard. Thus, the Windows cursor can
  be in a different position from the Linux pointer. When you click, Windows uses the
  position of the Linux pointer.
- In capture mode, the Linux pointer stays at the point in the window where capture
  started. When capture stops, the Windows cursor moves to that point again. A change
  of the window dimensions during capture also moves the cursor there. Scroll Lock+F,
  or a change of monitor or scale, can cause this change.

When you are not in capture mode and the window changed its dimensions, move the
mouse before you click.

### Resolution

The resolution of Windows follows the Windows window. In 5 seconds or less, Windows
changes its resolution to agree with the window in these conditions:

- The window opens.
- The window changes its dimensions.
- Hyprland tiles the window.
- The window changes to fullscreen mode.
- The window moves to a monitor with a different scale.

Windows also does this after the display driver starts again.

Before you sign in, Windows cannot change the dimensions of its desktop. Thus, when
Windows starts or starts again, it agrees with the window 15 seconds or less after
your sign-in.

When the Windows user who ran setup signs in, Lanai's scale task sets the dimensions.
The sign-in log of the scale task is `C:\Program Files\Lanai\lanai-signin.log`. If you
sign in as a different Windows user, possibly you must resize the window one time.

To change the resolution of Windows, resize the window. If you select a resolution in
Display settings in Windows, it does not stay. Lanai sets the dimensions of the window
again.

In two conditions, Windows does not agree with the window:

- Lanai does not set a width of less than 640 or a height of less than 480. These are
  the smallest dimensions that the display driver accepts.
- Windows rejects dimensions that are too large for the display memory that Lanai
  gives it. An example is fullscreen mode on a monitor with a very high resolution.
  Lanai tries a small number of times, and then it stops. While Lanai tries, the
  screen can have flicker, or Windows can show a notice.

In the two conditions, Windows keeps its previous dimensions. The Windows window makes
the image of the desktop larger or smaller. It shows all of the image in the window. To
repair this, resize the window or stop fullscreen mode.

### Updates

If setup ran with a previous version of Lanai, Windows continues to operate with Lanai.
But possibly Windows does not agree with the window. Also, after a sleep of the
computer, possibly the mouse can move only in a part of Windows.

If only the Looking Glass client must have an update, Lanai updates it automatically. It
is not necessary to click. Lanai does this update at one of these times:

- After `omarchy plugin update`
- After the shell starts again
- After you sign in.

After the first plugin update to this version, the update of the client starts only when
the shell starts again or when you sign in. The command `omarchy-restart-shell` starts
the shell again. Until this occurs, the panel shows **Update the Windows window** in
**More actions**.

The update continues for some minutes. It operates when Windows operates and when
Windows is off, and it does not change Windows. During the update, you can start and
use Windows. The update gets less CPU time than Windows.

A Windows window can open before the end of the update and stay open after it. In
this condition, the panel tells you to close the window and open it again. The
tooltip of the bar glyph refers you to the panel.

In these conditions, the panel tells you about the problems that can occur, and it
shows **Update the Windows window** in **More actions**:

- The update is not satisfactory.
- The update cannot start.
- The update stops two times before its end, for example at a logout.

When a log contains the cause, the panel also gives the name of that log. This log is
the build log of the Looking Glass client or the Jobs log.

If setup installed the scale task in Windows without the sign-in step, Windows can stay
at its previous dimensions after it starts. It stays at these dimensions until you
resize the window. In this condition, Lanai does not update the client automatically,
and the panel shows **Run setup again**.

**Run setup again** also updates the Looking Glass client. It disables the Windows lock
again, and it starts Windows again. Setup always does these steps. If setup cannot
update the client, the panel refers you to the same build log.

### Display scale

The display scale of Windows changes while Windows operates. It is not necessary to
start Windows again or to sign out.

“Match my monitor” uses the Windows step that is nearest to the scale of the monitor
that shows the Windows window. If two steps are equally near, Lanai uses the step
with the smaller value.

In 5 seconds or less, Windows changes its scale when the window moves to a monitor
with a different scale. Windows also does this when the scale of that monitor
changes. This also occurs while the panel is not open and while the shell starts
again.

Lanai uses the scale of one monitor. While the window is open, this is the monitor
that shows the window. In other conditions, Lanai uses this monitor:

- While the window is not open, the monitor that showed the window before it closed
- Before the window opens for the first time, the monitor that had the focus when
  Windows started.

If Lanai cannot find that monitor, it uses the monitor that has the focus. As a last
alternative, it uses the first monitor in the list from Hyprland. If there is no
monitor, the scale does not change. When Windows starts, this scale is 100%.

If you save a scale while Windows operates, Windows gets it in 5 seconds or less. But if
you did not sign in to Windows, Windows gets it 20 seconds or less after your next
sign-in. Lanai cannot know which of the two is correct. Thus, the panel tells you
about the two conditions. If you save a scale while Windows is off, Windows uses it
at the next start.

You can also select a scale in Windows, in Settings > System > Display > Scale. Your
selection in Windows stays until one of these occurs:

- You save a scale in Lanai.
- You sign out.
- Windows starts again.
- The VM stops.

The panel tells you that a scale that you save in Lanai replaces your selection in
Windows. While your selection stays, “Match my monitor” does not follow the window.
Your selection in Windows does not change the scale that you saved in Lanai.

When the resolution changes, Windows changes its recommended scale. Then the scale
task sets the scale to your selection in Windows again. If you did not select a scale
in Windows, the scale task sets the scale that you saved in Lanai.

The scale stays when the window changes its dimensions. But Windows has a maximum
scale for each resolution. If the scale is more than this maximum, Lanai uses the
maximum. When the window becomes larger, Lanai sets the higher scale again.

At a sign-in, the scale task starts more slowly. Thus, the scale changes after a sign-in
occur 20 seconds or less after it, not 5 seconds or less. These changes are:

- The scale after the end of your selection in Windows
- The scale for the dimensions that Lanai sets.

This scale is the display scale of Windows. It is different from “Text size” in
Windows.

Windows also has custom scaling, a percentage that Windows uses only after a sign-out.
While custom scaling is on, Windows uses it, and not the scale that Lanai sets. To stop
custom scaling:

1. In Settings > System > Display > Scale, set custom scaling to off.
2. Sign out.

Some Windows apps show a new scale only after they start again.

Windows can accept a change but not change the scale. In this condition, the scale task
tries again one time each minute. The log of the scale task is
`C:\Program Files\Lanai\lanai-scale.log`.

The scale task runs a small program that setup builds in Windows,
`C:\Program Files\Lanai\lanai-start.exe`. After setup, Windows can prevent the start
of this program, or remove it. For example:

- Your antivirus puts the program in quarantine.
- Smart App Control, an App Control policy or an AppLocker policy becomes active.

After this, the scale and the dimensions at sign-in do not obey Lanai. To repair
this, let the program run by its path, `C:\Program Files\Lanai\lanai-start.exe`. Do
this in your antivirus, or in the App Control or AppLocker policy.

If your antivirus or your policy lets the program run by its file hash, this permission
stops when setup runs again. Setup builds the program again each time that it runs.

Smart App Control cannot let only one program run. On many Windows versions, only a new
installation of Windows can enable Smart App Control again after you disable it. As an
alternative to the policy change, you can disable Smart App Control in Windows Security
> App & browser control.

Then click **Run setup again**. Setup makes sure that Windows runs the program. If
Windows does not run it, setup stops and shows these steps.

If setup ran with a version of Lanai that could not change the scale while Windows
operates, Windows keeps the previous scale task. With this task:

- Lanai uses a scale that you save when Windows starts the next time.
- The task does not keep the scale changes that you make in Windows.
- “Match my monitor” does not follow the window while Windows operates.

Adjacent to the repair for the dimensions, the panel tells you that Lanai uses a saved
scale only when Windows starts the next time. After you save a scale, the panel
gives the same three items of information.

To get scale changes while Windows operates, shut down Windows. Then click
**Run setup again**. Setup also disables the Windows lock again.

If you update Lanai while Windows operates, possibly the panel tells you that some of
Lanai's helpers stopped. They stay off until Windows starts the next time.

The [proof checklist](plugin/proofs.md) has checks for these items:

- A change of the window dimensions
- The limits of the scale
- A new connection of the display.

The [phase 8 checks](plugin/plan.md#phase-8-acceptance) are for a lock of the host,
sleep and the shutdown of a session. These checks have no result at this time.

## Windows lock and trust exposure

Setup disables the Windows lock for the Windows user who runs setup. This is
necessary because Windows ignores the clean shutdown from Lanai while it shows its
lock screen. Setup also disables Switch user and the machine inactivity limit for
**all accounts** on that Windows.

Setup replaces your previous lock settings, and it does not save them. To enable the
lock again, use the three registry commands in the Removal section. These commands
set the defaults of Windows, not your previous settings.

A domain policy or an MDM policy can enable the lock again. When the lock is on
again, because of a policy or because you enabled it, a forced stop can occur again.
A Windows security screen that stays open, for example UAC, can also cause a forced
stop.

Lanai does not change these facts:

- Dockur signs in to Windows automatically at each boot.
- RDP and the web console at `127.0.0.1:8006` tell you to type the Windows password,
  because of `PROTECT: "Y"`.
- All processes that run as your Linux user can read the saved password.

Lanai does not read or use the saved Windows password.

But after setup, Windows does not lock automatically, and it does not lock when you
try to lock it. If you do not lock your Linux session and you are not at the computer,
Windows stays unlocked while the VM operates.

To put the Windows window behind the Linux lock screen and prevent access to it, lock
Linux.

Setup in Windows adds the signing certificate of HostFission to Trusted Publishers on
the machine. Thus, Windows does not show a publisher prompt for the display driver.
After this, Windows accepts **all drivers that HostFission signs**, and it does not show
a prompt. When you remove Lanai, remove this certificate. The Removal section tells you
how.

While the Windows window is open, Windows can read **all data that you copy on Linux.
This includes files.** When you copy files in Windows, they show on Linux in a
read-only folder in your runtime directory.

This is an accepted exposure from the guest to the host. These are the other accepted
exposures:

- The frames and the cursor of Looking Glass
- The SPICE input, audio and clipboard
- The network backend
- The shared folder, `~/Windows`. Through this channel, Windows can open only this
  folder on Linux.
- The channel of the QEMU guest agent. Lanai uses it for the clock. At setup, Lanai
  also sends one command through it, and the allow-list of the agent must reject it.
- The scale channel.

The scale channel sends data in one direction only. Each message contains a scale
step and a save number. Lanai does not read the data that Windows writes to the
channel.

Windows lets only administrators open the scale channel. Thus, the scale task runs at
your sign-in with your administrator rights, and it does not show a prompt. These
items of the scale task are in `C:\Program Files\Lanai`:

- Its program
- The source of the program
- Its script
- Its logs
- Its temporary folder.

Only administrators can write to this folder. Setup builds the program in this folder
from the source of Lanai. It uses the C# compiler that Windows includes. Thus, Windows
gets no built program from Lanai.

But this type of task starts with the environment variables and the registry settings
of your Windows user. Thus, if malware runs as that user, it can use the task to get
administrator rights. If UAC is on, that malware has other methods to get these
rights.

## The network and the container

DNS in Windows uses the resolver of the host. This includes the search domains and
Tailscale MagicDNS. A DNS client in Windows, for example Cloudflare WARP or an agent
from your company, replaces the resolver of the host.

Windows can connect to the same network locations as the host. This includes VPNs.
But Windows cannot connect to a service of the host that is available only on the
loopback address. Windows can connect to services of the host on other addresses.

If the host has no default route when Windows boots, Windows starts with no network
access. Windows has no network access until the next start of the VM.

While Lanai operates Windows with QEMU and no container, the four Windows plugins that
use the container show **stopped**. Lanai uses a different name, glyph and VM name:
Lanai, the L-in-a-monitor glyph and `Lanai,process=lanai`.

**Caution:** While Lanai operates Windows, do not start `omarchy-windows-vm`. A
subsequent dockur version can write to paths that Lanai does not examine. The proofs
show that dockur **6.05** does not start while Lanai operates Windows, and this is safe.

At each start, Lanai examines the known paths where dockur writes before the boot.
While you use Lanai, do not change the Windows version, language, disk size or format
of the container. Also do not change `CLEAR` or the ISO mounts that you added.

If Lanai cannot read the settings of the container, it compares `windows.base` with
the usual Windows 11/no-language image. It also does not do the check of the disk
size. In this condition, the container can make the disk larger. This adds space, but
it does not replace Windows data. Lanai rejects installation layouts that are unknown.

Lanai has proofs for dockur **6.05**. `lib/dockur-6.05.args` and the
[proofs](plugin/proofs.md) record this version. We did not record the accurate
Omarchy build that we used for these proof sessions. **Phase 8 must record it before the
release.**

Phase 7 is for the installed shell API of Omarchy **4.0.0.alpha**. This version tells
you only which API Lanai uses. It does not tell you that Windows operates correctly
with Lanai on that version.

When you reboot or shut down the computer, Lanai tries to do a clean shutdown of
Windows. Omarchy gives it approximately 20 seconds, and Lanai cannot make sure of the
result. At a logout, the limit is a maximum of two minutes. If Windows does not complete
the shutdown in the time limit, the next start tells you about the forced stop.

**Phase 8 must measure the time of a clean Windows shutdown with Lanai on John's
computer, when it reboots. This measurement has no result at this time.**

In the previous sessions of proof 4, Windows had no work to do. Its shutdown continued
for 7 seconds when the computer rebooted, and for 11 to 13 seconds at a logout. These
times do not replace the phase 8 measurement.

## Removal

1. If a setup, snapshot, restore or update of the Looking Glass client is in progress,
   wait until its end. These operations continue when the panel is not open. To stop
   setup before its end, click **Shut down** in the panel. Then click it again to give
   your approval.

   **Caution:** If the command that follows continues until its timeout, it can do a
   forced stop. In this condition, Windows does not keep the work that you did not save.

   Then stop Lanai's VM with this Linux command. You can also use this command without
   the plugin. It waits for the shutdown.

   ```sh
   systemctl --user stop lanai-vm.service
   ```

2. When Lanai's VM stops, start Windows with `omarchy-windows-vm launch`. Then connect
   to Windows through RDP.

   **Do all the Windows removal steps that follow in that RDP session.** When you
   uninstall the display driver or the SPICE vdagent, this can remove the display or
   the input of Lanai. Also, a usual Lanai boot has no QEMU display.

   Open an administrator Command Prompt as **the Windows user who ran setup**. Two of
   these commands change `HKCU`, which is different for each account. Set the lock
   settings of Windows to the defaults:

   ```bat
   reg delete HKCU\Software\Microsoft\Windows\CurrentVersion\Policies\System /v DisableLockWorkstation /f
   reg delete HKLM\SOFTWARE\Microsoft\Windows\CurrentVersion\Policies\System /v HideFastUserSwitching /f
   reg delete "HKCU\Control Panel\Desktop" /v ScreenSaverIsSecure /f
   ```

   If a value is not in the registry, it is not necessary to delete it.
   `InactivityTimeoutSecs` is not in the registry by default. Thus, the removal does
   not write a value for it.

   You can also use these commands to enable the lock again and keep Lanai installed.
   To apply the settings that Windows reads at sign-in, start Windows again.

3. Before you remove the plugin, remove the other changes in Windows.

   If no other workflow uses the display driver and the QEMU guest agent, uninstall them
   in Installed apps. The display driver is Looking Glass IDD. When you uninstall the
   QEMU guest agent, you also remove Lanai's clock-only service configuration,
   `--allow-rpcs=guest-sync,guest-sync-delimited,guest-set-time`. Setup did not save
   the previous service configuration.

   If the container or a different SPICE connection uses the SPICE vdagent, the
   vdagent can stay. If the container and other SPICE connections do not use the
   vdagent, uninstall it there too.

   **Caution:** If a different workflow used a `VirtioFsSvc` that was there before
   setup, the commands that follow also remove it. Setup did not save its previous
   settings.

   From the administrator Command Prompt, remove Lanai's scale task and virtiofs service:

   ```bat
   schtasks /End /TN "Lanai display scale"
   schtasks /Delete /TN "Lanai display scale" /F
   sc.exe stop VirtioFsSvc
   sc.exe delete VirtioFsSvc
   rmdir /S /Q "C:\Program Files\Lanai"
   ```

   When you stop the task, its program also stops. When the program stops, the script
   stops. Thus, `rmdir` can remove them. If the task or the service does not operate,
   it is not necessary to stop it.

   These commands remove these items:

   - Lanai's `virtiofs.exe`
   - The scale task's `lanai-start.exe`, `lanai-start.cs` and all
     `lanai-start.old-*.exe` files
   - `lanai-scale.ps1`
   - The logs `lanai-scale.log`, `lanai-signin.log` and `lanai-signin.log.old`
   - The temporary folder
   - The settings of the service for the automatic start, the dependency and the
     path of the program file.

   Possibly, setup ran with a version of Lanai that could not change the scale while
   Windows operates. In this condition, `%LOCALAPPDATA%\Lanai` also contains the scale
   log. Delete that folder too.

   If a different workflow used the previous service, do one or the two steps before you
   use that workflow:

   - Install its virtiofs tools again.
   - Configure these tools again.

   WinFsp and the newer `viofs` driver can stay. A publisher signed this driver.
   Without the service, they do not make Lanai's shared folder.

   If no virtiofs workflow uses WinFsp or this driver, do these steps:

   1. Uninstall WinFsp in Installed apps.
   2. **Caution:** Before you select the removal of the driver, make sure that no other
      device uses the driver. A different virtiofs workflow can use this driver.

      Uninstall the VirtIO FS device and its driver in Device Manager.

   The RDP connection of the container and its usual file share can operate without
   Lanai's virtiofs service and scale task.

4. Run `certlm.msc`. Open **Trusted Publishers → Certificates**. Remove the
   **HostFission** signing certificate that setup added. This removes the permission
   to install all drivers that HostFission signs with no publisher prompt.

   As an alternative, do these steps from the administrator Command Prompt:

   1. Run `certutil -store TrustedPublisher`.
   2. Find the certificate with a Subject that names HostFission.
   3. Delete the certificate by its `Cert Hash(sha1)` value:

      ```bat
      certutil -delstore TrustedPublisher <Cert Hash(sha1) value>
      ```

5. From its **Start menu**, shut down Windows. The lock is on again. Thus, Windows
   can ignore the shutdown from Lanai. The container does not start again
   automatically. `omarchy-windows-vm` uses `restart: "no"`.

6. On Linux, remove the plugin:

   ```sh
   omarchy plugin remove io.github.jzetterman.lanai
   ```

   If you only reload, disable or remove the plugin, its VM does not stop.

   The VM unit of the plugin stays after you remove the plugin. You can also remove
   this unit. Before you remove it, make sure that the VM does not operate and that no
   panel operation is in progress. To remove the unit and make the user manager read
   its units again, run these commands:

   ```sh
   rm -f "${XDG_CONFIG_HOME:-$HOME/.config}/systemd/user/lanai-vm.service"
   systemctl --user daemon-reload
   ```

   Lanai's XDG configuration, data and cache directories and its XDG state directory
   keep these items:

   - The settings
   - The downloaded builds
   - The runtime copies
   - The data that setup recorded.

   Keep the snapshots until you are sure that they are not necessary. To delete a
   snapshot, remove its folder. Its path is the path that Lanai showed when it made
   the snapshot.

   The disk and the firmware of Windows stay, and `omarchy-windows-vm` stays
   available. The host packages can stay for other apps. If you know that no other
   app uses a dependency, you can remove it.
