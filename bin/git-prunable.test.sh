#!/usr/bin/env bash
# shellcheck shell=bash
# Tests for git-prunable. Hermetic: builds throwaway repos, no network, no global git config.

set -euo pipefail

TEST_PASS=0
TEST_FAIL=0
TEST_C_RESET=$'\033[0m'
TEST_C_RED=$'\033[31m'
TEST_C_GREEN=$'\033[32m'

test_pass() {
  printf '%b[PASS]%b %s\n' "$TEST_C_GREEN" "$TEST_C_RESET" "$1"
  ((TEST_PASS++)) || true
}

test_fail() {
  printf '%b[FAIL]%b %s\n' "$TEST_C_RED" "$TEST_C_RESET" "$1"
  [[ -n "${2:-}" ]] && printf '       actual: %s\n' "$2"
  ((TEST_FAIL++)) || true
}

assert_contains() {
  local label="$1" haystack="$2" needle="$3"
  if [[ "$haystack" == *"$needle"* ]]; then test_pass "$label"; else test_fail "$label (missing: $needle)" "$haystack"; fi
}

assert_not_contains() {
  local label="$1" haystack="$2" needle="$3"
  if [[ "$haystack" != *"$needle"* ]]; then test_pass "$label"; else test_fail "$label (unexpected: $needle)" "$haystack"; fi
}

assert_branch_exists() {
  if git -C "$REPO" rev-parse --verify --quiet "refs/heads/$1" > /dev/null; then test_pass "$2"; else test_fail "$2"; fi
}

assert_branch_missing() {
  if ! git -C "$REPO" rev-parse --verify --quiet "refs/heads/$1" > /dev/null; then test_pass "$2"; else test_fail "$2"; fi
}

TEST_TMP_DIR="$(mktemp -d)"
cleanup_test_tmp() {
  rm -rf "$TEST_TMP_DIR"
}
trap 'cleanup_test_tmp' EXIT

SCRIPT="$(cd "$(dirname "$0")" && pwd)/git-prunable"
REPO="$TEST_TMP_DIR/repo"

export GIT_CONFIG_GLOBAL=/dev/null GIT_CONFIG_SYSTEM=/dev/null
export GIT_AUTHOR_NAME=t GIT_AUTHOR_EMAIL=t@t GIT_COMMITTER_NAME=t GIT_COMMITTER_EMAIL=t@t

g() { git -C "$REPO" "$@"; }

commit_file() { # dir file
  echo "$2 $RANDOM" > "$1/$2"
  git -C "$1" add "$2"
  git -C "$1" commit -q -m "add $2"
}

# squash_merged NAME [worktree]: branch with 2 commits, squash-merged to main
squash_merged() {
  local name="$1" wt="${2:-}"
  if [[ -n "$wt" ]]
  then
    g worktree add -q -b "$name" "$wt"
    commit_file "$wt" "$name-1"
    commit_file "$wt" "$name-2"
  else
    g checkout -q -b "$name"
    commit_file "$REPO" "$name-1"
    commit_file "$REPO" "$name-2"
    g checkout -q main
  fi
  g merge -q --squash "$name"
  g commit -q -m "squash $name"
}

build_repo() {
  git init -q -b main "$REPO"
  commit_file "$REPO" base

  # plain merge
  g checkout -q -b merged
  commit_file "$REPO" merged-1
  g checkout -q main
  g merge -q --no-ff merged -m "merge merged"

  # squash merge (SHA differs)
  squash_merged squashed

  # rebase merge via cherry-pick (SHAs differ, patch-ids equal)
  g checkout -q -b rebased
  commit_file "$REPO" rebased-1
  commit_file "$REPO" rebased-2
  g checkout -q main
  g cherry-pick main..rebased > /dev/null

  # never pushed, real unmerged work
  g checkout -q -b unmerged
  commit_file "$REPO" unmerged-1
  g checkout -q main

  # worktree leftovers, all already squash-merged
  squash_merged wt_clean "$TEST_TMP_DIR/wt_clean"
  squash_merged wt_dirty "$TEST_TMP_DIR/wt_dirty"
  echo scratch > "$TEST_TMP_DIR/wt_dirty/untracked.txt"
  squash_merged wt_locked "$TEST_TMP_DIR/wt_locked"
  g worktree lock "$TEST_TMP_DIR/wt_locked"
  squash_merged wt_stale "$TEST_TMP_DIR/wt_stale"
  rm -rf "$TEST_TMP_DIR/wt_stale"

  # detached worktree
  g worktree add -q --detach "$TEST_TMP_DIR/wt_detached"

  # freshly created branch pointing at main (created last so main has not moved past it)
  g branch newbranch
}

run() { (cd "$REPO" && "$SCRIPT" --no-fetch --base main "$@" 2>&1); }

test_dry_run() {
  local out
  out=$(run)
  assert_contains "dry run: plain merge detected" "$out" "WOULD merged  [merged]"
  assert_contains "dry run: squash merge detected" "$out" "WOULD squashed  [content-in-base]"
  assert_contains "dry run: rebase/cherry-pick detected" "$out" "WOULD rebased"
  assert_not_contains "dry run: unmerged branch not listed" "$out" "unmerged"
  assert_contains "dry run: new branch at base skipped" "$out" "SKIP  newbranch"
  assert_contains "dry run: clean worktree branch listed" "$out" "WOULD wt_clean"
  assert_contains "dry run: dirty worktree skipped" "$out" "SKIP  wt_dirty  dirty worktree"
  assert_contains "dry run: locked worktree skipped" "$out" "SKIP  wt_locked  locked worktree"
  assert_contains "dry run: stale worktree metadata pruned, branch listed" "$out" "WOULD wt_stale"
  assert_contains "dry run: detached worktree reported" "$out" "NOTE  detached worktree"
  assert_not_contains "dry run: base branch itself not mentioned" "$out" "WOULD main"
  assert_branch_exists squashed "dry run: nothing deleted"
}

