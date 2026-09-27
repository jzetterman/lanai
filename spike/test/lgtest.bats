#!/usr/bin/env bats
# Tests for the lgtest functions that guard the live disk or produce a decision number.

bats_load_library bats-support
bats_load_library bats-assert

setup() {
  # shellcheck source=../lgtest
  source "$BATS_TEST_DIRNAME/../lgtest"
  FIX=$BATS_TEST_DIRNAME/fixtures
  # Temp dirs live in spike/work so they sit on the repo's btrfs filesystem.
  mkdir -p "$BATS_TEST_DIRNAME/../work/test-tmp"
  T=$(mktemp -d "$BATS_TEST_DIRNAME/../work/test-tmp/t.XXXXXX")
}

teardown() {
  rm -rf "$T"
}

teardown_file() {
  rmdir "$BATS_TEST_DIRNAME/../work/test-tmp" 2>/dev/null || true
}

# Skip a test unless its temp dir is on btrfs.
require_btrfs() {
  [[ $(stat -f -c %T "$T") == btrfs ]] || skip "needs btrfs"
}

# --- verify_sha256 ---

@test "verify_sha256: matching sum passes and keeps the file" {
  printf 'hello\n' >"$T/f"
  run verify_sha256 "$T/f" 5891b5b522d5df086d0ff0b110fbd9d21bb4fc7163af34d08286a2e846f6be03
  assert_success
  assert [ -f "$T/f" ]
}

@test "verify_sha256: mismatch deletes the file and fails" {
  printf 'tampered\n' >"$T/f"
  run verify_sha256 "$T/f" 5891b5b522d5df086d0ff0b110fbd9d21bb4fc7163af34d08286a2e846f6be03
  assert_failure
  assert_output --partial "SHA-256 mismatch"
  assert [ ! -e "$T/f" ]
}

# --- host_busy_seconds ---

@test "host_busy_seconds: sums user, nice, system, irq and softirq of a real cpu line" {
  # (34220712 + 709189 + 8097477 + 1512962 + 1236383) ticks / 100 per second.
  # Idle, iowait, steal and the guest columns are left out.
  [[ $(getconf CLK_TCK) == 100 ]] || skip "fixture math assumes CLK_TCK=100"
  LGTEST_STAT=$FIX/stat run host_busy_seconds
  assert_success
  assert_output "457767.23"
}

# --- baseline_median ---

@test "baseline_median: odd count gives the middle value" {
  printf '60,30\n60,10\n60,20\n' >"$T/b.csv"
  run baseline_median "$T/b.csv" 60
  assert_success
  assert_output "20.00"
}

@test "baseline_median: even count gives the mean of the middle two" {
  printf '60,40\n60,10\n60,21\n60,5\n' >"$T/b.csv"
  run baseline_median "$T/b.csv" 60
  assert_success
  assert_output "15.50"
}

@test "baseline_median: rows of other lengths are ignored" {
  printf '1800,900\n60,12\n30,1\n60,14\n1800,950\n60,13\n' >"$T/b.csv"
  run baseline_median "$T/b.csv" 60
  assert_success
  assert_output "13.00"
}

@test "baseline_median: no rows of that length fails" {
  printf '1800,900\n30,1\n' >"$T/b.csv"
  run baseline_median "$T/b.csv" 60
  assert_failure
  assert_output --partial "no 60 s baseline"
}

@test "baseline_median: a missing file fails" {
  run baseline_median "$T/none.csv" 60
  assert_failure
}

# --- qemu_cmdlines ---

@test "qemu_cmdlines: finds bare and full-path QEMU, ignores a shell that mentions it" {
  # One argument per line, a blank line after each process. The fixture also
  # holds a shell whose arguments name QEMU and a kernel thread (empty cmdline).
  LGTEST_PROC=$FIX/proc-qemu run qemu_cmdlines
  assert_success
  assert_output "qemu-system-x86_64
-name
Windows,process=windows
-m
16G

/usr/bin/qemu-system-x86_64
-name
spike
-m
16G"
}

@test "qemu_cmdlines: prints nothing when no QEMU runs" {
  LGTEST_PROC=$FIX/proc-none run qemu_cmdlines
  assert_success
  assert_output ""
}

# --- disk_locked ---

# Print a file's filesystem device the way /proc/locks writes it (%02x:%02x).
locks_dev() {
  local maj min
  IFS=: read -r maj min <<<"$(mount_dev "$1")"
  printf '%02x:%02x' "$maj" "$min"
}

