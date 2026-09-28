# Lanai's CLI backend. bin/lanai sources this file and calls lanai_main; tests
# source it directly. It defines functions and constants only.
#
# Every `lanai <command>` prints exactly one JSON object on stdout, then exits:
# {"ok": bool, "state": string|null, "message": string, "next": string|null,
#  ...details}. Diagnostics go to stderr. Commands are the cmd_<name>
# functions below.
# shellcheck shell=bash

# Keep in step with manifest.json (a test checks).
LANAI_VERSION=0.1.0

# --- output ---

# emit <ok true|false> <state> <message> <next> [details-json]: print the one
# JSON object for this call. An empty state or next prints as null.
emit() {
  local out details=${5:-}
  [[ -n $details ]] || details='{}'
  out=$(jq -n -c --argjson ok "$1" --arg state "$2" --arg message "$3" --arg next "$4" \
    --argjson details "$details" \
    '{ok: $ok,
      state: (if $state == "" then null else $state end),
      message: $message,
      next: (if $next == "" then null else $next end)} + $details') || return 1
  printf '%s\n' "$out"
  LANAI_EMITTED=1
}

# EXIT trap of lanai_main: when a command ended without printing its object
# (an error under set -e), print a generic failure. Without a working jq,
# print a fixed object instead.
lanai_on_exit() {
  local rc=$1
  ((${LANAI_EMITTED:-0})) && return 0
  emit false "" "lanai failed (exit $rc); see the error output" "" 2>/dev/null ||
    printf '%s\n' '{"ok":false,"state":null,"message":"lanai failed: jq did not run","next":null}'
}

# lanai_main <command> [args]: run cmd_<command>. Command names are lower-case
# words with dashes; "help" is the default.
lanai_main() {
  local cmd=${1:-help}
  shift || true
  LANAI_EMITTED=0
  trap 'lanai_on_exit $?' EXIT
  if [[ ! $cmd =~ ^[a-z][a-z-]*$ ]] || ! declare -F "cmd_${cmd//-/_}" >/dev/null; then
    emit false "" "unknown command: $cmd" "run lanai help"
    exit 2
  fi
  "cmd_${cmd//-/_}" "$@"
}

# --- commands ---

# help: list the commands.
cmd_help() {
  local names
  names=$(declare -F | awk '$3 ~ /^cmd_/ { sub(/^cmd_/, "", $3); gsub(/_/, "-", $3); print $3 }' |
    jq -R . | jq -s -c .)
  emit true "" "usage: lanai <command>" "" "{\"commands\": $names}"
}

# version: print Lanai's version.
cmd_version() {
  emit true "" "Lanai $LANAI_VERSION" "" "$(jq -n -c --arg v "$LANAI_VERSION" '{version: $v}')"
}

# --- checks shared with the spike (spike/lgtest) ---

# Check <file> against a SHA-256 sum. On mismatch, delete the file and fail,
# so a bad download never lingers.
verify_sha256() {
  local file=$1 want=$2 got
  got=$(sha256sum -- "$file") || return 1
  got=${got%% *}
  if [[ $got != "$want" ]]; then
    rm -f -- "$file"
    printf 'lanai: SHA-256 mismatch for %s: got %s, want %s (file deleted)\n' \
      "$file" "$got" "$want" >&2
    return 1
  fi
}

# Print the command line of every QEMU process, one argument per line, with a
# blank line after each process. Matches on argv[0], bare or with a path, so a
# shell that only mentions QEMU is ignored. Empty output means no QEMU runs.
# LANAI_PROC swaps /proc for a fixture tree.
qemu_cmdlines() {
  local f argv0
  for f in "${LANAI_PROC:-/proc}"/[0-9]*/cmdline; do
    argv0=""
    # stderr is silenced first, so a process that exits mid-scan prints nothing.
    IFS= read -r -d '' argv0 2>/dev/null <"$f" || [[ -n $argv0 ]] || continue
    [[ ${argv0##*/} == qemu-system-x86_64 ]] || continue
    tr '\0' '\n' 2>/dev/null <"$f" || continue
    echo
  done
  return 0
}

# Print the maj:min of the filesystem that holds <path>, trimmed. Used to
# match /proc/locks.
mount_dev() {
  local dev
  dev=$(findmnt -no MAJ:MIN -T "$1" | head -n1) || return 1
  dev=${dev//[[:space:]]/}
  [[ $dev == *:* ]] || return 1
  printf '%s\n' "$dev"
}

# Return 0 if any process holds a lock on <img>, 1 if none does, and 2 if it
# cannot tell. /proc/locks names a file as <maj>:<min>:<inode> with the device
# in %02x:%02x. The device comes from findmnt, because on btrfs stat reports
# the subvolume's device, which never matches /proc/locks. LANAI_LOCKS swaps
# /proc/locks for a fixture.
disk_locked() {
  local img=$1 locks=${LANAI_LOCKS:-/proc/locks} ino dev maj min
  [[ -r $locks ]] || return 2
  ino=$(stat -c %i -- "$img") || return 2
  dev=$(mount_dev "$img") || return 2
  IFS=: read -r maj min <<<"$dev"
  dev=$(printf '%02x:%02x' "$maj" "$min")
  awk -v want="$dev:$ino" '{ for (i = 1; i <= NF; i++) if ($i == want) found = 1 }
    END { exit !found }' "$locks"
}
