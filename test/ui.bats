#!/usr/bin/env bats
# Panel settings and detached jobs, using isolated files and a fake CLI.
load helpers

setup() {
  isolate_home
  T=$BATS_TEST_TMPDIR
  source "$REPO/lib/lanai.sh"
  mkdir -p "$XDG_CONFIG_HOME/lanai"
  printf '{"storage":"/test-copy","memory_gib":12,"cores":6,"extra":true}\n' >"$(settings_file)"
}

@test "settings: reads current sizing and preserves storage and unknown keys on save" {
  lanai_run settings
  assert_success
  assert_equal "$(field memory_gib)" 12
  assert_equal "$(field cores)" 6
  lanai_run settings 512 64
  assert_success
  run jq -c '{storage, memory_gib, cores, extra}' "$(settings_file)"
  assert_output '{"storage":"/test-copy","memory_gib":512,"cores":64,"extra":true}'
  assert_equal "$(stat -c %a "$(settings_file)")" 600
}

@test "settings: rejects invalid values with the VM's validation and leaves the file intact" {
  local before mem cores
  before=$(cat "$(settings_file)")
  for mem in 0 513 01 1.5 -1 garbage; do
    lanai_run settings "$mem" 4
    assert_failure
    assert_equal "$(field ok)" false
    run vm_args /test-copy 02:00:00:00:00:01 "$mem" 4 100 ""
    assert_failure
  done
  for cores in 0 65 01 1.5 -1 garbage; do
    lanai_run settings 12 "$cores"
    assert_failure
    run vm_args /test-copy 02:00:00:00:00:01 12 "$cores" 100 ""
    assert_failure
  done
  assert_equal "$(cat "$(settings_file)")" "$before"
  lanai_run settings 1 1
  assert_success
}

@test "settings: refuses broken JSON and symlinks rather than replacing them" {
  printf broken >"$(settings_file)"
  lanai_run settings 8 4
  assert_failure
  assert_equal "$(cat "$(settings_file)")" broken
  rm "$(settings_file)"
  printf '{}' >"$T/target"
  ln -s "$T/target" "$(settings_file)"
  lanai_run settings 8 4
  assert_failure
  assert_equal "$(cat "$T/target")" '{}'
}

@test "notice-seen: atomically clears the verdict with one JSON reply and is repeatable" {
  local s
  s=$(state_dir)
  mkdir -p "$s"
  printf 'forced\n' >"$s/last-run"
  lanai_run notice-seen
  assert_success
  assert_equal "$(field ok)" true
  assert_equal "$(wc -l <<<"$output")" 1
  assert_equal "$(cat "$s/last-run")" clean
  assert_equal "$(stat -c %a "$s/last-run")" 600
  lanai_run notice-seen
  assert_success
  assert_equal "$(cat "$s/last-run")" clean
  run find "$s" -name 'last-run.*'
  assert_output ''
}

@test "notice-seen: refuses arguments and a failed replacement leaves the verdict intact" {
  local s
  s=$(state_dir)
  mkdir -p "$s"
  printf 'forced\n' >"$s/last-run"
  lanai_run notice-seen extra
  assert_failure
  assert_equal "$(cat "$s/last-run")" forced
  shim mv 'exit 1'
  PATH=$T/shims:$PATH lanai_run notice-seen
  assert_failure
  assert_equal "$(field ok)" false
  assert_equal "$(wc -l <<<"$output")" 1
  assert_equal "$(cat "$s/last-run")" forced
  run find "$s" -name 'last-run.*'
  assert_output ''
}

@test "notice-seen: a busy operation cannot overwrite its forced verdict" {
  local s lock_fd
  s=$(state_dir)
  mkdir -p "$s"
  printf 'forced\n' >"$s/last-run"
  exec {lock_fd}>"$s/lock"
  flock "$lock_fd"
  lanai_run notice-seen
  assert_failure
  assert_equal "$(field ok)" false
  assert_equal "$(field message)" "$LANAI_BUSY."
  assert_equal "$(field reason)" busy
  assert_equal "$(wc -l <<<"$output")" 1
  assert_equal "$(cat "$s/last-run")" forced
  exec {lock_fd}>&-
  lanai_run notice-seen
  assert_success
  assert_equal "$(cat "$s/last-run")" clean
}

@test "status: an unfinished restore replaces start and setup guidance while stopped" {
  local setup state
  for setup in 'done' needed; do
    [[ $setup == 'done' ]] && state=stopped || state="setup-needed"
    run status_map <<EOF
ActiveState=inactive
LanaiInstall=present
LanaiSetup=$setup
LanaiRestorePending=true
EOF
    assert_success
    assert_equal "$(jq -r '.state' <<<"$output")" "$state"
    assert_equal "$(jq -r '.active' <<<"$output")" false
    assert_equal "$(jq -r '.message' <<<"$output")" "A restore did not finish, so Windows cannot start."
    assert_equal "$(jq -r '.next' <<<"$output")" "finish the restore in the Lanai panel"
  done
}

