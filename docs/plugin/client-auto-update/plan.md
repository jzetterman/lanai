# Update the Windows window by itself: plan

Full tier plan for [spec.md](spec.md). Line numbers refer to `client-auto-update`
at 41ac7f3. Each phase is self-contained: a fresh session can run it from this
document, the spec and the files it names.

## Summary

The bar item already polls `lanai panel` (the view) every 2 or 15 seconds. The
view stays read-only. It only says when an update is due, in a new field,
`auto_update: {launch, key}`. `LanaiModel.qml` (one per bar item) sees the field
and runs `lanai ui-job auto-<id> build-client --auto`, once per key. That starts
the same panel-job unit as the **Update the Windows window** button, with one flag
more.

The worker in that unit does the rest. It waits until no other job, client build,
or command-line snapshot or restore holds it back. Then it checks again from fresh
state that the update is due. If it is, its first act is to record the try in a
durable state file. Then it builds, then it records the outcome. The view reads
that file, and asks systemd whether each try's own unit still runs, and derives
every state from those two facts. Spec requirement 3 (as John changed it on
2026-10-27, EDT) counts a try only once the job records it, so the plan needs no
handshake between the launch and the job.

Four smaller changes carry the rest of the spec:

- The client install swaps the old and new build folders in one atomic rename
  (`mv --exchange`), after the new tree is on disk (requirement 4).
- Every `build-client` panel job runs with `CPUWeight=idle` and
  `OOMScoreAdjust=1000` (requirement 6).
- Start Windows and Open window stay available while a `build-client` job runs
  (requirement 6).
- The view says "close and reopen" only while the running window's binary is not
  the installed one (requirement 7).

## Design

### The parts

| Part | File | Job |
| --- | --- | --- |
| View | `lib/panel.sh` `cmd_panel`, `auto_view` | Reads the try record, the locks and the automatic units, and says `auto_update.launch` true with a `key`. Writes nothing. |
| Trigger | `LanaiModel.qml` `autoUpdate()` | Launches once per key. Forgets the key when a readable view says `launch` false. |
| Launch | `lib/ui.sh` `cmd_ui_job` | Starts the unit with `--service-type=exec`. Its one write: a `launch` try when `systemd-run` fails. |
| Worker | `lib/ui.sh` `auto_update_worker` | Waits, checks, records the try, builds, records the outcome. |

### The try record

`$(state_dir)/client-auto.json` (state, not `$RUN`, so it survives reboots):

```json
{"patches":"<patches_id>","tries":[{"token":"auto-...","at":1761580000.25,"outcome":null}]}
```

- `patches`: the patch set these tries count for (`patches_id`, the identity spec
  requirement 12 uses). A record for another patch set counts as an empty one, so
  a new patch set gets new tries.
- `tries`: one entry per counted try, at most two. `at` is the `ui_timestamp`
  when it was counted.
- `outcome`: `null` (no result yet), `"ok"`, `"failed"`, or `"launch"` (the launch
  could not start).

