#!/usr/bin/env bash
set -euo pipefail

DOTFILES_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
REPO_TO_BARE="$DOTFILES_ROOT/bin/repo-to-bare.sh"

test_help_flag() {
  local output
  output=$("$REPO_TO_BARE" --help)
  [[ "$output" == *"Usage:"* ]]
}

test_bare_conversion() {
  local testdir
  testdir=$(mktemp -d)
  trap "rm -rf '$testdir'" RETURN

  cd "$testdir"
  mkdir -p repo/.git
  touch repo/test.txt
  echo "test" > repo/test.txt

  "$REPO_TO_BARE"
  [[ ! -d repo/.git ]] || exit 1
  [[ -d repo.git ]] || exit 1
}

test_help_flag
test_bare_conversion

echo "All tests passed"
