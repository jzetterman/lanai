# OpenGL renderer on NVIDIA

Small tier: one combined spec and plan for one Looking Glass client flag in
`lib/client.sh`.

## Problem

On an NVIDIA host, opening the Windows window on an empty Hyprland workspace often
fails: the window flashes and closes. With any other window already on the workspace,
it opens.

The client starts normally, connects to the guest and creates its window. Its first
frame then fails and the client exits with status 255:

```
egl.c:1796 | egl_render | Failed to swap EGL buffers (eglError: 0x3000)
```

`eglGetError` reports `EGL_SUCCESS` (0x3000), so the driver gives no reason. Alone on
the workspace, the window's first configure is the whole output; next to another
window it is a split, and the first swap succeeds. The client treats the failed swap
as fatal, `lanai-client.service` exits 255, and the panel shows nothing.

Found by Allen Fox on November 21, 2026 (AKST) during his test install: RTX 4070 SUPER,
NVIDIA 615.78.08, Hyprland 0.56.2, Omarchy, Lanai runtime 0.3.3, client
B7-826-236efcb1. The output was DP-3, 5120x2160 at 165 Hz, scale 1.6.

Counts on an empty workspace (17 on DP-3), same VM and client, the client started by
hand with Lanai's flags plus the one listed, each run held open for 3 to 5 s:

| Renderer, extra flags | Opens that failed |
| --- | ---: |
| EGL (default) | 4 of 8 |
| EGL, `egl:noSwapDamage=yes` | 1 of 1 |
| EGL, `egl:doubleBuffer=yes` | 1 of 1 |
| `app:renderer=OpenGL` | 0 of 7 |

Then `app:renderer=OpenGL` in `client.ini` and five opens through `lanai open` on the
same empty workspace: 0 of 5 failed, and `client.log` showed `Using Renderer: OpenGL`.
On a workspace that already held a window, the EGL renderer opened every time.

## Requirements

1. On an NVIDIA host, Lanai starts the client with `app:renderer=OpenGL`, after the
   existing flags. The probe is the NVIDIA kernel driver's version file,
   `/proc/driver/nvidia/version`, so a host with the driver loaded counts, whichever
   GPU drives the window.
2. Without that file, the flags stay as they are.
3. The command line overrides `client.ini`, so on NVIDIA a `renderer` line there
   cannot bring EGL back. That is the point: EGL is what fails.
4. The README says what it costs on NVIDIA: the EGL renderer's extras, such as its
   scaling filters and HDR to SDR mapping, are not available.

The resize patches (`patches/looking-glass/0001` to `0003`) hook `core.c` and
`main.c`, not the EGL renderer, so they work with either renderer.

## Acceptance

- `client_args` prints `app:renderer=OpenGL` last when the probe file exists, and no
  renderer flag when it does not (`test/client.bats`). The handshake test pins the
  probe to a missing file, so it passes on NVIDIA and other hosts alike.
- The bats suite and shellcheck pass as CI runs them.
- A hand check on an NVIDIA host, on a reflink copy or a test install: with no
  `renderer` line in `client.ini`, open the window five times on an empty workspace
  (close it between opens). Every open stays up, and `client.log` shows
  `Using Renderer: OpenGL`. Live scale and resize behave as before.

## Plan

1. `test/client.bats`: two `client_args` tests (probe present, probe missing), and
   the handshake test pins `LANAI_NVIDIA_VERSION` to a missing file. Run them and see
   the first fail.
2. `lib/client.sh`, `client_args`: print `app:renderer=OpenGL` when the probe exists.
   `LANAI_NVIDIA_VERSION` replaces the probe's path in tests. Run the tests and see
   them pass.
3. `docs/plugin/proofs.md`: a dated section, "Empty-workspace open on NVIDIA
   (2026-11-21, AKST)", with the counts above.
4. `docs/plugin/plan.md`, phase 5's flag list: add the NVIDIA flag.
5. `README.md`, Daily use: one short paragraph on the NVIDIA renderer and its cost.
6. Run `bats test spike/test` and `bin/check`.

## Review log

Not yet reviewed. Contributed from a tester's install; the stage (a) and (b) reviews
and the diff gate are John's to run.
