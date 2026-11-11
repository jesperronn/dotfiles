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

ROOT="$TEST_TMP/session-state"

make_fixture() {
  local d="$ROOT/aaaa-normal" b="$ROOT/bbbb-crashed" c="$ROOT/cccc-noevents"
  mkdir -p "$d" "$b" "$c" "$ROOT/dddd-empty"

  cat >"$d/workspace.yaml" <<'YAML'
id: aaaa-normal
cwd: /work/alpha
client_name: github/cli
name: |-
  # Task: do the thing

  more detail
created_at: 2026-03-01T10:00:00.000Z
updated_at: 2026-03-01T10:30:00.000Z
YAML
  {
    echo '{"type":"session.start","data":{"sessionId":"aaaa-normal","startTime":"2026-03-01T10:00:00.000Z"},"id":"1","timestamp":"2026-03-01T10:00:00.000Z","parentId":null}'
    echo '{"type":"session.model_change","data":{"newModel":"gpt-x"},"id":"2","timestamp":"2026-03-01T10:00:01.000Z","parentId":"1"}'
    echo '{"type":"user.message","data":{"content":"hello there"},"id":"3","timestamp":"2026-03-01T10:00:02.000Z","parentId":"2"}'
    echo 'this line is {corrupt'
    echo '{"type":"assistant.turn_start","data":{"turnId":"0"},"id":"4","timestamp":"2026-03-01T10:00:03.000Z","parentId":"3"}'
    echo '{"type":"tool.execution_start","data":{"toolCallId":"t1","toolName":"view","arguments":{}},"id":"5","timestamp":"2026-03-01T10:00:04.000Z","parentId":"4"}'
    echo '{"type":"tool.execution_start","data":{"toolCallId":"t2","toolName":"view","arguments":{}},"id":"6","timestamp":"2026-03-01T10:00:05.000Z","parentId":"4"}'
    echo '{"type":"tool.execution_start","data":{"toolCallId":"t3","toolName":"bash","arguments":{}},"id":"7","timestamp":"2026-03-01T10:00:06.000Z","parentId":"4"}'
    echo '{"type":"tool.execution_complete","data":{"toolCallId":"t3","success":false,"error":{"message":"boom"}},"id":"8","timestamp":"2026-03-01T10:00:07.000Z","parentId":"7"}'
    echo '{"type":"tool.execution_complete","data":{"toolCallId":"t1","success":true},"id":"9","timestamp":"2026-03-01T10:00:08.000Z","parentId":"5"}'
    echo '{"type":"assistant.turn_start","data":{"turnId":"1"},"id":"10","timestamp":"2026-03-01T10:00:09.000Z","parentId":"9"}'
    echo '{"type":"session.shutdown","data":{"shutdownType":"routine","totalPremiumRequests":3,"totalNanoAiu":1000,"totalApiDurationMs":500,"codeChanges":{"linesAdded":10,"linesRemoved":4,"filesModified":["/a","/b"]},"modelMetrics":{"gpt-x":{"requests":{"count":2,"cost":3},"usage":{"inputTokens":1000,"outputTokens":50,"cacheReadTokens":600,"cacheWriteTokens":100}}},"currentModel":"gpt-x"},"id":"11","timestamp":"2026-03-01T10:30:00.000Z","parentId":"10"}'
  } >"$d/events.jsonl"

  cat >"$b/workspace.yaml" <<'YAML'
id: bbbb-crashed
cwd: /work/beta
client_name: copilot-intellij
created_at: 2026-04-01T08:00:00.000Z
YAML
  {
    echo '{"type":"session.start","data":{},"id":"1","timestamp":"2026-04-01T08:00:00.000Z","parentId":null}'
    echo '{"type":"user.message","data":{"content":"crash me"},"id":"2","timestamp":"2026-04-01T08:00:01.000Z","parentId":"1"}'
    echo '{"type":"session.usage_record","data":{"usage":{"model":"gpt-y","inputTokens":500,"outputTokens":20,"cacheReadTokens":300,"cacheWriteTokens":0}},"id":"3","timestamp":"2026-04-01T08:05:00.000Z","parentId":"2"}'
  } >"$b/events.jsonl"

  cat >"$c/workspace.yaml" <<'YAML'
id: cccc-noevents
cwd: /work/gamma
created_at: 2026-05-01T08:00:00.000Z
YAML
}

