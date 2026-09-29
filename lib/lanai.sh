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

# This file's folder. The VM and copy helpers live beside it.
LANAI_LIB=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)
# shellcheck source-path=SCRIPTDIR source=copy.sh
source "$LANAI_LIB/copy.sh"
# shellcheck source-path=SCRIPTDIR source=vm.sh
source "$LANAI_LIB/vm.sh"
# shellcheck source-path=SCRIPTDIR source=snapshot.sh
source "$LANAI_LIB/snapshot.sh"
# shellcheck source-path=SCRIPTDIR source=client.sh
source "$LANAI_LIB/client.sh"

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

# Print the pid of every QEMU process, one per line. Matches on argv[0], bare
# or with a path, so a shell that only mentions QEMU is ignored. LANAI_PROC
# swaps /proc for a fixture tree.
qemu_pids() {
  local f argv0 pid
  for f in "${LANAI_PROC:-/proc}"/[0-9]*/cmdline; do
    argv0=""
    # stderr is silenced first, so a process that exits mid-scan prints nothing.
    IFS= read -r -d '' argv0 2>/dev/null <"$f" || [[ -n $argv0 ]] || continue
    [[ ${argv0##*/} == qemu-system-x86_64 ]] || continue
    pid=${f%/cmdline}
    printf '%s\n' "${pid##*/}"
  done
  return 0
}

# Print the command line of every QEMU process, one argument per line, with a
# blank line after each process. Empty output means no QEMU runs.
qemu_cmdlines() {
  local pid
  for pid in $(qemu_pids); do
    tr '\0' '\n' 2>/dev/null <"${LANAI_PROC:-/proc}/$pid/cmdline" || continue
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

# --- adoption checks and settings (plan phase 3) ---

# Print the path of Lanai's settings file.
settings_file() {
  printf '%s\n' "${XDG_CONFIG_HOME:-$HOME/.config}/lanai/settings.json"
}

# Print the storage location Lanai uses (spec 6a): settings.json's "storage",
# else ~/.windows. A symlink resolves to its target (omarchy-windows-vm
# accepts a symlinked ~/.windows), so every check sees the real folder; a
# path that does not exist prints as is. ~/.windows is the default only when
# there is no settings file at all. Fails when the settings file is a symlink
# (dangling or not), cannot be read or parsed, or names a relative path, so a
# broken file never falls back to the live install.
storage_dir() {
  local f dir=""
  f=$(settings_file)
  # Only a settings file that does not exist at all means the default.
  if [[ -L $f ]]; then
    echo "lanai: $f is a symlink; Lanai reads only a regular settings file" >&2
    return 1
  elif [[ -e $f ]]; then
    dir=$(jq -r 'if (type == "object" and (.storage | type) == "string") then .storage
      elif (type == "object" and .storage == null) then ""
      else error("storage must be a string") end' "$f") || {
      echo "lanai: cannot read the storage location from $f" >&2
      return 1
    }
    [[ -z $dir || $dir == /* ]] || {
      echo "lanai: the storage location in $f must be an absolute path" >&2
      return 1
    }
  fi
  [[ -n $dir ]] || dir=$HOME/.windows
  realpath -e -- "$dir" 2>/dev/null || printf '%s\n' "$dir"
}

# Print the path of omarchy-windows-vm's compose file: the system one, else
# the legacy ~/.config/windows/docker-compose.yml. It may not be readable;
# callers check. A system folder Lanai cannot search counts as holding the
# file. Fails when neither exists. OMARCHY_WINDOWS_DIR moves the system
# folder, as it does for omarchy-windows-vm.
compose_file() {
  local dir=${OMARCHY_WINDOWS_DIR:-/var/lib/omarchy/windows}
  local legacy=$HOME/.config/windows/docker-compose.yml
  if [[ -e $dir/docker-compose.yml ]] || [[ -d $dir && ! -x $dir ]]; then
    printf '%s\n' "$dir/docker-compose.yml"
  elif [[ -e $legacy ]]; then
    printf '%s\n' "$legacy"
  else
    return 1
  fi
}

# Print the value of the first <key> line in the compose file <file>. Only
# that line is read into Lanai, so other values (the Windows password) never
# leave the file. Prints nothing when the key is missing. The line must be
# `KEY: "value"`, `KEY: 'value'` or `KEY: value` with no quotes or comment
# in the value. Returns 1 when the file cannot be read, and 2 when the key's
# line is in any other form, or the key also appears in the list form
# (`- KEY=value`), which Lanai does not parse: omarchy-windows-vm always
# writes the map form. Either way Lanai cannot tell what dockur would read.
compose_value() {
  local file=$1 key=$2 line rc=0 q=\' d=\"
  [[ $key =~ ^[A-Z_]+$ ]] || return 1
  grep -q -E "^[[:space:]]*-[[:space:]]*[\"']?$key=" -- "$file" || rc=$?
  if ((rc == 0)); then
    echo "lanai: cannot interpret $key in $file (list form)" >&2
    return 2
  elif ((rc != 1)); then
    return 1
  fi
  rc=0
  line=$(grep -m1 -E "^[[:space:]]*$key:" -- "$file") || rc=$?
  ((rc != 1)) || return 0
  ((rc == 0)) || return 1
  local pre="^[[:space:]]*$key:[[:space:]]*" post='[[:space:]]*$'
  local dquoted="$d([^$d]*)$d" squoted="$q([^$q]*)$q"
  local bare="([^$d$q#[:space:]]([^$d$q#]*[^$d$q#[:space:]])?)?"
  if [[ $line =~ $pre$dquoted$post ]] || [[ $line =~ $pre$squoted$post ]] ||
    [[ $line =~ $pre$bare$post ]]; then
    printf '%s\n' "${BASH_REMATCH[1]}"
  else
    echo "lanai: cannot interpret $key in $file" >&2
    return 2
  fi
}

# Print the readable compose file, or fail when there is none Lanai can read
# without a prompt.
readable_compose() {
  local f
  f=$(compose_file) && [[ -r $f ]] && printf '%s\n' "$f"
}

# Print the install image name dockur 6.05 derives from VERSION and LANGUAGE
# and stores in windows.base (install.sh getInstallFile and getBootFile).
# Fails, printing why, for a URL VERSION or a LANGUAGE dockur does not know.
dockur_base() {
  local version language v lang
  version=$(dockur_strip "$1")
  language=$(dockur_strip "$2")
  if [[ ${version,,} == http* ]]; then
    echo "VERSION is a URL, which Lanai does not support"
    return 1
  fi
  [[ -n $version ]] || version=win11
  v=$(dockur_version_id "$version")
  lang=${language//_/-}
  [[ -n $lang ]] || lang=en
  lang=$(dockur_culture "$lang") || {
    echo "LANGUAGE \"$language\" is not one dockur knows"
    return 1
  }
  if [[ $lang == en ]]; then
    printf '%s.iso\n' "${v//\//}"
  else
    printf '%s_%s.iso\n' "${v//\//}" "$lang"
  fi
}

# dockur's strip (utils.sh): trim white space, drop one leading and trailing
# double and single quote, then trim white space again.
dockur_strip() {
  local s=$1
  s="${s#"${s%%[![:space:]]*}"}"
  s="${s%"${s##*[![:space:]]}"}"
  s=${s%\"} s=${s#\"} s=${s%\'} s=${s#\'}
  s="${s#"${s%%[![:space:]]*}"}"
  s="${s%"${s##*[![:space:]]}"}"
  printf '%s\n' "$s"
}

# Print dockur 6.05's canonical id for a VERSION alias (define.sh
# parseVersion). Other values stay as given.
dockur_version_id() {
  case "${1,,}" in
    11 | 11p | win11 | pro11 | win11p | windows11 | "windows 11") echo win11x64 ;;
    11e | win11e | windows11e | "windows 11e") echo win11x64-enterprise-eval ;;
    11l | 11ltsc | ltsc11 | win11l | win11-ltsc | win11x64-ltsc) echo win11x64-enterprise-ltsc-eval ;;
    11i | 11iot | iot11 | win11i | win11-iot | win11x64-iot) echo win11x64-enterprise-iot-eval ;;
    10 | 10p | win10 | pro10 | win10p | windows10 | "windows 10") echo win10x64 ;;
    10e | win10e | windows10e | "windows 10e") echo win10x64-enterprise-eval ;;
    10l | 10ltsc | ltsc10 | win10l | win10-ltsc | win10x64-ltsc) echo win10x64-enterprise-ltsc-eval ;;
    10i | 10iot | iot10 | win10i | win10-iot | win10x64-iot) echo win10x64-enterprise-iot-eval ;;
    8 | 8p | 81 | 81p | pro8 | 8.1 | win8 | win8p | win81 | win81p | "windows 8") echo win81x64 ;;
    8e | 81e | 8.1e | win8e | win81e | "windows 8e") echo win81x64-enterprise-eval ;;
    7 | win7 | windows7 | "windows 7") echo win7x64 ;;
    7u | win7u | windows7u | "windows 7u") echo win7x64-ultimate ;;
    7e | win7e | windows7e | "windows 7e") echo win7x64-enterprise ;;
    7x86 | win7x86 | win732 | windows7x86) echo win7x86 ;;
    7ux86 | 7u32 | win7x86-ultimate) echo win7x86-ultimate ;;
    7ex86 | 7e32 | win7x86-enterprise) echo win7x86-enterprise ;;
    vista | vs | 6 | winvista | windowsvista | "windows vista") echo winvistax64 ;;
    vistu | vu | 6u | winvistu) echo winvistax64-ultimate ;;
    viste | ve | 6e | winviste) echo winvistax64-enterprise ;;
    vistax86 | vista32 | 6x86 | winvistax86 | windowsvistax86) echo winvistax86 ;;
    vux86 | vu32 | winvistax86-ultimate) echo winvistax86-ultimate ;;
    vex86 | ve32 | winvistax86-enterprise) echo winvistax86-enterprise ;;
    xp | xp32 | xpx86 | 5 | 5x86 | winxp | winxp86 | windowsxp | "windows xp") echo winxpx86 ;;
    xp64 | xpx64 | 5x64 | winxp64 | winxpx64 | windowsxp64 | windowsxpx64) echo winxpx64 ;;
    2k | 2000 | win2k | win2000 | windows2k | windows2000) echo win2kx86 ;;
    me | winme | win9x | windowsme | "windows me") echo win9x ;;
    98 | 98se | win98 | win98se | windows98 | windows98se | "windows 98" | "windows 98 se") echo win98 ;;
    95 | 95c | win95 | win95c | windows95 | "windows 95") echo win95 ;;
    25 | 2025 | win25 | win2025 | windows2025 | "windows 2025") echo win2025-eval ;;
    22 | 2022 | win22 | win2022 | windows2022 | "windows 2022") echo win2022-eval ;;
    19 | 2019 | win19 | win2019 | windows2019 | "windows 2019") echo win2019-eval ;;
    16 | 2016 | win16 | win2016 | windows2016 | "windows 2016") echo win2016-eval ;;
    hv | hyperv | "hyper v" | hyper-v | 19hv | 2019hv | win2019hv) echo win2019-hv ;;
    2012 | 2012r2 | win2012 | win2012r2 | windows2012 | "windows 2012") echo win2012r2-eval ;;
    2008 | 2008r2 | 2k8 | win2008 | win2008r2 | windows2008 | "windows 2008") echo win2008r2 ;;
    2003 | 2003r2 | 2k3 | win2003 | win2003r2 | windows2003 | "windows 2003") echo win2003r2 ;;
    core11 | "core 11") echo core11 ;;
    tiny11 | "tiny 11") echo tiny11 ;;
    tiny10 | "tiny 10") echo tiny10 ;;
    reactos | "react os") echo reactos ;;
    *) printf '%s\n' "$1" ;;
  esac
}

# Print the language part of the culture dockur 6.05 maps LANGUAGE to
# (define.sh getLanguage "culture", before the dash). Fails for a language
# dockur does not know. Order matters: specific forms come first.
dockur_culture() {
  case "${1,,}" in
    ar | ar-* | arabic | arab) echo ar ;;
    bg | bg-* | bulgarian | bu) echo bg ;;
    cs | cs-* | cz | cz-* | czech | cesky) echo cs ;;
    da | da-* | dk | dk-* | danish | danske) echo da ;;
    de | de-* | german | deutsch) echo de ;;
    el | el-* | gr | gr-* | greek) echo el ;;
    gb | en-gb | british) echo en ;;
    en | en-* | english) echo en ;;
    mx | es-mx) echo es ;;
    es | es-* | spanish | espanol | español) echo es ;;
    et | et-* | estonian | eesti) echo et ;;
    fi | fi-* | finnish | suomi) echo "fi" ;;
    ca | fr-ca) echo fr ;;
    fr | fr-* | french | français | francais) echo fr ;;
    he | he-* | il | il-* | hebrew) echo he ;;
    hr | hr-* | cr | cr-* | croatian | hrvatski) echo hr ;;
    hu | hu-* | hungarian | magyar) echo hu ;;
    it | it-* | italian | italiano) echo it ;;
    ja | ja-* | jp | jp-* | japanese) echo ja ;;
    ko | ko-* | kr | kr-* | korean) echo ko ;;
    lt | lt-* | lithuanian | lietuvos) echo lt ;;
    lv | lv-* | latvian | latvijas) echo lv ;;
    nb | nb-* | nn | nn-* | no | no-* | norwegian | norsk) echo nb ;;
    nl | nl-* | dutch | nederlands) echo nl ;;
    pl | pl-* | polish | polski) echo pl ;;
    br | pt | pt-br | portuguese | português | portugues | pt-*) echo pt ;;
    ro | ro-* | romanian | română | romana) echo ro ;;
    ru | ru-* | russian | ruski) echo ru ;;
    sk | sk-* | slovak | slovenský | slovensky) echo sk ;;
    sl | sl-* | si | si-* | slovenian | slovenski) echo sl ;;
    sr | sr-* | serbian | "serbian latin") echo sr ;;
    sv | sv-* | se | se-* | swedish | svenska) echo sv ;;
    th | th-* | thai) echo th ;;
    tr | tr-* | turkish | türk | turk) echo tr ;;
    ua | ua-* | uk | uk-* | ukrainian) echo uk ;;
    hk | zh-hk | cn-hk | tw | zh-tw | cn-tw | zh | zh-* | cn | cn-* | chinese) echo zh ;;
    *) return 1 ;;
  esac
}

# Print the windows.base name dockur would expect here, from the compose's
# VERSION and LANGUAGE. A missing key gets dockur's default, as dockur does.
# Only when the compose cannot be read does it use the values
# omarchy-windows-vm always sets (VERSION 11, no LANGUAGE), per spec 5a. A
# key line it cannot interpret fails, printing which key.
expected_base() {
  local f key rc
  local -A v=()
  if ! f=$(readable_compose); then
    dockur_base 11 ""
    return
  fi
  for key in VERSION LANGUAGE; do
    rc=0
    v[$key]=$(compose_value "$f" "$key" 2>/dev/null) || rc=$?
    if ((rc == 2)); then
      echo "cannot interpret $key in omarchy-windows-vm's settings"
      return 1
    elif ((rc != 0)); then
      # The file became unreadable after the check.
      dockur_base 11 ""
      return
    fi
  done
  dockur_base "${v[VERSION]}" "${v[LANGUAGE]}"
}

# Check that <dir> is an omarchy-windows-vm install Lanai supports and that
# none of dockur's destructive or rewriting paths can trigger (spec 5, 5a).
# The top level may hold only the allow-list, each a regular file. Prints each
# problem on its own line. Returns 0 when it passes, 1 when refused, and 2
# when there is no install (a missing or empty folder). Reads only.
layout_check() {
  local dir=$1 name p f base want rc
  local -a entries=() problems=()
  if [[ -e $dir && ! -d $dir ]]; then
    echo "$dir is not a folder"
    return 1
  fi
  if [[ -d $dir && ! (-r $dir && -x $dir) ]]; then
    echo "cannot read $dir"
    return 1
  fi
  if [[ -d $dir ]]; then
    mapfile -d '' entries < <(find "$dir" -mindepth 1 -maxdepth 1 -printf '%P\0' | LC_ALL=C sort -z)
  fi
  if ((${#entries[@]} == 0)); then
    echo "No Windows install at $dir. Install Windows with omarchy-windows-vm first."
    return 2
  fi

  for name in "${entries[@]}"; do
    p=$dir/$name
    case $name in
      data.img | windows.base | windows.boot | windows.mac | windows.rom | windows.vars | windows.ver)
        [[ -f $p && ! -L $p ]] || problems+=("$name: not a regular file")
        continue
        ;;
    esac
    case ${name,,} in
      windows.mode) problems+=("$name: this install uses Secure Boot or legacy BIOS boot, which Lanai does not support") ;;
      *.tpm) problems+=("$name: this install has a TPM, which Lanai does not support") ;;
      data.qcow2)
        if [[ -e $dir/data.img ]]; then
          problems+=("data.img and data.qcow2 both exist; dockur could pick either disk")
        else
          problems+=("$name: Lanai supports only a raw data.img disk")
        fi
        ;;
      windows.hv | windows.vga | windows.usb | windows.sound | windows.net | windows.port | windows.cpu | \
        windows.type | windows.bios | windows.flag | windows.args | windows.old | windows.system | windows.img)
        problems+=("$name: a dockur hardware override (a legacy layout), which Lanai does not support")
        ;;
      custom.iso | boot.iso)
        problems+=("$name: install media; while it is here, dockur would reinstall Windows over this disk. Move it out of $dir")
        ;;
      tmp) problems+=("tmp/: dockur's scratch folder from an unfinished start; delete it") ;;
      setup.img | setup.img.tmp) problems+=("$name: dockur's setup image from an unfinished start; delete it") ;;
      backups) problems+=("backups/: dockur moved an earlier install here; check it, then move it out of $dir") ;;
      *) problems+=("$name: not part of an omarchy-windows-vm install; move it out of $dir") ;;
    esac
  done

  for f in windows.rom windows.vars windows.mac; do
    [[ -s $dir/$f ]] || problems+=("$f is missing or empty; dockur would replace it")
  done
  [[ -e $dir/windows.boot ]] ||
    problems+=("windows.boot is missing: the install never finished, and dockur would install Windows again")
  if [[ ! -s $dir/data.img ]]; then
    [[ -e $dir/data.qcow2 ]] ||
      problems+=("data.img is missing or empty; dockur would install Windows on a new disk")
  elif (($(stat -c %s -- "$dir/data.img") < 102400)); then
    problems+=("data.img is smaller than 100 KB, so it is not a Windows disk")
  else
    # dockur's hasData: a disk whose first 100 KiB are zero counts as blank.
    # cmp: 0 = all zero, 1 = data; anything else (cmp missing, the disk
    # unreadable) fails closed.
    rc=2
    if command -v cmp >/dev/null; then
      rc=0
      cmp -s -n 102400 -- "$dir/data.img" /dev/zero || rc=$?
    fi
    case $rc in
      0) problems+=("the first 100 KB of data.img are all zero; dockur would treat the disk as blank and install Windows again") ;;
      1) ;;
      *) problems+=("cannot read the first 100 KB of data.img") ;;
    esac
  fi

  if [[ -s $dir/windows.base ]]; then
    # dockur's readFile: drop trailing newlines and unprintable characters.
    base=$(<"$dir/windows.base")
    base=${base//[![:print:]]/}
    if ! want=$(expected_base); then
      problems+=("windows.base: cannot tell which image the container's settings give ($want)")
    elif [[ ${base,,} != "${want,,}" ]]; then
      problems+=("windows.base names $base, but the container's settings give $want; dockur would install Windows again")
    fi
  fi

  ((${#problems[@]} == 0)) && return 0
  printf '%s\n' "${problems[@]}"
  return 1
}

# Print DISK_SIZE the way dockur 6.05 reads it (init.sh strip, then disk.sh
# normalizeSize and normalizeDiskSize): no spaces, a bare number gets G,
# upper case, MB/GB/TB become M/G/T, and empty means 64G. max and half,
# which depend on free space at start, stay as they are.
dockur_disk_size() {
  local s
  s=$(dockur_strip "$1")
  s=${s// /}
  [[ -n $s ]] || s=64G
  [[ -n ${s//[0-9.]/} ]] || s+=G
  s=${s^^}
  s=${s//MB/M} s=${s//GB/G} s=${s//TB/T}
  printf '%s\n' "$s"
}

# Check that <dir>/data.img is at least the compose's DISK_SIZE, so a
# container start would not grow it (spec 5a). Prints one line. Returns 0
# when it passes, and 2 ("not checked") only when the compose cannot be
# read. With a readable compose it refuses (1) a smaller disk, a DISK_SIZE
# line it cannot interpret, a dynamic size (max or half) and anything that
# is not a size.
disk_size_check() {
  local dir=$1 f size want have rc=0
  if f=$(readable_compose); then
    size=$(compose_value "$f" DISK_SIZE 2>/dev/null) || rc=$?
  else
    rc=1
  fi
  if ((rc == 2)); then
    echo "cannot interpret DISK_SIZE in omarchy-windows-vm's settings"
    return 1
  elif ((rc != 0)); then
    echo "disk size not checked: omarchy-windows-vm's settings are not readable"
    return 2
  fi
  size=$(dockur_disk_size "$size")
  if [[ $size == MAX || $size == HALF ]]; then
    # dockur sizes these from free space at each start, so the disk can grow.
    echo "a dynamic disk size (max/half) is not supported"
    return 1
  fi
  if ! want=$(numfmt --from=iec -- "$size" 2>/dev/null) || [[ ! $want =~ ^[0-9]+$ ]]; then
    echo "DISK_SIZE $size is not a size"
    return 1
  fi
  have=$(stat -c %s -- "$dir/data.img") || {
    echo "cannot read the size of $dir/data.img"
    return 1
  }
  if ((have < want)); then
    echo "data.img is $have bytes, smaller than DISK_SIZE $size ($want bytes); dockur would grow it"
    return 1
  fi
  echo "disk size ok"
}

# Check the file share (spec 28): ~/Windows must be a real folder, not a
# symlink, owned by the user. Prints the problem and fails otherwise.
share_check() {
  local share=$HOME/Windows
  if [[ -L $share ]]; then
    echo "$share is a symlink; Lanai shares only a real folder"
  elif [[ ! -e $share ]]; then
    echo "$share does not exist; create it with: mkdir $share"
  elif [[ ! -d $share ]]; then
    echo "$share is not a folder"
  elif [[ $(stat -c %u -- "$share") != "$(id -u)" ]]; then
    echo "$share is owned by another user"
  else
    return 0
  fi
  return 1
}

# Return 0 when process <pid> is in a docker container's cgroup: a systemd
# docker-<id>.scope or a cgroupfs /docker/<id> path. LANAI_PROC swaps /proc.
in_docker_cgroup() {
  grep -qE '(^|/)docker-[0-9a-f]+\.scope(/|$)|(^|/)docker/[0-9a-f]+(/|$)' \
    "${LANAI_PROC:-/proc}/$1/cgroup" 2>/dev/null
}

# Print the pid of a QEMU running in a Docker container and return 0; return
# 1 when there is none (spec 3). That is a Docker VM, most likely
# omarchy-windows-vm's but not certainly, so refusal messages built on this
# say "a Docker VM is running (possibly omarchy-windows-vm)". Reads only
# /proc, so it needs no Docker access and no password. LANAI_PROC swaps /proc.
container_running() {
  local pid
  for pid in $(qemu_pids); do
    if in_docker_cgroup "$pid"; then
      printf '%s\n' "$pid"
      return 0
    fi
  done
  return 1
}

# Return 0 when a Docker container runs dockur's /run/entry.sh but has no
# QEMU yet (a container, possibly omarchy-windows-vm's, is preparing a VM,
# spec 3). Best effort: QEMU's disk lock is the backstop. LANAI_PROC swaps
# /proc.
container_preparing() {
  local f pid arg
  container_running >/dev/null && return 1
  for f in "${LANAI_PROC:-/proc}"/[0-9]*/cmdline; do
    pid=${f%/cmdline}
    pid=${pid##*/}
    in_docker_cgroup "$pid" || continue
    while IFS= read -r -d '' arg; do
      [[ $arg == /run/entry.sh ]] && return 0
    done 2>/dev/null <"$f"
  done
  return 1
}

# Print the VM settings to seed Lanai's settings with (spec 6), as JSON:
# {"memory_gib": N, "cores": N, "source": "omarchy-windows-vm"|"defaults"}.
# From a readable compose it reads only RAM_SIZE and CPU_CORES. Otherwise, or
# when either line cannot be interpreted or its value is unusable, it uses
# half the host's memory (at most 16 GiB) and half its CPU threads (at most
# 8). Falling back is safe here: memory and cores are VM sizing, not an
# adoption safety check, and the user can change them in the panel. It never
# reads the password or the credentials file. LANAI_PROC swaps /proc.
settings_seed() {
  local f ram="" cores="" kb threads
  if f=$(readable_compose); then
    ram=$(compose_value "$f" RAM_SIZE 2>/dev/null) || ram=""
    cores=$(compose_value "$f" CPU_CORES 2>/dev/null) || cores=""
  fi
  if [[ $ram =~ ^[0-9]+G$ && $cores =~ ^[0-9]+$ ]] && ((10#${ram%G} >= 1 && 10#$cores >= 1)); then
    printf '{"memory_gib":%d,"cores":%d,"source":"omarchy-windows-vm"}\n' "$((10#${ram%G}))" "$((10#$cores))"
    return 0
  fi
  kb=$(awk '$1 == "MemTotal:" { print $2; exit }' "${LANAI_PROC:-/proc}/meminfo") || return 1
  threads=$(grep -c '^processor' "${LANAI_PROC:-/proc}/cpuinfo") || return 1
  ram=$((kb / 2 / 1048576))
  cores=$((threads / 2))
  ((ram >= 1)) || ram=1
  ((ram <= 16)) || ram=16
  ((cores >= 1)) || cores=1
  ((cores <= 8)) || cores=8
  printf '{"memory_gib":%d,"cores":%d,"source":"defaults"}\n' "$ram" "$cores"
}

# Print the focused monitor's scale as a percentage (1.5 prints 150, 1.125
# prints 112.5), from `hyprctl monitors -j`. `lanai start` reads it (spec 12).
# Fails without Hyprland or a focused monitor.
host_scale() {
  local scale
  scale=$(timeout 5 hyprctl monitors -j </dev/null 2>/dev/null |
    jq -er 'first(.[] | select(.focused == true)) | .scale | numbers') || return 1
  awk -v s="$scale" 'BEGIN { p = sprintf("%.2f", s * 100); sub(/\.?0+$/, "", p); print p }'
}

# Print the Windows scale step nearest <percent> (spec 12): 100 to 250 by 25,
# then 300 to 500 by 50. Ties round down; values outside clamp to the ends.
scale_step() {
  [[ $1 =~ ^[0-9]+(\.[0-9]+)?$ ]] || {
    echo "lanai: not a scale percentage: $1" >&2
    return 1
  }
  awk -v s="$1" -v steps="$LANAI_SCALE_STEPS" 'BEGIN {
    n = split(steps, step, " ")
    best = step[1]; bd = s - step[1]; if (bd < 0) bd = -bd
    for (i = 2; i <= n; i++) {
      d = s - step[i]; if (d < 0) d = -d
      if (d < bd) { bd = d; best = step[i] }
    }
    print best
  }'
}

# Print the dockurr/windows image's version label when Docker answers without
# a prompt, for display only (spec 5a). Never uses sudo. Fails quietly when
# Docker is missing, denied, or has no such label.
dockur_version() {
  local v
  command -v docker >/dev/null || return 1
  v=$(timeout 5 docker image inspect \
    --format '{{ index .Config.Labels "org.opencontainers.image.version" }}' \
    dockurr/windows </dev/null 2>/dev/null) || return 1
  [[ $v =~ ^[0-9A-Za-z][0-9A-Za-z._-]*$ ]] || return 1
  printf '%s\n' "$v"
}

# --- VM lifecycle (plan phase 4) ---

# Where to point for logs, and the fallback when Lanai cannot show Windows
# (spec 8, 10).
LANAI_LOGS="journalctl --user -u lanai-vm"
LANAI_FALLBACK="or use omarchy-windows-vm (RDP or its web console) instead"
LANAI_FORCED_NOTICE="Windows was force-stopped last time. Likely causes: a locked Windows, an open Windows security screen, or a shutdown that did not finish in time."
LANAI_BUSY="another Lanai start, snapshot or restore is running"

# Return 0 when Lanai's setup has finished: setup.json's "done" is true
# (phase 6 writes it).
setup_done() {
  jq -e '.done == true' "$(state_dir)/setup.json" >/dev/null 2>&1
}

# Print the VM unit's ActiveState, or fail when the user manager does not
# answer.
unit_state() {
  local st
  st=$(systemctl --user show -p ActiveState --value "$LANAI_UNIT" 2>/dev/null) || return 1
  [[ -n $st ]] || return 1
  printf '%s\n' "$st"
}

# Hold Lanai's operation lock (<state>/lock) until this process exits, so
# two starts, snapshots or restores never overlap (a double click). Call it
# in the command's own shell, not in $(...). Fails at once when another
# process holds it.
lanai_flock() {
  local s
  s=$(state_dir)
  mkdir -p -- "$s" || return 1
  exec {LANAI_FLOCK_FD}>>"$s/lock" || return 1
  flock -n "$LANAI_FLOCK_FD"
}

# Print why a container VM blocks Lanai, and succeed; fail when none does
# (spec 3). Reads only /proc.
container_blocked() {
  if container_running >/dev/null; then
    echo "a Docker VM is running (possibly omarchy-windows-vm). Stop it with omarchy-windows-vm stop first."
  elif container_preparing; then
    echo "a Docker container (possibly omarchy-windows-vm) is preparing a VM. Stop it with omarchy-windows-vm stop first."
  else
    return 1
  fi
}

# Print why an unfinished restore blocks a start or a snapshot, and succeed;
# fail when there is none.
restore_pending() {
  [[ -e $(state_dir)/restore-in-progress ]] || return 1
  echo "a restore did not finish: run lanai restore again"
}

# Return 0 when helper <name> still runs inside the VM unit: $RUN/<name>.pid
# names a live process (not a zombie) whose cgroup is lanai-vm.service. A
# dead pid, or a reused one outside the unit, means the helper is gone.
# LANAI_PROC swaps /proc.
helper_alive() {
  local f=$1/$2.pid pid proc stat
  [[ -r $f ]] || return 1
  pid=$(<"$f")
  [[ $pid =~ ^[0-9]+$ ]] || return 1
  proc=${LANAI_PROC:-/proc}/$pid
  [[ -r $proc/stat ]] || return 1
  stat=$(<"$proc/stat")
  stat=${stat##*) }
  [[ ${stat:0:1} != [ZX] ]] || return 1
  grep -qE "/${LANAI_UNIT//./\\.}\$" "$proc/cgroup" 2>/dev/null
}

# Print the facts lanai status maps to a state, as Key=Value lines: the
# unit's `systemctl --user show` output, then Lanai's own (LanaiInstall,
# LanaiSetup, LanaiContainer, LanaiForced, LanaiLastRun, and for an active
# unit LanaiQmp, LanaiQga, LanaiHelpersMissing, LanaiStopAge and
# LanaiClient=timeout when the client gave up waiting for QEMU),
# LanaiVersion (version_check's verdict on client.log for an active unit,
# else "unknown"; idd-missing only while the client runs), and
# LanaiDriverOld=<version> when the recorded guest driver is not the pinned
# build. QMP is asked on qmp-cli.sock, in one short session. It also
# records the guest version the client log names (guest_version_set).
status_facts() {
  local show active inv dir rc s run out name missing="" rinv at version=unknown guest="" first=""
  show=$(systemctl --user show "$LANAI_UNIT" -p ActiveState -p SubState -p Result \
    -p InvocationID -p ExecMainStatus 2>/dev/null) || show=ActiveState=unknown
  printf '%s\n' "$show"
  active=$(sed -n 's/^ActiveState=//p' <<<"$show")
  inv=$(sed -n 's/^InvocationID=//p' <<<"$show")
  s=$(state_dir)
  rc=0
  if dir=$(storage_dir 2>/dev/null); then
    layout_check "$dir" >/dev/null || rc=$?
  fi
  if ((rc == 2)); then echo LanaiInstall=none; else echo LanaiInstall=present; fi
  if setup_done; then echo LanaiSetup=done; else echo LanaiSetup=needed; fi
  if container_running >/dev/null; then
    echo LanaiContainer=running
  elif container_preparing; then
    echo LanaiContainer=preparing
  else
    echo LanaiContainer=none
  fi
  [[ ! -e $s/forced ]] || echo LanaiForced=yes
  [[ ! -f $s/last-run ]] || echo "LanaiLastRun=$(<"$s/last-run")"
  if [[ $active == active || $active == reloading ]] && run=$(run_dir); then
    if out=$(qmp_call "$run/qmp-cli.sock" '{"execute":"query-status"}' '{"execute":"query-chardev"}'); then
      echo "LanaiQmp=$(jq -r 'select(.return.status? | type == "string") | .return.status' <<<"$out" | head -n1)"
      if [[ $(jq -r 'select(.return | type == "array") | .return[] | select(.label == "qga0") |
        .["frontend-open"]' <<<"$out") == true ]]; then
        echo LanaiQga=open
      else
        echo LanaiQga=closed
      fi
    else
      echo LanaiQmp=none
    fi
    for name in "${!LANAI_HELPERS[@]}"; do
      helper_alive "$run" "$name" || missing+=,$name
    done
    [[ -z $missing ]] || echo "LanaiHelpersMissing=${missing#,}"
    if [[ -n $inv && -f $s/stop-requested ]] && read -r rinv at <"$s/stop-requested" &&
      [[ $rinv == "$inv" && $at =~ ^[0-9]+$ ]]; then
      echo "LanaiStopAge=$((EPOCHSECONDS - at))"
    fi
    if [[ -f $run/client.log ]]; then
      read -r version guest < <(version_check "$run/client.log") || version=unknown
      [[ -z $guest ]] || guest_version_set "$guest" || true
      # A log whose client was closed says nothing about the IDD now.
      [[ $version != idd-missing ]] || client_active || version=unknown
      IFS= read -r first <"$run/client.log" || true
      [[ $first != "$LANAI_CLIENT_TIMEOUT"* ]] || echo LanaiClient=timeout
    fi
  fi
  echo "LanaiVersion=$version"
  guest=$(guest_version_behind) || guest=""
  [[ -z $guest ]] || echo "LanaiDriverOld=$guest"
}

# status_map: read status_facts' lines on stdin and emit the state the bar
# shows (spec 10), with its cause and one next step: not-installed,
# setup-needed, stopped, starting, running, stopping, in-use,
# version-mismatch or failed. Details: notice (the last start's verdict was
# a forced stop, with its likely causes, spec 19; only from last-run, which
# the panel clears once shown), forced_pending (the VM was force-stopped or
# its stop timed out, and the next start will report it), warning (helpers
# that stopped, a client that gave up waiting for QEMU, or a guest driver
# that is not the pinned build), force_stop (true once a shutdown from the
# bar has run 2 minutes, spec 16) and, for failed, logs. The client log's
# verdict (LanaiVersion) makes a mismatch version-mismatch, and a missing
# IDD on a booted VM failed, with the client log as its logs (spec 8); a
# stop in progress and a QEMU error come first.
status_map() {
  local line state message next notice="" warning="" force=false name logs=""
  local -A f=()
  local -a lost=()
  while IFS= read -r line; do
    [[ $line != *=* ]] || f[${line%%=*}]=${line#*=}
  done
  local active=${f[ActiveState]:-unknown} setup=${f[LanaiSetup]:-needed} qmp=${f[LanaiQmp]:-none}
  local forced=${f[LanaiForced]:-no} failed_next="see the logs with $LANAI_LOGS, $LANAI_FALLBACK"
  # A stop that ran out of time (TimeoutStopSec, at logout with lingering)
  # is a forced stop, not a crash.
  [[ ! ($active == failed && ${f[Result]:-} == timeout) ]] || forced=yes
  [[ ${f[LanaiLastRun]:-} != forced ]] || notice=$LANAI_FORCED_NOTICE
  case $active in
    active | reloading)
      if [[ -n ${f[LanaiStopAge]:-} || $qmp == shutdown ]]; then
        state=stopping message="Windows is shutting down." next="wait up to 2 minutes"
        if ((${f[LanaiStopAge]:-0} >= 120)); then
          force=true
          message="Windows has not shut down after 2 minutes. It may be installing updates, or a Windows security screen may be open."
          next="wait, or use the forced stop in the panel"
        fi
      elif [[ $qmp == internal-error || $qmp == guest-panicked || $qmp == io-error ]]; then
        state=failed message="QEMU reports $qmp." next=$failed_next
      elif [[ $qmp == running && $setup != "done" ]]; then
        # dockur installs its own guest agent, so the port says nothing yet.
        state="setup-needed" message="Windows is running, but Lanai setup has not finished."
        next="finish setup in the Lanai panel"
      elif [[ ${f[LanaiVersion]:-} == mismatch ]]; then
        state="version-mismatch"
        message="The Looking Glass client and the driver in Windows come from different builds."
        next="run Lanai setup again to update Windows, $LANAI_FALLBACK"
      elif [[ $qmp == running && ${f[LanaiQga]:-} == open && ${f[LanaiVersion]:-} == idd-missing ]]; then
        # Windows has booted, but the IDD never answered the client (spec 8).
        state=failed logs="$(run_dir 2>/dev/null)/client.log"
        message="Windows is running, but the Looking Glass driver in Windows has not answered for $LANAI_IDD_WAIT s, so the window stays empty."
        next="shut Windows down, then run Lanai setup again to reinstall it, $LANAI_FALLBACK"
      elif [[ $qmp == running && ${f[LanaiQga]:-} == open ]]; then
        state=running message="Windows is running." next="open the Windows window"
        if [[ -n ${f[LanaiHelpersMissing]:-} ]]; then
          IFS=, read -r -a lost <<<"${f[LanaiHelpersMissing]}"
          for name in "${lost[@]}"; do
            warning+="${warning:+; }${LANAI_HELPERS[$name]:-$name stopped}"
          done
          warning="Some of Lanai's helpers stopped: $warning."
          next="shut Windows down and start it again"
        fi
      else
        state=starting message="Windows is starting." next="wait for Windows to start"
      fi
      ;;
    activating) state=starting message="Windows is starting." next="wait for Windows to start" ;;
    deactivating) state=stopping message="Windows is shutting down." next="wait up to 2 minutes" ;;
    inactive | failed)
      if [[ ${f[LanaiContainer]:-none} == running ]]; then
        state="in-use" message="omarchy-windows-vm is running Windows (a Docker VM is running)."
        next="stop it with omarchy-windows-vm stop, then start Windows here"
      elif [[ ${f[LanaiContainer]:-none} == preparing ]]; then
        state="in-use" message="A Docker container, possibly omarchy-windows-vm's, is preparing a VM."
        next="stop it with omarchy-windows-vm stop, then start Windows here"
      elif [[ $active == failed && $forced != yes ]]; then
        state=failed next=$failed_next
        message="Windows stopped with an error (${f[Result]:-unknown}, status ${f[ExecMainStatus]:-unknown})."
      elif [[ ${f[LanaiInstall]:-present} == none ]]; then
        state="not-installed" message="There is no Windows install at Lanai's storage location."
        next="install Windows with omarchy-windows-vm, then run Lanai setup"
      elif [[ $setup != "done" ]]; then
        state="setup-needed" message="Lanai setup has not finished." next="open the Lanai panel and run setup"
      else
        state=stopped message="Windows is stopped." next="start Windows"
      fi
      ;;
    *) state=failed message="Lanai cannot read the VM's state from systemd." next=$failed_next ;;
  esac
  # status_facts reports LanaiClient only for an active unit.
  if [[ ${f[LanaiClient]:-} == timeout ]]; then
    warning+="${warning:+ }The Windows window did not open: QEMU did not answer within $LANAI_CLIENT_WAIT s. Try Open again."
  fi
  if [[ -n ${f[LanaiDriverOld]:-} && $state != version-mismatch ]]; then
    warning+="${warning:+ }The Windows display driver (${f[LanaiDriverOld]}) is not Lanai's pinned build ($LG_BUILD); run Lanai setup again to update it."
  fi
  [[ $state != failed || -n $logs ]] || logs=$LANAI_LOGS
  emit true "$state" "$message" "$next" "$(jq -n -c --arg notice "$notice" --arg warning "$warning" \
    --argjson force "$force" --arg logs "$logs" --argjson pending "$([[ $forced == yes ]] && echo true || echo false)" \
    '{notice: (if $notice == "" then null else $notice end),
      warning: (if $warning == "" then null else $warning end),
      force_stop: $force, forced_pending: $pending} + (if $logs == "" then {} else {logs: $logs} end)')"
}

# Check everything that must hold before the VM unit starts, and print the
# first reason to refuse (plan phase 4). The unit must be stopped first, so
# a second start cannot clear a live run's markers; then the previous run's
# markers become a verdict (record_previous_run); then it refuses on an
# unfinished restore, layout_check, disk_size_check, share_check, a running
# or preparing container, or a held disk lock.
preflight() {
  local st dir out rc
  if ! st=$(unit_state); then
    echo "Lanai cannot reach the systemd user manager."
    return 1
  fi
  case $st in
    inactive | failed) ;;
    deactivating)
      echo "Windows is still shutting down; try again in a moment."
      return 1
      ;;
    *)
      echo "Windows is already running under Lanai ($st)."
      return 1
      ;;
  esac
  record_previous_run >/dev/null
  restore_pending && return 1
  dir=$(storage_dir) || {
    echo "Lanai cannot read its settings file."
    return 1
  }
  out=$(layout_check "$dir") || {
    printf '%s\n' "$out"
    return 1
  }
  rc=0
  out=$(disk_size_check "$dir") || rc=$?
  if ((rc == 1)); then
    printf '%s\n' "$out"
    return 1
  fi
  out=$(share_check) || {
    printf '%s\n' "$out"
    return 1
  }
  container_blocked && return 1
  rc=0
  disk_locked "$dir/data.img" || rc=$?
  case $rc in
    0)
      echo "another process holds the Windows disk ($dir/data.img)."
      return 1
      ;;
    2)
      echo "Lanai cannot tell whether another process holds the Windows disk."
      return 1
      ;;
  esac
}

# Print the VM unit for the runtime copy at <runtime-dir>, from
# systemd/lanai-vm.service, with the XDG folders the VM reads. Fails on a
# path the unit file cannot hold without quoting.
unit_render() {
  local rt=$1 unit p env
  local -a paths=("$rt/bin" "${XDG_CONFIG_HOME:-$HOME/.config}" "${XDG_STATE_HOME:-$HOME/.local/state}"
    "${XDG_DATA_HOME:-$HOME/.local/share}")
  for p in "${paths[@]}"; do
    [[ $p =~ ^/[A-Za-z0-9._/@+:,~=-]*$ ]] || {
      echo "lanai: $p has characters the VM unit cannot hold" >&2
      return 1
    }
  done
  env="XDG_CONFIG_HOME=${paths[1]} XDG_STATE_HOME=${paths[2]} XDG_DATA_HOME=${paths[3]}"
  unit=$(<"$LANAI_LIB/../systemd/lanai-vm.service") || return 1
  unit=${unit//@BIN@/"${paths[0]}"}
  printf '%s\n' "${unit//@ENV@/"$env"}"
}

# Make sure the VM unit runs Lanai's current code from a stable copy (plan:
# Stable runtime copy): copy bin/ and lib/ into <data>/runtime/<version>/
# when that copy is missing, install the unit when it differs, reload
# systemd, and remove older copies. Every step's failure stops it. Runs only
# while the unit is stopped (after preflight), so a plugin update or removal
# never pulls files from under a running VM.
runtime_refresh() {
  local root rt src part unit_dir unit want d
  root=$(data_dir)/runtime
  rt=$root/$LANAI_VERSION
  src=$(cd -- "$LANAI_LIB/.." && pwd) || return 1
  if [[ ! -d $rt ]]; then
    part=$rt.partial
    rm -rf -- "$part" || return 1
    mkdir -p -- "$part" || return 1
    cp -R -- "$src/bin" "$src/lib" "$part/" || return 1
    mv -T -- "$part" "$rt" || return 1
  fi
  want=$(unit_render "$rt") || return 1
  unit_dir=${XDG_CONFIG_HOME:-$HOME/.config}/systemd/user
  unit=$unit_dir/$LANAI_UNIT
  if [[ ! -f $unit || $(<"$unit") != "$want" ]]; then
    mkdir -p -- "$unit_dir" || return 1
    printf '%s\n' "$want" >"$unit.tmp" || return 1
    mv -f -- "$unit.tmp" "$unit" || return 1
    systemctl --user daemon-reload || return 1
  fi
  for d in "$root"/*; do
    [[ ! -e $d || $d == "$rt" ]] || rm -rf -- "$d" || return 1
  done
}

# boot_vm <setup true|false>: the one path that starts the VM unit (lanai
# start; lanai setup-guest and setup's step 6 boot in phase 6). Under
# lanai_flock it runs preflight, turns the focused monitor's scale into a
# Windows step (100% without Hyprland), runs lanai-vm-exec's own checks as a
# dry run (vm_plan), so a refusal is explained here rather than showing as
# a failed unit, refreshes the runtime copy, leaves the scale and boot mode
# in <state>/boot.json for lanai-vm-exec, and starts the unit. Emits the
# result, with last_run so the panel can show a forced-stop notice once,
# and network false when the host has no default route.
boot_vm() {
  local setup=$1 reason scale step s media="" last="" message="Windows is starting." network=true
  if ! lanai_flock; then
    emit false "" "$LANAI_BUSY." "try again when it finishes"
    return 1
  fi
  if ! reason=$(preflight); then
    emit false "" "$reason" ""
    return 1
  fi
  scale=$(host_scale) || scale=100
  step=$(scale_step "$scale") || step=100
  s=$(state_dir)
  [[ $setup != true ]] || media=$s/setup-media
  if ! reason=$(vm_plan "$step" "$media"); then
    emit false "" "$reason" ""
    return 1
  fi
  if [[ -z $(default_gateway) ]]; then
    network=false
    message="Windows is starting without a network: the host has no default route."
  fi
  if ! runtime_refresh >&2; then
    emit false failed "Lanai could not install its runtime copy or VM unit." "see the error output"
    return 1
  fi
  if ! mkdir -p -- "$s" || ! jq -n -c --argjson scale "$step" --argjson setup "$setup" \
    '{scale: $scale, setup: $setup}' >"$s/boot.json"; then
    emit false "" "Lanai cannot write $s/boot.json." ""
    return 1
  fi
  if ! systemctl --user start "$LANAI_UNIT" >&2; then
    emit false failed "Windows did not start." "see the logs with $LANAI_LOGS, $LANAI_FALLBACK"
    return 1
  fi
  [[ ! -f $s/last-run ]] || last=$(<"$s/last-run")
  emit true starting "$message" "wait for Windows to start" \
    "$(jq -n -c --argjson scale "$step" --arg last "$last" --argjson network "$network" \
      '{scale: $scale, network: $network, last_run: (if $last == "" then null else $last end)}')"
}

# status: print the VM's state for the bar (spec 10).
cmd_status() {
  status_map < <(status_facts)
}

# start: start Windows (spec 11). Refuses while setup is incomplete.
cmd_start() {
  if ! setup_done; then
    emit false setup-needed "Lanai setup has not finished." "open the Lanai panel and run setup"
    return 1
  fi
  boot_vm false
}

# stop: ask Windows to shut down cleanly (spec 16). Sends system_powerdown
# on qmp-cli.sock and records when, for this run; never uses systemctl stop.
# The unit stays active until QEMU exits by itself. A repeated stop keeps
# the first request's time, so the panel's 2 minutes run on.
cmd_stop() {
  local st inv run s reply rinv="" at=""
  st=$(unit_state) || st=""
  if [[ $st != active ]]; then
    emit false "" "Windows is not running." ""
    return 1
  fi
  inv=$(systemctl --user show -p InvocationID --value "$LANAI_UNIT" 2>/dev/null) || inv=""
  run=$(run_dir)
  if ! reply=$(qmp_call "$run/qmp-cli.sock" '{"execute":"system_powerdown"}') ||
    [[ $reply != '{"return":{}}' ]]; then
    emit false "" "Lanai could not ask Windows to shut down." "try again in a moment"
    return 1
  fi
  s=$(state_dir)
  mkdir -p -- "$s"
  [[ ! -f $s/stop-requested ]] || read -r rinv at <"$s/stop-requested" || true
  if [[ $rinv != "$inv" || ! $at =~ ^[0-9]+$ ]]; then
    printf '%s %s\n' "$inv" "$EPOCHSECONDS" >"$s/stop-requested"
  fi
  emit true stopping "Windows is shutting down." "wait up to 2 minutes"
}

# open: open the Windows window (spec 11, 17). Focuses the client's window
# when lanai-client.service already runs, so there is never a second
# client; else records the guest version the last client log names, picks
# the client build (build_select) and starts the unit, which waits for QEMU
# itself. Returns at once.
cmd_open() {
  local st pid client out
  st=$(unit_state) || st=""
  if [[ $st != active ]]; then
    emit false "" "Windows is not running." "start Windows"
    return 1
  fi
  if ! client_active; then
    guest_version_note "$(run_dir)/client.log"
    if ! client=$(build_select); then
      emit false "" "The Looking Glass client is not built." "run Lanai setup, or lanai build-client"
      return 1
    fi
    if client_start "$client" >&2; then
      emit true "" "The Windows window is opening." "" "$(jq -n -c --arg c "$client" '{client: $c}')"
      return 0
    fi
    # Another open may have started it meanwhile.
    if ! client_active; then
      emit false "" "Lanai could not open the Windows window." \
        "see the logs with journalctl --user -u $LANAI_CLIENT_UNIT"
      return 1
    fi
  fi
  pid=$(systemctl --user show -p MainPID --value "$LANAI_CLIENT_UNIT" 2>/dev/null) || pid=""
  if [[ $pid =~ ^[1-9][0-9]*$ ]] && out=$(timeout 5 hyprctl dispatch focuswindow "pid:$pid" 2>/dev/null) &&
    [[ $out == ok ]]; then
    emit true "" "Focused the Windows window." ""
  else
    emit true "" "The Windows window is opening." ""
  fi
}

# Return 0 while lanai-client.service runs or is starting.
client_active() {
  local st
  st=$(systemctl --user show -p ActiveState --value "$LANAI_CLIENT_UNIT" 2>/dev/null) || return 1
  [[ $st == active || $st == activating || $st == reloading ]]
}

# build-client: build and install the pinned Looking Glass client (spec 7,
# 26). It takes about a minute; the panel runs it detached (phases 6-7).
# Holds <state>/build.lock, so two builds never share the work folder.
cmd_build_client() {
  local out s
  s=$(state_dir)
  mkdir -p -- "$s"
  exec {LANAI_BUILD_FD}>>"$s/build.lock"
  if ! flock -n "$LANAI_BUILD_FD"; then
    emit false "" "Another Looking Glass client build is running." "wait for it to finish"
    return 1
  fi
  if ! out=$(build_client); then
    emit false "" "The Looking Glass client was not built: $out" "fix the cause, then run setup again"
    return 1
  fi
  emit true "" "The Looking Glass client $LG_BUILD is ready." "" \
    "$(jq -n -c --arg c "$out" --arg b "$LG_BUILD" '{client: $c, build: $b}')"
}

# setup-host: when a host package is missing, open a terminal (omarchy
# launch terminal) running lanai-setup-host, which prints the exact
# pacman command and runs it with sudo (spec 7). Never runs sudo itself.
# Returns at once, with the missing packages and the command.
cmd_setup_host() {
  local missing cmd details
  missing=$(host_packages_missing)
  cmd=$(host_install_command)
  details=$(jq -n -c --arg m "$missing" --arg c "$cmd" \
    '{missing: ($m | split("\n") | map(select(. != ""))), command: $c}')
  if [[ -z $missing ]]; then
    emit true "" "The host packages Lanai needs are installed." "" "$details"
    return 0
  fi
  if ! command -v omarchy >/dev/null; then
    emit false "" "Lanai cannot open a terminal: the omarchy command is missing." \
      "install the packages yourself with: $cmd" "$details"
    return 1
  fi
  setsid -f omarchy launch terminal -- "$LANAI_BIN/lanai-setup-host" </dev/null >/dev/null 2>&1
  emit true "" "A terminal opened to install the host packages. It shows the command before it runs." \
    "enter your password in the terminal, then continue setup" "$details"
}

# force-stop --confirm: kill the VM at once, like pulling the power (spec
# 16). Writes the "forced" marker first, so the next start reports it.
cmd_force_stop() {
  local st s
  if [[ ${1:-} != --confirm ]]; then
    emit false "" "The forced stop needs --confirm: Windows loses anything not saved." \
      "run lanai force-stop --confirm"
    return 2
  fi
  st=$(unit_state) || st=unknown
  case $st in
    active | activating | deactivating | reloading) ;;
    *)
      emit false "" "Windows is not running." ""
      return 1
      ;;
  esac
  s=$(state_dir)
  mkdir -p -- "$s"
  : >"$s/forced"
  if ! systemctl --user kill --signal=SIGKILL "$LANAI_UNIT" >&2; then
    rm -f -- "$s/forced"
    emit false "" "Lanai could not stop the VM." "see the logs with $LANAI_LOGS"
    return 1
  fi
  emit true stopped "Windows was force-stopped." "start Windows again when you need it"
}

# snapshot: make an instant, verified copy of the storage location (spec 7),
# and say where it lives, that it grows, and how to delete or restore it.
# It can take minutes; the panel runs it detached (plan phases 6-7).
cmd_snapshot() {
  local out rc=0 dir name
  if ! lanai_flock; then
    emit false "" "$LANAI_BUSY." "try again when it finishes"
    return 1
  fi
  out=$(snapshot_create) || rc=$?
  if ((rc == 3)); then
    dir=$(storage_dir) || dir="the storage location"
    emit false "" "$out Lanai cannot make an instant snapshot on this filesystem." \
      "make a backup of $dir before Lanai's first boot"
    return 1
  elif ((rc != 0)); then
    emit false "" "$out" ""
    return 1
  fi
  name=${out##*/}
  emit true "" "Snapshot saved at $out. It shares its data with the Windows disk, so it costs little space at first and grows as Windows changes. Delete it with: rm -rf ${out@Q}. Restore it with: lanai restore $name." "" \
    "$(jq -n -c --arg p "$out" --arg n "$name" '{snapshot: $p, name: $n}')"
}

# snapshots: list the complete snapshots of the storage location, oldest
# first.
cmd_snapshots() {
  local dir list
  dir=$(storage_dir) || return 1
  list=$(snapshot_list "$dir" | jq -R . | jq -s -c .)
  emit true "" "$(jq -r 'length' <<<"$list") snapshot(s)" "" "{\"snapshots\": $list}"
}

# restore [<name>]: return the storage location to a snapshot (spec 7).
# Without a name it resumes a restore that did not finish. It can take
# minutes; the panel runs it detached (plan phases 6-7).
cmd_restore() {
  local out
  if ! lanai_flock; then
    emit false "" "$LANAI_BUSY." "try again when it finishes"
    return 1
  fi
  if ! out=$(snapshot_restore "${1:-}"); then
    emit false "" "$out" ""
    return 1
  fi
  emit true "" "$out" "start Windows"
}
