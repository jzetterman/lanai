# Panel redesign spec: Lanai

Tier: Full. Background: [plugin spec](../spec.md). The ten HTML boards in the
redesign mockups' `canvas.json` define the visual and layout target.

## Problem

The panel gives daily controls, setup, settings and recovery similar weight.
Users need a clear status, a next action and details they can open when needed.

## Requirements

1. Redesign `LanaiPanel.qml` and `Widget.qml` to match the boards. Keep the
   L-in-a-monitor mark, Windows header, status badge, primary action, compact
   secondary actions and divided Settings, Snapshots and Logs rows. Open one
   detail section at a time. Use the shell's own `qs.Ui` and `qs.Commons`
   components, fonts and spacing. Use `Commons.Color` theme colours throughout.
   The blue accent and Tokyo Night colours stand for the active Omarchy theme.
   Never copy the boards' hex colours. The surrounding desktop bar is context.
   Keep Settings on every setup layout, including boards that omit it.
2. Put changed wording in `lib/panel.sh`. It still decides what shows, what is
   enabled and what action the user should take. Keep causes, next steps,
   warnings, results and disabled-control explanations available. QML presents
   that view and keeps local edits, expansion and confirmation state.
3. Keep every existing control reachable when the backend offers it, including
   controls absent from a board:

   | Area | Existing controls |
   |---|---|
   | Windows | Start Windows, Open window, Shut down, confirm setup shutdown, Force stop, confirm forced stop, Dismiss notice |
   | Setup | Continue setup, Run setup again, Reopen the Windows window, Install in a terminal, take the setup snapshot, continue without one, choose the basic or Windows window, Cancel |
   | Settings | Memory, CPU cores, Windows scale, Save settings |
   | Snapshots | Take a snapshot, Finish the unfinished restore, restore each named snapshot, confirm replacement, Cancel |
   | Updates | Update the Windows window |

4. Preserve the existing guards. Board controls appear only when these guards
   allow them.

   - Start requires completed setup for the storage location, no other VM,
     no blocking work and no unfinished restore. First-time setup hides daily
     Start and Open. Working installs keep them beside pending updates, except
     during setup and final-check boots. Open requires a closed window and is
     disabled during shutdown. Setup can reopen a closed client window, never
     a basic window or one shutting down.
   - Shut down stays available during startup and shutdown. Stopping a setup
     boot needs an arming click and a separate confirming click, with the
     existing warning. An existing shutdown request needs no new confirmation.
     Force stop appears only after the backend's two-minute shutdown wait. It
     needs a separate confirmation that names lost work. Arming either stop
     clears the other. Both support Cancel.
   - Restore arms one named snapshot, warns that later changes will be lost,
     then needs a separate confirming click. Cancel disarms it. Closing the
     panel clears all confirmations. Backend changes clear confirmations that
     are no longer valid.
   - Run setup again first reveals the two display choices and Cancel. It
     requires Windows stopped. A final-check timeout with Windows stopped
     offers both choices directly. Continuing checks and repeating the guest
     install remain distinct actions. Wait for shutdown before continuing.
   - Snapshot and restore require both VMs stopped and keep the operation and
     disk locks. Unfinished restores block Start and new snapshots. Finishing
     that restore or choosing another snapshot remains possible. Snapshots
     show when Windows is stopped or daily controls are available, including
     first-time setup, even where a board omits the row. Settings remain available.
5. Keep Tab, Shift+Tab, Enter and Space working on every control. Give icon
   buttons names and visible focus. Escape closes the panel. Keep `reveal()`
   scrolling focused controls into view, including expanded rows and menus.
   Keep the dropped-click notice pinned, opaque and dismissible. It must not
   move controls or pass clicks through. Leave room to scroll covered content
   into view. Preserve its two-second minimum and five-second maximum, except
   for dismissal or panel close. Duplicate clicks must not launch another job.
6. Use real backend data for header settings, snapshot counts, dates, status,
   results and progress. The dates, 8 GiB, 4 cores, 42% and 1:24 are placeholders.
   Header settings show saved values, not unsaved edits or a claim about the
   running VM's allocation. Daily headers include scale on Failed too.
   Setup headers replace saved settings with the step line and Setup badge,
   even while Windows runs. SetupTimeout adds the actual VM status to that line.
   Keep memory at 1–512 whole GiB and cores at 1–64.
   Keep Match my monitor and every existing scale choice through 500%.
   Memory and cores apply on the next start. Keep the current scale timing,
   warnings about replacing a scale picked in Windows and about old scale tasks.
   Do not promise instant scale.
   Selecting any scale entry, including the current entry, makes subsequent
   saves scale saves until Reset or panel reopen. An untouched scale list
   leaves the saved scale and its save number alone.
