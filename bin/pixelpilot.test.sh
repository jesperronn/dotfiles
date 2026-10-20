#!/usr/bin/env bash
# shellcheck disable=SC1091
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
PIXELPILOT_BIN="$ROOT/bin/pixelpilot"

source "$ROOT/bin/lib/bash_test.sh"

TEST_TMP_DIR="$(mktemp -d)"
cleanup_test_tmp() { rm -rf "$TEST_TMP_DIR"; }
trap 'cleanup_test_tmp' EXIT

test_help_prints_usage() {
  local output=""
  local status=0

  capture_command output status "$PIXELPILOT_BIN" --help
  assert_status "0" "$status" "pixelpilot --help exits zero"
  assert_contains "$output" "Usage: pixelpilot" "pixelpilot --help prints usage"
  assert_contains "$output" "--manifest" "pixelpilot --help lists the manifest option"
}

test_unknown_option_fails() {
  local output=""
  local status=0

  capture_command output status "$PIXELPILOT_BIN" --no-such-flag
  assert_not_status "0" "$status" "pixelpilot rejects an unknown option"
  assert_contains "$output" "Unknown option: --no-such-flag" "pixelpilot names the unknown option"
}

test_wrapper_runs_review_cli_with_node() {
  local manifest="$TEST_TMP_DIR/manifest.json"
  local output_html="$TEST_TMP_DIR/review/index.html"
  local output=""
  local status=0

  cat >"$manifest" <<'JSON'
{
  "baseline": { "ref": "HEAD", "describe": "v0-0-gabc", "generated_at": "2026-01-01T00:00:00.000Z" },
  "current": { "describe": "v0-0-gabc", "generated_at": "2026-01-01T00:00:00.000Z" },
  "scenarios": []
}
JSON

  capture_command output status "$PIXELPILOT_BIN" --manifest "$manifest" --output-html "$output_html" </dev/null
  assert_status "0" "$status" "pixelpilot runs the review CLI through node and exits zero"
  assert_contains "$output" "Wrote screenshot review page to $output_html" "pixelpilot reports the written review page"

  if [[ -f "$output_html" ]] && grep -q "Screenshot Review" "$output_html"; then
    test_pass "pixelpilot writes the HTML review page"
  else
    test_fail "pixelpilot writes the HTML review page" "Missing or invalid: $output_html"
  fi
}

test_help_prints_usage
test_unknown_option_fails
test_wrapper_runs_review_cli_with_node

run_tests "$@"
