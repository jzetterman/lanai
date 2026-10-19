# Plan: Lanai panel redesign

Governing spec: [spec.md](spec.md). Tier: Full. Branch: `panel-redesign`.
The approved spec controls behaviour when a board omits a control or uses
placeholder data. This plan changes presentation and adds the data it needs.

Read `CLAUDE.md`, the spec and the files named in a phase before starting it.
Run phases in order. Each phase leaves the existing panel usable and the full
suite green. Write the named tests first, run them to show the missing behaviour,
then implement it. Keep existing regression tests. Change their expectations only
where the spec changes the interaction.

The read-only boards are in [mockups/](mockups/) beside this plan.
Read `canvas.json` and all ten `.dc.html` files there. Do not change them or port
their HTML, JavaScript, colours or desktop bar. The panel inside the boards is
420 pixels wide. Keep `Style.space(420)` as the desired width and let
`KeyboardPanel.fittedContentWidth()` fit the screen. Keep the existing height cap
and scrolling unless the theme comparison shows that they need adjustment.

## Approach

Keep the three production QML files. Keep the small inline `Action` and `Note`
components in `LanaiPanel.qml`. Add an inline row component only where the three
detail rows share real geometry and keyboard behaviour. Do not add a general
state machine, action registry, page framework or second model.

`lib/panel.sh:cmd_panel()` remains the read-only decision and wording layer.
It gathers host facts once and reuses `status_map()`, `setup_plan()`,
`panel_records()`, `cmd_settings()` and `cmd_snapshots()`. Keep the existing
`buttons` descriptors and their command-side guards. Add presentation fields to
the same JSON reply. Keep old fields while the old QML still consumes them.

`lib/setup.sh` records actual check outcomes. Reuse the current checks and their
deadlines. `lib/snapshot.sh` and `lib/image-proof.py` supply the restore target
alongside existing progress. `LanaiModel.qml` keeps literal command transport,
polling and click suppression. It gains a separate clipboard process with exit
feedback. `LanaiPanel.qml` owns drafts, expansion, menus and confirmations.
`Widget.qml` renders the backend's bar decision.

No guest protocol change is needed. The current sources are enough:
`guest/setup.cmd` installs the pinned IDD and agent allow-list;
`guest/lanai-scale.ps1` opens the scale port; `guest/lanai-start.cs` starts the
sign-in work. Do not change those files or their trust rules for this redesign.
An open scale port proves startup only. A checked row describes that setup
attempt, not continuous health or a visible desktop.

## Installed shell components

These components were checked under `/usr/share/omarchy/shell`. Recheck their
source in a fresh session before editing QML. Use their installed APIs.

| Source | Use |
|---|---|
| `Ui/Panel.qml`, `Ui/KeyboardPanel.qml` | Keep panel ownership, popout coordination, Escape, focus priming and screen fitting. |
| `Ui/PanelHero.qml` | Windows title, monitor mark, saved-settings or setup meta line, and status pill through `title`, `meta`, `detail` and `iconComponent`. Its meta line uppercases and elides, so check that all header values remain readable. |
| `Ui/Button.qml` | Primary action, secondary text actions, detail toggles, Cancel, Save and Reset. Set `focusable: true`. It already handles Return, keypad Enter and Space and paints focus. Use `selected`, `background`, `foreground` and `accent` for emphasis. |
| `Ui/PanelActionButton.qml` | Compact shutdown, more-actions and copy buttons. Set `focusable: true`, `tooltipText` and `Accessible.name`. It already handles keyboard activation and focus. |
| `Ui/PanelSeparator.qml`, `Ui/PanelSectionHeader.qml` | Divided Settings, Snapshots and Logs rows and headings. A section header alone is text, so use a Button for the expanding control. |
| `Ui/NumberField.qml` | Memory and cores. Keep `field.value`, `field.valueModified`, `from`, `to` and whole-number steps. |
| `Ui/Dropdown.qml` | Every backend scale choice. Keep the FocusScope around it and restore its value binding after `changed`. |
| `Ui/BarWidget.qml`, `Ui/BarIconButton.qml` | Existing glyph slot, tooltip, mouse handling and panel ownership. Draw the underline and badges inside the custom icon item. |
| `Ui/BorderSurface.qml`, `Commons/Border.qml` | Setup cards and focused row borders where existing controls do not supply the surface. Use `Border.controlSpec()` and shell surface tokens. |
| `Commons/Style.qml` | `Style.space()`, `Style.spacing`, `Style.font`, `Style.cornerRadius` and `Style.duration()`. Use the shell font and focus tokens. |
| `Commons/Color.qml` | Import as `Commons`; use `Commons.Color.foreground`, `muted`, `accent`, `urgent`, `background` and `popups` roles. There is no semantic green success role. Use theme roles and status text instead of copied green, amber or blue values. |

Keep Qt Quick `Text`, `Rectangle`, layouts and animations for simple geometry.
Keep `QQC.ProgressBar` for the operation meter, with theme-bound content and
background. Keep `Text.PlainText`. Never use mockup hex colours. Prefer the
existing theme-derived foreground and font bindings where a shell component
expects them. Keep narrow qmllint suppressions only for actual dynamic shell
properties.

## Checks after every phase

Run these from the repository root in Bash. Use a short temporary path under the
session runtime directory. Do not put fake sockets under the long checkout path.

