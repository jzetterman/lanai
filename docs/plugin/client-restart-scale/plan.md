# Keep the pointer scale after the host restarts

Small tier: one combined spec and plan for a new Looking Glass client patch,
`patches/looking-glass/0003-client-restart-scale.patch`, and the panel's update
message that names it.

## Problem

After the Dell XPS wakes from sleep, the mouse reaches only the top-left quarter of
Windows. At the window's right or bottom edge the pointer leaves the window while the
Windows cursor sits at the middle of the screen. Capture mode (Scroll Lock) works.
Any resize of the window, such as Super+F twice, fixes it until the next wake. Only
closing and reopening the window fixed it before this was understood.

Each wake restarts the Looking Glass host in Windows. The client logs
`Waiting for the host to restart...`, then a new `Starting session`, and the frames of
the new session have the same size as before (3152x1900 on the XPS).

The cause is in the pinned client (B7-826-236efcb1), and upstream `master`
(cdba29f, 2026-10-07) has the same code:

- On a host restart, `lg_run` calls `lgInit` (`client/src/main.c:4164`; the function
  is at line 174, and the first start calls it at line 3828), which sets
  `g_cursor.useScale` to false and `g_cursor.scale` to 1.0 (lines 183-185).
- Only `core_updatePositionInfo` (`client/src/core.c`) sets the scale again, from the
  frame size and the window. After a restart, the frame path calls it only when
  `g_state.haveSrcSize` is false or the frame's size or rotation changed
  (`main.c:2171`). Nothing sets `haveSrcSize` back to false, so a new session at the
  same size never recomputes the scale.
- The absolute pointer path converts a window position to a Windows position with
  that scale (`util_localCurToGuest`). With a scale of 1.0 on a display at scale 2,
  the window maps onto Windows' top-left quarter.

The desktop does not show the bug: at scale 1 its window and frame match, so the
correct scale is 1.0 anyway.

A trace on John's XPS on 2026-10-25 (EDT) shows it. The XPS panel is eDP-1, 3200x2000
at scale 2, and the window is 1576x950. Before the sleep, the client logged
`core.geometry src=3152x1900 dst=0,0,1576,950 win=1576x950 scale=2.0000,2.0000`.
The wake restarted the host at 00:00:23 (client time), and no `core.geometry` line
followed. After it, `core.absolute local=1314.816,588.609 guest=1315,589
size=3152x1900`: the client sent the window position unscaled, where 2630,1177 was
right.

## Requirements

1. A host restart does not change the pointer scale. The scale comes from the frame
   size and the window (`core_updatePositionInfo`), and both survive a restart; only
   a new frame size, rotation or window size changes it, as today. Before the first
   frame of the client's first session, the scale is 1.0, as today.
2. Nothing else changes in the client: a first start, a frame size change and a
   window resize work as today, and the two resize patches keep working.
3. The panel's two messages for an old client name the mouse fix as well as the
   size fix. A new patch makes every install built with fewer patches count as an
   old client. Lanai stores one hash for the whole patch set and does not record
   which patches a build has, and a check per patch is not worth it here. The
   messages say "may" for each fix and name the mouse first: the patches have not
   changed since 2026-10-14, so most old builds already have the size fixes.
4. Spec requirement 12 (`docs/plugin/spec.md`) allows the patch and names the mouse
   fix in its upgrade words.

Between the restart and the new session's first frame (about 0.3 seconds on the
XPS), the client converts positions with the last session's frame size. That is
right when the size did not change, which is the case on every wake seen so far.
When it did change, the new size's first frame recomputes the scale, as today.

## Acceptance

- A client unit test in `mouse-tests` fails without the fix and passes with it. With
  a frame size that differs from the window, so the correct scale is not 1.0, a
  pointer move sends the right absolute position before and after the client's
  restart reset.
- The panel tests expect the new words for both old-client messages, and the README
  and spec requirement 12 name the mouse fix.
- Every patch applies exactly to the pinned source, the client builds, and its tests
  pass (`test/client-patches.bats` with `LANAI_TEST_LG_TARBALL`). The bats suite,
  `test/qml-lint` and shellcheck pass as CI runs them.
- John's hand check on the XPS after a release:
  - Shut Windows down, update Lanai, and click **Update the Windows window** when the
    panel offers it (the patch set changed), then start Windows.
  - Put `[input]` and `mouseTrace=yes` in `~/.config/looking-glass/client.ini`, and
    open the Windows window.
  - Close the lid, then wake the laptop. The mouse reaches the whole Windows screen,
    and the Windows cursor stays under the hand, without a resize.
  - `$XDG_RUNTIME_DIR/lanai/client.log` shows `Waiting for the host to restart...`
    and a new `Starting session`. After them, `core.absolute` lines have a `guest`
    about twice `local` (before the fix they were equal), with no `core.geometry`
    line between `Starting session` and those lines. Every recompute logs that line,
    so its absence shows no resize or scale change did the work.
  - Afterwards, remove the `mouseTrace=yes` line, or delete `client.ini` if it was
    created only for this check; the trace logs every mouse move.

## Constraints