`auto_record_write` writes a temporary file, runs `sync` on it, moves it into
place, and runs `sync` on the state folder, so every write survives a power loss.
Every write happens under `panel-job.lock`. A hand build (the button, `lanai
build-client`, setup's build step) never touches the record.

A try is due when the client update case (below) is `update`, the record has fewer
than two entries for this patch set, and no entry has `failed` or `launch`. So
there are two tries at most, a failure or a launch that cannot start ends them,
and a second stop ends them.

### The launch

The model starts `lanai ui-job auto-<ms>-<random> build-client --auto`. The
`auto-` token prefix names the unit `lanai-panel-auto-*`, so the view can find the
automatic units. `cmd_ui_job` and `cmd_ui_job_worker` take a token with the
`auto-` prefix exactly when `--auto` is given, and refuse every other mix (exit 2).
`cmd_ui_job` adds `--service-type=exec` for every panel job: with
the default `Type=simple`, `systemd-run` reports success right after the fork,
before the worker is executed. Checked on this machine (systemd 262): a
non-executable `ExecStart` gave exit 0 with the default type and exit 1 with
`--service-type=exec`.

When `systemd-run` fails for `--auto`, the launch takes `panel-job.lock` (with
`flock`, no time limit, which also waits out any read probe). It appends
`{token, at, outcome:"launch"}` only when three tests pass, then releases:

- the graphical session is active (`systemctl --user is-active --quiet
  graphical-session.target`);
- the user manager is not shutting down: `systemctl --user is-system-running`
  prints `running` or `degraded` (compare the word: `degraded` exits 1, as it does
  on this machine);
- the record still allows a try for this patch set.

That is the only write the launch makes. The first two tests keep a logout or
reboot from spending a try. During a logout with Windows running,
`graphical-session.target` stays active while `lanai-vm.service` shuts Windows
down (`TimeoutStopSec=2min`). A bar poll in that time can launch, and
`systemd-run` then fails only because the manager is stopping (a start against
`shutdown.target` is refused). A launch that `systemd-run`
started, but whose worker never records a try, counts for nothing (spec
requirement 3).

### The worker, step by step

`auto_update_worker <token>` runs in the unit `lanai-panel-<token>.service`. It
installs both traps of "The exit trap" first, with the `counted` flag clear.

1. Wait, in a loop that holds no lock while it sleeps, so the panel stays usable
   during a terminal build or snapshot:
   - If `lock_held build.lock` (a client build) or the image progress is active
     (a command-line snapshot or restore), sleep 2 s and start again.
   - Take `panel-job.lock` with `flock`, no time limit.
   - Take `build.lock` with `flock -w 1`. If that fails (a build started in the
     gap), release, sleep 2 s, and start again.
   - Check the image progress once more. If it is active, release both, sleep 2
     s, and start again.
2. Check, from fresh state. First `systemctl --user is-active --quiet
   graphical-session.target`: if the session is not active (a logout or reboot
   that queued this start), release and exit 0 with no entry. Then `setup_plan
   "$(shared_facts)"`, then `client_update_case`, then the record. If no try is
   due, release and exit 0. A second bar item's worker ends here. If the setup
   plan cannot be read, go on to step 3; right after its count and redirect, the
   worker prints its own line, "Lanai could not read the setup plan", to the Jobs
   log and exits 1, so the failure shows and ends the tries. The hand path keeps working without a session, as today
   (`test/panel-jobs.bats:378`).
3. Count: append `{token, at, outcome:null}` to the record (durable), then set
   the `counted` flag. At once, `: >panel-job.log` and `exec 2>>panel-job.log`, so
   every error from here on (even one before the build) is in the Jobs log that
   AUTO_FAILED names.
4. Write the panel's client record (`panel-result-client.json`): token, `command
   build-client`, `args ["--auto"]`, invocation, `started`. It keeps the view's
   running job, the busy line and the Jobs log right, as for every panel job.
5. Run `build_client` in this process, and turn its result into the `lanai
   build-client` reply (`build_client_emit`).
6. Set the outcome to `ok` or `failed` (durable).
7. End the client record with the reply. Release, exit.

It runs `build_client` itself while it holds `build.lock`. It does not call
`lanai build-client`, which would take the lock again and be refused.
`cmd_build_client`'s reply code moves into `build_client_emit <rc> <out>`, which
both use. The worker takes `panel-job.lock` before `build.lock`, as every job does,
and nothing holds `build.lock` while it waits for `panel-job.lock`, so no deadlock
can form.

### The exit trap: an error against a stop

Both traps are installed when the worker starts. They act on the record only
once the `counted` flag is set (after step 3's write), so a worker that exits
before it counts writes nothing. After the count, every way out leaves the right
outcome:

- `trap 'auto_signal=1; exit 143' TERM INT HUP`: a stop by a signal (logout,
  reboot, `systemctl stop`) sets a flag and exits. Bash runs the trap when the
  running command ends, and systemd sends the same signal to the build's children,
  so the trap runs before step 6 can write `failed`.
- The `EXIT` trap: when `counted` is set, the exit status is not 0, the signal
  flag is not set, and the entry's outcome is still null, it writes `failed`
  (durable). So every ordinary
  error after the count ends the tries: a build failure, a setup plan that cannot
  be read, a record or log that cannot be written, an error under `set -e`. Then
  it calls `lanai_on_exit` with the status, because `lanai_main` already owns the
  `EXIT` trap (lib/lanai.sh:50-56, 63) and its JSON fallback must still run.
- `SIGKILL` (systemd's final kill) and a power loss run no trap, so the entry
  stays null.

A null entry reads as a stop once its own unit has ended (next section).

### Liveness, per try

`auto_units` (new seam, `lib/ui.sh`) prints the tokens of the automatic units
that run: `systemctl --user list-units --plain --no-legend
--state=activating,active,reloading,deactivating 'lanai-panel-auto-*'`. A unit
that systemd is stopping still counts, so a logout's stop does not read as a
finished stop (and ask for a launch) before the unit is gone. It keeps only the
first field of lines that match `^lanai-panel-auto-[A-Za-z0-9-]+\.service$`,
with the `lanai-panel-` prefix and `.service` suffix cut. One call per poll.

- An entry with no outcome is running only while its own token is in that list.
  Otherwise it stopped without a result. Another job's lock never makes an
  automatic try look running.
- Any listed unit means an automatic launch is in flight (a worker that waits,
  checks or builds). The view then does not ask for another launch.

### Two bar items

Both may launch at once. Both workers wait in step 1. The first records a try and
builds. The second gets the lock after it ends, checks in step 2, finds the client
current (or the try ended), and exits. Only one try counts, and neither writes a
failure. The key stays `<patch id>:<tries counted>`.

`build_client_locked` changes from `flock -n` to `flock -w 1`, so a hand build
waits out the view's new shared probe on `build.lock`.

### The trigger's key

The model launches once per key and forgets the key in two cases:

- A readable view says `launch` false. The view says `launch` false while any
  automatic unit runs, so once a poll has seen the unit, the key is forgotten.
- The model launched with this key 30 seconds ago or more (`LanaiModel`'s
  `autoRearmMs`, longer than the slowest poll, 15 s, plus a launch), and the
  current view still says `launch` true with the same key and no automatic unit
  in flight. That is a launch whose worker ended without recording a try before
  any poll saw it.

So a launch cut off before its job records the try is launched again at the next
check after it is cut off, or within 30 seconds when no poll saw its unit (spec
requirement 3), with no view of `launch` false needed. The key changes whenever a
try is counted.

A worker that ends with no entry after a poll saw its unit is launched again at
the next check. The worker's planned exits with no entry are the ones the view
tests too (the session, the case, the record), so the view stops asking in the
same state and they cannot loop. Only an unplanned error before the count (a
broken install, such as a lock file the worker cannot open) can relaunch: at the
next check when a poll saw the unit, else at most every 30 seconds.

### The view's update states

`client_update_case <finished>` (new, `lib/ui.sh`, beside `scale_task_kind`)
prints one word. Both the view and the worker call it:

- `none`: the plan is not finished, or the client is current, or the stamp is not
  the pin's, or the guest is behind (requirement 8's case).
- `update`: the client is old, the scale task is the live one
  (`scale_task_kind` is `new`), and the sign-in step is present.
- `setup`: the client is old and `update` does not apply, so Run setup again is
  the one step (today's `client_old` and not `update_shown`).

This is today's `client_old` and `update_shown` test, moved into one function.

`auto_view` (new, `lib/panel.sh`) reads the record, the progress, the pending
token, `panel_records`' `held` flag, `lock_held build.lock` and `auto_units`, and
computes the case itself, once, last. It prints the case in its output, and
`cmd_panel` reads `clientCase` from there, so nothing hashes the patches twice
and the read-order argument covers that value too. It reads in a fixed order: `auto_units` first, then the try
record, then `build_patches_current` (through `client_update_case`) last. A try
writes its outcome before its unit ends. So if the unit is gone at the first
read, the record already holds the outcome; if the try ends after the first read,
it reads as running, or the record shows its outcome. A success also makes the
last read see a current client. A try that ends between the reads never reads as
"stopped". It prints one JSON object that
`cmd_panel` passes on. Its terms:

| Term | Meaning |
| --- | --- |
| `tries` | The record's entries for this patch set, else none. `last` is the last one. |
| `running` | `last` has no outcome and its token is in `auto_units`. |
| `inflight` | `auto_units` lists any token. |
| `over` | Not `running`, and two entries, or any entry with `failed` or `launch`. |
| `want` | Case `update`, not `over`, not `running`, and the graphical session is active (the worker's step 2 test). |
| `deciding` | `panel-job.lock` held, `inflight`, and the newest unended record is missing or is an `--auto` record whose token is not in `auto_units` (a stale record from a stopped try): an automatic worker in its steps 1 to 3. |
| `held_back` | `panel-job.lock` held, `build.lock` held, progress not null, or a pending click token. While `deciding`, neither lock counts: the worker holds both from step 1. |
| `launch` | `want`, not `held_back`, not `inflight`. The view's `auto_update.launch`. |
| `wait` | `want` and `held_back`. |
| `hand` | `shown`, and either the running job (the newest unended record, under a held lock) is a `build-client` record without `--auto`, or `build.lock` is held while `panel-job.lock` is not (a terminal `lanai build-client`). While tries are left, a terminal build is a hold (`held_back`, W_WAIT), not `hand`. Outside case `update` (a CLI setup's step 4, a quick-path build on a current client) it is neither. |
| `updating` | `running`, `hand`, or `want` and not `held_back` (launching). |
| `shown` | Case `update` and `over`. The update button shows. |
| `hand_after` | The client record has no `--auto` and started after `last.at`: the user started an update by hand after the tries. |
| `failed` | `shown`, not `updating`, not `hand_after`. Its kind comes from `last.outcome`: `failed`, `launch`, or (no outcome) stopped. Any other `last.outcome` (an `ok` try while the client is still old) gives the `failed` kind. |
| `key` | `<patch id>:<number of entries>`. |

So the failure state lasts "until the client is current or the user starts an
update by hand". It comes from the durable record alone, so a stop between the
outcome write and the client record's end, or a power loss, keeps the right words.

### What each state shows

The words go in `.warning`, so they show in the panel and in the bar's tooltip
(`LanaiModel.tooltip` joins `view.warning`). When a snapshot or restore shows
progress at the same time, the progress shows beside the warning.

| State | `.warning` (client part) | `result.client` | Bar | Button |
| --- | --- | --- | --- | --- |
| `wait` | W_WAIT | "" | as the holding job makes it | hidden |
| launching (first check, after a stop with a try left, or a unit in flight) | W_RUN | "" | busy | hidden |
| `running` or `hand` | W_RUN | "" | busy | hidden while tries are left; shown and disabled after they end |
| `failed` | RESIZE_NEW (today's, names the button) | AUTO_FAILED, AUTO_LAUNCH or AUTO_STOPPED | failed, also after a reload and with Windows started | shown, enabled when not busy |
| Client current, an older window open | W_REOPEN | "" | unchanged | hidden |
| Client current, no older window | none | "" | unchanged | hidden |
| Case `setup` | today's Run setup again words, unchanged | today's | today's | hidden |

The words:

- W_WAIT: "After the computer wakes from sleep, the mouse may reach only part of
  Windows. Windows may also start at, or change to, the wrong size. When the
  current job ends, Lanai updates the Windows window to fix both. Updating changes
  nothing in Windows."
- W_RUN: "Lanai is updating the Windows window. This can take several minutes. It
  changes nothing in Windows. You can start and use Windows while it runs."
- W_REOPEN: "The Windows window is updated. To use the update, close the Windows
  window and open it again."
- AUTO_FAILED (`last.outcome` is `failed`, or the fallback kind): "Lanai could
  not update the Windows window by itself. The Windows window build log
  (build-client.log) or the Jobs log says why."
- AUTO_LAUNCH (`launch`): "Lanai could not start its update of the Windows
  window. The Jobs log says why."
- AUTO_STOPPED (two entries, the last with no outcome): "Lanai's update of the
  Windows window stopped twice before it finished, for example at a logout or
  restart."

With the failure words, RESIZE_NEW names the button ("To fix both, click Update
the Windows window in More actions."), so the panel needs no earlier click to make
sense.

The busy line is "" whenever `$auto.updating` (a `build-client` job, launching,
or `hand`, including a terminal build with no panel job), because W_RUN says
it. Today's "You can start Windows when it finishes." goes away.

A successful build's reply gives no `result.client` words any more. W_REOPEN
replaces them, for every build that installs the client. The `lanai build-client`
CLI message stays as it is (`panel_words build-client` ok). An auto client record
never gives `result.client` words of its own; the failure words come from the
record.

### Start and Open during an update

`$busy` gains launching (`want` and not `held_back`) and `hand`, so the bar shows busy and
snapshot, restore, delete and Run setup again stay disabled. A new `$startBusy`
decides Start Windows and the right-click start:

```
$startBusy = $pending or ($progress != null) or
  ($rec.held and $job.command != "build-client" and ($auto.deciding|not))
```

The worker holds the lock under its auto client record while it builds, so
`$job.command` is `build-client` then. While it decides (`deciding`), the newest
unended record is none or a stale one, so the view counts it as launching: no W_WAIT, no "Starting the
operation.", and Start stays enabled.

`buttons.start` becomes `button($dailyControls and $off; $idle and ($startBusy|not)
and ($st.setup_done == true); ...)`. `right_click` uses `$startBusy` in place of
`$busy`. Open window and the right-click open have no busy test today, so they stay
available. `boot_vm` takes only `state/lock`, which no build holds, so a start
during the update works. Spec requirement 11 already allows this: it blocks the
right-click start only for unfinished setup, a snapshot or restore, and an
unfinished restore.

### Close and reopen: knowing the window is older

`client_window_stale` (new, `lib/client.sh`) succeeds when the Windows window runs
a client binary that is not the installed pinned build:

1. `client_active`, and `client_main_pid` (new seam: `systemctl --user show -p
   MainPID --value lanai-client.service`) is a positive number.
2. `client_exe <pid>` (new seam) prints `<dev>:<inode> <link text>` for the
   process's binary: `stat -L -c %d:%i` and `readlink` of `/proc/<pid>/exe`. The
   link text, without a ` (deleted)` suffix, must end in
   `/bin/looking-glass-client`. Before the client starts, the unit's main process
   is `lanai-client-exec` (bash), so a window that is still opening never counts.
3. The link text ends in ` (deleted)` (the old build folder is gone), or the
   printed `<dev>:<inode>` differs from `stat -c %d:%i` of
   `$(client_builds)/$LG_BUILD/bin/looking-glass-client`.

`cmd_panel` runs it only when the plan is finished, Windows is active, the stamp
and patches are current and the guest is not behind. Closing the window stops
`lanai-client.service`, and Windows' shutdown stops it too (`PartOf=`), so the
words go away by themselves. The check needs no time stamps and works for any
build, `lanai build-client` included.

### The unit's settings

Every panel job starts with `--service-type=exec` (see "The launch"). The units
are siblings in `session.slice`: `lanai-vm.service`, `lanai-client.service` and
`lanai-panel-<token>.service`. `cpu.weight` and `cpu.idle` share CPU among
siblings, so the CPU and memory settings go on the update's unit only.
`cmd_ui_job` adds, for `build-client` jobs (the button and `--auto`):

- `-p CPUWeight=idle`: the build gets CPU only when its siblings leave it some.
  systemd turns on the `cpu` controller in `session.slice` when a child asks for
  it. The user manager delegates `cpu memory pids` (checked on this machine,
  systemd 262).
- `-p OOMScoreAdjust=1000`: the kernel's OOM killer picks the build's processes
  first. A user manager may raise this value, and only this unit gets it. The VM
  and window keep the manager's default (100). systemd-oomd does not watch
  `session.slice` here (`ManagedOOMMemoryPressure=auto`), so the kernel is the
  one that acts.
- `-p OOMPolicy=continue`: when the kernel kills one compiler process, the unit
  keeps running, so the build fails and the worker writes `failed` (tries end).
  With the default `stop`, systemd would stop the unit, and the try would read as
  a stop or a failure by which came first.

The VM unit, the client unit, setup jobs and `lanai build-client` in a terminal
keep their CPU and memory settings. The spec lets the last two not yield.

### The install swap

`build_client`'s install block becomes:

1. `cmake --install` into `$dest.partial`, check the version, write both stamps
   (as today).
2. `find "$part" -exec sync -- {} +`: every new file and folder is on disk.
3. If `$dest` exists: `mv --exchange -T -- "$part" "$dest"` (one `renameat2`
   with `RENAME_EXCHANGE`). Otherwise: `mv -T -- "$part" "$dest"`.
4. `sync -- "${dest%/*}"`: the rename is on disk.
5. `rm -rf -- "$part"` (after the exchange, this is the old build).

Every path that `build_select` and `client_exec` read names a complete build at
every moment. A stop leaves the old build or the new one, and maybe a leftover
`.partial`. After a stop before the swap, the next build removes it (`rm -rf
"$part"`, as today). After a stop at `swapped` or `committed`, the client is
current, so the next build takes the quick path (lib/client.sh:478-490), and
`builds_prune` returns early when no guest version matches the pin. So the quick
path also runs `rm -rf -- "$dest.partial"`; `build.lock` is held there. coreutils 9.12 here has `--exchange` (it came in 9.5),
and so does Arch's CI image. Btrfs, ext4, tmpfs and overlayfs support the exchange.
On a filesystem that does not, `mv` fails, the build fails with "cannot install
into $dest", and the old client stays. There is no non-atomic fallback.

A no-op seam, `build_step <name>`, runs between the steps (`installing`,
`installed`, `stamped`, `synced`, `swapped`, `committed`, `cleaned`). Tests stop
the build there.

## Phase A: atomic install and the build lock (TDD)

Files: `lib/client.sh`, `lib/lanai.sh`, `test/client.bats`.

Write each test first and see it fail for the stated reason, then change the code.

1. `build_client` (lib/client.sh:540-566): replace `rm -rf -- "$dest" && mv -T`
   with the swap above. Add `build_step` (a no-op function with a comment that
   tests override it) and call it at each named point inside the build subshell.
   Update the comment above `build_client` (lines 444-458) to say the swap is
   atomic and the new tree is on disk first. The quick path (lines 478-490) also
   removes `$dest.partial`.
2. `build_client_locked` (lib/lanai.sh:1350): `flock -n` becomes `flock -w 1`.
   Add `lock_held <file>` beside it: it opens the file read-only (never creating
   it) and tries `flock -s -n`. It succeeds only when another process holds the
   lock exclusively, so two read probes never see each other.
3. Move the reply code of `cmd_build_client` (lines 1368-1384) into
   `build_client_emit <rc> <out>`, and have `cmd_build_client` call it. Its
   comment says the automatic worker uses it too.

Tests (`test/client.bats`):

- "build_client: a stop at each install step leaves a client that opens". For each
  step name, in a fresh `lg_source` with an old `fake_build` and a stale
  `build-patches`, override `build_step` to run `kill -KILL "$BASHPID"` at that
  step, and run `build_client`. Then `$LGDIR/$LG_BUILD/bin/looking-glass-client` is
  executable and `client_version` gives `$LG_BUILD`. Before `swapped`, the binary's
  sum and `build-patches` are the old ones, and `build_patches_current` fails.
  From `swapped` on, they are the new ones and `build_patches_current` succeeds.
  The next build after each stop succeeds and leaves no `.partial`, also after
  `swapped` and `committed`, where it takes the quick path (the fixture has no
  `guest-version`, so `builds_prune` does nothing). Red step: add
  the `build_step` calls to today's code first, with `swapped` between its `rm -rf`
  and its `mv`. The test fails there, because no client is left. Then change the
  swap and see it pass.
- "build_client: the new tree is on disk before the swap, and the swap after". Shim
  `sync` and `mv` to append their arguments to one `$T/order` file, then run the
  real tools. The order shows a `sync` of the `.partial` files, then `mv
  --exchange -T`, then `sync` of the build folder's parent. On a first install
  (no `$dest`) it shows plain `mv -T`.
- "build_client: a filesystem that refuses the exchange keeps the old client". Shim
  `mv` to fail for `--exchange`. The build fails with "cannot install into", and
  the old binary and stamps are unchanged.
- The existing tests still pass: "the new build has both stamps before it replaces
  the old one" (its shim lists `.partial` before the exchange), "a leftover
  .partial folder from a crash is not installed with it", "keeps older builds
  until the guest's IDD matches the pin".
- "lanai build-client: refuses while another build runs" still passes (the holder
  keeps the lock for 30 s). Add: "build_client_locked: waits out a shared probe".
  Hold a shared lock on `build.lock` for 0.3 s in the background, and the build
  still runs.
- "lock_held: true only for an exclusive holder". No file: false, and the probe
  creates no file. An exclusive `flock` in the background: true. A shared `flock`
  in the background: false. Free: false.

Verify: `bats test/client.bats`, shellcheck on the changed files.

Routing: mechanical and fully specified. The bulk implementer (gpt-6-luna, `codex
exec` in a worktree) can do it. Keep it with the Opus implementer if one session
runs all phases.

## Phase B: the record, the launch and the worker (TDD)

Files: `lib/ui.sh`, `test/client-auto.bats` (new), `test/panel-jobs.bats`.

1. `client_update_case <finished true|false>` in `lib/ui.sh`, beside
   `scale_task_kind`, as in "The view's update states".
2. The record helpers in `lib/ui.sh`: `auto_record_read <id>` (the doc for `<id>`,
   or an empty one; an unreadable or foreign doc counts as empty),
   `auto_record_write <doc>` (temporary file, `sync`, `mv`, `sync` of the folder),
   and `auto_try_due <doc>` (fewer than two entries, none with `failed` or
   `launch`). `auto_units`, as in "Liveness, per try".
3. `auto_update_worker <token>`, as in "The worker, step by step", with the traps
   of "The exit trap". A no-op seam, `auto_step <name>`, runs after step 3
   (`counted`), step 4 (`published`), step 5 (`built`) and step 6 (`recorded`).
   Tests stop or break the worker there. It emits one JSON object, like every
   command.
4. `cmd_ui_job`: every panel job gets `--service-type=exec`, and `build-client`
   jobs get `-p CPUWeight=idle -p OOMScoreAdjust=1000 -p OOMPolicy=continue`.
   `build-client` takes no argument or exactly `--auto`; anything else exits 2.
   The token has the `auto-` prefix exactly when `--auto` is given; any other mix
   exits 2. For `--auto`, a failed `systemd-run` writes the `launch` entry, with
   its session test, as in "The launch".
5. `cmd_ui_job_worker`: `build-client --auto` calls `auto_update_worker`. The
   same argument and token rules. With no argument it runs today's path. Update the comments
   above both functions.

Phase B's tests check records, unit launches and builds only. The view's fields
and words are Phase C's.

Tests, each written first and seen to fail, in `test/client-auto.bats`. It loads
`helpers` and `panel-fixtures`. The state is `state "$CURRENT"`, and
`unit_invocation` echoes `inv`. The worker runs as its own process, as in a unit:
a helper, `auto_bin`, writes one `lanai` wrapper in `LANAI_BIN=$T/bin` (the only
`lanai` stub in this file; the hand-path test's `{"ok":true}` answer is a mode of
the same wrapper, set by `$T/lanai-mode`). The wrapper runs `set -euo pipefail`,
as `bin/lanai` does, sources `$REPO/lib/lanai.sh`, then `$T/stubs.bash`, then
calls `lanai_main "$@"`. The worker is its own process under `set -euo
pipefail`, and the panel fixture's `ST`, `RESULT` and `INV` are not exported, so
`$T/stubs.bash` reads them from `$T/st`, `$T/result` and `$T/inv` (the tests write
these files, not the shell variables). `$T/stubs.bash` holds the panel
fixture's facts and these stubs: `build_client` logs a call to `$T/builds`, sleeps
when `$T/slow` exists, fails when `$T/fails` exists, and otherwise touches
`$T/current`; `build_patches_current` is `[[ -e $T/current ]]`. The test shell
sources the same stubs. The `systemctl` stub answers `is-active --quiet
graphical-session.target` from `$T/session` (`active` by default), and
`is-system-running` from `$T/manager` (`running` by default; `degraded` exits
1). The
`systemd-run` stub logs its arguments to `$T/launch`, then acts by
`$T/run-mode`: `ok` starts the command after `--` with `setsid`, in the
background, with fd 3 closed (`3>&-`, as `helpers.bash`' `serve` does), writes the
new process group's id to `$T/units/<token>`, and returns 0; `fail` returns 1;
`silent` returns 0 and runs nothing. That copies systemd's unit: a test stops a
worker the way systemd does, by signalling its whole process group (`kill -TERM
-- -<pgid>`, `kill -KILL -- -<pgid>`), so no orphaned `sleep` or build child keeps
the inherited `panel-job.lock` descriptor. `auto_units` in the stubs prints each
token whose group leader still runs (`kill -0 <pgid>`). `auto_wait <token>`
polls `kill -0 -- -<pgid>` every 0.1 s for up to 10 s, then fails the test, so a
hung worker never hangs the suite. `teardown` sends `SIGKILL` to every group in
`$T/units/`, then calls `stop_bg`.

- "auto worker: a due update records one try and builds". Run mode `ok`,
  `cmd_ui_job auto-a build-client --auto`, then wait for the worker. One build;
  one entry for the current id with outcome `ok`; the client record has token
  `auto-a`, `args ["--auto"]`, an ok reply and `ended`. With Windows stopped and
  with `ST=active`.
- "auto worker: nothing is due in each case of requirement 2". The worker exits 0
  with no build, no record and no client record when: the sign-in step is missing
  (`state '{"done":true,"scale_task":2}'`), the old task (`state
  '{"done":true}'`), setup unfinished (`state '{"snapshot":"declined"}'`, and
  `build_stamp_current` failing for a missing client and for a pin change), the
  guest behind (`guest_version_behind` printing a version), the client current,
  a record whose tries are over, and `$T/session` inactive (a logout or reboot).
- "auto launch: a failed systemd-run during a logout records nothing". With
  `$T/session` inactive and run mode `fail`, `cmd_ui_job auto-a build-client
  --auto` exits 1 and the record has no entry. The same with the session active
  and `$T/manager` `stopping` (Windows still shutting down at a logout): no
  entry. With `$T/manager` `degraded`, a failed launch still records its entry.
  The hand path's "It needs no graphical session" test
  (`test/panel-jobs.bats:378`) still passes.
- "auto launch: the token prefix goes with --auto". `cmd_ui_job auto-a
  build-client`, `cmd_ui_job panel-a build-client --auto`, and the same two for
  `cmd_ui_job_worker`, each exit 2 with no `systemd-run` call and no record.
- "auto worker: a hold that falls between two polls is waited out". Hold
  `panel-job.lock` exclusively from a background `flock` for 2 s, and start the
  worker during the hold. While the hold lasts, the record has no entry. When it
  ends, the worker records one try and builds. No `cmd_panel` runs. The same with
  `build.lock` held exclusively, and with a command-line snapshot's progress (the
  `lock` held and `image-progress.json` written, as `test/panel-qml.bats:3196-3197`
  does).
- "auto worker: short read probes are waited out". A background `flock -s` holds
  `panel-job.lock` for 0.5 s, then releases: the worker records and builds after
  the release. The same with `build.lock`. The shared holds end before the test
  expects the worker to go on.
- "auto launch: a failed systemd-run records one launch try". Run mode `fail`:
  `cmd_ui_job auto-a build-client --auto` exits 1, and the record has one entry
  with `launch`. A second failed launch adds no entry. With a background `flock
  -s` on `panel-job.lock` for 0.5 s, the launch waits it out and still records the
  entry.
- "auto launch: a launch whose worker never runs records nothing". Run mode
  `silent`: `cmd_ui_job` exits 0 and the record has no entry. A next launch in
  mode `ok` records a try and builds.
- "auto worker: every error after the count records failed". With `$T/fails`, the
  entry is `failed`. With `auto_step counted` running `false` (an error under `set
  -e`), and with `setup_plan` failing, the worker exits non-zero, the entry is
  `failed`, and the JSON fallback still prints. `panel-job.log` holds the
  `false` case's error text, and "Lanai could not read the setup plan" for the
  plan case. A next worker builds nothing.
- "auto worker: a stop by a signal leaves a stop". `auto_step` writes
  `$T/at-<step>` and sleeps. At `counted`, `published` and `built`, send the
  worker's process group `SIGTERM`: the entry stays null, no `failed` is written,
  and the worker is gone within 2 s. Send the group `SIGKILL` at the same steps:
  the same, and the next worker does not block on `panel-job.lock`. Then the
  reboot part, after a stop at `counted` (so `$T/current` does not exist yet):
  with the first entry null and its group gone, recreate `$RUN`, and a next worker
  records a second try and builds. Stop that one at `counted` too: a third worker
  builds nothing. A last case stops a build, not a seam: with `$T/slow`, send the
  group `SIGTERM` while the stub build sleeps. The entry stays null, no `failed`
  is written, and the worker is gone within 2 s.
- "auto worker: a failure keeps its outcome after a stop at the end". With
  `$T/fails`, `SIGKILL` the worker's group at `recorded`. The client record has no
  reply, and the one entry is `failed`.
- "auto worker: a cut-off try that installed the client leaves it current".
  `SIGKILL` the group at `built` with a build that succeeds: the entry is null and
  `build_patches_current` succeeds, so a next worker exits 0 with no build.
- "auto worker: a changed patch set gets new tries". A record for patches
  "older" with a `failed` entry: the worker records a try and writes the current
  id.
- "auto worker: builds Lanai did not start leave the record alone". Write a
  record, take its `sha256sum`, then run `cmd_ui_job_worker t build-client` (the
  hand path, with a stub `lanai` that answers `{"ok":true}`) and
  `cmd_build_client`. The sum is unchanged.
- "auto worker: two launches at once record one try" (requirement 5, real locks).
  Run mode `ok` with `$T/slow` (the build sleeps 2 s). Start `cmd_ui_job auto-a
  build-client --auto` and the same with `auto-b`, together, and wait for both
  workers. One build, one entry, both workers exited 0, and the client record's
  token is `auto-a` or `auto-b` with an ok reply.

`test/panel-jobs.bats`:

- "ui job: an update's unit yields CPU and memory to the VM and the window".
  `cmd_ui_job launch build-client` and `cmd_ui_job auto-x build-client --auto`
  pass `--service-type=exec`, `-p` `CPUWeight=idle`, `-p` `OOMScoreAdjust=1000`
  and `-p` `OOMPolicy=continue` in `$T/launch`. `cmd_ui_job launch setup` passes
  `--service-type=exec` and none of the others. `systemd/lanai-vm.service` has no `CPUWeight=` or
  `OOMScoreAdjust=` line. `client_start /x` (with `systemd-run` stubbed) passes
  neither. So the VM's and the window's units keep the default weight of 100 and
  the manager's OOM adjustment, and the update gets less CPU than they do and is
  killed first.
- "ui job: launch is a literal systemd session unit with collect" also checks
  `--service-type=exec`.
- Extend "ui job: the launcher and worker refuse commands the panel does not run
  as jobs" with `build-client --x` and `build-client --auto --auto`.
- "ui job: build-client launches and runs as a panel job in the client group"
  still passes.

Verify: `bats test/client-auto.bats test/panel-jobs.bats test/client.bats`,
shellcheck.

Routing: the Opus implementer (opus-5.5) in a worktree. The traps, the lock order
and the counting rules are where a mistake costs a second build or a lost try.

## Phase C: the view (TDD)

Files: `lib/panel.sh`, `lib/client.sh` (`client_main_pid`,
`client_window_stale`), `test/client-auto.bats`, `test/panel.bats`.

1. `cmd_panel` (lib/panel.sh:252-266): take `clientCase` from `auto_view`'s
   output (step 2), which computes `client_update_case "$(jq -r .finished
   <<<"$plan")"` once, after its record and unit reads. `client_old` is
   `clientCase != none`. Keep
   `signin_missing` and `task` for the other warnings and the settings note.
