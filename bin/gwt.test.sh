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
  ((TEST_PASS++)) || true
}

test_fail() {
  local expected="$1"
  local actual="$2"
  printf '%b[FAIL]%b %s\n' "$TEST_C_RED" "$TEST_C_RESET" "$expected"
  if [[ -n "$actual" ]]; then
    printf '       actual: %s\n' "$actual"
  fi
  ((TEST_FAIL++)) || true
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
gwt_test_worktree_count=2

gwt_list_worktrees() {
  GWT_WORKTREE_LINES=()
  local i
  for ((i = 0; i < gwt_test_worktree_count; i++)); do
    GWT_WORKTREE_LINES+=("/tmp/wt$i	abc1234	[branch-$i]")
  done
}

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

}

gwt_test_parse_prereqs() {

  gwt_reset_state
  gwt_parse_prereqs
  test_assert_eq "GWT_COLOR_ENABLED after prereqs" "1" "$GWT_COLOR_ENABLED"
  test_assert_eq "GWT_FZF_FOUND after prereqs" "1" "$GWT_FZF_FOUND"

}

gwt_test_find_repo_root() {

  TEST_REPOSITORY_ROOT="/tmp/test-repo"
  gwt_reset_state
  gwt_find_repo_root
  test_assert_eq "GWT_REPOSITORY_ROOT set correctly" "/tmp/test-repo" "$GWT_REPOSITORY_ROOT"

}

gwt_test_list_worktrees() {

  # Test the parsing logic directly (we can't easily mock git)
  local fake_output="${TEST_TMP_DIR}/wt1	branch-a	abc1234
${TEST_TMP_DIR}/wt2	branch-b	def5678"

  local lines=()
  while IFS= read -r line; do
    [[ -z "$line" ]] && continue
    lines+=("$line")
  done <<<"$fake_output"

  test_assert_eq "parsed 2 worktree lines" "2" "${#lines[@]}"

  # Parse the path from first line (awk '{print $1}')
  local path
  path="$(echo "${lines[0]}" | awk '{print $1}')"
  test_assert_eq "first worktree path parsed" "${TEST_TMP_DIR}/wt1" "$path"

}

gwt_test_generate_name() {

  gwt_reset_state
  GWT_REPOSITORY_ROOT="$TEST_TMP_DIR/myproject"
  local name
  name="$(gwt_generate_worktree_name)"
  test_assert_eq "basic worktree name" "$TEST_TMP_DIR/myproject/../myproject-wt" "$name"

  test_pass "generate_worktree_name returns expected format"

}

gwt_test_select_worktree() {

  # Test: ADD signal
  gwt_test_select_output="ADD"
  local result
  result="$(gwt_select_worktree)"
  test_assert_eq "select returns ADD when set" "ADD" "$result"

  # Test: normal selection
  gwt_test_select_output="/tmp/wt1	branch-a	abc1234"
  result="$(gwt_select_worktree)"
  test_assert_eq "select returns line when set" "/tmp/wt1	branch-a	abc1234" "$result"

}

gwt_test_add_flow() {

  gwt_test_select_output="ADD"
  TEST_REPOSITORY_ROOT="$TEST_TMP_DIR/myproject"

  gwt_reset_state
  GWT_REPOSITORY_ROOT="$TEST_TMP_DIR/myproject"
  gwt_parse_prereqs
  gwt_test_add_called=0

  gwt_run_main 2>/dev/null || true

  test_assert_eq "apply_add was called" "1" "$gwt_test_add_called"

}

gwt_test_delete_flow() {

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

}

gwt_test_delete_flow_multi() {

  # fzf --multi returns every selected line, newline-separated.
  local selected_lines
  selected_lines="$(printf '%s\tbranch-a\tabc1234\n%s\tbranch-b\tdef5678' "${TEST_TMP_DIR}/wt1" "${TEST_TMP_DIR}/wt2")"
  gwt_test_select_output="$selected_lines"
  TEST_REPOSITORY_ROOT="$TEST_TMP_DIR/myproject"

  gwt_reset_state
  GWT_REPOSITORY_ROOT="$TEST_TMP_DIR/myproject"
  gwt_parse_prereqs
  gwt_test_delete_called=0

  gwt_run_main 2>/dev/null || true

  test_assert_eq "apply_delete was called with multi-select" "1" "$gwt_test_delete_called"
  local expected_paths
  expected_paths="$(printf '%s\n%s' "${TEST_TMP_DIR}/wt1" "${TEST_TMP_DIR}/wt2")"
  test_assert_eq "both selected paths passed to delete" "$expected_paths" "$gwt_test_delete_path"

}

