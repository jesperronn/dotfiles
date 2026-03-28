#!/usr/bin/env bash

set -euo pipefail

DOTFILES_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
PGIT_BIN="$DOTFILES_ROOT/bin/pgit"

# shellcheck source=/Users/jesper/.dotfiles/bin/pgit
source "$PGIT_BIN"

TEST_TMP_DIR=""
TESTS_RUN=0

fail() {
  printf 'FAIL: %s\n' "$1" >&2
  exit 1
}

pass() {
  TESTS_RUN=$((TESTS_RUN + 1))
}

assert_eq() {
  local expected="$1"
  local actual="$2"
  local message="$3"

  if [[ "$actual" != "$expected" ]]; then
    printf 'Expected: <%s>\nActual:   <%s>\n' "$expected" "$actual" >&2
    fail "$message"
  fi
}

assert_contains() {
  local haystack="$1"
  local needle="$2"
  local message="$3"

  if [[ "$haystack" != *"$needle"* ]]; then
    printf 'Missing substring: <%s>\nWithin: <%s>\n' "$needle" "$haystack" >&2
    fail "$message"
  fi
}

assert_not_contains() {
  local haystack="$1"
  local needle="$2"
  local message="$3"

  if [[ "$haystack" == *"$needle"* ]]; then
    printf 'Unexpected substring: <%s>\nWithin: <%s>\n' "$needle" "$haystack" >&2
    fail "$message"
  fi
}

capture_command() {
  local output_var="$1"
  local status_var="$2"
  shift 2

  local output_file
  local captured_output
  local captured_status=0

  output_file="$(mktemp)"

  set +e
  "$@" > "$output_file" 2>&1
  captured_status=$?
  set -e

  captured_output="$(cat "$output_file")"
  rm -f "$output_file"

  printf -v "$output_var" '%s' "$captured_output"
  printf -v "$status_var" '%s' "$captured_status"
}

make_git_repo() {
  local repo_dir="$1"
  local with_commit="${2:-0}"

  mkdir -p "$repo_dir"
  git init -q "$repo_dir"
  git -C "$repo_dir" config user.name "pgit test"
  git -C "$repo_dir" config user.email "pgit@example.com"

  if [[ "$with_commit" == "1" ]]; then
    printf 'seed\n' > "$repo_dir/file.txt"
    git -C "$repo_dir" add file.txt
    git -C "$repo_dir" commit -q -m "initial"
  fi
}

make_bare_repo() {
  local repo_dir="$1"
  git init -q --bare "$repo_dir"
}

setup_tmpdir() {
  TEST_TMP_DIR="$(mktemp -d)"
  trap 'rm -rf "$TEST_TMP_DIR"' EXIT
}

test_parse_args() {
  local output=""
  local status=0

  capture_command output status parse_args
  assert_eq "1" "$status" "parse_args should fail without arguments"
  assert_contains "$output" "Usage:" "parse_args without args should print usage"

  capture_command output status parse_args --help
  assert_eq "2" "$status" "parse_args should return 2 for help"
  assert_contains "$output" "pgit" "parse_args help should print help text"

  pass
}

