# Stop the client moving the pointer

Small tier: one combined spec and plan for the Looking Glass client's flags in
`lib/client.sh`.

## Problem

When John drags a corner or edge of the Looking Glass window, the window grows much
faster than the pointer moves, or it stops growing while the pointer still moves.
Other windows follow the pointer exactly. Phase 7 of `docs/plugin/plan.md` listed
this bug and `wayland:warpSupport=no` as the first client option to try;
`docs/plugin/proofs.md` records the symptom but no result.

The cause is the pinned client (B7-826-236efcb1). After every change of window size,
`app_handleResizeEvent` calls `core_alignToGuest`, which moves the host pointer to
where the Windows cursor now shows in the resized picture. Hyprland sizes the window
from the pointer's position, so each move adds to, or takes away from, John's own
movement. Nothing on that path checks the input mode. A trace on October 23, 2026,
on John's install, in a client session started at 20:43 EDT, logged 790 resize
events (`app.resize` lines) and 763 pointer moves (`core.warp send` lines), counted
with `grep` on `client.log` while that session ran. That trace was overwritten when
the client restarted, so these counts cannot be checked again.

Lanai's mouse input is absolute while the client's LGMP input runs (it starts
within half a second of the client, after a moment of SPICE input, and can fall back
to SPICE mid-session): the client sends Windows the pointer's position, so the
Windows cursor follows the host pointer. SPICE input is relative only; with it, the
client's edge-exit move never arises on Wayland, because relative motion arrives
only in capture, where the client does not test for an exit. A resize rescales the picture, so the Windows
cursor's spot on screen shifts away from the host pointer, and the move chases that
shift. With warping off, the drawn Windows cursor can sit off the host pointer after
a resize until the pointer next moves. A click is still safe: the client sends the
pointer's position before the button.

With `wayland:warpSupport=no` set by hand the same day, in a client session started
at 21:04 EDT, the trace logged 482 resize events, no `core.warp send` line and 463
`core.warp drop=support` lines (warps the setting refused) by the time it was first
read. John reported the drag felt right at once.

A pointer sampler polled `hyprctl cursorpos` and `hyprctl -j activewindow` about 28
times a second. Its gap is the horizontal distance from the pointer to the window's
right edge (window x + width - pointer x), which stays fixed when a window follows a
bottom-right drag. A drag is a run of size changes at one window position with no
pause over 0.3 s. The gap's range within each floating drag:

- warping on, Looking Glass, four drags: 8, 150, 175 and 195 pixels;
- Ghostty, one drag: 3 pixels;
- warping off, Looking Glass, two drags: 25 and 87 pixels.

The sampler reads the pointer and the window some 15 ms apart, so a fast drag adds
error of its own. The sampler supports the trace but is the weaker evidence: the
trace's pointer-move counts and John's hand check decide.

A small client patch that skips the move on resize was also specified. The flag is
simpler and needs no new patch, so it is chosen; its cost is in requirement 3.

## Requirements

1. Lanai starts the client with `wayland:warpSupport=no`, so the client never moves
   the host pointer. The command line overrides `client.ini`, so a `warpSupport`
   line there cannot turn warping back on. (A `configFile` named in `client.ini`
   loads after the command line and could; Lanai does not use one.)
2. All other client flags stay as they are.
3. The README says what the setting costs. Most of it is in Looking Glass's capture
   mode (Scroll Lock by default), where the host pointer stays locked at one point of
   the window, where capture began:
   - When capture ends, the Windows cursor jumps to that point, instead of the host
     pointer moving to the Windows cursor.
   - A change of window size during capture, while the window keeps focus, also
     moves the Windows cursor to that point. The common case is the client's own
     fullscreen toggle, Scroll Lock+F, which keeps capture. Others: a monitor or
     scale change, or a resize by script. (A new window that takes focus ends capture
     first, so it does not do this.)
   - Outside capture, after a keyboard resize, the Windows cursor can show away from
     where the hidden host pointer is, until the mouse next moves. A click lands at
     the hidden pointer, so the README says to move the mouse before clicking.
   - Under the SPICE fallback (relative input), capture end sends no position, so the
     Windows cursor stays where capture moved it. This is rare; the README does not
     cover it.
   - The README also says that Scroll Lock enters and leaves capture, that
     Omarchy's shortcuts reach Windows while captured, and that Scroll Lock with
     another key runs the client's own commands (hold Scroll Lock to list them).

