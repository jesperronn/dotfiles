#!/usr/bin/env bash
# shellcheck disable=SC1090,SC1091
set -euo pipefail

DOTFILES_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
source "$DOTFILES_ROOT/bin/lib/bash_test.sh"

test_help_prints_usage_without_shell_syntax() {
  local output="" status=0
  capture_command output status "$DOTFILES_ROOT/bin/curlsubl" --help
  assert_status 0 "$status" "curlsubl --help succeeds"
  assert_contains "$output" 'Usage: curlsubl [curloptions...] url' "help shows the command syntax"
  assert_not_contains "$output" 'echo "Usage:' "help omits shell source syntax"
}

run_tests "$@"
