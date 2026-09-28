# Spike results: Looking Glass software mode vs RDP

Spec: [spec.md](spec.md). Plan: [plan.md](plan.md). Copied from
`spike/assets/results-template.md`.

Tester: John. Dates and times carry their timezone (for example
`2026-09-28 14:00 EDT`).

Transports: `lg` is Looking Glass on the spike VM, `rdp` is RDP on the spike VM,
`rdp-real` is RDP on the real `omarchy-windows-vm` (calibration, tasks 1-6 only).

## Setup

| Item | Value |
|---|---|
| Host monitor (model, resolution, refresh) | |
| Hyprland scale | |
| Windows scale used (from RDP's logic) | |
| Tiled window size and position | |
| Looking Glass build | B7-826-236efcb1 |
| Baseline rows (60 s busy seconds) | |

## Counter check

Both counts must read within 10% of the true rate.

| Running | Native rate | advances/s | repeats | skips | unreadable | Within 10%? |
|---|---|---|---|---|---|---|
| spike VM + LG client | 60 | 59.95 | 553 | 0 | 0 | yes |
| spike VM + LG client | 30 | 30.00 | 857 | 0 | 0 | yes |
| real VM + RDP | 60 | | | | | |
| real VM + RDP | 30 | | | | | |

## Runs

Measured values only; ratings go in the Ratings table. One row per task, mode
and transport. "First" is the transport that went first in this pair (`lg` or
`rdp`). Res, scale and Hz are what Windows reports after each resize.
"Measured" is the task's number: task 1 median frames (240 fps), task 2
frame-index advances/s, tasks 4 and 5 median CPU seconds over idle (from the CPU
runs table), task 7 clipboard both ways and system sound (yes/no), task 8
survives (yes/no). Tasks 3 and 6 have ratings only.

| Task | Mode | Transport | First | Res | Scale | Hz | Measured |
|---|---|---|---|---|---|---|---|
| 1 | fullscreen | lg | | | | | |
| 1 | fullscreen | rdp | | | | | |
| 1 | fullscreen | rdp-real | | | | | |
| 1 | tiled | lg | | | | | |
| 1 | tiled | rdp | | | | | |
| 1 | tiled | rdp-real | | | | | |
| 2 | fullscreen | lg | | | | | |
| 2 | fullscreen | rdp | | | | | |
| 2 | fullscreen | rdp-real | | | | | |
| 2 | tiled | lg | | | | | |
| 2 | tiled | rdp | | | | | |
| 2 | tiled | rdp-real | | | | | |
| 3 | fullscreen | lg | | | | | |
| 3 | fullscreen | rdp | | | | | |
| 3 | fullscreen | rdp-real | | | | | |
| 3 | tiled | lg | | | | | |
| 3 | tiled | rdp | | | | | |
| 3 | tiled | rdp-real | | | | | |
| 4 | fullscreen | lg | | | | | |
| 4 | fullscreen | rdp | | | | | |
| 4 | fullscreen | rdp-real | | | | | |
| 4 | tiled | lg | | | | | |
| 4 | tiled | rdp | | | | | |
| 4 | tiled | rdp-real | | | | | |
| 5 | fullscreen | lg | | | | | |
| 5 | fullscreen | rdp | | | | | |
| 5 | fullscreen | rdp-real | | | | | |
| 5 | tiled | lg | | | | | |
| 5 | tiled | rdp | | | | | |
| 5 | tiled | rdp-real | | | | | |
| 6 | fullscreen | lg | | | | | |
| 6 | fullscreen | rdp | | | | | |
| 6 | fullscreen | rdp-real | | | | | |
| 6 | tiled | lg | | | | | |
| 6 | tiled | rdp | | | | | |
| 6 | tiled | rdp-real | | | | | |
| 7 | fullscreen | lg | | | | | |
| 7 | fullscreen | rdp | | | | | |
| 7 | tiled | lg | | | | | |
| 7 | tiled | rdp | | | | | |
| 8 | fullscreen | lg | | | | | |
| 8 | fullscreen | rdp | | | | | |
| 8 | tiled | lg | | | | | |
| 8 | tiled | rdp | | | | | |

## Ratings

One row per mode and transport, one column per rated item. 1-5: 1 unusable,
2 distracting all the time, 3 noticeable but workable, 4 hard to spot,
5 indistinguishable from a native Linux app. Never combined.

| Mode | Transport | Typing (1) | Web scroll (2) | Excel scroll (2) | Window drag (3) | Video smoothness (4) | A/V sync (4) | Text sharpness (6) | Terminal scroll (6) |
|---|---|---|---|---|---|---|---|---|---|
| fullscreen | lg | | | | | | | | |
| fullscreen | rdp | | | | | | | | |
| fullscreen | rdp-real | | | | | | | | |
| tiled | lg | | | | | | | | |
| tiled | rdp | | | | | | | | |
| tiled | rdp-real | | | | | | | | |

## CPU runs (tasks 4 and 5)

Busy seconds over idle, from `spike/work/results.csv`. Three runs per mode,
alternating Looking Glass and RDP; the median goes into the Runs table. For
task 4, check "Stats for nerds" every run: 1080p60 and the codec.

| Task | Mode | Transport | Run | Busy over idle (s) | Stats for nerds (task 4: resolution, codec) |
|---|---|---|---|---|---|
| 4 | fullscreen | lg | 1 | | |
| 4 | fullscreen | lg | 2 | | |
| 4 | fullscreen | lg | 3 | | |
| 4 | fullscreen | rdp | 1 | | |
| 4 | fullscreen | rdp | 2 | | |
| 4 | fullscreen | rdp | 3 | | |
| 4 | fullscreen | rdp-real | 1 | | |
| 4 | fullscreen | rdp-real | 2 | | |
| 4 | fullscreen | rdp-real | 3 | | |
| 4 | tiled | lg | 1 | | |
| 4 | tiled | lg | 2 | | |
| 4 | tiled | lg | 3 | | |
| 4 | tiled | rdp | 1 | | |
| 4 | tiled | rdp | 2 | | |
| 4 | tiled | rdp | 3 | | |
| 4 | tiled | rdp-real | 1 | | |
| 4 | tiled | rdp-real | 2 | | |
| 4 | tiled | rdp-real | 3 | | |
| 5 | fullscreen | lg | 1 | | n/a |
| 5 | fullscreen | lg | 2 | | n/a |
| 5 | fullscreen | lg | 3 | | n/a |
| 5 | fullscreen | rdp | 1 | | n/a |
| 5 | fullscreen | rdp | 2 | | n/a |
| 5 | fullscreen | rdp | 3 | | n/a |
| 5 | fullscreen | rdp-real | 1 | | n/a |
| 5 | fullscreen | rdp-real | 2 | | n/a |
| 5 | fullscreen | rdp-real | 3 | | n/a |
| 5 | tiled | lg | 1 | | n/a |
| 5 | tiled | lg | 2 | | n/a |
| 5 | tiled | lg | 3 | | n/a |
| 5 | tiled | rdp | 1 | | n/a |
| 5 | tiled | rdp | 2 | | n/a |
| 5 | tiled | rdp | 3 | | n/a |
| 5 | tiled | rdp-real | 1 | | n/a |
| 5 | tiled | rdp-real | 2 | | n/a |
| 5 | tiled | rdp-real | 3 | | n/a |

## Task 1 latency log

Frames at 240 fps from key contact to glyph, one entry per keypress, 10 or more
per transport and mode. One refresh on a 60 Hz panel is 4 frames.

| Mode | Transport | Frames per keypress | Median |
|---|---|---|---|
| fullscreen | lg | | |
| fullscreen | rdp | | |
| fullscreen | rdp-real | | |
| tiled | lg | | |
| tiled | rdp | | |
| tiled | rdp-real | | |

## scroll.ps1 log

One row per run: what the script printed at the end.

| Task | Mode | Transport | Target | Keys sent | Achieved rate | Top of history reached early? |
|---|---|---|---|---|---|---|
| | | | | | | |

## Security check

Plan step 6. The probe port is CUPS on 631 if it listens on loopback only,
else a temporary `python3 -m http.server --bind 127.0.0.1 18631`.

| Check | Result |
|---|---|
| Probe port | 631 (CUPS on `127.0.0.1` and `[::1]` only; router's 631 closed, checked from the host) |
| Positive control (`run --expose-loopback`): guest reached the probe (yes/no) | yes: `Test-NetConnection 192.168.100.1 -Port 631` gave `TcpTestSucceeded : True` |
| Default `run`: probe blocked (yes/no) | yes: `TcpTestSucceeded : False`, ping to the gateway succeeded |
| Web page loads | pending (confirm in Edge) |
| `Resolve-DnsName wikipedia.org` | yes (via the guest's Cloudflare WARP resolver, see Notes) |
| Tailscale MagicDNS name resolves | yes through passt: `Resolve-DnsName dellxps.sawfish-toad.ts.net -Server 192.168.100.1` gave `100.77.254.3`. Without `-Server`, WARP answered NXDOMAIN (see Notes) |

## Notes

- DNS: `dns-forward` to the gateway works; passt also handed the guest the host's search suffix (`sawfish-toad.ts.net`). The guest runs Cloudflare WARP, which replaces the adapter's DNS servers with its own proxy (`127.0.2.2`), so tailnet names fail unless queried at the gateway. Same disk for every transport, so no skew. Plugin note: DNS clients inside Windows (WARP, corporate agents) override the host's resolver.
- Held key under Looking Glass: does it repeat at all?
- Manual touchpad scroll on the web page, per transport (smooth, steppy or laggy):
  - lg:
  - rdp:
  - rdp-real:
- Setup: the IDD's direct input needed a Windows restart after install. Before the restart, the Looking Glass window fell back to SPICE input, which did not reach Windows. Plugin note: the installer flow must restart Windows.
- Setup: closing the `--setup` QEMU window powers the VM off. Harness fix queued: `window-close=off`.
- Harness: `client` can start before QEMU creates the shared-memory file. Fix queued: wait for the file.
- Baselines taken 2026-09-27 (35.0, 19.8, 33.4 busy s) ran while another session ran Hyprland's test suite; retake before measured runs.
- Other:

## Decision

"RDP" means, per measure and mode, the better of `rdp` and `rdp-real`.

- [ ] Looking Glass rates at least equal on all eight ratings, in both modes.
- [ ] In at least one mode, Looking Glass is clearly better on a measured number
      (task 1 median lower by 4 or more frames, or task 2 at least 25% more
      advances/s), and in that same mode at least one rating is 1 point or more
      higher. Mode and evidence:
- [ ] Looking Glass CPU is no more than 1.5x RDP on tasks 4 and 5.
- [ ] Tasks 7 and 8 pass, or pass with a workaround applied and shown working in
      the spike. Workaround, if any:

Result: go to a plugin spec / stop. Why:
