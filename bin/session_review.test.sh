#!/usr/bin/env bash
# shellcheck disable=SC1090,SC1091

set -euo pipefail

DOTFILES_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
SCRIPT_UNDER_TEST="$DOTFILES_ROOT/bin/session_review"

source "$DOTFILES_ROOT/bin/lib/bash_test.sh"

TEST_TMP="$(mktemp -d)"
cleanup_test_tmp() {
  rm -rf "$TEST_TMP"
}
trap 'cleanup_test_tmp' EXIT

COPILOT="$TEST_TMP/inv/sessions"
CLAUDE="$TEST_TMP/claude/sessions"
OUT="$TEST_TMP/inv/overview"

ev() { # ev <file> <type> <data-json> <time>
  printf '{"type":"%s","data":%s,"id":"x","timestamp":"2026-03-01T%s.000Z","parentId":null}\n' "$2" "$3" "$4" >>"$1"
}

make_copilot() {
  rm -rf "$TEST_TMP/inv"
  local d="$COPILOT/aaaa1111-x"
  mkdir -p "$d"
  printf 'id: aaaa1111-x\ncwd: /work/alpha\nclient_name: copilot-intellij\ncreated_at: 2026-03-01T10:00:00.000Z\n' >"$d/workspace.yaml"
  ev "$d/events.jsonl" user.message '{"content":"first task"}' 10:00:00
  ev "$d/events.jsonl" tool.execution_start '{"toolCallId":"c1","toolName":"view","arguments":{"path":"/a"}}' 10:01:00
  ev "$d/events.jsonl" user.message '{"content":"second task"}' 10:03:00
}

make_handoff() {
  rm -rf "$TEST_TMP/inv"
  local d="$COPILOT/hand1111-x"
  mkdir -p "$d"
  printf 'id: hand1111-x\ncwd: /work/alpha\nclient_name: github/cli\ncreated_at: 2026-03-01T10:00:00.000Z\n' >"$d/workspace.yaml"
  ev "$d/events.jsonl" user.message '{"content":"continue from docs/HANDOFF.md please"}' 10:00:00
  ev "$d/events.jsonl" tool.execution_start '{"toolCallId":"c1","toolName":"create","arguments":{"path":"docs/plan.md"}}' 10:01:00
  ev "$d/events.jsonl" tool.execution_start '{"toolCallId":"c2","toolName":"create","arguments":{"path":"docs/handoff-next.md"}}' 10:02:00
  d="$COPILOT/plain111-x"
  mkdir -p "$d"
  printf 'id: plain111-x\ncwd: /work/alpha\nclient_name: github/cli\ncreated_at: 2026-03-01T10:00:00.000Z\n' >"$d/workspace.yaml"
  ev "$d/events.jsonl" user.message '{"content":"please explain the explanation of this code"}' 10:00:00
  ev "$d/events.jsonl" tool.execution_start '{"toolCallId":"c1","toolName":"view","arguments":{"path":"/a"}}' 10:01:00
}

make_claude() {
  rm -rf "$TEST_TMP/claude"
  mkdir -p "$CLAUDE"
  {
    echo '{"parentUuid":null,"type":"user","message":{"role":"user","content":"hello claude"},"cwd":"/work/claudeproj","timestamp":"2026-03-01T10:00:00.000Z","sessionId":"s1"}'
    echo '{"parentUuid":"x","type":"assistant","message":{"id":"m1","model":"claude-x","content":[{"type":"text","text":"hi"},{"type":"tool_use","id":"t1","name":"Bash","input":{"command":"ls","description":"List"}}],"usage":{"input_tokens":10,"output_tokens":5}},"timestamp":"2026-03-01T10:01:00.000Z"}'
    echo '{"parentUuid":"y","type":"user","message":{"role":"user","content":[{"type":"tool_result","tool_use_id":"t1","content":"ok"}]},"timestamp":"2026-03-01T10:01:05.000Z"}'
  } >"$CLAUDE/s1aaaaaa.jsonl"
}

build_overview() {
  "$SCRIPT_UNDER_TEST" overview "$1" --out "$OUT" "${@:2}" >/dev/null
}

test_detail_page_has_key_numbers_marks_and_timings() {
  make_copilot
  build_overview "$COPILOT"
  local page
  page="$(cat "$OUT/s/aaaa1111.html")"
  assert_contains "$page" '<span class="k">msgs</span>' "key numbers in header"
  assert_contains "$page" 'id="fav"' "favourite control present"
  assert_contains "$page" 'id="note"' "notes field present"
  assert_contains "$page" "agent <b>1m 00s</b> · you <b>2m 00s</b>" "timings split agent and you"
  assert_contains "$page" '"key": "session_review_v1:inv"' "storage key matches the overview's"
}

test_standalone_show_has_numbers_but_no_marks() {
  make_copilot
  "$SCRIPT_UNDER_TEST" show aaaa1111 --harness copilot --root "$COPILOT" --out "$TEST_TMP/s.html" >/dev/null
  assert_contains "$(cat "$TEST_TMP/s.html")" '<span class="k">tokens</span>' "key numbers shown"
  assert_not_contains "$(cat "$TEST_TMP/s.html")" 'id="fav"' "no favourite controls outside an investigation"
}

test_overview_detects_claude_harness_and_writes_label_metadata() {
  make_claude
  build_overview "$CLAUDE"
  local json
  json="$(cat "$OUT/sessions.json")"
  assert_contains "$json" '"harness": "claude"' "claude detected without --harness"
  assert_contains "$json" '"metricTips"' "metric tips travel with the data"
  assert_contains "$(cat "$OUT/s/s1aaaaaa.html")" "List" "claude tool summary rendered"
}

test_shortlist_detects_harness_from_root() {
  make_claude
  local out
  out="$("$SCRIPT_UNDER_TEST" shortlist --root "$CLAUDE" --min-turns 0 --bucket good --top 3 --recurring 0)"
  assert_contains "$out" "s1aaaaaa" "claude session listed"
}

labels_of() { # labels_of <session-id-prefix>: comma-joined label names from sessions.json
  python3 -c 'import json,sys; d=json.load(open(sys.argv[1]))["sessions"]; print(",".join(l["name"] for s in d if s["id"].startswith(sys.argv[2]) for l in s["labels"]))' "$OUT/sessions.json" "$1"
}

test_structural_labels_for_handoff_and_plan() {
  make_handoff
  build_overview "$COPILOT"
  local with without
  with="$(labels_of hand1111)"
  without="$(labels_of plain111)"
  assert_contains "$with" "starts-handoff" "first message mentioning HANDOFF.md labelled"
  assert_contains "$with" "ends-handoff" "handoff file written at the end labelled"
  assert_contains "$with" "ends-plan" "plan file written at the end labelled"
  assert_not_contains "$without" "ends-plan" "explain/explanation does not count as a plan"
  assert_not_contains "$without" "handoff" "plain session has no handoff label"
}

test_unknown_harness_fails() {
  local rc=0
  "$SCRIPT_UNDER_TEST" shortlist --harness nope >/dev/null 2>&1 || rc=$?
  assert_not_status 0 "$rc" "unknown harness exits non-zero"
}

run_tests "$@"
