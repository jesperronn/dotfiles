#!/usr/bin/env bash
# shellcheck disable=SC1090,SC1091

set -euo pipefail

DOTFILES_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
DOCTOR_BIN="$DOTFILES_ROOT/bin/rehome_doctor"

source "$DOTFILES_ROOT/bin/lib/bash_test.sh"

TEST_TMP_DIR=""

setup_tmpdir() {
  TEST_TMP_DIR="$(mktemp -d)"
  trap 'rm -rf "$TEST_TMP_DIR"' EXIT
}

make_repo_root() {
  local repo_root="$1"
  mkdir -p "$repo_root/link-file" "$repo_root/link-dir" "$repo_root/copy"
}

run_doctor() {
  local home_dir="$1"
  local repo_root="$2"
  shift 2
  NO_COLOR=1 env HOME="$home_dir" REHOME_REPO_ROOT="$repo_root" "$DOCTOR_BIN" --dir "$home_dir" "$@"
}

test_help_output() {
  local output="" status=0
  capture_command output status "$DOCTOR_BIN" --help
  assert_status "0" "$status" "rehome_doctor --help succeeds"
  assert_contains "$output" "Usage: rehome_doctor [options]" "help shows usage line"
  assert_contains "$output" "--interactive" "help mentions --interactive"
  assert_contains "$output" "--all" "help mentions --all"
  assert_contains "$output" "Candidate" "help explains candidate symbol"
  assert_contains "$output" "Managed" "help explains managed symbol"
}

test_symlink_into_repo_is_managed() {
  local home_dir="$TEST_TMP_DIR/home-managed"
  local repo_root="$TEST_TMP_DIR/repo-managed"
  local output="" status=0

  make_repo_root "$repo_root"
  repo_root="$(cd "$repo_root" && pwd -P)"
  mkdir -p "$home_dir"
  printf 'data\n' > "$repo_root/link-file/.bashrc"
  ln -s "$repo_root/link-file/.bashrc" "$home_dir/.bashrc"

  capture_command output status run_doctor "$home_dir" "$repo_root"
  assert_status "0" "$status" "doctor exits 0 with managed symlink"
  assert_contains "$output" "MANAGED" "managed section appears"
  assert_contains "$output" ".bashrc" "managed item is listed"
  assert_not_contains "$output" "CANDIDATES" "managed item does not appear as a candidate"
}

test_real_file_is_candidate() {
  local home_dir="$TEST_TMP_DIR/home-cand"
  local repo_root="$TEST_TMP_DIR/repo-cand"
  local output="" status=0

  make_repo_root "$repo_root"
  mkdir -p "$home_dir"
  printf '[user]\n  name = Test\n' > "$home_dir/.gitconfig_extra"

  capture_command output status run_doctor "$home_dir" "$repo_root"
  assert_status "0" "$status" "doctor exits 0 with unmanaged file"
  assert_contains "$output" "CANDIDATES" "candidates section appears"
  assert_contains "$output" ".gitconfig_extra" "unmanaged file listed as candidate"
}

test_real_dir_is_candidate() {
  local home_dir="$TEST_TMP_DIR/home-dircandidate"
  local repo_root="$TEST_TMP_DIR/repo-dircandidate"
  local output="" status=0

  make_repo_root "$repo_root"
  mkdir -p "$home_dir/.myapp"
  printf 'setting=1\n' > "$home_dir/.myapp/config"

  capture_command output status run_doctor "$home_dir" "$repo_root"
  assert_status "0" "$status" "doctor exits 0 with unmanaged dir"
  assert_contains "$output" ".myapp" "unmanaged dir listed as candidate"
  assert_contains "$output" "dir," "candidate shows type as dir"
}