2. Add `auto_view` (see "The view's update states") and call it after
   `panel_records`. Keep its read order: `auto_units`, then the try record, then
   `client_update_case` (which reads `build_patches_current`) last, so step 1's
   case is computed after the record is read. Compute `patches_id` and call
   `auto_units` only while the client's stamp is the pin's and setup is finished
   (the record cannot matter otherwise).
3. The client group in the words loop (lines 321-327):
   - An auto record (its `args` hold `--auto`): always "".
   - Any record with an ok reply: "". Remove `started`, `booted` and the
     `/proc/stat` read (lines 267-272), which only fed the old done words.
   - A hand record that failed or was interrupted: today's words, shown only while
     `auto.shown`.
   - When `auto.failed`, `result.client` is AUTO_FAILED, AUTO_LAUNCH or
     AUTO_STOPPED by its kind.
4. The setup group's exception (lines 295-300 and 541-544) tests "old client and
   the button hidden". Replace that test with `$clientCase == "setup"`, which is
   the same set of cases, so the try record cannot change setup's words.
5. In the final `jq`: `--argjson auto` and `--arg clientCase`. `$busy` adds
   launching and `$auto.hand`. Add `$startBusy` and use it for `buttons.start` and `right_click`.
   The busy line gives "" for a `build-client` job and while launching.
   `update_client` shows on `$auto.shown`. `$failed` adds `$auto.failed`. Add
   `auto_update: {launch: $auto.launch, key: $auto.key}`.
