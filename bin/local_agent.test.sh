#!/usr/bin/env bash
# shellcheck disable=SC1090,SC1091

set -euo pipefail

DOTFILES_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
LOCAL_AGENT_BIN="$DOTFILES_ROOT/bin/local_agent"

source "$DOTFILES_ROOT/bin/lib/bash_test.sh"
source "$LOCAL_AGENT_BIN" source

fixture_results_file() {
  local tmp_dir="$1"

  cat >"$tmp_dir/results.md" <<'EOF'
# Local Model Testrun Results

## Summary

Best current default:
- `qwen3.6:35b-a3b-coding-mxfp8`

Fastest model with comparable accuracy:
- `qwen3.5:35b-a3b-coding-nvfp4`

## Comparison

| Model | Ollama size | Exact final edit | Effort / recovery | Single-run wall time | Verdict |
| --- | --- | --- | --- | --- | --- |
| `qwen3.5:35b-a3b-coding-nvfp4` | 21 GB | Yes | recovered | 38.58s | Fastest confirmed isolated good result so far |
| `qwen3.6:35b-a3b-coding-mxfp8` | 37 GB | Yes | recovered | 105.14s | Best overall balance despite a messier isolated rerun |
| `qwen3.5:9b-mlx` | 8.9 GB | Yes | recovered | 92.89s | Working isolated MLX edit agent, but clearly weaker and slower than the best Qwen models |
| `qwen3.5:0.8b-mlx` | 1.2 GB | No | failed | 347.73s | Too weak and too slow for this edit-agent loop |
EOF
}

test_resolve_best_model_alias() {
  local output=""
  local status=0

  capture_command output status local_agent_resolve_model best
  assert_status "0" "$status" "best preset resolves successfully"
  assert_eq "qwen3.6-coding-best-64k" "$output" "best preset uses the recommended qwen 3.6 alias"
}

test_resolve_fast_model_alias() {
  local output=""
  local status=0

  capture_command output status local_agent_resolve_model fast
  assert_status "0" "$status" "fast preset resolves successfully"
  assert_eq "qwen3.5-coding-fast-64k" "$output" "fast preset uses the speed-focused qwen 3.5 alias"
}

test_models_output_lists_recommended_presets() {
  local tmp_dir=""
  local output=""
  local status=0

  tmp_dir="$(mktemp -d)"
  fixture_results_file "$tmp_dir"

  LOCAL_AGENT_RESULTS_FILE="$tmp_dir/results.md" \
    capture_command output status run_main models

  assert_status "0" "$status" "models command succeeds"
  assert_contains "$output" "top-pick" "models output marks the best current default"
  assert_contains "$output" "fast-pick" "models output marks the fast current default"
  assert_contains "$output" "works-weaker" "models output marks weaker but working models"
  assert_contains "$output" "not-good" "models output marks models that are not good at agentic work"
  assert_contains "$output" "qwen3.6-coding-best-64k" "models output includes the best preset target"
}

test_vscode_json_uses_custom_endpoint_shape() {
  local output=""
  local status=0

  capture_command output status run_main vscode-json
  assert_status "0" "$status" "vscode-json command succeeds"
  assert_contains "$output" '"vendor": "customendpoint"' "vscode-json uses the custom endpoint provider"
  assert_contains "$output" '"url": "http://127.0.0.1:11434/v1/chat/completions"' "vscode-json points at the Ollama OpenAI-compatible endpoint"
  assert_contains "$output" '"id": "qwen3.6-coding-best-64k"' "vscode-json exposes the best preset"
}

test_codex_command_uses_local_ollama_flags() {
  local tmp_dir=""
  local output=""
  local status=0

  tmp_dir="$(mktemp -d)"
  mkdir -p "$tmp_dir/bin"
  cat >"$tmp_dir/bin/ollama" <<'EOF'
#!/usr/bin/env bash
set -euo pipefail

case "$1" in
  list)
    printf 'NAME ID SIZE MODIFIED\n'
    ;;
  show)
    exit 0
    ;;
  *)
    printf 'unexpected ollama invocation: %s\n' "$*" >&2
    exit 1
    ;;
esac
EOF
  cat >"$tmp_dir/bin/codex" <<'EOF'
#!/usr/bin/env bash
printf '%s\n' "$*" >"${TEST_CODEX_ARGS:?}"
EOF
  chmod +x "$tmp_dir/bin/ollama" "$tmp_dir/bin/codex"

  TEST_CODEX_ARGS="$tmp_dir/codex.args" \
    PATH="$tmp_dir/bin:$PATH" \
    capture_command output status run_main codex fast "$tmp_dir/project"

  assert_status "0" "$status" "codex command exits through the stub binary"
  assert_contains "$(cat "$tmp_dir/codex.args")" "--oss --local-provider ollama -m qwen3.5-coding-fast-64k" "codex command selects the local ollama provider and fast preset"
  assert_contains "$(cat "$tmp_dir/codex.args")" "-C $tmp_dir/project -s workspace-write -a on-request" "codex command forwards cwd and default safety flags"
}