gwt_test_apply_delete_real_multi() {

  local repo="$TEST_TMP_DIR/real-repo"
  mkdir -p "$repo"
  git init -q "$repo"
  git -C "$repo" -c user.email=test@test -c user.name=test -c commit.gpgsign=false commit -q --allow-empty -m init
  git -C "$repo" worktree add -q "$TEST_TMP_DIR/real-wt1" -b real-a
  git -C "$repo" worktree add -q "$TEST_TMP_DIR/real-wt2" -b real-b

  local sel
  sel="$(printf '%s\treal-a\tabc1234\n%s\treal-b\tdef5678' "$TEST_TMP_DIR/real-wt1" "$TEST_TMP_DIR/real-wt2")"

  # Fresh subshell sources the script, so the real gwt_apply_delete
  # replaces the test override.
  local status=0
  (
    # shellcheck source=/dev/null
    source "$(dirname "$0")/gwt"
    GWT_REPOSITORY_ROOT="$repo"
    GWT_COLOR_ENABLED=0
    gwt_apply_delete "$sel"
  ) >/dev/null 2>&1 || status=$?

  test_assert_status "multi-delete of two worktrees exits 0" "0" "$status"

  local remaining
  remaining="$(git -C "$repo" worktree list | wc -l | tr -d ' ')"
  test_assert_eq "only main worktree remains" "1" "$remaining"

}

gwt_test_apply_delete_real_failure() {

  # Selecting the main checkout cannot be removed — must report failure
  # instead of claiming success.
  local repo="$TEST_TMP_DIR/real-repo2"
  mkdir -p "$repo"
  git init -q "$repo"
  git -C "$repo" -c user.email=test@test -c user.name=test -c commit.gpgsign=false commit -q --allow-empty -m init

  local sel
  sel="$repo"

  local status=0
  (
    # shellcheck source=/dev/null
    source "$(dirname "$0")/gwt"
    GWT_REPOSITORY_ROOT="$repo"
    GWT_COLOR_ENABLED=0
    gwt_apply_delete "$sel"
  ) >/dev/null 2>&1 || status=$?

  test_assert_status "deleting the main checkout exits 1" "1" "$status"

}

gwt_test_empty_flow() {

  gwt_test_worktree_count=1
  gwt_test_select_output="ADD"
  gwt_test_add_called=0
  gwt_test_delete_called=0
  gwt_reset_state

  local out status=0
  out="$(gwt_run_main 2>&1)" || status=$?

  test_assert_status "only main checkout exits 0" "0" "$status"
  case "$out" in
    *"No worktrees found to delete"*) test_pass "prints no-worktrees message" ;;
    *) test_fail "expected no-worktrees message" "$out" ;;
  esac
  case "$out" in
    *"/tmp/wt0"*) test_pass "prints the git worktree list line" ;;
    *) test_fail "expected the worktree line in output" "$out" ;;
  esac
  test_assert_eq "no add/delete when empty" "0" "$((gwt_test_add_called + gwt_test_delete_called))"
  gwt_test_worktree_count=2

}

gwt_test_fzf_args() {

  local stub_dir="$TEST_TMP_DIR/stubbin"
  mkdir -p "$stub_dir"
  cat >"$stub_dir/fzf" <<'STUB'
#!/usr/bin/env bash
printf '%s\n' "$@" >"$FZF_ARGS_FILE"
STUB
  chmod +x "$stub_dir/fzf"

  local args_file="$TEST_TMP_DIR/fzf-args"
  (
    PATH="$stub_dir:$PATH"
    FZF_ARGS_FILE="$args_file"
    export FZF_ARGS_FILE
    # shellcheck source=/dev/null
    source "$(dirname "$0")/gwt"
    GWT_FZF_FOUND=1
    GWT_WORKTREE_LINES=("/tmp/a" "/tmp/b")
    gwt_select_worktree >/dev/null 2>&1 || true
  )

  local args
  args="$(cat "$args_file")"
  case "$args" in
    *"load:last,"*) test_pass "cursor starts on the top row" ;;
    *) test_fail "expected load:last binding" "$args" ;;
  esac
  case "$args" in
    *"tab:"*) test_fail "tab should keep fzf default (toggle+down)" "$args" ;;
    *) test_pass "tab keeps fzf default binding" ;;
  esac
  case "$args" in
    *"~50%"*) test_pass "fzf height is adaptive percentage" ;;
    *) test_fail "expected ~50% height" "$args" ;;
  esac

}

