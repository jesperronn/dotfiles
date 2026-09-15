#!/usr/bin/env bash
# shellcheck disable=SC1090,SC1091,SC2016

set -euo pipefail

DOTFILES_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
VERIFY_OLLAMA_BIN="$DOTFILES_ROOT/bin/verify_ollama"
VERIFY_OLLAMA_PLIST="$DOTFILES_ROOT/link-file/Library/LaunchAgents/com.jesperronn.ollama-keep-alive.plist"
AI_TOOLS_FILE="$DOTFILES_ROOT/source/91_ai_tools.sh"

source "$DOTFILES_ROOT/bin/lib/bash_test.sh"
source "$VERIFY_OLLAMA_BIN" source

# Global cleanup: remove test temp directories
cleanup_test_temps() {
  rm -rf /tmp/test_*_$$ 2>/dev/null || true
}
trap cleanup_test_temps EXIT

# Fast temp dir creation without mktemp overhead
_make_test_tmpdir() {
  local name="$1"
  local dir="/tmp/test_${name}_$$"
  rm -rf "$dir" 2>/dev/null || true
  mkdir -p "$dir"
  printf '%s' "$dir"
}

reset_state() {
  true
}

# Fast stub writer: use printf instead of cat <<'EOF' to reduce overhead
fast_stub() {
  local path="$1" body="$2"
  printf '#!/usr/bin/env bash\nset -euo pipefail\n%s\n' "$body" >"$path"
  chmod +x "$path"
}

# Helper to create simple one-liner stubs
simple_stub() {
  local path="$1"
  shift
  {
    printf '#!/usr/bin/env bash\n'
    printf '%s\n' "$@"
  } >"$path"
  chmod +x "$path"
}

# Helper to create plist files efficiently
make_plist_with_env() {
  local path="$1" keep_alive="$2" context_length="$3"
  printf '<?xml version="1.0" encoding="UTF-8"?>\n<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">\n<plist version="1.0">\n<dict>\n  <key>EnvironmentVariables</key>\n  <dict>\n    <key>OLLAMA_KEEP_ALIVE</key>\n    <string>%s</string>\n    <key>OLLAMA_CONTEXT_LENGTH</key>\n    <string>%s</string>\n  </dict>\n</dict>\n</plist>\n' "$keep_alive" "$context_length" >"$path"
}

test_desired_keep_alive_defaults_to_30m() {
  local output=""
  local status=0

  capture_command output status verify_ollama_desired_keep_alive
  assert_status "0" "$status" "desired keep-alive helper succeeds"
  assert_eq "30m" "$output" "desired keep-alive defaults to 30m"
}

test_desired_context_length_defaults_to_524288() {
  local output=""
  local status=0

  capture_command output status verify_ollama_desired_context_length
  assert_status "0" "$status" "desired context-length helper succeeds"
  assert_eq "524288" "$output" "desired context length defaults to 524288"
}

test_run_main_applies_launchctl_value_on_macos() {
  local tmp_dir=""
  local plist_path=""
  local output=""
  local status=0

  tmp_dir="$(_make_test_tmpdir "apply_launchctl")"
  plist_path="$tmp_dir/homebrew.mxcl.ollama.plist"
  make_plist_with_env "$plist_path" "30m" "524288"

  mkdir -p "$tmp_dir/bin"
  simple_stub "$tmp_dir/bin/uname" "printf 'Darwin\n'"
  simple_stub "$tmp_dir/bin/pgrep" "printf '61055\n'"
  simple_stub "$tmp_dir/bin/ps" "printf '/opt/homebrew/opt/ollama/bin/ollama serve\n'"
  printf '#!/usr/bin/env bash\nset -euo pipefail\n[[ "$1" == "setenv" ]] && { printf "%%s %%s %%s\n" "$1" "$2" "$3" >>"${TEST_LAUNCHCTL_LOG:?}"; exit 0; }\n[[ "$1" == "getenv" ]] && exit 0\nexit 1\n' >"$tmp_dir/bin/launchctl"
  chmod +x "$tmp_dir/bin/launchctl"
  printf '#!/usr/bin/env bash\nset -euo pipefail\n[[ "$2" == *"OLLAMA_KEEP_ALIVE"* ]] && printf "30m\n" && exit 0\n[[ "$2" == *"OLLAMA_CONTEXT_LENGTH"* ]] && printf "524288\n" && exit 0\nexit 1\n' >"$tmp_dir/bin/PlistBuddy"
  chmod +x "$tmp_dir/bin/PlistBuddy"

  TEST_LAUNCHCTL_LOG="$tmp_dir/launchctl.log" \
    OLLAMA_HOMEBREW_PLIST="$plist_path" \
    OLLAMA_PLIST_BUDDY="$tmp_dir/bin/PlistBuddy" \
    OLLAMA_PROCESS_NAME=ollama \
    PATH="$tmp_dir/bin:$PATH" \
    capture_command output status run_main

  local launchctl_log_contents="$(cat "$tmp_dir/launchctl.log")"
  assert_status "0" "$status" "verify_ollama succeeds on macOS"
  assert_contains "$output" "Set OLLAMA_KEEP_ALIVE=30m for this login session" "verify_ollama reports the applied value"
  assert_contains "$output" "Set OLLAMA_CONTEXT_LENGTH=524288 for this login session" "verify_ollama reports the applied context value"
  assert_contains "$output" "Restart Ollama and any VS Code windows" "verify_ollama explains restart requirement"
  assert_contains "$launchctl_log_contents" "setenv OLLAMA_KEEP_ALIVE 30m" "verify_ollama writes launchctl env"
  assert_contains "$launchctl_log_contents" "setenv OLLAMA_CONTEXT_LENGTH 524288" "verify_ollama writes launchctl context env"
  rm -rf "$tmp_dir"
  true
}