test_vscode_command_prints_setup_steps() {
  local tmp_dir=""
  local output=""
  local status=0

  tmp_dir="$(mktemp -d)"
  mkdir -p "$tmp_dir/bin"
  cat >"$tmp_dir/bin/ollama" <<'EOF'
#!/usr/bin/env bash
set -euo pipefail

case "$1" in
  list)
    printf 'NAME ID SIZE MODIFIED\n'
    ;;
  show)
    exit 0
    ;;
  *)
    printf 'unexpected ollama invocation: %s\n' "$*" >&2
    exit 1
    ;;
esac
EOF
  cat >"$tmp_dir/bin/code" <<'EOF'
#!/usr/bin/env bash
printf '%s\n' "$*" >"${TEST_CODE_ARGS:?}"
EOF
  chmod +x "$tmp_dir/bin/ollama" "$tmp_dir/bin/code"

  TEST_CODE_ARGS="$tmp_dir/code.args" \
    PATH="$tmp_dir/bin:$PATH" \
    capture_command output status run_main vscode best "$tmp_dir/project"

  assert_status "0" "$status" "vscode command succeeds with a stubbed code binary"
  assert_contains "$(cat "$tmp_dir/code.args")" "--reuse-window --agents $tmp_dir/project" "vscode command opens the agents view in the requested project"
  assert_contains "$output" "bin/local_agent vscode-json" "vscode command points at the JSON helper"
  assert_contains "$output" "Ollama Qwen 3.6 Best (64k)" "vscode command recommends the best local model"
}

test_interactive_requires_fzf() {
  local tmp_dir=""
  local output=""
  local status=0

  tmp_dir="$(mktemp -d)"
  fixture_results_file "$tmp_dir"
  mkdir -p "$tmp_dir/bin"
  cat >"$tmp_dir/bin/ollama" <<'EOF'
#!/usr/bin/env bash
set -euo pipefail

case "$1" in
  list)
    printf 'NAME ID SIZE MODIFIED\n'
    ;;
  show)
    exit 0
    ;;
  *)
    exit 1
    ;;
esac
EOF
  cat >"$tmp_dir/bin/codex" <<'EOF'
#!/usr/bin/env bash
printf '%s\n' "$*" >"${TEST_CODEX_ARGS:?}"
EOF
  chmod +x "$tmp_dir/bin/ollama" "$tmp_dir/bin/codex"

  TEST_CODEX_ARGS="$tmp_dir/codex.args" \
    LOCAL_AGENT_RESULTS_FILE="$tmp_dir/results.md" \
    PATH="$tmp_dir/bin:/usr/bin:/bin" \
    capture_command output status run_main --interactive codex "$tmp_dir/project"

  assert_status "1" "$status" "interactive mode fails without fzf"
  assert_contains "$output" "fzf is not installed or not on PATH" "interactive mode reports missing fzf"
}

test_interactive_codex_uses_selected_model() {
  local tmp_dir=""
  local output=""
  local status=0

  tmp_dir="$(mktemp -d)"
  fixture_results_file "$tmp_dir"
  mkdir -p "$tmp_dir/bin"
  cat >"$tmp_dir/bin/ollama" <<'EOF'
#!/usr/bin/env bash
set -euo pipefail

case "$1" in
  list)
    printf 'NAME ID SIZE MODIFIED\n'
    ;;
  show)
    exit 0
    ;;
  *)
    exit 1
    ;;
esac
EOF
  cat >"$tmp_dir/bin/fzf" <<'EOF'
#!/usr/bin/env bash
set -euo pipefail
head -n 1
EOF
  cat >"$tmp_dir/bin/codex" <<'EOF'
#!/usr/bin/env bash
printf '%s\n' "$*" >"${TEST_CODEX_ARGS:?}"
EOF
  chmod +x "$tmp_dir/bin/ollama" "$tmp_dir/bin/fzf" "$tmp_dir/bin/codex"

  TEST_CODEX_ARGS="$tmp_dir/codex.args" \
    LOCAL_AGENT_RESULTS_FILE="$tmp_dir/results.md" \
    PATH="$tmp_dir/bin:$PATH" \
    capture_command output status run_main -i codex "$tmp_dir/project"

  assert_status "0" "$status" "interactive codex command succeeds"
  assert_contains "$(cat "$tmp_dir/codex.args")" "-m qwen3.5-coding-fast-64k" "interactive mode uses the model selected by fzf"
}

run_tests "$@"
