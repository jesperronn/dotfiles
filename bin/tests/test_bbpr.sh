#!/usr/bin/env bash
# Bash integration tests for the bbpr CLI.
#
# Offline smoke tests only: help output, subcommand dispatch, flag parsing, and
# PR-spec argument parsing. Does NOT hit the network or require a 1Password
# token. PR-spec parsing is exercised by pointing bbpr at a dead local URL
# (127.0.0.1:1) so a parse failure ("Invalid PR specification") is clearly
# distinguishable from an expected network failure.
#
# Run with: bash bin/tests/test_bbpr.sh

set -u

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/../../" && pwd)"
BBPR="${SCRIPT_DIR}/bin/bbpr"
DEAD_URL="http://127.0.0.1:1/" # nothing listens here -> instant connection refused

# Color codes for output
RED='\033[0;31m'
GREEN='\033[0;32m'
NC='\033[0m' # No Color

PASS_COUNT=0
FAIL_COUNT=0

# Test helper functions
test_exit_code() {
  local expected=$1
  local test_name=$2
  shift 2
  local output exit_code

  # Run command and capture both output and exit code
  if output=$("$@" 2>&1); then
    exit_code=0
  else
    exit_code=$?
  fi

  if [[ "$exit_code" -eq "$expected" ]]; then
    echo -e "${GREEN}✓${NC} $test_name"
    ((PASS_COUNT++))
    echo "$output"
  else
    echo -e "${RED}✗${NC} $test_name (expected exit code $expected, got $exit_code)"
    echo "  Output: $output"
    ((FAIL_COUNT++))
    echo "$output"
  fi
}

test_output_contains() {
  local expected_pattern=$1
  local test_name=$2
  shift 2
  local output exit_code

  if output=$("$@" 2>&1); then
    exit_code=0
  else
    exit_code=$?
  fi

  if echo "$output" | grep -q "$expected_pattern"; then
    echo -e "${GREEN}✓${NC} $test_name"
    ((PASS_COUNT++))
  else
    echo -e "${RED}✗${NC} $test_name (expected pattern not found: $expected_pattern)"
    echo "  Output: $output"
    ((FAIL_COUNT++))
  fi
}

# ===== Test: --help =====

echo "Testing: --help"
test_exit_code 0 "bbpr --help exits 0" "$BBPR" --help
for sub in ping mine review open show comments; do
  test_output_contains "$sub" "help lists $sub subcommand" "$BBPR" --help
done

# ===== Test: Unknown subcommand =====

echo ""
echo "Testing: Unknown subcommand"
test_exit_code 1 "unknown subcommand returns exit code 1" "$BBPR" bogus_subcommand
test_output_contains "Unknown subcommand" "unknown subcommand error message" "$BBPR" bogus_subcommand

# ===== Test: show with no argument =====

echo ""
echo "Testing: show with no argument"
test_exit_code 1 "show with no argument returns exit code 1" "$BBPR" show
test_output_contains "Usage:" "show with no argument shows usage" "$BBPR" show

# ===== Test: --json flag is accepted by the parser =====

echo ""
echo "Testing: --json flag parsing"
# With no subcommand, --json must be consumed as a flag (not treated as one),
# so bbpr falls through to help and exits 0. If --json were unparseable it
# would instead be reported as an unknown subcommand (exit 1).
test_exit_code 0 "bbpr --json is accepted (no subcommand -> help)" "$BBPR" --json

# ===== Test: --me flag is accepted by the parser =====

echo ""
echo "Testing: --me flag parsing"
test_exit_code 0 "bbpr --me is accepted (no subcommand -> help)" "$BBPR" --me someone.slug

# ===== Test: PR-spec argument parsing (slash, hash, URL forms) =====

# bbpr_cmd_show parses the PR spec before any network call, so pointing at a
# dead URL lets us confirm parsing succeeded (it proceeds to a network failure)
# vs. failed ("Invalid PR specification").
echo ""
echo "Testing: PR-spec parsing (slash / hash / URL forms)"
for spec in "SKOLELOGIN/changelog#52" "SKOLELOGIN/changelog/52" \
  "https://stash.stil.dk/projects/SKOLELOGIN/repos/changelog/pull-requests/52"; do
  output="$("$BBPR" --base-url "$DEAD_URL" show "$spec" 2>&1)" || true
  if echo "$output" | grep -q "Invalid PR specification"; then
    echo -e "${RED}✗${NC} $spec was rejected by the parser"
    echo "  Output: $output"
    ((FAIL_COUNT++))
  else
    echo -e "${GREEN}✓${NC} $spec parsed (proceeded past argument parsing)"
    ((PASS_COUNT++))
  fi
done

# A malformed spec must be rejected at parse time.
echo ""
echo "Testing: malformed PR-spec is rejected"
test_output_contains "Invalid PR specification" "malformed spec rejected at parse time" \
  "$BBPR" --base-url "$DEAD_URL" show "not-a-valid-spec"

# ===== Summary =====

echo ""
echo "================================"
echo -e "Tests passed: ${GREEN}${PASS_COUNT}${NC}"
echo -e "Tests failed: ${RED}${FAIL_COUNT}${NC}"
echo "================================"

if [[ "$FAIL_COUNT" -gt 0 ]]; then
  exit 1
fi

exit 0
