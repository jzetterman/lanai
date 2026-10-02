# Lanai's setup (plan phase 6): setup state that follows the disk, the
# setup media, and the resumable lanai setup. lib/lanai.sh sources this
# file; it defines functions and constants only.
#
# Setup state lives in <state>/setup.json:
#   location  the storage location it belongs to (storage_dir's real path)
#   snapshot  "taken" or "declined" (step 3)
#   step5     absent until a setup boot starts; false while one has not
#             ended cleanly; true once record_previous_run saw it end with a
#             clean guest shutdown that the panel did not ask for
#   done      true once step 6 passed
# State for another location, or none, counts as no state at all.
# shellcheck shell=bash

# --- setup.json ---

# Print the path of setup.json.
setup_file() {
  printf '%s\n' "$(state_dir)/setup.json"
}

# Print setup.json's <key> (jq -r form; false prints "false"), or nothing
# when the key or the file is missing.
setup_get() {
  jq -r --arg k "$1" 'if type == "object" and has($k) then .[$k] else empty end' \
    "$(setup_file)" 2>/dev/null || true
}

# setup_set <key> <json>: set setup.json's <key> to <json>, or remove it for
# null, keeping the other keys. Replaces the file by rename. Callers hold
# lanai_flock (record_previous_run's callers do too).
setup_set() {
  local f cur
  f=$(setup_file)
  cur=$(jq -c 'if type == "object" then . else {} end' "$f" 2>/dev/null) || cur=""
  [[ -n $cur ]] || cur='{}'
  mkdir -p -- "${f%/*}" &&
    jq -c --arg k "$1" --argjson v "$2" 'if $v == null then del(.[$k]) else .[$k] = $v end' \
      <<<"$cur" >"$f.tmp" &&
    mv -f -- "$f.tmp" "$f"
}

# Return 0 when setup.json belongs to storage location <dir>.
setup_current() {
  jq -e --arg d "$1" '.location == $d' "$(setup_file)" >/dev/null 2>&1
}

# Forget all setup state: run record_previous_run first, so markers from an
# earlier boot cannot mark step 5 done on the new state, then remove
# setup.json and guest-version. Needs lanai_flock and a stopped unit: boot_vm
# (setup boots), lanai setup's resume and lanai restore call it.
setup_reset() {
  local s
  record_previous_run >/dev/null
  s=$(state_dir)
  rm -f -- "$s/setup.json" "$s/guest-version"
}

# setup_follow <dir>: make setup state follow the disk. When setup.json is
# missing, has no location, or names another, and <dir> passes layout_check
# (an unmounted drive behind a symlink must not wipe setup state), it runs
# setup_reset and records <dir> as the location. Same lock rules as
# setup_reset.
setup_follow() {
  local dir=$1
  setup_current "$dir" && return 0
  layout_check "$dir" >/dev/null || return 0
  setup_reset
  setup_set location "$(jq -n -c --arg d "$dir" '$d')"
}
