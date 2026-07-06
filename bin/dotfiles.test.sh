#!/usr/bin/env bash
# shellcheck disable=SC1090,SC1091

set -euo pipefail

DOTFILES_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
DOTFILES_BIN="$DOTFILES_ROOT/bin/dotfiles"

source "$DOTFILES_ROOT/bin/lib/bash_test.sh"

TEST_TMP_DIR=""

setup_tmpdir() {
  TEST_TMP_DIR="$(mktemp -d)"
  trap 'rm -rf "$TEST_TMP_DIR"' EXIT
}

test_link_phase_skips_temporary_link_file_artifacts() {
  local home_dir="$TEST_TMP_DIR/home"
  local repo_root="$home_dir/src/dotfiles"
  local output=""
  local status=0

  mkdir -p "$repo_root/link-file/.config/myapp" "$repo_root/link-dir" "$repo_root/copy" "$repo_root/init"
  cp "$DOTFILES_BIN" "$repo_root/bin.dotfiles"
  mkdir -p "$repo_root/bin"
  mv "$repo_root/bin.dotfiles" "$repo_root/bin/dotfiles"
  chmod +x "$repo_root/bin/dotfiles"

  printf 'managed\n' >"$repo_root/link-file/.claude.json"
  printf 'temp\n' >"$repo_root/link-file/.claude.json.tmp.14926.28a48d52b754"
  printf 'swap\n' >"$repo_root/link-file/.config/myapp/settings.json.swp"
  printf 'managed nested\n' >"$repo_root/link-file/.config/myapp/settings.json"

  capture_command output status env HOME="$home_dir" bash "$repo_root/bin/dotfiles" --link

  assert_status "0" "$status" "dotfiles --link succeeds"
  assert_contains "$output" "Linking ~/.claude.json." "managed top-level file is linked"
  assert_contains "$output" "Linking ~/.config/myapp/settings.json." "managed nested file is linked"
  assert_not_contains "$output" ".claude.json.tmp.14926.28a48d52b754" "tmp artifact is not linked"
  assert_not_contains "$output" "settings.json.swp" "swap artifact is not linked"
  if [[ -e "$home_dir/.claude.json.tmp.14926.28a48d52b754" || -L "$home_dir/.claude.json.tmp.14926.28a48d52b754" ]]; then
    test_fail "tmp artifact is not created in home" "Unexpected linked temp file at [$home_dir/.claude.json.tmp.14926.28a48d52b754]"
  fi
}

setup_tmpdir
run_tests "$@"
