# Cut the bar's hover text

Small tier: one combined spec and plan for the bar item's hover text (tooltip).

## Problem

The hover text on Lanai's bar item has too much text. `LanaiModel.qml` builds it by
joining up to nine view fields: "Lanai", the bar label, the state label, the
headline, the cause, the next step, the notice, the warning and the right-click
words. It drops only exact repeats. On 2026-10-29 (EDT), during the phase F hand
check of PR #21 on John's desktop, it read:

```
Lanai
Busy
Running
Windows is running
Windows is available.
Click Open window.
Windows was force-stopped last time. Likely causes: a locked Windows, an open Windows security screen, or a shutdown that did not finish in time.
Lanai is updating the Windows window. This can take several minutes and changes nothing in Windows. You can start and use Windows during the update.
Right-click: Open the Windows window.
```

Four lines say the same thing in other words, and two long messages repeat the
panel. John's call (2026-10-29): the hover text names the state, says when the panel
holds more, and names the right-click action. All long words stay in the panel.

## Requirements

1. The hover text has two lines, sometimes three, in this order:
   1. The state line: `Lanai: ` and the state label (`view.label`, for example
      "Running", "Stopped", "Setup needed", "Failed"). When the bar shows busy,
      your turn or failed, the line adds the bar label in lower case in
      parentheses, for example "Lanai: Running (busy)", "Lanai: Setup needed (your
      turn)" or "Lanai: Stopped (failed)" (an unfinished restore or a failed action
      over a stopped VM). The parentheses are left out when they repeat the state
      label, compared without case ("Lanai: Failed", not "Lanai: Failed
      (failed)").
   2. The details line, "Open the panel for details.", only when the panel holds
      more than the state: a notice or a warning is set, the panel's layout is not
      the daily one (setup, a restore or a failure), the bar shows your turn or
      failed, or the next step offers Force stop. A result line in the daily layout
      (for example a start without a network) does not count: today's hover text
      leaves results out too.
   3. The right-click words (`right_click_tooltip`), as today. When the panel holds
      more (rule 2) and the right-click action opens the panel, rules 2 and 3 fold
      into one line, "Right-click: Open the panel for details.", so the pointer
      shows whatever right-click does.
2. No notice, warning, headline, cause or next step text appears in the hover text.
3. The bar's accessible name stays equal to the hover text.
4. Before the first view arrives, the hover text is "Lanai: Checking" and
   "Right-click: Open the panel." (a right click then opens the panel). When the
   view cannot be read, it is "Lanai: Unavailable" and "Right-click: Open the panel
   for details.". "Unavailable" names the failure, so this line has no
   parentheses.
5. The panel itself does not change.

These amend `docs/plugin/spec.md` requirement 10 (each non-running state's cause and
next step, and the logs' place for "Failed", now show in the panel; the bar names the
state and points to the panel) and `docs/plugin/redesign/spec.md` requirement 14
("Preserve tooltips with warnings, notices..." becomes a pointer to the panel). The
reopen words of `docs/plugin/client-auto-update/spec.md` (panel and hover text) now
show in the panel, and the hover text points there.

## Acceptance criteria

- A bats test of `lanai panel` compares the whole `tooltip` field, as an exact
  string, in these cases (so it also shows that no long text gets in):
  - stopped: "Lanai: Stopped" and "Right-click: Start Windows.";
  - the auto update running: "Lanai: Running (busy)", "Open the panel for
    details." and "Right-click: Open the Windows window." (right-click opens or
    raises the Looking Glass window, open or not);
  - the same while setup shows QEMU's own window (`LanaiWindow`, right-click opens
    the panel): "Lanai: Running (busy)" and "Right-click: Open the panel for
    details.";
  - the reopen words after an update, bar active: "Lanai: Running", "Open the
    panel for details." and "Right-click: Open the Windows window.";
  - a notice (a forced stop last time) with Windows stopped and nothing else:
    "Lanai: Stopped", the details line and "Right-click: Start Windows.";
  - setup step 5 with Windows running, on a first setup: "Lanai: Setup needed" and
    "Right-click: Open the panel for details." (the bar is active, so no
    parentheses); and on Run setup again (setup done before): "Lanai: Running" and
    the same right-click line;
  - in use by another VM: "Lanai: In use (your turn)" and "Right-click: Open the
    panel for details.";
  - an unfinished restore with Windows stopped: "Lanai: Stopped (failed)" and
    "Right-click: Open the panel for details.";
  - a restore running: "Lanai: Stopped (busy)" and "Right-click: Open the panel
    for details.";
  - Force stop offered while Windows shuts down: "Lanai: Shutting down" and
    "Right-click: Open the panel for details.";
  - a snapshot job with Windows stopped: "Lanai: Stopped (busy)" and "Right-click:
    Open the panel.";
  - a restore with progress: the same two lines as a restore running, so no
    percent;
  - the VM failed: "Lanai: Failed" and "Right-click: Open the panel for details.";
  - a failed start over a stopped VM: "Lanai: Stopped (failed)", "Open the panel
    for details." and "Right-click: Start Windows." (right-click still starts
    Windows after a failed start, spec requirement 11).
- One QML test checks that the bar's tooltip and accessible name equal
  `view.tooltip`, and the default and error views' hover text. The rules
  themselves are tested in bats.
