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
  awk -v s="$1" 'BEGIN {
    n = split("100 125 150 175 200 225 250 300 350 400 450 500", step, " ")
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
