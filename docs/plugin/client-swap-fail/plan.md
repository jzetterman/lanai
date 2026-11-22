# Keep the window open after a failed buffer swap

Small tier: one combined spec and plan for a new Looking Glass client patch,
`patches/looking-glass/0006-client-swap-fail.patch`.

## Problem

On Allen Fox's host, the Windows window sometimes closed about 0.4 seconds after it
opened (PR 28). The client's log ended with
`Failed to swap EGL buffers (eglError: 0x3000)`.

His host: RTX 4070 SUPER (12 GB), NVIDIA driver 615.78.08, Hyprland 0.56.2, a
5120x2160 monitor at scale 1.6, the pinned client (B7-826-236efcb1) with Lanai's
flags, and a real VM. His counts, from his PR comment of 2026-11-22:

| Condition | Opens that closed |
| --- | ---: |
| About 10.9 of 12.3 GB of video memory in use | 13 of 24 |
| About 2.3 GB in use | 0 of 8 |

Every failure seen came at the first buffer swap after the first guest frame. A swap
is the step that puts a finished frame on the screen.

The cause of the close is in the pinned client:

- `egl_render` returns the swap's result (`client/renderers/EGL/egl.c:1790-1798`).
- A `false` result breaks the render loop (`client/src/main.c:1083`), and the client
  exits.

So one failed swap ends the client. Allen changed `egl_render` in a test build to log
a failed swap and carry on. In 4 of 8 opens with video memory full, one swap failed
(swap 8 or 9), the next swap succeeded, and the window then ran normally. The EGL
error, 0x3000, is `EGL_SUCCESS`: the driver's swap call returns a failure with no
error code.

Why the swap fails is not known. The call that fails is the NVIDIA driver's, and
nearly full video memory is the only trigger seen, so the driver is the suspect.
This doc does not remove that cause. It stops a short run of failed swaps from
closing the window.

John's host (RTX 3090, 24 GB, the same driver) has never shown the failure. 17 opens
there with no VM did not fail, and 8 opens with no VM on Allen's host did not fail
either. So a test with no guest frame has not reached the failure.

PR 28 proposed `app:renderer=OpenGL` on NVIDIA hosts. The OpenGL renderer does not
check the swap's result, so Allen ran a build that logs a failed swap on that path.
With it, 0 of 8 opens logged a failed swap under the same pressure. It is not chosen:
upstream calls the OpenGL renderer deprecated (`doc/display.rst`), it redraws the
full frame each time, and it would change the renderer on every NVIDIA host for a
failure that needs nearly full video memory.

## Requirements

1. A failed swap does not end the client. The client waits 10 ms, draws the next
   frame in full and tries again.
2. The client ends, as it does today, when every swap has failed for one second.
3. The log shows what happened: the first failed swap of a run, and then either the
   first good swap (with the count of failed swaps and the time they took) or the
   last failed swap before the client ends.
4. Nothing else changes: no client flag, no renderer change, no NVIDIA check.

Why a full redraw: the EGL renderer redraws only the areas that changed, and it
works them out from what the earlier swaps showed (`egl.c:1485-1591`). A frame that
did not reach the screen breaks that record. `app_invalidateWindow(true)` is the
client's own way to ask for a full redraw. It also wakes the render thread, so the
retry does not wait for the next guest frame.

One full redraw is enough, because of how the client records it. A frame drawn for
an invalid window sets `hasOverlay` (`egl.c:1667-1672`), which writes -1 into that
frame's place in the overlay history (`egl.c:1709-1710`). A later frame on an older
buffer looks back through the history, and at a -1 it redraws in full too
(`egl.c:1576-1580`). `hadOverlay` also makes the frame after the retry a full redraw
(`egl.c:1497`, `1782`). So no later frame draws only part of a buffer that the failed
swap left out of step. A new pin must keep this behaviour (`CLAUDE.md`, Rules).

Why the 10 ms wait: without it a retry is fast. In a first run of the proof, about
40,000 failed swaps fit in one second. Each try asks the compositor for a frame
callback (with `win:jitRender`) and a presentation report
(`client/displayservers/Wayland/presentation.c`, `waylandPresentationFrame`), and
both wait for the surface's next commit, which a failed swap may not make. The wait
keeps a run to about 100 tries. In Allen's
test build the next swap came at the client's normal pace, tens of milliseconds
later, and succeeded, so a short wait also matches the one recovery that was seen.
The render thread holds the renderer lock during the wait, and that lock is a
spinlock (`LG_LOCK`, `common/include/common/locking.h`). A thread that needs the lock
in those 10 ms spins until the wait ends. That happens only during a run of failed
swaps, so it is accepted.

