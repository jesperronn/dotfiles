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

test_desired_keep_alive_defaults_to_30m() {
  local output=""
  local status=0

  capture_command output status verify_ollama_desired_keep_alive
  assert_status "0" "$status" "desired keep-alive helper succeeds"
  assert_eq "30m" "$output" "desired keep-alive defaults to 30m"
}

test_run_main_applies_launchctl_value_on_macos() {
  local tmp_dir=""
  local plist_path=""
  local output=""
  local status=0

  tmp_dir="$(mktemp -d)"
  plist_path="$tmp_dir/homebrew.mxcl.ollama.plist"
  cat >"$plist_path" <<'EOF'
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
  <key>EnvironmentVariables</key>
  <dict>
    <key>OLLAMA_KEEP_ALIVE</key>
    <string>30m</string>
  </dict>
</dict>
</plist>
EOF

  mkdir -p "$tmp_dir/bin"
  cat >"$tmp_dir/bin/uname" <<'EOF'
#!/usr/bin/env bash
printf 'Darwin\n'
EOF
  cat >"$tmp_dir/bin/pgrep" <<'EOF'
#!/usr/bin/env bash
printf '61055\n'
EOF
  cat >"$tmp_dir/bin/ps" <<'EOF'
#!/usr/bin/env bash
printf '/opt/homebrew/opt/ollama/bin/ollama serve\n'
EOF
  cat >"$tmp_dir/bin/launchctl" <<'EOF'
#!/usr/bin/env bash
set -euo pipefail

if [[ "$1" == "getenv" ]]; then
  exit 0
fi

if [[ "$1" == "setenv" ]]; then
  printf '%s %s %s\n' "$1" "$2" "$3" >>"${TEST_LAUNCHCTL_LOG:?}"
  exit 0
fi

printf 'unexpected launchctl invocation: %s\n' "$*" >&2
  exit 1
EOF
  cat >"$tmp_dir/bin/PlistBuddy" <<'EOF'
#!/usr/bin/env bash
set -euo pipefail

if [[ "$1" == "-c" && "$2" == "Print :EnvironmentVariables:OLLAMA_KEEP_ALIVE" ]]; then
  printf '30m\n'
  exit 0
fi

printf 'unexpected PlistBuddy invocation: %s\n' "$*" >&2
exit 1
EOF
  chmod +x "$tmp_dir/bin/uname" "$tmp_dir/bin/pgrep" "$tmp_dir/bin/ps" "$tmp_dir/bin/launchctl" "$tmp_dir/bin/PlistBuddy"

  TEST_LAUNCHCTL_LOG="$tmp_dir/launchctl.log" \
    OLLAMA_HOMEBREW_PLIST="$plist_path" \
    OLLAMA_PLIST_BUDDY="$tmp_dir/bin/PlistBuddy" \
    OLLAMA_PROCESS_NAME=ollama \
    PATH="$tmp_dir/bin:$PATH" \
    capture_command output status run_main

  assert_status "0" "$status" "verify_ollama succeeds on macOS"
  assert_contains "$output" "Set OLLAMA_KEEP_ALIVE=30m" "verify_ollama reports the applied value"
  assert_contains "$output" "Restart Ollama and any VS Code windows" "verify_ollama explains restart requirement"
  assert_contains "$(cat "$tmp_dir/launchctl.log")" "setenv OLLAMA_KEEP_ALIVE 30m" "verify_ollama writes launchctl env"
}