@test "snapshots: counts use singular for one and plural for zero or many" {
  local snapshot_count
  snapshot_list() {
    local i
    for ((i = 0; i < snapshot_count; i++)); do printf '%s/snapshot-%s\n' "$T" "$i"; done
  }
  for snapshot_count in 0 1 2; do
    run cmd_snapshots
    assert_success
    assert_equal "$(jq -r '.snapshots | length' <<<"$output")" "$snapshot_count"
    if ((snapshot_count == 1)); then
      assert_equal "$(jq -r '.message' <<<"$output")" "1 snapshot"
    else
      assert_equal "$(jq -r '.message' <<<"$output")" "$snapshot_count snapshots"
    fi
  done
}

@test "status: reports an unfinished restore without contacting a VM or install" {
  # Exercise real facts and mapping, with only external/install reads stubbed.
  systemctl() { printf 'ActiveState=inactive\n'; }
  storage_dir() { return 1; }
  setup_done() { return 1; }
  container_running() { return 1; }
  container_preparing() { return 1; }
  guest_version_behind() { return 1; }
  run lanai_main status
  assert_success
  assert_equal "$(jq -r '.restore_pending' <<<"$output")" false
  mkdir -p "$(state_dir)"
  : >"$(state_dir)/restore-in-progress"
  run lanai_main status
  assert_success
  assert_equal "$(jq -r '.restore_pending' <<<"$output")" true
  assert_equal "$(wc -l <<<"$output")" 1
}

@test "status: setup_done follows LanaiSetup, independent of the displayed state" {
  local facts
  for facts in 'ActiveState=inactive' 'ActiveState=activating' 'ActiveState=deactivating' \
    $'ActiveState=inactive\nLanaiInstall=none' $'ActiveState=inactive\nLanaiContainer=running' \
    $'ActiveState=failed\nResult=exit-code'; do
    run status_map <<<"$facts"
    assert_success
    assert_equal "$(jq -r '.setup_done' <<<"$output")" false
    run status_map <<<"$facts"$'\nLanaiSetup=needed'
    assert_success
    assert_equal "$(jq -r '.setup_done' <<<"$output")" false
    run status_map <<<"$facts"$'\nLanaiSetup=done'
    assert_success
    assert_equal "$(jq -r '.setup_done' <<<"$output")" true
  done
}

@test "ui library: sourcing preserves caller shell options for Bats timeout cleanup" {
  # Entry points own strict mode; an imported library must not change Bats.
  run bash -c '
    set +e +u
    set +o pipefail
    source "$1/lib/ui.sh"
    [[ $- != *e* && $- != *u* ]] || exit 1
    set -o | grep -Eq "^pipefail[[:space:]]+off$"
  ' _ "$REPO"
  assert_success
}

@test "ui library: a failed assertion still emits its Bats result with a timeout" {
  cat >"$T/failure-report.bats" <<'CHILD'
#!/usr/bin/env bats
@test "intentional reporting failure" {
  source "$LANAI_TEST_REPO/lib/lanai.sh"
  false
}
CHILD
  # The child deliberately fails; its result must survive timeout cleanup.
  run env LANAI_TEST_REPO="$REPO" BATS_TEST_TIMEOUT=2 bats "$T/failure-report.bats"
  assert_failure
  assert_output --partial 'not ok 1 intentional reporting failure'
  refute_output --partial 'Executed 0 instead of expected 1'
  refute_output --partial 'BATS_killer_pid: unbound variable'
}

@test "ui timestamp: JSON numbers use a local C locale and leave the caller locale intact" {
  local comma_locale candidate
  comma_locale=''
  while IFS= read -r candidate; do
    if [[ $(LC_ALL=$candidate locale decimal_point) == ',' ]]; then comma_locale=$candidate; break; fi
  done < <(locale -a)
  if [[ -n $comma_locale ]]; then
    LC_ALL=$comma_locale LC_NUMERIC=$comma_locale run bash -c '
      source "$1/lib/ui.sh"
      before=$LC_ALL
      value=$(ui_timestamp)
      jq -ne --argjson t "$value" "\$t > 0"
      [[ $LC_ALL == "$before" ]]
    ' _ "$REPO"
    assert_success
  else
    # Hosts without a comma locale still verify the local formatting guard.
    run declare -f ui_timestamp
    assert_output --partial 'local LC_ALL=C'
  fi
}

@test "busy lock: every operation reports its structured reason" {
  local command fd s
  s=$(state_dir); mkdir -p "$s"
  exec {fd}>"$s/lock"; flock "$fd"
  for command in 'cmd_settings 8 4' cmd_notice_seen 'setup_resume auto false "" ""' 'setup_guest auto' cmd_snapshot 'cmd_restore sample' 'boot_vm false auto'; do
    run bash -c 'source "$1/lib/lanai.sh"; storage_dir() { echo "$TMPDIR/storage"; }; setup_current() { return 0; }; setup_get() { echo declined; }; eval "$2"' _ "$REPO" "$command"
    assert_failure
    assert_equal "$(jq -r .reason <<<"$output")" busy
  done
  exec {fd}>&-
}
