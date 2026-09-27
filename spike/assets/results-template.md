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
| spike VM + viewer | 60 | | | | | |
| spike VM + viewer | 30 | | | | | |
| real VM + RDP | 60 | | | | | |
| real VM + RDP | 30 | | | | | |

## Runs

One row per task, mode and transport. Res, scale and Hz are what Windows reports
after each resize. "Measured" is the task's number: task 1 median frames
(240 fps), task 2 frame-index advances/s, tasks 4 and 5 median CPU seconds over
idle (from the CPU table), task 7 clipboard both ways and system sound (yes/no),
task 8 survives (yes/no). Ratings are 1-5: 1 unusable, 2 distracting all the
time, 3 noticeable but workable, 4 hard to spot, 5 indistinguishable from a
native Linux app.

| Task | Mode | Transport | Res | Scale | Hz | Measured | Typing | Web scroll | Excel scroll | Window drag | Video | A/V sync | Text | Terminal scroll |
|---|---|---|---|---|---|---|---|---|---|---|---|---|---|---|
| 1 | fullscreen | lg | | | | | | | | | | | | |
| 1 | fullscreen | rdp | | | | | | | | | | | | |
| 1 | fullscreen | rdp-real | | | | | | | | | | | | |
| 1 | tiled | lg | | | | | | | | | | | | |
| 1 | tiled | rdp | | | | | | | | | | | | |
| 1 | tiled | rdp-real | | | | | | | | | | | | |
| 2 | fullscreen | lg | | | | | | | | | | | | |
| 2 | fullscreen | rdp | | | | | | | | | | | | |
| 2 | fullscreen | rdp-real | | | | | | | | | | | | |
| 2 | tiled | lg | | | | | | | | | | | | |
| 2 | tiled | rdp | | | | | | | | | | | | |
| 2 | tiled | rdp-real | | | | | | | | | | | | |
| 3 | fullscreen | lg | | | | | | | | | | | | |
| 3 | fullscreen | rdp | | | | | | | | | | | | |
| 3 | fullscreen | rdp-real | | | | | | | | | | | | |
| 3 | tiled | lg | | | | | | | | | | | | |
| 3 | tiled | rdp | | | | | | | | | | | | |
| 3 | tiled | rdp-real | | | | | | | | | | | | |
| 4 | fullscreen | lg | | | | | | | | | | | | |
| 4 | fullscreen | rdp | | | | | | | | | | | | |
| 4 | fullscreen | rdp-real | | | | | | | | | | | | |
| 4 | tiled | lg | | | | | | | | | | | | |
| 4 | tiled | rdp | | | | | | | | | | | | |
| 4 | tiled | rdp-real | | | | | | | | | | | | |
| 5 | fullscreen | lg | | | | | | | | | | | | |
| 5 | fullscreen | rdp | | | | | | | | | | | | |
| 5 | fullscreen | rdp-real | | | | | | | | | | | | |
| 5 | tiled | lg | | | | | | | | | | | | |
| 5 | tiled | rdp | | | | | | | | | | | | |
| 5 | tiled | rdp-real | | | | | | | | | | | | |
| 6 | fullscreen | lg | | | | | | | | | | | | |
| 6 | fullscreen | rdp | | | | | | | | | | | | |
| 6 | fullscreen | rdp-real | | | | | | | | | | | | |
| 6 | tiled | lg | | | | | | | | | | | | |
| 6 | tiled | rdp | | | | | | | | | | | | |
| 6 | tiled | rdp-real | | | | | | | | | | | | |
| 7 | fullscreen | lg | | | | | | | | | | | | |
| 7 | fullscreen | rdp | | | | | | | | | | | | |
| 7 | tiled | lg | | | | | | | | | | | | |
| 7 | tiled | rdp | | | | | | | | | | | | |
| 8 | fullscreen | lg | | | | | | | | | | | | |
| 8 | fullscreen | rdp | | | | | | | | | | | | |
| 8 | tiled | lg | | | | | | | | | | | | |
| 8 | tiled | rdp | | | | | | | | | | | | |

## CPU runs (tasks 4 and 5)

Busy seconds over idle, from `spike/work/results.csv`. Three runs alternating
Looking Glass and RDP; the median goes into the Runs table.

| Task | Mode | Transport | Run 1 | Run 2 | Run 3 | Median |
|---|---|---|---|---|---|---|
| 4 | fullscreen | lg | | | | |
| 4 | fullscreen | rdp | | | | |
| 4 | fullscreen | rdp-real | | | | |
| 4 | tiled | lg | | | | |
| 4 | tiled | rdp | | | | |
| 4 | tiled | rdp-real | | | | |
| 5 | fullscreen | lg | | | | |
| 5 | fullscreen | rdp | | | | |
| 5 | fullscreen | rdp-real | | | | |
| 5 | tiled | lg | | | | |
| 5 | tiled | rdp | | | | |
| 5 | tiled | rdp-real | | | | |

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

## Notes

- DNS: which form worked (`dns-forward` to the gateway, or the `dns=` fallback),
  and whether a Tailscale MagicDNS name resolved:
- Held key under Looking Glass: does it repeat at all?
- Manual touchpad scroll on the web page, per transport (smooth, steppy or laggy):
  - lg:
  - rdp:
  - rdp-real:
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