- The ten-board test, which renders real `lanai panel` views, checks that each
  bar's tooltip equals `view.tooltip`, and compares the exact text of the not
  installed ("Lanai: Not installed (your turn)"), version mismatch ("Lanai:
  Display driver needs an update (your turn)") and in use boards, each with
  "Right-click: Open the panel for details.".
- John hovers the bar item during an auto update and after it, while the reopen
  words show, and sees the lines above.

## Plan

One phase, test first.

- `lib/panel.sh`: after `.bar.label` is set, add `.tooltip`, built from `.label`,
  `.bar.mode`, `.bar.label`, `.notice`, `.warning`, `.layout`, `$st.force_stop`,
  `$rightClick` and `.right_click_tooltip` by requirement 1, its lines joined
  with "\n". The words live here with the other panel words.
- `LanaiModel.qml`: `tooltip` becomes `view.tooltip || "Lanai"`. The default view
  gains `tooltip: "Lanai: Checking\nRight-click: Open the panel."`, and the error
  view gains `tooltip: "Lanai: Unavailable\nRight-click: Open the panel for
  details."`.
- Tests:
  - `test/panel.bats`: a new test for the bats cases in Acceptance criteria,
    except the reopen case, which goes in `test/client-auto.bats` beside "view:
    close and reopen only for a window older than the install", where the stale
    window fixture lives. The
    existing test near "The warning is the bar tooltip's source too" changes its
    comment: the warning shows in the panel.
  - `test/panel-qml.bats`: the widget test that compares the full tooltip
    (`test_widget_tooltip_includes_backend_right_click_words_and_error_fallback`)
    becomes the one QML check, renamed
    `test_widget_tooltip_is_the_view_tooltip_with_default_and_error_views`: its
    view sets `tooltip`, and it checks the bar's
    text and accessible name, then the default and error views. The other
    tooltip checks drop: the bar mode test's search for the bar label, the
    shortcut test's searches for the warning, notice and right-click words, the
    update test's search for the warning in `model.tooltip`, and the busy test's
    check for no percent (it moves to bats, where the real view is built). The
    ten-board test's search for `right_click_tooltip` becomes
    `compare(w.button.tooltipText, w.model.view.tooltip)`, since a folded line no
    longer contains "Right-click: Open the panel." with its period.
- Docs, as amended above:
  - `README.md`: "The tooltip names the right-click action and includes warnings
    and forced-stop notices" and "the panel and the bar's tooltip say to close it
    and open it again".
  - `docs/plugin/spec.md`: requirement 10, the client update paragraph ("The panel
    and the bar's tooltip say to close and reopen"), and row 12b's "Upgrade:"
    clause ("the panel and the bar's tooltip say to close and reopen it").
  - `docs/plugin/redesign/spec.md`: requirement 14.
  - `docs/plugin/client-auto-update/spec.md`: requirement 7's reopen bullet, the
    acceptance bullet "(panel and hover text, ...)" and the hand check's "then the
    hover text say to close and reopen the window".
  - The Open window button's own tooltip in the panel does not change.
  - This doc lives at `docs/plugin/bar-tooltip/plan.md`. The lines in
    `docs/plugin/plan.md` and `docs/plugin/client-auto-update/plan.md` that say
    the tooltip joins `view.warning` are plan history and stay.

## Review log

| Gate | Stage | Round | Findings |
|---|---|---|---|
| doc | a (gpt-6.1-sol) | 1 | 2 P2, 0 refuted: a failed bar over a stopped or running VM lost "failed" from the state line; the update acceptance case ignored that an open window makes right-click open the panel, which drops the details line. Integrated. |
| doc | a (gpt-6.1-sol) | 2 | 0: clean. |
| doc | b single (opus-5.5) | 1 | 4 should-fix, 3 nits, 0 refuted: with the window open the pointer dropped, so the reopen words and a notice read like a healthy VM (now folded into "Right-click: Open the panel for details."); setup step 5 and Force stop had no pointer (now the layout and the Force stop offer count); the docs list missed row 12b and three auto-update spec lines; the QML fixtures had no `tooltip` and the no-percent check would pass on an empty string (moved to bats, plus a ten-board check). Nits: exact strings for each case and a busy-over-stopped case; the default view's right-click line and the error view's missing parentheses; "brackets" became "parentheses". Integrated. |
| doc | b single (opus-5.5) | 2 | 4 should-fix, 4 nits, 0 refuted: a failed start keeps right-click on Start, so that case expected the wrong text; a first setup reads "Setup needed", not "Running"; no case covered your turn or a restore; the ten-board test's search for the right-click words would break on the folded line, and the update test's view was not named. Nits: result lines left out on purpose (noted), "compared without case", the doc's path; "Click for details." was not taken, since John picked "Open the panel for details.". Integrated. |
| doc | b single (opus-5.5) | 3 | 5 nits, 0 refuted; every acceptance case traced through the code gives the stated text. Nits: where the reopen case's fixture lives, an exact string for the progress case, exact text for three ten-board views, the kept QML test's name, the "\n" join. Integrated; the gate closed on a nits-only round. |

Implementation note (2026-10-29, EDT): the implementer found that right-click's
"window" test reads `LanaiWindow`, QEMU's own setup window, not the Looking Glass
window. So with the Looking Glass window open, right-click still opens (raises)
the Windows window, and the reopen and auto-update cases have three lines, not
the folded line the doc first expected. The rules were right; the expected text
was wrong, and is corrected above.