6. The warning list (lines 519-535): keep the Run setup again branch first. Then
   `$auto.updating` gives W_RUN, `$auto.wait` W_WAIT, `$auto.shown` RESIZE_NEW, and
   `$windowStale` W_REOPEN. Update the comment above it.
7. `client_main_pid` and `client_window_stale` in `lib/client.sh`, with comments.
   `cmd_panel` computes `window_stale` as in "Close and reopen".

Tests first, in `test/client-auto.bats`, reusing Phase B's stubs, with
`auto_units` stubbed to print `$T/units-list`. Each one writes the record, the
locks and the units it needs, runs `cmd_panel`, and reads fields with `jq`.

- "view: an old client asks for an update, with Windows stopped and running". The
  output has `auto_update.launch` true, key `<id>:0`, warning W_RUN, `bar.mode`
  busy, `busy.line` "", `result.client` "", `update_client.show` false, and no
  "Update the Windows window" in any text. `busy.line` holds no "when it
  finishes".
- "view: no ask in each case of requirement 2". The same cases as Phase B's. Each
  gives `auto_update.launch` false, and the Run setup again cases keep today's
  warning.
- "view: a job, a client build or a command-line snapshot makes it wait". Hold
  `panel-job.lock` with an unended snapshot record: `launch` false, warning W_WAIT,
  no button named. With `build.lock` held: the same. With a CLI snapshot's
  progress: W_WAIT and the progress both show. A pending click token gives the
  same. After the hold ends: `launch` true, W_RUN.
