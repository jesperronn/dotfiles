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
  assert_contains "$(cat "$repo/tmp/screenshot-review/index.html")" '"baseline_source":"HEAD:doc/screenshots/a.png"' "git-ref mode shows a git show path as the baseline source"
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
  assert_contains "$(cat "$repo/out/index.html")" 'class="generated-at"' "page shows a generated timestamp after the title"
  assert_contains "$(cat "$repo/out/index.html")" '"baseline_source":"orig/01-home.png"' "folder mode shows folder/file as the baseline source"
  assert_contains "$(cat "$repo/out/index.html")" '"current_source":"dev/01-home.png"' "folder mode shows folder/file as the current source"
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

test_new_flags_dir_to_dir_and_labels() {
  local repo="$TEST_TMP_DIR/newflags"
  local html=""
  setup_folder_pair "$repo"

  (cd "$repo" && "$PIXELPILOT_BIN" --from-dir orig --to-dir dev \
    --from-label 'Before' --to-label 'After' \
    --output-html out/index.html </dev/null >/dev/null 2>&1)
  html="$(cat "$repo/out/index.html")"
  assert_contains "$html" '"baseline_source":"orig/01-home.png"' "--from-dir reads the baseline folder"
  assert_contains "$html" '"current_source":"dev/01-home.png"' "--to-dir reads the current folder"
  assert_contains "$html" "Before" "--from-label is in the page"
  assert_contains "$html" "After" "--to-label is in the page"
}

setup_git_screenshots() {
  # setup_git_screenshots <repo> <tracked-dir> -- commit a tagged white PNG, then change it on disk
  local repo="$1" dir="$2"
  rm -rf "$repo"
  mkdir -p "$repo/$dir"
  make_png "$repo/$dir/01-home.png" 20 40 ffffff
  git -C "$repo" init -q
  git -C "$repo" add .
  git -C "$repo" -c user.email=t@example.com -c user.name=t commit -qm init
  git -C "$repo" tag -a v1 -m v1
  make_png "$repo/$dir/01-home.png" 20 60 000000
}

test_path_is_shared_between_ref_and_disk() {
  local repo="$TEST_TMP_DIR/pathshared"
  local output=""
  local status=0
  setup_git_screenshots "$repo" screenshots

  output="$(cd "$repo" && "$PIXELPILOT_BIN" --report --from v1 --path screenshots --report-dir rep 2>&1)" || status=$?
  assert_status "0" "$status" "--from <tag> --path compares the tag against the same dir on disk"
  assert_contains "$output" "20x40" "report shows the tagged baseline size"
  assert_contains "$output" "20x60" "report shows the on-disk current size"
}

test_from_path_and_to_dir_override_individually() {
  local repo="$TEST_TMP_DIR/pathsplit"
  local output=""
  local status=0
  setup_git_screenshots "$repo" doc/screenshots
  mkdir -p "$repo/screenshots"
  mv "$repo/doc/screenshots/01-home.png" "$repo/screenshots/01-home.png"

  output="$(cd "$repo" && "$PIXELPILOT_BIN" --report --from v1 --from-path doc/screenshots --to-dir screenshots --report-dir rep 2>&1)" || status=$?
  assert_status "0" "$status" "--from-path and --to-dir point each side at its own folder"
  assert_contains "$output" "20x40" "baseline read from --from-path inside the ref"
  assert_contains "$output" "20x60" "current read from --to-dir on disk"

  status=0
  output="$(cd "$repo" && "$PIXELPILOT_BIN" --report --from v1 --to HEAD --from-path doc/screenshots --to-path doc/screenshots --report-dir rep 2>&1)" || status=$?
  assert_status "0" "$status" "--to-path selects the path inside the --to ref"
}