# Write a /proc/locks fixture with one OFD lock line on <dev>:<inode>, among
# unrelated real-format lines.
write_locks() {
  {
    echo "1: POSIX  ADVISORY  WRITE 3372069 00:1d:32123 1073741826 1073742335"
    echo "2: OFDLCK ADVISORY  READ -1 $1 100 101"
    echo "3: FLOCK  ADVISORY  WRITE 2211 00:19:998 0 EOF"
  } >"$T/locks"
}

@test "disk_locked: a lock on the image's device and inode is found" {
  touch "$T/data.img"
  write_locks "$(locks_dev "$T/data.img"):$(stat -c %i "$T/data.img")"
  LGTEST_LOCKS=$T/locks run disk_locked "$T/data.img"
  assert_success
}

@test "disk_locked: no lock line for the image" {
  touch "$T/data.img"
  write_locks "00:1d:1"
  LGTEST_LOCKS=$T/locks run disk_locked "$T/data.img"
  assert_failure 1
}

@test "disk_locked: same inode on another device does not match" {
  touch "$T/data.img"
  local dev other=fe:01
  dev=$(locks_dev "$T/data.img")
  [[ $dev != "$other" ]] || other=fe:02
  write_locks "$other:$(stat -c %i "$T/data.img")"
  LGTEST_LOCKS=$T/locks run disk_locked "$T/data.img"
  assert_failure 1
}

@test "disk_locked: an inode that extends the image's inode does not match" {
  touch "$T/data.img"
  local ino
  ino=$(stat -c %i "$T/data.img")
  write_locks "$(locks_dev "$T/data.img"):${ino}4"
  LGTEST_LOCKS=$T/locks run disk_locked "$T/data.img"
  assert_failure 1
}