- "view: a launch in flight is not launched again". An automatic unit listed and
  no entry (a worker waiting or checking): `launch` false, W_RUN, busy. The unit
  gone and still no entry (a launch cut off before its job recorded the try):
  `launch` true with the same key, no failure.
- "view: a running update shows busy, W_RUN, and Start and Open". An entry with no
  outcome, its token listed, and an unended auto client record under a held
  `panel-job.lock`. Windows stopped: `buttons.start` shown and enabled,
  `right_click` "start", `launch` false. Windows running with no window:
  `buttons.open` enabled, `right_click` "open". The same at the launching check
  (nothing held, no entry), and for a hand `build-client` job after the tries
  end. With a CLI snapshot's progress as well: progress and W_RUN both show.
- "view: a worker that decides counts as launching". `panel-job.lock` and
  `build.lock` both held, no unended record, and an automatic unit listed: W_RUN,
  `busy.line` "", `buttons.start` enabled, no W_WAIT. The same with a stale
  unended auto client record whose token is not listed (the start of a second
  try): the same. The same locks with no unit listed: W_WAIT.
- "view: a terminal build after the tries end counts as an update by hand".
  `auto_over`-style record, `build.lock` held, `panel-job.lock` free: W_RUN,
  `bar.mode` busy, `busy.line` "" (not "Starting the operation."), no failure.
