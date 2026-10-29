# Cut the README to what a new user needs

Small tier: one combined spec and plan for the README and two new docs.

## Problem

`README.md` is 623 lines and about 6,100 words. It reads as a wall of text. Most
of it describes panel behavior in fine detail (drafts, confirmations, key
handling), snapshot internals (extent proofs, restore recovery), setup edge
cases, the security notes and the test suite. A new user cannot find the few
things they need: what Lanai needs, how to install it, what to do during setup,
how to use and update it, and how to remove it. Its status lines are stale (they
call the plugin a rehearsal build, say it will not be released, and tell users to
rehearse on a copy with a tool that is not on PATH, while v0.3.3 is released).

An onboarding audit on 2026-10-29 (EDT) found the README's other gaps for a new
user: it never says to finish the `omarchy-windows-vm` install first, how to stop
the container (`omarchy-windows-vm stop`), which Omarchy version it needs (only
under Networking, which says the tested build was never recorded and names
4.0.0.alpha as the shell API it targets), how much setup downloads (the virtio-win ISO alone is
877 MB) or how long setup takes; it names a `lanai` command that is not on PATH;
and it discloses setup's Windows changes (the lock turned off, a trusted
publisher added) only deep in the security section. Panel and setup fixes from
that audit are separate tasks; this one covers the README only.

John's calls (2026-10-29, EDT): cut the README to the bare minimum for getting
up and running; move the cut detail into `docs/`, user detail and developer
detail apart, so nothing is lost; keep in the README the requirements and
install, the first setup in steps, daily use and updating, and removal and the
license.

## Requirements

1. `README.md` holds only these sections, in this order, in plain short
   sentences:
   1. The wordmark, the one-line description, and a short status: an early 0.x
      release; setup offers a snapshot, and where it cannot, make a backup
      first.
   2. **Requirements:** Omarchy 4.0 with its plugin API (if `omarchy plugin`
      is not a command, the release is too old), stated as today's README
      states it: Lanai targets the 4.0.0.alpha shell API, and no exact tested
      build is recorded (the desktop it was built on runs an Omarchy dev
      build); a UEFI Windows install from `omarchy-windows-vm`, finished to
      the Windows desktop; `/dev/kvm` access as your user; enough memory for
      Windows and Linux, with a note that Lanai starts with the container's
      memory size when it can read the container's settings (otherwise half
      the host's memory, at most 16 GiB) and Settings can change it; about
      1 GB of downloads during setup, plus the Arch packages; what Lanai does
      not do (install Windows, TPM, Secure Boot, legacy layouts); that setup
      installs Arch packages with `sudo pacman` in a terminal it opens, with
      the packages named in one line of prose and `LANAI_HOST_PACKAGES` linked
      as the exact list, and builds the Looking Glass client.
   3. **Install:** the two `omarchy plugin` commands, and
      `omarchy-windows-vm stop` before setup.
   4. **First setup:** how to start it (left-click Lanai's bar glyph to open
      the panel, then click **Continue setup**), and that **Continue setup**
      moves on after each step. Then a numbered list of the six steps, each
      with what the user does or waits for:
      1. Check: Lanai checks the container's install; wait.
      2. Packages: click **Install in a terminal** and type your password.
      3. Snapshot: take one, or confirm you have a backup.
      4. Prepare: wait while Lanai downloads the drivers and builds the
         client, several minutes.
      5. Drivers: Windows opens in a basic window; there, run `setup.cmd` from
         Lanai's setup drive and approve the administrator prompt as the same
         user. Windows then shuts down by itself and Lanai starts it again, so
         do not click Shut down.
      6. Verify: wait while Lanai checks Windows; if Windows waits at its
         sign-in screen, sign in as the user who ran setup.

      One sentence says what setup changes in Windows (the lock turned off, a
      trusted publisher added, Lanai's services) and that Windows can read
      what you copy on Linux, and links the guide's section on it.
   5. **Daily use:** left-click opens the panel, right-click starts or opens
      Windows; closing the Windows window leaves Windows running (right-click
      reopens it); Shut down and Force stop; never start `omarchy-windows-vm`
      while Lanai runs Windows, and leave the container's Windows version,
      language, disk size or format, `CLEAR` and ISO mounts unchanged (to use
      the container over RDP as a fallback, stop Lanai first, then run
      `omarchy-windows-vm launch`); outside capture mode, Ctrl+Alt+Del goes to
      Omarchy and closes all windows, the Windows window too; resize the window
      to change Windows' resolution; capture mode with Scroll Lock (on a
      laptop, often Fn with another key); the shared folder `~/Windows`;
      Settings for memory, cores and Windows scale; snapshots in one or two
      sentences.
   6. **Updating:** `omarchy plugin update`, then `omarchy-restart-shell`; Lanai
      updates the Windows window by itself; if the panel names **Run setup
      again**, run it.
   7. **Removal:** these short steps, in this order, with a link to the full
      steps in the guide (today's Removal section):
      1. Stop Lanai's VM with `systemctl --user stop lanai-vm.service`.
      2. Run `omarchy-windows-vm launch` to start Windows and connect over RDP,
         and undo setup's Windows changes by the guide (the lock, the apps,
         the scale task and service, the publisher certificate).
      3. Shut Windows down from the Start menu.
      4. Run `omarchy plugin remove io.github.jzetterman.lanai`.
   8. **More:** links to `docs/guide.md`, `docs/development.md` and the specs.
   9. **License:** MIT, except the Looking Glass patches (GPL-2.0-or-later),
      from today's License paragraph (README 620-623).
