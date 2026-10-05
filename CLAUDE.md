# Lanai

Windows in a window on Omarchy: plain QEMU plus Looking Glass IDD. The spike is done
except its measured sessions; the Lanai plugin is being built (docs/plugin/).

## Layout

- `docs/` holds specs and plans, with review logs in each doc.
- `spike/` holds the software-mode test harness. `spike/work/` is gitignored scratch.
- The Lanai plugin sits at the root: `manifest.json`, `bin/` (the `lanai` CLI,
  `lanai-copy`, the VM unit's `lanai-vm-exec`, `lanai-vm-stop` and
  `lanai-vm-helper`, the client unit's `lanai-client-exec`, and `lanai-setup-host`,
  which installs the host packages in a terminal), `lib/` (`client.sh` holds the
  Looking Glass client code, `setup.sh` the setup flow and setup media, `pins.sh`
  the pinned downloads), `systemd/` (the VM unit template), `guest/` (what runs in
  Windows: `setup.cmd`, `lanai-lock.cmd`, `lanai-scale.ps1`) and `test/` (bats; fake
  QMP and guest agent servers and trimmed client logs in `test/fixtures/`).
  `docs/plugin/proof-kit/` holds the phase 1 proof scripts.
- Tests: `bats test spike/test`; btrfs tests read `LANAI_TEST_BTRFS_DIR` (the ignored
  `.btrfs-test/` works). CI runs the same in an Arch container
  (`.github/workflows/test.yml`).

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
- The spike (`spike/`) never writes to the live `omarchy-windows-vm` disk; it works on a
  reflink copy. Lanai boots the live disk only after its adoption checks pass
  (docs/plugin/spec.md, requirements 1-5).
- Agents and automated tests never boot, modify or experiment on John's live
  `~/.windows`. Use a reflink copy or a test install on a separate machine or VM. Only
  John runs checks on the live install, by hand, after the rehearsal on a copy passes
  (docs/plugin/spec.md, Acceptance criteria).

## Docs to update before merge

`README.md`, the governing doc in `docs/`, and `CLAUDE.md` when layout or rules change.
