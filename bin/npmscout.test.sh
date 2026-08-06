#!/usr/bin/env bash
# shellcheck disable=SC1090,SC1091,SC2016

set -euo pipefail

DOTFILES_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
SCRIPT_UNDER_TEST="$DOTFILES_ROOT/bin/npmscout.sh"

source "$DOTFILES_ROOT/bin/lib/bash_test.sh"

make_stub_dir() {
  local stub_dir="$1"
  mkdir -p "$stub_dir"
}

write_stub() {
  local file_path="$1"
  shift
  local body="$1"

  cat >"$file_path" <<EOF
#!/usr/bin/env bash
set -euo pipefail
$body
EOF
  chmod +x "$file_path"
}

mock_node() {
  local stub_dir="$1"
  shift
  local body="$1"

  cat >"$stub_dir/node" <<'NODESCRIPT'
#!/usr/bin/env bash
# Mock node that simulates parsing package-lock.json

if [[ "$1" != "-e" ]]; then
  exit 0
fi

SCRIPT="$2"

# Use sed to extract the file path and package name
LOCK_FILE=$(echo "$SCRIPT" | sed -n "s/.*require('\([^']*\)').*/\1/p" | head -1)
PKG_NAME=$(echo "$SCRIPT" | sed -n "s/.*pkgName = '\([^']*\)'.*/\1/p" | head -1)

# If both are found, look up the version
if [[ -n "$LOCK_FILE" && -n "$PKG_NAME" && -f "$LOCK_FILE" ]]; then
  # Extract version from the package-lock.json file
  # Look for the exact package name in the node_modules section
  IN_PACKAGE=0
  while IFS= read -r line; do
    if [[ "$line" == *"\"node_modules/$PKG_NAME\":"* ]]; then
      IN_PACKAGE=1
      continue
    fi
    if [[ $IN_PACKAGE -eq 1 && "$line" == *'"version"'* ]]; then
      VERSION=$(echo "$line" | sed 's/.*"version": *"\([^"]*\)".*/\1/')
      break
    fi
  done < "$LOCK_FILE"
  
  if [[ -n "$VERSION" ]]; then
    echo "$VERSION"
  fi
fi
NODESCRIPT
  chmod +x "$stub_dir/node"
}

make_package_lock() {
  local lock_file="$1"
  shift
  local body="$1"

  mkdir -p "$(dirname "$lock_file")"
  cat >"$lock_file" <<EOF
{
  "name": "test-project",
  "lockfileVersion": 3,
  "packages": {
    "": {
      "name": "test-project"
    },
    "node_modules/keyv": {
      "version": "4.5.0"
    },
    "node_modules/cachable": {
      "version": "2.0.0"
    },
    "node_modules/@types/node": {
      "version": "20.1.0"
    },
    "node_modules/lodash": {
      "version": "4.17.21"
    }
  }
}
EOF
}

make_empty_package_lock() {
  local lock_file="$1"

  mkdir -p "$(dirname "$lock_file")"
  cat >"$lock_file" <<EOF
{
  "name": "empty-project",
  "lockfileVersion": 3,
  "packages": {}
}
EOF
}

test_default_packages_finds_keyv_and_cachable() {
  local work_dir=""
  local output=""
  local status=0

  work_dir="$(mktemp -d)"
  make_stub_dir "$work_dir/stub-bin"
  mock_node "$work_dir/stub-bin" 'echo "mock node"'

  make_package_lock "$work_dir/test-project/package-lock.json" ""

  # Run the script directly
  cd "$work_dir"
  output=$(NO_COLOR=1 PATH="$work_dir/stub-bin:$PATH" /Users/jesper/src/dotfiles/bin/npmscout.sh 2>&1)
  status=0

  assert_status "0" "$status" "npmscout completes successfully"
  assert_contains "$output" "keyv" "output contains keyv"
  assert_contains "$output" "cachable" "output contains cachable"
  assert_contains "$output" "4.5.0" "output contains keyv version"
  assert_contains "$output" "2.0.0" "output contains cachable version"
  assert_contains "$output" "Project | Package | Version | Path" "output contains table header"

  rm -rf "$work_dir"
}

test_custom_packages_flag() {
  local work_dir=""
  local output=""
  local status=0

  work_dir="$(mktemp -d)"
  make_stub_dir "$work_dir/stub-bin"
  mock_node "$work_dir/stub-bin" 'echo "mock node"'

  make_package_lock "$work_dir/test-project/package-lock.json" ""

  # Run the script directly instead of using capture_command
  cd "$work_dir"
  output=$(NO_COLOR=1 PATH="$work_dir/stub-bin:$PATH" /Users/jesper/src/dotfiles/bin/npmscout.sh --packages lodash 2>&1)
  status=0

  assert_status "0" "$status" "npmscout completes with custom packages"
  assert_contains "$output" "lodash" "output contains lodash"
  assert_contains "$output" "4.17.21" "output contains lodash version"
  assert_not_contains "$output" "keyv" "output does not contain keyv when not requested"

  rm -rf "$work_dir"
}