- "view: a terminal build is a hold while tries are left, and nothing outside the
  update case". No entries, `build.lock` held, `panel-job.lock` free: W_WAIT, not
  W_RUN. With the client current (a quick-path `lanai build-client`), or the plan
  unfinished (a CLI `lanai setup` at step 4), the same lock: no update words, and
  `bar.mode` not busy from it.
- "view: a successful second try never shows stopped". One entry with no outcome.
  Stub `auto_units` to list its token and, as it returns, to write the `ok`
  outcome and touch `$T/current` (the try ends right after the first read): no
  AUTO_STOPPED, no failure, no update words. An `ok` last entry with the client still old and two entries: the
  `failed` kind (AUTO_FAILED).
- "view: another job's lock never makes a dead try look running". An entry with
  no outcome, its token not listed, and `panel-job.lock` held by a snapshot job:
  the try reads as a stop (key `<id>:1`, W_WAIT).
- "view: a stop with a try left shows no failure and asks again". One entry with
  no outcome, its token not listed, nothing held: `launch` true, key `<id>:1`,
  W_RUN, `result.client` "", `bar.mode` busy, not failed.
- "view: after the tries end, every bar item fails until a hand update or a
  current client". Three records: one `failed` entry, one `launch` entry, and two
  entries with no outcome. Each gives `bar.mode` failed, `layout` failed, the
  matching AUTO_* words, warning RESIZE_NEW, and `update_client` shown and
  enabled. The same output after a second `cmd_panel` (a reload), with
  `ST=active` and `INV` changed (Windows started), with a fresh `$RUN`, and with
  the client record removed (the record alone carries it). Then a hand client
  record (no `--auto`) started after the last entry, running: no failure, W_RUN.
  The same record failed: today's hand words. A hand record from before the
  tries does not end the failure state. With `build_patches_current` true: no
  failure, no button, no words.
- "view: a failed try stopped at its end shows failed, not stopped". One `failed`
  entry and an unended auto client record, nothing running: AUTO_FAILED.
- "view: the button starts an update by hand after the tries end". From the
  failed state, `buttons.update_client.enable` is true.
- "view: a cut-off try that installed the client shows neither failure nor
  button". One entry with no outcome and the client current: `launch` false, no
  failure, no button, `result.client` "".
- "view: a changed patch set asks again". A record for patches "older" with a
  `failed` entry: `launch` true, key `<id>:0`, no failure.
- "view: two bar items' launches show no failure". Phase B's "two launches at
  once" run, then `cmd_panel`: `bar.mode` not failed, `result.client` "",
  `result.launch` "".
- "view: close and reopen only for a window older than the install". Use the real
  `build_patches_current` (re-source `lib/client.sh` after the fixture, as the QML
  board test re-sources `snapshot.sh`) and `fake_build` for an installed client
  with current stamps. `fake_build` lives in `test/client.bats:61`; move it to
  `test/helpers.bash`, which both files load (`test/setup.bats:283` keeps its own
  definition, which overrides it there). The check reads the window's binary
  through a narrow seam, `client_exe <pid>`, which prints `<dev>:<inode>
  <link text>` (in Lanai: `stat -L -c %d:%i` and `readlink` of `/proc/<pid>/exe`).
  With `ST=active`, `client_active` true, `client_main_pid` printing 4242, and
  `client_exe` printing the id of another file and a path ending in
  `/bin/looking-glass-client`, the warning is W_REOPEN and the tooltip source
  holds it, with `bar.mode` not failed or busy. The installed binary's id shows
  nothing. A path ending in ` (deleted)` shows W_REOPEN. `/usr/bin/bash` (the
  window still opening) shows nothing. `client_active` false
  (window closed) or `ST=inactive` (Windows shut down) shows nothing. A
  successful hand or auto client record with no window shows nothing in
  `warning` or `result.client`.

`test/panel.bats` changes (rewrite each test first, see it fail, then the code):

- 2615 ("an old client ... offers the update"): becomes the automatic case (W_RUN,
  no button). Add an `auto_over` helper that writes a record with one `failed`
  entry for the current id. With it, the same test still shows RESIZE_NEW and the
  enabled button.
- 2726 ("the update button shows disabled while a panel job runs"): with
  `auto_over` and a hand record started after the entry, the button is shown and
  disabled, Start is enabled, `busy.line` is "", and the warning is W_RUN.
- 2758 ("the done words stay until a client starts"): replace it with the close
  and reopen test above, or delete it there. `CLIENT_DONE` stays for the
  `panel_words` test (2744).
- 2796, 2814 and 2828: these need the button, so call `auto_over` first, with the
  hand record started after the entry. 2828's Run setup again half is unchanged.
- Run the rest of `test/panel.bats`. 3265 ("every existing guard survives") keeps
  Start enabled for an old client with Windows stopped. Fix any other test that
  read the old done words or busy line. `panel_fixture_setup` gets an
  `auto_units` stub that prints nothing.

Verify: `bats test/client-auto.bats test/panel.bats test/panel-jobs.bats`,
shellcheck.

Routing: the Opus implementer (opus-5.5) in a worktree. It is user-facing words
(taste >= 7) and the panel's busiest `jq`.

## Phase D: the bar item's trigger (TDD, QML)

Files: `LanaiModel.qml`, `test/panel-qml.bats`.

1. `LanaiModel.qml`: add `property string autoKey: ""`, `property real autoAt: 0`,
   `property int autoRearmMs: 30000` and `function autoUpdate()`, called from
   `onViewChanged`. When `view.auto_update` is missing (the unreadable-poll
   fallback), do nothing. When `launch` is not true, set `autoKey` to "". When
   `launch` is true and the key is new, or the key is the same and `Date.now() -
   autoAt >= autoRearmMs` (the view says `launch` true only while no automatic unit
   is in flight), set `autoKey` and `autoAt` and call `Quickshell.execDetached([cli, "ui-job", "auto-" + Date.now() + "-" +
   Math.floor(Math.random() * 1000000), "build-client", "--auto"])`. It never
   touches `pendingToken`, `pendingAt` or `clickNotice`, and never calls `run()`.
   A comment above it says why: the backend decides and waits out holds, a key
   launches once, and the user's clicks never wait on it.
2. `LanaiPanel.qml` and `Widget.qml` need no change: the warning, the result, the
   busy line and the right-click already come from the view. Confirm that while
   testing.

Tests, in the renderer test's inline QML (`qml_renderer_fixture`), written first:

- `test_auto_update_launches_once_per_key`: a model with `panelOpen` false, then
  one with `panelOpen` true. A view with `auto_update {launch:true,key:"a:0"}`
  raises `Quickshell.launchCount` by one, with `lastCommand` `[cli, "ui-job",
  "auto-...", "build-client", "--auto"]`. The same view again launches nothing. A
  view with `launch` false, then `a:0` again, launches once more (a launch cut off
  before its job recorded the try). With no `launch` false view in between, an
  `a:0` view after `autoAt` is set 30 s back launches once more (a launch whose
  unit ended before any poll saw it), and one at 29 s does not. `a:1` launches. An
  unreadable poll between two `a:0` views does not relaunch. A second model (a
  second bar item, or a shell restart) launches `a:0` once on its own.
- `test_auto_update_has_no_pending_notice_or_blocked_click`: first assert that the
  view's ask raised `launchCount` (the automatic launch happened). Then
  `pendingToken` is "" and `clickNotice` is "". The next poll's command has
  no `--pending`, so the view can never say "The operation did not start" for it.
  `model.run(["snapshot","x"], true)` at once returns a token and launches
  `ui-job ... snapshot x`, and `model.run(["start"], false)` starts `ui-run`, both
  with no notice.

Verify: `bats test/panel-qml.bats`, then `test/qml-lint` (local only).

Routing: the Opus implementer. It is small, but it is the trigger every install
runs.

## Phase E: docs (requirement 8)

Files: `README.md`, `docs/plugin/spec.md`, `docs/plugin/plan.md`,
`docs/plugin/proofs.md`, `CLAUDE.md`.

