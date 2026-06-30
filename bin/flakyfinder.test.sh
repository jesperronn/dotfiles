#!/usr/bin/env bash
# shellcheck shell=bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "$SCRIPT_DIR/lib/bash_test.sh"
source "$SCRIPT_DIR/flakyfinder"

# ── parse_opts ──────────────────────────────────────────────────────────────

test_defaults() {
  FF_RUNS=10; FF_TIMEOUT=30; FF_QUIET=0; FF_SHOW_HELP=0; FF_COMMAND=()
  parse_opts -- echo hello
  assert_eq "10"    "$FF_RUNS"        "default runs"
  assert_eq "30"    "$FF_TIMEOUT"     "default timeout"
  assert_eq "0"     "$FF_QUIET"       "default quiet"
  assert_eq "echo"  "${FF_COMMAND[0]}" "command[0]"
  assert_eq "hello" "${FF_COMMAND[1]}" "command[1]"
}

test_runs_long_flag() {
  FF_RUNS=10; FF_COMMAND=()
  parse_opts --runs 5 -- true
  assert_eq "5" "$FF_RUNS" "--runs sets FF_RUNS"
}

test_runs_short_flag() {
  FF_RUNS=10; FF_COMMAND=()
  parse_opts -N 3 -- true
  assert_eq "3" "$FF_RUNS" "-N sets FF_RUNS"
}

test_timeout_flag() {
  FF_TIMEOUT=30; FF_COMMAND=()
  parse_opts --timeout 15 -- true
  assert_eq "15" "$FF_TIMEOUT" "--timeout sets FF_TIMEOUT"
}

test_quiet_flag() {
  FF_QUIET=0; FF_COMMAND=()
  parse_opts --quiet -- true
  assert_eq "1" "$FF_QUIET" "--quiet sets FF_QUIET"
}

test_help_flag() {
  FF_SHOW_HELP=0; FF_COMMAND=()
  parse_opts --help
  assert_eq "1" "$FF_SHOW_HELP" "--help sets FF_SHOW_HELP"
}

test_invalid_runs() {
  FF_RUNS=10; FF_COMMAND=()
  local rc=0
  parse_opts --runs 0 -- true 2>/dev/null || rc=$?
  assert_status "1" "$rc" "invalid runs returns non-zero"
}

# ── ff_detect_command ────────────────────────────────────────────────────────

test_detect_maven() {
  local tmpdir
  tmpdir=$(mktemp -d)
  touch "$tmpdir/pom.xml"
  local rc=0
  (cd "$tmpdir" && ff_detect_command >/dev/null 2>&1) || rc=$?
  rm -rf "$tmpdir"
  assert_status "0" "$rc" "detect maven exits 0"
}

test_detect_npm() {
  local tmpdir
  tmpdir=$(mktemp -d)
  echo '{}' > "$tmpdir/package.json"
  local rc=0
  (cd "$tmpdir" && ff_detect_command >/dev/null 2>&1) || rc=$?
  rm -rf "$tmpdir"
  assert_status "0" "$rc" "detect npm exits 0"
}

test_detect_none() {
  local tmpdir
  tmpdir=$(mktemp -d)
  local rc=0
  (cd "$tmpdir" && ff_detect_command >/dev/null 2>&1) || rc=$?
  rm -rf "$tmpdir"
  assert_status "1" "$rc" "no pom.xml or package.json returns non-zero"
}

# ── ff_extract_failures ──────────────────────────────────────────────────────

test_extract_maven_failure() {
  local tmpfile
  tmpfile=$(mktemp)
  cat > "$tmpfile" <<'EOF'
[ERROR] com.example.UserServiceTest#testConcurrentLogin  Time elapsed: 0.123 s  <<< FAILURE!
[ERROR] com.example.FooTest#testBar  Time elapsed: 0.05 s  <<< ERROR!
EOF
  local result
  result=$(ff_extract_failures "$tmpfile")
  rm -f "$tmpfile"
  assert_contains "$result" "UserServiceTest#testConcurrentLogin" "extracts first maven test name"
  assert_contains "$result" "FooTest#testBar"                     "extracts second maven test name"
}

test_extract_no_failures() {
  local tmpfile
  tmpfile=$(mktemp)
  printf 'BUILD SUCCESS\n' > "$tmpfile"
  local result
  result=$(ff_extract_failures "$tmpfile")
  rm -f "$tmpfile"
  assert_eq "" "$result" "no failures returns empty"
}

run_tests \
  test_defaults \
  test_runs_long_flag \
  test_runs_short_flag \
  test_timeout_flag \
  test_quiet_flag \
  test_help_flag \
  test_invalid_runs \
  test_detect_maven \
  test_detect_npm \
  test_detect_none \
  test_extract_maven_failure \
  test_extract_no_failures