test_run_main_fails_when_homebrew_plist_is_wrong() {
  local tmp_dir=""
  local plist_path=""
  local output=""
  local status=0

  tmp_dir="$(_make_test_tmpdir "fail_wrong_plist")"
  plist_path="$tmp_dir/homebrew.mxcl.ollama.plist"
  make_plist_with_env "$plist_path" "5m" "131072"

  mkdir -p "$tmp_dir/bin"
  simple_stub "$tmp_dir/bin/uname" "printf 'Darwin\n'"
  printf '#!/usr/bin/env bash\nset -euo pipefail\n[[ "$2" == *"OLLAMA_KEEP_ALIVE"* ]] && printf "5m\n" && exit 0\nexit 1\n' >"$tmp_dir/bin/PlistBuddy"
  chmod +x "$tmp_dir/bin/PlistBuddy"

  TEST_LAUNCHCTL_LOG="$tmp_dir/launchctl.log" \
    OLLAMA_HOMEBREW_PLIST="$plist_path" \
    OLLAMA_PLIST_BUDDY="$tmp_dir/bin/PlistBuddy" \
    OLLAMA_PROCESS_NAME=ollama \
    PATH="$tmp_dir/bin:$PATH" \
    capture_command output status run_main

  assert_status "1" "$status" "verify_ollama fails when homebrew plist is wrong"
  assert_contains "$output" "does not set OLLAMA_KEEP_ALIVE=30m" "verify_ollama reports plist mismatch"
  assert_contains "$output" "next step: bin/verify_ollama --fix" "verify_ollama provides plist fix next step"
  rm -rf "$tmp_dir"
}

test_run_main_fails_when_ollama_is_not_running() {
  local tmp_dir=""
  local plist_path=""
  local output=""
  local status=0

  tmp_dir="$(_make_test_tmpdir "fail_not_running")"
  plist_path="$tmp_dir/homebrew.mxcl.ollama.plist"
  make_plist_with_env "$plist_path" "30m" "524288"

  mkdir -p "$tmp_dir/bin"
  simple_stub "$tmp_dir/bin/uname" "printf 'Darwin\n'"
  printf '#!/usr/bin/env bash\nset -euo pipefail\n[[ "$2" == *"OLLAMA_KEEP_ALIVE"* ]] && printf "30m\n" && exit 0\n[[ "$2" == *"OLLAMA_CONTEXT_LENGTH"* ]] && printf "524288\n" && exit 0\nexit 1\n' >"$tmp_dir/bin/PlistBuddy"
  simple_stub "$tmp_dir/bin/pgrep" "exit 1"
  chmod +x "$tmp_dir/bin/PlistBuddy"

  TEST_LAUNCHCTL_LOG="$tmp_dir/launchctl.log" \
    OLLAMA_HOMEBREW_PLIST="$plist_path" \
    OLLAMA_PLIST_BUDDY="$tmp_dir/bin/PlistBuddy" \
    OLLAMA_PROCESS_NAME=ollama \
    PATH="$tmp_dir/bin:$PATH" \
    capture_command output status run_main

  assert_status "1" "$status" "verify_ollama fails when ollama is not running"
  assert_contains "$output" "Ollama is not running" "verify_ollama reports missing process"
  assert_contains "$output" "next step: brew services start ollama" "verify_ollama suggests the start command"
  rm -rf "$tmp_dir"
}

