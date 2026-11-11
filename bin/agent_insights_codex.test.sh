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

# Writes the shared synthetic fixture tree once (session_index.jsonl sits beside the root, like ~/.codex).
build_fixture() {
  local day1="$ROOT/2026/09/01" day2="$ROOT/2026/09/05" day3="$ROOT/2026/01/01"
  mkdir -p "$day1" "$day2" "$day3"

  cat >"$day1/rollout-2026-09-01T10-00-00-aaaa1111.jsonl" <<'JSONL'
{"timestamp":"2026-09-01T10:00:00.100Z","type":"session_meta","payload":{"id":"aaaa1111","timestamp":"2026-09-01T10:00:00.000Z","cwd":"/work/alpha","originator":"codex-tui","cli_version":"0.1.0","source":"cli","model_provider":"openai","git":{"branch":"feat/x"}}}
{"timestamp":"2026-09-01T10:00:01.000Z","type":"event_msg","payload":{"type":"task_started","turn_id":"t1"}}
{"timestamp":"2026-09-01T10:00:01.100Z","type":"turn_context","payload":{"turn_id":"t1","cwd":"/work/alpha","approval_policy":"on-request","sandbox_policy":{"type":"workspace-write"},"model":"gpt-5.4","effort":"medium"}}
{"timestamp":"2026-09-01T10:00:02.000Z","type":"event_msg","payload":{"type":"item_completed","item":{"type":"UserMessage","content":[{"type":"text","text":"please fix it"}]}}}
{"timestamp":"2026-09-01T10:00:03.000Z","type":"response_item","payload":{"type":"reasoning","summary":[],"encrypted_content":"xxxx"}}
{"timestamp":"2026-09-01T10:00:04.000Z","type":"response_item","payload":{"type":"function_call","name":"exec_command","arguments":"{}","call_id":"c1"}}
{"timestamp":"2026-09-01T10:00:05.000Z","type":"response_item","payload":{"type":"function_call_output","call_id":"c1","output":"Process exited with code 1\nOutput:\nboom"}}
{"timestamp":"2026-09-01T10:00:05.100Z","type":"event_msg","payload":{"type":"item_completed","item":{"type":"CommandExecution","status":"failed","exit_code":1}}}
{"timestamp":"2026-09-01T10:00:06.000Z","type":"response_item","payload":{"type":"function_call","name":"exec_command","arguments":"{}","call_id":"c2"}}
{"timestamp":"2026-09-01T10:00:07.000Z","type":"event_msg","payload":{"type":"item_completed","item":{"type":"CommandExecution","status":"completed","exit_code":0}}}
{"timestamp":"2026-09-01T10:00:08.000Z","type":"response_item","payload":{"type":"custom_tool_call","name":"apply_patch","input":"*** Begin Patch","call_id":"c3"}}
{"timestamp":"2026-09-01T10:00:09.000Z","type":"event_msg","payload":{"type":"item_completed","item":{"type":"FileChange","status":"completed","changes":{"/work/alpha/a.txt":{"type":"add","content":"one\ntwo\n"},"/work/alpha/b.txt":{"type":"update","unified_diff":"@@ -1,2 +1,2 @@\n keep\n-old\n+new\n+more\n"}}}}}
{"timestamp":"2026-09-01T10:00:10.000Z","type":"response_item","payload":{"type":"web_search_call","status":"completed"}}
{"timestamp":"2026-09-01T10:00:11.000Z","type":"response_item","payload":{"type":"message","role":"assistant","content":[{"type":"output_text","text":"done"}]}}
{"timestamp":"2026-09-01T10:00:12.000Z","type":"event_msg","payload":{"type":"token_count","info":{"total_token_usage":{"input_tokens":1000,"cached_input_tokens":600,"cache_write_input_tokens":0,"output_tokens":50,"reasoning_output_tokens":10,"total_tokens":1050}}}}
THIS LINE IS CORRUPT {{{
{"timestamp":"2026-09-01T10:00:30.000Z","type":"event_msg","payload":{"type":"token_count","info":null}}
{"timestamp":"2026-09-01T10:00:40.000Z","type":"event_msg","payload":{"type":"token_count","info":{"total_token_usage":{"input_tokens":3000,"cached_input_tokens":2000,"cache_write_input_tokens":100,"output_tokens":200,"reasoning_output_tokens":40,"total_tokens":3200}}}}
{"timestamp":"2026-09-01T10:00:50.000Z","type":"event_msg","payload":{"type":"turn_aborted","turn_id":"t1","reason":"interrupted"}}
{"timestamp":"2026-09-01T10:01:00.000Z","type":"event_msg","payload":{"type":"task_complete","turn_id":"t1"}}
JSONL

  # Guardian-style subagent session using a local model, compressed when zstd exists.
  cat >"$day2/rollout-2026-09-05T10-00-00-bbbb2222.jsonl" <<'JSONL'
{"timestamp":"2026-09-05T10:00:00.100Z","type":"session_meta","payload":{"id":"bbbb2222","timestamp":"2026-09-05T10:00:00.000Z","cwd":"/work/beta","originator":"Codex Desktop","source":{"subagent":{"other":"guardian"}}}}
{"timestamp":"2026-09-05T10:00:01.000Z","type":"turn_context","payload":{"cwd":"/work/beta","approval_policy":"never","sandbox_policy":{"type":"read-only"},"model":"codex-auto-review","collaboration_mode":{"settings":{"reasoning_effort":"low"}}}}
{"timestamp":"2026-09-05T10:00:02.000Z","type":"event_msg","payload":{"type":"item_completed","item":{"type":"UserMessage","content":[{"type":"text","text":"review"}]}}}
{"timestamp":"2026-09-05T10:00:05.000Z","type":"token_usage_record","payload":{"thread_token_usage":{"input_tokens":70,"cached_input_tokens":0,"cache_write_input_tokens":0,"output_tokens":30,"reasoning_output_tokens":0,"total_tokens":100}}}
JSONL
  if command -v zstd >/dev/null 2>&1; then
    zstd -q --rm "$day2/rollout-2026-09-05T10-00-00-bbbb2222.jsonl"
  fi

  # Old-format rollout: bare header, unwrapped records, exit codes only inside outputs.
  cat >"$day3/rollout-2026-01-01T10-00-00-cccc3333.jsonl" <<'JSONL'
{"id":"cccc3333","timestamp":"2025-12-31T09:00:00.000Z","instructions":"be nice","git":{"branch":"old"}}
{"record_type":"state"}
{"type":"message","role":"user","content":[{"type":"input_text","text":"<environment_context>cwd</environment_context>"}]}
{"type":"message","role":"user","content":[{"type":"input_text","text":"hello old world"}]}
{"type":"message","role":"assistant","content":[{"type":"output_text","text":"hi"}]}
{"type":"function_call","name":"shell","arguments":"{}","call_id":"o1"}
{"type":"function_call_output","call_id":"o1","output":"{\"output\":\"nope\",\"metadata\":{\"exit_code\":2,\"duration_seconds\":0.1}}"}
{"type":"function_call","name":"shell","arguments":"{}","call_id":"o2"}
{"type":"function_call_output","call_id":"o2","output":"{\"output\":\"ok\",\"metadata\":{\"exit_code\":0,\"duration_seconds\":0.1}}"}
JSONL

  : >"$day1/rollout-2026-09-01T11-00-00-empty.jsonl"
  echo '{"id":"aaaa1111","thread_name":"Fix the thing"}' >"$TEST_TMP/session_index.jsonl"
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
a, b, c = by["aaaa1111"], by["bbbb2222"], by["cccc3333"]
tok = lambda s: " ".join(str(s["tokens"][k]) for k in ("input", "output", "cache_read", "cache_write"))
rows = {
    "count": len(by),
    "project": a["project"], "title": a["title"], "first_prompt": a["first_prompt"],
    "turns": f'{a["user_turns"]} {a["assistant_turns"]}', "models": a["models"],
    "meta": " ".join(str(a["extra"][k]) for k in ("originator", "cli_version", "git_branch")),
    "policies": f'{a["extra"]["efforts"]} {a["extra"]["sandbox_policies"]} {a["extra"]["approval_policies"]}',
    "tools": dict(sorted(a["tool_calls"].items())), "errors": a["tool_errors"],
    "tokens": tok(a), "cost": a["cost"],
    "patch": " ".join(str(a["extra"][k]) for k in ("patches", "patch_files", "lines_added", "lines_removed")),
    "corrupt": a["extra"]["corrupt_lines"], "aborted": a["extra"]["aborted_turns"],
    "searches": a["extra"]["web_searches"], "duration_end": a["ended"],
    "sub_flags": f'{b["extra"]["subagent"]} {b["extra"]["subagent_kind"]}',
    "sub_model": b["models"], "sub_effort": b["extra"]["efforts"], "sub_tokens": tok(b),
    "old_prompt": c["first_prompt"], "old_turns": f'{c["user_turns"]} {c["assistant_turns"]}',
    "old_errors": c["tool_errors"], "old_tools": c["tool_calls"], "old_branch": c["extra"]["git_branch"],
    "old_started": c["started"],
}
for k, v in rows.items():
    print(f"{k}\t{v}")
PY
  )
}

count_sessions() {
  "$SCRIPT_UNDER_TEST" codex --root "$ROOT" --json "$@" | python3 -c "import json,sys; print(len(json.load(sys.stdin)['sessions']))"
}

test_sessions_counted_and_empty_file_skipped() {
  assert_eq "3" "${V[count]}" "empty file is not a session; plain, zstd and old-format files all load"
}

test_normal_session_fields() {
  assert_eq "/work/alpha" "${V[project]}" "project from session_meta cwd"
  assert_eq "Fix the thing" "${V[title]}" "title from sibling session_index.jsonl"
  assert_eq "please fix it" "${V[first_prompt]}" "first prompt from UserMessage item"
  assert_eq "1 1" "${V[turns]}" "user and assistant turn counts"
  assert_eq "['gpt-5.4']" "${V[models]}" "model from turn_context"
  assert_eq "codex-tui 0.1.0 feat/x" "${V[meta]}" "originator, cli_version and git branch"
  assert_eq "{'medium': 1} {'workspace-write': 1} {'on-request': 1}" "${V[policies]}" "effort, sandbox and approval distributions"
  assert_eq "1" "${V[aborted]}" "aborted turn counted"
  assert_eq "1" "${V[searches]}" "web search counted"
}

test_tool_calls_and_failures() {
  assert_eq "{'apply_patch': 1, 'exec_command': 2, 'web_search': 1}" "${V[tools]}" "tool calls from function_call, custom_tool_call and web_search_call"
  assert_eq "1" "${V[errors]}" "failure counted once from the status event, not again from the output text"
}

test_patch_stats() {
  assert_eq "1 2 4 1" "${V[patch]}" "patches, files, lines added (2 from add + 2 from diff) and removed"
}

test_last_token_count_wins() {
  assert_eq "900 200 2000 100" "${V[tokens]}" "last cumulative total; input excludes cached and cache-write"
  assert_eq "None" "${V[cost]}" "cost is not recorded"
}

test_corrupt_line_skipped_and_counted() {
  assert_eq "1" "${V[corrupt]}" "corrupt line counted, parsing continued past it"
  assert_eq "2026-09-01T10:01:00.000Z" "${V[duration_end]}" "ended is the last event after the corrupt line"
}

test_subagent_session() {
  assert_eq "1 guardian" "${V[sub_flags]}" "guardian subagent flagged"
  assert_eq "['codex-auto-review']" "${V[sub_model]}" "subagent model"
  assert_eq "{'low': 1}" "${V[sub_effort]}" "effort from collaboration_mode settings"
  assert_eq "70 30 0 0" "${V[sub_tokens]}" "token_usage_record fallback when no token_count"
}

test_old_format_session() {
  assert_eq "hello old world" "${V[old_prompt]}" "first prompt skips injected environment_context"
  assert_eq "1 1" "${V[old_turns]}" "old-format turn counts"
  assert_eq "1" "${V[old_errors]}" "failure from metadata.exit_code in outputs when no status events exist"
  assert_eq "{'shell': 2}" "${V[old_tools]}" "old unwrapped function_call names"
  assert_eq "old" "${V[old_branch]}" "git branch from bare header"
  assert_eq "2025-12-31T09:00:00.000Z" "${V[old_started]}" "started from bare header timestamp"
}

test_since_and_project_filters() {
  assert_eq "1" "$(count_sessions --since 2026-09-03)" "--since drops earlier sessions"
  assert_eq "1" "$(count_sessions --project alpha)" "--project keeps matching cwd"
  assert_eq "0" "$(count_sessions --until 2025-01-01)" "--until before all sessions"
}

test_report_and_list_modes() {
  local out
  out="$("$SCRIPT_UNDER_TEST" codex --root "$ROOT" 2>&1)"
  assert_contains "$out" "codex usage report" "report header"
  assert_contains "$out" "Sessions: 3" "report session count"
  assert_contains "$out" "exec_command" "report lists tools"
  assert_contains "$out" "lines_added=4" "report sums numeric extras"
  out="$("$SCRIPT_UNDER_TEST" codex list --root "$ROOT" 2>&1)"
  assert_contains "$out" "bbbb2222" "list shows newest session"
  assert_contains "$out" "Fix the thing" "list shows title"
}

test_missing_root_fails() {
  local out status
  capture_command out status "$SCRIPT_UNDER_TEST" codex --root "$TEST_TMP/nope"
  assert_status "1" "$status" "missing root exits 1"
  assert_contains "$out" "no such directory" "missing root message"
}

build_fixture
"$SCRIPT_UNDER_TEST" codex --root "$ROOT" --json >"$TEST_TMP/all.json"
load_values
run_tests "$@"
