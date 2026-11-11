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

# Writes the shared synthetic fixture tree once.
build_fixture() {
  local proj="$ROOT/-src-alpha" other="$ROOT/-src-beta"
  mkdir -p "$proj/2026-09-01T10-00-00-000Z_aaaa1111" "$other"

  cat >"$proj/2026-09-01T10-00-00-000Z_aaaa1111.jsonl" <<'JSONL'
{"type":"session","version":3,"id":"aaaa1111","timestamp":"2026-09-01T10:00:00.000Z","cwd":"/work/alpha"}
{"type":"title","title":"Fix the thing"}
{"type":"model_change","id":"m1","timestamp":"2026-09-01T10:00:01.000Z","model":"omlx/Qwen"}
{"type":"thinking_level_change","id":"t1","timestamp":"2026-09-01T10:00:01.500Z","thinkingLevel":"high","configured":"auto"}
{"type":"message","id":"u1","timestamp":"2026-09-01T10:00:02.000Z","message":{"role":"user","attribution":"user","content":[{"type":"text","text":"please fix it"}]}}
{"type":"message","id":"a1","timestamp":"2026-09-01T10:00:10.000Z","message":{"role":"assistant","model":"Qwen","provider":"omlx","stopReason":"toolUse","usage":{"input":100,"output":20,"cacheRead":50,"cacheWrite":5,"totalTokens":175,"cost":{"total":0.25}},"content":[{"type":"text","text":"ok"},{"type":"toolCall","id":"c1","name":"bash","arguments":{}},{"type":"toolCall","id":"c2","name":"read","arguments":{}}]}}
{"type":"custom","customType":"tool_execution_start","data":{"toolName":"bash"},"timestamp":"2026-09-01T10:00:11.000Z"}
{"type":"message","id":"r1","timestamp":"2026-09-01T10:00:12.000Z","message":{"role":"toolResult","toolName":"bash","isError":true,"content":[]}}
{"type":"message","id":"r2","timestamp":"2026-09-01T10:00:13.000Z","message":{"role":"toolResult","toolName":"read","isError":false,"content":[]}}
{"type":"message","id":"f1","timestamp":"2026-09-01T10:00:13.500Z","message":{"role":"fileMention","files":[{"path":"notes.txt"}]}}
{"type":"compaction","id":"k1","timestamp":"2026-09-01T10:00:14.000Z","summary":"s"}
THIS LINE IS CORRUPT {{{
{"type":"message","id":"a2","timestamp":"2026-09-01T10:01:00.000Z","message":{"role":"assistant","model":"Qwen","provider":"omlx","stopReason":"stop","usage":{"input":200,"output":30,"cacheRead":0,"cacheWrite":0,"cost":{"total":0.5}},"content":[{"type":"text","text":"done"}]}}
JSONL

  # Subagent session beside its parent, with a tombstone marker and unrelated artifacts.
  cat >"$proj/2026-09-01T10-00-00-000Z_aaaa1111/child.jsonl" <<'JSONL'
{"type":"session","version":3,"id":"child001","timestamp":"2026-09-01T10:00:30.000Z","cwd":"/work/alpha","parentSession":"x"}
{"type":"session_init","id":"i1","agent":"task","resolvedModel":"lm/Child"}
{"type":"message","id":"a1","timestamp":"2026-09-01T10:00:40.000Z","message":{"role":"assistant","model":"Child","provider":"lm","stopReason":"stop","usage":{"input":1,"output":1,"cacheRead":0,"cacheWrite":0,"cost":{"total":0}},"content":[]}}
JSONL
  : >"$proj/2026-09-01T10-00-00-000Z_aaaa1111/child.jsonl.tombstone"
  echo "log" >"$proj/2026-09-01T10-00-00-000Z_aaaa1111/1.bash.log"
  echo "md" >"$proj/2026-09-01T10-00-00-000Z_aaaa1111/child.md"
  : >"$proj/.2026-09-01T10-00-00-000Z_aaaa1111.jsonl.lock.os"

  # Empty file and a later session in another project (zero-cost local model).
  : >"$other/2026-09-02T10-00-00-000Z_empty.jsonl"
  cat >"$other/2026-09-05T10-00-00-000Z_bbbb2222.jsonl" <<'JSONL'
{"type":"session","version":3,"id":"bbbb2222","timestamp":"2026-09-05T10:00:00.000Z","cwd":"/work/beta","title":"Second"}
{"type":"message","id":"u1","timestamp":"2026-09-05T10:00:02.000Z","message":{"role":"user","attribution":"user","content":"hello"}}
{"type":"message","id":"a1","timestamp":"2026-09-05T10:00:05.000Z","message":{"role":"assistant","model":"Q","provider":"p","stopReason":"stop","usage":{"input":7,"output":3,"cacheRead":0,"cacheWrite":0,"cost":{"total":0}},"content":[]}}
JSONL
}

declare -A V

# Extracts every value the tests assert on from the full --json output in one python run.
load_values() {
  local key value
  while IFS=$'\t' read -r key value; do
    V[$key]="$value"
  done < <(python3 - "$TEST_TMP/all.json" <<'PY'
import json, sys
d = json.load(open(sys.argv[1]))
by = {s["id"]: s for s in d["sessions"]}
a, b, c = by["aaaa1111"], by["bbbb2222"], by["child001"]
rows = {
    "count": len(by),
    "project": a["project"], "title": a["title"], "first_prompt": a["first_prompt"],
    "turns": f'{a["user_turns"]} {a["assistant_turns"]}', "models": a["models"],
    "thinking": a["extra"]["thinking_level_last"], "compactions": a["extra"]["compactions"],
    "children": a["extra"]["subagent_sessions"], "mentioned": a["extra"]["files_mentioned"],
    "tools": a["tool_calls"], "errors": a["tool_errors"],
    "tokens": " ".join(str(a["tokens"][k]) for k in ("input", "output", "cache_read", "cache_write")),
    "cost": a["cost"], "zero_cost": b["cost"], "corrupt": a["extra"]["corrupt_lines"],
    "child_flags": " ".join(str(c["extra"][k]) for k in ("subagent", "tombstoned", "subagent_kind")),
    "stops": dict(sorted(a["extra"]["stop_reasons"].items())),
}
for k, v in rows.items():
    print(f"{k}\t{v}")
PY
  )
}

count_sessions() {
  "$SCRIPT_UNDER_TEST" omp --root "$ROOT" --json "$@" | python3 -c "import json,sys; print(len(json.load(sys.stdin)['sessions']))"
}

test_sessions_counted_and_non_jsonl_ignored() {
  # parent + child + beta; empty file, tombstone, log, md, lock ignored/skipped
  assert_eq "3" "${V[count]}" "empty file, tombstone and non-jsonl files are not sessions"
}

test_normal_session_fields() {
  assert_eq "/work/alpha" "${V[project]}" "project from cwd"
  assert_eq "Fix the thing" "${V[title]}" "title record"
  assert_eq "please fix it" "${V[first_prompt]}" "first prompt"
  assert_eq "1 2" "${V[turns]}" "turn counts"
  assert_eq "['omlx/Qwen']" "${V[models]}" "model names deduped across model_change and assistant provider"
  assert_eq "high" "${V[thinking]}" "thinking level"
  assert_eq "1" "${V[compactions]}" "compaction counted"
  assert_eq "1" "${V[children]}" "subagent child counted on parent"
  assert_eq "['notes.txt']" "${V[mentioned]}" "files mentioned"
}

test_tool_calls_and_errors() {
  assert_eq "{'bash': 1, 'read': 1}" "${V[tools]}" "tool calls from toolCall blocks only"
  assert_eq "1" "${V[errors]}" "tool error from toolResult.isError"
}

test_tokens_and_cost_sums() {
  assert_eq "300 50 50 5" "${V[tokens]}" "token sums across assistant messages"
  assert_eq "0.75" "${V[cost]}" "cost summed"
  assert_eq "0.0" "${V[zero_cost]}" "zero cost stays 0.0 not None"
}

test_corrupt_line_skipped_and_counted() {
  assert_eq "1" "${V[corrupt]}" "corrupt line counted, parsing continued"
}

test_subagent_and_tombstone_flags() {
  assert_eq "1 1 task" "${V[child_flags]}" "subagent, tombstone flag, kind"
}

test_stop_reasons() {
  assert_eq "{'stop': 1, 'toolUse': 1}" "${V[stops]}" "stopReason distribution"
}

test_since_and_project_filters() {
  assert_eq "1" "$(count_sessions --since 2026-09-03)" "--since drops earlier sessions"
  assert_eq "2" "$(count_sessions --project alpha)" "--project keeps matching cwd (parent and child)"
  assert_eq "0" "$(count_sessions --until 2026-08-01)" "--until before all sessions"
}

test_report_and_list_modes() {
  local out
  out="$("$SCRIPT_UNDER_TEST" omp --root "$ROOT" 2>&1)"
  assert_contains "$out" "omp usage report" "report header"
  assert_contains "$out" "Sessions: 3" "report session count"
  assert_contains "$out" "bash" "report lists tools"
  out="$("$SCRIPT_UNDER_TEST" omp list --root "$ROOT" 2>&1)"
  assert_contains "$out" "bbbb2222" "list shows newest session"
  assert_contains "$out" "Fix the thing" "list shows title"
}

test_missing_root_fails() {
  local out status
  capture_command out status "$SCRIPT_UNDER_TEST" omp --root "$TEST_TMP/nope"
  assert_status "1" "$status" "missing root exits 1"
  assert_contains "$out" "no such directory" "missing root message"
}

build_fixture
"$SCRIPT_UNDER_TEST" omp --root "$ROOT" --json >"$TEST_TMP/all.json"
load_values
run_tests "$@"
