#!/usr/bin/env bash
# shellcheck disable=SC1091
set -euo pipefail
ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
source "$ROOT/bin/lib/bash_test.sh"
SCRIPT="$ROOT/bin/eachdir"
TEST_TMP_DIR="$(mktemp -d)"
cleanup_test_tmp() { rm -rf "$TEST_TMP_DIR"; }
trap 'cleanup_test_tmp' EXIT

# Fixture: alpha/ and beta/ (each with a marker file), empty gamma/, plus a plain file.
make_fixture() {
  local root="$1"
  mkdir -p "$root/alpha" "$root/beta" "$root/gamma"
  touch "$root/alpha/marker" "$root/beta/marker" "$root/plain-file"
}

# Run eachdir in $1 with remaining args; sets $out and $status. Never fails the test shell.
run_eachdir() {
  local dir="$1"
  shift
  status=0
  out="$(cd "$dir" && TERM=xterm "$SCRIPT" "$@" 2>&1)" || status=$?
}

test_help_flags() {
  local out="" status=0 flag
  for flag in -h --help; do
    run_eachdir "$TEST_TMP_DIR" "$flag"
    assert_status "0" "$status" "eachdir $flag exits 0"
    assert_contains "$out" "Usage: eachdir [dirs --] commands" "eachdir $flag prints usage"
  done
}

test_no_args_errors() {
  local out="" status=0
  run_eachdir "$TEST_TMP_DIR" ""
  assert_status "1" "$status" "eachdir with no args exits 1"
  assert_contains "$out" "You must specify one or more commands to run." "eachdir with no args explains"
}

test_default_all_subdirs() {
  local root="$TEST_TMP_DIR/default" out="" status=0
  make_fixture "$root"
  run_eachdir "$root" ls
  assert_status "0" "$status" "eachdir default exits 0"
  assert_contains "$out" "alpha" "default mode visits alpha"
  assert_contains "$out" "beta" "default mode visits beta"
  assert_contains "$out" "marker" "default mode shows command output"
  assert_not_contains "$out" "plain-file" "default mode ignores plain files"
  assert_contains "$out" "no output from" "default mode lists dirs with no output"
  assert_contains "$out" "gamma" "empty dir listed as no output"
}

test_explicit_dirs_before_dashes() {
  local root="$TEST_TMP_DIR/explicit" out="" status=0
  make_fixture "$root"
  run_eachdir "$root" alpha plain-file nonexistent -- pwd
  assert_status "0" "$status" "eachdir explicit dirs exits 0"
  assert_contains "$out" "$root/alpha" "explicit dir alpha is visited"
  assert_not_contains "$out" "beta" "unlisted dir beta is skipped"
  assert_not_contains "$out" "plain-file" "non-dir argument is ignored"
  assert_not_contains "$out" "no output from" "no 'no output' section when all dirs print"
}

test_failing_command_in_one_dir() {
  local root="$TEST_TMP_DIR/failing" out="" status=0
  make_fixture "$root"
  run_eachdir "$root" alpha beta -- 'cat only-in-some'
  # stderr from the failing command is captured and shown; exit status stays 0.
  assert_status "0" "$status" "eachdir exits 0 even when the command fails in dirs"
  assert_contains "$out" "only-in-some" "failure message from command is displayed"
  assert_contains "$out" "alpha" "failing dir header shown"

  run_eachdir "$root" alpha gamma -- 'test -f marker && echo has-marker'
  assert_status "0" "$status" "eachdir exits 0 when command fails silently in a dir"
  assert_contains "$out" "has-marker" "dirs where command succeeds print output"
  assert_contains "$out" "no output from" "silent failing dir is listed under no output"
  assert_contains "$out" "gamma" "gamma listed as no output"
}

# Line 83 (`[[ ${#nops[@]} > 0 ]]`) sees an array length: always a non-negative
# integer with no leading zeros, so string and integer comparison against 0
# agree for every possible value (any positive count starts with a digit > "0").
# No string-vs-integer discriminating input exists, so only both branches are pinned.
test_no_output_section_branch() {
  local root="$TEST_TMP_DIR/branch" out="" status=0
  make_fixture "$root"
  run_eachdir "$root" alpha beta -- ls
  assert_not_contains "$out" "no output from" "no section when nops is empty"
  run_eachdir "$root" gamma -- true
  assert_contains "$out" "no output from" "section printed when nops has 1 entry"
}

run_tests "$@"
