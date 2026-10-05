# Settings and detached panel jobs. Sourced by lib/lanai.sh.
# shellcheck shell=bash
set -euo pipefail

# settings [<memory GiB> <cores>]: preserve all other keys; apply next boot.
# The ranges and integer syntax are the same as vm_args in lib/vm.sh.
cmd_settings() {
  local f doc='{}' mem cores tmp
  f=$(settings_file)
  if [[ -L $f ]] || { [[ -e $f ]] && ! doc=$(jq -ce 'select(type == "object")' "$f"); }; then
    emit false "" "Lanai cannot read its settings file: $f." "repair that file, then try again"
    return 1
  fi
  if (($# == 0)); then
    read -r mem cores < <(vm_settings) || return 1
  elif (($# == 2)); then
    mem=$1 cores=$2
  else
    emit false "" "Settings need memory in GiB and cores." "use lanai settings <memory> <cores>"
    return 2
  fi
  if [[ ! $mem =~ ^[1-9][0-9]{0,2}$ ]] || ((mem > 512)); then
    emit false "" "Memory must be a whole number of GiB from 1 to 512." "choose a valid memory size"
    return 2
  fi
  if [[ ! $cores =~ ^[1-9][0-9]?$ ]] || ((cores > 64)); then
    emit false "" "Cores must be a whole number from 1 to 64." "choose a valid core count"
    return 2
  fi
  if (($#)); then
    if ! lanai_flock; then
      emit false "" "$LANAI_BUSY." "try again when it finishes"
      return 1
    fi
    # Read again under the operation lock: setup may have seeded settings.
    if [[ -L $f ]] || { [[ -e $f ]] && ! doc=$(jq -ce 'select(type == "object")' "$f"); }; then
      emit false "" "Lanai cannot read its settings file: $f." "repair that file"
      return 1
    fi
    if ! mkdir -p -- "${f%/*}" || ! tmp=$(mktemp "$f.XXXXXX"); then return 1; fi
    if ! jq --argjson m "$mem" --argjson c "$cores" '. + {memory_gib:$m, cores:$c}' <<<"$doc" >"$tmp" ||
      ! mv -f -- "$tmp" "$f"; then
      rm -f -- "$tmp"
      return 1
    fi
  fi
  emit true "" "VM settings apply at the next start." "" \
    "$(jq -nc --argjson m "$mem" --argjson c "$cores" '{memory_gib:$m, cores:$c}')"
}

# Atomically publish the single panel job's progress or completion.
panel_job_write() {
  local f tmp
  f=$(state_dir)/panel-job.json
  tmp=$(mktemp "$f.XXXXXX") || return 1
  if ! printf '%s\n' "$1" >"$tmp" || ! mv -f -- "$tmp" "$f"; then
    rm -f -- "$tmp"
    return 1
  fi
}

# ui-job <token> setup|snapshot|restore [args]: launched with execDetached.
# This lock survives panel unloading and serializes jobs across all monitors.
cmd_ui_job() {
  local token=${1:-} command=${2:-} s out args rc=0 fd
  if [[ ! $token =~ ^[A-Za-z0-9-]+$ || ! $command =~ ^(setup|snapshot|restore)$ ]]; then
    emit false "" "Invalid panel job." ""
    return 2
  fi
  shift 2
  umask 077
  args=$(jq -nc '$ARGS.positional' --args -- "$@")
  s=$(state_dir)
  mkdir -p -- "$s"
  exec {fd}>>"$s/panel-job.lock"
  if ! flock -n "$fd"; then
    emit false "" "A panel job is already running." "wait for it to finish"
    return 1
  fi
  panel_job_write "$(jq -nc --arg t "$token" --arg c "$command" --argjson a "$args" '{token:$t, command:$c, args:$a, active:true}')"
  out=$("$LANAI_BIN/lanai" "$command" "$@" 2>>"$s/panel-job.log") || rc=$?
  if ! jq -se 'length == 1 and (.[0] | type == "object" and (.ok | type == "boolean"))' <<<"$out" >/dev/null 2>&1; then
    out=$(jq -nc --arg m "Lanai gave no valid reply (exit $rc)." \
      --arg n "see $s/panel-job.log, then retry" '{ok:false, message:$m, next:$n}')
  fi
  panel_job_write "$(jq -nc --arg t "$token" --arg c "$command" --argjson r "$out" --argjson a "$args" \
    '{token:$t, command:$c, args:$a, active:false, reply:$r}')"
  emit true "" "Panel job finished." ""
}

# ui-job-status: bounded, read-only polling; a free lock detects a dead worker.
cmd_ui_job_status() {
  local s doc fd
  s=$(state_dir)
  if [[ ! -f $s/panel-job.json ]]; then
    emit true "" "No panel job." "" '{"active":false}'
    return
  fi
  doc=$(jq -ce 'select(type == "object")' "$s/panel-job.json") || return 1
  if [[ $(jq -r '.active' <<<"$doc") == true ]]; then
    exec {fd}>>"$s/panel-job.lock"
    if flock -n "$fd"; then
      # The worker may have finished after our first read, before releasing its lock.
      doc=$(jq -ce 'select(type == "object")' "$s/panel-job.json") || return 1
      if [[ $(jq -r '.active' <<<"$doc") == true ]]; then
        doc=$(jq -c '. + {active:false, reply:{ok:false, message:"The operation was interrupted.", next:"try again; setup and restore can resume"}}' <<<"$doc")
      fi
    fi
  fi
  emit true "" "Panel job status." "" "$doc"
}
