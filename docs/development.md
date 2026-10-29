# Lanai development

This doc is for people who work on Lanai: the background, the file layout and the
tests. To install and use Lanai, read the [README](../README.md) and the
[user guide](guide.md).

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
   See the [spec](spike/spec.md), [plan](spike/plan.md) and
   [results](spike/results.md). The measured sessions have not run yet.
2. **Lanai**, an Omarchy plugin for [plugins.omarchy.org](https://plugins.omarchy.org),
   is being built on the assumption that Looking Glass wins. See its
   [spec](plugin/spec.md) and [plan](plugin/plan.md).

Out of v1: GPU passthrough, and a dedicated partition or NVMe for Windows.

## Layout

Lanai is an Omarchy bar plugin (id `io.github.jzetterman.lanai`) that runs your
`omarchy-windows-vm` Windows install in plain QEMU, as your user, and shows it in a
Looking Glass window. The plugin sits at the repository root: `manifest.json`, `bin/`,
`lib/`, `systemd/`, `guest/`, `Widget.qml`, `LanaiPanel.qml`, `LanaiModel.qml`
and `test/`. [CLAUDE.md](../CLAUDE.md) describes each file.

## Rehearsals

Rehearse on a reflink copy, as the [acceptance plan](plugin/plan.md#phase-8-acceptance)
describes, never on your live `~/.windows`.
Before enabling the plugin for a rehearsal, set `storage` in
`${XDG_CONFIG_HOME:-$HOME/.config}/lanai/settings.json` to the copy's absolute path.

## Tests

Run `bats test spike/test`. Tests that need btrfs read `LANAI_TEST_BTRFS_DIR` (for
example `LANAI_TEST_BTRFS_DIR=$PWD/.btrfs-test`, which git ignores) and skip when it is
unset or not on btrfs; CI runs them on a loop-mounted btrfs image. No test boots Windows
or talks to your systemd user manager; QEMU runs only paused (TCG) on 1 MiB scratch
disks for the lock tests. No test downloads or builds the Looking Glass client, runs
sudo, or opens a window: curl, cmake, pacman, sudo, omarchy, systemd-run and hyprctl
are stand-ins. One exception: when `LANAI_TEST_LG_TARBALL` names a local copy of the
pinned source tarball, `test/client-patches.bats` applies Lanai's patches to it,
builds the client, and builds and runs the client's own tests. The guest C# and
PowerShell tests in `test/guest.bats` need `pwsh`. CI does not install it, so CI
skips them: run them locally before a merge. Two QML tests in `test/panel-qml.bats`
load the installed shell's controls from `/usr/share/omarchy/shell`, which CI does not
have, so CI skips them too. Lint with
`shellcheck -x bin/* lib/*.sh spike/lgtest test/*.bats test/helpers.bash spike/test/*.bats
docs/plugin/proof-kit/proof-vm docs/plugin/proof-kit/proof-unit-start
docs/plugin/proof-kit/proof-unit-stop docs/plugin/proof-kit/clock-ping
docs/plugin/proof-kit/size-window-on-open docs/plugin/proof-kit/stamp-client-log
test/fixtures/fake-qmp test/fixtures/fake-qga test/qml-lint`.

Run `test/qml-lint`.

Panel fixtures in `test/panel.bats`,
`test/panel-jobs.bats` and `test/ui.bats` use a fake CLI and host facts without
sockets or a VM. `test/panel-qml.bats` runs the real renderer in Qt 6 with inert
shell and Process types when Qt 6’s test runner is available. It never starts the
Omarchy shell. Its ten-board integration generates real backend replies with
`test/panel-fixtures.bash`, shared with the backend panel tests. It covers
recovery, partial checks, invalid timing, read failures and the bar matrix too.
The [redesign acceptance notes](plugin/redesign/plan.md#acceptance-notes)
record automated results and pending theme and VM checks. `lanai panel` supplies
the complete view, including settings,
snapshot names and plain-language results; the QML polls every two seconds only
while its own panel is open, and every fifteen seconds otherwise.
With Windows running or stopped, the daily view shows no status lines or
disabled-action hints: the status badge and the Open window or Start Windows
button carry the routine status, and Open window's extra guidance is in its
tooltip. A running restore is quiet too: its target, progress and warning say
what runs. Successful
snapshot details and a path copy button are available in Snapshots through **Show details**, while failures
remain visible above the controls. Direct actions are recorded by `lanai ui-run`; setup, snapshots,
restores and updates run in session units through `lanai ui-job`, with
diagnostics in Lanai’s state directory as
`panel-run.log` and `panel-job.log`. The panel labels these as the Actions log
and the Jobs log. Rapid repeated clicks keep the first
launch pending. Other controls preserve a failed launch notice until the next
setup, snapshot, restore or update starts. The Windows window log has its own
path, and so does the Windows window build log, `build-client.log` in Lanai’s
state directory; the Windows VM log is in your user journal, under lanai-vm.
