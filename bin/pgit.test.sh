#!/usr/bin/env bash
# shellcheck disable=SC1091

set -euo pipefail

DOTFILES_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
PGIT_BIN="$DOTFILES_ROOT/bin/pgit"

source "$PGIT_BIN" source

TEST_TMP_DIR=""
TESTS_RUN=0

TEST_C_RESET=$'\033[0m'
TEST_C_GREEN=$'\033[32m'
TEST_C_RED=$'\033[31m'

test_color_print() {
  local color="$1"
  shift
  printf '%b%s%b\n' "$color" "$*" "$TEST_C_RESET"
}

test_pass() {
  TESTS_RUN=$((TESTS_RUN + 1))
  test_color_print "$TEST_C_GREEN" "[PASS] $*"
}

test_fail() {
  test_color_print "$TEST_C_RED" "[FAIL] $1" >&2
  shift || true
  if [[ $# -gt 0 ]]; then
    printf '%s\n' "$@" >&2
  fi
  exit 1
}

assert_eq() {
  local expected="$1"
  local actual="$2"
  local label="$3"

  if [[ "$expected" != "$actual" ]]; then
    test_fail "$label" "Expected: [$expected]" "Actual:   [$actual]"
  fi
}

assert_contains() {
  local haystack="$1"
  local needle="$2"
  local label="$3"

  if [[ "$haystack" != *"$needle"* ]]; then
    test_fail "$label" "Expected substring: [$needle]" "Actual output:      [$haystack]"
  fi
}

assert_not_contains() {
  local haystack="$1"
  local needle="$2"
  local label="$3"

  if [[ "$haystack" == *"$needle"* ]]; then
    test_fail "$label" "Unexpected substring: [$needle]" "Actual output:       [$haystack]"
  fi
}

assert_status() {
  local expected="$1"
  local actual="$2"
  local label="$3"

  if [[ "$expected" != "$actual" ]]; then
    test_fail "$label" "Expected status: [$expected]" "Actual status:   [$actual]"
  fi
}

capture_command() {
  local output_var="$1"
  local status_var="$2"
  shift 2

  local output_file=""
  local captured_output=""
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

reset_state() {
  pgit_reset_state
}

test_parse_opts() {
  local output=""
  local status=0

  reset_state
  capture_command output status parse_opts
  assert_status "1" "$status" "parse_opts should fail without arguments"
  assert_contains "$output" "Usage:" "parse_opts should print usage without arguments"
  test_pass "parse_opts: rejects missing arguments"

  reset_state
  capture_command output status run_main --help
  assert_status "0" "$status" "run_main --help should succeed"
  assert_contains "$output" "Run one git command across multiple repositories." "help should print overview"
  assert_contains "$output" "-h, --help" "help should list supported flags"
  test_pass "parse_opts: help mode prints usage and exits cleanly"
}

test_plan_inputs() {
  reset_state
  pgit_plan_inputs repo-a repo-b -- status -sb
  assert_eq "repo-a repo-b" "${PGIT_DIRS[*]}" "explicit directories should be preserved"
  assert_eq "status -sb" "${PGIT_GIT_ARGS[*]}" "git args after separator should be preserved"
  test_pass "plan_inputs: separator mode keeps dirs and git args distinct"

  reset_state
  pgit_plan_inputs fetch --all
  if [[ ${#PGIT_DIRS[@]} -eq 0 ]]; then
    test_fail "default directory scan should populate immediate subdirectories"
  fi
  assert_eq "fetch --all" "${PGIT_GIT_ARGS[*]}" "git args should be preserved without separator"
  test_pass "plan_inputs: default mode scans immediate subdirectories"
}

test_repo_detection_and_collection() {
  local repo_dir="$TEST_TMP_DIR/repo-a"
  local bare_dir="$TEST_TMP_DIR/repo-b.git"
  local plain_dir="$TEST_TMP_DIR/plain"

  make_git_repo "$repo_dir"
  make_bare_repo "$bare_dir"
  mkdir -p "$plain_dir"

  if ! is_git_repo_dir "$repo_dir"; then
    test_fail "work tree repo should be detected as git repo"
  fi

  if ! is_git_repo_dir "$bare_dir"; then
    test_fail "bare repo should be detected as git repo"
  fi

  if is_git_repo_dir "$plain_dir"; then
    test_fail "plain directory should not be detected as git repo"
  fi

  reset_state
  PGIT_DIRS=("$repo_dir/" "$bare_dir/" "$plain_dir/")
  pgit_plan_repo_dirs
  assert_eq "$repo_dir $bare_dir" "${PGIT_REPO_DIRS[*]}" "plan_repo_dirs should keep only git repositories"
  test_pass "repo_detection: repo discovery filters non-repositories"
}

test_formatting_helpers() {
  local output=""
  local status=0

  reset_state
  PGIT_COLOR_ENABLED=0
  assert_eq "demo" "$(pgit_format_heading "demo")" "plain heading should not include color codes"
  assert_eq "demo" "$(pgit_color_print "$PGIT_C_GREEN" "demo")" "plain color print should not include color codes"
  test_pass "formatting: plain helpers stay readable without color"

  reset_state
  capture_command output status pgit_report_no_repos
  assert_status "0" "$status" "report_no_repos should print without failing"
  assert_contains "$output" "No git repositories found" "report_no_repos should explain the failure"
  test_pass "formatting: failure reporting includes actionable message"
}

test_help_palette() {
  local output=""
  local status=0

  reset_state
  PGIT_COLOR_ENABLED=1
  capture_command output status pgit_usage
  assert_status "0" "$status" "pgit_usage should render when color is enabled"
  assert_contains "$output" "${PGIT_C_BOLD}${PGIT_C_SECTION}Usage:${PGIT_C_RESET}" "help should color section headings with the warm heading style"
  assert_contains "$output" "${PGIT_C_BOLD}${PGIT_C_ACCENT}pgit${PGIT_C_RESET}" "help should color the tool name with the pgit accent"
  assert_contains "$output" "${PGIT_C_PLACEHOLDER}[dirs --]${PGIT_C_RESET}" "help should color placeholders separately"
  assert_contains "$output" "${PGIT_C_GREEN}<git-command>${PGIT_C_RESET}" "help should color command slots in green"
  assert_contains "$output" "${PGIT_C_GREEN}-h, --help${PGIT_C_RESET}" "help should color option names in green"
  test_pass "formatting: help palette uses semantic token colors"
}

test_worker_records_output_and_failures() {
  local repo_dir="$TEST_TMP_DIR/repo-worker"
  local result_file="$TEST_TMP_DIR/worker-result.txt"
  local output=""
  local status=0

  make_git_repo "$repo_dir" 1

  reset_state
  capture_command output status pgit_worker "$repo_dir" "$result_file" rev-parse --is-inside-work-tree
  assert_status "0" "$status" "worker should succeed for valid git command"
  assert_contains "$output" "$repo_dir" "worker should print repo header when command has output"
  assert_contains "$output" "true" "worker should include command output"
  assert_eq $'0\n1\n'"$repo_dir" "$(cat "$result_file")" "worker should record success result"
  test_pass "worker: records successful output"

  capture_command output status pgit_worker "$repo_dir" "$result_file" show does-not-exist
  assert_status "128" "$status" "worker should return failing git exit code"
  assert_contains "$output" "fatal:" "worker should surface git failure output"
  assert_eq $'128\n1\n'"$repo_dir" "$(cat "$result_file")" "worker should record failure result"
  test_pass "worker: records failures and exit codes"
}

test_collect_parallel_results() {
  local first_result="$TEST_TMP_DIR/result-1.txt"
  local second_result="$TEST_TMP_DIR/result-2.txt"

  printf '0\n0\nrepo-a\n' > "$first_result"
  printf '128\n1\nrepo-b\n' > "$second_result"

  reset_state
  pgit_collect_parallel_results "$first_result" "$second_result"
  assert_eq "repo-a" "${PGIT_NO_OUTPUT_DIRS[*]}" "silent repos should be tracked"
  assert_eq $'repo-b\t128' "${PGIT_FAILED_REPOS[*]}" "failed repos should be tracked"
  test_pass "parallel_results: separates silent and failed repos"
}

test_run_main_no_repos() {
  local work_dir="$TEST_TMP_DIR/no-repos"
  local output=""
  local status=0

  mkdir -p "$work_dir/plain"

  capture_command output status bash -lc "cd \"$work_dir\" && \"$PGIT_BIN\" status -sb"
  assert_status "1" "$status" "run_main should fail when no repositories are found"
  assert_contains "$output" "No git repositories found" "run_main should report when no repos are found"
  test_pass "run_main: reports empty selections"
}

test_run_main_default_directory_scan() {
  local work_dir="$TEST_TMP_DIR/default-scan"
  local output=""
  local status=0

  mkdir -p "$work_dir"
  make_git_repo "$work_dir/repo-a" 1
  mkdir -p "$work_dir/plain"

  capture_command output status bash -lc "cd \"$work_dir\" && \"$PGIT_BIN\" rev-parse --is-inside-work-tree"
  assert_status "0" "$status" "pgit should succeed when scanning default subdirectories"
  assert_contains "$output" "repo-a" "pgit should include matching git repo output"
  assert_not_contains "$output" "plain" "pgit should ignore non-repo directories"
  test_pass "run_main: default scan ignores non-repositories"
}

test_run_main_continues_and_summarizes_failures() {
  local work_dir="$TEST_TMP_DIR/continue-on-error"
  local output=""
  local status=0

  mkdir -p "$work_dir"
  make_git_repo "$work_dir/repo-good" 1
  make_git_repo "$work_dir/repo-bad" 0

  capture_command output status bash -lc "cd \"$work_dir\" && \"$PGIT_BIN\" repo-good repo-bad -- show HEAD --stat --oneline"
  assert_status "128" "$status" "pgit should return the first failing repo exit code"
  assert_contains "$output" "repo-good" "pgit should still run successful repositories"
  assert_contains "$output" "repo-bad" "pgit should print failing repository output"
  assert_contains "$output" "errors" "pgit should print a final error summary"
  assert_contains "$output" "repo-bad (exit 128)" "pgit should list failed repositories in the summary"
  test_pass "run_main: continues and summarizes failures"
}

test_run_main_reports_no_output() {
  local work_dir="$TEST_TMP_DIR/no-output"
  local output=""
  local status=0

  mkdir -p "$work_dir"
  make_git_repo "$work_dir/repo-silent" 1

  capture_command output status bash -lc "cd \"$work_dir\" && \"$PGIT_BIN\" repo-silent -- status --porcelain"
  assert_status "0" "$status" "pgit should succeed when repos are silent"
  assert_contains "$output" "no output from" "pgit should report repos with no output"
  assert_contains "$output" "repo-silent" "pgit should list silent repositories"
  test_pass "run_main: reports repositories with no output"
}

main() {
  setup_tmpdir
  test_parse_opts
  test_plan_inputs
  test_repo_detection_and_collection
  test_formatting_helpers
  test_help_palette
  test_worker_records_output_and_failures
  test_collect_parallel_results
  test_run_main_no_repos
  test_run_main_default_directory_scan
  test_run_main_continues_and_summarizes_failures
  test_run_main_reports_no_output
  printf 'PASS: %s checks\n' "$TESTS_RUN"
}

main "$@"
