#!/usr/bin/env bash
# Offline color tests for `bbpr open` dense output.
#
# Sources bin/bbpr (safe: the file's EOF sourcing guard prevents main() from
# running when sourced), stubs bbpr_fetch to return a fake PRs JSON array with
# mixed states, then asserts that the dense open output colors the PR number by
# state (OPEN=green, MERGED=dim, CLOSED=red) only when BBPR_COLOR_ENABLED=1,
# and stays plain otherwise. No network, no 1Password token required.
#
# Run with: bash bin/tests/test_bbpr_color.sh

set -u

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/../../" && pwd)"
BBPR="${SCRIPT_DIR}/bin/bbpr"

# bbpr loads with `set -euo pipefail`; disable errexit here so our assertions
# and counters control flow (keep nounset to catch unset variables).
# shellcheck disable=SC1090
source "$BBPR"
set +e

PASS_COUNT=0
FAIL_COUNT=0

# ANSI escape substrings we assert on.
ESC_GREEN=$'\033[32m' # OPEN
ESC_RED=$'\033[31m'   # CLOSED
ESC_DIM=$'\033[2m'    # MERGED / otherwise
# (header always emits bold ESC[1m + reset ESC[0m regardless of color mode;
#  that pre-existing behavior is intentionally left untouched.)

pass() {
  echo "  ✓ $1"
  PASS_COUNT=$((PASS_COUNT + 1))
}
fail() {
  echo "  ✗ $1"
  FAIL_COUNT=$((FAIL_COUNT + 1))
}

# Fake paginated response shape expected by bbpr_paginate (isLastPage + values),
# with one PR of each state to exercise the color mapping.
FAKE_PRS='{"isLastPage":true,"values":[
  {"id":1,"state":"OPEN","title":"Fix login bug","fromRef":{"repository":{"slug":"web","name":"Web Service"}},"author":{"user":{"slug":"alice"}},"createdDate":"2026-08-29T10:00:00+0000"},
  {"id":2,"state":"MERGED","title":"Add feature X","fromRef":{"repository":{"slug":"api","name":"API Service"}},"author":{"user":{"slug":"bob"}},"createdDate":"2026-08-28T10:00:00+0000"},
  {"id":3,"state":"CLOSED","title":"Drop legacy flag","fromRef":{"repository":{"slug":"old","name":"Old Service"}},"author":{"user":{"slug":"carol"}},"createdDate":"2026-08-27T10:00:00+0000"}
]}'

# Stub the network layer: return the fake paginated response verbatim.
bbpr_fetch() { printf '%s' "$FAKE_PRS"; }

# Run bbpr open in dense mode with all long/short/json variants disabled.
run_open() {
  BBPR_LONG=0
  BBPR_JSON=0
  BBPR_SHORT=0
  bbpr_cmd_open
}

echo "Testing: dense open colors PR number by state when color enabled"
BBPR_COLOR_ENABLED=1
out="$(run_open)"
[[ "$out" == *"$ESC_GREEN"* ]] && pass "OPEN PR number is green ($ESC_GREEN)" || fail "OPEN PR number should be green"
[[ "$out" == *"$ESC_RED"* ]] && pass "CLOSED PR number is red ($ESC_RED)" || fail "CLOSED PR number should be red"
[[ "$out" == *"$ESC_DIM"* ]] && pass "MERGED PR number is dim ($ESC_DIM)" || fail "MERGED PR number should be dim"

echo "Testing: dense open rows stay plain when color disabled"
BBPR_COLOR_ENABLED=0
out="$(run_open)"
if [[ "$out" != *"$ESC_GREEN"* && "$out" != *"$ESC_RED"* && "$out" != *"$ESC_DIM"* ]]; then
  pass "no state-based row colors when BBPR_COLOR_ENABLED=0"
else
  fail "state-based row colors leaked when color disabled"
fi

echo ""
echo "Color tests passed: $PASS_COUNT"
echo "Color tests failed: $FAIL_COUNT"

if [[ "$FAIL_COUNT" -eq 0 ]]; then
  exit 0
fi

exit 1
