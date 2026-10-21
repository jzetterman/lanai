# Snapshot deletion implementation plan

Governing spec: [spec.md](spec.md).

## Backend and tests

1. Add focused `test/snapshot.bats` cases before implementation. Cover a valid named snapshot, two valid copies with the same name, a missing or malformed name, a foreign or invalid snapshot, an unfinished restore, an operation-lock collision, and a deletion failure that leaves a valid duplicate. Assert that the current storage files and unrelated paths remain intact. Use isolated test directories only.
2. Add `lanai delete-snapshot <name>` in `lib/lanai.sh`. Validate exactly one UTC snapshot name. Take `lanai_flock`, refuse an unfinished restore, resolve only complete snapshots for the current storage through `snapshot_list()`, and remove every valid copy with that name from the two supported roots. Report full success, refusal, or partial failure as structured JSON. Check the remaining validated list after a removal failure so the message accurately describes whether the restore point still exists. No active VM disk file is opened or changed.
3. Add `delete-snapshot` to the long-job allow-lists and snapshot result group in `lib/ui.sh`. Keep it serialized with other panel work and include its literal name in the recorded argument array. Add a focused `test/panel-jobs.bats` case for launch, worker record, and invalid or conflicting job behavior.

## Panel and tests

4. Add the Delete and confirmation descriptors, per-item accessible labels and loss warning, busy copy, and result words to `lib/panel.sh`. Enable deletion only when a validated snapshot is listed, no panel job is busy, and no restore is unfinished; Windows may be running. Keep the visible list based on the validated snapshot inventory. Add focused `test/panel.bats` cases for running, busy, and unfinished-restore states and success/failure feedback.
5. Add a short Delete button to each snapshot row in `LanaiPanel.qml`, beside Restore. Keep Restore at the right edge. One click arms only that snapshot and shows a named warning, which is also the armed button's accessible description; a second click confirms. A confirming click within 800 ms of arming, or of an ignored click, does nothing, so a held key cannot arm and confirm in one press. Cancel and panel close clear the armed target. Restore and Delete disarm each other. Clear the target if a poll removes it or disables deletion. Run the deletion through `LanaiModel.run(["delete-snapshot", name], true)` and refresh after the job. Extend `test/panel-qml.bats` with confirmation, cancellation, stale-target, accessible-name, and 420/360/260 px layout checks.
6. Update `README.md` with the panel action and the fact that current Windows state stays intact. Remove obsolete file-manager-only guidance from the panel details. Install changed plugin files in the active Omarchy shell and restart it after tests and review.

## Verification and reviews

Run focused Bats suites for snapshot, panel, panel jobs, and QML; QML lint, shellcheck, and whitespace checks. Review the implementation diff through the repository's Codex stage, optional Grok stage when useful, and the mandatory Claude final stage. If Claude is unavailable, report the gate as open and do not open a PR. A user-authorized live preview may be installed while the gate remains open. Record each review round below.

| Gate | Stage | Round | Findings | Result |
| --- | --- | ---: | ---: | --- |
| Plan | a (gpt-6.1-sol) | 1 | 1 | P2 confirmed: state that Claude final review remains mandatory when unavailable. |
| Plan | a (gpt-6.1-sol) | 2 | 0 | Clean. |
| Diff | a (gpt-6.1-sol) | 1 | 0 | Clean; full tracked diff and new snapshot deletion documents reviewed. Refuted and downgraded counts not recorded. |
| Diff | opt Grok (grok-4.7) | 1 | 1 | P2 confirmed: interrupted deletion fell through to the setup message; fixed with a failing then passing panel test. Refuted and downgraded counts not recorded. |
| Diff | opt Grok (grok-4.7) | 2 | 1 | P3 confirmed: README retained obsolete folder-deletion guidance; corrected. No code findings. Refuted and downgraded counts not recorded. |
| Diff | a (gpt-6.1-sol) | 2 | 0 | Clean on `git diff main...snapshot-delete` through ada823b, which adds the stopped panel text cut (`docs/plugin/redesign/stopped-copy.md`); 0 refuted, 0 downgraded to nit. Codex ran the focused suites. |
| Diff | b panel (opus-5.5), 5 lenses | 1 | 27 | 35 raw, 27 distinct after dedupe; 0 refuted, 0 downgraded to nit; 7 should-fix confirmed: the in-use Snapshots line called Delete unavailable, button words were hard-coded in QML, and five test gaps proved by surviving mutations (stale-target and panel-close disarm, Restore and Delete disarming each other, refusal and failure words, the Snapshots result note, bounds). Fixed in 727d922 through a899e84 with the confirmed nits. Left as nits: one `hasSaved` property for four repeated checks, the Open window tooltip built in the generic Action, the restore row's Flow layout, one copy of the running-restore rule, the unused `restore_confirm` and `restore_snapshot.labels` words, and a refused delete showing the Failed layout. |
| Diff | b panel (opus-5.5), 3 lenses | 2 | 18 | 21 raw, 18 distinct after dedupe; 0 refuted, 0 downgraded to nit; 1 should-fix confirmed: redesign/plan.md still named the armed caption Delete permanently. Fixed in 28d33dd through 1b6c206 with these nits: a held Space armed and confirmed a delete (an 800 ms confirm guard that restarts on each ignored click, past the 600 ms key repeat delay), a storage path with a newline split the snapshot roots, saved details outlived a snapshot deleted elsewhere, one log had three names (now the Jobs log), five test gaps, and doc and log fixes. Left as nits: the redundant re-check and post-removal check in delete, the Open window tooltip, focus after a confirmed delete, the long armed Restore caption on this branch, the Copied note between the path and advice lines, and no visible reason for a disabled Delete during an unfinished restore. |

On October 20, 2026, John accepted the diff gate's Claude panel as the final review stage for this spec and plan, which had only their stage (a) rounds: the panel checked the built code against both docs.