Why one second and not a count: the driver's recovery time is not known. One second
is long enough to cover a slow recovery and short enough that a dead display still
closes the window promptly. The limit has two edges, and neither has been seen:

- It is time alone. If the render thread stalls for over a second between the first
  and the second failed swap, the client ends after two tries. Before this patch it
  ended after one.
- It covers one run of failed swaps. If swaps fail and succeed in turn, the client
  stays up and logs two lines for each run, and `client.log` has no size limit while
  the client runs.

## Known limits

- The client's render loop (`client/src/main.c:1083-1095`) treats a frame whose swap
  failed as shown, because `egl_render` now returns `true`. It retires the render
  queue's pending change of video source (`renderQueue_presented`) and the cursor
  repaint, and it counts the frame's timing, one try early. At the first guest frame
  that means the client can stop the SPICE picture and switch input to Looking Glass
  up to one retry before the new picture shows. The next try redraws everything, so
  the picture then matches. Allen's test build returned `true` in the same way, and
  his recovered opens ran normally. To report "try again" to the loop would need a
  change in `main.c`, which patches 0002 and 0003 and the `resize-hang` patches also
  change. One reviewer rated this a blocker; see the review log.
- A failed swap can add one wrong sample to the client's PHOTON latency graph, a
  diagnostic overlay (`presentation.c:133`). It is not fixed.

## Acceptance

- Every patch applies exactly to the pinned source and the client builds
  (`test/client-patches.bats` with `LANAI_TEST_LG_TARBALL`). The bats suite,
  `test/qml-lint` and shellcheck pass as CI runs them.
- `docs/plugin/proof-kit/swap-fail-open` shows the five cases in the table under
  "Proof" on a host with no VM attached.
- Allen's test on his host, with the patched client and video memory nearly full: at
  least 16 opens, none closes, and the log shows the failed swaps and the good swap
  after each run. The picture is right after each recovered open. Allen posts the
  counts and one `client.log` from a recovered open.
- No hand check on John's install is needed before the merge: his host does not
  show the failure, and the patch changes nothing until a swap fails.

## Constraints

- The change is a new patch in `patches/looking-glass/` that applies exactly to the
  pinned source (no offset or fuzz). It changes only `client/renderers/EGL/egl.c`,
  which no other Lanai patch changes, so its place in the order does not matter.
- Its number is 0006. The `resize-hang` branch already holds 0004 and 0005. If this
  patch merges first, `main` has a gap in the numbers until that branch merges.
  `patches_list` reads the files in name order and accepts a gap.
- The pin, the IDD and the other patches stay as they are.
- The panel's words for an old client stay as they are. The failure is rare, and
  Lanai updates an old client by itself.
- A new patch changes the identity of the client build that Lanai requires. Lanai's
  own client update then builds the new client on installs that it covers
  (`docs/plugin/client-auto-update/spec.md`).
- A report to NVIDIA or to Looking Glass is out of scope here; John decides on that.

## Plan

One phase.

1. `egl.c`, `struct Inst`: add `swapFails` (failed swaps in a row) and
   `swapFailStart` (when the first of them failed). `calloc` sets both to zero.
2. `egl.c`, the end of `egl_render`:
   - On a good swap after failed ones, log
     `EGL swap succeeded after N failed in M ms` and set the count to zero.
   - On the first failed swap of a run, record the time and log the old line with
     `, trying again` added.
   - On a later failed swap, when one second (`SWAP_FAIL_LIMIT_NS`) has passed since
     the first, log the old line with `, N failed in a row` added and return `false`.
   - In every other failed case, wait 10 ms (`SWAP_FAIL_RETRY_NS`), call
     `app_invalidateWindow(true)` and return `true`.
3. `test/client-patches.bats`: expect the new patch in the `patches_list` output and
   update the two comments that say which patch changes which file.
4. `docs/plugin/proof-kit/swap-fail.c` and `swap-fail-open`: the proof tool. The
   first is an `LD_PRELOAD` shim that makes chosen swaps return `EGL_FALSE`. The
   second opens a client with the shim on an empty workspace, against a scratch
   memory file, and reports the result. It passes the client a config file that
   loads last (`-C`), so no `client.ini` on the host can point the client at a live
   VM or at another renderer.
5. `docs/plugin/proofs.md`: a dated section with the proof. `CLAUDE.md`: name the
   two proof-kit files, and add the pin-change recheck. `README.md`: name the two
   new log lines.

No client unit test covers the patch. The test targets that
`test/client-patches.bats` builds (`resize-tests`, `config-message-tests`,
`mouse-tests`) build no renderer, and the logic is one counter and one time check.
The proof tool covers it. Upstream's `render-tests` (`client/tests/CMakeLists.txt`)
runs the real client under a headless Weston and checks the pixels it draws, with
partial updates among its cases. Lanai does not build it, and Weston is not on
John's host. With Weston installed, `render-tests` with `swap-fail.c` loaded could
check the picture after a failed swap. That is not part of this change.

