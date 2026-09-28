#!/usr/bin/env bats
# Tests for the phase 1 proof kit (docs/plugin/proof-kit/proof-vm), run as a
# command. No VM starts and nothing is downloaded: every case stops before
# QEMU, and curl is a PATH shim.

load helpers

setup() {
  isolate_home
  T=$BATS_TEST_TMPDIR
  KIT=$REPO/docs/plugin/proof-kit
  mkdir -p "$T/shims"
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