run_cli() {
  NO_COLOR=1 "$SCRIPT_UNDER_TEST" copilot --root "$ROOT" "$@"
}

# Load the fixture once and flatten everything asserted below into "key=value" lines (one python call).
FACTS=""
load_facts() {
  [[ -n "$FACTS" ]] && return 0
  make_fixture
  FACTS="$(run_cli --json | python3 -c '
import json, sys
d = json.load(sys.stdin)
by = {s["id"]: s for s in d["sessions"]}
a, b, c = by["aaaa-normal"], by["bbbb-crashed"], by["cccc-noevents"]
x = d["summary"]["extra_totals"]
f = {
  "count": len(by), "a_project": a["project"], "a_title": a["title"], "a_prompt": a["first_prompt"],
  "a_turns": "%d %d" % (a["user_turns"], a["assistant_turns"]),
  "a_tools": sorted(a["tool_calls"].items()), "a_errors": a["tool_errors"], "a_cost": a["cost"],
  "a_tokens": " ".join(str(int(a["tokens"][k])) for k in ("input", "cache_read", "cache_write", "output")),
  "b_no_shutdown": b["extra"]["no_shutdown"], "b_ended": b["ended"],
  "b_tokens": " ".join(str(int(b["tokens"][k])) for k in ("input", "cache_read", "output")),
  "c_no_events": c["extra"]["no_events"], "c_project": c["project"],
  "premium": int(x["premium_requests"]), "nano": int(x["nano_aiu"]), "shutdown_routine": int(x["shutdown_routine"]),
  "lines": " ".join(str(int(x[k])) for k in ("lines_added", "lines_removed", "files_modified")),
  "clients": "%d %d" % (x["client_github_cli"], x["client_copilot_intellij"]),
}
for k, v in f.items():
  print("%s=%s" % (k, v))
')"
}

fact() {
  load_facts
  local line
  while IFS= read -r line; do
    [[ "$line" == "$1="* ]] && { printf '%s' "${line#*=}"; return 0; }
  done <<<"$FACTS"
  return 1
}

test_normal_session_with_shutdown_metrics() {
  load_facts
  assert_eq "4" "$(fact count)" "all four session dirs loaded (empty dir included)"
  assert_eq "/work/alpha" "$(fact a_project)" "project from workspace cwd"
  assert_eq "Task: do the thing" "$(fact a_title)" "title is first line of block-scalar name"
  assert_eq "hello there" "$(fact a_prompt)" "first prompt captured"
  assert_eq "1 2" "$(fact a_turns)" "user and assistant turn counts"
  assert_eq "[('bash', 1), ('view', 2)]" "$(fact a_tools)" "tool calls counted by name"
  assert_eq "300 600 100 50" "$(fact a_tokens)" "uncached input, cache_read, cache_write, output from modelMetrics"
  assert_eq "None" "$(fact a_cost)" "cost stays None"
}

test_tool_error_counted() {
  load_facts
  assert_eq "1" "$(fact a_errors)" "failed tool completion counted once"
}

test_corrupt_line_tolerated() {
  load_facts
  assert_eq "1 2" "$(fact a_turns)" "events after the corrupt line are still counted"
}

test_extra_totals_premium_and_lines() {
  load_facts
  assert_eq "3" "$(fact premium)" "premium requests totalled"
  assert_eq "10 4 2" "$(fact lines)" "lines added/removed and files modified totalled"
  assert_eq "1000" "$(fact nano)" "nano AIU totalled"
  assert_eq "1" "$(fact shutdown_routine)" "shutdown type distribution recorded"
  assert_contains "$(run_cli)" "premium_requests=3" "report prints premium request total"
}

test_session_without_shutdown() {
  load_facts
  assert_eq "1" "$(fact b_no_shutdown)" "no_shutdown flagged"
  assert_eq "200 300 20" "$(fact b_tokens)" "tokens fall back to usage_record events"
  assert_eq "2026-04-01T08:05:00.000Z" "$(fact b_ended)" "ended is last event timestamp"
}

test_missing_events_file() {
  load_facts
  assert_eq "1" "$(fact c_no_events)" "no_events flagged"
  assert_eq "/work/gamma" "$(fact c_project)" "metadata still read from workspace.yaml"
}

