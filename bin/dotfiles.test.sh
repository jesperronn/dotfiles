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

test_link_phase_does_not_link_state_heavy_top_level_dirs() {
  local home_dir="$TEST_TMP_DIR/home-state-dirs"
  local repo_root="$home_dir/src/dotfiles"
  local output=""
  local status=0

  mkdir -p "$repo_root/link-dir/.config/myapp" "$repo_root/link-dir/.vim/plugin" "$repo_root/link-file/.config/myapp" "$repo_root/copy" "$repo_root/init"
  cp "$DOTFILES_BIN" "$repo_root/bin.dotfiles"
  mkdir -p "$repo_root/bin"
  mv "$repo_root/bin.dotfiles" "$repo_root/bin/dotfiles"
  chmod +x "$repo_root/bin/dotfiles"

  printf 'runtime state\n' >"$repo_root/link-dir/.config/myapp/state.json"
  printf 'managed config\n' >"$repo_root/link-file/.config/myapp/settings.json"
  printf 'vim plugin\n' >"$repo_root/link-dir/.vim/plugin/example.vim"

  capture_command output status env HOME="$home_dir" bash "$repo_root/bin/dotfiles" --link

  assert_status "0" "$status" "dotfiles --link succeeds"
  assert_not_contains "$output" "Linking ~/.config." "state-heavy .config directory is not linked wholesale"
  assert_contains "$output" "Linking ~/.config/myapp/settings.json." "nested config file is linked individually"
  assert_contains "$output" "Linking ~/.vim." "managed link-dir directory is still linked"
  if [[ -L "$home_dir/.config" ]]; then
    test_fail ".config is not a symlink" "Unexpected symlink at [$home_dir/.config]"
  fi
  if [[ ! -L "$home_dir/.config/myapp/settings.json" ]]; then
    test_fail "nested config file is linked" "Missing symlink at [$home_dir/.config/myapp/settings.json]"
  fi
}

test_link_phase_replaces_old_managed_parent_dir_symlinks() {
  local home_dir="$TEST_TMP_DIR/home-parent-symlink"
  local repo_root="$home_dir/src/dotfiles"
  local output=""
  local status=0

  mkdir -p "$repo_root/link-dir/.config/myapp" "$repo_root/link-file/.config/myapp" "$repo_root/copy" "$repo_root/init" "$home_dir"
  cp "$DOTFILES_BIN" "$repo_root/bin.dotfiles"
  mkdir -p "$repo_root/bin"
  mv "$repo_root/bin.dotfiles" "$repo_root/bin/dotfiles"
  chmod +x "$repo_root/bin/dotfiles"

  printf 'runtime state\n' >"$repo_root/link-dir/.config/myapp/state.json"
  printf 'managed config\n' >"$repo_root/link-file/.config/myapp/settings.json"
  ln -s "$repo_root/link-dir/.config" "$home_dir/.config"

  capture_command output status env HOME="$home_dir" bash "$repo_root/bin/dotfiles" --link

  assert_status "0" "$status" "dotfiles --link succeeds"
  assert_contains "$output" "Backing up managed directory link ~/.config." "old managed parent symlink is backed up"
  if [[ -L "$home_dir/.config" ]]; then
    test_fail ".config is replaced with a directory" "Unexpected symlink at [$home_dir/.config]"
  fi
  if [[ ! -L "$home_dir/.config/myapp/settings.json" ]]; then
    test_fail "nested config file is linked under real parent dir" "Missing symlink at [$home_dir/.config/myapp/settings.json]"
  fi
  if [[ -e "$repo_root/link-dir/.config/myapp/settings.json" || -L "$repo_root/link-dir/.config/myapp/settings.json" ]]; then
    test_fail "nested config is not written back into link-dir" "Unexpected file at [$repo_root/link-dir/.config/myapp/settings.json]"
  fi
}

test_link_phase_replaces_old_parent_symlink_even_when_file_target_matches() {
  local home_dir="$TEST_TMP_DIR/home-parent-symlink-same-file"
  local repo_root="$home_dir/src/dotfiles"
  local output=""
  local status=0

  mkdir -p "$repo_root/link-dir/.cave/agent" "$repo_root/link-file/.cave/agent" "$repo_root/copy" "$repo_root/init" "$home_dir"
  cp "$DOTFILES_BIN" "$repo_root/bin.dotfiles"
  mkdir -p "$repo_root/bin"
  mv "$repo_root/bin.dotfiles" "$repo_root/bin/dotfiles"
  chmod +x "$repo_root/bin/dotfiles"

  printf 'managed model config\n' >"$repo_root/link-file/.cave/agent/models.json"
  ln -s "$repo_root/link-file/.cave/agent/models.json" "$repo_root/link-dir/.cave/agent/models.json"
  ln -s "$repo_root/link-dir/.cave" "$home_dir/.cave"

  capture_command output status env HOME="$home_dir" bash "$repo_root/bin/dotfiles" --link

  assert_status "0" "$status" "dotfiles --link succeeds"
  assert_contains "$output" "Backing up managed directory link ~/.cave." "matching file under old parent symlink still triggers parent backup"
  if [[ -L "$home_dir/.cave" ]]; then
    test_fail ".cave is replaced with a directory" "Unexpected symlink at [$home_dir/.cave]"
  fi
  if [[ ! -L "$home_dir/.cave/agent/models.json" ]]; then
    test_fail "matching nested file is relinked under real parent dir" "Missing symlink at [$home_dir/.cave/agent/models.json]"
  fi
}

setup_tmpdir
run_tests "$@"
