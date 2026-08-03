#!/usr/bin/env bash
# shellcheck disable=SC1090,SC1091

set -euo pipefail

DOTFILES_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
REHOME_BIN="$DOTFILES_ROOT/bin/rehome"

source "$DOTFILES_ROOT/bin/lib/bash_test.sh"

TEST_TMP_DIR=""

setup_tmpdir() {
  TEST_TMP_DIR="$(mktemp -d)"
  trap 'rm -rf "$TEST_TMP_DIR"' EXIT
}

make_repo_root() {
  local repo_root="$1"

  mkdir -p "$repo_root/link-file" "$repo_root/link-dir"
}

run_rehome() {
  local home_dir="$1"
  local repo_root="$2"
  shift 2

  env HOME="$home_dir" REHOME_REPO_ROOT="$repo_root" "$REHOME_BIN" "$@"
}

test_help_output() {
  local output=""
  local status=0

  capture_command output status "$REHOME_BIN" --help
  assert_status "0" "$status" "rehome --help succeeds"
  assert_contains "$output" "Usage: rehome [options] [path]" "help lists the command usage"
  assert_contains "$output" "REHOME_DEFAULT_FILE_DEST" "help explains file destination defaults"
  assert_contains "$output" "REHOME_DEFAULT_FOLDER_DEST" "help explains folder destination defaults"
  assert_contains "$output" "--repo-root PATH" "help explains repo-root"
}

test_rehome_file_into_custom_repo() {
  local home_dir="$TEST_TMP_DIR/home-file"
  local repo_root="$TEST_TMP_DIR/repo"
  local source_file=""
  local repo_file=""
  local output=""
  local status=0

  mkdir -p "$home_dir/.config/myapp"
  make_repo_root "$repo_root"
  repo_root="$(cd "$repo_root" && pwd -P)"
  source_file="$home_dir/.config/myapp/settings.json"
  printf '{"mode":"local"}\n' >"$source_file"
  repo_file="$repo_root/link-file/.config/myapp/settings.json"

  capture_command output status run_rehome "$home_dir" "$repo_root" "$source_file"
  assert_status "0" "$status" "rehome succeeds for files"
  assert_contains "$output" "into link-file/.config/myapp/settings.json and linked it back." "rehome reports the file move"
  if ! test -L "$source_file"; then
    test_fail "original file path becomes a symlink" "Expected symlink at [$source_file]"
  fi
  assert_eq "$repo_file" "$(readlink "$source_file")" "file symlink points at the repo copy"
  assert_eq '{"mode":"local"}' "$(cat "$repo_file")" "file contents move into link-file"
}

test_rehome_folder_into_custom_repo() {
  local home_dir="$TEST_TMP_DIR/home-dir"
  local repo_root="$TEST_TMP_DIR/repo"
  local source_dir=""
  local repo_dir=""
  local output=""
  local status=0

  mkdir -p "$home_dir/Documents/Workspace"
  make_repo_root "$repo_root"
  repo_root="$(cd "$repo_root" && pwd -P)"
  source_dir="$home_dir/Documents/Workspace"
  printf 'workspace\n' >"$source_dir/README.txt"
  repo_dir="$repo_root/link-dir/Documents/Workspace"

  capture_command output status run_rehome "$home_dir" "$repo_root" "$source_dir"
  assert_status "0" "$status" "rehome succeeds for folders"
  assert_contains "$output" "into link-dir/Documents/Workspace and linked it back." "rehome reports the folder move"
  if ! test -L "$source_dir"; then
    test_fail "original folder path becomes a symlink" "Expected symlink at [$source_dir]"
  fi
  assert_eq "$repo_dir" "$(readlink "$source_dir")" "folder symlink points at the repo copy"
  assert_eq 'workspace' "$(cat "$repo_dir/README.txt")" "folder contents move into link-dir"
}

test_rehome_relative_target_outside_home_uses_cwd_path() {
  local home_dir="$TEST_TMP_DIR/home-relative"
  local repo_root="$TEST_TMP_DIR/repo"
  local work_dir="$TEST_TMP_DIR/work"
  local output=""
  local status=0

  mkdir -p "$home_dir"
  make_repo_root "$repo_root"
  repo_root="$(cd "$repo_root" && pwd -P)"
  mkdir -p "$work_dir"
  printf 'payload\n' >"$work_dir/note.txt"

  capture_command output status bash -lc "cd \"$work_dir\" && env HOME=\"$home_dir\" REHOME_REPO_ROOT=\"$repo_root\" \"$REHOME_BIN\" note.txt"
  assert_status "0" "$status" "rehome succeeds for relative targets"
  assert_contains "$output" "into link-file/note.txt and linked it back." "rehome keeps relative cwd paths"
  if ! test -L "$work_dir/note.txt"; then
    test_fail "relative target becomes a symlink" "Expected symlink at [$work_dir/note.txt]"
  fi
  assert_eq "$repo_root/link-file/note.txt" "$(readlink "$work_dir/note.txt")" "relative target points at repo copy"
}

