#!/usr/bin/env bats
# Tests for Lanai's Looking Glass client patches (patches/looking-glass/).
# Everywhere: the patch headers and COPYING, and patch 0001 (new files only)
# applied to an empty folder, its resize module built with cc and every
# resize case run. Locally, when LANAI_TEST_LG_TARBALL names the pinned
# source tarball: every patch applied exactly to the real source, and the
# client tests that cover the change built and run (needs the client's
# build dependencies and GoogleTest).
# shellcheck disable=SC2030,SC2031,SC2034

load helpers

setup() {
  isolate_home
  # shellcheck source-path=SCRIPTDIR source=../lib/lanai.sh
  source "$REPO/lib/lanai.sh"
  T=$BATS_TEST_TMPDIR
  PATCHES=$REPO/patches/looking-glass
}

# The SHA-256 of the GPL-2.0 text in the pinned tree's LICENSE.
COPYING_SHA=8177f97513213526df2cf6184d8ff986c675afb514d4e68a404010521b880643

@test "patches: each header carries its license and no line patch reads as a diff; COPYING is the GPL-2.0 text" {
  local p header
  run patches_list
  assert_output $'0001-client-resize-module.patch\n0002-client-resize-hooks.patch'
  # The header is the text before the first diff line. Its SPDX line comes
  # last, so a header line that patch would read as a diff cuts it off.
  for p in "$PATCHES"/[0-9][0-9][0-9][0-9]-*.patch; do
    header=$(sed -E '/^(diff |--- )/,$d' "$p")
    [[ $header == *"SPDX-License-Identifier: GPL-2.0-or-later"* ]] ||
      fail "${p##*/} has no SPDX line"
    [[ $header == *"Copyright (C) 2026 John Zetterman"* ]] ||
      fail "${p##*/} has no copyright line"
    run grep -E '^(\+\+\+ |\*\*\* |diff |Index:|Prereq:)' <<<"$header"
    assert_failure
  done
  assert_equal "$(sha256sum "$PATCHES/COPYING" | cut -d' ' -f1)" "$COPYING_SHA"
}

@test "patch 0001: applies to an empty folder, and every resize case passes" {
  local c
  local -a cases=()
  mkdir -p "$T/patches" "$T/src"
  cp "$PATCHES/0001-client-resize-module.patch" "$T/patches/"
  LANAI_PATCHES=$T/patches
  run patches_apply "$T/src" "$T/apply.log"
  assert_success
  run grep '^Hunk ' "$T/apply.log"
  assert_failure

  cc -std=gnu11 -Wall -Wextra -Werror -I"$T/src/client/src" \
    "$T/src/client/src/resize.c" "$T/src/client/tests/resize_test.c" \
    -o "$T/resize-tests"
  mapfile -t cases < <("$T/resize-tests" --list)
  ((${#cases[@]} >= 10)) || fail "resize-tests lists ${#cases[@]} cases"
  for c in "${cases[@]}"; do
    run "$T/resize-tests" "$c"
    [[ $status == 0 ]] || fail "resize case $c failed: $output"
  done
  run "$T/resize-tests" no-such-case
  assert_failure
}

@test "the pinned source: every patch applies exactly, and the client tests that cover it pass" {
  [[ -n ${LANAI_TEST_LG_TARBALL:-} ]] || skip "LANAI_TEST_LG_TARBALL is not set"
  local src listed declared
  # verify_sha256 deletes a file that does not match, so check a copy.
  cp -- "$LANAI_TEST_LG_TARBALL" "$T/lg.tar.gz"
  verify_sha256 "$T/lg.tar.gz" "$LG_SOURCE_SHA"
  mkdir "$T/work"
  tar -xzf "$T/lg.tar.gz" -C "$T/work" --no-same-owner
  src=$T/work/looking-glass-$LG_BUILD

  run patches_apply "$src" "$T/apply.log"
  assert_success
  run grep '^Hunk ' "$T/apply.log"
  assert_failure

  cmake -S "$src/client" -B "$T/build" -DENABLE_X11=no -DENABLE_TESTS=ON \
    -DWESTON_EXECUTABLE=/usr/bin/true >"$T/cmake.log" 2>&1 ||
    fail "cmake could not configure: $(tail -20 "$T/cmake.log")"
  cmake --build "$T/build" -j "$(nproc)" \
    --target resize-tests config-message-tests mouse-tests >"$T/build.log" 2>&1 ||
    fail "the tests did not build: $(grep -m5 -E 'error' "$T/build.log")"
  run ctest --test-dir "$T/build" -R '^(resize|config-message|mouse)-' --output-on-failure
  assert_success

  # resize-tests names the same cases that CMake registers.
  listed=$("$T/build/tests/resize-tests" --list | LC_ALL=C sort)
  declared=$(sed -n '/^set(RESIZE_CASES/,/^)/s/^  \([a-z-]*\)$/\1/p' \
    "$src/client/tests/CMakeLists.txt" | LC_ALL=C sort)
  [[ -n $listed ]]
  assert_equal "$listed" "$declared"
}
