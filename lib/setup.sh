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

# --- the setup media (spec 7, 26) ---

# Print the pinned guest files, one per line: "<cache name> <url> <sha256>"
# (lib/pins.sh, read at call time).
guest_pins() {
  printf '%s %s %s\n' \
    "looking-glass-idd-$LG_BUILD.zip" "$LG_IDD_URL" "$LG_IDD_SHA" \
    "spice-vdagent-x64-$VDAGENT_VERSION.msi" "$VDAGENT_URL" "$VDAGENT_SHA" \
    "qemu-ga-x86_64-$QEMU_GA_VERSION.msi" "$QEMU_GA_URL" "$QEMU_GA_SHA" \
    "winfsp-$WINFSP_VERSION.msi" "$WINFSP_URL" "$WINFSP_SHA" \
    "virtio-win-$VIRTIO_WIN_VERSION.iso" "$VIRTIO_WIN_URL" "$VIRTIO_WIN_SHA"
}

# Print the folder pinned downloads are cached in.
downloads_dir() {
  printf '%s\n' "${XDG_CACHE_HOME:-$HOME/.cache}/lanai/downloads"
}

# Download every pinned guest file into downloads_dir and verify its
# SHA-256 (fetch_verified: a cached file is used only while it matches; a
# mismatch deletes the file). On failure prints why.
setup_downloads() {
  local dl name url sum out
  dl=$(downloads_dir)
  mkdir -p -- "$dl" || {
    echo "cannot create $dl"
    return 1
  }
  while read -r name url sum; do
    if ! out=$(fetch_verified "$url" "$dl/$name" "$sum" 2>&1); then
      printf '%s\n' "${out:-could not download $url}"
      return 1
    fi
  done < <(guest_pins)
}

# Build the setup disk's folder, <state>/setup-media: remove the old media
# first, so a failure leaves none at all; download and verify the pinned
# guest files (setup_downloads); then, in setup-media.partial, renamed at
# the end, put the IDD installer from its zip, the three MSIs under the
# names setup.cmd uses, the guest scripts, and from the virtio-win ISO (too
# big for QEMU's FAT disk) only viofs/w11/amd64. The VM must be stopped: a
# running setup boot reads the folder. On failure prints why.
setup_media_build() {
  local dl media part guest=$LANAI_LIB/../guest f
  dl=$(downloads_dir)
  media=$(state_dir)/setup-media
  part=$media.partial
  chmod -R u+w -- "$media" "$part" 2>/dev/null || true
  if ! rm -rf -- "$media" "$part"; then
    echo "cannot remove the old $media"
    return 1
  fi
  setup_downloads || return 1
  mkdir -p -- "$part" || {
    echo "cannot create $part"
    return 1
  }
  if ! bsdtar -xf "$dl/looking-glass-idd-$LG_BUILD.zip" -C "$part" looking-glass-idd-setup.exe ||
    ! bsdtar -xf "$dl/virtio-win-$VIRTIO_WIN_VERSION.iso" -C "$part" viofs/w11/amd64 ||
    ! chmod -R u+rwX -- "$part"; then
    echo "cannot unpack the IDD installer or viofs/w11/amd64 from the downloads"
    rm -rf -- "$part"
    return 1
  fi
  for f in looking-glass-idd-setup.exe viofs/w11/amd64/viofs.inf viofs/w11/amd64/virtiofs.exe; do
    [[ -f $part/$f && ! -L $part/$f ]] || {
      echo "the downloads hold no $f"
      rm -rf -- "$part"
      return 1
    }
  done
  if ! cp -- "$dl/spice-vdagent-x64-$VDAGENT_VERSION.msi" "$part/spice-vdagent.msi" ||
    ! cp -- "$dl/qemu-ga-x86_64-$QEMU_GA_VERSION.msi" "$part/qemu-ga.msi" ||
    ! cp -- "$dl/winfsp-$WINFSP_VERSION.msi" "$part/winfsp.msi" ||
    ! cp -- "$guest/setup.cmd" "$guest/lanai-lock.cmd" "$guest/lanai-scale.ps1" "$part/" ||
    ! mv -T -- "$part" "$media"; then
    echo "cannot assemble $media"
    rm -rf -- "$part"
    return 1
  fi
}

# Print the window choice from setup's options: auto, or true for --window
# and false for --no-window. Fails on any other option.
window_option() {
  local w=auto a
  for a; do
    case $a in
      --window) w=true ;;
      --no-window) w=false ;;
      *) return 1 ;;
    esac
  done
  printf '%s\n' "$w"
}

# setup_guest <window auto|true|false>: step 5's setup boot (plan phase 6).
# Refuses before step 3 (no snapshot decision for this location). Builds
# the setup media under lanai_flock, with the VM stopped (in a subshell,
# released before boot_vm takes the lock again; the downloads can take
# minutes), then boots with the setup disk (boot_vm true). Emits one JSON
# object. Records no guest version: step 6 does, from evidence.
setup_guest() {
  local window=$1 dir out rc st
  if ! dir=$(storage_dir) || ! setup_current "$dir" || [[ -z $(setup_get snapshot) ]]; then
    emit false setup-needed "Lanai setup has not offered its snapshot for this storage location yet." \
      "run lanai setup"
    return 1
  fi
  rc=0
  out=$(
    lanai_flock || exit 3
    st=$(unit_state) || st=unknown
    [[ $st == inactive || $st == failed ]] || exit 4
    setup_media_build
  ) || rc=$?
  case $rc in
    0) ;;
    3)
      emit false "" "$LANAI_BUSY." "try again when it finishes"
      return 1
      ;;
    4)
      emit false "" "Windows is running under Lanai." "shut Windows down, then run setup again"
      return 1
      ;;
    *)
      emit false "" "The setup media were not built: $out" "run setup again"
      return 1
      ;;
  esac
  boot_vm true "$window"
}