test_run_main_fix_repairs_homebrew_plist_and_restarts() {
  local tmp_dir=""
  local plist_path=""
  local output=""
  local status=0

  tmp_dir="$(_make_test_tmpdir "fix_repairs_plist")"
  plist_path="$tmp_dir/homebrew.mxcl.ollama.plist"
  make_plist_with_env "$plist_path" "5m" "131072"

  mkdir -p "$tmp_dir/bin"
  simple_stub "$tmp_dir/bin/uname" "printf 'Darwin\n'"
  simple_stub "$tmp_dir/bin/pgrep" "printf '61055\n'"
  simple_stub "$tmp_dir/bin/ps" "printf '/opt/homebrew/opt/ollama/bin/ollama serve\n'"
  printf '#!/usr/bin/env bash\nset -euo pipefail\n[[ "$1" == "setenv" ]] && { printf "%%s %%s %%s\n" "$1" "$2" "$3" >>"${TEST_LAUNCHCTL_LOG:?}"; exit 0; }\n[[ "$1" == "getenv" ]] && exit 0\n' >"$tmp_dir/bin/launchctl"
  chmod +x "$tmp_dir/bin/launchctl"
  {
    printf '#!/usr/bin/env bash\nset -euo pipefail\np="${@: -1}"\ncase "$2" in\n'
    printf '  *"Print"*"KEEP_ALIVE"*) grep -q "30m" "$p" && printf "30m\n" || printf "5m\n" ;;\n'
    printf '  *"Print"*"CONTEXT_LENGTH"*) grep -q "524288" "$p" && printf "524288\n" || printf "131072\n" ;;\n'
    printf '  *"Set"*"KEEP_ALIVE"*) sed -i "" "s/5m/30m/g" "$p" ;;\n'
    printf '  *"Set"*"CONTEXT_LENGTH"*) sed -i "" "s/131072/524288/g" "$p" ;;\n'
    printf '  *"Add"*) true ;;\n'
    printf 'esac\n'
  } >"$tmp_dir/bin/PlistBuddy"
  chmod +x "$tmp_dir/bin/PlistBuddy"

  TEST_LAUNCHCTL_LOG="$tmp_dir/launchctl.log" \
    OLLAMA_HOMEBREW_PLIST="$plist_path" \
    OLLAMA_PLIST_BUDDY="$tmp_dir/bin/PlistBuddy" \
    OLLAMA_BREW_CMD="$tmp_dir/bin/brew" \
    OLLAMA_PROCESS_NAME=ollama \
    PATH="$tmp_dir/bin:$PATH" \
    capture_command output status run_main --fix

  local plist_contents="$(cat "$plist_path")"
  assert_status "0" "$status" "verify_ollama --fix succeeds"
  assert_contains "$output" "Homebrew Ollama plist" "verify_ollama --fix warns about the bad plist"
  assert_contains "$output" "editing: adding \"OLLAMA_KEEP_ALIVE=30m\"" "verify_ollama --fix reports the edit"
  assert_contains "$output" "editing: adding \"OLLAMA_CONTEXT_LENGTH=524288\"" "verify_ollama --fix reports the context edit"
  assert_contains "$output" "done, edit successful" "verify_ollama --fix confirms the edit"
  assert_contains "$output" "next step: brew services restart ollama" "verify_ollama --fix gives the restart next step"
  assert_contains "$plist_contents" "30m" "verify_ollama --fix repairs the plist"
  assert_contains "$plist_contents" "524288" "verify_ollama --fix repairs the context length"
  rm -rf "$tmp_dir"
}

