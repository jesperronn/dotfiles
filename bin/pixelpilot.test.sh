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
  assert_contains "$output" "--output-html" "pixelpilot --help lists the output-html option"
}

test_unknown_option_fails() {
  local output=""
  local status=0

  capture_command output status "$PIXELPILOT_BIN" --no-such-flag
  assert_not_status "0" "$status" "pixelpilot rejects an unknown option"
  assert_contains "$output" "Unknown option: --no-such-flag" "pixelpilot names the unknown option"
}

test_wrapper_reviews_git_baseline() {
  local repo="$TEST_TMP_DIR/repo"
  local output=""
  local status=0

  rm -rf "$repo"
  mkdir -p "$repo/doc/screenshots" "$repo/cur"
  # 1x1 PNG
  printf 'iVBORw0KGgoAAAANSUhEUgAAAAEAAAABCAYAAAAfFcSJAAAADUlEQVR42mNkYPhfDwAChwGA60e6kgAAAABJRU5ErkJggg==' | base64 -d >"$repo/doc/screenshots/a.png"
  cp "$repo/doc/screenshots/a.png" "$repo/cur/a.png"
  git -C "$repo" init -q
  git -C "$repo" add .
  git -C "$repo" -c user.email=t@example.com -c user.name=t commit -qm init
  git -C "$repo" tag -a v0 -m v0

  output="$(cd "$repo" && "$PIXELPILOT_BIN" --baseline HEAD --current-dir cur </dev/null 2>&1)" || status=$?
  assert_status "0" "$status" "pixelpilot reviews a git baseline and exits zero"
  assert_contains "$output" "Wrote screenshot review page to tmp/screenshot-review/index.html" "pixelpilot reports the written review page"

  if [[ -f "$repo/tmp/screenshot-review/index.html" ]]; then
    test_pass "pixelpilot writes the HTML review page"
  else
    test_fail "pixelpilot writes the HTML review page" "Missing: $repo/tmp/screenshot-review/index.html"
  fi
}

test_help_prints_usage
test_unknown_option_fails
test_wrapper_reviews_git_baseline

run_tests "$@"
