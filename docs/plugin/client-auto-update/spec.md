# Update the Windows window by itself

Full tier spec. The plan follows in `plan.md` after this spec clears its gate.

## Problem

When Lanai's client patches change, every install's Looking Glass client (the
Windows window) is out of date. Today the panel then shows a warning and an
**Update the Windows window** button in More actions, and nothing happens until
the user finds and clicks it. After v0.3.2, John ran `omarchy plugin update` and
`omarchy-restart-shell`, then still had to open More actions and click the button
before the mouse fix reached the window.

John's call (2026-10-25): `omarchy plugin update` should bring both the panel and
the client up to date. Omarchy's update command runs no plugin step: it pulls,
validates the manifest and rescans the plugins (`omarchy-plugin-update`). The
rescan reloads Lanai's bar item, which checks Lanai's state every few seconds
whether the panel is open or not. So Lanai acts when that check finds the client
out of date.

In this spec, "the panel" is the popup, and "the bar item" is Lanai's icon in the
bar (one per monitor), which keeps checking while the panel is closed.

## Requirements

1. **Start by itself.** When Lanai's state check finds that the installed client was
   built without the current patches, in the case where spec requirement 12 names
   the build step (**Update the Windows window**) as the one step, Lanai starts that
   same update without a click.
   It acts the first time the check finds this, at any check, with the panel open or
   closed: after a plugin update, a shell restart or a sign-in, and after a job that
   held it back ends. It applies whether Windows runs or not.
2. **Only that case.** Lanai does not start an update by itself when the panel names
   **Run setup again** instead (the scale task lacks the sign-in step), when setup is
   unfinished (this also covers a missing client and a pin change, which setup's own
   build step handles), or when the client in use is an older pin's build
   (spec requirement 8). While anything makes the panel busy today (a panel job, a
   client build, or a snapshot or restore from the command line), Lanai waits, and
   starts when it ends if the client is still out of date. During the wait, the
   warning says the Windows window will update when the current job ends, and names
   no button.
3. **Tries per patch set.** The patch set is the identity spec requirement 12
   already uses: the patches' names and contents. A launch that is refused only because
   another panel job or another client build holds it back counts for nothing and
   shows no failure; Lanai waits, as in requirement 2. Every other automatic launch
   counts as a try, including one that cannot start at all. For a given patch set,
   Lanai makes at most two automatic tries:
   - A try that succeeds installs the current client, so no other try follows.
   - A try that fails, or a launch that cannot start, ends automatic tries for that
     patch set.
   - A try that stops without a result (for example at a logout, reboot or
     power-off) allows one more automatic try at the next check. A second such stop
     ends automatic tries.

   This holds across panel reloads, shell restarts and reboots. A patch set that
   differs from the last one Lanai tried by itself allows new tries. Builds that
   Lanai did not start by itself (the button, `lanai build-client`, and setup's own
   build step) do not change this count. When automatic tries end and the
   client is still out of date, the panel shows the failure and the **Update the
   Windows window** button as today, and the user can try again by hand. When a
   cut-off try had already installed the new client, the client is current, and the
   panel shows neither.
4. **Always a working client.** At every moment of an update, and after a stop at
   any moment (the update's job stopped or killed, a clean reboot or power-off, or a
   power loss), the installed client is the old one or the new one, complete and
   able to run. The new client is on disk before it replaces the old one. So the second try after a stop always has its chance, and an open of
   the window during the update never fails because the client is being replaced.
5. **One update at a time.** However many bar items Lanai runs (one per monitor), at
   most one update runs, only one try counts, and no panel or bar item shows a
   failure because another bar item started the update first.
6. **Windows keeps working.** The update changes nothing in Windows, as today. When
   an update that the panel or Lanai starts competes with Windows for the CPU, it
   yields to the VM and to the Windows window, so Windows stays responsive during
   the several minutes the build takes. When memory runs short, the system stops the
   update before it stops the VM or the window. (`lanai build-client` in a terminal
   and setup's own build step need not yield.) While the update runs, the user can start Windows and
   open the window, from the panel and from the bar item's right-click (John's call,
   2026-10-27); the window then opens with the client already installed (see 4).
   An open Windows window keeps working with the client it started with. Snapshot,
   restore, delete and Run setup again stay unavailable while the update runs, as
   for any panel job today.