test_client_name_recorded() {
  load_facts
  assert_eq "1 1" "$(fact clients)" "client names counted"
}

test_since_and_project_filters() {
  load_facts
  local out
  out="$(run_cli list --since 2026-04-01)"
  assert_not_contains "$out" "aaaa-nor" "--since drops the March session"
  assert_contains "$out" "bbbb-cra" "--since keeps April session"
  out="$(run_cli list --project alpha)"
  assert_contains "$out" "aaaa-nor" "--project keeps matching cwd"
  assert_not_contains "$out" "bbbb-cra" "--project drops non-matching cwd"
  out="$(run_cli list --until 2026-03-31)"
  assert_not_contains "$out" "cccc-noe" "--until drops later sessions"
}

test_list_mode() {
  load_facts
  local out
  out="$(run_cli list)"
  assert_contains "$out" "aaaa-nor" "list shows normal session id"
  assert_contains "$out" "/work/beta" "list shows project"
  assert_contains "$out" "Task: do the thing" "list shows title"
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
  mkdir -p "$errroot/err-1"
  printf 'id: err-1\ncwd: /work/err\nclient_name: github/cli\ncreated_at: 2026-09-01T10:00:00.000Z\n' >"$errroot/err-1/workspace.yaml"
  cat >"$errroot/err-1/events.jsonl" <<'JSONL'
{"type":"user.message","data":{"content":"please fix it"},"id":"1","timestamp":"2026-09-01T10:00:01.000Z"}
{"type":"tool.execution_complete","data":{"toolCallId":"t1","success":false,"error":{"message":"curl failed: Authorization: Bearer abcdef1234567890XYZ at /Users/alice/src/app","code":"failure"}},"id":"2","timestamp":"2026-09-01T10:00:02.000Z"}
{"type":"session.error","data":{"errorType":"query","message":"401 key sk-abcdefghijklmnop1234 token ghp_abcdefghijklmnopqrstuvwxyz0123456789 hash 0123456789abcdef0123456789abcdef01234567","statusCode":401},"id":"3","timestamp":"2026-09-01T10:00:03.000Z"}
{"type":"tool.execution_complete","data":{"toolCallId":"t2","success":false,"error":{"message":"curl failed: Authorization: Bearer abcdef1234567890XYZ at /Users/alice/src/app","code":"failure"}},"id":"4","timestamp":"2026-09-01T10:00:04.000Z"}
{"type":"tool.execution_complete","data":{"toolCallId":"t3","success":false,"error":{"message":"word word word word word word word word word word word word word word word word word word word word word word word word word word word word word word word word word word word word word word word word word word word word word word word word word word word word word word word word word word word word","code":"failure"}},"id":"5","timestamp":"2026-09-01T10:00:05.000Z"}
{"type":"tool.execution_complete","data":{"toolCallId":"t4","success":false,"error":{"message":"dropped-fourth","code":"failure"}},"id":"6","timestamp":"2026-09-01T10:00:06.000Z"}
{"type":"tool.execution_complete","data":{"toolCallId":"t5","success":true},"id":"7","timestamp":"2026-09-01T10:00:07.000Z"}
JSONL
  out="$(errors_of copilot "$errroot")"
  assert_eq "3" "$(head -n1 <<<"$out")" "at most 3 distinct errors kept (duplicate and fourth dropped)"
  assert_contains "$out" "curl failed: Authorization: [redacted] at ~/src/app" "Authorization header redacted and /Users/<name> replaced by ~"
  assert_contains "$out" "401 key [redacted] token [redacted] hash [redacted]" "sk- and ghp_ keys and 40-char hex redacted"
  assert_not_contains "$out" "abcdef1234567890" "secret values do not appear"
  assert_not_contains "$out" "/Users/alice" "home directory never appears"
  assert_not_contains "$out" "please fix it" "user prompts are never captured as errors"
  assert_not_contains "$out" "dropped-fourth" "fourth distinct error dropped"
  assert_contains "$out" "word word…" "long message truncated to 200 chars with ellipsis"
}


test_missing_root_fails() {
  local out status
  capture_command out status "$SCRIPT_UNDER_TEST" copilot --root "$TEST_TMP/nope"
  assert_not_status "0" "$status" "nonexistent root exits non-zero"
  assert_contains "$out" "no such directory" "error explains missing root"
}

run_tests "$@"