7. Add backend setup step names and the line "Step N of 6". Use Check, Packages,
   Snapshot, Prepare, Drivers and Verify. The existing storage preparation
   substep 3a and client preparation belong to Prepare, step 4. Completion is
   finished, never step 7 of 6. Derive progress from the existing setup decision.
   Check, Packages and Prepare reuse SetupSnapshot's header, step strip and card
   layout with backend wording and permitted actions. Completion returns to the
   daily header.
   SetupSnapshot offers the snapshot or an explicit skip that requires a backup, with
   unsupported-filesystem advice. SetupDrivers tells the user to open the setup
   drive and run `setup.cmd`. Explain that Windows shuts down and Lanai starts
   it for checks; without a following worker, name Continue setup. Preserve
   the option to shut down if the script hangs or its share check asks for it.
8. Add readable snapshot dates from the existing UTC folder names, such as
   `20261012T091200Z`. Show date and time in UTC with the timezone stated.
   List newest first, as the boards do. Keep the original name as the restore
   identity. Count only valid snapshots for the configured storage location.
   Use these dates in restore confirmation and progress. The unfinished
   restore record supplies its target when no panel job record exists. If no
   valid target is available, show a generic restore label, never an invented date.
9. Add copy buttons for the VM, Window, Build, Jobs and Actions log rows. The
   backend must provide each row's label and exact copy text. Copy the existing
   user-journal command for the VM and the full current path for each file log.
   Omit unavailable paths. Short display names must not shorten copied text.
   Copy only; do not run the command. Show Copied beside the row on success.
   Show an inline error beside the row on failure and keep its copy button
   available for retry.
10. Add Reset and the Unsaved marker to Settings. The backend supplies the saved
    baseline and wording. Reset restores that baseline locally and clears scale
    selection intent; it saves nothing and does not restore defaults. Mark
    changed draft values or a scale selection made since the last successful
    save as Unsaved. Preserve drafts through polls, section changes and failed
    saves. A successful save clears the marker, but keeps the scale-save
    behaviour in requirement 6.
    When drafts match the baseline and there is no scale selection intent, show
    disabled Saved and hide Reset and Unsaved. Otherwise show Save and Reset,
    subject to backend guards.
    After a successful save with scale selection intent, keep Save and Reset
    available with no Unsaved marker. Another save remains a scale save.
    Do not disable Save just because a deliberately selected scale is unchanged.
    Reopening the panel discards edits and reads the current saved values.
11. Add the per-check list on SetupVerify: Display driver, Windows agents and
    Scale task. The current panel has no per-check list. Use the existing setup
    checks as its source: the pinned IDD build, SPICE agent, QEMU guest agent
    clock and allow-list checks, then the scale task's open port. Expose their
    actual outcomes. The backend currently exposes only a combined record that
    the earlier checks passed. It supplies both Done rows on the sign-in board.
    Any earlier detail must come from actual check outcomes, not the step number.
    Show Not checked before a check runs, Waiting while it awaits an answer,
    Done on success and Failed on failure. Windows agents is Done only when
    SPICE, clock and allow-list checks all pass. Name any waiting or failed
    component. Scale task stays Not checked until the earlier checks pass.
    Timeouts use SetupTimeout. Wrong IDD or allow-list answers return to Drivers
    with the cause and recovery actions.
    Done means checked during that attempt, not continuous health.
    An open scale port proves task startup, not applied scale or a visible desktop.
12. Add the sign-in countdown on SetupVerify. Expose when setup started waiting
    for the scale task and its effective `LANAI_SETUP_SCALE_LIMIT`, which defaults
    to 120 seconds. Show remaining duration as minutes and seconds, never below
    zero, only while the backend actively waits. Reopening the panel or shell
    must not restart it. A Windows restart resets no limit. Continue setup
    after a stop starts fresh checks and a fresh scale wait when they pass.
    Missing or invalid timing shows no invented countdown. The backend decides
    timeout and completion. Sign-in guidance is conditional: Lanai cannot see
    the sign-in screen or identify the signed-in user.
13. Restoring shows its target, phase, backend percentage and stopped-Windows
    warning above the actions. Use `progress.label` for the phase.
    Preserve progress for snapshots too, including CLI operations and panels
    opened midway. Ignore stale progress. Keep Start
    blocked through unfinished recovery. After restore, show the setup required
    for that disk. A busy notice does not replace operation errors or results.
