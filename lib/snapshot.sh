# Snapshot and restore of the storage location (spec 7, plan phase 4).
# lib/lanai.sh sources this file; it defines functions and constants only.
#
# A snapshot is an instant copy (a reflink copy that shares its data blocks)
# at <data>/snapshots/<name>/, or at <storage>.lanai-snapshots/<name>/ when
# the data folder cannot reflink from the storage location. <name> is the
# UTC time, like 20260928T193000Z. It is built in <name>.partial/, checked
# file by file (list, size, SHA-256) against the storage location while
# QEMU's write lock is held, given a COMPLETE file holding that manifest,
# and only then renamed. Only a folder with a matching COMPLETE counts.
# shellcheck shell=bash

LANAI_SNAP_RE='^[0-9]{8}T[0-9]{6}Z$'

# Print the places snapshots of <storage> may live, in order of preference.
snapshot_roots() {
  printf '%s\n' "$(data_dir)/snapshots" "$1.lanai-snapshots"
}

# Print the first snapshot place that can hold an instant copy of the
# install at <storage>, probed with a real reflink of windows.mac (a small
# file). A folder the probe had to create is removed again when it fails.
# Fails when neither place can reflink.
snapshot_root() {
  local storage=$1 root probe made
  while IFS= read -r root; do
    made=0
    if [[ ! -d $root ]]; then
      mkdir -p -- "$root" 2>/dev/null || continue
      made=1
    fi
    probe=$root/.lanai-probe.$$
    if reflink_file "$storage/windows.mac" "$probe"; then
      rm -f -- "$probe"
      printf '%s\n' "$root"
      return 0
    fi
    rm -f -- "$probe"
    ((made == 0)) || rmdir -- "$root" 2>/dev/null || true
  done < <(snapshot_roots "$storage")
  return 1
}