```bash
(
  set -euo pipefail
  test -n "${XDG_RUNTIME_DIR:-}" && test -d "$XDG_RUNTIME_DIR"
  lanai_test_tmp=$(mktemp -d "$XDG_RUNTIME_DIR/lr.XXXXXX")
  export TMPDIR="$lanai_test_tmp"
  test/qml-lint
  BATS_TEST_TIMEOUT=120 bats test spike/test
  shellcheck -x bin/* lib/*.sh spike/lgtest test/*.bats test/helpers.bash \
    spike/test/*.bats test/qml-lint
  rm -rf -- "$lanai_test_tmp"
)
```

The subshell stops at the first failed check and skips the cleanup.

Do not report success if a command fails. Keep the temp directory on failure for
diagnosis. Run each phase's focused command before this block. For the red pass,
use the same `TMPDIR` setup and run the named focused command before editing
production code. QML behavioural cases live inside the existing bats test
`QML renderer: poll cadence, refresh races, literal actions and armed confirmations`
in `test/panel-qml.bats`. Name its added QtTest functions as specified below.
Run it with `bats test/panel-qml.bats`.

The Bats helpers isolate HOME, settings, runtime files, sockets and services.
Never use John's live `~/.windows`. Keep `LANAI_TEST_BTRFS_DIR` pointing to a
separate fixture directory when available. Run btrfs cases before merge with
`LANAI_REQUIRE_BTRFS=1`. Run guest tests locally with `pwsh` installed; CI skips
them. Report skips and unavailable checks. Nothing in this plan authorizes a
live boot, a root command or a theme/config edit on John's desktop.

## Phase 1: Record setup checks and expose the scale wait

Read `lib/setup.sh:step6_start()`, `step6_checked()`, `setup_step6()`,
`step6_check()`, `step6_scale()` and `setup_plan()`. Read
`lib/vm.sh:vm_exec()` and `event_record()`, `lib/ui.sh:ui_setup_next()` and
`cmd_ui_job_worker()`, and the step 6 cases in `test/setup.bats`.
The existing QML can ignore the added fields at the end of this phase.

Write these failing Bats cases first in `test/setup.bats`:

- `redesign checks: each probe records only outcomes it actually observed`.
- `redesign checks: agents require SPICE, clock and allow-list success`.
- `redesign checks: wrong IDD and allow-list answers record failure before Drivers`.
- `redesign checks: waiting and timeout name the missing component`.
- `redesign checks: Continue clears check detail but RESET preserves the attempt`.
- `redesign checks: malformed or unwritable detail never creates a false Done`.
- `redesign countdown: default and overridden limits keep the actual scale start`.

Extend existing fake QMP, client-log and QGA fixtures through their current
knobs. Check intermediate publication during a blocked fake call, not just its
final reply. Keep tests for guest-boot, window-closed, idd-missing, agents, QMP,
wrong-build replacement, missing records and record-write failures.

Add one runtime file, `$RUN/step6-checks.json`. Use a small writer in
`lib/setup.sh`, `step6_checks_write()`, with a private mktemp file and atomic
rename, following `step6_stamp()`. Store:

| Field | Meaning |
|---|---|
| `since` | Numeric `step6-since` value for this check attempt. |
| `location` | Configured storage location checked during this attempt. |
| `invocation` | Current VM unit invocation. |
| `idd`, `spice`, `clock`, `allowlist`, `scale` | Each has `state` in `not_checked`, `waiting`, `done`, `failed`, plus a fixed `reason` code where needed. |

Publish only known keys and reason codes. Store no guest strings or translated
prose. `step6_start()` removes the detail file along with the current stop,
QMP-failure and checked markers. It starts a fresh attempt at VM start or Continue
after a stop. Preserve all records across `event_record()`'s ignored RESET.
No timer or new check runs from `cmd_panel()`.

Instrument the existing control flow, in place. Publish Waiting just before a
probe runs or while its answer is unavailable. Record the IDD match or mismatch
from `version_check()` only for the pinned client. Record the SPICE port, clock
reply and refusal separately. Record an allow-list violation as Failed and call
the existing `setup_back5()`. Missing answers stay Waiting until their existing
timeout, then become Failed with the actual reason. Do not infer outcomes for
checks skipped by an earlier return. A QMP or startup wait can name its cause
without claiming a later component ran.

Keep the two existing deadlines unchanged. `step6-checked` is written with
`EPOCHSECONDS` after the earlier calls pass. It remains the combined proof that
IDD and all agents passed. During the scale wait, retain those successes and
query only the scale port, as today. Publish scale Waiting or Done from
`step6_scale()`. A detail write failure returns the existing `reason:record`
failure and stops the attempt. It must not complete setup with missing evidence.

Add a read-only `step6_checks_read()` helper. Reject malformed, foreign-location,
foreign-invocation or old-attempt details. A valid current `step6-checked` can
supply the two combined Done rows when detail is absent, including an attempt
started by older code. Without that combined record, absent detail means Not
checked. An inconsistent detail record never overrides the combined proof.

Expose from `setup_plan()` the accepted check facts and raw scale-wait timing:
`checks`, `scale_started_at`, `scale_limit_seconds`. Read timing without calling
`step6_since()`, which can write. Validate finite positive integer timing before
exposing it. Invalid timing is null. Use the effective `LANAI_SETUP_SCALE_LIMIT`,
not a hard-coded 120. These fields do not decide completion.

