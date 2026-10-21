# Stopped panel text cut

Small tier: one combined spec and plan. It extends the Main board text cut in
[plan.md](plan.md) (Follow-ups) to the stopped panel and to busy lines.

## Problem

The daily panel with Windows stopped shows text that repeats the header and
buttons. John's screenshot of a running snapshot on October 20, 2026 showed,
above Start Windows:

- "Windows is stopped", which repeats the Stopped badge.
- "Windows is ready to start." and "Click Start Windows.", which repeat the
  button and are false while a job keeps Start disabled.
- "You can close this panel.", which is true of every menubar panel.

Below Start Windows, it showed the hints of the two disabled "Set up in…"
choices in More actions. They describe those choices, not why Start is
disabled. The setup card still shows them under the choices, and nothing can
be done with a disabled choice anyway. After a snapshot, the Snapshots section
also shows "Snapshot saved." above a list that already has the new snapshot
first.

The Stopped board in `mockups/Stopped.dc.html` shows only the header, the
badge, Start Windows and the section rows; More actions sits beside Start
Windows on the Main board.

A running restore has a worse version of the same problem. The restore writes
its unfinished-restore marker when it starts, so while it runs the panel says
"A restore did not finish, so Windows cannot start.", which is false. The
Restoring board shows no status lines.

## Requirements

1. In the daily layout with Windows stopped, the panel shows no status lines
   (headline, cause, next) and no disabled-action hints below the buttons.
   This is the same rule that the running state already follows. Start Windows
   gets no added tooltip.
2. No busy line says "You can close this panel.". A busy line that has another
   sentence keeps it, for example "Taking a snapshot.", "Checking Windows." or
   "Updating the Windows window. This may take several minutes. You can start
   Windows when it finishes.".
3. While a job shows its progress line and bar, the panel shows no busy line.
   A restore never shows a busy line, with or without progress: its target
   line and "Keep Windows stopped until the restore finishes." already show,
   as on the Restoring board.
4. The Snapshots section drops "Snapshot saved.". Show details, the saved
   path, Copy and the disk space advice stay as they are.
5. While a restore runs, the panel shows no status lines and no
   disabled-action hints either; its target line, progress and warning say
   what is happening. An unfinished restore that is not running keeps both,
   because they say what to do.
6. Nothing else changes. The other states and layouts keep their status lines.
   Notices, warnings, results, failures and the setup flow stay visible.

## Acceptance

- Panel view tests (`test/panel.bats`) check the busy lines: for each job
  command and the setup step 5 and step 6 replies, the busy line does not
  contain "You can close this panel."; a snapshot with progress has an empty
  busy line, a delete job shows "Deleting a snapshot.", and a restore, with or
  without progress, has an empty busy line while its restore warning shows.
- QML renderer tests (`test/panel-qml.bats`) check that the stopped daily
  panel shows no status lines and no disabled-action hints, both idle and
  during a job. They also check that the Snapshots section has no "Snapshot
  saved." note but keeps Show details and the path, and that a state outside
  the daily layout, such as failed, still shows its status lines. A starting
  daily panel also keeps its status lines, to pin the edge of the wider quiet
  rule.
- A renderer check shows that a running restore has no status lines and no
  disabled-action hints, and an unfinished restore that is not running keeps
  both. The idle Stopped board has no disabled hint today, so the failing hint
  check is on the `Bar-busy` boards; the idle check is a guard.
- Panel view tests check `restore.active`: true for a held restore job without
  progress, false for an unfinished restore with nothing running. A pending
  Finish click over an interrupted, unended restore record shows "Starting the
  operation.".
- The stopped, starting, failed and restore checks run on the real backend
  boards in `test_backend_boards` (`Stopped`, `Bar-busy-0`, `Bar-busy-100`,
  `Bar-activating`, `Failed`, and the restore boards), so the backend and QML
  are checked together. The "Snapshot saved." check runs on the synthetic view
  in `test_main_keeps_routine_copy_out_of_collapsed_panel`, because no backend
  board has a saved snapshot.

## Plan

1. Tests first. Change the existing busy-line and saved-summary assertions in
   `test/panel.bats` and `test/panel-qml.bats` to the new behavior. Add new
   `test/panel.bats` cases for the job-only busy lines, which no test covers
   today: a held delete job, a held restore job without progress, and the loop
   over every job command and setup reply. Add the board checks named in
   Acceptance to `test_backend_boards`. Run them and see them fail.
2. `lib/panel.sh`: in the `busy` view, return an empty line when progress is
   shown, and while a restore runs. Use the condition that drives `$restoring`
   and `panel_restore`'s active flag (progress operation is restore, or a held
   job whose command is restore), moved above the view object, not the unheld
   `$job.command`, so a pending launch over a stale record shows "Starting the
   operation.". Delete the `restore` key from the no-progress busy table: with
   the new condition it is reachable only in that pending case. Expose the
   flag as `restore.active` in the view. Remove "You can close this panel."
   from every busy line. Remove `summary` from `snapshots.saved`, because
   nothing else reads it.
3. `LanaiPanel.qml`: make `quietMain` true in the daily layout for the stopped
   state too, and while `restore.active` is true. It hides the status lines
   and the disabled-hint Repeater. The Open window tooltip shows only while
   Windows runs, so it stays as it is. Remove the Note that shows
   `snapshotSaved.summary`.
4. Update the "Main board copy" and "Snapshots copy" bullets in Follow-ups in
   `plan.md`, and add a note to `docs/plugin/plan.md` that this doc supersedes
   the progress-line item that keeps "Keep Windows stopped until it finishes."
   and "You can close this panel." visible, and the update busy line quoted
   later in that plan. README text quotes none of the removed lines. Run the
   focused suites (`test/panel.bats`, `test/panel-qml.bats`,
   `test/panel-jobs.bats`), `test/qml-lint LanaiPanel.qml`, shellcheck on the
   CI set and `git diff --check`.

## Review log

| Gate | Stage | Round | Findings | Result |
| --- | --- | ---: | ---: | --- |
| Doc | a (gpt-6.1-sol) | 1 | 0 | Clean. |
| Doc | b single (opus-5.5) | 1 | 7 | Two should-fix and five nits. Integrated six: drop the duplicate restore busy line, fix the impossible delete-progress check, test on the real backend boards, name both stale Follow-ups bullets and the superseded plan item, correct the tooltip reason, and check a starting panel. Left one: "Show details" keeps its label, since it sits inside Snapshots. |
| Doc | b single (opus-5.5) | 2 | 6 | One should-fix and five nits confirmed: a running restore showed the false "A restore did not finish" status lines, now quiet; name the restore condition, the new job-only tests and the boards each check uses; fix the Stopped board description and the superseded plan lines. Integrated. |
| Doc | b single (opus-5.5) | 3 | 5 | Two should-fix and three nits confirmed: state that a running restore also drops disabled hints, delete the restore busy-table entry so a pending Finish shows "Starting the operation.", test `restore.active` directly, mark the idle hint check as a guard, and rewrap. Integrated; this round hit the three-round cap with nothing left open. |