The spike's proof kit (`docs/plugin/proof-kit/proof-vm`) and `spike/lgtest` run the
spike's own client with the flags they were proved with. They stay as they are.

## Acceptance

- `bin/lanai-client-exec` passes the new flag after the existing ones; the test
  checks the whole argument list (`test/client.bats`).
- The bats suite and shellcheck pass as CI runs them.
- `docs/plugin/proofs.md` records phase 7's check as below (Plan, step 3).
- John's hand check on his install after the change ships. It needs no rehearsal on
  a reflink copy first: the flag changes only how the client handles the pointer and
  writes nothing to the Windows disk.
  - Set up: `~/.config/looking-glass/client.ini` holds `[input]` `mouseTrace=yes` and
    no `warpSupport` line, so the flag under test is the one Lanai passes. Close and
    reopen the window, so the client starts with both.
  - A floating drag with Super and the right mouse button, a drag on the window's
    border, and a drag of a tiled split with the Looking Glass window focused all
    follow the pointer. Only the first tells the two settings apart: in the other
    two the pointer is off the client's surface, so the client drops its moves
    either way. The log's `drop=support` lines come from the first.
  - Capture end: note where the Windows cursor is, press Scroll Lock, move the mouse,
    press Scroll Lock again. The Windows cursor jumps back to where it was when
    capture began.
  - Resize in capture: press Scroll Lock, move the mouse, then press Scroll Lock+F.
    When the window goes fullscreen, the Windows cursor jumps to the point in the
    window where capture began. Press Scroll Lock+F again, then Scroll Lock to leave
    capture.
  - Shortcuts in capture: press Scroll Lock, then press Super. Windows' Start menu
    opens and Omarchy does nothing. Press Scroll Lock to leave capture.
  - Click after a resize: make the Looking Glass window float (Super+T). Outside
    capture, rest the pointer on a distinct target in Windows (an icon) and take your
    hand off the mouse. Press Super+minus, and check that the window's size changed.
    The drawn Windows cursor moves off the target with the picture. Click without
    moving the mouse: the Windows cursor jumps back to the target and the click acts
    there. If the size changed and the cursor did not drift, record it: the README's
    outside-capture cost would then overstate.
  - `$XDG_RUNTIME_DIR/lanai/client.log` shows the trace was on and the flag took
    effect: its `Loading config from:` lines name only
    `/home/john/.config/looking-glass/client.ini` (no `/etc/looking-glass-client.ini`,
    no `/home/john/.looking-glass-client.ini`, no `configFile`), and it has
    `app.resize` lines
    for the drags, at least one `core.warp drop=support` line, and no
    `core.warp send` line.
  - Afterwards, remove the trace lines from `client.ini`; the trace logs every mouse
    move.

## Plan

One phase, test first.

1. `test/client.bats`, the `lanai-client-exec` handshake test: expect
   `wayland:warpSupport=no` as the last argument. Run it and see it fail.
2. `lib/client.sh`, `client_args`: append `wayland:warpSupport=no`. Update the
   comment above it to say why the flag is there. Run the test and see it pass.
