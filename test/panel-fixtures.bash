# Isolated backend facts shared by the panel and renderer integration tests.
# shellcheck shell=bash
# shellcheck disable=SC2034,SC2154,SC2329

panel_fixture_setup() {
  # Match CLI pipeline errors without enabling nounset in Bats timeout traps.
  set -o pipefail
  # shellcheck source-path=SCRIPTDIR source=../lib/lanai.sh
  source "$REPO/lib/lanai.sh"
  T=$BATS_TEST_TMPDIR
  S=$(state_dir)
  RUN=$(run_dir)
  STORE=$T/storage
  mkdir -p "$S" "$RUN" "$STORE" "$HOME/Windows" "$(settings_file | xargs dirname)"
  printf '{"storage":"%s","memory_gib":8,"cores":4}\n' "$STORE" >"$(settings_file)"
  echo base >"$STORE/windows.base"
  ST=inactive RESULT=success INV=inv
  systemctl() { printf 'ActiveState=%s\nResult=%s\nInvocationID=%s\n' "$ST" "$RESULT" "$INV"; }
  layout_check() { return 0; }
  share_check() { return 0; }
  host_packages_missing() { :; }
  snapshot_list() { :; }
  guest_version_behind() { :; }
  eval "$(declare -f container_fact | sed '1s/container_fact/real_container_fact/')"
  container_fact() { echo none; }
  qmp_call() { printf '{"return":{"status":"running"}}\n'; }
  helper_alive() { return 0; }
  build_stamp_current() { return 0; }
  build_patches_current() { return 0; }
  # No automatic client update unit runs.
  auto_units() { :; }
  expected_base() { echo fixture.iso; }
  settings_seed() { echo '{"memory_gib":8,"cores":4}'; }
  # A finished setup with the live scale task and the current sign-in mark.
  CURRENT=$(jq -nc --argjson i "$LANAI_SIGNIN_STEP" '{done:true,scale_task:2,signin_step:$i}')
  export T
}

# Write a step 6 timeout as the setup job's ended record.
timeout_record() {
  local reply
  reply=$(setup_stop6 "$1" "UNTRUSTED" "${@:2}") || true
  panel_result_write setup "$(jq -nc --argjson r "$reply" '{command:"setup",started:1,ended:2,reply:$r}')"
}

# Write setup state belonging to the fixture's storage.
state() { jq -nc --arg l "$STORE" --argjson d "$1" '$d + {location:$l}' >"$S/setup.json"; }

# Use real validation and listing for snapshot presentation.
display_snapshot() {
  local snap=$1
  mkdir -p "${snap%/*}"
  mkdir -m 700 "$snap"
  printf image >"$snap/data.img"
  printf '%s\n' "$STORE" >"$snap/SOURCE"
  tree_manifest "$snap" | sed '/ SOURCE$/d' >"$T/manifest"
  cp "$T/manifest" "$snap/COMPLETE"
}

# Mark the earlier checks passed using their combined record.
checks_passed() {
  echo 1 >"$RUN/step6-since"
  echo 1 >"$RUN/step6-checked"
}

# Write current attempt detail with setup's fixed probe vocabulary.
redesign_check_detail() {
  jq -nc --arg l "$STORE" --arg i "$INV" --argjson s "$(cat "$RUN/step6-since")" \
    --argjson c "$1" '$c + {location:$l,invocation:$i,since:$s}' >"$RUN/step6-checks.json"
}