test_run_main_fix_survives_launchctl_setenv_failure() {
  local tmp_dir=""
  local plist_path=""
  local output=""
  local status=0

  tmp_dir="$(_make_test_tmpdir "fix_survives_failure")"
  plist_path="$tmp_dir/homebrew.mxcl.ollama.plist"
  make_plist_with_env "$plist_path" "5m" "131072"

  mkdir -p "$tmp_dir/bin"
  simple_stub "$tmp_dir/bin/uname" "printf 'Darwin\n'"
  simple_stub "$tmp_dir/bin/pgrep" "printf '61055\n'"
  simple_stub "$tmp_dir/bin/ps" "printf '/opt/homebrew/opt/ollama/bin/ollama serve\n'"
  printf '#!/usr/bin/env bash\nset -euo pipefail\n[[ "$1" == "getenv" ]] && exit 0\n[[ "$1" == "setenv" ]] && { printf "Could not set environment: 150: Operation not permitted while System Integrity Protection is engaged\n" >&2; exit 1; }\nexit 1\n' >"$tmp_dir/bin/launchctl"
  chmod +x "$tmp_dir/bin/launchctl"
  {
    printf '#!/usr/bin/env bash\nset -euo pipefail\np="${@: -1}"\ncase "$2" in\n'
    printf '  *"Print"*"KEEP_ALIVE"*) grep -q "30m" "$p" && printf "30m\n" || printf "5m\n" ;;\n'
    printf '  *"Print"*"CONTEXT_LENGTH"*) grep -q "524288" "$p" && printf "524288\n" || printf "131072\n" ;;\n'
    printf '  *"Set"*"KEEP_ALIVE"*) sed -i "" "s/5m/30m/g" "$p" ;;\n'
    printf '  *"Set"*"CONTEXT_LENGTH"*) sed -i "" "s/131072/524288/g" "$p" ;;\n'
    printf '  *"Add"*) true ;;\n'
    printf 'esac\n'
  } >"$tmp_dir/bin/PlistBuddy"
  chmod +x "$tmp_dir/bin/PlistBuddy"

  TEST_LAUNCHCTL_LOG="$tmp_dir/launchctl.log" \
    OLLAMA_HOMEBREW_PLIST="$plist_path" \
    OLLAMA_PLIST_BUDDY="$tmp_dir/bin/PlistBuddy" \
    OLLAMA_BREW_CMD="$tmp_dir/bin/brew" \
    OLLAMA_PROCESS_NAME=ollama \
    PATH="$tmp_dir/bin:$PATH" \
    capture_command output status run_main --fix

  assert_status "0" "$status" "verify_ollama --fix ignores launchctl setenv failure"
  assert_contains "$output" "Could not set OLLAMA_KEEP_ALIVE=30m for this login session." "verify_ollama warns about the session env failure"
  assert_contains "$output" "next step: run bin/verify_ollama without sudo, or set it manually with launchctl" "verify_ollama explains the fallback"
  assert_contains "$output" "done, edit successful" "verify_ollama still completes the plist repair"
  assert_contains "$(cat "$plist_path")" "30m" "verify_ollama still repairs the plist"
  rm -rf "$tmp_dir"
}

test_sourcing_ai_tools_exports_keep_alive() {
  source "$AI_TOOLS_FILE"
  assert_eq "30m" "$OLLAMA_KEEP_ALIVE" "ai tools source exports the keep-alive env"
  assert_eq "524288" "$OLLAMA_CONTEXT_LENGTH" "ai tools source exports the context length env"
}

test_sourcing_ai_tools_keeps_export_stable() {
  source "$AI_TOOLS_FILE"
  assert_eq "30m" "$OLLAMA_KEEP_ALIVE" "ai tools source keeps the env export stable"
  assert_eq "524288" "$OLLAMA_CONTEXT_LENGTH" "ai tools source keeps the context length export stable"
}

test_run_main_skips_outside_macos() {
  local tmp_dir=""
  local output=""
  local status=0

  tmp_dir="$(mktemp -d)"
  mkdir -p "$tmp_dir/bin"
  simple_stub "$tmp_dir/bin/uname" "printf 'Linux\n'"

  PATH="$tmp_dir/bin:$PATH" capture_command output status run_main

  assert_status "0" "$status" "verify_ollama skips non-macOS hosts"
  assert_contains "$output" "Skipping: Ollama launchd env setup is only needed on macOS." "verify_ollama explains the skip"
}

test_launch_agent_plist_targets_verify_ollama() {
  local plist_contents=""

  plist_contents="$(cat "$VERIFY_OLLAMA_PLIST")"
  assert_contains "$plist_contents" "bin/verify_ollama" "launch agent calls the verifier script"
  assert_contains "$plist_contents" "RunAtLoad" "launch agent runs at login"
}

run_tests "$@"