test_rehome_uses_env_default_destinations() {
  local home_dir="$TEST_TMP_DIR/home-defaults"
  local repo_root="$TEST_TMP_DIR/repo"
  local source_file=""
  local source_dir=""
  local output=""
  local status=0

  mkdir -p "$home_dir/.config/myapp" "$home_dir/Documents/Workspace"
  make_repo_root "$repo_root"
  repo_root="$(cd "$repo_root" && pwd -P)"
  source_file="$home_dir/.config/myapp/settings.json"
  source_dir="$home_dir/Documents/Workspace"
  printf '{"mode":"env"}\n' >"$source_file"
  printf 'workspace\n' >"$source_dir/README.txt"

  capture_command output status bash -lc "
    cd \"$DOTFILES_ROOT\"
    env \
      HOME=\"$home_dir\" \
      REHOME_REPO_ROOT=\"$repo_root\" \
      REHOME_DEFAULT_FILE_DEST=\"file-store\" \
      REHOME_DEFAULT_FOLDER_DEST=\"folder-store\" \
      \"$REHOME_BIN\" \"$source_file\"
  "
  assert_status "0" "$status" "rehome honors file destination env vars"
  assert_contains "$output" "into file-store/.config/myapp/settings.json and linked it back." "file env destination is used"
  assert_eq "$repo_root/file-store/.config/myapp/settings.json" "$(readlink "$source_file")" "file env destination is the symlink target"

  capture_command output status bash -lc "
    cd \"$DOTFILES_ROOT\"
    env \
      HOME=\"$home_dir\" \
      REHOME_REPO_ROOT=\"$repo_root\" \
      REHOME_DEFAULT_FILE_DEST=\"file-store\" \
      REHOME_DEFAULT_FOLDER_DEST=\"folder-store\" \
      \"$REHOME_BIN\" \"$source_dir\"
  "
  assert_status "0" "$status" "rehome honors folder destination env vars"
  assert_contains "$output" "into folder-store/Documents/Workspace and linked it back." "folder env destination is used"
  assert_eq "$repo_root/folder-store/Documents/Workspace" "$(readlink "$source_dir")" "folder env destination is the symlink target"
}

test_rehome_missing_path_fails_cleanly() {
  local home_dir="$TEST_TMP_DIR/home-missing"
  local repo_root="$TEST_TMP_DIR/repo"
  local missing_path="$home_dir/.config/unknown.yml"
  local output=""
  local status=0

  make_repo_root "$repo_root"
  mkdir -p "$home_dir"

  capture_command output status run_rehome "$home_dir" "$repo_root" "$missing_path"
  assert_status "1" "$status" "rehome fails for missing paths"
  assert_contains "$output" "Missing path:" "missing-path error is clear"
}

test_rehome_revert_file() {
  local home_dir="$TEST_TMP_DIR/home-revert-file"
  local repo_root="$TEST_TMP_DIR/repo-revert-file"
  local source_file="$home_dir/.config/myapp/settings.json"
  local output=""
  local status=0

  mkdir -p "$(dirname "$source_file")"
  make_repo_root "$repo_root"
  printf '{"mode":"revert"}\n' >"$source_file"
  run_rehome "$home_dir" "$repo_root" "$source_file"

  capture_command output status run_rehome "$home_dir" "$repo_root" --revert "$source_file"
  assert_status "0" "$status" "rehome --revert succeeds for files"
  assert_contains "$output" "Reverted $source_file from link-file/.config/myapp/settings.json." "revert reports the file move"
  if [[ -L "$source_file" ]]; then
    test_fail "reverted file is no longer a symlink" "Expected a regular file at [$source_file]"
  fi
  assert_eq '{"mode":"revert"}' "$(cat "$source_file")" "reverted file retains its contents"
}

test_rehome_revert_requires_managed_symlink() {
  local home_dir="$TEST_TMP_DIR/home-revert-invalid"
  local repo_root="$TEST_TMP_DIR/repo-revert-invalid"
  local source_file="$home_dir/file.txt"
  local output=""
  local status=0

  mkdir -p "$home_dir"
  make_repo_root "$repo_root"
  printf 'payload\n' >"$source_file"

  capture_command output status run_rehome "$home_dir" "$repo_root" --revert "$source_file"
  assert_status "1" "$status" "revert rejects a regular file"
  assert_contains "$output" "Target is not a symlink:" "revert explains invalid target"
}

setup_tmpdir
run_tests "$@"
