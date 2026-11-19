#!/usr/bin/env bash
# shellcheck disable=SC1090,SC1091

set -euo pipefail

DOTFILES_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
BUILDER="$DOTFILES_ROOT/bin/presentation-builder"

source "$DOTFILES_ROOT/bin/lib/bash_test.sh"

TMP="$(mktemp -d)"
cleanup_test_tmp() { rm -rf "$TMP"; }
trap 'cleanup_test_tmp' EXIT

write_slides() {
  printf '# Hello World\n\nSubtitle here\n\n---\n\n## Slide Two\n\n- Bullet one\n- Bullet two\n' > "$1"
}

# Stub opener: records its arguments instead of launching a browser.
make_opener_stub() {
  OPENER_LOG="$TMP/opener.log"
  OPENER_STUB="$TMP/opener"
  : > "$OPENER_LOG"
  printf '#!/usr/bin/env bash\necho "$@" >> "%s"\n' "$OPENER_LOG" > "$OPENER_STUB"
  chmod +x "$OPENER_STUB"
}

test_no_args_prints_usage() {
  local out status
  capture_command out status "$BUILDER"
  assert_not_status 0 "$status" "no args exits non-zero"
  assert_contains "$out" "Usage" "no args prints usage"
}

test_missing_file_exits_non_zero() {
  local out status
  capture_command out status "$BUILDER" "$TMP/nonexistent.md"
  assert_not_status 0 "$status" "missing file exits non-zero"
}

test_unknown_option_errors() {
  local out status
  capture_command out status "$BUILDER" --bogus
  assert_not_status 0 "$status" "unknown option exits non-zero"
  assert_contains "$out" "unknown option" "unknown option is reported"
}

test_help() {
  local out status flag
  for flag in --help -h; do
    capture_command out status "$BUILDER" "$flag"
    assert_status 0 "$status" "$flag exits 0"
    assert_contains "$out" "--open" "$flag mentions --open"
    assert_contains "$out" "--help" "$flag mentions --help"
    assert_contains "$out" "<input.md>" "$flag mentions input argument"
  done
}

test_build_output() {
  write_slides "$TMP/my-slides.md"
  local out status
  capture_command out status "$BUILDER" "$TMP/my-slides.md"
  assert_status 0 "$status" "build exits 0"
  assert_contains "$out" "Built: $TMP/my-slides.html" "prints output path"
  [[ -f "$TMP/my-slides.html" ]] || test_fail "output file not created"
  test_pass "output file created with .html extension"
  local html
  html="$(cat "$TMP/my-slides.html")"
  assert_contains "$html" "<!DOCTYPE html>" "output has DOCTYPE"
  assert_contains "$html" "</html>" "output has closing html tag"
  assert_contains "$html" "Bullet one" "markdown embedded in output"
  assert_contains "$html" "text/markdown" "markdown script tag present"
}

test_hidden_slide_content_kept() {
  printf '# Visible\n\n---\n\n[slide:hidden]\n## Hidden\n\nSecret content\n' > "$TMP/hidden.md"
  "$BUILDER" "$TMP/hidden.md" > /dev/null
  assert_contains "$(cat "$TMP/hidden.html")" "Secret content" "[slide:hidden] content present in source"
}

test_open_invokes_opener() {
  write_slides "$TMP/open.md"
  make_opener_stub
  local out status
  PRESENTATION_BUILDER_OPENER="$OPENER_STUB" capture_command out status "$BUILDER" --open "$TMP/open.md"
  assert_status 0 "$status" "--open exits 0"
  assert_contains "$out" "Built: $TMP/open.html" "--open still prints output path"
  assert_eq "$TMP/open.html" "$(cat "$OPENER_LOG")" "opener called with output path"
}

test_open_flag_after_input() {
  write_slides "$TMP/after.md"
  make_opener_stub
  PRESENTATION_BUILDER_OPENER="$OPENER_STUB" "$BUILDER" "$TMP/after.md" --open > /dev/null
  assert_eq "$TMP/after.html" "$(cat "$OPENER_LOG")" "--open after input also opens"
}

test_no_open_without_flag() {
  write_slides "$TMP/noopen.md"
  make_opener_stub
  PRESENTATION_BUILDER_OPENER="$OPENER_STUB" "$BUILDER" "$TMP/noopen.md" > /dev/null
  assert_eq "" "$(cat "$OPENER_LOG")" "opener not invoked without --open"
}

run_tests "$@"
