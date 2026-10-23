# Faster CI

Small tier: one combined spec and plan for `.github/workflows/test.yml`.

## Problem

One CI run takes about 20 minutes, and each push to a PR branch starts two.

- The workflow runs on `push` and `pull_request`, so a push to a branch with
  an open PR starts two identical runs. PRs #10 and #11 on October 22, 2026
  (EDT) took 8 runs over two pushes each.
- One job runs every test in series (967 on `main` today), then shellcheck. Bats takes about 18
  minutes and shellcheck about 1 minute. Run 39882401570 (PR #10) gave these
  times per file: `test/panel.bats` 6.4 min, `test/snapshot.bats` 4.2 min,
  `test/setup.bats` 2.9 min, all other files together 4.5 min, plus about
  45 s for the container, packages and checkout.
- On October 22 the job passed its 20-minute limit during shellcheck and was
  cancelled though no test failed. The limit is now 30 minutes (42bb02d).

## Requirements

1. A push to a branch with an open PR starts one run. A push to `main` still
   starts one run. A push to a branch with no PR starts none.
2. Every test file in `test/` and `spike/test/` runs exactly once per run,
   with the same environment as today: an unprivileged user, the loop-mounted
   btrfs image, `LANAI_REQUIRE_BTRFS=1` and `BATS_TEST_TIMEOUT=120`.
3. A new test file runs without a workflow change.
4. Shellcheck checks the same files as today.
5. One failing group does not cancel the others, so a run shows every failure.
6. A new push to a PR cancels that PR's run still in progress. Runs on `main`
   are never cancelled.

## Acceptance

- The PR that makes this change starts one run per push, not two.
- That run finishes in under 10 minutes from start to end.
- The test counts of the bats jobs add up to the count of a local
  `bats --count test spike/test`.
- Each bats job runs its files and no others, and shellcheck passes in its own
  job.

## Plan

1. Triggers: `push` limited to `branches: [main]`, and `pull_request`
   unchanged. Add a top-level `concurrency` with `cancel-in-progress: true`
   and group `${{ github.workflow }}-${{ github.event_name == 'pull_request'
   && github.ref || github.run_id }}`. A PR's runs share one group. Each run
   on `main` gets its own, because GitHub cancels a pending run in a shared
   group even when `cancel-in-progress` is false.
2. Turn the `test` job into a matrix over `group: [panel, snapshot, setup,
   rest]` with `fail-fast: false`. Keep the container, privileges, packages
   (less `shellcheck`, which no test calls), checkout and the btrfs and user
   setup in each job as today. Lower
   `timeout-minutes` to 20, since the slowest group takes about 7 minutes.
3. In the bats step, build the file list from `matrix.group` in bash. One
   bash array holds the named groups (`panel snapshot setup`). A named group
   runs `test/<group>.bats`. `rest` runs every `test/*.bats` and
   `spike/test/*.bats` file except the named ones. Any other `matrix.group`
   value exits non-zero, so a group added to the matrix but not to the array
   fails instead of running its file twice. The other drift, a name in the
   array but not in the matrix, would run its file nowhere and stay green, so
   a comment at both lists says to keep them in sync. A new file lands in `rest` by
   itself, and a renamed named file makes bats fail on the missing path. Print
   the file list before running bats, since its TAP output names no files.
4. Move shellcheck to its own job, `shellcheck`, on `runs-on: ubuntu-24.04`
   with `timeout-minutes: 10`, in the same `archlinux:latest` container
   without `--privileged`. Its steps: install only `shellcheck`,
   check out with the same pinned `actions/checkout` and
   `persist-credentials: false`, then run today's command and file list
   unchanged.
5. Update the workflow's header comment for the groups and the trigger rule.
   `README.md` and `CLAUDE.md` say only that CI runs the tests in an Arch
   container, which stays true.

Check: `actionlint` is not installed, so the PR's own run is the test. Compare
its per-job test counts and printed file lists with a local `bats --count` on
the same tree.

## Review log

| Gate | Stage | Round | Findings | Result |
| --- | --- | ---: | ---: | --- |
| Doc | a (gpt-6.1-sol) | 1 | 2 | Two P2 confirmed: a shared concurrency group cancels a pending `main` run, so each `main` run gets its own group; the shellcheck job needs its own checkout. Integrated. |
| Doc | a (gpt-6.1-sol) | 2 | 0 | Clean. |
| Doc | b single (opus-5.5) | 1 | 3 | Three nits, all integrated, so stage (b) closed: one array of named groups with a non-zero exit for an unknown group, print each job's file list, and pin the shellcheck job's runner and a 10-minute timeout. The doc gate is closed. |
| Diff | a (gpt-6.1-sol) | 1 | 0 | Clean on `git diff main...ci-speed-impl` through 6b97be1; 0 refuted, 0 downgraded to nit. Codex ran the file-list logic: all 17 files (967 tests) run exactly once. |
| Diff | b panel (opus-5.5), 3 lenses | 1 | 6 | 8 raw, 6 distinct after dedupe; 0 refuted, 0 downgraded to nit; 1 should-fix confirmed: a group added to `named_groups` but not to the matrix would drop its file from every job with CI still green, so both lists now say to keep them in sync. Fixed with these nits: the header comment now scopes privilege to the test job, says "concurrency group" and notes that tags and other branches no longer run; the test job drops the unused shellcheck package and a redundant GROUP guard; the file list prints under a label. |
| Diff | b panel (opus-5.5), 3 lenses | 2 | 4 | 4 raw, 4 distinct; 0 refuted, 0 downgraded to nit; all nits, so stage (b) closed. Fixed: the loop variable `group` beside `GROUP` is now `name`, and plan steps 2 and 3 now name the dropped shellcheck package and the keep-in-sync comments. Accepted: an approved fork PR could edit its workflow to cancel a run by its public concurrency group, at worst one rerun. |
| Diff | a (gpt-6.1-sol) | 2 | 0 | Rerun on the final diff through 83fdbfa. Clean; 0 refuted, 0 downgraded to nit. The diff gate is closed. |
