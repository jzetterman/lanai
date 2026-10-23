# Delete snapshots from the panel

## Problem

Snapshots can currently be removed only in a file manager or terminal. The panel lists them and offers Restore, but does not offer Delete.

## Requirements

- Each listed snapshot has a Delete action. A first click reveals a confirmation that names the selected snapshot and explains that the current Windows state stays intact while this restore point is lost. Cancel leaves the snapshot untouched.
- Deletion removes the selected restore point for the current storage location. If the same snapshot name has valid copies in both supported roots, both copies belong to that restore point. Other snapshots, other storage locations, the current Windows disk, and unrelated files remain untouched.
- A deletion cannot run while a snapshot or restore operation holds Lanai's operation lock, or while a restore is unfinished. It may run while Windows is running because it does not modify the current disk.
- Invalid names, missing or invalid snapshots, and failed removals produce a clear error. Deletion of duplicate copies need not be atomic: if one copy remains after an attempt, the error says that the restore point is still available. The panel refreshes after every attempt to show the actual remaining snapshots. A fully deleted snapshot disappears from the list and can no longer be restored.
- The confirmation is reachable by keyboard and names the target to assistive technology. Buttons remain within the panel at narrow widths.

## Acceptance

Backend tests show that a valid target is removed, duplicate valid copies are removed, partial deletion is reported when a duplicate remains, the current disk and unrelated paths remain, and refusal cases leave files untouched. Panel tests show the action, confirmation, cancellation, accessibility, narrow layout, and refreshed result.

## Review log

| Stage | Round | Findings | Result |
| --- | ---: | ---: | --- |
| a (gpt-6.1-sol) | 1 | 1 | P2 confirmed: define partial deletion of duplicate copies. |
| a (gpt-6.1-sol) | 2 | 0 | Clean. |
