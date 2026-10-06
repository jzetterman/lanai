# Snapshot and restore of the storage location (spec 7, plan phase 4).
# lib/lanai.sh sources this file; it defines functions and constants only.
#
# A snapshot is an instant copy (a reflink copy that shares its data blocks)
# at <data>/snapshots/<name>/, or at <storage>.lanai-snapshots/<name>/ when
# the data folder cannot reflink from the storage location. <name> is the
# UTC time, like 20260928T193000Z. It is built in <name>.partial/, checked
# by shared image extents and small-file bytes against the storage location while
# QEMU's write lock is held, given a SOURCE file (the storage location's
# real path) and a COMPLETE file (the manifest), and only then renamed. A
# snapshot counts only for the storage location its SOURCE names, and only
# with a matching COMPLETE. The callers hold lanai_flock, so no two
# snapshots or restores overlap.
# shellcheck shell=bash
# The operation wrapper deliberately supplies exported variables to its callees.
# shellcheck disable=SC2030,SC2031

LANAI_SNAP_RE='^[0-9]{8}T[0-9]{6}Z$'

# The names a storage location may hold for a snapshot or restore: the
# omarchy-windows-vm install (layout_check's allow-list), dockur's leftover
# setup image, and a restore's own temp files.
LANAI_STORE_NAMES=" data.img windows.base windows.boot windows.mac windows.rom windows.vars windows.ver "
LANAI_STORE_LEFTOVERS=" setup.img setup.img.tmp "

