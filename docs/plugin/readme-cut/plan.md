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
      release, take a backup or a snapshot before setup.
   2. **Requirements:** Omarchy 4.0 with its plugin API, stated as today's
      README states it: Lanai targets the 4.0.0.alpha shell API, and no exact
      tested build is recorded (the desktop it was built on runs an Omarchy dev
      build); a UEFI Windows install from `omarchy-windows-vm`, finished to
      the Windows desktop; `/dev/kvm` access as your user; enough memory for
      Windows and Linux, with a note that Lanai starts with the container's
      memory size when it can read the container's settings (otherwise half the
      host's memory, at most 16 GiB) and Settings can change it; about 1 GB of downloads during
      setup; what Lanai does not do (install Windows, TPM, Secure Boot, legacy
      layouts); that setup installs Arch packages with `sudo pacman` in a
      terminal it opens (the package list stays linked), and builds the Looking
      Glass client.
   3. **Install:** the two `omarchy plugin` commands, and
      `omarchy-windows-vm stop` before setup.
   4. **First setup:** how to start it (left-click Lanai's bar glyph to open
      the panel, then click **Continue setup**), then a numbered list of the six
      steps (Check, Packages,
      Snapshot, Prepare, Drivers, Verify), each with what the user does or waits
      for: Packages (Install in a terminal, password), Snapshot (take one, or
      confirm a backup), Prepare (wait while Lanai builds the client, several
      minutes), Drivers (in Windows, run `setup.cmd` from Lanai's setup drive and
      approve the administrator prompt as the same user), Verify (sign in as the
      user who ran setup). One sentence says what setup changes in Windows (the
      lock turned off, a trusted publisher added, Lanai's services) and links
      the guide's section on it.
   5. **Daily use:** left-click opens the panel, right-click starts or opens
      Windows; closing the Windows window leaves Windows running (right-click
      reopens it); Shut down and Force stop; capture mode with Scroll Lock (on a
      laptop, often Fn with another key); the shared folder `~/Windows`;
      Settings for memory, cores and Windows scale; snapshots in one or two
      sentences.
   6. **Updating:** `omarchy plugin update`, then `omarchy-restart-shell`; Lanai
      updates the Windows window by itself.
   7. **Removal:** the short steps that requirement 31 of `docs/plugin/spec.md`
      asks for, with a link to the full steps in the guide.
   8. **More:** links to `docs/guide.md`, `docs/development.md` and the specs.
   9. **License:** MIT, except the Looking Glass patches (GPL-2.0-or-later).
2. The README fits on about two screens: at most 150 lines.
3. `docs/guide.md` (the user guide) holds every user-facing paragraph cut from
   the README, grouped under the README's section names plus the current
   sections it does not keep (Windows lock and trust exposure, Networking and
   coexistence, the full Removal). Text moves as it is; edits are limited to
   headings, links that change with the move, and sentences that the README's
   new text makes repeat.
4. `docs/development.md` holds the developer content: the background (Why and
   Plan, the spike), the plugin's file layout, and Tests.
5. Nothing is lost: every paragraph of today's README is in the new README, the
   guide or the development doc, or is a stale status line that the new status
   replaces.
6. Specs and rules follow the move:
   - `docs/plugin/spec.md` gains one rule: where it says the README states
     something, the README or the user guide it links may state it.
     Requirement 31 (install and removal steps, license, dependencies in the
     README) stays as it is, and the new README meets it.
   - `CLAUDE.md`'s "Docs to update before merge" adds `docs/guide.md`, and its
     Tests paragraph points to `docs/development.md` where it repeats it.
   - Plans and proofs that cite README line numbers are history and stay.
7. The README names no command that is not on PATH. Where a step needs Lanai's
   CLI, it gives the full path
   (`~/.config/omarchy/plugins/io.github.jzetterman.lanai/bin/lanai`) or leaves
   the step to the guide.

## Acceptance criteria

- `README.md` has the sections of requirement 1, in order, and at most 150
  lines.
- A check script (run once, not kept) lists every paragraph of today's
  README and finds each in the new README, the guide or the development doc, or
  names it as a replaced status line. Its output goes in the PR body.
- Every relative link in the three files resolves to a file in the repo.
- The README states everything requirement 31 asks for.
- `bats test` passes (no test reads the README).
- John reads the new README and says it is enough to get going.

## Plan

One phase.

1. Write `docs/development.md` from the README's Why, Plan, Lanai (file layout)
   and Tests sections.
2. Write `docs/guide.md` from the rest, in the README's order, with a short
   contents list at the top.
3. Rewrite `README.md` by requirement 1, from the moved text and the panel's
   own words. Where the README states a fact the guide also states, the guide
   keeps the detail and the README links to it.
4. Edit `docs/plugin/spec.md` and `CLAUDE.md` by requirement 6.
5. Run the paragraph check, the link check and `bats test`.

## Review log

| Gate | Stage | Round | Findings |
|---|---|---|---|
| Doc | a (gpt-6.1-sol) | 1 | 4 P2, all confirmed and fixed |
