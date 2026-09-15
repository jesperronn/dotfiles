#!/usr/bin/env bash
# shellcheck disable=SC1090,SC1091

set -euo pipefail

DOTFILES_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
VERIFY_OLLAMA_BIN="$DOTFILES_ROOT/bin/verify_ollama"
VERIFY_OLLAMA_PLIST="$DOTFILES_ROOT/link-file/Library/LaunchAgents/com.jesperronn.ollama-keep-alive.plist"
AI_TOOLS_FILE="$DOTFILES_ROOT/source/91_ai_tools.sh"

source "$DOTFILES_ROOT/bin/lib/bash_test.sh"
source "$VERIFY_OLLAMA_BIN" source

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

  tmp_dir="$(mktemp -d)"
  plist_path="$tmp_dir/homebrew.mxcl.ollama.plist"
  {
    printf '<?xml version="1.0" encoding="UTF-8"?>\n'
    printf '<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">\n'
    printf '<plist version="1.0">\n<dict>\n  <key>EnvironmentVariables</key>\n  <dict>\n'
    printf '    <key>OLLAMA_KEEP_ALIVE</key>\n    <string>30m</string>\n'
    printf '    <key>OLLAMA_CONTEXT_LENGTH</key>\n    <string>524288</string>\n'
    printf '  </dict>\n</dict>\n</plist>\n'
  } >"$plist_path"

  mkdir -p "$tmp_dir/bin"
  simple_stub "$tmp_dir/bin/uname" "printf 'Darwin\n'"
  simple_stub "$tmp_dir/bin/pgrep" "printf '61055\n'"
  simple_stub "$tmp_dir/bin/ps" "printf '/opt/homebrew/opt/ollama/bin/ollama serve\n'"

  {
    printf '#!/usr/bin/env bash\n'
    printf 'set -euo pipefail\n'
    printf 'if [[ "$1" == "getenv" ]]; then\n'
    printf '  exit 0\n'
    printf 'fi\n'
    printf 'if [[ "$1" == "setenv" ]]; then\n'
    printf '  printf "%%s %%s %%s\n" "$1" "$2" "$3" >>"${TEST_LAUNCHCTL_LOG:?}"\n'
    printf '  exit 0\n'
    printf 'fi\n'
    printf 'printf "unexpected launchctl invocation: %%s\n" "$*" >&2\n'
    printf 'exit 1\n'
  } >"$tmp_dir/bin/launchctl"
  chmod +x "$tmp_dir/bin/launchctl"

  {
    printf '#!/usr/bin/env bash\n'
    printf 'set -euo pipefail\n'
    printf 'case "$2" in\n'
    printf '  "Print :EnvironmentVariables:OLLAMA_KEEP_ALIVE")\n'
    printf '    printf "30m\n"\n'
    printf '    exit 0\n'
    printf '    ;;\n'
    printf '  "Print :EnvironmentVariables:OLLAMA_CONTEXT_LENGTH")\n'
    printf '    printf "524288\n"\n'
    printf '    exit 0\n'
    printf '    ;;\n'
    printf 'esac\n'
    printf 'printf "unexpected PlistBuddy invocation: %%s\n" "$*" >&2\n'
    printf 'exit 1\n'
  } >"$tmp_dir/bin/PlistBuddy"
  chmod +x "$tmp_dir/bin/PlistBuddy"

  TEST_LAUNCHCTL_LOG="$tmp_dir/launchctl.log" \
    OLLAMA_HOMEBREW_PLIST="$plist_path" \
    OLLAMA_PLIST_BUDDY="$tmp_dir/bin/PlistBuddy" \
    OLLAMA_PROCESS_NAME=ollama \
    PATH="$tmp_dir/bin:$PATH" \
    capture_command output status run_main

  assert_status "0" "$status" "verify_ollama succeeds on macOS"
  assert_contains "$output" "Set OLLAMA_KEEP_ALIVE=30m" "verify_ollama reports the applied value"
  assert_contains "$output" "Set OLLAMA_CONTEXT_LENGTH=524288" "verify_ollama reports the applied context value"
  assert_contains "$output" "Restart Ollama and any VS Code windows" "verify_ollama explains restart requirement"
  assert_contains "$(cat "$tmp_dir/launchctl.log")" "setenv OLLAMA_KEEP_ALIVE 30m" "verify_ollama writes launchctl env"
  assert_contains "$(cat "$tmp_dir/launchctl.log")" "setenv OLLAMA_CONTEXT_LENGTH 524288" "verify_ollama writes launchctl context env"
}