test_copy_managed_file_is_managed() {
  local home_dir="$TEST_TMP_DIR/home-copy"
  local repo_root="$TEST_TMP_DIR/repo-copy"
  local output="" status=0

  make_repo_root "$repo_root"
  repo_root="$(cd "$repo_root" && pwd -P)"
  printf '[user]\n  email = test@example.com\n' > "$repo_root/copy/.gitconfig_local"
  mkdir -p "$home_dir"
  printf '[user]\n  email = test@example.com\n' > "$home_dir/.gitconfig_local"

  capture_command output status run_doctor "$home_dir" "$repo_root"
  assert_status "0" "$status" "doctor exits 0 with copy-managed file"
  assert_contains "$output" ".gitconfig_local" "copy-managed file appears in output"
  assert_contains "$output" "copy/.gitconfig_local" "copy-managed file shows copy/ source"
  assert_not_contains "$output" "CANDIDATES" "copy-managed file not listed as candidate"
}

test_skip_items_hidden_by_default() {
  local home_dir="$TEST_TMP_DIR/home-skip"
  local repo_root="$TEST_TMP_DIR/repo-skip"
  local output="" status=0

  make_repo_root "$repo_root"
  mkdir -p "$home_dir"
  printf 'history\n' > "$home_dir/.bash_history"
  printf 'history\n' > "$home_dir/.zsh_history"
  printf 'junk\n' > "$home_dir/.DS_Store"

  capture_command output status run_doctor "$home_dir" "$repo_root"
  assert_status "0" "$status" "doctor exits 0 with only skipped items"
  assert_not_contains "$output" ".bash_history" "bash_history hidden by default"
  assert_not_contains "$output" ".zsh_history" "zsh_history hidden by default"
  assert_not_contains "$output" ".DS_Store" "DS_Store hidden by default"
}

test_all_flag_promotes_skip_items_to_candidates() {
  local home_dir="$TEST_TMP_DIR/home-showall"
  local repo_root="$TEST_TMP_DIR/repo-showall"
  local output="" status=0

  make_repo_root "$repo_root"
  mkdir -p "$home_dir"
  printf 'history\n' > "$home_dir/.bash_history"

  capture_command output status run_doctor "$home_dir" "$repo_root" --all
  assert_status "0" "$status" "doctor exits 0 with --all"
  assert_contains "$output" "CANDIDATES" "candidates section appears with --all"
  assert_contains "$output" ".bash_history" "bash_history promoted to candidate with --all"
}

test_symlink_elsewhere_is_other() {
  local home_dir="$TEST_TMP_DIR/home-other"
  local repo_root="$TEST_TMP_DIR/repo-other"
  local other_dir="$TEST_TMP_DIR/elsewhere"
  local output="" status=0

  make_repo_root "$repo_root"
  mkdir -p "$home_dir" "$other_dir"
  printf 'data\n' > "$other_dir/somefile"
  ln -s "$other_dir/somefile" "$home_dir/.somelink"

  capture_command output status run_doctor "$home_dir" "$repo_root"
  assert_status "0" "$status" "doctor exits 0 with other symlink"
  assert_contains "$output" "OTHER" "other section appears"
  assert_contains "$output" ".somelink" "other symlink is listed"
  assert_not_contains "$output" "CANDIDATES" "other symlink not listed as candidate"
}

test_summary_counts_are_accurate() {
  local home_dir="$TEST_TMP_DIR/home-counts"
  local repo_root="$TEST_TMP_DIR/repo-counts"
  local output="" status=0

  make_repo_root "$repo_root"
  repo_root="$(cd "$repo_root" && pwd -P)"
  mkdir -p "$home_dir"

  # 1 managed symlink
  printf 'data\n' > "$repo_root/link-file/.vimrc"
  ln -s "$repo_root/link-file/.vimrc" "$home_dir/.vimrc"
  # 1 candidate
  printf 'settings\n' > "$home_dir/.ripgreprc"
  # 1 other symlink
  printf 'x\n' > "$TEST_TMP_DIR/external"
  ln -s "$TEST_TMP_DIR/external" "$home_dir/.external"

  capture_command output status run_doctor "$home_dir" "$repo_root"
  assert_status "0" "$status" "doctor exits 0 with mixed items"
  assert_contains "$output" "1 managed" "managed count is 1"
  assert_contains "$output" "1 candidates" "candidate count is 1"
  assert_contains "$output" "1 other" "other count is 1"
}

setup_tmpdir
run_tests "$@"