make_fzf_stub() {
  FZF_STUB="$TEST_TMP_DIR/fzf-stub"
  cat > "$FZF_STUB" <<'EOS'
#!/usr/bin/env bash
# fake fzf: print stdin lines whose first field matches $FZF_STUB_PICK
[[ -n "${FZF_STUB_PICK:-}" ]] || exit 1
grep -E "^($FZF_STUB_PICK)"$'\t' || true
EOS
  chmod +x "$FZF_STUB"
}

test_interactive() {
  local out status=0
  (cd "$REPO" && GIT_PRUNABLE_FZF=nonexistent-fzf "$SCRIPT" --no-fetch --base main -i > /dev/null 2>&1) || status=$?
  if [[ $status -ne 0 ]]; then test_pass "interactive without fzf fails"; else test_fail "interactive without fzf fails"; fi
  assert_branch_exists squashed "interactive without fzf: nothing deleted"

  make_fzf_stub
  out=$(cd "$REPO" && GIT_PRUNABLE_FZF="$FZF_STUB" FZF_STUB_PICK='' "$SCRIPT" --no-fetch --base main -i 2>&1)
  assert_contains "interactive: empty selection reported" "$out" "nothing selected"
  assert_branch_exists squashed "interactive: empty selection deletes nothing"

  out=$(cd "$REPO" && GIT_PRUNABLE_FZF="$FZF_STUB" FZF_STUB_PICK='squashed|wt_clean' "$SCRIPT" --no-fetch --base main -i 2>&1)
  assert_contains "interactive: selected branch deleted" "$out" "DEL   squashed"
  assert_branch_missing squashed "interactive: squashed gone"
  assert_branch_missing wt_clean "interactive: multi-select deletes second branch and its worktree"
  assert_branch_exists merged "interactive: unselected branch kept"
}

test_apply() {
  local out
  out=$(run --yes)
  assert_contains "apply: deletion reported" "$out" "DEL   merged"
  assert_branch_missing merged "apply: merged branch deleted"
  assert_branch_missing squashed "apply: squash-merged branch deleted"
  assert_branch_missing rebased "apply: rebased branch deleted"
  assert_branch_missing wt_clean "apply: clean worktree branch deleted"
  assert_branch_missing wt_stale "apply: stale worktree branch deleted"
  assert_branch_exists unmerged "apply: unmerged branch kept"
  assert_branch_exists newbranch "apply: new branch at base kept"
  assert_branch_exists wt_dirty "apply: dirty worktree branch kept"
  assert_branch_exists wt_locked "apply: locked worktree branch kept"
  if [[ ! -d "$TEST_TMP_DIR/wt_clean" ]]; then test_pass "apply: clean worktree directory removed"; else test_fail "apply: clean worktree directory removed"; fi
  if [[ -f "$TEST_TMP_DIR/wt_dirty/untracked.txt" ]]; then test_pass "apply: dirty worktree contents untouched"; else test_fail "apply: dirty worktree contents untouched"; fi
  assert_contains "apply: recovery log records branch" "$(cat "$REPO/.git/prunable.log")" " squashed "
}

test_gone_unmerged() {
  g checkout -q -b gonework
  commit_file "$REPO" gonework-1
  g checkout -q main
  g config remote.origin.url "$TEST_TMP_DIR/nonexistent"
  g config remote.origin.fetch '+refs/heads/*:refs/remotes/origin/*'
  g update-ref refs/remotes/origin/gonework HEAD
  g config branch.gonework.remote origin
  g config branch.gonework.merge refs/heads/gonework
  g update-ref -d refs/remotes/origin/gonework
  local out
  out=$(run)
  assert_contains "gone but unmerged: flagged KEEP" "$out" "KEEP  gonework"
}

test_dangling_origin_head() {
  # origin/HEAD points at origin/master, which does not exist: must fall back to main
  g symbolic-ref refs/remotes/origin/HEAD refs/remotes/origin/master
  local out
  out=$(cd "$REPO" && "$SCRIPT" --no-fetch 2>&1)
  assert_contains "dangling origin/HEAD falls back to main" "$out" "base: main"
  g symbolic-ref --delete refs/remotes/origin/HEAD
}

test_bad_base() {
  local status=0
  (cd "$REPO" && "$SCRIPT" --no-fetch --base nope > /dev/null 2>&1) || status=$?
  if [[ $status -ne 0 ]]; then test_pass "unknown base exits non-zero"; else test_fail "unknown base exits non-zero"; fi
}

main() {
  build_repo
  test_dry_run
  test_interactive
  test_apply
  test_gone_unmerged
  test_dangling_origin_head
  test_bad_base

  printf '%bResults: %s passed, %s failed%s\n' "$TEST_C_GREEN" "$TEST_PASS" "$TEST_FAIL" "$TEST_C_RESET"
  ((TEST_FAIL == 0))
}

main "$@"