Focused checks: `bats test/setup.bats test/lifecycle.bats test/panel-jobs.bats`.
Then run the shared checks. Confirm that all existing timeout boundaries and
ten-second worker spacing still pass.

Phase 1 implementation is complete. Shared validation remains blocked by an
existing spike test in this sandbox. The seven new cases failed before the
implementation and passed after it. The focused command passed all 175 cases,
including the timeout boundaries and worker spacing. Two additional window
failure and client replacement checks passed.

The shared run passed QML lint with its existing warnings. Bats reported 821
passes and 79 skips, but stalled after omitting one expected result. The run
was interrupted and exited 1 with `Executed 900 instead of expected 901 tests`.
It omitted `disk_locked: live flock on btrfs shows in the real
/proc/locks`. Running that unchanged spike case alone without the Bats watchdog
reported one failure at `spike/test/lgtest.bats:190`: the acquired flock was not
visible to `disk_locked()` through this sandbox's `/proc/locks`. With the
watchdog enabled, that failure omits its result and stalls the run. The 79 skips were 76 cases
without `LANAI_TEST_BTRFS_DIR`, the pinned-source build without
`LANAI_TEST_LG_TARBALL`, one unavailable `strace` measurement and one missing
comma-decimal locale. Guest tests ran with `pwsh`.

The shared block stopped at Bats as required. Its full shellcheck command was
then run separately, along with shellcheck for the changed fake QGA fixture;
both passed. `git diff --check` passed. Runtime test files and diagnostic logs
remain under `/run/user/1000/lzi`; the failed shared run's temporary directory
was retained. No spec behaviour changed beyond this phase. The spike failure
needs an environment with working lock visibility before full acceptance.

## Phase 2: Add snapshot display data and restore identity

Read `lib/snapshot.sh:snapshot_valid()`, `snapshot_list()`, `image_operation()`,
`snapshot_restore()` and `restore_mark()`, `lib/image-proof.py:progress()` and
`activity()`, `lib/lanai.sh:cmd_snapshots()` and `cmd_restore()`, and snapshot
progress cases in `test/snapshot.bats` and `test/panel.bats`.
This phase follows phase 1 and leaves current QML fields available.

Write these failing Bats cases first:

- In `test/panel.bats`: `redesign snapshots: UTC rows are newest first and keep restore names`.
- In `test/panel.bats`: `redesign snapshots: counts exclude partial, foreign and invalid snapshots`.
- In `test/panel.bats`: `redesign restore: marker supplies the target without a panel job`.
- In `test/panel.bats`: `redesign restore: invalid or foreign targets use generic wording`.
- In `test/snapshot.bats`: `redesign progress: CLI restore keeps its validated target once resolved`.
- In `test/snapshot.bats`: `redesign progress: stale owner and lock records expose no target or percentage`.
- In `test/panel.bats`: `redesign progress: accepted totals distinguish unmeasured work from zero percent hashing`.

Keep `snapshot_list()` and the public `snapshots` CLI oldest first. In
`lib/panel.sh`, build `snapshots.items` from the current validated snapshot list.
Sort newest first and deduplicate identical names from the two snapshot roots,
using the same preferred identity as `snapshot_find()`. Each item has `name`,
`date`, `time`, `label`, `restore_label`, `confirm_label` and `warning`.
`name` is the unchanged UTC folder name passed to `restore`. Format real calendar
dates under `LC_ALL=C` and UTC. For example, `Oct 12, 2026` and `09:12 UTC`.
Validate the complete timestamp with a round trip. Do not normalize an invalid
date into another day. Use the raw name without an invented date if parsing
fails. Set `snapshots.count` from the valid unique items, not a directory count.
Retain `snapshots.names` and existing descriptor labels for the old panel.

Add `operation`, validated `total` and optional `target` to the accepted result
of `activity()`. Preserve `progress.label` and `progress.percent` exactly. In
`snapshot_restore()`, after resolving and validating `snap`, export its basename
as `LANAI_IMAGE_TARGET` within `image_operation()`'s subshell. Have `progress()`
write that optional name on subsequent phases. The wrapper's first checking
record may have no target before snapshot resolution. `lib/ficlone.py` does not
write progress and needs no change. Accept target metadata only after the existing live-owner and held-lock
checks. A missing target must not invalidate otherwise valid old progress.

For an active restore, use its accepted progress target first. Otherwise use the
current active restore job's literal argument, or its matching
`restore-in-progress` record when the argument is absent. The marker contains
the snapshot path on line one and storage location on line two. Verify its
storage and snapshot identity with existing snapshot validation. Do not use an
ended job or another storage location. When no valid source supplies a target,
say Restoring Windows or Unfinished restore. Do not fabricate a date.

Add `restore: {pending, name, label, warning}` to the panel view. `name` is null
when unknown. Keep progress top-level so snapshots and CLI operations also show
it. Leave the operation lock, disk locks, stale-progress checks, interrupted
restore block and `cmd_restore()`'s `setup_reset()` untouched.

Focused checks: `bats test/snapshot.bats test/panel.bats test/lanai-copy.bats`.
Then run the shared checks. Run the btrfs cases with the configured test directory
before closing implementation of this phase.