test_run_main_fails_when_homebrew_plist_is_wrong() {
  local tmp_dir=""
  local plist_path=""
  local output=""
  local status=0

  tmp_dir="$(mktemp -d)"
  plist_path="$tmp_dir/homebrew.mxcl.ollama.plist"
  cat >"$plist_path" <<'EOF'
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
  <key>EnvironmentVariables</key>
  <dict>
    <key>OLLAMA_KEEP_ALIVE</key>
    <string>5m</string>
  </dict>
</dict>
</plist>
EOF

  mkdir -p "$tmp_dir/bin"
  cat >"$tmp_dir/bin/uname" <<'EOF'
#!/usr/bin/env bash
printf 'Darwin\n'
EOF
  cat >"$tmp_dir/bin/PlistBuddy" <<'EOF'
#!/usr/bin/env bash
set -euo pipefail

if [[ "$1" == "-c" && "$2" == "Print :EnvironmentVariables:OLLAMA_KEEP_ALIVE" ]]; then
  printf '5m\n'
  exit 0
fi

exit 1
EOF
  chmod +x "$tmp_dir/bin/uname" "$tmp_dir/bin/PlistBuddy"

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
  cat >"$plist_path" <<'EOF'
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
  <key>EnvironmentVariables</key>
  <dict>
    <key>OLLAMA_KEEP_ALIVE</key>
    <string>30m</string>
  </dict>
</dict>
</plist>
EOF

  mkdir -p "$tmp_dir/bin"
  cat >"$tmp_dir/bin/uname" <<'EOF'
#!/usr/bin/env bash
printf 'Darwin\n'
EOF
  cat >"$tmp_dir/bin/PlistBuddy" <<'EOF'
#!/usr/bin/env bash
set -euo pipefail

if [[ "$1" == "-c" && "$2" == "Print :EnvironmentVariables:OLLAMA_KEEP_ALIVE" ]]; then
  printf '30m\n'
  exit 0
fi

exit 1
EOF
  cat >"$tmp_dir/bin/pgrep" <<'EOF'
#!/usr/bin/env bash
exit 1
EOF
  chmod +x "$tmp_dir/bin/uname" "$tmp_dir/bin/PlistBuddy" "$tmp_dir/bin/pgrep"

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
  cat >"$plist_path" <<'EOF'
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
  <key>EnvironmentVariables</key>
  <dict>
    <key>OLLAMA_KEEP_ALIVE</key>
    <string>5m</string>
  </dict>
</dict>
</plist>
EOF

  mkdir -p "$tmp_dir/bin"
  cat >"$tmp_dir/bin/uname" <<'EOF'
#!/usr/bin/env bash
printf 'Darwin\n'
EOF
  cat >"$tmp_dir/bin/pgrep" <<'EOF'
#!/usr/bin/env bash
printf '61055\n'
EOF
  cat >"$tmp_dir/bin/ps" <<'EOF'
#!/usr/bin/env bash
printf '/opt/homebrew/opt/ollama/bin/ollama serve\n'
EOF
  cat >"$tmp_dir/bin/launchctl" <<'EOF'
#!/usr/bin/env bash
set -euo pipefail

if [[ "$1" == "getenv" ]]; then
  exit 0
fi

if [[ "$1" == "setenv" ]]; then
  printf '%s %s %s\n' "$1" "$2" "$3" >>"${TEST_LAUNCHCTL_LOG:?}"
  exit 0
fi

printf 'unexpected launchctl invocation: %s\n' "$*" >&2
  exit 1
EOF
  cat >"$tmp_dir/bin/PlistBuddy" <<'EOF'
#!/usr/bin/env bash
set -euo pipefail

plist_path="${@: -1}"

if [[ "$1" == "-c" && "$2" == "Print :EnvironmentVariables:OLLAMA_KEEP_ALIVE" ]]; then
  if rg -n '<string>30m</string>' "$plist_path" >/dev/null 2>&1; then
    printf '30m\n'
  else
    printf '5m\n'
  fi
  exit 0
fi

if [[ "$1" == "-c" && $2 == Set* ]]; then
  perl -0pi -e 's#<string>5m</string>#<string>30m</string>#g; s#<string>unset</string>#<string>30m</string>#g' "$plist_path"
  exit 0
fi

if [[ "$1" == "-c" && $2 == Add* ]]; then
  exit 0
fi

printf 'unexpected PlistBuddy invocation: %s\n' "$*" >&2
exit 1
EOF
  chmod +x "$tmp_dir/bin/uname" "$tmp_dir/bin/pgrep" "$tmp_dir/bin/ps" "$tmp_dir/bin/launchctl" "$tmp_dir/bin/PlistBuddy"

  TEST_LAUNCHCTL_LOG="$tmp_dir/launchctl.log" \
    OLLAMA_HOMEBREW_PLIST="$plist_path" \
    OLLAMA_PLIST_BUDDY="$tmp_dir/bin/PlistBuddy" \
    OLLAMA_BREW_CMD="$tmp_dir/bin/brew" \
    OLLAMA_PROCESS_NAME=ollama \
    PATH="$tmp_dir/bin:$PATH" \
    capture_command output status run_main --fix

  assert_status "0" "$status" "verify_ollama --fix succeeds"
  assert_contains "$output" "FATAL: Homebrew Ollama plist" "verify_ollama --fix warns about the bad plist"
  assert_contains "$output" "editing: adding \"OLLAMA_KEEP_ALIVE=30m\"" "verify_ollama --fix reports the edit"
  assert_contains "$output" "done, edit successful" "verify_ollama --fix confirms the edit"
  assert_contains "$output" "next step: brew services restart ollama" "verify_ollama --fix gives the restart next step"
  assert_contains "$(cat "$plist_path")" "30m" "verify_ollama --fix repairs the plist"
}

test_sourcing_ai_tools_exports_keep_alive() {
  source "$AI_TOOLS_FILE"
  assert_eq "30m" "$OLLAMA_KEEP_ALIVE" "ai tools source exports the keep-alive env"
}

test_sourcing_ai_tools_keeps_export_stable() {
  source "$AI_TOOLS_FILE"
  assert_eq "30m" "$OLLAMA_KEEP_ALIVE" "ai tools source keeps the env export stable"
}

test_run_main_skips_outside_macos() {
  local tmp_dir=""
  local output=""
  local status=0

  tmp_dir="$(mktemp -d)"
  mkdir -p "$tmp_dir/bin"
  cat >"$tmp_dir/bin/uname" <<'EOF'
#!/usr/bin/env bash
printf 'Linux\n'
EOF
  chmod +x "$tmp_dir/bin/uname"

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
