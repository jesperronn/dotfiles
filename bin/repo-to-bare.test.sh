#!/usr/bin/env bash
set -euo pipefail

REPO_TO_BARE="$(pwd)/repo-to-bare.sh"

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
  mkdir -p .git
  touch test.txt
  echo "test" > test.txt
  
  "$REPO_TO_BARE"
  [[ ! -d .git ]] || exit 1
  [[ -d .git.git ]] || exit 1
}

test_help_flag
test_bare_conversion

echo "All tests passed"
