#!/usr/bin/env bash
# shellcheck disable=SC1091

set -euo pipefail

DOTFILES_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
PGIT_BIN="$DOTFILES_ROOT/bin/pgit"

source "$DOTFILES_ROOT/bin/lib/bash_test.sh"
source "$PGIT_BIN" source

TEST_TMP_DIR=""

make_git_repo() {
  local repo_dir="$1"
  local with_commit="${2:-0}"

  mkdir -p "$repo_dir"
  git init -q "$repo_dir"
  git -C "$repo_dir" config user.name "pgit test"
  git -C "$repo_dir" config user.email "pgit@example.com"

  if [[ "$with_commit" == "1" ]]; then
    printf 'seed\n' >"$repo_dir/file.txt"
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

test_collect_parallel_results() {
  local result_dir="$TEST_TMP_DIR/result-files"
  local repo_ok="$TEST_TMP_DIR/repo-ok"
  local repo_silent="$TEST_TMP_DIR/repo-silent"
  local repo_fail="$TEST_TMP_DIR/repo-fail"

  mkdir -p "$result_dir"
  make_git_repo "$repo_ok" 1
  make_git_repo "$repo_silent" 1
  make_git_repo "$repo_fail" 0

  printf '0\n1\n%s\n' "$repo_ok" >"$result_dir/ok.result"
  printf '0\n0\n%s\n' "$repo_silent" >"$result_dir/silent.result"
  printf '128\n1\n%s\n' "$repo_fail" >"$result_dir/fail.result"

  reset_state
  pgit_collect_parallel_results "$result_dir/ok.result" "$result_dir/silent.result" "$result_dir/fail.result"

  assert_eq "$repo_silent" "${PGIT_NO_OUTPUT_DIRS[*]}" "parallel results keep silent repos"
  assert_eq "$repo_fail	128" "${PGIT_FAILED_REPOS[*]}" "parallel results keep failing repos"
}

test_formatting_helpers() {
  local output=""
  local status=0

  reset_state
  PGIT_COLOR_ENABLED=0
  assert_eq "demo" "$(pgit_format_heading "demo")" "plain heading stays readable"
  assert_eq "demo" "$(pgit_color_print "$PGIT_C_GREEN" "demo")" "plain color print omits color codes"

  reset_state
  capture_command output status pgit_report_no_repos
  assert_status "0" "$status" "report_no_repos prints without failing"
  assert_contains "$output" "No git repositories found" "report_no_repos explains empty selections"
}

test_help_palette() {
  local output=""
  local status=0

  reset_state
  PGIT_COLOR_ENABLED=1
  capture_command output status pgit_usage
  assert_status "0" "$status" "pgit_usage renders when color is enabled"
  assert_contains "$output" "${PGIT_C_BOLD}${PGIT_C_SECTION}Usage:${PGIT_C_RESET}" "help colors section headings"
  assert_contains "$output" "${PGIT_C_BOLD}${PGIT_C_ACCENT}pgit${PGIT_C_RESET}" "help colors the tool name"
  assert_contains "$output" "${PGIT_C_PLACEHOLDER}[dirs --]${PGIT_C_RESET}" "help colors placeholders"
  assert_contains "$output" "${PGIT_C_GREEN}<git-command>${PGIT_C_RESET}" "help colors command slots"
  assert_contains "$output" "${PGIT_C_GREEN}-h, --help${PGIT_C_RESET}" "help colors option names"
}

test_parse_opts() {
  local output=""
  local status=0

  reset_state
  capture_command output status parse_opts
  assert_status "1" "$status" "parse_opts rejects missing arguments"
  assert_contains "$output" "Usage:" "parse_opts prints usage with missing arguments"

  reset_state
  capture_command output status run_main --help
  assert_status "0" "$status" "run_main --help succeeds"
  assert_contains "$output" "Run one git command across multiple repositories." "help prints overview"
  assert_contains "$output" "-h, --help" "help lists supported flags"
}

test_plan_inputs() {
  reset_state
  pgit_plan_inputs repo-a repo-b -- status -sb
  assert_eq "repo-a repo-b" "${PGIT_DIRS[*]}" "separator mode preserves explicit directories"
  assert_eq "status -sb" "${PGIT_GIT_ARGS[*]}" "separator mode preserves git args"

  reset_state
  pgit_plan_inputs fetch --all
  if [[ ${#PGIT_DIRS[@]} -eq 0 ]]; then
    test_fail "default directory scan populates immediate subdirectories"
  fi
  assert_eq "fetch --all" "${PGIT_GIT_ARGS[*]}" "default mode preserves git args"
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
  assert_eq "$repo_dir $bare_dir" "${PGIT_REPO_DIRS[*]}" "plan_repo_dirs filters non-repositories"
}

test_run_main_continues_and_summarizes_failures() {
  local work_dir="$TEST_TMP_DIR/continue-on-error"
  local output=""
  local status=0

  mkdir -p "$work_dir"
  make_git_repo "$work_dir/repo-good" 1
  make_git_repo "$work_dir/repo-bad" 0

  capture_command output status bash -lc "cd \"$work_dir\" && \"$PGIT_BIN\" repo-good repo-bad -- show HEAD --stat --oneline"
  assert_status "128" "$status" "pgit returns the first failing repo exit code"
  assert_contains "$output" "repo-good" "pgit still runs successful repositories"
  assert_contains "$output" "repo-bad" "pgit prints failing repository output"
  assert_contains "$output" "errors" "pgit prints a final error summary"
  assert_contains "$output" "repo-bad (exit 128)" "pgit lists failed repositories in the summary"
}

test_run_main_default_directory_scan() {
  local work_dir="$TEST_TMP_DIR/default-scan"
  local output=""
  local status=0

  mkdir -p "$work_dir"
  make_git_repo "$work_dir/repo-a" 1
  mkdir -p "$work_dir/plain"

  capture_command output status bash -lc "cd \"$work_dir\" && \"$PGIT_BIN\" rev-parse --is-inside-work-tree"
  assert_status "0" "$status" "pgit succeeds when scanning default subdirectories"
  assert_contains "$output" "repo-a" "pgit includes matching git repo output"
  assert_not_contains "$output" "plain" "pgit ignores non-repo directories"
}

test_run_main_no_repos() {
  local work_dir="$TEST_TMP_DIR/no-repos"
  local output=""
  local status=0

  mkdir -p "$work_dir/plain"

  capture_command output status bash -lc "cd \"$work_dir\" && \"$PGIT_BIN\" status -sb"
  assert_status "1" "$status" "run_main fails when no repositories are found"
  assert_contains "$output" "No git repositories found" "run_main reports empty selections"
}

test_run_main_reports_no_output() {
  local work_dir="$TEST_TMP_DIR/no-output"
  local output=""
  local status=0

  mkdir -p "$work_dir"
  make_git_repo "$work_dir/repo-silent" 1

  capture_command output status bash -lc "cd \"$work_dir\" && \"$PGIT_BIN\" repo-silent -- status --porcelain"
  assert_status "0" "$status" "pgit succeeds when repos are silent"
  assert_contains "$output" "no output from" "pgit reports repos with no output"
  assert_contains "$output" "repo-silent" "pgit lists silent repositories"
}

test_worker_records_output_and_failures() {
  local repo_dir="$TEST_TMP_DIR/repo-worker"
  local result_file="$TEST_TMP_DIR/worker-result.txt"
  local output=""
  local status=0

  make_git_repo "$repo_dir" 1

  reset_state
  capture_command output status pgit_worker "$repo_dir" "$result_file" rev-parse --is-inside-work-tree
  assert_status "0" "$status" "worker succeeds for valid git commands"
  assert_contains "$output" "$repo_dir" "worker prints repo header when command has output"
  assert_contains "$output" "true" "worker includes command output"
  assert_eq $'0\n1\n'"$repo_dir" "$(cat "$result_file")" "worker records success result"
}

setup_tmpdir
run_tests "$@"