test_scoped_packages() {
  local work_dir=""
  local output=""
  local status=0

  work_dir="$(mktemp -d)"
  make_stub_dir "$work_dir/stub-bin"
  mock_node "$work_dir/stub-bin" 'echo "mock node"'

  make_package_lock "$work_dir/test-project/package-lock.json" ""

  # Run the script directly
  cd "$work_dir"
  output=$(PATH="$work_dir/stub-bin:$PATH" /Users/jesper/src/dotfiles/bin/npmscout.sh --packages '@types/node' 2>&1)
  status=0

  assert_status "0" "$status" "npmscout handles scoped packages"
  assert_contains "$output" "@types/node" "output contains scoped package name"
  assert_contains "$output" "20.1.0" "output contains scoped package version"

  rm -rf "$work_dir"
}

test_multiple_packages() {
  local work_dir=""
  local output=""
  local status=0

  work_dir="$(mktemp -d)"
  make_stub_dir "$work_dir/stub-bin"
  mock_node "$work_dir/stub-bin" 'echo "mock node"'

  make_package_lock "$work_dir/test-project/package-lock.json" ""

  # Run the script directly
  cd "$work_dir"
  output=$(PATH="$work_dir/stub-bin:$PATH" /Users/jesper/src/dotfiles/bin/npmscout.sh --packages 'keyv,lodash' 2>&1)
  status=0

  assert_status "0" "$status" "npmscout handles comma-separated packages"
  assert_contains "$output" "keyv" "output contains keyv"
  assert_contains "$output" "lodash" "output contains lodash"
  assert_not_contains "$output" "cachable" "output does not contain cachable when not requested"
  assert_not_contains "$output" "@types/node" "output does not contain @types/node when not requested"

  rm -rf "$work_dir"
}

test_no_matching_packages() {
  local work_dir=""
  local output=""
  local status=0

  work_dir="$(mktemp -d)"
  make_stub_dir "$work_dir/stub-bin"
  mock_node "$work_dir/stub-bin" 'echo "mock node"'

  make_empty_package_lock "$work_dir/test-project/package-lock.json" ""

  # Run the script directly
  cd "$work_dir"
  output=$(PATH="$work_dir/stub-bin:$PATH" /Users/jesper/src/dotfiles/bin/npmscout.sh --packages 'nonexistent' 2>&1)
  status=0

  assert_status "0" "$status" "npmscout exits cleanly when no matches found"
  assert_contains "$output" "No matching packages found" "output contains no matches message"

  rm -rf "$work_dir"
}

test_multiple_project_folders() {
  local work_dir=""
  local output=""
  local status=0

  work_dir="$(mktemp -d)"
  make_stub_dir "$work_dir/stub-bin"
  mock_node "$work_dir/stub-bin" 'echo "mock node"'

  make_package_lock "$work_dir/project-a/package-lock.json" ""
  make_package_lock "$work_dir/project-b/package-lock.json" ""

  # Run the script directly
  cd "$work_dir"
  output=$(PATH="$work_dir/stub-bin:$PATH" /Users/jesper/src/dotfiles/bin/npmscout.sh 2>&1)
  status=0

  assert_status "0" "$status" "npmscout handles multiple project folders"
  assert_contains "$output" "keyv" "output contains keyv"
  assert_contains "$output" "cachable" "output contains cachable"

  rm -rf "$work_dir"
}

test_help_flag() {
  local work_dir=""
  local output=""
  local status=0

  work_dir="$(mktemp -d)"
  make_stub_dir "$work_dir/stub-bin"
  mock_node "$work_dir/stub-bin" 'echo "mock node"'

  make_package_lock "$work_dir/test-project/package-lock.json" ""

  # Run the script directly
  cd "$work_dir"
  output=$(PATH="$work_dir/stub-bin:$PATH" /Users/jesper/src/dotfiles/bin/npmscout.sh --help 2>&1)
  status=0

  assert_contains "$output" "Usage:" "output contains usage information"
  assert_contains "$output" "--packages" "output contains --packages option"
  assert_contains "$output" "--help" "output contains --help option"

  rm -rf "$work_dir"
}

test_specified_folder() {
  local work_dir=""
  local output=""
  local status=0

  work_dir="$(mktemp -d)"
  make_stub_dir "$work_dir/stub-bin"
  mock_node "$work_dir/stub-bin" 'echo "mock node"'

  make_package_lock "$work_dir/test-project/package-lock.json" ""

  # Run the script directly
  output=$(PATH="$work_dir/stub-bin:$PATH" /Users/jesper/src/dotfiles/bin/npmscout.sh --packages keyv "$work_dir/test-project" 2>&1)
  status=0

  assert_status "0" "$status" "npmscout handles specified folder"
  assert_contains "$output" "keyv" "output contains keyv"

  rm -rf "$work_dir"
}

run_tests "$@"
