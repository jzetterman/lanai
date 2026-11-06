# Keep the last client logs

Small tier: one combined spec and plan for the follow-on "Keep the last client log"
(`docs/plugin/plan.md`, "Follow-ons after v0.1.0").

## Problem

`$RUN/client.log` holds the Looking Glass client's output (`$RUN` is
`$XDG_RUNTIME_DIR/lanai`). Lanai clears it at three points:

- `client_exec` (`lib/client.sh`) writes a fresh start line with `>` each time the
  window opens.
- `client_exec`'s timeout path writes its message with `>`.
- `vm_exec` (`lib/vm.sh`) empties it with `: >` at each VM start.

On 2026-11-06 (EST), after a night idle, Windows sent no frames and the client sat
at its splash screen. The window was reopened, then Windows was restarted. The
reopen wiped the frozen session's log, so nothing was left to diagnose. Keeping one
old log would not have been enough: the reopen moved the frozen log aside, and the
restart pushed it out. John's call (2026-11-06): keep three.

## Requirements

1. Before any of the three points above clears or overwrites `client.log`, Lanai
   keeps the current log as `client.log.1`. The older ones shift down:
   `.1` becomes `.2`, `.2` becomes `.3`, and the old `.3` is dropped. Lanai keeps
   at most three old logs.
2. Lanai keeps a log only when `client.log` is a regular file (not a symlink) and is
   not empty. An empty or missing log shifts nothing, so a VM start just after a
   window open does not push a useful log out with an empty one. A log whose first
   line is the timeout message (`$LANAI_CLIENT_TIMEOUT` ...) also shifts nothing:
   it holds only that line, which the journal already has (John's call,
   2026-11-06).
3. At VM start, a client that is still running keeps writing into the fresh
   `client.log`, as it does today (the client appends; the comment in
   `client_exec` says why). So the keep only copies the log; the caller's existing
   write then empties or overwrites it. The keep never renames `client.log` itself. Lines the client writes between
   the copy and the reset are lost; the window is a few milliseconds.
4. A kept log holds at most the last 16 MiB of `client.log`, so the three kept logs
   take at most 48 MiB of `$RUN`, which is RAM. A client with `mouseTrace=yes`
   wrote 77 MB in 3.3 h on John's desktop (2026-11-06), and `$RUN` also holds the
   VM's 128 MiB `ivshmem`. The end of a log is the part worth keeping: it shows
   what the client saw last. A kept log keeps its last-write time, so `ls -l`
   shows when its client went quiet.
5. Keeping logs is best effort. If a shift or the copy fails, the failing tool's own
   error and then one `lanai: ...` line go to stderr (the journal); Lanai stops the
   keep and still writes
   `client.log` as it does today. A failure never stops the window from opening or
   the VM from starting.
6. The keep step never writes through a symlink and never moves a file into a
   directory a link points to. A shift renames links as links, and the copy never
   follows a link at `client.log.1`. The writes to `client.log` itself stay what
   they are today (same file, same content): `$RUN` is the private folder
   `run_dir_check` guards.
