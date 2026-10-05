# Snapshot and restore of the storage location (spec 7, plan phase 4).
# lib/lanai.sh sources this file; it defines functions and constants only.
#
# A snapshot is an instant copy (a reflink copy that shares its data blocks)
# at <data>/snapshots/<name>/, or at <storage>.lanai-snapshots/<name>/ when
# the data folder cannot reflink from the storage location. <name> is the
# UTC time, like 20260928T193000Z. It is built in <name>.partial/, checked
# file by file (list, size, SHA-256) against the storage location while
# QEMU's write lock is held, given a SOURCE file (the storage location's
# real path) and a COMPLETE file (the manifest), and only then renamed. A
# snapshot counts only for the storage location its SOURCE names, and only
# with a matching COMPLETE. The callers hold lanai_flock, so no two
# snapshots or restores overlap.
# shellcheck shell=bash

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

# Print the first snapshot place that can hold an instant copy of the
# install at <storage>, probed with a real reflink of windows.mac (a small
# file). Places are made with mode 0700; one that fails own_dir is
# skipped. A folder the probe had to create is removed again
# when it fails. Fails when neither place can reflink.
snapshot_root() {
  local storage=$1 root probe made
  while IFS= read -r root; do
    made=0
    if [[ ! -e $root && ! -L $root ]]; then
      if ! mkdir -p -- "${root%/*}" 2>/dev/null || ! mkdir -m 700 -- "$root" 2>/dev/null; then
        continue
      fi
      made=1
    fi
    own_dir "$root" || continue
    # A place that cannot reflink is expected here, so cp's error is hidden.
    probe=$root/.lanai-probe.$$
    if reflink_file "$storage/windows.mac" "$probe" 2>/dev/null; then
      rm -f -- "$probe"
      printf '%s\n' "$root"
      return 0
    fi
    rm -f -- "$probe"
    ((made == 0)) || rmdir -- "$root" 2>/dev/null || true
  done < <(snapshot_roots "$storage")
  return 1
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
  [[ ${d##*/} =~ $LANAI_SNAP_RE && -d $d && ! -L $d ]] || return 1
  [[ $(stat -c %u -- "$d") == "$(id -u)" ]] && own_dir "${d%/*}" || return 1
  [[ -f $d/SOURCE && ! -L $d/SOURCE && -f $d/COMPLETE && ! -L $d/COMPLETE ]] || return 1
  [[ $(<"$d/SOURCE") == "$storage" ]] || return 1
  while read -r kind size sum name; do
    [[ $kind == f && $size =~ ^[0-9]+$ && $sum =~ ^[0-9a-f]{64}$ &&
      $LANAI_STORE_NAMES == *" $name "* ]] || return 1
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

# snapshot: make a snapshot of the storage location. Prints its path; on a
# refusal prints the reason, and returns 3 when no place can reflink.
snapshot_create() {
  local dir reason root name part m d
  dir=$(storage_dir) || return 1
  if [[ $dir == *$'\n'* ]]; then
    echo "the storage location's path holds a newline"
    return 1
  fi
  if reason=$(snapshot_blocked) || reason=$(restore_pending) || reason=$(storage_problem "$dir" snapshot); then
    echo "$reason"
    return 1
  fi
  # The adoption checks (the setup flow's snapshot step comes after them),
  # which also make sure snapshot_root's probe file, windows.mac, exists.
  if ! reason=$(layout_check "$dir"); then
    printf '%s\n' "$reason"
    return 1
  fi
  root=$(snapshot_root "$dir") || {
    echo "$dir's filesystem cannot make an instant copy here."
    return 3
  }
  if ! lock_disk "$dir/data.img"; then
    echo "cannot take the disk lock on $dir/data.img ($LANAI_LOCK_ERROR). Stop the VM that uses it first."
    return 1
  fi
  # Leftovers of an interrupted snapshot of this location. Under lanai_flock
  # no snapshot is being built, so one without a SOURCE yet (stopped
  # mid-copy) is a leftover too; another location's are left alone.
  for d in "$root"/*.partial; do
    [[ -d $d && ! -L $d ]] || continue
    d=${d%.partial}
    [[ ${d##*/} =~ $LANAI_SNAP_RE ]] || continue
    if [[ ! -e $d.partial/SOURCE || $(<"$d.partial/SOURCE") == "$dir" ]]; then
      snapshot_remove "$d.partial"
    fi
  done
  name=$(date -u +%Y%m%dT%H%M%SZ)
  part=$root/$name.partial
  if [[ -e $root/$name || -e $part ]]; then
    unlock_disk
    echo "a snapshot named $name already exists; try again in a second"
    return 1
  fi
  if ! mkdir -m 700 -- "$part"; then
    unlock_disk
    echo "cannot create $part"
    return 1
  fi
  # Success is reported only once the tree, its rename and its final name
  # are on disk: a crash must not leave the reported snapshot named
  # *.partial, which the next snapshot would remove as a leftover. sync -f
  # commits the whole filesystem, cloned files included; sync FILE would
  # fsync only the files named, which on XFS leaves the clones unflushed.
  if reflink_tree "$dir" "$part" && printf '%s\n' "$dir" >"$part/SOURCE" &&
    m=$(tree_manifest "$dir") && [[ $m == "$(snapshot_manifest "$part")" ]] &&
    printf '%s\n' "$m" >"$part/COMPLETE" && sync -f -- "$part" &&
    mv -T -- "$part" "$root/$name"; then
    unlock_disk
    if ! sync -f -- "$root"; then
      echo "the snapshot at $root/$name could not be flushed to disk, so it may not survive a crash; delete it with rm -rf ${root@Q}/$name and try again"
      return 1
    fi
    printf '%s\n' "$root/$name"
    return 0
  fi
  snapshot_remove "$part"
  unlock_disk
  echo "the snapshot failed; nothing was kept"
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

# restore [<name>]: return the storage location to snapshot <name>. The
# storage location must pass storage_problem before anything happens. When
# data.img exists, QEMU's write lock is taken next and held to the end, and
# the snapshot's files must match its manifest before anything is written.
# Then the "restore-in-progress" marker names the snapshot and the storage
# location (a deleted data.img is put back and locked only after it); every
# file but data.img is replaced through a temp file and a rename, and data.img is cloned in place with ficlone.py, so it
# is never empty and the locked inode is the one written; other regular
# files are removed; the result is checked against the manifest, flushed,
# and only then is the marker deleted. While the marker exists, a restore
# without a name resumes it; when its snapshot is gone or damaged, a named
# restore of another snapshot replaces it. Prints what it did, or why it
# stopped.
snapshot_restore() {
  local want=${1:-} dir s marker snap="" msrc="" reason note="" kind size sum name rc=0 e
  local fail="run lanai restore again"
  local -a order=() strays=()
  local -A keep=()
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
  if [[ -f $dir/data.img ]] && [[ $(has_nocow "$snap/data.img" && echo C) != "$(has_nocow "$dir/data.img" && echo C)" ]]; then
    echo "$dir/data.img and $snap/data.img differ in NOCOW (the C attribute), so btrfs cannot clone one onto the other. Nothing was changed."
    return 1
  fi
  # QEMU's write lock is held from here to the end whenever the disk exists,
  # through the minutes of hashing too, so no container VM (or a direct
  # start of lanai-vm) can boot while the restore runs. Taking it writes
  # nothing, so a refusal before the marker still changes nothing.
  local locked=0
  if [[ -f $dir/data.img ]]; then
    if ! lock_disk "$dir/data.img"; then
      echo "cannot take the disk lock on $dir/data.img ($LANAI_LOCK_ERROR). Stop the VM that uses it first. Nothing was changed."
      return 1
    fi
    locked=1
  fi
  if [[ $(snapshot_manifest "$snap") != "$(<"$snap/COMPLETE")" ]]; then
    ((locked == 0)) || unlock_disk
    echo "$snap is damaged: its files do not match its manifest. Nothing was changed."
    return 1
  fi
  while read -r kind size sum name; do
    keep[$name]=1
    [[ $name == data.img ]] || order+=("$name")
  done <"$snap/COMPLETE"
  order+=(data.img)
  # The marker comes before the first write to the storage folder, so a
  # restore that stops anywhere after it blocks lanai start until it is
  # finished.
  if ! restore_mark "$marker" "$snap" "$dir"; then
    ((locked == 0)) || unlock_disk
    echo "cannot write $marker; nothing was changed"
    return 1
  fi
  if ((locked == 0)); then
    # dockur deleted the disk: put it back first, so its lock can be taken.
    if ! reflink_file "$snap/data.img" "$dir/.lanai-restore.data.img" ||
      ! mv -f -T -- "$dir/.lanai-restore.data.img" "$dir/data.img"; then
      echo "the restore did not finish: cannot copy data.img back from $snap; run lanai restore again"
      return 1
    fi
    if ! lock_disk "$dir/data.img"; then
      echo "the restore did not finish: cannot take the disk lock on $dir/data.img ($LANAI_LOCK_ERROR). Stop the VM that uses it, then run lanai restore again."
      return 1
    fi
  fi
  for name in "${order[@]}"; do
    if [[ $name == data.img ]]; then
      if ! reason=$(python3 "$LANAI_LIB/ficlone.py" "$snap/data.img" "$dir/data.img" 2>&1); then
        # Keep ficlone.py's detail, but other files were already replaced,
        # so its "nothing was changed" is not true here; and always end with
        # the next step.
        rc=1 fail=${reason#ficlone.py: }
        fail=${fail//; nothing was changed/}
        [[ $fail == *"the snapshot is intact"* ]] || fail+="; run lanai restore again"
      fi
    elif ! reflink_file "$snap/$name" "$dir/.lanai-restore.$name" ||
      ! mv -f -T -- "$dir/.lanai-restore.$name" "$dir/$name"; then
      rc=1
    fi
    ((rc == 0)) || break
  done
  if ((rc == 0)); then
    # Only names a restore may remove; anything that appeared while the
    # disk was being hashed or cloned stays, and the restore does not finish.
    while IFS= read -r -d '' e; do
      [[ -z ${keep[$e]:-} ]] || continue
      if restorable_name "$e" && [[ -f $dir/$e && ! -L $dir/$e ]]; then
        rm -f -- "${dir:?}/$e" || rc=1
      else
        strays+=("$e")
      fi
    done < <(find "$dir" -mindepth 1 -maxdepth 1 -printf '%P\0' | LC_ALL=C sort -z)
    if ((${#strays[@]})); then
      rc=1
      fail="$(printf '%s, ' "${strays[@]}" | sed 's/, $//') appeared in $dir while it ran; move that out, then run lanai restore again"
    fi
    ((rc != 0)) || [[ $(tree_manifest "$dir") == "$(<"$snap/COMPLETE")" ]] || rc=1
    ((rc != 0)) || sync -f -- "$dir" || rc=1
  fi
  unlock_disk
  if ((rc != 0)); then
    echo "the restore did not finish: $fail"
    return 1
  fi
  rm -f -- "$marker"
  echo "${note}restored $dir from $snap"
}