# Return 0 when <dir> is a folder Lanai may trust with snapshots: a real
# folder (not a symlink), owned by the user, that no group or other user can
# write to.
own_dir() {
  local st
  [[ -d $1 && ! -L $1 ]] || return 1
  st=$(stat -c '%u %a' -- "$1") || return 1
  [[ ${st% *} == "$(id -u)" ]] && (((8#${st#* } & 8#022) == 0))
}

# Print the places snapshots of <storage> may live, in order of preference.
snapshot_roots() {
  printf '%s\n' "$(data_dir)/snapshots" "$1.lanai-snapshots"
}

# Print the manifest (tree_manifest) of snapshot folder <dir> without its
# own COMPLETE and SOURCE files.
snapshot_manifest() {
  local m
  m=$(tree_manifest "$1") || return 1
  grep -vE '^f [0-9]+ [0-9a-f]{64} (COMPLETE|SOURCE)$' <<<"$m" || true
}

# Return 0 when <dir> is a complete snapshot of <storage>: a real folder
# owned by the user, in a snapshot place that passes own_dir, with a
# snapshot name, a SOURCE naming <storage>, a COMPLETE manifest of top-level
# install files only, and exactly those files at those sizes beside them.
# (restore checks every SHA-256 before it writes anything.)
snapshot_valid() {
  local d=$1 storage=$2 kind size sum name want="" have
  local -A seen=()
  [[ ${d##*/} =~ $LANAI_SNAP_RE && -d $d && ! -L $d ]] || return 1
  [[ $(stat -c %u -- "$d") == "$(id -u)" ]] && own_dir "${d%/*}" || return 1
  [[ -f $d/SOURCE && ! -L $d/SOURCE && -f $d/COMPLETE && ! -L $d/COMPLETE ]] || return 1
  [[ $(<"$d/SOURCE") == "$storage" ]] || return 1
  while read -r kind size sum name; do
    [[ $kind == f && $size =~ ^[0-9]+$ && $sum =~ ^[0-9a-f]{64}$ &&
      $LANAI_STORE_NAMES == *" $name "* ]] || return 1
    [[ -z ${seen[$name]:-} ]] || return 1
    seen[$name]=1
    want+="f $name $size"$'\n'
  done <"$d/COMPLETE"
  [[ $want == *" data.img "* ]] || return 1
  have=$(find "$d" -mindepth 1 -maxdepth 1 ! -name COMPLETE ! -name SOURCE -printf '%y %P %s\n' |
    LC_ALL=C sort)
  [[ $have == "$(LC_ALL=C sort <<<"${want%$'\n'}")" ]]
}

# Print the path of every complete snapshot of <storage>, oldest first.
snapshot_list() {
  local root d
  while IFS= read -r root; do
    for d in "$root"/*; do
      if snapshot_valid "$d" "$1"; then printf '%s\t%s\n' "${d##*/}" "$d"; fi
    done
  done < <(snapshot_roots "$1") | LC_ALL=C sort | cut -f2-
}

# Print the path of the complete snapshot of <storage> named <name>.
snapshot_find() {
  local d
  [[ $2 =~ $LANAI_SNAP_RE ]] || return 1
  while IFS= read -r d; do
    [[ ${d##*/} != "$2" ]] || {
      printf '%s\n' "$d"
      return 0
    }
  done < <(snapshot_list "$1")
  return 1
}

# Return 0 when <name> is one a restore may replace or remove: an install
# file, dockur's leftover setup image, or a restore's own temp file.
restorable_name() {
  [[ $LANAI_STORE_NAMES$LANAI_STORE_LEFTOVERS == *" $1 "* || $1 == .lanai-restore.* ]]
}

# storage_problem <dir> snapshot|restore: print why the storage location
# <dir> is not one a snapshot or restore may touch, and succeed; fail when
# it is fine. It must be an existing real folder holding only regular files.
# A snapshot takes install files only, so dockur's leftover setup image or
# a restore's temp file must be deleted first; a restore may replace those.
# Anything else (a folder, a symlink, someone's own file) means Lanai's
# storage may point at the wrong place, so nothing is copied, replaced or
# removed.
storage_problem() {
  local dir=$1 mode=$2 e
  local -a bad=() leftovers=()
  if [[ ! -d $dir || -L $dir ]]; then
    echo "$dir is not an existing folder. Lanai snapshots and restores only an existing storage location."
    return 0
  fi
  while IFS= read -r -d '' e; do
    if ! restorable_name "$e"; then
      bad+=("$e")
    elif [[ ! -f $dir/$e || -L $dir/$e ]]; then
      bad+=("$e (not a regular file)")
    elif [[ $mode == snapshot && $LANAI_STORE_NAMES != *" $e "* ]]; then
      leftovers+=("$e")
    fi
  done < <(find "$dir" -mindepth 1 -maxdepth 1 -printf '%P\0' | LC_ALL=C sort -z)
  if ((${#bad[@]})); then
    echo "$dir holds $(printf '%s, ' "${bad[@]}" | sed 's/, $//'), which Lanai will not copy, replace or remove. Check that Lanai's storage points at the right folder, and move those out first."
  elif ((${#leftovers[@]})); then
    echo "$dir holds $(printf '%s, ' "${leftovers[@]}" | sed 's/, $//'): left over from an unfinished dockur start or restore, not Windows data; delete $( ((${#leftovers[@]} > 1)) && echo them || echo it), then take the snapshot."
  else
    return 1
  fi
}

# Print why a snapshot or restore must wait, and succeed: the user manager
# does not answer, Lanai's VM runs, or a container VM runs or prepares. The
# disk lock the caller then takes also refuses while any VM holds the disk.
snapshot_blocked() {
  local st
  if ! st=$(unit_state); then
    echo "Lanai cannot reach the systemd user manager."
  elif [[ $st != inactive && $st != failed ]]; then
    echo "Windows is running under Lanai. Shut it down first."
  else
    container_blocked
  fi
}

# Remove a folder this module made (it may hold read-only folders).
snapshot_remove() {
  chmod -R u+w -- "$1" 2>/dev/null || true
  rm -rf -- "$1"
}

# Progress belongs to the operation lock, including CLI invocations. A separate
# subshell keeps traps and exported helper context out of sourced callers.
image_operation() (
  export LANAI_IMAGE_OPERATION=$1 LANAI_IMAGE_OWNER=$BASHPID
  LANAI_IMAGE_PROGRESS="$(state_dir)/image-progress.json"
  LANAI_IMAGE_MAP="$(state_dir)/image-map.$BASHPID.json"
  export LANAI_IMAGE_PROGRESS LANAI_IMAGE_MAP
  shift
  LANAI_SNAPSHOT_PART=''
  trap 'rm -f -- "$LANAI_IMAGE_PROGRESS" "$LANAI_IMAGE_MAP"; if [[ -n $LANAI_SNAPSHOT_PART ]]; then snapshot_remove "$LANAI_SNAPSHOT_PART"; fi; unlock_disk' EXIT
  trap 'exit 130' INT
  trap 'exit 143' TERM
  image_phase cloning || exit 1
  "$@"
)

image_phase() {
  python3 "$LANAI_LIB/image-proof.py" progress "$1"
}

# Hash only small files. The image's one hash comes from image-proof.py.
small_manifest() {
  local dir=$1 name size sum
  while IFS= read -r name; do
    [[ $LANAI_STORE_NAMES == *" $name "* && $name != data.img ]] || continue
    size=$(stat -c %s -- "$dir/$name") || return 1
    sum=$(sha256sum <"$dir/$name" | cut -d ' ' -f1) || return 1
    [[ $sum =~ ^[0-9a-f]{64}$ ]] || return 1
    printf 'f %s %s %s\n' "$size" "$sum" "$name"
  done < <(find "$dir" -mindepth 1 -maxdepth 1 -printf '%P\n' | LC_ALL=C sort)
}

install_list() {
  find "$1" -mindepth 1 -maxdepth 1 ! -name SOURCE ! -name COMPLETE -printf '%y %P %s\n' | LC_ALL=C sort
}

# Make a snapshot; return 3 for an unprovable image or unsupported roots.
snapshot_create() {
  local dir reason root name part='' m image name_file rc
  dir=$(storage_dir) || return 1
  if [[ $dir == *$'\n'* ]]; then
    echo "the storage location's path holds a newline"; return 1
  fi
  if reason=$(snapshot_blocked) || reason=$(restore_pending) || reason=$(storage_problem "$dir" snapshot); then
    echo "$reason"; return 1
  fi
  if ! reason=$(layout_check "$dir" structural); then
    printf '%s\n' "$reason"; return 1
  fi
  if ! lock_disk "$dir/data.img"; then
    echo "cannot take the disk lock on $dir/data.img ($LANAI_LOCK_ERROR). Stop the VM that uses it first."; return 1
  fi
  image_phase checking
  if ! reason=$(python3 "$LANAI_LIB/image-proof.py" gate "$dir/data.img" 2>&1); then
    echo "$reason"; return 3
  fi
  name=$(date -u +%Y%m%dT%H%M%SZ)
  while IFS= read -r root; do
    if [[ ! -e $root && ! -L $root ]]; then
      if ! mkdir -p -- "${root%/*}" || ! mkdir -m 700 -- "$root"; then continue; fi
    fi
    own_dir "$root" || continue
    part=$root/$name.partial
    if [[ -e $root/$name || -e $part ]]; then
      echo "a snapshot named $name already exists; try again in a second"; return 1
    fi
    mkdir -m 700 -- "$part" || return 1
    LANAI_SNAPSHOT_PART=$part
    image_phase cloning
    rc=0
    reason=$(python3 "$LANAI_LIB/ficlone.py" --new "$dir/data.img" "$part/data.img" 2>&1) || rc=$?
    if ((rc == 0)); then break; fi
    snapshot_remove "$part"; part=''; LANAI_SNAPSHOT_PART=''
    if ((rc != 3)); then echo "the snapshot failed: $reason; nothing was kept"; return 1; fi
  done < <(snapshot_roots "$dir")
  if [[ -z $part ]]; then
    echo "$dir's filesystem cannot make an instant copy here; make a backup."; return 3
  fi
  rc=0
  while IFS= read -r name_file; do
    [[ $name_file != data.img ]] || continue
    reflink_file "$dir/$name_file" "$part/$name_file" || { rc=1; break; }
  done < <(find "$dir" -mindepth 1 -maxdepth 1 -printf '%P\n' | LC_ALL=C sort)
  if ((rc == 0)); then
    image=$(python3 "$LANAI_LIB/image-proof.py" prove "$dir/data.img" "$part/data.img" "$LANAI_IMAGE_MAP" adopt 2>&1) || rc=1
  fi
  if ((rc == 0)); then
    if m=$(small_manifest "$part"); then
      m=$( { printf '%s\n' "$image"; printf '%s\n' "$m"; } | LC_ALL=C sort -k4,4)
    else rc=1; fi
    while IFS= read -r name_file; do
      [[ $name_file != data.img ]] || continue
      cmp -s -- "$dir/$name_file" "$part/$name_file" || rc=1
    done < <(find "$dir" -mindepth 1 -maxdepth 1 -printf '%P\n' | LC_ALL=C sort)
    [[ $(install_list "$dir") == "$(install_list "$part")" ]] || rc=1
  fi
  image_phase finishing
  if ((rc == 0)) && printf '%s\n' "$dir" >"$part/SOURCE" &&
    printf '%s\n' "$m" >"$part/COMPLETE" && sync -f -- "$part" &&
    mv -T -- "$part" "$root/$name"; then
    if ! sync -f -- "$root"; then
      echo "the snapshot at $root/$name could not be flushed to disk; delete it and try again"; return 1
    fi
    printf '%s\n' "$root/$name"; return 0
  fi
  snapshot_remove "$part"
  echo "the snapshot failed: ${image:-copy or small-file check failed}; nothing was kept"
  return 1
}

# Write the restore-in-progress marker <marker> (the snapshot, then the
# storage location) and flush it and its folder to disk before any storage
# file changes.
restore_mark() {
  local marker=$1
  printf '%s\n%s\n' "$2" "$3" >"$marker.tmp" && sync -- "$marker.tmp" &&
    mv -f -- "$marker.tmp" "$marker" && sync -- "${marker%/*}"
}

# The image proof can take minutes. Recheck each staged small file against
# COMPLETE immediately before its rename, even if it passed the clone check.
restore_small_file() {
  local dir=$1 name=$2 sum=$3 actual
  if ! actual=$(sha256sum <"$dir/.lanai-restore.$name" | cut -d ' ' -f1) ||
    [[ $actual != "$sum" ]]; then
    echo "the temporary $name does not match its manifest"
    return 1
  fi
  mv -f -T -- "$dir/.lanai-restore.$name" "$dir/$name"
}

# Restore uses one image read from a fresh clone, equal maps before and after
# hashing, and a final map after in-place FICLONE. Small files are hashed before
# replacement. Failures before any replacement clean up a new marker; later
# failures keep it so recovery remains resumable. A missing disk is published
# with its lock held before hashing (John's approved req 7 exception).
snapshot_restore() {
  local want=${1:-} dir s marker snap="" msrc="" reason note="" kind size sum name rc=0 e
  local -a order=() strays=()
  local -A keep=() sums=()
  dir=$(storage_dir) || return 1
  s=$(state_dir)
  marker=$s/restore-in-progress
  if [[ -f $marker ]]; then
    { IFS= read -r snap && IFS= read -r msrc; } <"$marker" || true
    if [[ $msrc != "$dir" ]]; then
      echo "the unfinished restore ($marker) was for ${msrc:-an unknown storage location}, not $dir. Point Lanai's storage back at it, then run lanai restore again."
      return 1
    elif snapshot_valid "$snap" "$dir"; then
      if [[ -n $want && $want != "${snap##*/}" ]]; then
        echo "a restore of ${snap##*/} did not finish: run lanai restore again to finish it first"
        return 1
      fi
    elif [[ -z $want ]]; then
      echo "the unfinished restore's snapshot ($snap) is gone or damaged. Restore another snapshot by name (lanai snapshots lists them); that replaces $marker."
      return 1
    else
      note="replacing the unfinished restore of ${snap##*/} ($marker); "
      snap=""
    fi
  fi
  if [[ -z $snap ]]; then
    if [[ -z $want ]]; then
      echo "name a snapshot to restore (lanai snapshots lists them)"
      return 1
    elif ! snap=$(snapshot_find "$dir" "$want"); then
      echo "there is no complete snapshot named $want for $dir"
      return 1
    fi
  fi
  if reason=$(snapshot_blocked) || reason=$(storage_problem "$dir" restore); then
    echo "$reason"
    return 1
  fi
  if [[ ! -s $snap/data.img ]]; then
    echo "$snap's data.img is empty, so it cannot be cloned onto the disk. Nothing was changed."
    return 1
  fi
  local existed=false older=false changed=false image_sum temp reason_map
  [[ ! -e $marker ]] || older=true
  [[ ! -f $dir/data.img ]] || existed=true
  if $existed; then
    if ! lock_disk "$dir/data.img"; then
      echo "cannot take the disk lock on $dir/data.img ($LANAI_LOCK_ERROR). Stop the VM that uses it first. Nothing was changed."; return 1
    fi
  fi
  image_phase checking
  if ! reason=$(python3 "$LANAI_LIB/image-proof.py" gate "$snap/data.img" 2>&1); then
    echo "$reason. Nothing was changed."; return 3
  fi
  if $existed; then
    if ! reason=$(python3 "$LANAI_LIB/image-proof.py" filesystem "$dir/data.img" 2>&1); then
      echo "$reason. Nothing was changed."; return 3
    fi
    if [[ $(has_nocow "$snap/data.img" && echo C) != "$(has_nocow "$dir/data.img" && echo C)" ]]; then
      echo "$dir/data.img and $snap/data.img differ in NOCOW (the C attribute). Nothing was changed."; return 1
    fi
  fi
  while read -r kind size sum name; do
    keep[$name]=1
    sums[$name]=$sum
    if [[ $name == data.img ]]; then image_sum=$sum; else order+=("$name"); fi
  done <"$snap/COMPLETE"
  if ! restore_mark "$marker" "$snap" "$dir"; then
    echo "cannot write $marker; nothing was changed"; return 1
  fi
  image_phase cloning
  # Never reuse an interrupted temporary inode (its NOCOW may differ).
  for name in data.img "${order[@]}"; do
    rm -f -- "$dir/.lanai-restore.$name"
  done
  temp=$dir/.lanai-restore.data.img
  if ! reason=$(python3 "$LANAI_LIB/ficlone.py" --new "$snap/data.img" "$temp" 2>&1); then rc=1; fi
  for name in "${order[@]}"; do
    ((rc == 0)) || break
    if ! reflink_file "$snap/$name" "$dir/.lanai-restore.$name"; then rc=1; break; fi
    sum=$(awk -v n="$name" '$4 == n {print $3}' "$snap/COMPLETE")
    if [[ $(sha256sum <"$dir/.lanai-restore.$name" | cut -d ' ' -f1) != "$sum" ]]; then
      reason="$snap is damaged: $name does not match its manifest"; rc=1
    fi
  done
  if ((rc == 0)) && ! $existed; then
    # Approved req 7 exception: lock the inode before publishing, then install
    # verified boot markers before hashing, preventing dockur's disk cleanup.
    if ! lock_disk "$temp"; then
      reason="cannot take the disk lock ($LANAI_LOCK_ERROR)"; rc=1
    elif ! reason=$(python3 "$LANAI_LIB/image-proof.py" publish "$temp" "$dir/data.img" 2>&1); then
      rc=1
    else
      changed=true
      temp=$dir/data.img
      for name in "${order[@]}"; do
        if ! reason=$(restore_small_file "$dir" "$name" "${sums[$name]}"); then rc=1; break; fi
        # Boot files must exist before the image read. Keep a fresh staged
        # clone for final verification and replacement after that long read.
        if ! reflink_file "$dir/$name" "$dir/.lanai-restore.$name"; then rc=1; break; fi
      done
    fi
  fi
  if ((rc == 0)); then
    reason_map=$(python3 "$LANAI_LIB/image-proof.py" prove "$snap/data.img" "$temp" "$LANAI_IMAGE_MAP" "$image_sum" 2>&1) || { reason=$reason_map; rc=1; }
  fi
  if ((rc == 0)) && $existed; then
    # From here any failure keeps recovery blocked, even if FICLONE partially
    # changed the destination. It retains QEMU's locked inode throughout.
    changed=true
    if ! reason=$(python3 "$LANAI_LIB/ficlone.py" "$temp" "$dir/data.img" 2>&1) ||
      ! reason=$(python3 "$LANAI_LIB/image-proof.py" final "$temp" "$dir/data.img" "$LANAI_IMAGE_MAP" 2>&1); then
      rc=1
    fi
  fi
  if ((rc == 0)); then
    for name in "${order[@]}"; do
      if ! reason=$(restore_small_file "$dir" "$name" "${sums[$name]}"); then rc=1; break; fi
    done
  fi
  if $existed; then rm -f -- "$dir/.lanai-restore.data.img"; fi
  if ((rc == 0)); then
    image_phase finishing
    while IFS= read -r -d '' e; do
      [[ -z ${keep[$e]:-} ]] || continue
      if restorable_name "$e" && [[ -f $dir/$e && ! -L $dir/$e ]]; then
        rm -f -- "${dir:?}/$e" || rc=1
      else strays+=("$e"); fi
    done < <(find "$dir" -mindepth 1 -maxdepth 1 -printf '%P\0' | LC_ALL=C sort -z)
    if ((${#strays[@]})); then
      rc=1
      reason="$(printf '%s, ' "${strays[@]}" | sed 's/, $//') appeared in $dir while it ran; move that out"
    fi
    ((rc != 0)) || sync -f -- "$dir" || rc=1
  fi
  if ((rc != 0)); then
    if $existed && ! $changed; then
      for name in data.img "${order[@]}"; do rm -f -- "$dir/.lanai-restore.$name"; done
      $older || rm -f -- "$marker"
      echo "${reason:-verification failed}. Nothing was changed."
    else
      echo "the restore did not finish: ${reason:-replacement failed}; run lanai restore again; the snapshot is intact"
    fi
    return 1
  fi
  rm -f -- "$marker"
  sync -- "$s"
  echo "${note}restored $dir from $snap"
}