test_run_main_fails_when_homebrew_plist_is_wrong() {
  local tmp_dir=""
  local plist_path=""
  local output=""
  local status=0

  tmp_dir="$(mktemp -d)"
  plist_path="$tmp_dir/homebrew.mxcl.ollama.plist"
  {
    printf '<?xml version="1.0" encoding="UTF-8"?>\n'
    printf '<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">\n'
    printf '<plist version="1.0">\n<dict>\n  <key>EnvironmentVariables</key>\n  <dict>\n'
    printf '    <key>OLLAMA_KEEP_ALIVE</key>\n    <string>5m</string>\n'
    printf '    <key>OLLAMA_CONTEXT_LENGTH</key>\n    <string>131072</string>\n'
    printf '  </dict>\n</dict>\n</plist>\n'
  } >"$plist_path"

  mkdir -p "$tmp_dir/bin"
  simple_stub "$tmp_dir/bin/uname" "printf 'Darwin\n'"
  {
    printf '#!/usr/bin/env bash\n'
    printf 'set -euo pipefail\n'
    printf 'if [[ "$1" == "-c" && "$2" == "Print :EnvironmentVariables:OLLAMA_KEEP_ALIVE" ]]; then\n'
    printf '  printf "5m\n"\n'
    printf '  exit 0\n'
    printf 'fi\n'
    printf 'exit 1\n'
  } >"$tmp_dir/bin/PlistBuddy"
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
}

test_run_main_fails_when_ollama_is_not_running() {
  local tmp_dir=""
  local plist_path=""
  local output=""
  local status=0

  tmp_dir="$(mktemp -d)"
  plist_path="$tmp_dir/homebrew.mxcl.ollama.plist"
  {
    printf '<?xml version="1.0" encoding="UTF-8"?>\n'
    printf '<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">\n'
    printf '<plist version="1.0">\n<dict>\n  <key>EnvironmentVariables</key>\n  <dict>\n'
    printf '    <key>OLLAMA_KEEP_ALIVE</key>\n    <string>30m</string>\n'
    printf '    <key>OLLAMA_CONTEXT_LENGTH</key>\n    <string>524288</string>\n'
    printf '  </dict>\n</dict>\n</plist>\n'
  } >"$plist_path"

  mkdir -p "$tmp_dir/bin"
  simple_stub "$tmp_dir/bin/uname" "printf 'Darwin\n'"
  {
    printf '#!/usr/bin/env bash\n'
    printf 'set -euo pipefail\n'
    printf 'if [[ "$1" == "-c" && "$2" == "Print :EnvironmentVariables:OLLAMA_KEEP_ALIVE" ]]; then\n'
    printf '  printf "30m\n"\n'
    printf '  exit 0\n'
    printf 'fi\n'
    printf 'if [[ "$1" == "-c" && "$2" == "Print :EnvironmentVariables:OLLAMA_CONTEXT_LENGTH" ]]; then\n'
    printf '  printf "524288\n"\n'
    printf '  exit 0\n'
    printf 'fi\n'
    printf 'exit 1\n'
  } >"$tmp_dir/bin/PlistBuddy"
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
}