test_collect_inputs() {
  pgit_collect_inputs repo-a repo-b -- status -sb
  assert_eq "repo-a repo-b" "${P_GIT_DIRS[*]}" "collect_inputs should keep explicit directories"
  assert_eq "status -sb" "${P_GIT_GIT_ARGS[*]}" "collect_inputs should keep git args after separator"

  pgit_collect_inputs fetch --all
  if [[ ${#P_GIT_DIRS[@]} -eq 0 ]]; then
    fail "collect_inputs should discover immediate subdirectories"
  fi
  assert_eq "fetch --all" "${P_GIT_GIT_ARGS[*]}" "collect_inputs should treat args as git command without separator"

  pass
}

test_repo_detection_and_collection() {
  local repo_dir="$TEST_TMP_DIR/repo-a"
  local bare_dir="$TEST_TMP_DIR/repo-b.git"
  local plain_dir="$TEST_TMP_DIR/plain"

  make_git_repo "$repo_dir"
  make_bare_repo "$bare_dir"
  mkdir -p "$plain_dir"

  if ! is_git_repo_dir "$repo_dir"; then
    fail "work tree repo should be detected as git repo"
  fi

  if ! is_git_repo_dir "$bare_dir"; then
    fail "bare repo should be detected as git repo"
  fi

  if is_git_repo_dir "$plain_dir"; then
    fail "plain directory should not be detected as git repo"
  fi

  P_GIT_DIRS=("$repo_dir/" "$bare_dir/" "$plain_dir/")
  pgit_collect_repo_dirs
  assert_eq "$repo_dir $bare_dir" "${P_GIT_REPO_DIRS[*]}" "collect_repo_dirs should keep only git repositories"

  pass
}

test_worker_records_output_and_failures() {
  local repo_dir="$TEST_TMP_DIR/repo-worker"
  local result_file="$TEST_TMP_DIR/worker-result.txt"
  local output=""
  local status=0

  make_git_repo "$repo_dir" 1

  P_GIT_H1=""
  P_GIT_H2=""
  capture_command output status pgit_worker "$repo_dir" "$result_file" rev-parse --is-inside-work-tree
  assert_eq "0" "$status" "worker should succeed for valid git command"
  assert_contains "$output" "$repo_dir" "worker should print repo header when command has output"
  assert_contains "$output" "true" "worker should include command output"
  assert_eq $'0\n1\n'"$repo_dir" "$(cat "$result_file")" "worker should record success result"

  capture_command output status pgit_worker "$repo_dir" "$result_file" show does-not-exist
  assert_eq "128" "$status" "worker should return failing git exit code"
  assert_contains "$output" "fatal:" "worker should surface git failure output"
  assert_eq $'128\n1\n'"$repo_dir" "$(cat "$result_file")" "worker should record failure result"

  pass
}

test_collect_parallel_results() {
  local first_result="$TEST_TMP_DIR/result-1.txt"
  local second_result="$TEST_TMP_DIR/result-2.txt"

  printf '0\n0\nrepo-a\n' > "$first_result"
  printf '128\n1\nrepo-b\n' > "$second_result"

  pgit_collect_parallel_results "$first_result" "$second_result"

  assert_eq "repo-a" "${P_GIT_NO_OUTPUT_DIRS[*]}" "collect_parallel_results should track silent repos"
  assert_eq $'repo-b\t128' "${P_GIT_FAILED_REPOS[*]}" "collect_parallel_results should track failed repos"

  pass
}

test_run_main_no_repos() {
  local work_dir="$TEST_TMP_DIR/no-repos"
  local output=""
  local status=0

  mkdir -p "$work_dir/plain"

  capture_command output status bash -lc "cd \"$work_dir\" && \"$PGIT_BIN\" status -sb"
  assert_eq "1" "$status" "run_main should fail when no repositories are found"
  assert_contains "$output" "No git repositories found" "run_main should report when no repos are found"

  pass
}

test_run_main_default_directory_scan() {
  local work_dir="$TEST_TMP_DIR/default-scan"
  local output=""
  local status=0

  mkdir -p "$work_dir"
  make_git_repo "$work_dir/repo-a" 1
  mkdir -p "$work_dir/plain"

  capture_command output status bash -lc "cd \"$work_dir\" && \"$PGIT_BIN\" rev-parse --is-inside-work-tree"
  assert_eq "0" "$status" "pgit should succeed when scanning default subdirectories"
  assert_contains "$output" "repo-a" "pgit should include matching git repo output"
  assert_not_contains "$output" "plain" "pgit should ignore non-repo directories"

  pass
}

test_run_main_continues_and_summarizes_failures() {
  local work_dir="$TEST_TMP_DIR/continue-on-error"
  local output=""
  local status=0

  mkdir -p "$work_dir"
  make_git_repo "$work_dir/repo-good" 1
  make_git_repo "$work_dir/repo-bad" 0

  capture_command output status bash -lc "cd \"$work_dir\" && \"$PGIT_BIN\" repo-good repo-bad -- show HEAD --stat --oneline"
  assert_eq "128" "$status" "pgit should return the first failing repo exit code"
  assert_contains "$output" "repo-good" "pgit should still run successful repositories"
  assert_contains "$output" "repo-bad" "pgit should print failing repository output"
  assert_contains "$output" "errors" "pgit should print a final error summary"
  assert_contains "$output" "repo-bad (exit 128)" "pgit should list failed repositories in the summary"

  pass
}

test_run_main_reports_no_output() {
  local work_dir="$TEST_TMP_DIR/no-output"
  local output=""
  local status=0

  mkdir -p "$work_dir"
  make_git_repo "$work_dir/repo-silent" 1

  capture_command output status bash -lc "cd \"$work_dir\" && \"$PGIT_BIN\" repo-silent -- status --porcelain"
  assert_eq "0" "$status" "pgit should succeed when repos are silent"
  assert_contains "$output" "no output from" "pgit should report repos with no output"
  assert_contains "$output" "repo-silent" "pgit should list silent repositories"

  pass
}

main() {
  setup_tmpdir
  test_parse_args
  test_collect_inputs
  test_repo_detection_and_collection
  test_worker_records_output_and_failures
  test_collect_parallel_results
  test_run_main_no_repos
  test_run_main_default_directory_scan
  test_run_main_continues_and_summarizes_failures
  test_run_main_reports_no_output

  printf 'PASS: %s tests\n' "$TESTS_RUN"
}

main "$@"