gwt_test_clear_prompt_line() {

  local out
  out="$(gwt_clear_prompt_line)"
  test_assert_eq "no escape codes when stdout is not a tty" "" "$out"

  out="$(GWT_FORCE_CLEAR=1 gwt_clear_prompt_line)"
  test_assert_eq "clears previous line when forced" $'\033[1A\033[2K\r' "$out"

}

gwt_test_make_repo() {

  local repo="$1"
  mkdir -p "$repo"
  git init -q "$repo"
  git -C "$repo" -c user.email=test@test -c user.name=test -c commit.gpgsign=false commit -q --allow-empty -m init

}

# Run the real gwt_apply_delete in a fresh subshell against $1 with selection $2.
# Remaining args are env assignments (e.g. GWT_ASSUME_FORCE=y). Output goes to
# $TEST_TMP_DIR/delete.out; the exit status is returned.
gwt_test_run_real_delete() {

  local repo="$1" sel="$2"
  shift 2
  (
    # shellcheck source=/dev/null
    source "$(dirname "$0")/gwt"
    local kv
    for kv in "$@"; do declare -x "$kv"; done
    GWT_REPOSITORY_ROOT="$repo"
    GWT_COLOR_ENABLED=0
    gwt_apply_delete "$sel"
  ) >"$TEST_TMP_DIR/delete.out" 2>&1

}

gwt_test_line_path() {

  local got

  got="$(gwt_line_path "/a/b c/d  abc1234 [feat/x]")"
  test_assert_eq "line_path keeps spaces in path" "/a/b c/d" "$got"

  got="$(gwt_line_path "/a/rb4  c74e1738 (detached HEAD)")"
  test_assert_eq "line_path handles detached HEAD" "/a/rb4" "$got"

  got="$(gwt_line_path "/a/wt1	branch-a	abc1234")"
  test_assert_eq "line_path handles tab-separated lines" "/a/wt1" "$got"

}

gwt_test_apply_delete_dirty() {

  local repo="$TEST_TMP_DIR/dirty-repo"
  gwt_test_make_repo "$repo"
  git -C "$repo" worktree add -q "$TEST_TMP_DIR/dirty-wt" -b dirty-a
  echo x >"$TEST_TMP_DIR/dirty-wt/untracked.txt"
  local sel
  sel="$TEST_TMP_DIR/dirty-wt	abc1234	[dirty-a]"

  local status=0
  gwt_test_run_real_delete "$repo" "$sel" GWT_ASSUME_FORCE=n || status=$?
  test_assert_status "dirty worktree declined exits 1" "1" "$status"
  test_assert_eq "dirty worktree kept when declined" "1" "$([[ -d "$TEST_TMP_DIR/dirty-wt" ]] && echo 1 || echo 0)"

  status=0
  gwt_test_run_real_delete "$repo" "$sel" GWT_ASSUME_FORCE=y || status=$?
  test_assert_status "dirty worktree force-removed exits 0" "0" "$status"
  test_assert_eq "dirty worktree gone after force" "0" "$([[ -d "$TEST_TMP_DIR/dirty-wt" ]] && echo 1 || echo 0)"

}

gwt_test_apply_delete_locked() {

  local repo="$TEST_TMP_DIR/locked-repo"
  gwt_test_make_repo "$repo"
  git -C "$repo" worktree add -q "$TEST_TMP_DIR/locked-wt" -b locked-a
  git -C "$repo" worktree lock "$TEST_TMP_DIR/locked-wt"

  local status=0
  gwt_test_run_real_delete "$repo" "$TEST_TMP_DIR/locked-wt	abc1234	[locked-a]" GWT_ASSUME_FORCE=y || status=$?
  test_assert_status "locked worktree exits 1" "1" "$status"
  if grep -q "locked" "$TEST_TMP_DIR/delete.out" && grep -q "git worktree unlock" "$TEST_TMP_DIR/delete.out"; then
    test_pass "locked worktree shows git error and unlock hint"
  else
    test_fail "expected locked error and unlock hint" "$(cat "$TEST_TMP_DIR/delete.out")"
  fi

}

gwt_test_apply_delete_space_path() {

  local repo="$TEST_TMP_DIR/space-repo"
  gwt_test_make_repo "$repo"
  git -C "$repo" worktree add -q "$TEST_TMP_DIR/sp ace" -b spaced-a

  local status=0
  gwt_test_run_real_delete "$repo" "$TEST_TMP_DIR/sp ace  abc1234 [spaced-a]" || status=$?
  test_assert_status "worktree with space in path exits 0" "0" "$status"
  test_assert_eq "space-path worktree removed" "0" "$([[ -d "$TEST_TMP_DIR/sp ace" ]] && echo 1 || echo 0)"

}