test_run_main_fix_repairs_homebrew_plist_and_restarts() {
  local tmp_dir=""
  local plist_path=""
  local output=""
  local status=0

  tmp_dir="$(mktemp -d)"
  plist_path="$tmp_dir/homebrew.mxcl.ollama.plist"

  # Create plist efficiently with printf to avoid subshell overhead
  {
    printf '<?xml version="1.0" encoding="UTF-8"?>\n'
    printf '<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">\n'
    printf '<plist version="1.0">\n<dict>\n  <key>EnvironmentVariables</key>\n  <dict>\n'
    printf '    <key>OLLAMA_KEEP_ALIVE</key>\n    <string>5m</string>\n'
    printf '    <key>OLLAMA_CONTEXT_LENGTH</key>\n    <string>131072</string>\n'
    printf '  </dict>\n</dict>\n</plist>\n'
  } >"$plist_path"

  mkdir -p "$tmp_dir/bin"

  # Create simple stubs with printf-only approach
  simple_stub "$tmp_dir/bin/uname" "printf 'Darwin\n'"
  simple_stub "$tmp_dir/bin/pgrep" "printf '61055\n'"
  simple_stub "$tmp_dir/bin/ps" "printf '/opt/homebrew/opt/ollama/bin/ollama serve\n'"

  # Create launchctl stub - no subshell overhead
  # shellcheck disable=SC2016
  {
    printf '#!/usr/bin/env bash\n'
    printf 'set -euo pipefail\n'
    printf 'if [[ "$1" == "getenv" ]]; then\n'
    printf '  exit 0\n'
    printf 'fi\n'
    printf 'if [[ "$1" == "setenv" ]]; then\n'
    printf '  printf "%%s %%s %%s\n" "$1" "$2" "$3" >>"${TEST_LAUNCHCTL_LOG:?}"\n'
    printf '  exit 0\n'
    printf 'fi\n'
    printf 'printf "unexpected launchctl invocation: %%s\n" "$*" >&2\n'
    printf 'exit 1\n'
  } >"$tmp_dir/bin/launchctl"
  chmod +x "$tmp_dir/bin/launchctl"

  # Create PlistBuddy stub - use grep instead of ripgrep for speed
  # shellcheck disable=SC2016
  {
    printf '#!/usr/bin/env bash\n'
    printf 'set -euo pipefail\n'
    printf 'plist_path="${@: -1}"\n'
    printf 'case "$2" in\n'
    printf '  "Print :EnvironmentVariables:OLLAMA_KEEP_ALIVE")\n'
    printf '    if grep -q "<string>30m</string>" "$plist_path" 2>/dev/null; then printf "30m\n"; else printf "5m\n"; fi\n'
    printf '    exit 0\n'
    printf '    ;;\n'
    printf '  "Print :EnvironmentVariables:OLLAMA_CONTEXT_LENGTH")\n'
    printf '    if grep -q "<string>524288</string>" "$plist_path" 2>/dev/null; then printf "524288\n"; else printf "131072\n"; fi\n'
    printf '    exit 0\n'
    printf '    ;;\n'
    printf 'esac\n'
    printf 'if [[ "$1" == "-c" && $2 == *"OLLAMA_KEEP_ALIVE"* ]]; then\n'
    printf '  sed -i "" "s#<string>5m</string>#<string>30m</string>#g; s#<string>unset</string>#<string>30m</string>#g" "$plist_path"\n'
    printf '  exit 0\n'
    printf 'fi\n'
    printf 'if [[ "$1" == "-c" && $2 == *"OLLAMA_CONTEXT_LENGTH"* ]]; then\n'
    printf '  sed -i "" "s#<string>131072</string>#<string>524288</string>#g; s#<string>unset</string>#<string>524288</string>#g" "$plist_path"\n'
    printf '  exit 0\n'
    printf 'fi\n'
    printf 'if [[ "$1" == "-c" && $2 == Add* ]]; then\n'
    printf '  exit 0\n'
    printf 'fi\n'
    printf 'printf "unexpected PlistBuddy invocation: %%s\n" "$*" >&2\n'
    printf 'exit 1\n'
  } >"$tmp_dir/bin/PlistBuddy"
  chmod +x "$tmp_dir/bin/PlistBuddy"

  TEST_LAUNCHCTL_LOG="$tmp_dir/launchctl.log" \
    OLLAMA_HOMEBREW_PLIST="$plist_path" \
    OLLAMA_PLIST_BUDDY="$tmp_dir/bin/PlistBuddy" \
    OLLAMA_BREW_CMD="$tmp_dir/bin/brew" \
    OLLAMA_PROCESS_NAME=ollama \
    PATH="$tmp_dir/bin:$PATH" \
    capture_command output status run_main --fix

  assert_status "0" "$status" "verify_ollama --fix succeeds"
  assert_contains "$output" "Homebrew Ollama plist" "verify_ollama --fix warns about the bad plist"
  assert_contains "$output" "editing: adding \"OLLAMA_KEEP_ALIVE=30m\"" "verify_ollama --fix reports the edit"
  assert_contains "$output" "editing: adding \"OLLAMA_CONTEXT_LENGTH=524288\"" "verify_ollama --fix reports the context edit"
  assert_contains "$output" "done, edit successful" "verify_ollama --fix confirms the edit"
  assert_contains "$output" "next step: brew services restart ollama" "verify_ollama --fix gives the restart next step"
  assert_contains "$(cat "$plist_path")" "30m" "verify_ollama --fix repairs the plist"
  assert_contains "$(cat "$plist_path")" "524288" "verify_ollama --fix repairs the context length"
}