Phase 2 adds validated, unique snapshot rows in newest-first order, UTC display
labels and restore identity from accepted progress, an active job or a matching
unfinished-restore marker. The public snapshot list and old panel fields remain
available. Progress retains its existing labels and percentages and adds the
operation, accepted total and optional validated target. Each image operation
clears inherited target metadata before its first checking record.

All seven named cases failed before implementation and passed afterward. The
additional assertions cover invalid calendar dates and normalized hours, target
precedence, ended jobs, old progress records, malformed targets and totals, and
stale ownership. The focused command exited successfully across 250 cases:
174 passes and 76 skips (75 without a usable btrfs fixture and one unavailable
`strace` measurement). QML lint passed with its existing warnings.

The shared run reported 828 passes and 79 skips, then stalled after the final
case with one of 908 results missing. The omitted case was the unchanged spike
test `disk_locked: live flock on btrfs shows in the real /proc/locks`. Running
it alone without the watchdog failed at `spike/test/lgtest.bats:190`: the held
flock was invisible through this sandbox's `/proc/locks`. The shared run was
interrupted with exit 130. This is not a successful full-suite result. Its
skips were 76 cases without `LANAI_TEST_BTRFS_DIR`, the pinned-source build
without `LANAI_TEST_LG_TARBALL`, the unavailable `strace` measurement and the
missing comma-decimal locale. Guest tests ran with `pwsh`.

The shared block stopped at Bats and retained its temporary directory. The
full shellcheck command passed separately, and `git diff --check` passed.
Diagnostic logs and runtime files
remain under `/run/user/1000/lzi/lr2.IacdQ0`; the shared test directory is
`/run/user/1000/lzi/lr.XqgMZO`. No review stage or commit ran in this delegated
phase. The orchestrator must rerun the full checks outside this sandbox.

The session requires every temporary directory to use a path under
`/run/user/1000/lzi`, which is tmpfs. A btrfs attempt used a runtime symlink to
the worktree's `.btrfs-test` fixture directory. Existing cases compare their
unresolved fixture paths with canonical storage identities, so that alias
caused path and SOURCE mismatches. The attempt was interrupted after 67 reported
cases: 51 passes and 16 failures. It does not provide btrfs acceptance.
Rerun the focused command with the real btrfs fixture path outside this
session's temporary-path restriction before closing Phase 2.

## Phase 3: Finish the backend presentation contract

Read all of `lib/panel.sh`, plus `lib/lanai.sh:status_map()`, `shared_facts()` and
`LANAI_LOGS`, `lib/ui.sh:cmd_settings()` and `panel_records()`'s consumers.
Read phases 1 and 2's added fields. Extend `test/panel.bats` and `test/ui.bats`.
Do this before any QML consumer changes.

Write these failing Bats cases first in `test/panel.bats`:

- `redesign header: daily saved values include scale in Failed`.
- `redesign setup: Check through Verify map six steps and completion has no seventh step`.
- `redesign setup: Prepare covers 3a and client build with their actual guidance`.
- `redesign verify: checklist labels and aggregate states follow actual outcomes`.
- `redesign countdown: active worker exposes remaining duration and stopped work hides it`.
- `redesign logs: every available row has exact copy text and a short display name`.
- `redesign settings: baseline and Save Saved Reset Unsaved words come from backend`.
- `redesign bar: failure attention busy active stopped priority and Drivers exception`.
- `redesign bar: setup timeout and user prompts request attention despite unsuccessful replies`.
- `redesign actions: every existing guard survives the presentation choice`.

For both `3a` and `4`, the Prepare test asserts `setup.number` is 4,
`setup.name` is Prepare and `setup.step_line` is Step 4 of 6. Assert the header
uses that step line while the card keeps each decision's title and guidance.

Add fields to `cmd_panel()` after its current decisions. Use small local jq
functions or Bash formatting helpers in `lib/panel.sh`; avoid a second facts
pass. Keep all changed wording there.

| Field | Contract |
|---|---|
| `header` | `{title, meta, badge}`. Title is Windows. Daily meta formats saved memory, cores and scale, including Failed. Setup meta uses Step N of 6 and the step name. A timeout adds the actual status label. Missing settings do not become invented defaults. |
| `layout` | `daily`, `failed`, `restoring`, `setup`, `setup_verify` or `setup_timeout`. Derive it from actual status, setup decision, accepted operation and current result. A stale failed reply does not override a newer attempt. |
| `primary_action` | Existing button key or null. Choose from the already computed descriptors. QML never makes a hidden action primary. Keep other offered controls reachable. |
| `sections` | `{settings, snapshots, logs, default}`. The first three fields hold row labels. `default` is empty or a section key. Failed defaults to logs. Settings always remains available. Preserve `snapshots.show`. |
| `settings.baseline`, `settings.labels` | Baseline is `{memory_gib, cores, windows_scale}` from saved settings. Labels is `{memory, cores, scale, save, saved, reset, unsaved}`. Keep existing values, notes, error and complete scale choices. No usable baseline on a settings read failure. |
| `setup.number`, `setup.name`, `setup.step_line`, `setup.steps`, `setup.title` | Map 1 Check, 2 Packages, 3 Snapshot, 3a and 4 Prepare, 5 Drivers, 6 Verify. Both `3a` and `4` expose number `4`, name `Prepare` and step line `Step 4 of 6`. `setup.steps` contains six `{number, name, state}` entries with current/complete/pending states derived from the decision. Keep `setup.title` and existing `setup.lines` specific to storage or client preparation. A finished plan returns the daily header and no current step. |
| `setup.checks` | Three rows `{id, label, state, status, detail}` for Display driver, Windows agents and Scale task. States are `not_checked`, `waiting`, `done`, `failed`; status strings are Not checked, Waiting, Done and Failed. Agents is Done only when SPICE, clock and allow-list passed. Details name waiting or failed components. |
| `setup.countdown` | Null or `{started_at, limit_seconds, remaining_seconds, label}`. A duration, not a clock time. Only a current step 6 setup worker actively following the scale wait can expose it. |
| `logs.rows` | Ordered `{id, label, display, copy_text, copy_label}` entries. IDs are `vm`, `client`, `build`, `job`, `command`; labels are VM, Window, Build, Jobs, Actions. Add backend success and failure copy wording. |
| `bar` | `{mode, percent}` with mode `failed`, `attention`, `busy`, `active`, `stopped`. Use accepted `progress.percent` only when `progress.total > 0`, including zero percent at the start of hashing. Otherwise percent is null. |