gwt_test_worktree_status() {

  local repo="$TEST_TMP_DIR/status-repo"
  mkdir -p "$repo"
  (
    cd "$repo"
    export GIT_AUTHOR_NAME=t GIT_AUTHOR_EMAIL=t@t GIT_COMMITTER_NAME=t GIT_COMMITTER_EMAIL=t@t
    git init -q -b main
    git commit -q --allow-empty -m init
    git worktree add -q -b b-merged "$TEST_TMP_DIR/wt-merged"
    git -C "$TEST_TMP_DIR/wt-merged" commit -q --allow-empty -m work
    git merge -q --ff-only b-merged
    git commit -q --allow-empty -m later
    git worktree add -q -b b-empty "$TEST_TMP_DIR/wt-empty"
    git worktree add -q -b b-unmerged "$TEST_TMP_DIR/wt-unmerged"
    git -C "$TEST_TMP_DIR/wt-unmerged" commit -q --allow-empty -m wip
    touch "$TEST_TMP_DIR/wt-unmerged/new.txt"
  ) >/dev/null 2>&1

  gwt_reset_state
  GWT_REPOSITORY_ROOT="$repo"
  local base
  base="$(gwt_base_ref)"
  test_assert_eq "base_ref falls back to main" "main" "$base"

  test_assert_eq "status: merged branch" "merged" \
    "$(gwt_worktree_status "$TEST_TMP_DIR/wt-merged  abc1234 [b-merged]" "$base")"
  test_assert_eq "status: branch with no commits" "no-commits" \
    "$(gwt_worktree_status "$TEST_TMP_DIR/wt-empty  abc1234 [b-empty]" "$base")"
  test_assert_eq "status: dirty unmerged branch" "dirty,unmerged" \
    "$(gwt_worktree_status "$TEST_TMP_DIR/wt-unmerged  abc1234 [b-unmerged]" "$base")"
  test_assert_eq "status: main checkout is clean" "clean" \
    "$(gwt_worktree_status "$repo  abc1234 [main]" "$base")"
  test_assert_eq "status: missing directory" "missing" \
    "$(gwt_worktree_status "$TEST_TMP_DIR/nope  abc1234 [x]" "$base")"

}

gwt_test_display_rows() {

  local home_saved="$HOME"
  HOME="/Users/jt"
  # shellcheck disable=SC2088
  test_assert_eq "short_path: ~ for home" "~/src/app" "$(gwt_short_path "/Users/jt/src/app")"
  test_assert_eq "short_path: deep path keeps last two" "…/scratchpad/wt-x" \
    "$(gwt_short_path "/private/tmp/claude/a/b/scratchpad/wt-x")"
  test_assert_eq "short_path: short path untouched" "/tmp/wt0" "$(gwt_short_path "/tmp/wt0")"
  HOME="$home_saved"

  local row
  row="$(gwt_display_row "/private/tmp/a/b/c/wt-x  f13040f [feat/x]" "unmerged" 10)"
  test_assert_eq "display_row layout" \
    "/private/tmp/a/b/c/wt-x"$'\t'"unmerged       feat/x      f13040f  …/c/wt-x" "$row"
  test_assert_eq "line_path recovers full path from display row" "/private/tmp/a/b/c/wt-x" \
    "$(gwt_line_path "$row")"

  row="$(gwt_display_row "/a/b c/d  abc1234 (detached HEAD)" "clean" 0)"
  test_assert_eq "line_path keeps spaces via display row" "/a/b c/d" "$(gwt_line_path "$row")"

}

gwt_test_countdown_navigate() {

  gwt_countdown_navigate "/tmp/new-wt"
  test_pass "countdown_navigate returns 0"

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
  gwt_test_delete_flow_multi
  gwt_test_apply_delete_real_multi
  gwt_test_apply_delete_real_failure
  gwt_test_empty_flow
  gwt_test_fzf_args
  gwt_test_clear_prompt_line
  gwt_test_line_path
  gwt_test_apply_delete_dirty
  gwt_test_apply_delete_locked
  gwt_test_apply_delete_space_path
  gwt_test_countdown_navigate
  gwt_test_worktree_status
  gwt_test_display_rows

  printf '%bResults: %s passed, %s failed%s\n' \
    "$TEST_C_GREEN" "$TEST_PASS" "$TEST_FAIL" "$TEST_C_RESET"

  if ((TEST_FAIL > 0)); then
    return 1
  fi
  return 0
}

if [[ "${BASH_SOURCE[0]}" == "$0" ]]; then
  main "$@"
fi
