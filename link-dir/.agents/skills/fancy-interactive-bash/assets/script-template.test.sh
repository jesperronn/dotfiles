#!/usr/bin/env bash
# shellcheck disable=SC1090,SC1091

set -euo pipefail

TEMPLATE_SCRIPT="$(cd "$(dirname "$0")" && pwd)/script-template.sh"
source "$TEMPLATE_SCRIPT"

T_PASS=$'\033[32m[PASS]\033[0m'
T_FAIL=$'\033[31m[FAIL]\033[0m'

test_pass() {
  printf '%b %s\n' "$T_PASS" "$1"
}

test_fail() {
  local label=$1
  local expected=$2
  local actual=$3

  printf '%b %s\nExpected: [%s]\nActual:   [%s]\n' \
    "$T_FAIL" "$label" "$expected" "$actual" >&2
  exit 1
}

assert_eq() {
  local expected=$1
  local actual=$2
  local label=$3

  if [[ "$expected" != "$actual" ]]; then
    test_fail "$label" "$expected" "$actual"
  fi

  test_pass "$label"
}

assert_status() {
  local expected=$1
  local actual=$2
  local label=$3

  if [[ "$expected" -ne "$actual" ]]; then
    test_fail "$label" "$expected" "$actual"
  fi

  test_pass "$label"
}

template_reset_state() {
  TEMPLATE_VERBOSE=0
  TEMPLATE_COLOR_ENABLED=1
  TEMPLATE_INTERACTIVE=0
  TEMPLATE_TIMINGS=0
}

template_reset_state
template_parse_opts --verbose --timings --interactive
assert_eq "1" "$TEMPLATE_VERBOSE" "verbose flag"
assert_eq "1" "$TEMPLATE_TIMINGS" "timings flag"
assert_eq "1" "$TEMPLATE_INTERACTIVE" "interactive flag"

template_reset_state
template_parse_opts --no-color
assert_eq "0" "$TEMPLATE_COLOR_ENABLED" "no-color flag"

template_reset_state
usage="$(template_usage)"
assert_eq "${C_BOLD}${C_SECTION}Usage:${C_0} ${C_BOLD}${C_ACCENT}template-script${C_0} ${C_PLACEHOLDER}[OPTIONS]${C_0}" \
  "$(printf '%s\n' "$usage" | head -n 1)" \
  "usage uses the Vibe palette for headings, tool name, and placeholders"
assert_eq "${C_GREEN}--help${C_0}" \
  "$(printf '%s\n' "$usage" | sed -n '8p' | awk '{print $1}')" \
  "usage uses green for flags"

template_reset_state
set +e
template_parse_opts --bogus >/dev/null 2>&1
status=$?
set -e
assert_status 2 "$status" "unknown option exits 2"