1. `README.md:318-329`, the upgrade paragraph. The first sentence and the Run
   setup again half stay. The middle becomes: "When only the Windows window needs
   an update, Lanai updates it by itself after `omarchy plugin update`, a shell
   restart or a sign-in, with no click. The update takes several minutes, works
   whether Windows runs or not, and changes nothing in Windows. You can start and
   use Windows while it runs, and it gets less CPU than Windows. If the Windows
   window was open when the update finished, the panel and the bar's tooltip say to
   close it and open it again. If the update fails, or stops twice before it
   finishes (for example at a logout), the panel shows the failure and **Update the
   Windows window** in More actions, and points to the Windows window build log or
   the Jobs log."
2. `docs/plugin/spec.md` requirement 12, the bullet at lines 360-371. Replace "until
   the user runs the one step ... says to close and reopen the Windows window." with
   words that say: Lanai runs that build step by itself, without a click, whether
   Windows runs or not (with a link to this spec); the build step changes nothing
   in Windows (keep the three named items); while it runs the panel says the
   Windows window is updating; the fixed client takes over the next time the
   window opens; the panel and the bar's tooltip say to close and reopen the window
   only while a window that opened before the install is open, and `lanai
   build-client`'s last message still says it; when Lanai's own tries end with the
   client still old, the panel says what may go wrong, as today, and names the
   step, **Update the Windows window**. The Run setup again and requirement 8
   sentences stay.
3. Row 12b's "Upgrade:" clause (line 528). Replace "the panel names the step and
   says what it fixes, starting and using Windows still works, the step shows no
   Windows prompt and does not restart Windows, its last message says to close and
   reopen the window" with: "Lanai starts the build step by itself and the panel
   says the Windows window is updating; starting and using Windows still works
   during it; the step shows no Windows prompt and does not restart Windows; while
   a window that opened before the update is open, the panel and the bar's tooltip
   say to close and reopen it; when Lanai's own tries end with the client still
   old, the panel names the step and says what it fixes". The rest of the clause
   stays.
4. Add a row to the spec's review log: an amendment dated on the day of the change
   (EDT), naming this spec and the three text changes.
5. `docs/plugin/plan.md:2185-2191`, the follow-on bullet: add one sentence that
   points to `docs/plugin/client-auto-update/`.