test_run_main_fix_survives_launchctl_setenv_failure() {
  local tmp_dir=""
  local plist_path=""
  local output=""
  local status=0

  tmp_dir="$(mktemp -d)"
  plist_path="$tmp_dir/homebrew.mxcl.ollama.plist"
  {
    printf '<?xml version="1.0" encoding="UTF-8"?>\n'
    printf '<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">\n'
    printf '<plist version="1.0">\n<dict>\n  <key>EnvironmentVariables</key>\n  <dict>\n'
    printf '    <key>OLLAMA_KEEP_ALIVE</key>\n    <string>5m</string>\n'
    printf '    <key>OLLAMA_CONTEXT_LENGTH</key>\n    <string>131072</string>\n'
    printf '  </dict>\n</dict>\n</plist>\n'
  } >"$plist_path"

  mkdir -p "$tmp_dir/bin"
  simple_stub "$tmp_dir/bin/uname" "printf 'Darwin\n'"
  simple_stub "$tmp_dir/bin/pgrep" "printf '61055\n'"
  simple_stub "$tmp_dir/bin/ps" "printf '/opt/homebrew/opt/ollama/bin/ollama serve\n'"

  {
    printf '#!/usr/bin/env bash\n'
    printf 'set -euo pipefail\n'
    printf 'if [[ "$1" == "getenv" ]]; then\n'
    printf '  exit 0\n'
    printf 'fi\n'
    printf 'if [[ "$1" == "setenv" ]]; then\n'
    printf '  printf "Could not set environment: 150: Operation not permitted while System Integrity Protection is engaged\n" >&2\n'
    printf '  exit 1\n'
    printf 'fi\n'
    printf 'printf "unexpected launchctl invocation: %%s\n" "$*" >&2\n'
    printf 'exit 1\n'
  } >"$tmp_dir/bin/launchctl"
  chmod +x "$tmp_dir/bin/launchctl"

  {
    printf '#!/usr/bin/env bash\n'
    printf 'set -euo pipefail\n'
    printf 'plist_path="${@: -1}"\n'
    printf 'case "$2" in\n'
    printf '  "Print :EnvironmentVariables:OLLAMA_KEEP_ALIVE")\n'
    printf '    if grep -q "<string>30m</string>" "$plist_path" 2>/dev/null; then printf "30m\n"; else printf "5m\n"; fi\n'
    printf '    exit 0\n'
    printf '    ;;\n'
    printf '  "Print :EnvironmentVariables:OLLAMA_CONTEXT_LENGTH")\n'
    printf '    if grep -q "<string>524288</string>" "$plist_path" 2>/dev/null; then printf "524288\n"; else printf "131072\n"; fi\n'
    printf '    exit 0\n'
    printf '    ;;\n'
    printf 'esac\n'
    printf 'if [[ "$1" == "-c" && $2 == *"OLLAMA_KEEP_ALIVE"* ]]; then\n'
    printf '  sed -i "" "s#<string>5m</string>#<string>30m</string>#g; s#<string>unset</string>#<string>30m</string>#g" "$plist_path"\n'
    printf '  exit 0\n'
    printf 'fi\n'
    printf 'if [[ "$1" == "-c" && $2 == *"OLLAMA_CONTEXT_LENGTH"* ]]; then\n'
    printf '  sed -i "" "s#<string>131072</string>#<string>524288</string>#g; s#<string>unset</string>#<string>524288</string>#g" "$plist_path"\n'
    printf '  exit 0\n'
    printf 'fi\n'
    printf 'if [[ "$1" == "-c" && $2 == Add* ]]; then\n'
    printf '  exit 0\n'
    printf 'fi\n'
    printf 'printf "unexpected PlistBuddy invocation: %%s\n" "$*" >&2\n'
    printf 'exit 1\n'
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
