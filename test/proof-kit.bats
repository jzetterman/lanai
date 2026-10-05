#!/usr/bin/env bats
# Tests for the proof kit (docs/plugin/proof-kit/proof-vm), run as a
# command. No VM starts and nothing is downloaded: every case stops before
# QEMU, curl is a PATH shim, and `client` talks to test/fixtures/fake-qmp and
# execs a stand-in client.
# shellcheck disable=SC2030,SC2031

load helpers

setup() {
  isolate_home
  T=$BATS_TEST_TMPDIR
  KIT=$REPO/docs/plugin/proof-kit
  RUN=$XDG_RUNTIME_DIR/lanai-proof
  mkdir -p "$T/shims"
  export T REPO
}

teardown() {
  stop_bg
}

# Make a fake copy at <dir>: a disk and one state file.
make_copy() {
  mkdir -p "$1"
  truncate -s 1M "$1/data.img"
  echo rom >"$1/windows.rom"
}

# Put a curl shim first on PATH that writes junk to its -o file, so every
# download fails its SHA-256 check.
junk_curl() {
  cat >"$T/shims/curl" <<'EOF'
#!/usr/bin/env bash
while (($#)); do
  if [[ $1 == -o ]]; then echo junk >"$2"; fi
  shift
done
EOF
  chmod +x "$T/shims/curl"
}

@test "proof-vm: a path with a newline is refused before any QEMU argument is built" {
  local nl=$T/co$'\n'py
  make_copy "$nl"
  make_copy "$T/copy"
  mkdir -p "$T/sh"$'\n'"are" "$T/setup"
  run "$KIT/proof-vm" args "$nl"
  assert_failure
  assert_output --partial "must not contain a newline"
  run "$KIT/proof-vm" args "$T/copy" --share "$T/sh"$'\n'"are"
  assert_failure
  assert_output --partial "must not contain a newline"
  run "$KIT/proof-vm" args "$T/copy" --setup "$T/setup" --iso "$T/x"$'\n'".iso"
  assert_failure
  assert_output --partial "must not contain a newline"
  mkdir -m 700 "$T/r"$'\n'"un"
  XDG_RUNTIME_DIR=$T/r$'\n'un run "$KIT/proof-vm" args "$T/copy"
  assert_failure
  assert_output --partial "must not contain a newline"
}

@test "proof-vm media: a media folder with a newline is refused" {
  run "$KIT/proof-vm" media "$T/me"$'\n'"dia"
  assert_failure
  assert_output --partial "must not contain a newline"
  assert [ ! -e "$T/me"$'\n'"dia" ]
}

@test "proof-vm media: a download that fails its pin stops, and no unverified installer is left" {
  junk_curl
  mkdir -p "$T/kit/setup"
  # Stale, unverified installers from an earlier run.
  echo stale >"$T/kit/setup/looking-glass-idd-setup.exe"
  echo stale >"$T/kit/setup/spice-vdagent-x64-0.10.0.msi"
  PATH=$T/shims:$PATH run "$KIT/proof-vm" media "$T/kit"
  assert_failure
  assert_output --partial "SHA-256 mismatch"
  assert [ ! -e "$T/kit/setup/looking-glass-idd-setup.exe" ]
  assert [ ! -e "$T/kit/setup/spice-vdagent-x64-0.10.0.msi" ]
  run find "$T/kit" -type f
  assert_output ""
}

# Put shims first on PATH that let media's pinned files pass without a
# download: sha256sum prints each file's pin (found by its name), unzip
# writes a stand-in IDD installer, and curl records that it ran.
pinned_media_shims() {
  cat >"$T/shims/sha256sum" <<'EOF'
#!/usr/bin/env bash
source "$REPO/lib/pins.sh"
f=${!#}
case ${f##*/} in
  looking-glass-*-idd.zip) s=$LG_IDD_SHA ;;
  spice-vdagent-*) s=$VDAGENT_SHA ;;
  winfsp-*) s=$WINFSP_SHA ;;
  qemu-ga-*) s=$QEMU_GA_SHA ;;
  virtio-win-*) s=$VIRTIO_WIN_SHA ;;
  *) exit 1 ;;
esac
printf '%s  %s\n' "$s" "$f"
EOF
  cat >"$T/shims/unzip" <<'EOF'
