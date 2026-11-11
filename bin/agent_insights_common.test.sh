#!/usr/bin/env bash
# shellcheck disable=SC1090,SC1091

set -euo pipefail

DOTFILES_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
SCRIPT_UNDER_TEST="$DOTFILES_ROOT/bin/agent_insights"

source "$DOTFILES_ROOT/bin/lib/bash_test.sh"

TEST_TMP="$(mktemp -d)"
cleanup_test_tmp() {
  rm -rf "$TEST_TMP"
}
trap 'cleanup_test_tmp' EXIT

ROOT="$TEST_TMP/sessions"

# Writes one omp session using the given model names (one model_change each): id, date, models...
write_session() {
  local id="$1" date="$2"
  shift 2
  mkdir -p "$ROOT/-src-x"
  {
    echo "{\"type\":\"session\",\"version\":3,\"id\":\"$id\",\"timestamp\":\"${date}T10:00:00.000Z\",\"cwd\":\"/work/x\"}"
    local m
    for m in "$@"; do
      echo "{\"type\":\"model_change\",\"id\":\"m\",\"timestamp\":\"${date}T10:00:01.000Z\",\"model\":\"$m\"}"
    done
    echo "{\"type\":\"message\",\"id\":\"u1\",\"timestamp\":\"${date}T10:00:02.000Z\",\"message\":{\"role\":\"user\",\"attribution\":\"user\",\"content\":\"hi\"}}"
  } >"$ROOT/-src-x/${date}T10-00-00-000Z_$id.jsonl"
}

build_fixture() {
  write_session s1 2026-09-01 "omlx/Ornith-1.5-35B-A3B-MLX-4bit"
  write_session s2 2026-09-02 "mtplx/ornith-ai-ornith-1.5-35b-a3b-mlx-4bit"
  write_session s3 2026-09-03 "litellm/omlx/Ornith-1.5-35B-A3B-MLX-4bit"
  write_session s4 2026-09-04 "litellm/mtplx/ornith-ai-ornith-1.5-35b-a3b-mlx-4bit"
  # Two spellings of the same model inside one session still count once.
  write_session s5 2026-09-05 "omlx/Ornith-1.5-35B-A3B-MLX-4bit" "mtplx/ornith-ai-ornith-1.5-35b-a3b-mlx-4bit"
  write_session s6 2026-09-06 "omlx/Ornith-1.5-35B-A3B-MLX-6bit"
  write_session s7 2026-09-07 "openai/gpt-5.4"
}

test_ornith_spellings_collapse_but_quantizations_stay_apart() {
  local out
  out="$("$SCRIPT_UNDER_TEST" omp --root "$ROOT" --json | python3 -c "import json,sys; d=json.load(sys.stdin); print(json.dumps(d['summary']['models'], sort_keys=True))")"
  assert_eq '{"gpt-5.4": 1, "ornith-1.5-35b-a3b-mlx-4bit": 5, "ornith-1.5-35b-a3b-mlx-6bit": 1}' "$out" \
    "4 spellings (+1 mixed session counted once) = one 4bit row; 6bit and gpt-5.4 stay separate"
  out="$("$SCRIPT_UNDER_TEST" omp --root "$ROOT" | grep -c 'ornith-1.5-35b-a3b-mlx-4bit')"
  assert_eq "1" "$out" "report shows a single merged 4bit row"
}

test_session_models_stay_raw_in_json() {
  local out
  out="$("$SCRIPT_UNDER_TEST" omp --root "$ROOT" --json | python3 -c "
import json,sys
d=json.load(sys.stdin)
print([s['models'] for s in d['sessions'] if s['id']=='s4'][0])")"
  assert_eq "['litellm/mtplx/ornith-ai-ornith-1.5-35b-a3b-mlx-4bit']" "$out" "per-session models are not normalized"
}

test_bars_use_thin_bar_glyph() {
  local out
  out="$("$SCRIPT_UNDER_TEST" omp --root "$ROOT")"
  assert_contains "$out" "▬▬▬▬▬▬▬▬▬▬▬▬▬▬▬▬▬▬▬▬▬▬▬▬" "peak row draws a full 24-wide bar of ▬"
  assert_not_contains "$out" "█" "old block glyph is gone"
}

test_normalize_model_unit() {
  local out
  out="$(cd "$DOTFILES_ROOT/bin/lib" && python3 -c "
from agent_insights.common import normalize_model as n
print(n('LiteLLM/lm-studio/Qwen/Qwen2.5-Coder-7B'), n('lms/*'), n('gpt-oss:20b'), n('ollama/phi4:latest'))")"
  assert_eq "qwen2.5-coder-7b lms/* gpt-oss:20b phi4:latest" "$out" "prefix and vendor-path stripping, wildcard kept"
}

build_fixture
run_tests "$@"