@test "disk_locked: an inode that is a prefix of the image's inode does not match" {
  touch "$T/data.img"
  local ino
  ino=$(stat -c %i "$T/data.img")
  [[ ${#ino} -gt 1 ]] || skip "inode too short to truncate"
  write_locks "$(locks_dev "$T/data.img"):${ino%?}"
  LGTEST_LOCKS=$T/locks run disk_locked "$T/data.img"
  assert_failure 1
}

@test "disk_locked: live flock on btrfs shows in the real /proc/locks" {
  require_btrfs
  touch "$T/data.img"
  run disk_locked "$T/data.img"
  assert_failure 1
  exec {fd}<"$T/data.img"
  flock -s "$fd"
  run disk_locked "$T/data.img"
  exec {fd}<&-
  assert_success
  run disk_locked "$T/data.img"
  assert_failure 1
}

# --- prepare_copy ---

# Build a fake dockur storage dir at <dir>: a 1 MiB data.img (NOCOW when the
# second argument is "nocow") plus the firmware and MAC files.
make_src() {
  mkdir -p "$1"
  touch "$1/data.img"
  [[ ${2:-} != nocow ]] || chattr +C "$1/data.img"
  dd if=/dev/urandom of="$1/data.img" bs=1M count=1 conv=notrunc,fsync status=none
  echo rom >"$1/windows.rom"
  echo vars >"$1/windows.vars"
  echo 02:4B:81:73:3C:96 >"$1/windows.mac"
}

# Point the QEMU and lock checks at quiet fixtures.
quiet_host() {
  export LGTEST_PROC=$FIX/proc-none
  : >"$T/nolocks"
  export LGTEST_LOCKS=$T/nolocks
}

@test "prepare_copy: refuses while a QEMU process runs" {
  make_src "$T/src"
  quiet_host
  LGTEST_PROC=$FIX/proc-qemu run prepare_copy "$T/src" "$T/dst"
  assert_failure
  assert_output --partial "QEMU process is running"
  assert [ ! -e "$T/dst" ]
  assert [ ! -e "$T/dst.tmp" ]
}

@test "prepare_copy: refuses while the source disk is locked" {
  make_src "$T/src"
  quiet_host
  write_locks "$(locks_dev "$T/src/data.img"):$(stat -c %i "$T/src/data.img")"
  LGTEST_LOCKS=$T/locks run prepare_copy "$T/src" "$T/dst"
  assert_failure
  assert_output --partial "is locked"
  refute_output --partial "QEMU process"
  assert [ ! -e "$T/dst" ]
}

@test "prepare_copy: refuses when it cannot check locks" {
  make_src "$T/src"
  quiet_host
  LGTEST_LOCKS=$T/missing-locks run prepare_copy "$T/src" "$T/dst"
  assert_failure
  assert_output --partial "cannot check locks"
  assert [ ! -e "$T/dst" ]
  assert [ ! -e "$T/dst.tmp" ]
}

@test "prepare_copy: refuses when the destination exists" {
  make_src "$T/src"
  quiet_host
  mkdir "$T/dst"
  echo keep >"$T/dst/marker"
  run prepare_copy "$T/src" "$T/dst"
  assert_failure
  assert_output --partial "already exists"
  assert [ "$(cat "$T/dst/marker")" = keep ]
}

@test "prepare_copy: NOCOW source gives a NOCOW reflink copy on btrfs" {
  require_btrfs
  make_src "$T/src" nocow
  quiet_host
  run prepare_copy "$T/src" "$T/dst"
  assert_success
  [[ $(lsattr "$T/dst/data.img" | awk '{print $1}') == *C* ]]
  run filefrag -v "$T/dst/data.img"
  assert_output --partial "shared"
  cmp "$T/src/data.img" "$T/dst/data.img"
  cmp "$T/src/windows.rom" "$T/dst/windows.rom"
  cmp "$T/src/windows.vars" "$T/dst/windows.vars"
  cmp "$T/src/windows.mac" "$T/dst/windows.mac"
  assert [ ! -e "$T/dst.tmp" ]
}

@test "prepare_copy: COW source gives a copy without the C flag" {
  require_btrfs
  make_src "$T/src"
  quiet_host
  run prepare_copy "$T/src" "$T/dst"
  assert_success
  [[ $(lsattr "$T/dst/data.img" | awk '{print $1}') != *C* ]]
}

@test "prepare_copy: a failed copy leaves no dst and no dst.tmp; a rerun succeeds" {
  require_btrfs
  make_src "$T/src" nocow
  quiet_host
  rm "$T/src/windows.mac"
  run prepare_copy "$T/src" "$T/dst"
  assert_failure
  assert [ ! -e "$T/dst" ]
  assert [ ! -e "$T/dst.tmp" ]
  echo 02:4B:81:73:3C:96 >"$T/src/windows.mac"
  run prepare_copy "$T/src" "$T/dst"
  assert_success
  cmp "$T/src/data.img" "$T/dst/data.img"
}

@test "prepare_copy: a stale dst.tmp is deleted before copying" {
  require_btrfs
  make_src "$T/src" nocow
  quiet_host
  mkdir "$T/dst.tmp"
  echo junk >"$T/dst.tmp/junk"
  run prepare_copy "$T/src" "$T/dst"
  assert_success
  assert [ ! -e "$T/dst/junk" ]
  assert [ ! -e "$T/dst.tmp" ]
}

# --- vm_args (run's argument builder, checked against the real dockur capture) ---

# Join $output lines with single spaces, padded, for substring checks.
joined() {
  printf ' %s ' "$(tr '\n' ' ' <<<"$output" | sed 's/ *$//')"
}

@test "vm_args: keeps the capture, swaps tap for passt, rewrites paths" {
  run vm_args "$FIX/dockur-cmdline.txt" 192.168.1.1 0 0
  assert_success
  # argv[0] and the capture's trailing blank line are dropped.
  assert_line --index 0 -- -nodefaults
  refute_line ""
  local j
  j=$(joined)
  # Kept from the capture as-is.
  [[ $j == *" -m 16G "* ]]
  [[ $j == *" -smp 6,sockets=1,dies=1,cores=6,threads=1 "* ]]
  [[ $j == *" -smbios type=1,serial=SystemSerialNumber "* ]]
  [[ $j == *"rotation_rate=1,bootindex=3 "* ]]
  [[ $j == *" -device virtio-net-pci,id=net0,netdev=hostnet0,romfile=,mac=02:4B:81:73:3C:96 "* ]]
  # Network: passt on the capture's netdev id, loopback mapping off.
  [[ $j == *" -netdev passt,id=hostnet0,ipv6=off,map-host-loopback=none,dns-forward=192.168.1.1,tcp-ports=127.0.0.1/13389:3389,udp-ports=127.0.0.1/13389:3389 "* ]]
  refute_output --partial "tap,"
  # Paths: storage files come from work/vm, no container paths remain.
  [[ $j == *" -drive file=$WORK/vm/data.img,id=data3,"* ]]
  [[ $j == *" -drive file=$WORK/vm/windows.rom,if=pflash,unit=0,format=raw,readonly=on "* ]]
  refute_output --partial "/storage/"
  refute_output --partial "/run/shm"
  refute_output --partial "vnc"
  refute_output --partial "-monitor"
  # Display path: Looking Glass, SPICE, QMP, no emulated display.
  [[ $j == *" -object memory-backend-file,id=ivshmem,share=on,mem-path=$RUN/ivshmem,size=128M -device ivshmem-plain,memdev=ivshmem "* ]]
  [[ $j == *" -spice unix=on,addr=$RUN/spice.sock,disable-ticketing=on "* ]]
  [[ $j == *" -device virtserialport,chardev=vdagent,name=com.redhat.spice.0 "* ]]
  [[ $j == *" -device usb-redir,chardev=usbredir0 "* ]]
  [[ $j == *" -qmp unix:$RUN/qmp.sock,server=on,wait=off "* ]]
  [[ $j == *" -pidfile $RUN/qemu.pid "* ]]
  [[ $j == *" -vga none -display none "* ]]
  refute_output --partial "fat:"
  [[ $(grep -c '^-vga$' <<<"$output") == 1 ]]
}

@test "vm_args: --setup adds the GTK display and the setup disk" {
  run vm_args "$FIX/dockur-cmdline.txt" 192.168.1.1 1 0
  assert_success
  local j
  j=$(joined)
  [[ $j == *" -vga virtio -display gtk "* ]]
  [[ $j == *" -drive if=none,id=setup,file=fat:$WORK/setup,format=raw,readonly=on -device usb-storage,drive=setup "* ]]
  [[ $(grep -c '^-vga$' <<<"$output") == 1 ]]
}

@test "vm_args: --expose-loopback drops only the loopback mapping" {
  run vm_args "$FIX/dockur-cmdline.txt" 192.168.1.1 0 1
  assert_success
  refute_output --partial "map-host-loopback"
  assert_line "passt,id=hostnet0,ipv6=off,dns-forward=192.168.1.1,tcp-ports=127.0.0.1/13389:3389,udp-ports=127.0.0.1/13389:3389"
}

@test "vm_args: a container path it does not know how to rewrite fails" {
  { cat "$FIX/dockur-cmdline.txt"; printf -- '-chardev\nsocket,id=x,path=/run/shm/x.sock\n'; } >"$T/cap"
  run vm_args "$T/cap" 192.168.1.1 0 0
  assert_failure
  assert_output --partial "/run/shm/x.sock"
}

@test "vm_args: a /storage path it cannot rewrite fails" {
  { cat "$FIX/dockur-cmdline.txt"; printf -- '-virtfs\nlocal,path=/storage,mount_tag=s\n'; } >"$T/cap"
  run vm_args "$T/cap" 192.168.1.1 0 0
  assert_failure
  assert_output --partial "path=/storage"
}

@test "vm_args: a replayed network listener fails" {
  local extra
  for extra in '-vnc\n:1' '-gdb\ntcp::1234' '-s' '-incoming\ndefer' \
    '-chardev\nsocket,id=m,host=127.0.0.1,port=4444,server=on' \
    '-serial\ntelnet:127.0.0.1:5555,server=on' '-serial\nudp:127.0.0.1:5556' \
    '-spice\nport=5930,disable-ticketing=on' '-object\nsecret,id=v,vnc=:2' \
    '-chardev\nsocket,id=w,path=/x,websocket=on'; do
    { cat "$FIX/dockur-cmdline.txt"; printf -- "$extra\n"; } >"$T/cap"
    run vm_args "$T/cap" 192.168.1.1 0 0
    assert_failure
    assert_output --partial "listener"
  done
}

@test "vm_args: a work path with & is copied literally" {
  WORK='/x/a&b'
  run vm_args "$FIX/dockur-cmdline.txt" 192.168.1.1 0 0
  assert_success
  assert_line "file=/x/a&b/vm/data.img,id=data3,format=raw,cache=none,aio=native,discard=unmap,detect-zeroes=on,if=none"
}

# --- frame_index_rate ---

# Encode a 16x16 clip at <out> through libx264 yuv420p. stdin holds one frame
# per line: a palette index 0-7 (black, red, green, yellow, blue, magenta,
# cyan, white), or "b<i>" for a 50/50 blend of colors i and i+1. <rate> is the
# input frame rate; extra ffmpeg output options follow.
make_clip() {
  local out=$1 rate=$2
  shift 2
  LC_ALL=C awk '
    BEGIN { for (i = 0; i < 8; i++) { r[i] = (i % 2) * 255; g[i] = (int(i / 2) % 2) * 255; b[i] = int(i / 4) * 255 } }
    function frame(R, G, B,   s, p) { s = sprintf("%c%c%c", R, G, B); for (p = 0; p < 256; p++) printf "%s", s }
    /^b/ { i = substr($0, 2) + 0; j = (i + 1) % 8
           frame(int((r[i] + r[j]) / 2), int((g[i] + g[j]) / 2), int((b[i] + b[j]) / 2)); next }
    { frame(r[$1], g[$1], b[$1]) }' |
    ffmpeg -v error -f rawvideo -pix_fmt rgb24 -s 16x16 -r "$rate" -i - "$@" \
      -c:v libx264 -pix_fmt yuv420p -y "$out"
}

# Assert that the "advances per second" field of $output is within 1 of <want>.
assert_rate() {
  local rate
  read -r rate _ <<<"$output"
  awk -v r="$rate" -v w="$1" 'BEGIN { exit !(r - w <= 1 && w - r <= 1) }' ||
    fail "advances/s $rate is not within 1 of $1 (output: $output)"
}

@test "frame_index_rate: 60 steps/s at 60 fps counts every frame as an advance" {
  seq 0 119 | awk '{ print $1 % 8 }' | make_clip "$T/c.mp4" 60
  run frame_index_rate "$T/c.mp4" 8:8:4:4
  assert_success
  assert_rate 60
  read -r _ rep skip unr dur <<<"$output"
  assert_equal "$rep $skip $unr" "0 0 0"
  awk -v d="$dur" 'BEGIN { exit !(d > 1.95 && d < 2.05) }'
}

@test "frame_index_rate: 30 steps/s at 60 fps shows repeats" {
  seq 0 119 | awk '{ print int($1 / 2) % 8 }' | make_clip "$T/c.mp4" 60
  run frame_index_rate "$T/c.mp4" 8:8:4:4
  assert_success
  assert_rate 30
  read -r _ rep skip unr _ <<<"$output"
  assert_equal "$rep $skip $unr" "60 0 0"
}

@test "frame_index_rate: 60 steps/s with every 4th frame dropped shows skips" {
  # The display repeats the last frame in place of each dropped one.
  seq 0 119 | awk '{ n = ($1 % 4 == 3) ? $1 - 1 : $1; print n % 8 }' | make_clip "$T/c.mp4" 60
  run frame_index_rate "$T/c.mp4" 8:8:4:4
  assert_success
  assert_rate 45
  read -r _ rep skip unr _ <<<"$output"
  # 30 dropped frames; the last one has no following frame to show the skip.
  assert_equal "$rep $skip $unr" "30 29 0"
}

@test "frame_index_rate: a 50/50 blended frame is unreadable and adds no advance" {
  seq 0 119 | awk '{ i = int($1 / 2) % 8; print ($1 == 21) ? "b" i : i }' | make_clip "$T/c.mp4" 60
  run frame_index_rate "$T/c.mp4" 8:8:4:4
  assert_success
  assert_rate 30
  read -r _ rep skip unr _ <<<"$output"
  assert_equal "$rep $skip $unr" "59 0 1"
}

@test "frame_index_rate: a 30-then-60 fps variable-rate clip loses no frames" {
  # 30 frames 1/30 s apart, then 60 frames 1/60 s apart: 90 steps in 2 s.
  seq 0 89 | awk '{ print $1 % 8 }' |
    make_clip "$T/c.mp4" 60 -vf 'setpts=if(lt(N\,30)\,2*N\,N+30)/(60*TB)' -fps_mode passthrough
  run ffprobe -v error -count_frames -select_streams v:0 \
    -show_entries stream=nb_read_frames -of default=nw=1:nk=1 "$T/c.mp4"
  assert_output 90
  run frame_index_rate "$T/c.mp4" 8:8:4:4
  assert_success
  assert_rate 44.5
  read -r _ rep skip unr _ <<<"$output"
  assert_equal "$rep $skip $unr" "0 0 0"
}