test_ref_and_dir_on_same_side_conflict() {
  local repo="$TEST_TMP_DIR/conflict"
  local output=""
  local status=0
  setup_folder_pair "$repo"

  capture_command output status "$PIXELPILOT_BIN" --from HEAD --from-dir "$repo/orig"
  assert_not_status "0" "$status" "--from and --from-dir are rejected together"
  assert_contains "$output" "mutually exclusive" "conflict error explains the exclusivity"
  status=0
  capture_command output status "$PIXELPILOT_BIN" --to HEAD --to-dir "$repo/dev"
  assert_not_status "0" "$status" "--to and --to-dir are rejected together"
}

test_help_lists_new_flags() {
  local output=""
  local status=0

  capture_command output status "$PIXELPILOT_BIN" --help
  assert_contains "$output" "--from-dir" "help lists --from-dir"
  assert_contains "$output" "--to-dir" "help lists --to-dir"
  assert_contains "$output" "--extract-dir" "help lists --extract-dir"
  assert_contains "$output" "Deprecated aliases" "help documents the old flag names"
}


test_help_is_colorized_on_demand() {
  local output=""
  local status=0
  local esc=$'\033'

  capture_command output status "$PIXELPILOT_BIN" --help
  assert_not_contains "$output" "${esc}[" "help has no color codes when piped"

  output="$(FORCE_COLOR=1 "$PIXELPILOT_BIN" --help 2>&1)"
  assert_contains "$output" "${esc}[1;32mpixelpilot${esc}[0m" "help colors the script name"
  assert_contains "$output" "${esc}[1;36m--from-dir${esc}[0m" "help colors option flags"
  assert_contains "$output" "${esc}[33m<dir>${esc}[0m" "help colors option values"

  output="$(NO_COLOR=1 FORCE_COLOR=1 "$PIXELPILOT_BIN" --help 2>&1)"
  assert_not_contains "$output" "${esc}[" "NO_COLOR disables color"
}

test_slim_images_are_not_upscaled() {
  local repo="$TEST_TMP_DIR/slim"
  local html=""
  local scales=""
  rm -rf "$repo"
  mkdir -p "$repo/orig" "$repo/dev"
  make_png "$repo/orig/01-slim.png" 39 146 ffffff
  make_png "$repo/dev/01-slim.png" 39 140 000000
  git -C "$repo" init -q
  (cd "$repo" && "$PIXELPILOT_BIN" --from-dir orig --to-dir dev --output-html out/index.html </dev/null >/dev/null 2>&1)
  html="$(cat "$repo/out/index.html")"
  assert_contains "$html" "max-width: var(--canvas-max, 100%)" "pane image area is capped by --canvas-max"
  assert_contains "$html" "function applyImageSizing" "page computes the image sizing"

  # min(fitWidth, max(1, fitHeight)): normal, very long and slim images
  scales="$(node -e '
    const src = require("node:fs").readFileSync(process.argv[1], "utf8");
    const fn = src.match(/function computeImageScale[\s\S]*?\n\t}\n/)[0];
    const compute = new Function(fn + "; return computeImageScale;")();
    // [w, h, paneW, availH]
    console.log([[1280, 800, 800, 900], [1280, 6000, 800, 900], [390, 844, 800, 900], [390, 1463, 800, 900]]
      .map((a) => compute(...a).toFixed(3)).join(" "));
  ' "$ROOT/bin/lib/pixelpilot/review-page.js")"
  assert_eq "0.625 0.625 1.066 1.000" "$scales" "scale fits width for normal/long images and caps slim ones"
}

test_help_prints_usage
test_slim_images_are_not_upscaled
test_help_is_colorized_on_demand
test_unknown_option_fails
test_wrapper_reviews_git_baseline
test_folder_mode_needs_no_git_tags
test_labels_appear_in_html
test_report_prints_table_and_fail_above
test_new_flags_dir_to_dir_and_labels
test_path_is_shared_between_ref_and_disk
test_from_path_and_to_dir_override_individually
test_ref_and_dir_on_same_side_conflict
test_help_lists_new_flags

run_tests "$@"
