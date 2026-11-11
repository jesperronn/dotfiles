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

build_fixture() {
  local proj="$ROOT/--work-alpha--" other="$ROOT/--work-beta--"
  mkdir -p "$proj" "$other"

  cat >"$proj/2026-09-01T10-00-00-000Z_aaaa1111.jsonl" <<'JSONL'
{"type":"session","version":3,"id":"aaaa1111","timestamp":"2026-09-01T10:00:00.000Z","cwd":"/work/alpha"}
{"type":"model_change","id":"m1","parentId":null,"timestamp":"2026-09-01T10:00:01.000Z","provider":"omlx","modelId":"Qwen"}
{"type":"thinking_level_change","id":"t1","parentId":"m1","timestamp":"2026-09-01T10:00:01.500Z","thinkingLevel":"low"}
{"type":"message","id":"s0","timestamp":"2026-09-01T10:00:01.800Z","message":{"role":"system","content":"","sections":{}}}
{"type":"message","id":"u1","timestamp":"2026-09-01T10:00:02.000Z","message":{"role":"user","content":[{"type":"text","text":"please fix it"}]}}
{"type":"message","id":"a1","timestamp":"2026-09-01T10:00:10.000Z","message":{"role":"assistant","model":"Qwen","provider":"omlx","stopReason":"toolUse","usage":{"input":100,"output":20,"cacheRead":50,"cacheWrite":5,"cost":{"total":0.25}},"content":[{"type":"text","text":"ok"},{"type":"toolCall","id":"c1","name":"bash","arguments":{}},{"type":"toolCall","id":"c2","name":"read","arguments":{}}]}}
{"type":"message","id":"r1","timestamp":"2026-09-01T10:00:12.000Z","message":{"role":"toolResult","toolName":"bash","isError":true,"content":[]}}
{"type":"message","id":"r2","timestamp":"2026-09-01T10:00:13.000Z","message":{"role":"toolResult","toolName":"read","isError":false,"content":[]}}
{"type":"compaction","id":"k1","timestamp":"2026-09-01T10:00:14.000Z","summary":"s","tokensBefore":900,"usage":{"input":10,"output":2,"cacheRead":0,"cacheWrite":0,"cost":{"total":0.05}}}
THIS LINE IS CORRUPT {{{
{"type":"message","id":"a2","timestamp":"2026-09-01T10:01:00.000Z","message":{"role":"assistant","model":"Qwen","provider":"omlx","stopReason":"error","errorMessage":"500: boom","usage":{"input":200,"output":30,"cacheRead":0,"cacheWrite":0,"cost":{"total":0.5}},"content":[]}}
JSONL
  : >"$proj/2026-09-01T10-00-00-000Z_aaaa1111.txt"

  : >"$other/2026-09-02T10-00-00-000Z_empty.jsonl"
  cat >"$other/2026-09-05T10-00-00-000Z_bbbb2222.jsonl" <<'JSONL'
{"type":"session","version":3,"id":"bbbb2222","timestamp":"2026-09-05T10:00:00.000Z","cwd":"/work/beta"}
{"type":"message","id":"u1","timestamp":"2026-09-05T10:00:02.000Z","message":{"role":"user","content":"hello"}}
{"type":"message","id":"a1","timestamp":"2026-09-05T10:00:05.000Z","message":{"role":"assistant","model":"Q","provider":"p","stopReason":"stop","usage":{"input":7,"output":3,"cacheRead":0,"cacheWrite":0,"cost":{"total":0}},"content":[]}}
JSONL
}

declare -A V

load_values() {
  local key value
  while IFS=$'\t' read -r key value; do
    V[$key]="$value"
  done < <(python3 - "$TEST_TMP/all.json" <<'PY'
import json, sys
d = json.load(open(sys.argv[1]))
by = {s["id"]: s for s in d["sessions"]}
a, b = by["aaaa1111"], by["bbbb2222"]
rows = {
    "count": len(by),
    "project": a["project"], "first_prompt": a["first_prompt"],
    "turns": f'{a["user_turns"]} {a["assistant_turns"]}', "models": a["models"],
    "thinking": a["extra"]["thinking_level_last"], "compactions": a["extra"]["compactions"],
    "tools": a["tool_calls"], "errors": a["tool_errors"],
    "tokens": " ".join(str(a["tokens"][k]) for k in ("input", "output", "cache_read", "cache_write")),
    "cost": a["cost"], "zero_cost": b["cost"], "corrupt": a["extra"]["corrupt_lines"],
    "assistant_errors": a["extra"]["assistant_errors"],
    "stops": dict(sorted(a["extra"]["stop_reasons"].items())),
}
for k, v in rows.items():
    print(f"{k}\t{v}")
PY
  )
}

count_sessions() {
  "$SCRIPT_UNDER_TEST" pi --root "$ROOT" --json "$@" | python3 -c "import json,sys; print(len(json.load(sys.stdin)['sessions']))"
}

test_sessions_counted_and_non_jsonl_ignored() {
  assert_eq "2" "${V[count]}" "empty file and non-jsonl sibling are not sessions"
}

test_normal_session_fields() {
  assert_eq "/work/alpha" "${V[project]}" "project from cwd"
  assert_eq "please fix it" "${V[first_prompt]}" "first prompt (system message not counted)"
  assert_eq "1 2" "${V[turns]}" "turn counts"
  assert_eq "['omlx/Qwen']" "${V[models]}" "model deduped across model_change and assistant"
  assert_eq "low" "${V[thinking]}" "thinking level"
  assert_eq "1" "${V[compactions]}" "compaction counted"
}

test_tool_calls_and_errors() {
  assert_eq "{'bash': 1, 'read': 1}" "${V[tools]}" "tool calls from toolCall blocks"
  assert_eq "1" "${V[errors]}" "tool error from toolResult.isError"
  assert_eq "1" "${V[assistant_errors]}" "assistant error stop counted"
}

test_tokens_and_cost_sums() {
  assert_eq "310 52 50 5" "${V[tokens]}" "token sums include compaction usage"
  assert_eq "0.8" "${V[cost]}" "cost summed"
  assert_eq "0.0" "${V[zero_cost]}" "zero cost stays 0.0 not None"
}

test_corrupt_line_skipped_and_counted() {
  assert_eq "1" "${V[corrupt]}" "corrupt line counted, parsing continued"
  assert_eq "{'error': 1, 'toolUse': 1}" "${V[stops]}" "stopReason distribution"
}

test_since_and_project_filters() {
  assert_eq "1" "$(count_sessions --since 2026-09-03)" "--since drops earlier sessions"
  assert_eq "1" "$(count_sessions --project alpha)" "--project keeps matching cwd"
  assert_eq "0" "$(count_sessions --until 2026-08-01)" "--until before all sessions"
}

test_report_and_list_modes() {
  local out
  out="$("$SCRIPT_UNDER_TEST" pi --root "$ROOT" 2>&1)"
  assert_contains "$out" "pi usage report" "report header"
  assert_contains "$out" "Sessions: 2" "report session count"
  assert_contains "$out" "bash" "report lists tools"
  out="$("$SCRIPT_UNDER_TEST" pi list --root "$ROOT" 2>&1)"
  assert_contains "$out" "bbbb2222" "list shows newest session"
  assert_contains "$out" "aaaa1111" "list shows older session"
}

errors_of() {
  # errors_of <harness> <root>: prints the errors list of the single session as JSON, one item per line
  "$SCRIPT_UNDER_TEST" "$1" --root "$2" --json | python3 -c "
import json, sys
d = json.load(sys.stdin)
for s in d['sessions']:
    print(len(s['errors']))
    for e in s['errors']:
        print(e)"
}

test_errors_captured_redacted_and_capped() {
  local errroot="$TEST_TMP/errroot" out
  mkdir -p "$errroot"
  cat >"$errroot/s.jsonl" <<'JSONL'
{"type":"session","version":3,"id":"err00001","timestamp":"2026-09-01T10:00:00.000Z","cwd":"/work/err"}
{"type":"message","id":"u1","timestamp":"2026-09-01T10:00:01.000Z","message":{"role":"user","content":"please fix it"}}
{"type":"message","id":"r1","timestamp":"2026-09-01T10:00:02.000Z","message":{"role":"toolResult","toolName":"bash","isError":true,"content":[{"type":"text","text":"curl failed: Authorization: Bearer abcdef1234567890XYZ at /Users/alice/src/app"}]}}
{"type":"message","id":"a1","timestamp":"2026-09-01T10:00:03.000Z","message":{"role":"assistant","model":"Q","provider":"p","stopReason":"error","errorMessage":"401 key sk-abcdefghijklmnop1234 token ghp_abcdefghijklmnopqrstuvwxyz0123456789 hash 0123456789abcdef0123456789abcdef01234567","content":[]}}
{"type":"message","id":"r2","timestamp":"2026-09-01T10:00:04.000Z","message":{"role":"toolResult","toolName":"bash","isError":true,"content":[{"type":"text","text":"curl failed: Authorization: Bearer abcdef1234567890XYZ at /Users/alice/src/app"}]}}
{"type":"message","id":"r3","timestamp":"2026-09-01T10:00:05.000Z","message":{"role":"toolResult","toolName":"bash","isError":true,"content":[{"type":"text","text":"word word word word word word word word word word word word word word word word word word word word word word word word word word word word word word word word word word word word word word word word word word word word word word word word word word word word word word word word word word word word"}]}}
{"type":"message","id":"r4","timestamp":"2026-09-01T10:00:06.000Z","message":{"role":"toolResult","toolName":"bash","isError":true,"content":[{"type":"text","text":"dropped-fourth"}]}}
{"type":"message","id":"r5","timestamp":"2026-09-01T10:00:07.000Z","message":{"role":"toolResult","toolName":"bash","isError":false,"content":[{"type":"text","text":"fine output"}]}}
JSONL
  out="$(errors_of pi "$errroot")"
  assert_eq "3" "$(head -n1 <<<"$out")" "at most 3 distinct errors kept (duplicate and fourth dropped)"
  assert_contains "$out" "curl failed: Authorization: [redacted] at ~/src/app" "Authorization header redacted and /Users/<name> replaced by ~"
  assert_contains "$out" "401 key [redacted] token [redacted] hash [redacted]" "sk- and ghp_ keys and 40-char hex redacted"
  assert_not_contains "$out" "abcdef1234567890" "secret values do not appear"
  assert_not_contains "$out" "/Users/alice" "home directory never appears"
  assert_not_contains "$out" "please fix it" "user prompts are never captured as errors"
  assert_not_contains "$out" "dropped-fourth" "fourth distinct error dropped"
  assert_contains "$out" "word word…" "long message truncated to 200 chars with ellipsis"
}


build_fixture
"$SCRIPT_UNDER_TEST" pi --root "$ROOT" --json >"$TEST_TMP/all.json"
load_values
run_tests "$@"