For the countdown, require the current setup worker, matching invocation, a
valid current `step6-checked`, setup step 6, scale Waiting and no stopped marker
or timeout. Return `max(0, limit - (now - started))`. Reject future, malformed or
missing timing. Reopen and shell restart only reread it. RESET changes nothing.
An expired duration shows zero until the backend resolves the wait. Continue
after a stopped attempt uses phase 1's fresh checks and scale stamp.
Replace fixed "within 2 minutes" panel wording with wording based on the
effective limit or guidance without a false duration. Keep timeout causes,
both retry paths and the `setup.cmd` stop condition.

Use `$LANAI_LOGS` verbatim for the VM copy text. It currently contains
`journalctl --user -u lanai-vm`. Use full current paths for client.log,
build-client.log, panel-job.log and panel-run.log. Omit a file row when its path
cannot be resolved or its log file is unavailable. Never create a log to make
it copyable. Keep old `logs.vm`, `client`, `build`, `job`, `command` strings until
the renderer moves to rows. Update fixtures to create the logs they offer.

Build bar priority from status, current failures, unfinished recovery, setup
attention, accepted progress and current jobs. A normal Drivers wait means
`setup_plan().action == setup-wait`, Windows active and no error or recovery
request. Render it active even if a worker is held or setup requests attention.
Outside that exception, choose failure, attention, busy, active, stopped in that
order. Not installed, in use and version mismatch request attention. A sign-in
wait may request attention while its worker runs. Ignore successful, stale and
superseded results when deciding failure. An unsuccessful setup reply alone
does not mean failure. SetupTimeout, package installation and the snapshot
decision request attention even with a current `ok:false` setup reply. Keep
independent failures and unfinished recovery at failure priority. Keep
right-click decisions and all tooltip fields unchanged.

In the guard matrix, test daily Start and Open beside pending updates; first
setup and final-check boots; starting and stopping; setup reopen versus a basic
window; shutdown arming and two-minute force-stop delay; unfinished recovery;
both VMs stopped; missing helpers; failed status reads; interrupted jobs and
launch failure. Assert `buttons.*.show`, `enable`, `confirm` and hints, not just
the selected layout. Do not weaken guards to match a board.

Focused checks: `bats test/panel.bats test/ui.bats test/panel-jobs.bats`.
Then run the shared checks. Review the resulting JSON for all ten boards before
starting phase 4.

Choose layout in this order: an active restore or unfinished restore, a current
setup timeout, the current unfinished setup card, daily Failed, then daily.
An unfinished restore still exposes setup guidance and recovery. A new setup
attempt supersedes an older timeout. Keep daily controls beside pending updates
where the existing descriptors allow them, regardless of the chosen card.

## Phase 4: Rebuild the daily panel and detail sections

Read `LanaiPanel.qml` completely, `LanaiModel.qml:control()` and `run()`,
`test/panel-qml.bats`'s inert imports and phases 2 and 3's view contract.
Read the installed components listed above. Compare Main, Stopped, Restoring and
Failed. This phase follows all backend phases.

First add these failing QtTest functions inside `test/panel-qml.bats`:

- `test_redesign_header_uses_saved_view_and_theme_roles`.
- `test_redesign_only_one_detail_section_opens_and_failed_defaults_to_logs`.
- `test_redesign_all_offered_controls_remain_reachable`.
- `test_redesign_restore_dates_identity_cancel_and_invalidated_target`.
- `test_redesign_progress_stays_above_actions_for_snapshot_and_restore`.
- `test_redesign_focus_reveals_expanded_rows_and_notice_covered_controls`.

Extend the existing TestUi and TestCommons stubs only for APIs actually used:
PanelHero, PanelActionButton, BorderSurface, Border and added Style/Color roles.
Keep Process inert and retain actual Qt Quick controls for editable values.
Do not replace behaviour assertions with text searches. Find new controls by
stable `objectName` values and backend control keys rather than translated
labels. Existing tests that activate a hidden detail control must open its row
first. Keep coverage for every original command and confirmation.

Extend both the initial and failed-poll views in `LanaiModel.qml` with safe empty
values for the new objects and arrays. A failed poll uses Failed presentation,
an error bar mode, Logs as its default detail and the existing read-failure
guidance. It offers no action without a backend descriptor. Test an invalid JSON
poll and a nonzero status exit, including recovery on the next valid reply.

