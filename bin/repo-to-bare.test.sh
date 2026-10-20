#!/usr/bin/env bash
set -euo pipefail

DOTFILES_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
REPO_TO_BARE="$DOTFILES_ROOT/bin/repo-to-bare.sh"

# shellcheck disable=SC1091
source "$DOTFILES_ROOT/bin/lib/bash_test.sh"

test_help_flag() {
  local output
  output=$("$REPO_TO_BARE" --help)
  [[ "$output" == *"Usage:"* ]]
}

test_bare_conversion() {
  local testdir
  testdir=$(mktemp -d)
  # shellcheck disable=SC2064
  trap "rm -rf '$testdir'" RETURN

  cd "$testdir"
  mkdir -p repo/.git
  touch repo/test.txt
  echo "test" > repo/test.txt

  "$REPO_TO_BARE"
  [[ ! -d repo/.git ]] || exit 1
  [[ -d repo.git ]] || exit 1
}

make_git_repo() {
  git init -q "$1"
  echo "content" > "$1/file.txt"
}

test_multiple_repos_normal_paths() {
  local testdir out
  testdir=$(mktemp -d)
  # shellcheck disable=SC2064
  trap "rm -rf '$testdir'" RETURN
  cd "$testdir"
  make_git_repo alpha
  make_git_repo beta
  mkdir -p plain/sub
  mkdir -p deep/er/.git

  out=$("$REPO_TO_BARE" 2>&1)

  assert_contains "$out" "converting ./alpha/.git:" "announces alpha"
  assert_contains "$out" "converting ./beta/.git:" "announces beta"
  [[ -d alpha.git && -d beta.git ]] || test_fail "bare copies exist"
  test_pass "bare copies exist for each repo"
  [[ ! -e alpha/.git && ! -e beta/.git ]] || test_fail "originals removed"
  test_pass "original .git dirs removed"
  assert_eq "true" "$(git -C alpha.git config core.bare)" "alpha.git is core.bare"
  assert_eq "true" "$(git -C beta.git config core.bare)" "beta.git is core.bare"
  [[ -f alpha/file.txt ]] || test_fail "working files kept"
  test_pass "working tree files untouched"
  [[ -d deep/er/.git ]] || test_fail "depth-3 .git untouched"
  test_pass ".git at depth 3 is not converted"
  [[ ! -e deep/er.git ]] || test_fail "no depth-3 bare copy"
  test_pass "no bare copy for depth-3 .git"
}

test_no_repos_is_noop() {
  local testdir out
  testdir=$(mktemp -d)
  # shellcheck disable=SC2064
  trap "rm -rf '$testdir'" RETURN
  cd "$testdir"
  mkdir -p empty
  out=$("$REPO_TO_BARE" 2>&1)
  assert_eq "" "$out" "no output when nothing to convert"
}

test_path_with_spaces() {
  local testdir
  testdir=$(mktemp -d)
  # shellcheck disable=SC2064
  trap "rm -rf '$testdir'" RETURN
  cd "$testdir"
  make_git_repo "my repo"
  make_git_repo normal

  "$REPO_TO_BARE" >/dev/null 2>&1

  [[ -d normal.git && ! -e normal/.git ]] || test_fail "normal repo converted"
  test_pass "normal repo converted alongside spaced one"
  # Newly works with NUL-safe iteration (previously word-splitting skipped it).
  [[ -d "my repo.git" && ! -e "my repo/.git" ]] || test_fail "spaced repo converted"
  test_pass "spaced repo converted to bare"
  assert_eq "true" "$(git -C "my repo.git" config core.bare)" "spaced bare copy is core.bare"
}

test_help_flag
test_bare_conversion
test_multiple_repos_normal_paths
test_no_repos_is_noop
test_path_with_spaces

echo "All tests passed"