7. Nothing that reads `client.log` changes (`lanai status`, setup's step 6, the
   panel's log path). They read only the current log.

No lock (John's call, 2026-11-06). The only overlap is a window open that times out
while the VM starts: two window opens cannot overlap (`lanai-client.service` is one
unit), nor can two VM starts, and a normal open keeps only after QEMU answers, which
is after the VM start's keep. If that overlap hits the keep, one old log can be
kept twice (pushing another out), kept out of order, or kept empty, and a spurious
`lanai:` line can reach the journal. Nothing else breaks.

## Acceptance criteria

- Starting with a non-empty `client.log` (L0) and no old logs, three window opens
  leave `client.log.1` to `.3` holding the logs of opens 2 and 1 and then L0
  (newest first), and `client.log` holding open 3's log.
- A fourth open drops L0.
- A VM start with a non-empty log keeps it as `.1` and leaves `client.log` empty.
- A VM start or window open with an empty or missing log, or a log whose first line
  is the timeout message, leaves `.1` to `.3` as they were.
- A client that writes after a VM start's keep lands its new lines in `client.log`,
  not in `client.log.1`.
- The timeout path keeps the old log before writing its message.
- A kept log has the same modification time as the `client.log` it came from.
- A `client.log` over 16 MiB is kept as its last 16 MiB; a smaller one is kept
  whole.
- A failed keep prints a `lanai:` line, and the window still opens and the VM still
  starts. The test trigger: a regular file at `client.log.2` and a directory at
  `client.log.3`, so `mv -fT` exits 1.
- A symlink at `client.log` is not copied, a symlink at `client.log.1` is not
  written through, and a link at `client.log.2` or `.3` that points to a directory
  is replaced, with nothing moved into that directory.
- `shellcheck` is clean and the existing `client_exec` and `vm_exec` tests still pass.

## Constraints

- Bash, `set -euo pipefail`, clean under `shellcheck` (CLAUDE.md rules).
- The logs stay in `$RUN`, the private runtime folder. It is tmpfs, so they are gone
  when the user logs out (without linger) or the host restarts. That is fine: the
  logs help with problems in the current session.

## Plan

One phase. Test-first.

### Code

- `lib/client.sh`: add `client_log_keep <run>`, with a short comment above it, and a
  constant `LANAI_CLIENT_LOG_KEEP` (16 MiB in bytes, `16777216`).
  - If `$run/client.log` is a symlink, not a regular file, or empty, return 0.
  - Read its first line (`IFS= read -r first <log || true`, as `lib/lanai.sh` does);
    if it starts with `$LANAI_CLIENT_TIMEOUT`, return 0.
  - Shift: `mv -fT -- .2 .3`, then `mv -fT -- .1 .2`, each only if the source
    exists (`-e` or `-L`). `-T` treats the target as a file even when it is a link
    to a directory, and `mv` renames a link as a link.
  - `tail -c "$LANAI_CLIENT_LOG_KEEP" -- client.log >.1`, then
    `touch -r client.log -- .1`. The shift has just moved any `.1` (file or link)
    away, so the redirect creates a new file.
  - Errexit is live where the callers run this (`vm_exec` calls it outside any
    condition). So guard every step: `cmd || { echo "lanai: could not keep the
    old Windows window log in $run" >&2; return 0; }`.
- `client_exec`: call `client_log_keep "$run"` on the line above each of its two
  writes; the writes stay as they are. The timeout one stays inside the existing
  `-d $run && ! -L $run && run_dir_check` guard. The appending `exec` stays.
- `vm_exec` (`lib/vm.sh`): call `client_log_keep "$run"` on the line above
  `: >"$run/client.log"`. `lanai-vm-exec` sources `lib/lanai.sh`, which loads both
  `vm.sh` and `client.sh`, so the function is in reach.
- Update the `vm_exec` and `client_exec` comments: they now keep the old log first.

### Tests (`test/client.bats` and `test/vm.bats`)

Write these first and watch them fail:

- `client_log_keep` unit tests: the shift order over four calls; the empty,
  missing and timeout-only cases; a symlink at `client.log`; a symlink at `client.log.1` (the link's
  target stays unchanged); a link at `client.log.3` to a directory (the directory
  stays empty, and `.3` then holds the old `.2`); the kept log's mtime matches (set
  `client.log` to a fixed past time first, `touch -d @1000000000`, so the test fails
  without `touch -r`); a log over the cap keeps exactly its last
  `LANAI_CLIENT_LOG_KEEP` bytes (shrink the constant in the test); the failure
  trigger above prints the exact `lanai:` message (match it as one line with
  `assert_line`; the tool's own error line comes first) and returns 0.
- The inode case (requirement 3): open `client.log` for append on a new descriptor
  (`exec {fd}>>"$RUN/client.log"`, as `test/panel-jobs.bats:215` does; never fd 3,
  which bats owns), run `client_log_keep "$RUN"` and `: >"$RUN/client.log"`, write one
  line on the descriptor, and check the line is in `client.log` and not in `.1`.
- `lanai-client-exec`: the existing "waits for a status reply" test also checks that
  "an old client's log" is now in `client.log.1`. A timeout run keeps the old log as
  `.1`. A run with the failure trigger and a non-empty `client.log` prints the exact
  message, writes the start line, and execs the client (bats' `run` turns errexit
  off, so only a full `lanai-client-exec` run proves the guard). The wrong-mode
  tests (around `test/client.bats:376` and `:405`) also assert no `client.log.1`.
- `lanai-vm-exec` (`test/vm.bats`, beside "prepares \$RUN, starts the helpers"):
  a start with a non-empty `client.log` leaves it empty and its text in `.1`; a
  start with an empty `client.log` leaves `.1` unchanged; a start with a non-empty
  `client.log` and the failure trigger still execs QEMU (its args are recorded),
  prints the exact message, and leaves `client.log` empty.

### Docs

- `README.md:616-618`, the sentence "The Windows window log has its own path": name
  the path, `$XDG_RUNTIME_DIR/lanai/client.log`, and say Lanai keeps the end (up to
  16 MiB) of the last three beside it as `client.log.1` to `.3`, newest first,
  until you log out or the host restarts.
- `docs/plugin/plan.md`: in the follow-on bullet, change "at both points" to "at
  all three points" (the timeout path counts), "move" to "copy", say "keeping three
  previous logs", and point to `docs/plugin/client-log/plan.md`.
- `CLAUDE.md`: no change (layout and rules stay the same).

## Review log

| Gate | Stage | Round | Findings |
|---|---|---|---|
| doc | a (gpt-6.1-sol) | 1 | 3 should-fix, all confirmed and integrated: `mv -T` against directory links; requirement on symlinks narrowed to the keep step; judge the copy, not the live file, under a race (later replaced) |
| doc | a (gpt-6.1-sol) | 2 | 2 should-fix, both confirmed and integrated: interleaved shifts can lose a log (a `flock`, later dropped); the open-count criteria lacked a starting log |
| doc | a (gpt-6.1-sol) | 3 | 2 should-fix, both confirmed and integrated: a symlink at the lock file; the start line's time read after the lock wait (both dropped with the lock). Cap reached with nothing left open |
| doc | b single (opus-5.5) | 1 | 3 should-fix, 7 nits, all confirmed. The lock's cost went to John, who dropped it (the race is accepted above). Integrated: errexit guard and a `lanai-vm-exec` failure test; a concrete failure trigger; `--preserve=timestamps`; README path; lost lines named. Moot with the lock gone: start line inside the lock, FIFO lock file, QEMU-side descriptor test, lock-wait test design |
| doc | b single (opus-5.5) | 2 | 2 should-fix, 6 nits, all confirmed and integrated: kept logs capped at 16 MiB (John's live log was 77 MB after 3.3 h, from `mouseTrace=yes`); the mtime test made non-tautological; the race's strongest reason named; `client_log_start` dropped for a call above each write; a client-side errexit test and exact-message matches; wrong-mode tests assert no `.1`; plan.md wording; logout clears `$RUN` |
| doc | b single (opus-5.5) | 3 | 7 nits, no blocker or should-fix: gate closed. Integrated: the tool's own error line before Lanai's; requirement 3 wording; two more race outcomes named; the dead `rm` dropped; no fd 3 in the inode test; plan.md wording. John's call on the last: skip timeout-only logs |
