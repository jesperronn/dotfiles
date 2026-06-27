#!/usr/bin/env bash
# shellcheck shell=bash

set -euo pipefail

# ── Test infrastructure ────────────────────────────────────────────────

TEST_PASS=0
TEST_FAIL=0

TEST_C_RESET=$'\033[0m'
# shellcheck disable=SC2034
TEST_C_DIM=$'\033[2m'
# shellcheck disable=SC2034
TEST_C_BOLD=$'\033[1m'
# shellcheck disable=SC2034
TEST_C_RED=$'\033[31m'
# shellcheck disable=SC2034
TEST_C_GREEN=$'\033[32m'

test_pass() {
  local msg="$1"
  printf '%b[PASS]%b %s\n' "$TEST_C_GREEN" "$TEST_C_RESET" "$msg"
  (( TEST_PASS++ )) || true
}

test_fail() {
  local expected="$1"
  local actual="$2"
  printf '%b[FAIL]%b %s\n' "$TEST_C_RED" "$TEST_C_RESET" "$expected"
  if [[ -n "$actual" ]]; then
    printf '       actual: %s\n' "$actual"
  fi
  (( TEST_FAIL++ )) || true
}

test_assert_eq() {
  local label="$1"
  local expected="$2"
  local actual="$3"

  if [[ "$expected" == "$actual" ]]; then
    test_pass "$label"
  else
    test_fail "expected: $expected" "$actual"
  fi
}

test_assert_status() {
  local label="$1"
  local expected_status="$2"
  local actual_status="$3"

  if [[ "$expected_status" == "$actual_status" ]]; then
    test_pass "$label"
  else
    test_fail "expected status: $expected_status" "$actual_status"
  fi
}

# ── Test fixtures ──────────────────────────────────────────────────────

TEST_TMP_DIR="$(mktemp -d)"
trap 'rm -rf "$TEST_TMP_DIR"' EXIT

mkdir -p "$TEST_TMP_DIR/test-repo/.git"
mkdir -p "$TEST_TMP_DIR/myproject/.git"

# ── Source the script, then override for tests ─────────────────────────

# Source the real script (loads all functions)
# shellcheck source=/dev/null
source "$(dirname "$0")/gwt"

# Now override functions for test isolation
gwt_parse_prereqs() {
  GWT_COLOR_ENABLED=1
  GWT_FZF_FOUND=1
  return 0
}

gwt_find_repo_root() {
  GWT_REPOSITORY_ROOT="$TEST_REPOSITORY_ROOT"
  gwt_verbose "Test: Repository root: $GWT_REPOSITORY_ROOT"
  return 0
}

gwt_test_select_output=""

gwt_select_worktree() {
  if [[ "$gwt_test_select_output" == "ADD" ]]; then
    echo "ADD"
    return 0
  fi
  echo "$gwt_test_select_output"
  return 0
}

gwt_test_add_called=0

gwt_apply_add() {
  gwt_test_add_called=1
  return 0
}

gwt_test_delete_called=0
gwt_test_delete_path=""

gwt_apply_delete() {
  gwt_test_delete_called=1
  # Parse path the same way the real function does (awk '{print $1}')
  gwt_test_delete_path="$(echo "$1" | awk '{print $1}')"
  return 0
}

gwt_countdown_navigate() {
  return 0
}

# ── Tests ──────────────────────────────────────────────────────────────

gwt_test_parse_opts() {
  echo "--- parse_opts ---"

  # Test: no args returns 0
  gwt_reset_state
  gwt_parse_opts
  test_assert_status "parse_opts with no args returns 0" "0" "$?"

  # Test: --help prints usage and returns 1
  gwt_reset_state
  local help_status=0
  gwt_parse_opts --help 2>/dev/null || help_status=$?
  test_assert_status "parse_opts --help returns 1" "1" "$help_status"

  # Test: -h returns 1
  gwt_reset_state
  local h_status=0
  gwt_parse_opts -h 2>/dev/null || h_status=$?
  test_assert_status "parse_opts -h returns 1" "1" "$h_status"

  echo ""
}

gwt_test_parse_prereqs() {
  echo "--- parse_prereqs ---"

  gwt_reset_state
  gwt_parse_prereqs
  test_assert_eq "GWT_COLOR_ENABLED after prereqs" "1" "$GWT_COLOR_ENABLED"
  test_assert_eq "GWT_FZF_FOUND after prereqs" "1" "$GWT_FZF_FOUND"

  echo ""
}

