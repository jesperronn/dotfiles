#!/usr/bin/env bash
set -euo pipefail

pushd "$(dirname "$0")/.." > /dev/null || exit 1

source bin/lib/bash_test.sh
source bin/script-name source

reset_script_name_test_state() {
  unset SCRIPT_NAME_FLAG_VERBOSE || true
}

test_script_name_help_lists_verbose_flag() {
  reset_script_name_test_state

  local output
  output="$(usage)"

  assert_contains "${output}" "--verbose" "help lists verbose flag"
}

run_tests "$@"