Render PanelHero, primary action and compact shutdown/more actions. Use an
inline expanding action area for more actions, built from existing descriptors.
This avoids a separate popup and its extra focus lifecycle. It must expose
Force stop only when offered, Dismiss notice, setup recovery and the client
update. Render each descriptor's hint when a disabled action needs explanation.
Keep causes, next steps, warnings, results and launch errors readable above or
beside their relevant controls. A dropped-click notice never replaces them.

Use one string `expandedSection`, with values empty, settings, snapshots or
logs. Clicking the open row closes it. Opening another closes the first without
resetting drafts. Apply the backend default on panel open and when entering a
new Failed state, not on every poll. Give toggles an accessible expanded state.
Keep Settings on all setup layouts and preserve `snapshots.show`.

Render newest-first `snapshots.items`, count and date/time. Use `item.name` for
`restoreArmed` and literal restore argv. Render backend confirmation wording and
loss warning. Disarm on Cancel, panel close, a removed target or loss of restore
permission. Preserve the unfinished restore action and the ability to choose
another valid snapshot. Keep the accepted progress meter, target label,
`progress.label` and stopped-Windows warning above actions, even when Snapshots
is collapsed. Show a snapshot's progress there too.

Preserve mutual exclusion of `stopArmed` and `forceArmed`, separate confirming
clicks, their warnings and Cancel. Clear confirmations on panel close and on
backend changes that invalidate them. A click that changes expansion must never
confirm a destructive action. Keep setup's two display options and arming rules
reachable until phase 6 changes their layout.

Keep `reveal()` and the Flickable's bottom margin. Invoke reveal after expansion
layout settles and on focus for every row, menu action, field, confirmation and
copy control. Preserve the opaque pinned notice and its absorbing MouseArea.
Add a keyboard-focusable dismiss control with a backend name. Closing the panel
still clears it. Keep all two-second and five-second notice tests and duplicate
job suppression tests intact.

Focused checks: `bats test/panel-qml.bats test/panel.bats`.
Then run the shared checks. On inert fixtures, tab forward and backward through
all expanded sections at a small height with the notice visible. Confirm no
covered action fires on notice dismissal.

## Phase 5: Implement Settings drafts and reliable log copying

Read `LanaiPanel.qml`'s draft inputs, `scaleTouched`, dropdown binding and
`onSettingsSaved()`. Read `LanaiModel.qml`'s action completion and
`lib/ui.sh:cmd_settings()`. Use phase 3's baseline and log rows. Compare Settings
and Failed. Do not change the settings CLI or scale timing.

Add these failing QtTest functions in `test/panel-qml.bats` first:

- `test_redesign_clean_settings_show_disabled_saved_only`.
- `test_redesign_reset_is_local_and_restores_latest_saved_baseline`.
- `test_redesign_drafts_survive_polls_sections_and_failed_saves`.
- `test_redesign_scale_selection_is_dirty_even_when_unchanged`.
- `test_redesign_success_clears_dirty_but_keeps_scale_save_intent`.
- `test_redesign_copy_uses_literal_stdin_and_reports_each_rows_exit`.
- `test_redesign_copy_failure_can_retry_and_cannot_run_the_vm_command`.

Retain `memoryInput`, `coresInput`, `windowsScaleInput` and `scaleTouched`.
Add `scaleDirty` for a selection made since the last successful save. Set both
flags for every Dropdown `changed`, including selecting its current entry.
Unsaved is draft values differing from the saved baseline, or `scaleDirty`.
Do not use `scaleTouched` alone for Unsaved. Successful saves clear `scaleDirty`
and update the saved baseline from the accepted saved values. They keep
`scaleTouched`. Reset and panel reopen clear both flags.

Read the latest valid backend baseline on open and Reset. Keep local drafts
detached from polls after editing. Later baseline polls may update Reset's
target and dirty comparison but must not replace drafts. Ensure the successful
save response updates the local baseline before a refresh arrives. Keep memory
and cores within 1–512 and 1–64. Render every backend scale choice through 500%.
Preserve the Dropdown value binding repair and focused-field reveal.

Show disabled Saved and hide Reset and Unsaved when drafts match and there is
no scale intent. Otherwise show Save and Reset, subject to the existing backend
save guard. After a successful scale save, show Save and Reset without Unsaved.
Another save still passes the third scale argument. With an untouched list,
pass only memory and cores and leave scale and its save number untouched.
Keep existing failed-save retention and successful-response reconciliation.
Reset sends no command and restores no defaults. A read failure disables saving
and resetting without inventing a baseline. Keep scale timing and old-task
warnings beside the list.

Add `copyLog(id)` and per-row feedback to `LanaiModel.qml`. Look up the current
backend row by id. Start a separate `Quickshell.Io.Process` with literal
`command: ["wl-copy"]`, `stdinEnabled: true`; on start, write `copy_text` with
`write()` and set `stdinEnabled = false` to close input after the queued text.
Set it true again before each retry. The installed
`/usr/lib/qt6/qml/Quickshell/Io/quickshell-io.qmltypes` exposes `started`,
`write`, `stdinEnabled` and `exited(exitCode, exitStatus)`; it exposes no
`closeWriteChannel()` method. Validate the implementation with `test/qml-lint`.
Copy exact bytes with no added newline. Do not use `bash -c`, detached execution,
or `run()`. The copy command must never execute the journal command it receives.
`wl-copy` is already the shell's clipboard command. If it cannot start, show
the backend inline failure wording.

