#!/usr/bin/env bash
# shellcheck disable=SC1090,SC1091,SC2034,SC2329

set -euo pipefail

DOTFILES="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
SUPERDU_BIN="$DOTFILES/bin/superdu"

source "$DOTFILES/bin/lib/bash_test.sh"
source "$SUPERDU_BIN" source

superdu_reset_state() {
  SUPER_DU_COLOR_ENABLED=1
  SUPER_DU_COLOR_MODE="auto"
  SUPER_DU_VERBOSE=0
  SUPER_DU_PROGRESSIVE=1
  SUPER_DU_TTY_ACTIVE=0
  SUPER_DU_RENDERED_LINES=0
  SUPER_DU_HEADER_PRINTED=0
  SUPER_DU_WARNINGS_PRINTED=0
  SUPER_DU_GROUP_DOWNLOADS=1
  SUPER_DU_GROUP_DESKTOP=1
  SUPER_DU_GROUP_DOCUMENTS=1
  SUPER_DU_GROUP_PHOTOS=1
  SUPER_DU_GROUP_MUSIC=1
  SUPER_DU_GROUP_TV=1
  SUPER_DU_GROUP_OLLAMA=1
  SUPER_DU_GROUP_BREW=1
  SUPER_DU_POSITIVE_GROUP_FLAGS=0
  SUPER_DU_CATEGORY_ROWS=()
  SUPER_DU_OLLAMA_WARNINGS=()
}

test_parse_opts_and_groups() {
  superdu_reset_state
  superdu_parse_opts --plain --verbose --downloads --documents
  assert_eq "0" "$SUPER_DU_PROGRESSIVE" "plain disables progressive rendering"
  assert_eq "1" "$SUPER_DU_VERBOSE" "verbose flag"
  assert_eq "1" "$SUPER_DU_GROUP_DOWNLOADS" "downloads enabled"
  assert_eq "1" "$SUPER_DU_GROUP_DOCUMENTS" "documents enabled"
  assert_eq "0" "$SUPER_DU_GROUP_DESKTOP" "positive selection disables other groups"
  assert_eq "0" "$SUPER_DU_GROUP_BREW" "positive selection disables brew"

  superdu_reset_state
  superdu_parse_opts --no-photos --no-tv
  assert_eq "0" "$SUPER_DU_GROUP_PHOTOS" "photos disabled"
  assert_eq "0" "$SUPER_DU_GROUP_TV" "tv disabled"
  assert_eq "1" "$SUPER_DU_GROUP_DOWNLOADS" "downloads remain enabled"
}

test_formatting_and_next_steps() {
  assert_eq "10.0 KB" "$(superdu_format_kb 10)" "format small kb"
  assert_eq "2.0 MB" "$(superdu_format_kb 2048)" "format mb"
  assert_eq "2.00 GB" "$(superdu_format_kb 2097152)" "format gb"
  assert_eq "downloads" "$(superdu_group_label downloads)" "downloads label"
  assert_eq "$HOME/Documents" "$(superdu_group_display documents)" "documents display"
  assert_eq "next: superclean --desktop --interactive --dry-run" "$(superdu_group_next_step desktop)" "desktop next step"
  assert_eq "next: ollama list  or  rm -rf <store-folder> manually" "$(superdu_group_next_step ollama)" "ollama next step"
  assert_eq "##########################" "$(superdu_render_bar 10 10)" "leader bar fills width"
  assert_eq " 50%" "$(superdu_percent_of_max 10 20)" "percent of max"
}

test_path_dedup_and_rendering() {
  local tmp_root="" deduped="" rows="" next_line=""

  tmp_root="$(mktemp -d)"
  mkdir -p "$tmp_root/a" "$tmp_root/b"
  printf 'x' >"$tmp_root/a/file"
  ln -s "$tmp_root/a" "$tmp_root/link-a"

  deduped="$(printf '%s\n%s\n' "$tmp_root/a" "$tmp_root/link-a" | superdu_dedupe_existing_paths)"
  assert_eq "$(cd "$tmp_root" && pwd -P)/a" "$deduped" "dedupe resolves symlink aliases"

  SUPER_DU_CATEGORY_ROWS=(
    "$(printf '%012d\t%s\t%s\t%s\t%s' 10240 downloads downloads "$HOME/Downloads" "next: superclean --downloads --interactive --dry-run")"
    "$(printf '%012d\t%s\t%s\t%s\t%s' 20480 desktop desktop "$HOME/Desktop" "next: superclean --desktop --interactive --dry-run")"
  )
  rows="$(superdu_build_category_rows)"
  assert_contains "$rows" "desktop" "larger row sorts first"
  assert_contains "$rows" " 50%  $HOME/Downloads" "smaller row rescales bar percentage"
  assert_not_contains "$rows" "  - " "primary rows do not use bullet prefix"

  next_line="$(superdu_format_next_step_line 'next: superclean --downloads --interactive --dry-run')"
  assert_contains "$next_line" "superclean --downloads --interactive --dry-run" "next-step formatter keeps command"

  rm -rf "$tmp_root"
}

test_path_fallbacks() {
  local tmp_root=""

  tmp_root="$(mktemp -d)"
  HOME="$tmp_root/home"
  mkdir -p "$HOME/Pictures" "$HOME/Movies"

  assert_eq "$HOME/Pictures" "$(superdu_group_display photos)" "photos prefers Pictures on macOS-style homes"
  assert_eq "$HOME/Movies" "$(superdu_group_display tv)" "tv prefers Movies on macOS-style homes"

  rm -rf "$tmp_root"
  HOME="/Users/jesper"
}

test_macos_access_preflight() {
  local output="" status=0

  superdu_reset_state
  SUPER_DU_GROUP_DOWNLOADS=1
  SUPER_DU_GROUP_DESKTOP=0
  SUPER_DU_GROUP_DOCUMENTS=0
  SUPER_DU_GROUP_PHOTOS=0
  SUPER_DU_GROUP_MUSIC=0
  SUPER_DU_GROUP_TV=0
  superdu_running_on_macos() { return 0; }
  superdu_has_macos_protected_access() { return 1; }

  capture_command output status superdu_require_macos_protected_access
  assert_status "1" "$status" "preflight fails without protected access"
  assert_contains "$output" "Grant Full Disk Access" "preflight explains full disk access"

  unset -f superdu_running_on_macos
  unset -f superdu_has_macos_protected_access

  superdu_reset_state
  SUPER_DU_GROUP_DOWNLOADS=0
  SUPER_DU_GROUP_DESKTOP=0
  SUPER_DU_GROUP_DOCUMENTS=0
  SUPER_DU_GROUP_PHOTOS=0
  SUPER_DU_GROUP_MUSIC=0
  SUPER_DU_GROUP_TV=0
  superdu_running_on_macos() { return 0; }
  superdu_has_macos_protected_access() { return 1; }

  capture_command output status superdu_require_macos_protected_access
  assert_status "0" "$status" "preflight skips when protected groups are disabled"

  unset -f superdu_running_on_macos
  unset -f superdu_has_macos_protected_access
}

test_access_helpers() {
  local host=""

  assert_eq "x-apple.systempreferences:com.apple.preference.security?Privacy_AllFiles" "$(superdu_full_disk_access_url)" "full disk access url"

  TERM_PROGRAM="WezTerm"
  host="$(superdu_detect_host_app)"
  assert_eq "WezTerm" "$host" "host app prefers TERM_PROGRAM"
  unset TERM_PROGRAM
}

run_tests "$@"
