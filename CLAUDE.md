# Lanai

Windows in a window on Omarchy: plain QEMU plus Looking Glass IDD. The spike is done
except its measured sessions; the Lanai plugin is being built (docs/plugin/).

## Layout

- `docs/` holds specs and plans, with review logs in each doc.
- `spike/` holds the software-mode test harness. `spike/work/` is gitignored scratch.
- The Lanai plugin sits at the root: `manifest.json`, `bin/` (the `lanai` CLI,
  `lanai-copy`, the VM unit's `lanai-vm-exec`, `lanai-vm-stop` and
  `lanai-vm-helper`, the client unit's `lanai-client-exec`, and `lanai-setup-host`,
  which installs the host packages in a terminal), `Widget.qml` (the bar glyph),
  `LanaiPanel.qml` (setup cards, VM controls, detail sections, drafts and
  confirmations), `LanaiModel.qml` (panel polling, literal command transport and
  clipboard exit feedback), `lib/` (`panel.sh` holds the
  read-only panel view and words, `client.sh` holds the
  Looking Glass client code, `setup.sh` the setup flow, setup media and
  `$RUN/step6-checks.json` check outcomes and `$RUN/step6-scale-limit` worker
  timeout for each attempt, `pins.sh`
  the pinned downloads, `ui.sh` the settings command, per-group result records,
  session-unit panel jobs and Lanai's own client update (its try record,
  `client-auto.json`, and the `$RUN/client-auto-gave-up` marker), `snapshot.sh`
  snapshot and restore,
  `snapshot-label.py` the snapshot label validator and reader, `copy.sh` the
  reflink copy helpers, `ficlone.py` the in-place clone, `image-proof.py` the
  one-read image hash, FIEMAP proof and progress record),
  `systemd/` (the VM unit template), `guest/` (what runs in
  Windows: `setup.cmd`, `lanai-lock.cmd`, `lanai-scale.ps1`, `lanai-share-check.ps1`,
  setup's check that the shared folder appears as a drive, and `lanai-start.cs`,
  the scale task's start program, which setup builds in Windows), `patches/looking-glass/`
  (Lanai's Looking Glass client patches, `NNNN-<topic>.patch`, with the GPL-2.0 text
  in `COPYING`) and `test/` (bats; fake
  QMP and guest agent servers and trimmed client logs in `test/fixtures/`;
  `test/client-patches.bats` builds and runs the patches' C tests;
  `test/client-auto.bats` tests Lanai's own client update;
  `test/panel-fixtures.bash` shares isolated backend fixtures between the panel
  tests and the ten-board renderer integration in `test/panel-qml.bats`).
  `docs/plugin/proof-kit/` holds the phase 1, live-scale and resize proof scripts and
  `count-image-extents.py`, the read-only extent census.
- QML lint: `test/qml-lint` (or `test/qml-lint <file>`). It makes a temporary
  repository-local import root with `qs` linked to `/usr/share/omarchy/shell`,
  then runs `/usr/lib/qt6/bin/qmllint -I /usr/share/omarchy/shell -I "$imports" "$@"`.
  This resolves `qs.Commons` and `qs.Ui` against the installed shell's actual
  types. The script removes its import root on exit and never starts the shell.
  `/usr/bin/qmllint` is the older Qt 5 linter and rejects Qt 6 syntax.
- Tests: `bats test spike/test`; btrfs tests read `LANAI_TEST_BTRFS_DIR` (the ignored
  `.btrfs-test/` works). Keep `TMPDIR` short (for example a folder under
  `$XDG_RUNTIME_DIR`): socket paths over 108 characters make the fake QMP and guest
  agent tests fail. CI runs the same in an Arch container
  (`.github/workflows/test.yml`). `test/client-patches.bats` also applies every patch
  to the pinned source, builds the client and runs its tests when
  `LANAI_TEST_LG_TARBALL` names the pinned source tarball (local only; CI skips it).
  The guest C# and PowerShell tests in `test/guest.bats` need `pwsh`, which CI does
  not install, so CI skips them: run them locally before a merge. CI also skips the
  two QML tests in `test/panel-qml.bats` that load the installed shell's controls
  from `/usr/share/omarchy/shell`.

## Rules

- QML for the plugin UI. Bash for scripts: `set -euo pipefail`, clean under `shellcheck`.
- Nothing escalates (no sudo, pkexec or run0). One exception: Lanai's setup
  may install packages with `sudo pacman`, only inside a terminal the user opened from
  the panel, after printing the exact command. Everything else that needs root prints
  the command for the user to run.
- The VM runs as the user. Keep sockets and state under `$XDG_RUNTIME_DIR` or the
  plugin's own state directory, never world-writable paths.
- Pin every file we fetch ourselves by exact build and SHA-256 (system packages come from
  the signed Arch repos). The Looking Glass client and IDD must come from the same build.
- Lanai changes the Looking Glass client only through the patches in
  `patches/looking-glass/`, applied exactly to the pinned source (no offset or fuzz);
  the IDD stays the pinned build. A pin change needs patches that apply exactly to
  the new source, and a recheck that the new IDD still stores the ask where and as
  `guest/lanai-start.cs` reads it (`ExtraMode` in `HKLM\SOFTWARE\LookingGlass\IDD`,
  `<w>x<h>@<refresh>[*]`; spec 12, the sign-in bullet).
- The spike (`spike/`) never writes to the live `omarchy-windows-vm` disk; it works on a
  reflink copy. Lanai boots the live disk only after its adoption checks pass
  (docs/plugin/spec.md, requirements 1-5).
- Agents and automated tests never boot, modify or experiment on John's live
  `~/.windows`. Use a reflink copy or a test install on a separate machine or VM. Only
  John runs checks on the live install, by hand, after the rehearsal on a copy passes
  (docs/plugin/spec.md, Acceptance criteria).

## Docs to update before merge

`README.md`, the governing doc in `docs/`, and `CLAUDE.md` when layout or rules change.