## Proof

2026-11-22 (EST), on John's desktop (RTX 3090, NVIDIA 615.78.08, Hyprland, 3840x2160
at scale 1), with `swap-fail-open`. "Stock" is the installed client with patches
0001 to 0003. "Patched" adds 0006. The shim fails swaps from swap 8.

| Client | Swaps that fail | Result |
| --- | --- | --- |
| Stock | 1 | Ended. Logged the old line at 0.349 s. |
| Patched | 1 | Still up after 4 s. Logged `trying again`, then `succeeded after 1 failed in 10 ms`. |
| Patched | 5 in a row | Still up after 4 s. Logged `trying again`, then `succeeded after 5 failed in 50 ms`. |
| Patched | Every swap | Ended. Logged `trying again` at 0.335 s and `100 failed in a row` at 1.337 s. |
| Patched | None | Still up after 4 s. No line about a failed swap or a recovery. |

The times are the client's own log times. The script polls four times a second, so
it does not measure when a client's process ended.

What this proof does not cover:

- The shim's failed swap never reaches the driver. The NVIDIA driver's failed swap
  may leave other state behind. Allen's test covers that.
- The client shows its "waiting" screen, which it always redraws in full. So the
  proof does not show a partial redraw after a failed swap with real guest frames.
  The full redraw rests on the reading of the source in "Requirements", and on
  Allen's check of the picture.
- Allen saw 60 swaps in 5 seconds in the opens with a failed swap, and 120 in the
  others. The cause is not known. The log from his test of this patch has the times
  to check it.

## Review log

One reviewer, `gpt-6.1-sol` (Codex) at high effort, on a snapshot of the tree with
the pinned source and the proof logs. Each reviewer run stated the snapshot's
manifest hash, and it matched.

| Round | Context | Findings | Result |
| ---: | --- | ---: | --- |
| 1 | Blind | 3 | P2 confirmed: with no wait, a run of failed swaps made about 40,000 tries a second, and each try left a presentation report (and with `win:jitRender` a frame callback) waiting for a good swap. Fixed with the 10 ms wait. The reviewer's own fix, to cancel those requests, was not taken: it needs changes outside `egl.c`. P1 confirmed as an open gate, not a defect: Allen's test on his host is still to come, and the merge waits for it. P3 confirmed: the doc said the client's tests build no renderer, but upstream has `render-tests`. Fixed in "Plan". |
| 2 | Follow-up, with the findings and the changes | 1 | P3 confirmed: the patch header and the code comment did not say that the frame callback needs `win:jitRender`. Fixed (text only). The reviewer judged a bound of about 100 waiting requests acceptable, and noted the spinlock, which "Requirements" now records. No P1 or P2. |

Round 3 was a panel that John asked for: `claude-fable-5-2` (Claude) and
`gpt-6.2-astra` (Codex), both at high effort, blind and in parallel, on a snapshot
with this log removed.

| Reviewer | Findings | Result |
| --- | ---: | --- |
| `claude-fable-5-2` | 2 | Both P3, both confirmed. The doc gave only part of the reason why one full redraw is enough: fixed in "Requirements", with a pin-change recheck in `CLAUDE.md`. The limit's two edges were not stated: fixed in "Requirements". Its optional code change (a minimum count of tries) was not taken. |
| `gpt-6.2-astra` | 7 | P1, the render loop treats a failed swap as shown: confirmed as described, but not fixed and not agreed as a blocker; see "Known limits". P1, a `client.ini` on the host could point the proof script's client at a live VM: confirmed (`config.c:625-641`; John's `client.ini` names no such file, so the runs here used the scratch files) and fixed with `-C` and a check of the log. P2, a wrong PHOTON sample: confirmed, not fixed, in "Known limits"; its wording point on the waiting requests is fixed. P2, the problem statement claimed more than was observed: confirmed and fixed. P3, the proof kept no record of the script's result: fixed (`<label>.txt`). P3, a failed workspace lookup left the script's folder behind: fixed. P3, the rebuild wording and a README line: fixed. |

The two reviewers disagree on the first P1. `gpt-6.1-sol` and `claude-fable-5-2`
checked the same path and found no visible effect, because the next try redraws
everything. Three review cycles are the limit, so this went to John: accept the
limit as written, or move the retry into `main.c`. On 2026-11-22 John chose to keep
the patch as it is.

After round 3 the patch's header and one code comment changed, with no change to
the code. The proof script changed and has not run on a desktop since: John's
desktop was in use. The patch tests on the pinned source and `bin/check` ran again
on the final tree.