6. `docs/plugin/proofs.md`: add "Update unit settings (<date>, EDT)". Claude runs,
   on the host, with no VM:
   - `systemd-run --user --collect --quiet --unit=lanai-props-check
     --slice=session.slice --service-type=exec -p CPUWeight=idle -p
     OOMScoreAdjust=1000 sleep 30`. Record `cpu.idle` (expect 1) in the unit's
     cgroup under `session.slice`, `cgroup.subtree_control` of `session.slice`
     (expect `cpu`), and `/proc/<pid>/oom_score_adj` (expect 1000). Then stop the
     unit.
   - The same `systemd-run` with a non-executable `ExecStart`, once without and
     once with `--service-type=exec`. Record the exit codes (0 and 1 when this
     plan was written, 2026-10-27, EDT, systemd 262).
   - The TERM trap under a real `systemctl --user stop`, kept away from John's
     live state: temporary `XDG_STATE_HOME`, `XDG_DATA_HOME`, `XDG_CACHE_HOME`
     and `XDG_CONFIG_HOME` folders under the scratchpad (passed with `--setenv`),
     a `lanai` wrapper that sources Phase B's test build stub, a fixture setup
     record in the temporary state, and a unit named `lanai-trapcheck-<n>`. The
     wrapper also stubs `shared_facts` (prints nothing), `setup_plan` (prints
     `{"finished":true}`), `client_update_case` (prints `update`) and
     `unit_invocation` (prints `inv`, for step 4's record), so the worker
     never runs `layout_check`, never reads a storage folder (with no settings
     file, `storage_dir` would default to John's live `~/.windows`), and never
     asks systemd about the live `lanai-vm.service`. The unit name is outside
     `lanai-panel-*`, so no live bar sees it in flight. Stop the unit
     at the stub's `built` seam, and record only the entry's outcome (expect
     null). Remove the temporary folders after.
   Phase F's results go in the same file.
7. `CLAUDE.md`, the layout: `lib/ui.sh` also holds Lanai's own client update
   (`client-auto.json`), and `test/client-auto.bats` tests it.
8. `rg -n -U 'Update\s+the\s+Windows\s+window|close\s+and\s+(re)?open|when\s+it\s+finishes' README.md lib docs/plugin/spec.md`
   for anything else that describes the old behavior.

Routing: the Opus implementer. The words are user-facing.

## Phase F: John's hand check

As the spec's last acceptance bullet says, on John's install, after phases A to E
pass. The installed plugin folder is a git checkout. All times in EDT.

It needs no rehearsal on a reflink copy first (CLAUDE.md's rule for live checks):
the update builds and swaps the client on Linux only and writes nothing to the
Windows disk, and starting Windows during the update is an ordinary start. The
client-warp plan made the same call for a client-only change. Phases A to E cover
the swap, the locks and the CPU and memory settings without a VM.

1. Make a throwaway commit on top of the feature branch that changes one patch's
   header text, so its patch set differs and it still applies. In the installed
   plugin's folder, `git fetch` the local repo's branch with that commit, check it
   out, and run `omarchy-shell shell rescanPlugins`.
2. Part one, Windows running and the window open: the bar item shows busy without
   a click, the panel says W_RUN, and Windows stays responsive. When it finishes,
   the panel and the tooltip say W_REOPEN. Close and reopen the window: the
   warning is gone and `client.log` starts fresh.
3. Part two: shut Windows down. Check out the feature branch without the
   throwaway commit (`main`'s patch set, so it differs again) and rescan. A second
   update starts by itself. Start Windows from the bar while it runs.
4. Put the folder back on `main` and rescan. The client is current for `main`,
   with no click.
5. Claude records the times and what showed in `docs/plugin/proofs.md`.

## Requirement and acceptance map

| Spec item | Phase | Tests |
| --- | --- | --- |
| Req 1, start by itself | B, C, D | "a due update records one try and builds" (stopped, running); "view: an old client asks"; `test_auto_update_launches_once_per_key` (panel open and closed) |
| Req 2, only that case, and the wait | B, C | "nothing is due in each case"; "view: no ask in each case"; "a hold that falls between two polls is waited out"; "short read probes are waited out"; "view: ... makes it wait", then asks after the hold |
| Req 3, tries | B, C, D | errors after the count, signal stops and their reboot, the failure kept across a stop at the end, a failed `systemd-run`, a worker that never runs (counts nothing, launched again), changed patch set, hand builds leave the record; "view: a launch in flight ..."; "view: another job's lock ..."; "view: after the tries end ..."; "view: the button starts an update by hand"; QML relaunch after `launch` false and second model |
| Req 4, always a working client | A, B | "a stop at each install step"; "on disk before the swap"; "refuses the exchange"; "a cut-off try that installed the client" (worker and view) |
| Req 5, one update at a time | B, C | "two launches at once record one try"; "view: two bar items' launches show no failure" |
| Req 6, Windows keeps working | A, B, C | "an update's unit yields CPU and memory"; "view: a running update shows ... Start and Open"; the atomic swap |
| Req 7, what the user sees | C, D | the view tests per state; the reopen test; `test_auto_update_has_no_pending_notice_or_blocked_click` |
| Req 8, docs | E | review of the README, spec 12 and row 12b |
| Acceptance: suite, lint, shellcheck | all | `bats test spike/test` with a short `TMPDIR`, `test/qml-lint`, shellcheck as CI runs it |
| Acceptance: hand check | F | John |

## What CI runs

CI runs every bats file: `test/panel.bats` in the panel group, and
`test/client-auto.bats`, `test/client.bats`, `test/panel-jobs.bats` and
`test/panel-qml.bats` in the rest group (a new file needs no workflow change). The
QML renderer tests run in CI, which installs `qt6-declarative`. CI also runs
shellcheck on `test/*.bats`, so the new file is checked.

Only local: `test/qml-lint` (it needs the installed shell), the two QML tests that
load the installed shell's controls, the proofs on a real user manager (Phase E
step 6), and Phase F.

## Risks

- Accepted by the spec: a launch cut off before its job records the try counts for
  nothing and is launched again: at the next check, or within 30 seconds when its
  unit ended before any poll saw it (the model's re-arm).
- A worker that ends before it records anything, every time, from an unplanned
  error (for example, a lock file it cannot open), shows the update as launching
  until the state changes. It is launched again at the next check when a poll saw
  its unit, else at most every 30 seconds. Each such launch exits at once and
  builds nothing. Only a broken install gets here. The worker's planned exits
  with no entry (the session, the case, the record) cannot loop: the view tests
  the same facts.
- Waiting workers: during a long job, each bar item that launched has a worker
  waiting in step 1. When the job ends, the first one runs the try and the others
  check and exit.
- `CPUWeight=idle` can make the build slow while Windows is busy for a long time.
  The spec asks Windows to win. Use `CPUWeight=1` instead if the hand check finds
  the build too slow.
- An OOM kill of one compiler process fails the build (`failed`, tries end):
  `OOMPolicy=continue` keeps the unit running so the worker can record it. The
  user retries by hand.
- A logout or reboot during a try leaves a stop (one more try at the next
  sign-in). Three tests keep a launch made while the session stops from spending
  the second try: the session test in the view, the launch and the worker, the
  manager test (`is-system-running`) before a `launch` entry, and `auto_units`
  counting a `deactivating` unit as in flight.
- A snapshot name prompt that the backend refused reopens only once nothing is
  busy (`settleSnapshotJob`, LanaiPanel.qml:178). An automatic update that starts
  right after a snapshot job delays that reopening until the build ends.
  Accepted: the refusal's words still show beside the prompt's action.
- A plugin update during a running build can change the patches under it. This
  is the same today. The stamp keeps the patch id the build started with, so the
  next check sees an old client and asks again.

## Review log

| Stage | Round | Findings | Result |
| --- | ---: | ---: | --- |
| a (gpt-6.1-sol) | 1 | 5 | Five P2 confirmed, none refuted. (1) The worker gave up after `flock -w 1`, and a hold between two polls left the model's key latched: confirmed, since another bar item's pending click never reaches this view. (2) The client record came before the count: confirmed. (3) `systemd-run`'s default type reports success after the fork: confirmed by the man page and on this machine (exit 0 for a non-executable `ExecStart`, exit 1 with `--service-type=exec`). (4) The failure words came from the client record, which `panel_result_write` (`lib/ui.sh:143-151`) writes without `sync`: confirmed. (5) The failed-launch path used `flock -n` against the view's shared probes (`lib/panel.sh:126-128`): confirmed. Redesign: a launcher that waited out holds, counted durably and waited for the worker's start, and a record of tries with outcomes. |
| a (gpt-6.1-sol) | 2 | 5 | Five P2 confirmed, all in the launcher and worker handshake, plus two test findings: a Phase B test held shared locks through a run that needs the exclusive ones, and Phase B asserted view fields that Phase C builds. John changed spec requirement 3 (2026-10-27, EDT): a try counts once the update job records it, and a launch cut off before that is launched again. Rewritten around that: no launcher decision and no start lock. The worker waits with no time limit, checks from fresh state, records the try as its first act, then builds and records the outcome; a signal trap tells a stop from an error, and an exit trap writes `failed` for any error after the count. Liveness is per try, from the try's own unit. The launch writes only a `launch` try, when `systemd-run --service-type=exec` fails. Removed: the launcher's decision, `auto.lock`, the start wait and its time limit. Both test findings fixed: shared holds end before the worker must go on, and Phase B tests only records, launches and builds. |
| a (gpt-6.1-sol) | 3 | 2 | Two P2 confirmed: a launch whose unit ended before any poll saw it was never re-armed (the model now relaunches the same key after 30 seconds with no unit in flight, tested without a `launch` false view), and Phase F lacked the repo's rehearsal rule (it now says why a client-only change needs no rehearsal on a copy, as the client-warp plan did). Integrated by the orchestrator; stage (a) reached its cap, and stage (b) reviews the result. |
| b single (opus-5.5) | 1 | 13 | Four should-fix and nine nits, all confirmed against the code, none refuted. Should-fix: (1) a logout or reboot could spend both tries through a launch made while the session stops; the launch's `launch` write and worker step 2 now test `graphical-session.target` first and exit with no entry (the hand path is unchanged), with one test per path. (2) The signal tests signalled only the worker pid, so bash waited on `auto_step`'s `sleep` and an orphaned child kept `panel-job.lock`; the stub now starts workers with `setsid` and fd 3 closed, and tests signal the process group. (3) After a stop at `swapped` or `committed` the next build takes the quick path (lib/client.sh:478-490), which left `.partial` (and `builds_prune` returns early without `guest-version`); the quick path now removes it, and the swap text says so. (4) Phase E's trap check would have written John's live state and shown as in flight to his bars; it now runs with temporary XDG folders, the test build stub and a unit name outside `lanai-panel-*`. Nits: `auto_view`'s read order (record, units, then `build_patches_current`); both traps installed at start, acting only after `counted`; `OOMPolicy=continue` for build jobs; a deciding worker counts as launching, not held back; `setup` defined as old and not `update`; `hand` covers a terminal build; the `auto-` prefix goes exactly with `--auto`, `auto_units` matches whole unit names, and an `ok` last entry while over gives the `failed` kind; W_RUN, W_WAIT and AUTO_STOPPED words; the snapshot prompt's delayed reopening is accepted in Risks. |
| b single (opus-5.5) | 2 | 9 | Three should-fix and six nits, all confirmed against the code, none refuted. Should-fix: (1) during a logout with Windows running, `graphical-session.target` stays active while `lanai-vm.service` stops (`TimeoutStopSec=2min`), and a `deactivating` try unit read as a stop, so a failed `systemd-run` could end the tries; the launch now writes `launch` only when `systemctl --user is-system-running` prints `running` or `degraded` (`degraded` exits 1, as on this machine), and `auto_units` lists `deactivating`, with a `stopping` test. (2) `hand` gave W_RUN and busy for any terminal build; it now needs `shown`, so a terminal build with tries left is a hold (W_WAIT) and a CLI setup or quick-path build shows nothing, and `$busy` adds `hand` explicitly, with tests. (3) The Phase E trap proof would have read John's live `~/.windows` (no settings file means the default `storage_dir`) and the live VM unit; its wrapper now stubs `shared_facts`, `setup_plan` and `client_update_case`. Nits: `auto_view` reads `auto_units` before the record (the earlier order could read a finished try as stopped); the Jobs log starts right after the count and AUTO_FAILED and the README name it; step 1 checks the build lock and progress before `panel-job.lock`, then once more after; the 30-second claim corrected and the session test added to `want`; test helpers (bounded `auto_wait`, a teardown that kills every group, one `set -euo pipefail` wrapper in one `LANAI_BIN`, the reboot part after a stop at `counted`, `launchCount` asserted first, a `client_exe` seam in place of `LANAI_PROC`, `fake_build` moved to `helpers.bash`, anchor 3265); W_WAIT words. |
| b single (opus-5.5) | 3 | 9 | Two should-fix and seven nits, all confirmed against the plan and the code, none refuted. Should-fix: (1) `deciding` exempted only `panel-job.lock`, but the worker holds `build.lock` from step 1, and a stopped try leaves its auto client record unended, so the start of a try (and every second try) showed W_WAIT; `deciding` now also covers a stale unended `--auto` record whose unit is gone, and neither lock counts toward `held_back` while it holds, with both locks and the stale record in the test. (2) The signal test now also stops a build in progress (`$T/slow`), not only seams. Nits: `busy.line` is "" whenever `$auto.updating`, asserted for a terminal build; the unreadable setup plan prints its own Jobs log line after the redirect, and the test expects it; "Close and reopen" uses the `client_exe` seam; the Phase E proof stubs `unit_invocation`; `auto_view` computes the case once and `cmd_panel` reads it from there; the worker's stubs read `ST`, `RESULT` and `INV` from files; the button test keeps only its `enable` assertion. Stage (b) reached its cap. |

On October 27, 2026 (EDT), John accepted advancing to code after stage (b)'s third
round, with every finding integrated. The diff gate reviews the code against this
plan and the spec.
