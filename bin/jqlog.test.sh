#!/usr/bin/env bash
# shellcheck disable=SC1090,SC1091

set -euo pipefail

DOTFILES_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
JQLOG_BIN="$DOTFILES_ROOT/bin/jqlog"

source "$DOTFILES_ROOT/bin/lib/bash_test.sh"

cleanup_test_tmp() {
  [[ -z "${TEST_TMP_DIR:-}" ]] && return 0
  rm -rf "$TEST_TMP_DIR"
}
trap 'cleanup_test_tmp' EXIT
TEST_TMP_DIR="$(mktemp -d)"

test_help_flag_prints_usage_and_exits_zero() {
  local output="" status=0

  capture_command output status "$JQLOG_BIN" --help
  assert_status "0" "$status" "jqlog --help exits 0"
  assert_contains "$output" "Usage:" "jqlog --help prints usage"
  assert_contains "$output" "-h, --help" "jqlog --help lists the help flag"
  assert_contains "$output" '."@timeStamp"' "jqlog --help documents the timestamp field"

  capture_command output status "$JQLOG_BIN" -h
  assert_status "0" "$status" "jqlog -h exits 0"
}

test_help_flag_is_not_treated_as_a_file() {
  local output="" status=0

  capture_command output status "$JQLOG_BIN" --help
  assert_not_contains "$output" "No such file or directory" "jqlog --help is not read as a file"
}

test_stdin_input_is_formatted() {
  local output=""

  output="$(printf '%s\n' '{"level":"INFO","sequence":7,"message":"hello world","stackTrace":"","@timeStamp":"2026-11-26T10:00:00Z"}' | "$JQLOG_BIN")"
  assert_contains "$output" "INFO" "jqlog formats the level"
  assert_contains "$output" "7" "jqlog formats the sequence"
  assert_contains "$output" "hello world" "jqlog formats the message"
  assert_contains "$output" "2026-11-26T10:00:00Z" "jqlog formats the timestamp"
}

test_bad_line_aborts_with_nonzero_exit() {
  local output="" status=0

  set +e
  output="$(printf '%s\n' 'not json at all' '{"level":"WARN","sequence":2,"message":"later line","stackTrace":"","@timeStamp":"2026-11-26T10:01:00Z"}' | "$JQLOG_BIN" 2>&1)"
  status=$?
  set -e

  assert_not_status "0" "$status" "jqlog exits non-zero on an unparseable line"
  assert_contains "$output" "parse error" "jqlog reports the jq parse error"
  assert_not_contains "$output" "later line" "jqlog does not format lines after a bad one"
}

run_tests "$@"
