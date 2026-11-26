#!/usr/bin/env bash
# shellcheck disable=SC1090,SC1091

set -euo pipefail

DOTFILES_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
WRAPPER_BIN="$DOTFILES_ROOT/bin/git-gpg-wrapper"

source "$DOTFILES_ROOT/bin/lib/bash_test.sh"

cleanup_test_tmp() {
  [[ -z "${TEST_TMP_DIR:-}" ]] && return 0
  rm -rf "$TEST_TMP_DIR"
}
trap 'cleanup_test_tmp' EXIT
TEST_TMP_DIR="$(mktemp -d)"

make_stub() {
  local name="$1" body="$2"
  printf '#!/bin/sh\n%s\n' "$body" >"$TEST_TMP_DIR/$name"
  chmod +x "$TEST_TMP_DIR/$name"
}

test_help_flag_prints_wrapper_usage_and_exits_zero() {
  local output="" status=0

  capture_command output status "$WRAPPER_BIN" --help
  assert_status "0" "$status" "git-gpg-wrapper --help exits 0"
  assert_contains "$output" "Usage:" "git-gpg-wrapper --help prints usage"
  assert_contains "$output" "custom.gpgkeygrip" "git-gpg-wrapper --help documents configuration"
  assert_not_contains "$output" "gpg (GnuPG)" "git-gpg-wrapper --help does not print gpg's own help"

  capture_command output status "$WRAPPER_BIN" -h
  assert_status "0" "$status" "git-gpg-wrapper -h exits 0"
}

test_non_signing_args_pass_through_to_gpg() {
  make_stub gpg 'echo "gpg-called:$*"'

  local output="" status=0

  set +e
  output="$(PATH="$TEST_TMP_DIR:$PATH" "$WRAPPER_BIN" --version 2>&1)"
  status=$?
  set -e

  assert_status "0" "$status" "git-gpg-wrapper passes non-signing args through to gpg"
  assert_contains "$output" "gpg-called:--version" "git-gpg-wrapper execs gpg with the original args"
}

test_signing_without_keygrip_aborts() {
  local tmpdir="$TEST_TMP_DIR/abort-test"
  local output="" status=0

  mkdir -p "$tmpdir"

  set +e
  output="$(cd "$tmpdir" && PATH="$TEST_TMP_DIR:$PATH" GIT_CONFIG_GLOBAL=/dev/null GIT_CONFIG_SYSTEM=/dev/null "$WRAPPER_BIN" --detach-sign data.txt 2>&1)"
  status=$?
  set -e

  assert_status "1" "$status" "git-gpg-wrapper signing without a keygrip aborts with exit 1"
  assert_contains "$output" "custom.gpgkeygrip is not configured" "git-gpg-wrapper reports the missing keygrip"
}

test_signing_with_cache_hit_execs_gpg_batch() {
  local tmpdir="$TEST_TMP_DIR/cache-hit-test"
  local output="" status=0

  make_stub gpg-connect-agent 'echo "6=1"'
  make_stub gpg 'echo "gpg-called:$*"'

  mkdir -p "$tmpdir"
  (cd "$tmpdir" && git init -q . && git config custom.gpgkeygrip ABC123)

  set +e
  output="$(cd "$tmpdir" && PATH="$TEST_TMP_DIR:$PATH" GIT_CONFIG_GLOBAL=/dev/null GIT_CONFIG_SYSTEM=/dev/null "$WRAPPER_BIN" --clearsign data.txt 2>&1)"
  status=$?
  set -e

  assert_status "0" "$status" "git-gpg-wrapper with a cache hit succeeds"
  assert_contains "$output" "--batch" "git-gpg-wrapper execs gpg with --batch"
  assert_contains "$output" "--no-tty" "git-gpg-wrapper execs gpg with --no-tty"
}

run_tests "$@"