2. The README fits on about two screens: at most 150 lines.
3. `docs/guide.md` (the user guide) holds every user-facing paragraph cut from
   the README, under today's README section names (Install and setup, Daily
   use, Windows lock and trust exposure, Networking and coexistence, Removal),
   with subheadings where a section is long (for example Snapshots under
   Install and setup). Text moves as it is. The only edits allowed:
   - headings;
   - links that change with the move;
   - sentences that the README's new text makes repeat;
   - commands corrected so that they run as written: `lanai` and `bin/lanai`
     get the full path of requirement 7, and a bare `omarchy-windows-vm` that
     means "start it" becomes `omarchy-windows-vm launch`.
4. `docs/development.md` holds the developer content: the background (Why and
   Plan, the spike), the plugin's file layout, the Tests section's test and
   panel-internals text (README 569-599), and the rehearsal note of
   requirement 5. The Tests section's log locations (README 600-618: the
   Actions and Jobs logs, `build-client.log`, the VM log in the user journal)
   are user facts and go to the guide; its License paragraph (620-623) goes
   to the README.
5. Nothing is lost: every sentence of today's README is in the new README, the
   guide or the development doc, or is a stale status line that the new status
   replaces. The stale status lines are README lines 7-9, 29-30, 40-41, 49 and
   51 (as of main c72a2e6). The sentence at line 59 ("Before enabling it for
   a rehearsal, set `storage` ... to the copy's absolute path.") is a
   rehearsal step no user needs, since `omarchy-windows-vm` and Lanai both use
   `~/.windows`; it moves to `docs/development.md` as a rehearsal note, and
   the default and seeding sentences after it (60-63) go to the guide. Lines
   that say phase 8 is pending (397-398, 461-471) are still true and move to
   the guide unchanged. Where the guide drops a sentence that the new README
   now states (requirement 3), the README keeps the fact and the guide links to
   it.
6. Specs and rules follow the move:
   - `docs/plugin/spec.md` gains one rule, as a paragraph right after
     requirement 32. Its text says: wherever the spec, its acceptance table or
     a plan refers to the README's content, words or steps, the README or the
     user guide it links (`docs/guide.md`) may hold it. Examples are "states",
     "names", "says", "tells", "notes", "lists", "written in the README", "the
     README's words", "the README's restore steps" and "removal steps from the
     README"; the list is not complete. Two exceptions: requirement 31's
     install and removal steps, license and dependencies stay in the README,
     and row 7's "a user who follows the README" means the README alone. The
     rule also governs the plans' open work, such as `docs/plugin/plan.md`'s
     phase 8 notes that write to "the README".
   - `CLAUDE.md`'s "Docs to update before merge" adds `docs/guide.md` and
     `docs/development.md`; its layout bullet for `docs/` names the two new
     docs; its Tests paragraph stays inline (agents load CLAUDE.md, not
     development.md).
   - Plans and proofs that cite README line numbers are history and stay.
7. Neither the README nor the guide names a command that is not on PATH. Where
   a step needs Lanai's CLI, it gives the full path
   (`~/.config/omarchy/plugins/io.github.jzetterman.lanai/bin/lanai`) or, in
   the README, leaves the step to the guide.

## Acceptance criteria

- `README.md` has the sections of requirement 1, in order, and at most 150
  lines.
- A check script (run once, not kept) splits today's README into sentences
  (lines rejoined, code blocks and list items each counted as one unit) and
  finds each in the new README, the guide or the development doc. A match is
  verbatim after whitespace is normalized and the edits requirement 3 allows
  are ignored. Each unmatched sentence is listed with its reason (a stale
  status line or the rehearsal note from requirement 5, a sentence the new
  README states, or a corrected command) and where its fact now lives. Its
  output goes in the PR body.
- Every relative link in the three files resolves to a file in the repo, and
  every `#anchor` in them resolves to a heading in its target file.
- A grep of the README and the guide finds no `lanai ` or `bin/lanai` command
  without the full path, and no bare `omarchy-windows-vm` given as a command
  to run.
- The README states everything requirement 31 asks for; `docs/plugin/spec.md`
  has requirement 6's paragraph and `CLAUDE.md` its edits.
- `bats test spike/test` passes, as a no-regression run (no test reads the
  README).
- John reads the new README and says it is enough to get going.

## Plan

One phase.

1. Write `docs/development.md` by requirement 4: the README's Why, Plan, Lanai
   (file layout) sections, the Tests section's test text, and the rehearsal
   note.
2. Write `docs/guide.md` from the rest, in the README's order, with a short
   contents list at the top, applying only requirement 3's edits.
3. Rewrite `README.md` by requirement 1, from the moved text and the panel's
   own words. The README states each fact briefly and links to the guide for
   the detail; the guide drops only the sentences requirement 5 names.
4. Edit `docs/plugin/spec.md` and `CLAUDE.md` by requirement 6.
5. Run the sentence check, the link check, the command grep and
   `bats test spike/test`.

## Review log

| Gate | Stage | Round | Findings |
|---|---|---|---|
| Doc | a (gpt-6.1-sol) | 1 | 4 P2, all confirmed and fixed |
| Doc | a (gpt-6.1-sol) | 2 | 0, clean |
| Doc | b single (opus-5.5) | 1 | 4 should-fix, 4 nits, 0 refuted; all confirmed and integrated |
| Doc | b single (opus-5.5) | 2 | 5 should-fix, 7 nits, 0 refuted; all confirmed and integrated |