14. Match BarStates: normal foreground when stopped, accent and underline while
    backend `active` is true, including starting and stopping, progress underline
    when busy, an attention badge for the user's turn and an error badge for
    failure. Not installed, in use and version mismatch request attention.
    Setup needed uses backend setup attention or busy while work runs.
    During the normal Drivers wait for setup.cmd with Windows active, show the
    active glyph even when setup attention or busy is true. Failures and recovery
    requests keep their priority.
    Use existing backend status, progress, setup attention and operation outcomes.
    A sign-in wait can request attention
    while its worker continues. Without measurable progress, show busy without
    an invented percentage: animate a fixed-width underline segment.
    Except for that Drivers wait, give failure priority over attention, then busy,
    then active, then stopped.
    Preserve tooltips with warnings, notices and the actual right-click
    action. Left-click and Return, keypad Enter, Space and Menu toggle the panel.
    Right-click uses the backend's guarded Start or Open, otherwise opens the
    panel. Failed shortcuts and forced-stop reports still open the panel.
15. Failed opens Logs and presents the actual cause and permitted recovery.
    Never offer immediate Force stop just because the board does. SetupTimeout
    names the check that timed out and offers Continue setup or, once stopped,
    either guest-install display choice. Keep the `setup.cmd` stop condition.
    Keep useful guidance for starting, stopping, missing or unsupported installs,
    another VM, driver mismatch, lost helpers, failed status reads, interrupted
    work and failed launches, even though the boards do not cover them.

## Acceptance criteria

Rehearse on fixtures or a separate test copy. Never use John's live install.

| Requirement | Check |
|---|---|
| 1–6, 10 | Compare Main and Settings with the boards under two Omarchy themes. Exercise all section toggles, settings edits and controls. Confirm theme colours, saved header values, disabled Saved with hidden Reset on clean load, Reset, Unsaved, unchanged-scale saves, failed saves and reopen behaviour. After a successful scale save, confirm Save and Reset remain available without Unsaved and another save is a scale save. |
| 3–5, 8, 13 | Compare Stopped and Restoring. Cancel and confirm a named restore. Check UTC dates, ordering and counts. Start stays blocked during work and unfinished recovery. CLI progress and reopening midway show the same operation. Recovery and setup remain reachable. |
| 2–5, 9, 15 | Compare Failed and SetupTimeout. Copy every available log target exactly. Check Copied feedback, a simulated copy failure's inline error and a successful retry. Check every failure reason, both retry paths, shutdown confirmation, the force-stop delay, confirmation and Cancel. No board bypasses a backend guard. |
| 7, 11, 12 | Compare SetupSnapshot, SetupDrivers and SetupVerify. Check the shared layout for Check, Packages and Prepare, substep 3a, the daily header at completion, snapshot refusal and script instructions. Check pending and partial check outcomes, sign-in wait, countdown expiry and success with default and overridden scale limits. Check timeouts on SetupTimeout and wrong IDD or allow-list answers on Drivers. Reopen, shell restart and Windows restart preserve the deadline; Continue after timeout gets fresh limits. |
| 5, 14 | Compare every BarStates glyph and tooltip. Also check the visual mappings for not installed, in use, version mismatch, starting, stopping and the Drivers wait with and without a worker. Exercise mouse and keyboard shortcuts in every state. On a small screen, tab through all expanded controls with the notice visible. Focus stays visible and a dismissed notice activates nothing beneath it. |
| All | `test/qml-lint` and `bats test spike/test` stay green. Extend behaviour coverage for new data and controls. Update README.md for changed interactions and README.md and CLAUDE.md if layout changes. |

## Constraints

- This changes the panel and bar presentation. The plugin spec's VM, setup,
  snapshot, restore and trust rules still apply. Do not port the HTML or its scripts.
- Add no root action or new escalation. Keep the existing user-opened package
  installation terminal as the only established exception.
- Keep new state under `$XDG_RUNTIME_DIR` or the plugin state directory. Panel
  reads stay read-only. Keep commands literal and jobs independent of panel life.
- Agents and tests never boot, modify or experiment on `~/.windows`. Use the
  configured test copy. State the timezone on every displayed clock time;
  label countdowns as durations.

## Review log

| Gate | Stage | Round | Findings | Notes |
|---|---|---|---|---|
| Spec | a (gpt-6.1-sol) | 1 | 0 | clean |
| Spec | opt Grok (grok-4.6) | 1 | 7 | 7 confirmed, 0 refuted, 1 nit, 0 could not verify; Clarified setup layouts and states |
| Spec | opt Grok (grok-4.6) | 2 | 6 | 6 confirmed, 0 refuted, 1 nit, 0 could not verify; Clarified glyphs settings copy timing |
| Spec | opt Grok (grok-4.6) | 3 | 2 | 2 confirmed, 0 refuted, 1 nit, 0 could not verify; Clarified scale saves and Reset |