7. **What the user sees.**
   - From the check that starts the update, while it launches and while it runs,
     the panel says the Windows window is updating, and the bar item shows busy, as
     today. No view names the button, and the words never tell the user to wait
     before starting Windows (today's words say "You can start Windows when it
     finishes"). When a snapshot or restore shows progress at the same time, the
     panel shows both.
   - A stop with a try left shows no failure: the panel shows the update as starting
     again at the next check.
   - After an update installs the new client, while a Windows window that started
     before that install is open, the panel and the bar item's hover text say to
     close it and open it again (John's call, 2026-10-27). This holds for any build
     that installs the client, including `lanai build-client`. When that window
     closes, or Windows shuts down, the words go away. Lanai never closes or reopens
     the window by itself. The bar item shows no failure or busy state for it.
   - When no such window is open, the panel and bar item show nothing about the
     finished update, whether it started by itself or by hand; the warning and the
     button are gone. The next open uses the new client.
   - When automatic tries end with the client still out of date, every bar item,
     also after a reload and whether Windows runs or not, shows the failure state,
     and the panel shows the failure words and the button. This lasts until the
     client is current or the user starts an update by hand. The failure words make
     sense without an earlier click (today's words after a stop say "Click Update the
     Windows window ... again").
   - An automatic launch never shows the "previous action is still running" notice
     and never blocks a click by the user.
8. **Docs.** The README's upgrade paragraph, spec requirement 12 (including its rule
   that "the build step's last message says to close and reopen the Windows window")
   and acceptance row 12b's "Upgrade:" clause say that Lanai updates the Windows
   window by itself, when the reopen words show, and when the button still appears.
   Spec requirement 12 keeps the rule that the build step changes nothing in
   Windows.

## Acceptance

- Tests show the automatic start for an out-of-date client with Windows stopped and
  with Windows running, with the panel open and closed, and no automatic start in
  each case of requirement 2. A test shows the wait: a job that holds the update
  back ends, and the update then starts.
- Tests show the tries of requirement 3: after a success, a failure, one stop
  without a result and two, a panel reload, a shell restart, a second bar item and a reboot (a
  fresh runtime folder, as after a reboot) each start a try only where requirement 3
  allows one. After automatic tries end with the client out of date, the button is
  back and starts one by hand. A launch refused because another job runs counts for
  nothing. A failure that comes before the build starts, every time, ends automatic
  tries after one (no relaunch at every check). A changed patch set allows new
  tries, and builds Lanai did not start by itself leave the count alone.
- Tests show requirement 4: a stop at each step of the install leaves a client that
  opens. The next check makes the second try when the old client is still in place,
  and none when the new one was installed.
- Bats tests show requirement 5 with two launches at once against the real locks:
  one update runs, one try counts, and neither shows a failure.
- A test that loads Lanai's bar model in the QML renderer (`test/panel-qml.bats`)
  shows that it launches the update when the view asks for one, at most once for a
  given view, that a refused launch shows no "The operation did not start", and that
  an automatic launch shows no busy-click notice and blocks no click by the user.
- Tests show the words and bar states of requirement 7 for each bullet: during a
  wait, at the launching check and while the update runs (busy; no button named, no
  "wait to start"; with a snapshot's progress too), after a stop with a try left
  (no failure), with an older window open after the install (panel and hover text,
  no bar failure), after that window closes and after Windows shuts down (the words
  go away), with no window open (nothing), and after automatic tries end (failure
  on every bar item, after a reload and with Windows started, until an update by
  hand or a current client).
- Tests show that Start Windows and Open window, in the panel and on the bar item's
  right-click, stay available while the update runs.
- A test shows that an update's unit is set to get less CPU than the VM's unit and
  the window's unit when they compete, and to be stopped before them when memory
  runs short.
- A review shows the README, spec requirement 12 and row 12b say what requirement 8
  asks.
- The bats suite, `test/qml-lint` and shellcheck pass as CI runs them.
- John's hand check before merge, on his install. `omarchy plugin update` only
  fast-forwards to the remote's default branch, so in the installed plugin's folder
  `git fetch` the local repo's branch, check it out, and run `omarchy-shell shell
  rescanPlugins`, the step plugin update runs after it pulls.
  - Part one, on a throwaway commit on top of the feature branch that edits one
    patch's header text (so its patch set differs from the installed client's and
    it still applies; row 12b's repeatable pre-fix fixture): with Windows running
    and the window open, see the bar item show the update running without a click,
    Windows stay responsive, then the hover text say to close and reopen the window.
    After the reopen, the warning is gone and `client.log` starts fresh.
  - Part two, with Windows stopped, on the feature branch without the throwaway
    commit (its patch set is `main`'s, so it differs again): see a second update
    start by itself, and start Windows while it runs.
  - Afterwards, put the folder back on `main` and run the rescan. The client is
    then current for `main`, with no click.

## Constraints

- No root, no prompt, and nothing changes in Windows (spec requirements 12 and 22).
- The update fetches only the pinned source, as today (spec requirement 26).
- A plugin update never stops the VM (spec requirement 18).
- The panel view stays read-only; whatever starts the update is not the panel view
  (`lanai panel`), which the bar item checks every 2 to 15 seconds.

## Out of scope

- Showing the update inside Windows, and cutting the panel's status text: a separate
  follow-on (`docs/plugin/plan.md`, "Show VM updates in Windows").
- Reopening the Windows window by itself (John's call, 2026-10-25).
- Updates that need **Run setup again**, which restarts Windows.
- Memory use beyond requirement 6's rule; the build's memory need is not measured.
- A setting to turn the automatic update off. John asked for the update to start by
  itself, and a patch-only change reuses the cached pinned source, so it usually
  costs only CPU time (after a cache cleanup, the first try downloads the source).

## Review log

| Stage | Round | Findings | Result |
| --- | ---: | ---: | --- |
| a (gpt-6.1-sol) | 1 | 1 | One P2 confirmed: the acceptance checks did not cover a reboot or a cut-off try, so a try record lost at reboot could pass. Integrated. |
| a (gpt-6.1-sol) | 2 | 1 | One P2 confirmed: the hand retry applies only after a failed or cut-off try; after a success the client is current and the button is hidden. Integrated. |
| a (gpt-6.1-sol) | 3 | 1 | One P2 confirmed: a try cut off after it installed the new client leaves the client current, so no failure or button shows. Integrated; stage (a) reached its cap with every finding integrated, and stage (b) reviews the result. |
| b single (opus-5.5) | 1 | 13 | Nine should-fix and four nits confirmed: Start Windows was blocked during every panel job, the trigger ran only at load, a reboot spent the one try, a refused launch or a second bar could count as a try or show a failure, the words named a button during the update and assumed a click, the closed-window outcome and the bar's states were missing, no test drove the QML trigger and the hand check needed a release, and row 12b would fail; plus the CPU priority for every update, the patch-set identity, missing clients and pin changes, and no opt-out. John's calls (2026-10-27): Start stays available during the update, a cut-off try allows one more automatic try, and the reopen words show in the panel and the bar's hover text. Integrated. |
| b single (opus-5.5) | 2 | 14 | Seven should-fix and seven nits confirmed: a launch that fails before its build would relaunch at every check, a stop during the install could leave no client (new requirement 4), a nice value does not protect Windows across units, the update words told the user to wait and the bar's right-click was missed, the QML test cannot count launches across instances (moved to bats), the hand check could not reach an unmerged branch through plugin update, and the reopen words went stale; plus the stop wording, which builds leave the count alone, the words during a wait, the done line, the busy buttons, the opt-out wording and docs acceptance. Integrated. |
| b single (opus-5.5) | 3 | 11 | Five should-fix and six nits confirmed: the stop test wrongly expected a second try after the new client was installed, the reopen words keyed to the job's end rather than the install, three states had no words (a stop with a try left, the launching check, a failure across bar items), the hand check could not run in full, and command-line snapshots and restores did not hold the update back; plus requirement 1's "today", which builds must yield, memory, the busy-click notice, requirement 12's last-message rule, and power loss during the swap. Integrated; stage (b) reached its cap. |

On October 27, 2026 (EDT), John accepted advancing to the plan after stage (b)'s
third round, with every finding integrated.