#!/usr/bin/env bash
while (($#)); do
  if [[ $1 == -d ]]; then echo idd >"$2/looking-glass-idd-setup.exe"; fi
  shift
done
EOF
  cat >"$T/shims/curl" <<'EOF'
#!/usr/bin/env bash
touch "$T/curl.called"
exit 1
EOF
  chmod +x "$T/shims/sha256sum" "$T/shims/unzip" "$T/shims/curl"
}

@test "proof-vm media: the setup disk gets lanai-lock.cmd and lanai-scale.ps1 from the checkout" {
  pinned_media_shims
  # shellcheck source-path=SCRIPTDIR source=../lib/pins.sh
  source "$REPO/lib/pins.sh"
  mkdir -p "$T/kit/setup"
  touch "$T/kit/looking-glass-$LG_BUILD-idd.zip" "$T/kit/spice-vdagent-x64-$VDAGENT_VERSION.msi" \
    "$T/kit/setup/winfsp-$WINFSP_VERSION.msi" "$T/kit/setup/qemu-ga-x86_64.msi" \
    "$T/kit/virtio-win-$VIRTIO_WIN_VERSION.iso"
  # An old copy from before the script changed.
  echo old >"$T/kit/setup/lanai-lock.cmd"
  PATH=$T/shims:$PATH run "$KIT/proof-vm" media "$T/kit"
  assert_success
  assert_output --partial "media ready"
  assert [ ! -e "$T/curl.called" ]
  cmp "$REPO/guest/lanai-lock.cmd" "$T/kit/setup/lanai-lock.cmd" || fail "lanai-lock.cmd differs"
  cmp "$REPO/guest/lanai-scale.ps1" "$T/kit/setup/lanai-scale.ps1" || fail "lanai-scale.ps1 differs"
  assert [ -e "$T/kit/setup/looking-glass-idd-setup.exe" ]
}

# --- client: wait for QEMU's reply on qmp.sock, then exec the client ---

# A stand-in client at $T/fake-client (PROOF_CLIENT) that records its
# arguments. With $T/probe-qmp it first asks QMP itself, which on a
# one-client server works only if proof-vm closed its connection.
fake_client() {
  cat >"$T/fake-client" <<'EOF'
#!/usr/bin/env bash
if [[ -e $T/probe-qmp ]]; then
  source "$REPO/lib/lanai.sh"
  if qmp_call "$XDG_RUNTIME_DIR/lanai-proof/qmp.sock" '{"execute":"query-status"}' >/dev/null; then
    echo free >"$T/client.qmp"
  fi
fi
printf '%s\n' "$@" >"$T/client.args"
EOF
  chmod +x "$T/fake-client"
  export PROOF_CLIENT=$T/fake-client
}

@test "proof-vm client: waits for a status reply on qmp.sock, closes it, then execs the client" {
  mkdir -m 700 "$RUN"
  fake_client
  touch "$T/probe-qmp"
  export FAKE_QMP_LOG=$T/qmp.log
  # The first connection gets no status; once query-status has arrived,
  # later connections get a real answer. A connection left open would block
  # every later one, as in QEMU.
  conf FAKE_QMP_MODE=nostatus
  serve_one "$RUN/qmp.sock"
  (
    until grep -q query-status "$T/qmp.log" 2>/dev/null; do sleep 0.05; done
    : >"$FAKE_CONF"
  ) 3>&- &
  BG_PIDS+=("$!")
  PROOF_CLIENT_WAIT=8 run timeout 20 "$KIT/proof-vm" client
  assert_success
  # The handshake: greeting, capabilities, then query-status.
  assert_equal "$(sed -n 1p "$T/qmp.log")" '{"execute":"qmp_capabilities","id":1}'
  assert_equal "$(sed -n 2p "$T/qmp.log")" '{"execute":"query-status","id":2}'
  (($(grep -c query-status "$T/qmp.log") >= 2)) || fail "a reply without a status counted"
  assert_equal "$(cat "$T/client.qmp")" free
  run cat "$T/client.args"
  assert_output -- "-f
$RUN/ivshmem
spice:host=$RUN/spice.sock
spice:port=0
win:setGuestRes=yes"
}

@test "proof-vm client: a stale ivshmem with no QEMU answering does not start the client" {
  mkdir -m 700 "$RUN"
  fake_client
  # Left by an earlier run.
  touch "$RUN/ivshmem"
  local start=$SECONDS
  PROOF_CLIENT_WAIT=2 run timeout 20 "$KIT/proof-vm" client
  assert_failure
  (((SECONDS - start) <= 6)) || fail "took $((SECONDS - start)) s"
  assert_output --partial "QEMU did not answer"
  assert [ ! -e "$T/client.args" ]
}

@test "proof-vm client: retries a refused connect, then starts" {
  mkdir -m 700 "$RUN"
  fake_client
  # A socket file with no listener, as a crashed QEMU leaves it.
  python3 -c 'import socket, sys; socket.socket(socket.AF_UNIX).bind(sys.argv[1])' "$RUN/qmp.sock"
  PROOF_CLIENT_WAIT=15 timeout 20 "$KIT/proof-vm" client >"$T/out" 2>&1 &
  local pid=$!
  BG_PIDS+=("$pid")
  sleep 1.5
  assert [ ! -e "$T/client.args" ]
  rm "$RUN/qmp.sock"
  serve "$RUN/qmp.sock" "$FIX/fake-qmp"
  wait "$pid" || fail "proof-vm client failed: $(cat "$T/out")"
  assert [ -e "$T/client.args" ]
}

@test "proof-vm client: the greeting alone does not count; each try times out and retries" {
  mkdir -m 700 "$RUN"
  fake_client
  export FAKE_QMP_LOG=$T/qmp.log FAKE_QMP_MODE=silent
  serve "$RUN/qmp.sock" "$FIX/fake-qmp"
  PROOF_CLIENT_WAIT=4 run timeout 20 "$KIT/proof-vm" client
  assert_failure
  assert_output --partial "QEMU did not answer"
  (($(grep -c qmp_capabilities "$T/qmp.log") >= 2)) || fail "only one try: $(cat "$T/qmp.log")"
  assert [ ! -e "$T/client.args" ]
}
