#!/usr/bin/env bats
# Tests for Lanai's adoption checks and settings (plan phase 3), against
# fixture directories. No test reads the real compose file, ~/.windows,
# /proc processes or Hyprland: HOME, XDG_*, OMARCHY_WINDOWS_DIR and LANAI_PROC
# point at temp dirs, and hyprctl and docker are PATH shims.
# shellcheck disable=SC2030,SC2031

load helpers

SENTINEL=LanaiSentinel-7f3a9c2e

setup() {
  isolate_home
  # shellcheck source-path=SCRIPTDIR source=../lib/lanai.sh
  source "$REPO/lib/lanai.sh"
  T=$BATS_TEST_TMPDIR
  # No compose anywhere unless a test writes one.
  export OMARCHY_WINDOWS_DIR=$T/var-lib-omarchy-windows
  mkdir -p "$T/shims"
}

# Skip when running as root, which reads files whatever their mode.
require_non_root() {
  ((EUID != 0)) || skip "root can read unreadable files"
}

# Install the fixture compose as omarchy-windows-vm's system compose, with
# each KEY=VALUE argument setting that key under environment (KEY= removes
# the line).
write_compose() {
  local f=$OMARCHY_WINDOWS_DIR/docker-compose.yml kv
  mkdir -p "$OMARCHY_WINDOWS_DIR"
  cp "$FIX/docker-compose.yml" "$f"
  for kv in "$@"; do
    sed -i "/^ *${kv%%=*}:/d" "$f"
    [[ -z ${kv#*=} ]] || sed -i "s|^    environment:\$|&\n      ${kv%%=*}: \"${kv#*=}\"|" "$f"
  done
}

# Build a finished omarchy-windows-vm install at <dir>: a 1 MiB data.img with
# data in its first bytes, firmware, variables, MAC, boot marker, base, ver.
make_install() {
  mkdir -p "$1"
  truncate -s 1M "$1/data.img"
  printf 'LANAI' | dd of="$1/data.img" conv=notrunc status=none
  echo rom >"$1/windows.rom"
  echo vars >"$1/windows.vars"
  echo 02:4B:81:73:3C:96 >"$1/windows.mac"
  : >"$1/windows.boot"
  echo win11x64.iso >"$1/windows.base"
  echo 6.05 >"$1/windows.ver"
}

# Write a fake /proc entry: fake_proc <pid> <cgroup path> <argv...>.
fake_proc() {
  local pid=$1 cg=$2
  shift 2
  mkdir -p "$T/proc/$pid"
  printf '%s\0' "$@" >"$T/proc/$pid/cmdline"
  printf '0::%s\n' "$cg" >"$T/proc/$pid/cgroup"
}

# Put an executable shim <name> with body <script> first on PATH.
shim() {
  printf '#!/usr/bin/env bash\n%s\n' "$2" >"$T/shims/$1"
  chmod +x "$T/shims/$1"
}

DOCKER_SCOPE=/system.slice/docker-4f1c2d3e4b5a69788796a5b4c3d2e1f00112233445566778899aabbccddeeff.scope

# --- storage_dir ---

@test "storage_dir: defaults to ~/.windows" {
  run storage_dir
  assert_success
  assert_output "$HOME/.windows"
}

@test "storage_dir: defaults to ~/.windows when settings have no storage" {
  mkdir -p "$XDG_CONFIG_HOME/lanai"
  echo '{"memory_gib": 8}' >"$XDG_CONFIG_HOME/lanai/settings.json"
  run storage_dir
  assert_success
  assert_output "$HOME/.windows"
}

@test "storage_dir: uses the configured location" {
  mkdir -p "$XDG_CONFIG_HOME/lanai"
  echo '{"storage": "/srv/copies/lanai-proof"}' >"$XDG_CONFIG_HOME/lanai/settings.json"
  run storage_dir
  assert_success
  assert_output /srv/copies/lanai-proof
}

@test "storage_dir: reads settings under ~/.config when XDG_CONFIG_HOME is unset" {
  unset XDG_CONFIG_HOME
  mkdir -p "$HOME/.config/lanai"
  echo '{"storage": "/srv/copy"}' >"$HOME/.config/lanai/settings.json"
  run storage_dir
  assert_output /srv/copy
}

@test "storage_dir: broken settings fail instead of falling back to the live install" {
  mkdir -p "$XDG_CONFIG_HOME/lanai"
  local bad
  for bad in '{"storage": ' '{"storage": 5}' '["x"]' '{"storage": "relative/copy"}'; do
    printf '%s\n' "$bad" >"$XDG_CONFIG_HOME/lanai/settings.json"
    run storage_dir
    assert_failure
    refute_output --partial "$HOME/.windows"
  done
}

# --- compose_file ---

@test "compose_file: the system compose when it exists" {
  write_compose
  mkdir -p "$HOME/.config/windows"
  touch "$HOME/.config/windows/docker-compose.yml"
  run compose_file
  assert_success
  assert_output "$OMARCHY_WINDOWS_DIR/docker-compose.yml"
}

@test "compose_file: the legacy compose under ~/.config when there is no system one" {
  mkdir -p "$HOME/.config/windows"
  touch "$HOME/.config/windows/docker-compose.yml"
  # omarchy-windows-vm uses ~/.config, not XDG_CONFIG_HOME.
  export XDG_CONFIG_HOME=$T/elsewhere
  run compose_file
  assert_success
  assert_output "$HOME/.config/windows/docker-compose.yml"
}

@test "compose_file: fails when there is neither" {
  run compose_file
  assert_failure
  assert_output ""
}

@test "compose_file: the default system path is /var/lib/omarchy/windows" {
  unset OMARCHY_WINDOWS_DIR
  # Only the path is compared; the file is never opened.
  run bash -c 'source "$1"; declare -f compose_file' _ "$REPO/lib/lanai.sh"
  assert_output --partial "/var/lib/omarchy/windows"
}

@test "compose_file: an unreadable system compose is still the one" {
  require_non_root
  write_compose
  chmod 000 "$OMARCHY_WINDOWS_DIR/docker-compose.yml"
  run compose_file
  assert_success
  assert_output "$OMARCHY_WINDOWS_DIR/docker-compose.yml"
}

@test "compose_file: a system folder Lanai cannot search counts as holding it" {
  require_non_root
  write_compose
  mkdir -p "$HOME/.config/windows"
  touch "$HOME/.config/windows/docker-compose.yml"
  chmod 000 "$OMARCHY_WINDOWS_DIR"
  run compose_file
  chmod 755 "$OMARCHY_WINDOWS_DIR"
  assert_success
  assert_output "$OMARCHY_WINDOWS_DIR/docker-compose.yml"
}

# --- compose_value ---

@test "compose_value: reads quoted, single-quoted and bare values of one key" {
  write_compose
  local f=$OMARCHY_WINDOWS_DIR/docker-compose.yml
  assert_equal "$(compose_value "$f" RAM_SIZE)" 8G
  sed -i "s|RAM_SIZE: \"8G\"|RAM_SIZE: '12G'|" "$f"
  assert_equal "$(compose_value "$f" RAM_SIZE)" 12G
  sed -i "s|RAM_SIZE: '12G'|RAM_SIZE: 16G|" "$f"
  assert_equal "$(compose_value "$f" RAM_SIZE)" 16G
}

@test "compose_value: a missing key is empty; similar keys do not match" {
  write_compose
  local f=$OMARCHY_WINDOWS_DIR/docker-compose.yml
  echo '      XRAM_SIZE: "99G"' >>"$f"
  echo '      RAM_SIZE_MAX: "98G"' >>"$f"
  run compose_value "$f" LANGUAGE
  assert_success
  assert_output ""
  assert_equal "$(compose_value "$f" RAM_SIZE)" 8G
}

@test "compose_value: refuses a key that is not a plain name" {
  write_compose
  run compose_value "$OMARCHY_WINDOWS_DIR/docker-compose.yml" '.*'
  assert_failure
}

# --- dockur_base ---

@test "dockur_base: omarchy-windows-vm's values give win11x64.iso" {
  assert_equal "$(dockur_base 11 "")" win11x64.iso
  assert_equal "$(dockur_base "" "")" win11x64.iso
}

@test "dockur_base: follows dockur 6.05's version names" {
  local pair
  for pair in "10:win10x64.iso" "Windows 11:win11x64.iso" "WIN11:win11x64.iso" \
    "11e:win11x64-enterprise-eval.iso" "ltsc10:win10x64-enterprise-ltsc-eval.iso" \
    "2022:win2022-eval.iso" "xp:winxpx86.iso" "tiny11:tiny11.iso" \
    "win11x64:win11x64.iso" "my/custom:mycustom.iso" " \"10\" :win10x64.iso"; do
    assert_equal "$(dockur_base "${pair%%:*}" "")" "${pair#*:}"
  done
}

@test "dockur_base: adds the language's culture prefix except for English" {
  local pair
  for pair in "de:win11x64_de.iso" "German:win11x64_de.iso" "fr-CA:win11x64_fr.iso" \
    "br:win11x64_pt.iso" "pt-pt:win11x64_pt.iso" "nb:win11x64_nb.iso" \
    "zh-hk:win11x64_zh.iso" "sr:win11x64_sr.iso" "ua:win11x64_uk.iso" \
    "en:win11x64.iso" "en-GB:win11x64.iso" "en_GB:win11x64.iso" "gb:win11x64.iso" \
    "english:win11x64.iso"; do
    assert_equal "$(dockur_base 11 "${pair%%:*}")" "${pair#*:}"
  done
}

@test "dockur_base: an unknown language or a URL version cannot be derived" {
  run dockur_base 11 klingon
  assert_failure
  assert_output --partial "LANGUAGE"
  run dockur_base https://example.com/win.iso ""
  assert_failure
  assert_output --partial "URL"
}

# --- layout_check ---

@test "layout_check: a finished install passes" {
  make_install "$T/w"
  run layout_check "$T/w"
  assert_success
  assert_output ""
}

@test "layout_check: an install without windows.base or windows.ver passes" {
  make_install "$T/w"
  rm "$T/w/windows.base" "$T/w/windows.ver"
  run layout_check "$T/w"
  assert_success
}

@test "layout_check: a missing or empty folder is no install" {
  run layout_check "$T/none"
  assert_failure 2
  assert_output --partial "No Windows install"
  mkdir "$T/empty"
  run layout_check "$T/empty"
  assert_failure 2
  assert_output --partial "No Windows install"
}

@test "layout_check: a file in place of the folder is refused" {
  touch "$T/w"
  run layout_check "$T/w"
  assert_failure 1
  assert_output --partial "not a folder"
}

@test "layout_check: each unsupported layout gets its own refusal" {
  local pair
  for pair in \
    "windows.mode:Secure Boot or legacy BIOS" \
    "windows.tpm:TPM" \
    "custom.iso:reinstall" \
    "Custom.ISO:reinstall" \
    "boot.iso:reinstall" \
    "setup.img:unfinished" \
    "setup.img.tmp:unfinished" \
    "notes.txt:move it out" \
    ".hidden:move it out"; do
    make_install "$T/w"
    echo x >"$T/w/${pair%%:*}"
    run layout_check "$T/w"
    assert_failure 1
    assert_output --partial "${pair%%:*}"
    assert_output --partial "${pair#*:}"
    rm -rf "$T/w"
  done
}

@test "layout_check: every dockur hardware override file is refused" {
  local n
  for n in hv vga usb sound net port cpu type bios flag args old system img; do
    make_install "$T/w"
    echo x >"$T/w/windows.$n"
    run layout_check "$T/w"
    assert_failure 1
    assert_output --partial "windows.$n: a dockur hardware override"
    rm -rf "$T/w"
  done
}

@test "layout_check: tmp/ and backups/ folders are refused with their reasons" {
  make_install "$T/w"
  mkdir "$T/w/tmp" "$T/w/backups"
  run layout_check "$T/w"
  assert_failure 1
  assert_output --partial "tmp/: dockur's scratch folder"
  assert_output --partial "backups/: dockur moved an earlier install here"
}

@test "layout_check: a qcow2 disk, alone or beside data.img, is refused" {
  make_install "$T/w"
  touch "$T/w/data.qcow2"
  run layout_check "$T/w"
  assert_failure 1
  assert_output --partial "data.img and data.qcow2 both exist"
  rm "$T/w/data.img"
  run layout_check "$T/w"
  assert_failure 1
  assert_output --partial "data.qcow2: Lanai supports only a raw data.img"
}

@test "layout_check: an allow-listed name that is not a regular file is refused" {
  make_install "$T/w"
  rm "$T/w/windows.vars"
  ln -s "$T/w/windows.rom" "$T/w/windows.vars"
  run layout_check "$T/w"
  assert_failure 1
  assert_output --partial "windows.vars: not a regular file"
  rm "$T/w/windows.vars"
  mkdir "$T/w/windows.vars"
  run layout_check "$T/w"
  assert_failure 1
  assert_output --partial "windows.vars: not a regular file"
}

@test "layout_check: missing or empty firmware, variables or MAC are refused" {
  local f
  for f in windows.rom windows.vars windows.mac; do
    make_install "$T/w"
    rm "$T/w/$f"
    run layout_check "$T/w"
    assert_failure 1
    assert_output --partial "$f is missing or empty"
    : >"$T/w/$f"
    run layout_check "$T/w"
    assert_failure 1
    assert_output --partial "$f is missing or empty"
    rm -rf "$T/w"
  done
}

@test "layout_check: a missing windows.boot is refused" {
  make_install "$T/w"
  rm "$T/w/windows.boot"
  run layout_check "$T/w"
  assert_failure 1
  assert_output --partial "windows.boot is missing"
}

@test "layout_check: a missing or empty disk is refused" {
  make_install "$T/w"
  rm "$T/w/data.img"
  run layout_check "$T/w"
  assert_failure 1
  assert_output --partial "data.img is missing or empty"
  : >"$T/w/data.img"
  run layout_check "$T/w"
  assert_failure 1
  assert_output --partial "data.img is missing or empty"
}

@test "layout_check: a disk whose first 100 KB are zero is refused, byte-exact" {
  make_install "$T/w"
  truncate -s 0 "$T/w/data.img"
  truncate -s 1M "$T/w/data.img"
  run layout_check "$T/w"
  assert_failure 1
  assert_output --partial "first 100 KB of data.img are all zero"
  # A byte just past the first 100 KB (102400 bytes) does not count.
  printf 'x' | dd of="$T/w/data.img" bs=1 seek=102400 conv=notrunc status=none
  run layout_check "$T/w"
  assert_failure 1
  # The last byte inside it does.
  printf 'x' | dd of="$T/w/data.img" bs=1 seek=102399 conv=notrunc status=none
  run layout_check "$T/w"
  assert_success
}

@test "layout_check: an empty windows.base passes" {
  make_install "$T/w"
  : >"$T/w/windows.base"
  run layout_check "$T/w"
  assert_success
}

@test "layout_check: without a readable compose, windows.base must be win11x64.iso" {
  make_install "$T/w"
  echo WIN11X64.ISO >"$T/w/windows.base"
  run layout_check "$T/w"
  assert_success
  echo win10x64.iso >"$T/w/windows.base"
  run layout_check "$T/w"
  assert_failure 1
  assert_output --partial "windows.base names win10x64.iso"
  assert_output --partial "win11x64.iso"
}

@test "layout_check: a windows.base without .iso is refused" {
  make_install "$T/w"
  echo win11x64 >"$T/w/windows.base"
  run layout_check "$T/w"
  assert_failure 1
  assert_output --partial "windows.base names win11x64,"
}

@test "layout_check: windows.base follows the compose's VERSION and LANGUAGE" {
  make_install "$T/w"
  write_compose VERSION=10 LANGUAGE=de
  echo win11x64.iso >"$T/w/windows.base"
  run layout_check "$T/w"
  assert_failure 1
  assert_output --partial "win10x64_de.iso"
  echo win10x64_de.iso >"$T/w/windows.base"
  run layout_check "$T/w"
  assert_success
}

@test "layout_check: an unreadable compose falls back to omarchy-windows-vm's values" {
  require_non_root
  make_install "$T/w"
  write_compose VERSION=10
  chmod 000 "$OMARCHY_WINDOWS_DIR/docker-compose.yml"
  run layout_check "$T/w"
  assert_success
}

@test "layout_check: a compose whose image name cannot be derived refuses a set base" {
  make_install "$T/w"
  write_compose LANGUAGE=klingon
  run layout_check "$T/w"
  assert_failure 1
  assert_output --partial "windows.base: cannot tell"
  : >"$T/w/windows.base"
  run layout_check "$T/w"
  assert_success
}

@test "layout_check: lists every problem, one per line" {
  make_install "$T/w"
  rm "$T/w/windows.boot"
  touch "$T/w/custom.iso" "$T/w/windows.tpm"
  run layout_check "$T/w"
  assert_failure 1
  assert_equal "${#lines[@]}" 3
}

# --- disk_size_check ---

@test "disk_size_check: a disk at least DISK_SIZE passes" {
  make_install "$T/w"
  write_compose DISK_SIZE=1M
  run disk_size_check "$T/w"
  assert_success
  truncate -s 2M "$T/w/data.img"
  run disk_size_check "$T/w"
  assert_success
}

@test "disk_size_check: a disk below DISK_SIZE is refused" {
  make_install "$T/w"
  write_compose DISK_SIZE=64G
  run disk_size_check "$T/w"
  assert_failure 1
  assert_output --partial "smaller than DISK_SIZE 64G"
  # One byte short of 2 MiB.
  write_compose DISK_SIZE=2M
  truncate -s 2097151 "$T/w/data.img"
  run disk_size_check "$T/w"
  assert_failure 1
}

@test "disk_size_check: no DISK_SIZE means dockur's 64G" {
  make_install "$T/w"
  write_compose DISK_SIZE=
  run disk_size_check "$T/w"
  assert_failure 1
  assert_output --partial "64G"
}

@test "disk_size_check: DISK_SIZE with spaces is read as dockur reads it" {
  make_install "$T/w"
  write_compose "DISK_SIZE= 1 M"
  run disk_size_check "$T/w"
  assert_success
}

@test "disk_size_check: without a compose it reports not checked" {
  make_install "$T/w"
  run disk_size_check "$T/w"
  assert_failure 2
  assert_output --partial "not checked"
}

@test "disk_size_check: an unreadable compose reports not checked" {
  require_non_root
  make_install "$T/w"
  write_compose DISK_SIZE=64G
  chmod 000 "$OMARCHY_WINDOWS_DIR/docker-compose.yml"
  run disk_size_check "$T/w"
  assert_failure 2
  assert_output --partial "not checked"
}

@test "disk_size_check: a size it cannot read reports not checked" {
  make_install "$T/w"
  local v
  for v in max half 64GB lots; do
    write_compose "DISK_SIZE=$v"
    run disk_size_check "$T/w"
    assert_failure 2
    assert_output --partial "not checked"
  done
}

# --- share_check ---

@test "share_check: a real ~/Windows folder of the user passes" {
  mkdir "$HOME/Windows"
  run share_check
  assert_success
}

@test "share_check: missing, a file, or a symlink is refused" {
  run share_check
  assert_failure
  assert_output --partial "does not exist"
  touch "$HOME/Windows"
  run share_check
  assert_failure
  assert_output --partial "is not a folder"
  rm "$HOME/Windows"
  mkdir "$T/elsewhere"
  ln -s "$T/elsewhere" "$HOME/Windows"
  run share_check
  assert_failure
  assert_output --partial "is a symlink"
}

@test "share_check: a folder owned by another user is refused" {
  mkdir "$HOME/Windows"
  # Pretend to be a different user than the folder's owner.
  # shellcheck disable=SC2016 # the shim's $1 and $@ stay literal
  shim id 'if [[ $1 == -u ]]; then echo 4242; else exec /usr/bin/id "$@"; fi'
  PATH=$T/shims:$PATH run share_check
  assert_failure
  assert_output --partial "owned by another user"
}

# --- container_running and container_preparing ---

@test "container_running: finds dockur's QEMU in a systemd docker scope" {
  fake_proc 4100 "$DOCKER_SCOPE" qemu-system-x86_64 -name Windows,process=windows
  LANAI_PROC=$T/proc run container_running
  assert_success
  assert_output 4100
}

@test "container_running: finds QEMU in a cgroupfs docker group" {
  fake_proc 4200 /docker/4f1c2d3e4b5a6978 /usr/bin/qemu-system-x86_64 -m 8G
  LANAI_PROC=$T/proc run container_running
  assert_success
  assert_output 4200
}

@test "container_running: ignores a QEMU outside docker and a docker shell that names QEMU" {
  fake_proc 4300 /user.slice/user-1000.slice/user@1000.service/session.slice/lanai-vm.service \
    qemu-system-x86_64 -name Lanai,process=lanai
  fake_proc 4301 "$DOCKER_SCOPE" bash -c "exec qemu-system-x86_64"
  fake_proc 4302 /user.slice/user-1000.slice/user@1000.service/app.slice/docker-desktop.scope \
    qemu-system-x86_64
  fake_proc 4303 "$DOCKER_SCOPE"
  LANAI_PROC=$T/proc run container_running
  assert_failure
  assert_output ""
}

@test "container_preparing: dockur's entry script without QEMU yet" {
  fake_proc 4400 "$DOCKER_SCOPE" /usr/bin/tini -s /run/entry.sh
  fake_proc 4401 "$DOCKER_SCOPE" bash /run/entry.sh
  LANAI_PROC=$T/proc run container_preparing
  assert_success
}

@test "container_preparing: not once the container's QEMU runs" {
  fake_proc 4400 "$DOCKER_SCOPE" /usr/bin/tini -s /run/entry.sh
  fake_proc 4402 "$DOCKER_SCOPE" qemu-system-x86_64 -name Windows
  LANAI_PROC=$T/proc run container_preparing
  assert_failure
}

@test "container_preparing: an entry.sh outside docker does not count" {
  fake_proc 4500 /user.slice/user-1000.slice/session-2.scope bash /run/entry.sh
  fake_proc 4501 /user.slice/user-1000.slice/session-2.scope vim /tmp/entry.sh
  LANAI_PROC=$T/proc run container_preparing
  assert_failure
}

# --- settings_seed ---

# Fake /proc with <MemTotal kB> and <n> processors, for the defaults.
fake_host() {
  mkdir -p "$T/proc"
  printf 'MemTotal:       %s kB\nMemFree:         1000 kB\n' "$1" >"$T/proc/meminfo"
  local i
  : >"$T/proc/cpuinfo"
  for ((i = 0; i < $2; i++)); do printf 'processor\t: %d\nmodel name\t: Fake\n\n' "$i" >>"$T/proc/cpuinfo"; done
}

@test "settings_seed: reads RAM_SIZE and CPU_CORES from a readable compose" {
  write_compose RAM_SIZE=12G CPU_CORES=6
  fake_host 65536000 32
  LANAI_PROC=$T/proc run settings_seed
  assert_success
  assert_output '{"memory_gib":12,"cores":6,"source":"omarchy-windows-vm"}'
}

@test "settings_seed: without a compose, half the host, at most 16 GiB and 8 cores" {
  local case
  for case in "65536000 32 16 8" "16384000 6 7 3" "3000000 1 1 1" "33554432 16 16 8"; do
    read -r kb n mem cores <<<"$case"
    fake_host "$kb" "$n"
    LANAI_PROC=$T/proc run settings_seed
    assert_success
    assert_output "{\"memory_gib\":$mem,\"cores\":$cores,\"source\":\"defaults\"}"
  done
}

@test "settings_seed: an unreadable compose uses the defaults, with no prompt" {
  require_non_root
  write_compose RAM_SIZE=12G CPU_CORES=6
  chmod 000 "$OMARCHY_WINDOWS_DIR/docker-compose.yml"
  fake_host 16384000 6
  LANAI_PROC=$T/proc run settings_seed </dev/null
  assert_success
  assert_output '{"memory_gib":7,"cores":3,"source":"defaults"}'
}

@test "settings_seed: values it cannot use fall back to the defaults" {
  fake_host 16384000 6
  local bad
  for bad in "RAM_SIZE=half" "RAM_SIZE=0G" "CPU_CORES=0" "CPU_CORES=four" "RAM_SIZE="; do
    write_compose "$bad"
    LANAI_PROC=$T/proc run settings_seed
    assert_success
    assert_output '{"memory_gib":7,"cores":3,"source":"defaults"}'
  done
}

@test "the compose password never reaches output, files, or any child's argv or env" {
  grep -q "$SENTINEL" "$FIX/docker-compose.yml"
  write_compose
  make_install "$T/w"
  echo win11x64.iso >"$T/w/windows.base"
  fake_host 16384000 6
  # Each shim logs its name, argv and environment, then runs the real tool.
  local tool real log=$T/children.log
  for tool in sed awk grep head tail cat jq cut tr sort wc stat numfmt cmp find id nproc getconf timeout; do
    real=$(command -v "$tool") || continue
    shim "$tool" "{ printf '%s\n' \"\$0\" \"\$@\"; env; } >>'$log'; exec '$real' \"\$@\""
  done
  PATH=$T/shims:$PATH LANAI_PROC=$T/proc run settings_seed
  assert_success
  refute_output --partial "$SENTINEL"
  PATH=$T/shims:$PATH run layout_check "$T/w"
  assert_success
  refute_output --partial "$SENTINEL"
  PATH=$T/shims:$PATH run disk_size_check "$T/w"
  refute_output --partial "$SENTINEL"
  # The shims ran, and a child read the compose.
  grep -q "$OMARCHY_WINDOWS_DIR/docker-compose.yml" "$log"
  run grep -rl "$SENTINEL" "$T" "$HOME"
  assert_output "$OMARCHY_WINDOWS_DIR/docker-compose.yml"
}

# --- host_scale ---

@test "host_scale: the focused monitor's scale as a percentage" {
  shim hyprctl 'cat <<EOF
[{"name": "DP-1", "focused": false, "scale": 1.00},
 {"name": "HDMI-A-1", "focused": true, "scale": 1.50}]
EOF'
  PATH=$T/shims:$PATH run host_scale
  assert_success
  assert_output 150
}

@test "host_scale: fractional scales keep two decimals" {
  local pair
  for pair in "1.125:112.5" "1.666667:166.67" "1:100" "2.5:250"; do
    shim hyprctl "echo '[{\"focused\": true, \"scale\": ${pair%%:*}}]'"
    PATH=$T/shims:$PATH run host_scale
    assert_output "${pair#*:}"
  done
}

@test "host_scale: fails with no focused monitor or no Hyprland" {
  shim hyprctl "echo '[{\"focused\": false, \"scale\": 2}]'"
  PATH=$T/shims:$PATH run host_scale
  assert_failure
  shim hyprctl 'echo "HYPRLAND_INSTANCE_SIGNATURE not set" >&2; exit 1'
  PATH=$T/shims:$PATH run host_scale
  assert_failure
  shim hyprctl "echo 'not json'"
  PATH=$T/shims:$PATH run host_scale
  assert_failure
}

# --- scale_step ---

# Assert scale_step maps each "<input>:<step>" pair.
assert_steps() {
  local pair
  for pair in "$@"; do
    run scale_step "${pair%%:*}"
    assert_success
    assert_equal "${pair%%:*} -> $output" "${pair%%:*} -> ${pair#*:}"
  done
}

@test "scale_step: every Windows step maps to itself" {
  assert_steps 100:100 125:125 150:150 175:175 200:200 225:225 250:250 \
    300:300 350:350 400:400 450:450 500:500
}

@test "scale_step: a tie rounds down" {
  assert_steps 112.5:100 137.5:125 162.5:150 187.5:175 212.5:200 237.5:225 \
    275:250 325:300 375:350 425:400 475:450
}

@test "scale_step: just below and above each boundary" {
  assert_steps 112.49:100 112.51:125 137.49:125 137.51:150 162.49:150 162.51:175 \
    187.49:175 187.51:200 212.49:200 212.51:225 237.49:225 237.51:250 \
    274.99:250 275.01:300 324.99:300 325.01:350 374.99:350 375.01:400 \
    424.99:400 425.01:450 474.99:450 475.01:500
}

@test "scale_step: the 250-300 gap goes to the nearer end" {
  assert_steps 251:250 260:250 266.67:250 290:300 299:300
}

@test "scale_step: below 100 and above 500 clamp to the ends" {
  assert_steps 0:100 50:100 99.99:100 500.01:500 600:500 1000:500
}

@test "scale_step: refuses input that is not a plain number" {
  local bad
  for bad in "" abc -5 1e3 "150%" "1.5.0" " 150"; do
    run scale_step "$bad"
    assert_failure
  done
}

# --- dockur_version ---

@test "dockur_version: the image's version label, asked without a prompt" {
  shim docker 'printf "%s\n" "$@" >"'"$T"'/docker.args"; [ -t 0 ] && echo tty >>"'"$T"'/docker.args"; echo 6.05'
  PATH=$T/shims:$PATH run dockur_version
  assert_success
  assert_output 6.05
  run cat "$T/docker.args"
  assert_line dockurr/windows
  assert_line --partial org.opencontainers.image.version
  refute_line tty
}

@test "dockur_version: fails quietly when docker is denied, missing or has no label" {
  shim docker 'echo "permission denied while trying to connect" >&2; exit 1'
  PATH=$T/shims:$PATH run dockur_version
  assert_failure
  assert_output ""
  shim docker 'echo "<no value>"'
  PATH=$T/shims:$PATH run dockur_version
  assert_failure
  assert_output ""
  rm "$T/shims/docker"
  mkdir "$T/bin"
  ln -s "$(command -v timeout)" "$T/bin/timeout"
  PATH=$T/bin run dockur_version
  assert_failure
  assert_output ""
}
