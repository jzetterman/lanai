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

1. The hover text has at most three lines, in this order:
   1. The state line: `Lanai: ` and the state label (`view.label`, for example
      "Running", "Stopped", "Setup needed", "Failed"). When the bar shows busy,
      your turn or failed, the line adds the bar label in lower case in brackets,
      for example "Lanai: Running (busy)", "Lanai: Setup needed (your turn)" or
      "Lanai: Stopped (failed)" (an unfinished restore or a failed action over a
      stopped VM). The bracket is left out when it repeats the state label
      ("Lanai: Failed", not "Lanai: Failed (failed)").
   2. The details line, "Open the panel for details.", only when the panel holds
      more than the state: a notice or a warning is set, or the bar shows your turn
      or failed. It is left out when the right-click action already opens the panel.
   3. The right-click words (`right_click_tooltip`), as today.
2. No notice, warning, headline, cause or next step text appears in the hover text.
3. The bar's accessible name stays equal to the hover text.
4. Before the first view arrives, the hover text is "Lanai: Checking". When the view
   cannot be read, it is "Lanai: Unavailable" and "Right-click: Open the panel.", the
   right-click action in that case.
5. The panel itself does not change.

These amend `docs/plugin/spec.md` requirement 10 (each non-running state's cause and
next step, and the logs' place for "Failed", now show in the panel; the bar names the
state and points to the panel) and `docs/plugin/redesign/spec.md` requirement 14
("Preserve tooltips with warnings, notices..." becomes a pointer to the panel). The
reopen words of `docs/plugin/client-auto-update/spec.md` (panel and hover text) now
show in the panel, and the hover text points there.

## Acceptance criteria

- A bats test of `lanai panel` checks the `tooltip` field for: stopped (state and
  right-click lines only); running with the auto update's warning and the window
  closed ("Lanai: Running (busy)", the details line, "Right-click: Open the Windows
  window."); the same with the window open ("Lanai: Running (busy)" and
  "Right-click: Open the panel.", no details line); a notice with nothing else; your
  turn with right-click opening the panel (no details line); the VM failed ("Lanai:
  Failed"); and a failed action over a stopped VM ("Lanai: Stopped (failed)").
- The QML test checks that the bar's tooltip and accessible name equal
  `view.tooltip`, and the default and error views' hover text.
- John hovers the bar item during an auto update, with the window open and then
  closed, and sees the two and three lines above.

## Plan

One phase, test first.

- `lib/panel.sh`: after `.bar.label` is set, add
  `.tooltip`, built from `.label`, `.bar.mode`, `.bar.label`, `.notice`, `.warning`,
  `$rightClick` and `.right_click_tooltip` by requirement 1. The words live here with
  the other panel words.
- `LanaiModel.qml`: `tooltip` becomes `view.tooltip`. The default view gains
  `tooltip: "Lanai: Checking"`, and the error view gains
  `tooltip: "Lanai: Unavailable\nRight-click: Open the panel."`.
- Tests:
  - `test/panel.bats`: a new test for the cases in Acceptance criteria. The existing
    test that says the warning is the tooltip's source (near "The warning is the
    bar tooltip's source too") changes its comment: the warning shows in the panel.
  - `test/panel-qml.bats`: the widget test that compares the full tooltip, the bar
    mode test that looks for the bar label, the shortcut test that looks for the
    warning and notice, and the update test that looks for the warning in
    `model.tooltip` change to the new rules.
- Docs: `README.md` (the sentences "The tooltip names the right-click action and
  includes warnings and forced-stop notices" and "the panel and the bar's tooltip
  say to close it and open it again"), `docs/plugin/spec.md` requirement 10 and the
  reopen words, and `docs/plugin/redesign/spec.md` requirement 14, as amended above.
  The Open window button's own tooltip in the panel does not change.

## Review log

| Gate | Stage | Round | Findings |
|---|---|---|---|
| doc | a (gpt-6.1-sol) | 1 | 2 P2, 0 refuted: a failed bar over a stopped or running VM lost "failed" from the state line; the update acceptance case ignored that an open window makes right-click open the panel, which drops the details line. Integrated. |