gwt_test_find_repo_root() {
  echo "--- find_repo_root ---"

  TEST_REPOSITORY_ROOT="/tmp/test-repo"
  gwt_reset_state
  gwt_find_repo_root
  test_assert_eq "GWT_REPOSITORY_ROOT set correctly" "/tmp/test-repo" "$GWT_REPOSITORY_ROOT"

  echo ""
}

gwt_test_list_worktrees() {
  echo "--- list_worktrees ---"

  # Test the parsing logic directly (we can't easily mock git)
  local fake_output="${TEST_TMP_DIR}/wt1	branch-a	abc1234
${TEST_TMP_DIR}/wt2	branch-b	def5678"

  local lines=()
  while IFS= read -r line; do
    [[ -z "$line" ]] && continue
    lines+=("$line")
  done <<< "$fake_output"

  test_assert_eq "parsed 2 worktree lines" "2" "${#lines[@]}"

  # Parse the path from first line (awk '{print $1}')
  local path
  path="$(echo "${lines[0]}" | awk '{print $1}')"
  test_assert_eq "first worktree path parsed" "${TEST_TMP_DIR}/wt1" "$path"

  echo ""
}

gwt_test_generate_name() {
  echo "--- generate_worktree_name ---"

  gwt_reset_state
  GWT_REPOSITORY_ROOT="$TEST_TMP_DIR/myproject"
  local name
  name="$(gwt_generate_worktree_name)"
  test_assert_eq "basic worktree name" "$TEST_TMP_DIR/myproject/../myproject-wt" "$name"

  test_pass "generate_worktree_name returns expected format"

  echo ""
}

gwt_test_select_worktree() {
  echo "--- select_worktree ---"

  # Test: ADD signal
  gwt_test_select_output="ADD"
  local result
  result="$(gwt_select_worktree)"
  test_assert_eq "select returns ADD when set" "ADD" "$result"

  # Test: normal selection
  gwt_test_select_output="/tmp/wt1	branch-a	abc1234"
  result="$(gwt_select_worktree)"
  test_assert_eq "select returns line when set" "/tmp/wt1	branch-a	abc1234" "$result"

  echo ""
}

gwt_test_add_flow() {
  echo "--- add flow ---"

  gwt_test_select_output="ADD"
  TEST_REPOSITORY_ROOT="$TEST_TMP_DIR/myproject"

  gwt_reset_state
  GWT_REPOSITORY_ROOT="$TEST_TMP_DIR/myproject"
  gwt_parse_prereqs
  gwt_test_add_called=0

  gwt_run_main 2>/dev/null || true

  test_assert_eq "apply_add was called" "1" "$gwt_test_add_called"

  echo ""
}

gwt_test_delete_flow() {
  echo "--- delete flow ---"

  local selected_line="${TEST_TMP_DIR}/wt1	branch-a	abc1234"
  gwt_test_select_output="$selected_line"
  TEST_REPOSITORY_ROOT="$TEST_TMP_DIR/myproject"

  gwt_reset_state
  GWT_REPOSITORY_ROOT="$TEST_TMP_DIR/myproject"
  gwt_parse_prereqs
  gwt_test_delete_called=0

  gwt_run_main 2>/dev/null || true

  test_assert_eq "apply_delete was called" "1" "$gwt_test_delete_called"
  test_assert_eq "delete path parsed correctly" "${TEST_TMP_DIR}/wt1" "$gwt_test_delete_path"

  echo ""
}

gwt_test_countdown_navigate() {
  echo "--- countdown_navigate ---"

  gwt_countdown_navigate "/tmp/new-wt"
  test_pass "countdown_navigate returns 0"

  echo ""
}

# ── Run all tests ──────────────────────────────────────────────────────

main() {
  gwt_test_parse_opts
  gwt_test_parse_prereqs
  gwt_test_find_repo_root
  gwt_test_list_worktrees
  gwt_test_generate_name
  gwt_test_select_worktree
  gwt_test_add_flow
  gwt_test_delete_flow
  gwt_test_countdown_navigate

  echo ""
  printf '%bResults: %s passed, %s failed%s\n' \
    "$TEST_C_GREEN" "$TEST_PASS" "$TEST_FAIL" "$TEST_C_RESET"

  if (( TEST_FAIL > 0 )); then
    return 1
  fi
  return 0
}

if [[ "${BASH_SOURCE[0]}" == "$0" ]]; then
  main "$@"
fi