- The change is a new patch in `patches/looking-glass/`, numbered 0003, that applies
  exactly after 0001 and 0002 to the pinned source (no offset or fuzz). It carries the
  same header, GPL-2.0-or-later notice and copyright as the other two.
- The pin, the IDD and the existing patches stay as they are.
- Reporting the bug upstream is out of scope here; John posts that issue.
- Building the new client by itself after `omarchy plugin update` is a separate,
  later task (John's call, 2026-10-25). This change keeps today's update button.

## Plan

One phase, test first, by one implementer in a worktree. Line numbers refer to the
unpatched pinned source; with 0001 and 0002 applied they shift (for example
`core.c:746` becomes 854).

The fix: `lgInit` resets `g_cursor.useScale` and `g_cursor.scale` only while
`g_state.haveSrcSize` is false, that is, before the client has seen any frame. On a
restart `haveSrcSize` is already true (only `videoSourcePrepare` writes it, at
`main.c:2177`, and only ever to true), so the scale keeps the value
`core_updatePositionInfo` last computed from the frame size and window, which the
restart does not change. Nothing new waits for a later frame, so the SPICE fallback
and a resize behave as today. `haveSrcSize` is a plain bool that the render thread
writes and `lgInit` (main thread) now reads; on a restart it was set long before, and
on the first start `lgInit` (`main.c:3828`) runs before the render thread exists,
so no frame can exist yet. One case can race: a restart before any frame arrived,
while the render thread prepares a SPICE fallback frame. The worst outcome is a
reset to 1.0, which is what today's unconditional reset does, so it is no
regression. (A reset that runs only once, before the first `lgInit`, would remove
the read, but would leave nothing for `mouse-tests` to test, so the plan keeps the
guard.)

`main.c`, where `lgInit` lives, is built by no client test, so the reset moves into
`core.c`, which `mouse-tests` (`client/tests/mouse_test.c`) builds and drives through
its own `g_state`.

1. In the pinned source with 0001 and 0002 applied, add a `restart-scale` case to
   `mouse_test.c` and to `MOUSE_CASES` in `client/tests/CMakeLists.txt`. The case:
   - turns on absolute input (`lgInput_setFallback` with the test's absolute input
     ops, as other absolute cases do);
   - sets a 1576x950 window and a 3152x1900 frame with `haveSrcSize` true, runs
     `core_updatePositionInfo`, and checks that a move to (700,400) sends 1400,800;
   - runs `core_resetPointerScale()`, and checks that the same move sends 1400,800 again
     and that `useScale` is still true;
   - then, keeping that state (scale 2, `useScale` true), sets only `haveSrcSize`
     to false, runs `core_resetPointerScale()`, and checks that the scale is 1.0 and
     `useScale` is false. (`reset()` already sets those values, so this part must not
     start from `reset()`.)

   `mouse-tests` does not yet reach `core_updatePositionInfo`: the tests link with
   `--gc-sections`, and no case calls it. The case needs stubs for `lgMessage_post`
   (`void lgMessage_post(const LGMsg *)`, from `message.h`),
   `app_handleMouseRelative` and `app_updateMouseState`, with their exact
   signatures; the `inputMousePosition` stub extended to count calls and record x and
   y; and `posInfoValid` left true from `reset()`, since the test display-server stub
   has no `realignPointer`.
2. Add `core_resetPointerScale()` to `core.c` and `core.h` in two moves, so the test
   goes red on an assertion before it goes green:
   - Move the writes at `main.c:183-185` into `core_resetPointerScale()` unchanged, with
     no condition, and have `lgInit` call it in their place. Everything else in
     `lgInit` stays there, in its current order. Build and run the case, and see it
     fail at the second move's assertion. That red is the negative control.
   - Wrap the writes in `if (!g_state.haveSrcSize)`, and see the case pass. A
     comment above the function says why the scale survives a restart.
3. Write the patch as `0003-client-restart-scale.patch` in the style of 0002: a
   subject line, a body that says what changes and why, the "From Lanai" line, the
   copyright line, the SPDX line last, then `diff -Naur` hunks against the tree with
   0001 and 0002 applied.
4. `test/client-patches.bats`: expect 0003 in the `patches_list` output, and update
   the header comment (line 7) and the comment above the build (line 86), which say
   only patch 0002 compiles hooks into `main.c`. The pinned-source test already
   builds `mouse-tests` and runs `mouse-` cases, so the new case runs there
   unchanged. Run that file with `LANAI_TEST_LG_TARBALL` set
   (`~/.cache/lanai/downloads/looking-glass-B7-826-236efcb1-source.tar.gz`; copy it,
   never change it) and see it pass. No test covers the `main.c` call; the client
   build and John's hand check do.
5. The panel's old-client messages (requirement 3), test first in `test/panel.bats`:
   - `RESIZE_NEW` (line 2585), for the update button branch (`lib/panel.sh:532`):
     "After the computer wakes from sleep, the mouse may reach only part of Windows.
     Windows may also start at, or change to, the wrong size. To fix both, click
     Update the Windows window in More actions. Updating changes nothing in
     Windows."
   - The Run setup again branch (`lib/panel.sh:524-530`): `$clientOld` adds two
     items to `$fixes`, in this order: a new `MOUSE` sentence, "After the computer
     wakes from sleep, the mouse may reach only part of Windows.", then the current
     `BOTH` sentence unchanged. The lookup becomes
     `{"1":"this","2":"both","3":"all three"}` in the same change: jq turns a missing
     key into "To fix , click ...". The count is at most 3 (old client 2, plus old
     task 1). The test for an old task plus an old client (around `panel.bats:2625`)
     then expects "To fix all three".
   - See both fail, then change `lib/panel.sh`. `test/panel-qml.bats:2168` is a
     fixture that never reads `panel.sh`; update it for consistency only.
   - `README.md:318-329`: that paragraph covers two cases; its first sentence
     ("Windows may not match the window") and both cases name the mouse fix.
   - The comments in `lib/panel.sh` that describe these messages: the one above the
     resize warning ("says what it fixes ...") and the one that names "the one step
     that brings the resize fix".
   - `docs/plugin/spec.md` requirement 12: widen "they change only when the client
     sends the window-size message it already sends, and what it logs" to allow
     keeping the pointer scale across a host restart, and add the mouse fix to the
     upgrade words for both steps. Log the amendment in the spec's review log.
   - `rg -n -U 'wrong\s+size' README.md lib docs/plugin/spec.md` (the phrase wraps
     in `spec.md`) for anything else that describes the current panel.
6. `docs/plugin/proofs.md`: add a dated section, "Pointer scale after a host restart
   (2026-10-25)", with the trace lines from the Problem section and a link to this
   doc.
7. Run `bats test spike/test`, `test/qml-lint`, and shellcheck as CI runs them.

## Review log

| Stage | Round | Findings | Result |
| --- | ---: | ---: | --- |
| a (gpt-6.1-sol) | 1 | 2 | Two P2 confirmed: the `test` transport ends the session instead of restarting it, and the client test build has no real Weston. The test moved to a `mouse-tests` unit case, with the code at fault moved into `core.c`. |
| a (gpt-6.1-sol) | 2 | 3 | Three P2 confirmed: a negative control that builds and fails on an assertion, the render-thread reader of `haveSrcSize` (an existing unlocked pattern; the plan now says why the new write is safe), and a `client.ini` clean-up that keeps other settings. Integrated. |
| a (gpt-6.1-sol) | 3 | 1 | One P2 confirmed: the frame-size writer is a render-thread callback that also serves the SPICE fallback, so `core_resetSession` now takes `g_state.videoSplashLock` around its writes. Integrated; stage (a) reached its cap with every finding integrated, and stage (b) reviews the result. |
| b single (opus-5.5) | 1 | 9 | Three should-fix and six nits confirmed: `core_setSourceSize` must return whether this call changed the source, `mouse-tests` needs three link stubs and a recording position stub, and the panel's update message names only the resize fix (new requirement 4); plus `core.h`'s rotation type, which `lgInit` writes move, unpatched line numbers, why the lock adds no lock order, relative input's ungated realign, and two stale bats comments. Integrated. |
| b single (opus-5.5) | 2 | 9 | Three should-fix and six nits confirmed: waiting for a later prepare left a gap when the SPICE fallback was already prepared, and a resize could no longer recover; the Run setup again message also names the old client; spec requirement 12 limits what the patches change. The design changed to the simpler fix (keep the scale across a restart; reset it only before the first frame), which drops the old requirement 2, the lock and `core_setSourceSize`. Also integrated: both panel messages, the spec amendment, the QML fixture note, absolute input in the test, a shorter panel sentence, the hash rationale, and a hand check that rules out a resize. |
| b single (opus-5.5) | 3 | 8 | Two should-fix and six nits confirmed: the test's second part could pass with a no-op function, and the Run setup again words were unspecified and too long for one sentence. Integrated: the test goes red on an assertion by moving the code before adding the guard, and the mouse becomes its own `$fixes` item with an "all three" lookup. Also integrated: mouse first in both messages, the before-any-frame race, a hand check keyed on `core.geometry`, README and comment scope, a grep that matches wrapped text, and the `lgInit` call site. Stage (b) reached its cap. |

On October 25, 2026 (EDT), John accepted advancing to code after stage (b)'s third
round, with every finding integrated. The diff gate reviews the code and every doc and
panel text change again.

Diff gate (the branch against `main`):

| Stage | Round | Findings | Refuted | Downgraded to nit | Result |
| --- | ---: | ---: | ---: | ---: | --- |
| a (gpt-6.1-sol) | 1 | 0 | 0 | 0 | Clean. |
| b single (opus-5.5) | 1 | 8 | 1 | 0 | Eight nits, a nits-only stop. Seven integrated: the README's repeated mouse sentence and its one-fix "with the mouse fix", the spec's dangling phrase and long lines, "a restart by itself changes neither" in the spec and the patch, the proofs heading's timezone and wording, and `core_resetSession` renamed `core_resetPointerScale`. Refuted: the test's order of `lgInput_setFallback` and `reset()` matches upstream's own auto-capture case (`mouse_test.c:609-611`). |
