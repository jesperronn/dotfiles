#!/usr/bin/env bash
# shellcheck disable=SC1090,SC1091

set -euo pipefail

DOTFILES_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
VERIFY_OLLAMA_MODELS_BIN="$DOTFILES_ROOT/bin/verify_ollama_models"

source "$DOTFILES_ROOT/bin/lib/bash_test.sh"
source "$VERIFY_OLLAMA_MODELS_BIN" source

test_run_main_fails_when_ollama_is_not_installed() {
  local tmp_dir=""
  local output=""
  local status=0

  tmp_dir="$(mktemp -d)"

  # shellcheck disable=SC2329
  run_main_without_ollama() {
    PATH="$tmp_dir:/usr/bin:/bin"
    run_main
  }

  capture_command output status run_main_without_ollama
  unset -f run_main_without_ollama

  assert_status "1" "$status" "verify_ollama_models fails without ollama"
  assert_contains "$output" "ollama is not installed" "verify_ollama_models reports missing cli"
  assert_contains "$output" "next step: brew install ollama" "verify_ollama_models suggests brew install"
}

test_run_main_fails_when_ollama_is_not_running() {
  local tmp_dir=""
  local output=""
  local status=0

  tmp_dir="$(mktemp -d)"
  mkdir -p "$tmp_dir/bin" "$tmp_dir/modelfiles"
  cat >"$tmp_dir/modelfiles/qwen3.6-coding-64k.Modelfile" <<'EOF'
FROM qwen3.6:35b-a3b-coding-bf16
PARAMETER num_ctx 65536
EOF
  cat >"$tmp_dir/bin/ollama" <<'EOF'
#!/usr/bin/env bash
exit 1
EOF
  chmod +x "$tmp_dir/bin/ollama"

  OLLAMA_MODELFILES_DIR="$tmp_dir/modelfiles" \
    PATH="$tmp_dir/bin:$PATH" \
    capture_command output status run_main

  assert_status "1" "$status" "verify_ollama_models fails when ollama is down"
  assert_contains "$output" "ollama is not responding" "verify_ollama_models reports unavailable daemon"
  assert_contains "$output" "next step: brew services start ollama" "verify_ollama_models suggests starting ollama"
}

test_run_main_fails_when_alias_is_missing() {
  local tmp_dir=""
  local output=""
  local status=0

  tmp_dir="$(mktemp -d)"
  mkdir -p "$tmp_dir/bin" "$tmp_dir/modelfiles"
  cat >"$tmp_dir/modelfiles/qwen3.6-coding-64k.Modelfile" <<'EOF'
FROM qwen3.6:35b-a3b-coding-bf16
PARAMETER num_ctx 65536
EOF
  cat >"$tmp_dir/bin/ollama" <<'EOF'
#!/usr/bin/env bash
set -euo pipefail

case "$1" in
  list)
    printf 'NAME ID SIZE MODIFIED\n'
    ;;
  show)
    exit 1
    ;;
  *)
    printf 'unexpected ollama invocation: %s\n' "$*" >&2
    exit 1
    ;;
esac
EOF
  chmod +x "$tmp_dir/bin/ollama"

  OLLAMA_MODELFILES_DIR="$tmp_dir/modelfiles" \
    PATH="$tmp_dir/bin:$PATH" \
    capture_command output status run_main

  assert_status "1" "$status" "verify_ollama_models fails when alias is missing"
  assert_contains "$output" "Missing Ollama model alias 'qwen3.6-coding-64k'" "verify_ollama_models reports the missing alias"
  assert_contains "$output" "next step: run bin/verify_ollama_models --fix" "verify_ollama_models suggests the fix command"
}

test_run_main_fix_creates_aliases() {
  local tmp_dir=""
  local output=""
  local status=0

  tmp_dir="$(mktemp -d)"
  mkdir -p "$tmp_dir/bin" "$tmp_dir/modelfiles"
  cat >"$tmp_dir/modelfiles/qwen3.6-coding-64k.Modelfile" <<'EOF'
FROM qwen3.6:35b-a3b-coding-bf16
PARAMETER num_ctx 65536
EOF
  cat >"$tmp_dir/modelfiles/qwen3.5-9b-32k.Modelfile" <<'EOF'
FROM qwen3.5:9b
PARAMETER num_ctx 32768
EOF
  cat >"$tmp_dir/bin/ollama" <<'EOF'
#!/usr/bin/env bash
set -euo pipefail

if [[ "$1" == "list" ]]; then
  printf 'NAME ID SIZE MODIFIED\n'
  exit 0
fi

if [[ "$1" == "create" ]]; then
  printf 'create %s %s %s\n' "$1" "$2" "$4" >>"${TEST_OLLAMA_LOG:?}"
  exit 0
fi

printf 'unexpected ollama invocation: %s\n' "$*" >&2
exit 1
EOF
  chmod +x "$tmp_dir/bin/ollama"

  TEST_OLLAMA_LOG="$tmp_dir/ollama.log" \
    OLLAMA_MODELFILES_DIR="$tmp_dir/modelfiles" \
    PATH="$tmp_dir/bin:$PATH" \
    capture_command output status run_main --fix

  assert_status "0" "$status" "verify_ollama_models --fix succeeds"
  assert_contains "$output" "creating: qwen3.6-coding-64k from qwen3.6:35b-a3b-coding-bf16" "verify_ollama_models --fix reports the qwen alias"
  assert_contains "$output" "done: qwen3.5-9b-32k" "verify_ollama_models --fix reports the autocomplete alias"
  assert_contains "$output" "next step: point your Ollama-backed IDEs at these alias names" "verify_ollama_models --fix prints the handoff"
  assert_contains "$(cat "$tmp_dir/ollama.log")" "create qwen3.6-coding-64k" "verify_ollama_models --fix created the qwen alias"
  assert_contains "$(cat "$tmp_dir/ollama.log")" "create qwen3.5-9b-32k" "verify_ollama_models --fix created the autocomplete alias"
}

test_run_main_succeeds_when_aliases_exist() {
  local tmp_dir=""
  local output=""
  local status=0

  tmp_dir="$(mktemp -d)"
  mkdir -p "$tmp_dir/bin" "$tmp_dir/modelfiles"
  cat >"$tmp_dir/modelfiles/gemma4-26b-64k.Modelfile" <<'EOF'
FROM gemma4:26b
PARAMETER num_ctx 65536
EOF
  cat >"$tmp_dir/bin/ollama" <<'EOF'
#!/usr/bin/env bash
set -euo pipefail

case "$1" in
  list)
    printf 'NAME ID SIZE MODIFIED\n'
    ;;
  show)
    printf 'FROM gemma4:26b\n'
    ;;
  *)
    printf 'unexpected ollama invocation: %s\n' "$*" >&2
    exit 1
    ;;
esac
EOF
  chmod +x "$tmp_dir/bin/ollama"

  OLLAMA_MODELFILES_DIR="$tmp_dir/modelfiles" \
    PATH="$tmp_dir/bin:$PATH" \
    capture_command output status run_main

  assert_status "0" "$status" "verify_ollama_models succeeds when aliases exist"
  assert_contains "$output" "verified: gemma4-26b-64k" "verify_ollama_models reports the verified alias"
}

run_tests "$@"
