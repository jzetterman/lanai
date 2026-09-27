# windows-on-omarchy

Windows in a window on Omarchy: plain QEMU plus Looking Glass IDD. Currently a spike;
the goal is an Omarchy plugin.

## Layout

- `docs/` holds specs and plans, with review logs in each doc.
- `spike/` holds the software-mode test harness. `spike/work/` is gitignored scratch.

## Rules

- Bash, `set -euo pipefail`, clean under `shellcheck`.
- Scripts never escalate (no sudo, pkexec or run0). If root is needed, print the
  command for the user to run.
- The VM runs as the user. Keep sockets and state under `$XDG_RUNTIME_DIR` or
  `spike/work/`, never world-writable paths.
- Pin every upstream artifact by exact build and SHA-256. The Looking Glass client
  and IDD must come from the same build.
- Never write to the live `omarchy-windows-vm` disk. Work on a reflink copy.

## Docs to update before merge

`README.md`, the governing doc in `docs/`, and `CLAUDE.md` when layout or rules change.