Capture the in-flight row id and copy text so a poll cannot misattribute the
completion. Update that row only on successful process exit; show Copied.
On nonzero or crash exit, show an inline error and leave its button retryable.
Cover failure to start separately: it must clear the in-flight row and show an
error even if no `started` or `exited` signal arrives. Track whether the process
started, and defer a stopped-process fallback until normal exit handling has
had a chance to run. Test the missing-executable path with the inert Process.
Permit one copy process at a time and explain transient disabled copy controls.
Do not alter VM action suppression or create a panel result file for copying.
Clear old feedback on reopen or when a row's target changes. Extend the inert
Process stub to capture stdin and model normal, failed and crashed completion.
No test writes John's clipboard. Give every copy icon a backend accessible name,
visible focus and `reveal()`.

Focused checks: `bats test/panel-qml.bats test/ui.bats test/panel.bats`.
Then run the shared checks. Verify two successive unchanged-scale saves and a
Reset followed by a memory-only save through the real settings fixture.

## Phase 6: Render setup cards, checks and countdown

Read phases 1 and 3's setup fields, `LanaiPanel.qml`'s existing setup controls and
`test/panel-qml.bats`'s setup tests. Compare SetupSnapshot, SetupDrivers,
SetupVerify and SetupTimeout, then use the same card layout for Check, Packages
and Prepare. This phase consumes finished backend fields; it adds no probes.

Add these failing QtTest functions in `test/panel-qml.bats` first:

- `test_redesign_all_six_setup_steps_and_prepare_substep_render`.
- `test_redesign_setup_headers_override_running_settings_and_finish_returns_daily`.
- `test_redesign_snapshot_skip_keeps_backup_and_filesystem_advice`.
- `test_redesign_drivers_guidance_follows_worker_and_keeps_shutdown`.
- `test_redesign_verify_renders_actual_partial_checks_and_conditional_signin`.
- `test_redesign_countdown_reopen_preserves_deadline_and_hides_invalid_timing`.
- `test_redesign_timeout_keeps_continue_and_both_stopped_display_choices`.

Show Windows, Setup badge, backend step line and a six-entry step strip. Use
backend labels and states. Keep it readable on a narrow screen without making
step names navigation controls. SetupTimeout includes the actual VM status.
Never display Step 7 of 6. Keep Settings and permitted Snapshots reachable on
every card, including boards that omit them.

Use a shared inline setup card for title, guidance and offered actions. Snapshot
offers its snapshot or explicit backup skip. Drivers names the setup drive and
`setup.cmd`. With a following worker, explain the shutdown and check boot.
Without one, name Continue setup. Preserve stop-if-hung and share-check guidance,
Reopen the Windows window where guarded, setup shutdown confirmation and Cancel.

Verify repeats `setup.checks`. Show Not checked before a probe, Waiting while
pending, Done after success and Failed after failure. Include component detail.
Do not infer Done from step-strip completion. Sign-in guidance is conditional on
the backend scale wait and cannot claim which user or screen is visible.
Render the provided remaining seconds as a duration `m:ss`. A one-second timer
may interpolate between polls from the backend remaining value and local elapsed
time, clamped to zero. Re-anchor it on each valid poll. It never changes backend
state, restarts a deadline, declares timeout or completes setup. No valid timing
means no countdown.

Timeout renders the failed check and actual cause. Continue setup checks again.
When Windows is stopped, expose both guest-install display choices directly,
with the existing literal mapping: basic window is `setup --window`; Windows
window is `setup --no-window`. Keep Run setup again's separate arming step on a
finished install. Wrong IDD or allow-list answers render Drivers and recovery,
not SetupTimeout. Keep waiting-for-shutdown guidance and the `setup.cmd` stop
condition. Preserve per-group results and error text across all cards.

Focused checks: `bats test/panel-qml.bats test/setup.bats test/panel-jobs.bats test/panel.bats`.
Then run the shared checks. In fixtures, recreate both panel and model during a
scale wait, deliver the same backend deadline and check the remaining duration.
Use backend tests for shell restart, RESET and fresh Continue semantics.

## Phase 7: Render bar states and preserve shortcuts

Read `Widget.qml`, `LanaiModel.qml:tooltip`, phase 3's `bar` fields and the
installed BarIconButton and WidgetButton APIs. Compare BarStates. Keep the
L-in-a-monitor drawing in its existing custom icon slot.

Write these failing tests first:

- In `test/panel-qml.bats`: `test_redesign_bar_modes_render_theme_badges_and_underlines`.
- In `test/panel-qml.bats`: `test_redesign_busy_without_progress_animates_a_fixed_segment`.
- In `test/panel-qml.bats`: `test_redesign_bar_shortcuts_and_failure_panel_requests_survive`.
- In `test/panel.bats`: `redesign bar: Drivers active exception never hides failure or recovery`.

Import `qs.Commons as Commons` in Widget and bind colours to the theme.
Stopped uses normal foreground. Active uses accent and a full underline,
including starting and stopping. Busy uses the backend percentage for its
underline only when non-null. Otherwise animate a fixed-width segment without
a number. Attention and failure add distinct badges and accessible tooltip
words using accent and urgent. Render the backend priority as supplied; do not
rederive setup or failure decisions in QML. Keep `button.active` tied to the
backend active flag, and explicitly choose glyph colour from `bar.mode` where
the shell's default active colour would conflict with it.