# Return 0 when <dir> is a complete snapshot: a real folder with a snapshot
# name, a COMPLETE manifest of top-level regular files only, and exactly
# those files at those sizes beside it. (restore checks every SHA-256 at
# the end.)
snapshot_valid() {
  local d=$1 kind size sum name want="" have
  [[ ${d##*/} =~ $LANAI_SNAP_RE && -d $d && ! -L $d && -f $d/COMPLETE && ! -L $d/COMPLETE ]] || return 1
  while read -r kind size sum name; do
    [[ $kind == f && $size =~ ^[0-9]+$ && $sum =~ ^[0-9a-f]{64}$ && -n $name && $name != */* &&
      $name != COMPLETE ]] || return 1
    want+="f $name $size"$'\n'
  done <"$d/COMPLETE"
  [[ -n $want ]] || return 1
  have=$(find "$d" -mindepth 1 -maxdepth 1 ! -name COMPLETE -printf '%y %P %s\n' | LC_ALL=C sort)
  [[ $have == "$(LC_ALL=C sort <<<"${want%$'\n'}")" ]]
}

# Print the path of every complete snapshot of <storage>, oldest first.
snapshot_list() {
  local root d
  while IFS= read -r root; do
    for d in "$root"/*; do
      if snapshot_valid "$d"; then printf '%s\t%s\n' "${d##*/}" "$d"; fi
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

# Print why a snapshot or restore must wait, and fail: Lanai's VM runs, a
# container VM runs or prepares, or a restore did not finish. The disk lock
# the caller then takes also refuses while any VM holds the disk.
snapshot_blocked() {
  local st
  if ! st=$(unit_state); then
    echo "Lanai cannot reach the systemd user manager."
  elif [[ $st != inactive && $st != failed ]]; then
    echo "Windows is running under Lanai. Shut it down first."
  elif container_running >/dev/null; then
    echo "a Docker VM is running (possibly omarchy-windows-vm). Stop it with omarchy-windows-vm stop first."
  elif container_preparing; then
    echo "a Docker container (possibly omarchy-windows-vm) is preparing a VM. Stop it with omarchy-windows-vm stop first."
  else
    return 1
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
  if reason=$(snapshot_blocked); then
    echo "$reason"
    return 1
  fi
  if [[ -e $(state_dir)/restore-in-progress ]]; then
    echo "a restore did not finish: run lanai restore again"
    return 1
  fi
  if [[ ! -f $dir/data.img || -L $dir/data.img ]] ||
    [[ -n $(find "$dir" -mindepth 1 -maxdepth 1 ! -type f -print -quit) ]]; then
    echo "$dir is not a storage location Lanai can snapshot: it needs data.img and only files"
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
  # Leftovers of an interrupted snapshot; ours, since we hold the lock.
  for d in "$root"/*.partial; do
    [[ ! -d $d || -L $d || ! ${d##*/} =~ ^[0-9]{8}T[0-9]{6}Z\.partial$ ]] || snapshot_remove "$d"
  done
  name=$(date -u +%Y%m%dT%H%M%SZ)
  part=$root/$name.partial
  if [[ -e $root/$name ]] || ! mkdir -- "$part"; then
    unlock_disk
    echo "a snapshot named $name already exists; try again in a second"
    return 1
  fi
  if reflink_tree "$dir" "$part" && m=$(tree_manifest "$dir") &&
    [[ $m == "$(tree_manifest "$part")" ]] && printf '%s\n' "$m" >"$part/COMPLETE" &&
    mv -T -- "$part" "$root/$name"; then
    unlock_disk
    printf '%s\n' "$root/$name"
    return 0
  fi
  snapshot_remove "$part"
  unlock_disk
  echo "the snapshot failed; nothing was kept"
  return 1
}

# restore [<name>]: return the storage location to snapshot <name>. First
# the "restore-in-progress" marker names the snapshot; then, under QEMU's
# write lock, every file but data.img is replaced through a temp file and a
# rename, and data.img is cloned in place with ficlone.py, so it is never
# empty and the locked inode is the one written; files not in the snapshot
# are removed; the result is checked against the manifest, and only then
# is the marker deleted. While the marker exists, a restore without a name
# resumes the same snapshot. Prints what it did, or why it stopped.
snapshot_restore() {
  local want=${1:-} dir s marker snap reason kind size sum name rc=0 e
  local -a order=()
  local -A keep=()
  dir=$(storage_dir) || return 1
  s=$(state_dir)
  marker=$s/restore-in-progress
  if [[ -f $marker ]]; then
    snap=$(<"$marker")
    if [[ -n $want && $want != "${snap##*/}" ]]; then
      echo "a restore of ${snap##*/} did not finish: run lanai restore again to finish it first"
      return 1
    fi
  elif [[ -z $want ]]; then
    echo "name a snapshot to restore (lanai snapshots lists them)"
    return 1
  elif ! snap=$(snapshot_find "$dir" "$want"); then
    echo "there is no complete snapshot named $want"
    return 1
  fi
  if ! snapshot_valid "$snap"; then
    echo "$snap is not a complete snapshot"
    return 1
  fi
  if reason=$(snapshot_blocked); then
    echo "$reason"
    return 1
  fi
  while read -r kind size sum name; do
    keep[$name]=1
    [[ $name == data.img ]] || order+=("$name")
  done <"$snap/COMPLETE"
  [[ -n ${keep[data.img]:-} ]] || {
    echo "$snap has no data.img"
    return 1
  }
  order+=(data.img)
  mkdir -p -- "$dir"
  if [[ ! -f $dir/data.img ]]; then
    # dockur deleted the disk: put it back first, so its lock can be taken.
    if ! reflink_file "$snap/data.img" "$dir/.lanai-restore.data.img" ||
      ! mv -f -T -- "$dir/.lanai-restore.data.img" "$dir/data.img"; then
      echo "cannot copy data.img back from $snap"
      return 1
    fi
  fi
  if ! lock_disk "$dir/data.img"; then
    echo "cannot take the disk lock on $dir/data.img ($LANAI_LOCK_ERROR). Stop the VM that uses it first."
    return 1
  fi
  mkdir -p -- "$s"
  printf '%s\n' "$snap" >"$marker"
  for name in "${order[@]}"; do
    if [[ $name == data.img ]]; then
      python3 "$LANAI_LIB/ficlone.py" "$snap/data.img" "$dir/data.img" || rc=1
    elif ! reflink_file "$snap/$name" "$dir/.lanai-restore.$name" ||
      ! mv -f -T -- "$dir/.lanai-restore.$name" "$dir/$name"; then
      rc=1
    fi
    ((rc == 0)) || break
  done
  if ((rc == 0)); then
    while IFS= read -r -d '' e; do
      [[ -n ${keep[$e]:-} ]] || rm -rf -- "${dir:?}/$e"
    done < <(find "$dir" -mindepth 1 -maxdepth 1 -printf '%P\0')
    [[ $(tree_manifest "$dir") == "$(<"$snap/COMPLETE")" ]] || rc=1
  fi
  unlock_disk
  if ((rc != 0)); then
    echo "the restore did not finish: run lanai restore again"
    return 1
  fi
  rm -f -- "$marker"
  echo "restored $dir from $snap"
}