3. `docs/plugin/proofs.md`: add a dated section, "Resize drag (2026-10-23)", in the
   style of the other dated sections, and link it from the proof 1 note on the resize
   symptom (that note says Shift and right-drag; Omarchy's resize binding is Super
   and the right mouse button). Say it ran on John's install on October 23, 2026,
   not on the phase 6 test copy; give the trace and sampler numbers and the sampler's
   gap metric from the Problem section; and say the later options in phase 7's list
   (`input:captureOnly=yes`, `win:setGuestRes=no`) were not needed.
4. `docs/plugin/plan.md`:
   - phase 7's resize check: note that it ran on October 23, 2026, and point to this
     doc;
   - phase 5's flag list (the `client_exec` bullet): add `wayland:warpSupport=no`;
   - the phase 7 "Deferred acceptance" note: say the resize drag was settled by this
     doc.
5. `README.md`, Daily use: in the paragraph on Super shortcuts, say they do not
   reach Windows outside capture mode. After it, add one short paragraph on capture
   mode and the costs in requirement 3.
6. Run `bats test spike/test` and shellcheck as CI runs it.

## Review log

| Stage | Round | Findings | Result |
| --- | ---: | ---: | --- |
| a (gpt-6.1-sol) | 1 | 1 | One P2 confirmed: make the trace check prove the trace was on. Integrated. |
| a (gpt-6.1-sol) | 2 | 0 | Clean. |
| b single (opus-5.5) | 1 | 10 | Four should-fix and six nits confirmed: the resize-during-capture cost, a capture step in the hand check, a positive `drop=support` check, two more stale places in `plan.md`, the sampler's metric and ranges, the input-mode wording, the `proofs.md` details, and the `client.ini` override. Integrated; the orchestrator's recount replaced the sampler ranges with per-drag numbers. |
| b single (opus-5.5) | 2 | 8 | One should-fix and seven nits confirmed: a new window ends capture by taking focus, so the resize-in-capture example and hand check now use a focused resize; plus what John can see in capture, the resize sentence, the `configFile` override, other ini files, trace times, shortcuts in capture, and a dated `proofs.md` section. Integrated. |
| b single (opus-5.5) | 3 | 9 | Two should-fix and seven nits confirmed: the README line saying shortcuts never reach Windows must change, and Scroll Lock+F (fullscreen, keeps capture) is the common resize in capture and replaces the timed `hyprctl` step; plus an outside-capture cost, the `configFile` case, SPICE fallback, the source of the trace counts, why no rehearsal, and a click check. Integrated; the round cap is reached, so advancing needs John's call. |

On October 23, 2026, John accepted advancing to code after stage (b)'s third round,
with every finding integrated. The diff gate reviews the doc text again where it lands
in the README, `proofs.md` and `plan.md`.

Diff gate (the branch against `main`):

| Stage | Round | Findings | Refuted | Downgraded to nit | Result |
| --- | ---: | ---: | ---: | ---: | --- |
| a (gpt-6.1-sol) | 1 | 0 | 0 | 0 | Clean. |
| b panel (opus-5.5), 3 lenses | 1 | 10 | 0 | 0 | Three should-fix and seven nits confirmed, after merging one comment nit three lenses found: the README's Ctrl+Alt+Del line (Omarchy's shortcut closes all windows), the hidden Linux pointer in the README's wording, and a click hand check John can see; plus the drag sentence's place, monitor or scale, a key for keyboards with no Scroll Lock, the `configFile` case in the comment, the edge-exit sentence, the SPICE fallback, and a self-contradicting `plan.md` sentence. Integrated. |
| b panel (opus-5.5), 3 lenses | 2 | 13 | 0 | 0 | Four should-fix and nine nits confirmed, after merging the Ctrl+Alt+Del qualifier two lenses found: the `escapeKey` example hid that the chosen key stops reaching Windows (cut), `plan.md` still said host keys never reach Windows, and the click hand check broke under focus-follows-mouse and on a tiled window; plus the capture alerts and command list, paragraph order, the comment's tense and ini scope, a shortcuts-in-capture check, which drag proves the flag, and expanded log paths. Integrated. |
