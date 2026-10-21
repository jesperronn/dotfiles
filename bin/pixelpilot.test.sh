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
  assert_contains "$(cat "$repo/tmp/screenshot-review/index.html")" "<p>v0" "git-ref mode still labels headings with git describe"
}

make_png() {
  # make_png <path> <width> <height> <rgb-hex> -- solid-colour PNG via the bundled encoder
  node -e '
    const { PNG } = require(process.argv[1]);
    const [file, w, h, hex] = process.argv.slice(2);
    const png = new PNG({ width: +w, height: +h });
    const rgb = [0, 2, 4].map((i) => parseInt(hex.slice(i, i + 2), 16));
    for (let i = 0; i < png.data.length; i += 4) png.data.set([...rgb, 255], i);
    require("node:fs").writeFileSync(file, PNG.sync.write(png));
  ' "$ROOT/bin/lib/pixelpilot/png.js" "$@"
}

setup_folder_pair() {
  local repo="$1"
  rm -rf "$repo"
  mkdir -p "$repo/orig" "$repo/dev"
  make_png "$repo/orig/01-home.png" 20 40 ffffff
  make_png "$repo/dev/01-home.png" 20 60 000000
  git -C "$repo" init -q
}

test_folder_mode_needs_no_git_tags() {
  local repo="$TEST_TMP_DIR/folders"
  local output=""
  local status=0
  setup_folder_pair "$repo"

  output="$(cd "$repo" && "$PIXELPILOT_BIN" --baseline-folder orig --current-dir dev --output-html out/index.html </dev/null 2>&1)" || status=$?
  assert_status "0" "$status" "folder mode works in a repo with no commits or tags"
  assert_contains "$(cat "$repo/out/index.html")" "<p>orig " "folder mode defaults the baseline heading to the folder path"
  assert_contains "$(cat "$repo/out/index.html")" "<p>dev</p>" "folder mode defaults the current heading to the folder path"
}

test_labels_appear_in_html() {
  local repo="$TEST_TMP_DIR/labels"
  local html=""
  setup_folder_pair "$repo"

  (cd "$repo" && "$PIXELPILOT_BIN" --baseline-folder orig --current-dir dev \
    --baseline-label 'WordPress (original)' --current-label 'Hugo (new)' \
    --output-html out/index.html </dev/null >/dev/null 2>&1)
  html="$(cat "$repo/out/index.html")"
  assert_contains "$html" "WordPress (original)" "baseline label is in the page"
  assert_contains "$html" "Hugo (new)" "current label is in the page"
}

test_report_prints_table_and_fail_above() {
  local repo="$TEST_TMP_DIR/report"
  local output=""
  local status=0
  setup_folder_pair "$repo"

  output="$(cd "$repo" && "$PIXELPILOT_BIN" --report --baseline-folder orig --current-dir dev --report-dir rep 2>&1)" || status=$?
  assert_status "0" "$status" "report exits zero without --fail-above"
  assert_contains "$output" "20x40" "report shows the baseline size"
  assert_contains "$output" "20x60" "report shows the current size"
  assert_contains "$output" "01-home" "report lists the pair"
  assert_contains "$output" "bands(%): 0:100" "report prints per-band percentages"

  status=0
  output="$(cd "$repo" && "$PIXELPILOT_BIN" --report --baseline-folder orig --current-dir dev --report-dir rep --fail-above 5 2>&1)" || status=$?
  assert_status "1" "$status" "report exits 1 when a pair differs above --fail-above"

  if [[ -f "$repo/rep/01-home.png" ]]; then
    test_pass "report writes the diff PNG"
  else
    test_fail "report writes the diff PNG" "Missing: $repo/rep/01-home.png"
  fi
}

test_help_prints_usage
test_unknown_option_fails
test_wrapper_reviews_git_baseline
test_folder_mode_needs_no_git_tags
test_labels_appear_in_html
test_report_prints_table_and_fail_above

run_tests "$@"
