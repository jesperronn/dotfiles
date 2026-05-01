#!/usr/bin/env bash
# shellcheck disable=SC1090,SC1091

set -euo pipefail

DOTFILES_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
RETURNER_BIN="$DOTFILES_ROOT/bin/returner"

source "$DOTFILES_ROOT/bin/lib/bash_test.sh"
source "$RETURNER_BIN" source

reset_state() {
  returner_reset_state
}

test_help_output_lists_message_flag() {
  local output=""
  local status=0

  reset_state
  # shellcheck disable=SC2034
  RETURNER_COLOR_ENABLED=1
  capture_command output status returner_usage
  assert_status "0" "$status" "returner_usage renders help"
  assert_contains "$output" "${RETURNER_C_BOLD}${RETURNER_C_SECTION}Usage:${RETURNER_C_RESET}" "help colors section headings"
  assert_contains "$output" "${RETURNER_C_BOLD}${RETURNER_C_ACCENT}bin/returner${RETURNER_C_RESET}" "help colors tool name"
  assert_contains "$output" "--message" "help lists message flag"
}

test_parse_opts_rejects_invalid_exit_code() {
  local output=""
  local status=0

  reset_state
  capture_command output status parse_opts abc
  assert_status "99" "$status" "parse_opts rejects non-numeric exit codes"
  assert_contains "$output" "0..255" "parse_opts explains valid exit code range"

  reset_state
  capture_command output status parse_opts 256
  assert_status "99" "$status" "parse_opts rejects out-of-range exit codes"
  assert_contains "$output" "0..255" "parse_opts rejects out-of-range value with the same guidance"
}

test_parse_opts_sets_state() {
  reset_state
  parse_opts 7 --message=hello
  assert_eq "7" "$RETURNER_EXIT_CODE" "parse_opts captures exit code"
  assert_eq "hello" "$RETURNER_MESSAGE" "parse_opts captures message"
}

test_run_main_prints_message_and_returns_requested_status() {
  local output=""
  local status=0

  capture_command output status "$RETURNER_BIN" 4 --message=done
  assert_status "4" "$status" "returner returns requested exit code"
  assert_eq "done" "$output" "returner prints the requested message"
}

test_run_main_without_message_stays_quiet() {
  local output=""
  local status=0

  capture_command output status "$RETURNER_BIN" 0
  assert_status "0" "$status" "returner succeeds with zero status"
  assert_eq "" "$output" "returner stays quiet without a message"
}

run_tests "$@"
