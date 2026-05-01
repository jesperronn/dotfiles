#!/usr/bin/env bash
# shellcheck disable=SC1090,SC1091

set -euo pipefail

DOTFILES_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
LOOPER_BIN="$DOTFILES_ROOT/bin/looper"
RETURNER_BIN="$DOTFILES_ROOT/bin/returner"

source "$DOTFILES_ROOT/bin/lib/bash_test.sh"
source "$LOOPER_BIN" source

reset_state() {
  looper_reset_state
}

test_format_command_preserves_shell_quoting() {
  reset_state
  assert_eq "printf %q two\\ words" "$(looper_format_command printf %q "two words")" "format_command shell-escapes arguments"
}

test_iteration_output_uses_green_success_prefix_when_colored() {
  local output=""
  local status=0

  reset_state
  LOOPER_COLOR_ENABLED=1
  LOOPER_COUNT=5
  LOOPER_COMMAND=(sleep 2)

  capture_command output status looper_print_iteration 1
  assert_status "0" "$status" "print_iteration succeeds"
  assert_contains "$output" "${LOOPER_C_GREEN}OK looper done run 1/5:${LOOPER_C_RESET} sleep 2" "print_iteration colors the success prefix"
}

test_help_output_lists_count_flag() {
  local output=""
  local status=0

  reset_state
  # shellcheck disable=SC2034
  LOOPER_COLOR_ENABLED=1
  capture_command output status looper_usage
  assert_status "0" "$status" "looper_usage renders help"
  assert_contains "$output" "${LOOPER_C_BOLD}${LOOPER_C_SECTION}Usage:${LOOPER_C_RESET}" "help colors section headings"
  assert_contains "$output" "${LOOPER_C_BOLD}${LOOPER_C_ACCENT}bin/looper${LOOPER_C_RESET}" "help colors tool name"
  assert_contains "$output" "-n | --count" "help groups count flag names"
  assert_contains "$output" "Defaults to infinite" "help documents infinite default"
}

test_parse_opts_rejects_invalid_inputs() {
  local output=""
  local status=0

  reset_state
  capture_command output status parse_opts
  assert_status "99" "$status" "parse_opts rejects missing command"
  assert_contains "$output" "Usage:" "parse_opts shows usage for missing command"

  reset_state
  capture_command output status parse_opts -n=0 printf hello
  assert_status "99" "$status" "parse_opts rejects non-positive count"
  assert_contains "$output" "positive integer" "parse_opts explains count validation"

  reset_state
  capture_command output status parse_opts -n
  assert_status "99" "$status" "parse_opts rejects -n without a value"
  assert_contains "$output" "Option -n requires a count." "parse_opts explains missing short count value"

  reset_state
  capture_command output status parse_opts --count
  assert_status "99" "$status" "parse_opts rejects --count without a value"
  assert_contains "$output" "Option --count requires a count." "parse_opts explains missing long count value"
}

test_parse_opts_sets_count_and_command() {
  reset_state
  parse_opts --count=3 printf hello
  assert_eq "3" "$LOOPER_COUNT" "parse_opts captures count"
  assert_eq "printf hello" "${LOOPER_COMMAND[*]}" "parse_opts captures command tokens"

  reset_state
  parse_opts -n 4 printf hello
  assert_eq "4" "$LOOPER_COUNT" "parse_opts captures short count without equals"

  reset_state
  parse_opts --count 5 printf hello
  assert_eq "5" "$LOOPER_COUNT" "parse_opts captures long count without equals"
}

test_run_main_defaults_to_infinite_loop_until_failure() {
  local output=""
  local status=0

  capture_command output status "$LOOPER_BIN" "$RETURNER_BIN" 9
  assert_status "9" "$status" "looper defaults to looping until a failure occurs"
  assert_contains "$output" "FATAL run 1: $RETURNER_BIN 9" "looper omits a max count in infinite mode"
}

test_run_main_honors_requested_count() {
  local output=""
  local status=0

  capture_command output status "$LOOPER_BIN" --count=3 "$RETURNER_BIN" 0 --message=ok
  assert_status "0" "$status" "looper succeeds when all iterations succeed"
  assert_contains "$output" "OK looper done run 1/3:" "looper prints the first iteration"
  assert_contains "$output" "OK looper done run 2/3:" "looper prints the second iteration"
  assert_contains "$output" "OK looper done run 3/3:" "looper prints the third iteration"
}

test_run_main_stops_on_first_failure_and_propagates_status() {
  local output=""
  local status=0

  capture_command output status "$LOOPER_BIN" --count=5 "$RETURNER_BIN" 7 --message=fail
  assert_status "7" "$status" "looper returns the failing command status"
  assert_contains "$output" "FATAL run 1/5:" "looper labels the failing iteration"
  assert_not_contains "$output" "OK looper done run 2/5:" "looper stops after the first failure"
  assert_contains "$output" "fail" "looper preserves command output"
}

test_run_main_stops_on_interrupt() {
  local output=""
  local status=0

  capture_command output status bash -lc "source \"$LOOPER_BIN\" source; test_interrupt_command() { kill -INT \"\$\$\"; return 0; }; LOOPER_COMMAND=(test_interrupt_command); looper_run_iterations"

  assert_eq "130" "$status" "looper exits 130 after SIGINT"
  assert_contains "$output" "INTERRUPTED run 1:" "looper labels interrupted iteration"
}

run_tests "$@"