Keep left-click and Return, keypad Enter, Space and Menu toggles in every state.
Keep `rightClick()`'s literal guarded Start/Open or panel fallback. Keep warnings,
notices and the actual right-click action in the tooltip. Keep failed shortcuts
and forced-stop reports opening the panel through `panelRequested()`.
Stop busy animations when their mode ends. Use `Style.duration()` and existing
slot sizing. Do not add percentages for setup checks or sign-in waits.

Focused checks: `bats test/panel-qml.bats test/panel.bats test/ui.bats`.
Then run the shared checks. Exercise the priority matrix with and without a
worker, including normal Drivers, sign-in wait, SetupTimeout with Windows active
and stopped, package and snapshot prompts, missing install, another VM,
version mismatch, failed reads and unfinished restore. Check that independent
failures still override setup attention.

## Phase 8: Acceptance fixtures and documentation

Read `README.md`, `CLAUDE.md`'s Layout section, the redesign spec and this plan.
Read the complete implemented panel view and QML tests. This phase follows all
production changes and documents the behaviour that passed acceptance.

First add a Bats integration case in `test/panel-qml.bats` named
`QML redesign: all ten board views render from backend fixtures`. Generate the
ten real `cmd_panel()` JSON views using isolated panel fixtures, then load them
through the inert renderer. Its first run must expose any remaining mismatch
between the actual backend view and renderer. Reuse the existing fixture
functions and import stubs rather than adding a second renderer. Cover Main,
Settings, Stopped with a restore armed, Restoring, Failed, SetupSnapshot,
SetupDrivers, SetupVerify, SetupTimeout and the BarStates matrix. Assert the
critical fields and permitted controls for each board. Include failed-read and
invalid-timing views so the renderer's empty defaults cannot conceal bad data.

If the integration passes on its first run, record that result. Do not manufacture
a failure by omitting test plumbing or adding a production hook just for tests.
Use fixture files under `test/fixtures/panel-redesign/` only if the handoff needs
them. Generate state-dependent values from the backend instead of committing
copied placeholder replies. Keep all service, process and clipboard effects
inert. Extend fixture support until this integration passes, then run
`bats test/panel-qml.bats test/panel.bats` and the shared checks.

Compare the rendered boards under two existing Omarchy themes in a disposable
shell session or a separate test machine. Use the installed shell components.
Record theme names, panel size, screenshots and results in this plan's acceptance
notes above Review log. Test every spec acceptance row: daily controls, all
sections, draft/reset/save states, log copy success/failure/retry, named restore
and recovery, setup checks and timing, bar states, small-screen keyboard focus
and notice click absorption. Measure no invented progress. Any real VM rehearsal
uses an explicitly configured separate test copy. John performs live acceptance
only after that rehearsal. If a visual or VM check cannot run here, record it as
pending for John and do not claim acceptance.

Update these documents:

- `README.md`: divided detail rows, more actions, saved header values, Reset and
  Unsaved, persistent scale intent after save, exact log copying and retry,
  readable UTC snapshots, restore target/phase/progress, six setup steps,
  checklist meaning, conditional sign-in duration and bar states. Keep current
  shutdown guards, setup.cmd recovery, memory/CPU limits and scale timing.
- `CLAUDE.md`: describe the runtime check detail and any test fixture directory
  in Layout. Keep the three QML responsibilities accurate. Change layout notes
  only for files actually added. Preserve rules and test commands.
- `docs/plugin/redesign/spec.md`: retain approved requirements and its review
  history. Add factual acceptance evidence or agreed clarifications only.
- `docs/plugin/redesign/plan.md`: mark phases completed with focused and full
  check outcomes, skips and pending manual checks. Record deviations against the
  spec. Keep review entries for the orchestrator to supply.

Use short sentences and active voice. Use no em dashes. Check links and file
names with `rg --files`, then run `git diff --check`, `test/qml-lint` and
`BATS_TEST_TIMEOUT=120 bats test spike/test` with the shared runtime TMPDIR setup.
Do not add documentation-only tests that merely pin prose.

Plan authoring checks: `test/qml-lint` passed with the existing var-hoisting and
model-id warnings. The baseline full Bats run was stopped after fake socket
creation failed. A direct Unix socket bind also failed with
`PermissionError: [Errno 1] Operation not permitted` in this sandbox. Rerun the
full suite in an environment that permits Unix sockets before implementation
acceptance. No production files changed while writing this plan.

## Review log

| Gate | Stage | Round | Findings | Notes |
|---|---|---|---|---|
| Plan | a (gpt-6.1-sol) | 1 | 1 | 1 confirmed (P2): checks block now fails fast |
| Plan | a (gpt-6.1-sol) | 2 | 0 | clean |
| Plan | opt Grok (grok-4.6) | 1 | 2 | 2 confirmed, 0 refuted, 0 nit, 0 could not verify; Clarified attention preserved durable boards |
| Plan | opt Grok (grok-4.6) | 2 | 1 | 1 confirmed, 0 refuted, 0 nit, 0 could not verify; Exposed totals distinguish measurable progress |
| Plan | opt Grok (grok-4.6) | 3 | 1 | 1 confirmed, 0 refuted, 0 nit, 0 could not verify; Mapped storage substep to Prepare |
