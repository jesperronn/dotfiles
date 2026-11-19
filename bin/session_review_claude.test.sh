#!/usr/bin/env bash
# shellcheck disable=SC1090,SC1091

set -euo pipefail

DOTFILES_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"

source "$DOTFILES_ROOT/bin/lib/bash_test.sh"

TEST_TMP="$(mktemp -d)"
cleanup_test_tmp() {
  rm -rf "$TEST_TMP"
}
trap 'cleanup_test_tmp' EXIT

ROOT="$TEST_TMP/projects"
SID="11111111-aaaa-bbbb-cccc-222222222222"
FIX="$ROOT/-proj/$SID.jsonl"

make_fixture() {
  mkdir -p "$ROOT/-proj/$SID/subagents" "$TEST_TMP/cop"
  {
    echo '{"type":"file-history-snapshot","messageId":"x"}'
    echo 'not json at all'
    echo '{"type":"user","message":{"role":"user","content":"fix the bug"},"cwd":"/work/app","timestamp":"2026-03-01T10:00:00.000Z"}'
    echo '{"type":"user","isMeta":true,"message":{"role":"user","content":"meta caveat"},"timestamp":"2026-03-01T10:00:01.000Z"}'
    echo '{"type":"user","isSidechain":true,"message":{"role":"user","content":"sidechain prompt"},"timestamp":"2026-03-01T10:00:01.000Z"}'
    echo '{"type":"user","message":{"role":"user","content":"<command-name>/clear</command-name>"},"timestamp":"2026-03-01T10:00:01.000Z"}'
    echo '{"type":"assistant","message":{"id":"msg_1","model":"claude-x","content":[{"type":"text","text":"on it"}],"usage":{"input_tokens":10,"output_tokens":1,"cache_read_input_tokens":5,"cache_creation_input_tokens":2}},"timestamp":"2026-03-01T10:00:02.000Z"}'
    echo '{"type":"assistant","message":{"id":"msg_1","model":"claude-x","content":[{"type":"tool_use","id":"t1","name":"Bash","input":{"command":"ls","description":"List files"}}],"usage":{"input_tokens":10,"output_tokens":20,"cache_read_input_tokens":5,"cache_creation_input_tokens":2}},"timestamp":"2026-03-01T10:00:03.000Z"}'
    printf '%s\n' '{"type":"assistant","message":{"id":"msg_2","model":"claude-x","content":[{"type":"tool_use","id":"t2","name":"Edit","input":{"file_path":"/work/app/a.py","old_string":"a\nb","new_string":"c\nd\ne"}},{"type":"tool_use","id":"t3","name":"Task","input":{"prompt":"go explore"}}],"usage":{"input_tokens":30,"output_tokens":7,"cache_read_input_tokens":0,"cache_creation_input_tokens":0}},"timestamp":"2026-03-01T10:00:04.000Z"}'
    echo '{"type":"user","message":{"role":"user","content":[{"type":"tool_result","tool_use_id":"t1","content":"a.py b.py"}]},"timestamp":"2026-03-01T10:00:05.000Z"}'
    echo '{"type":"user","message":{"role":"user","content":[{"type":"tool_result","tool_use_id":"t2","content":[{"type":"text","text":"boom"}],"is_error":true}]},"timestamp":"2026-03-01T10:00:06.000Z"}'
    echo '{"type":"user","message":{"role":"user","content":[{"type":"text","text":"[Request interrupted by user]"}]},"timestamp":"2026-03-01T10:00:07.000Z"}'
    echo '{"type":"system","subtype":"compact_boundary","timestamp":"2026-03-01T10:00:08.000Z"}'
    echo '{"type":"user","message":{"role":"user","content":[{"type":"text","text":"no, the other file"}]},"timestamp":"2026-03-01T10:01:00.000Z"}'
  } >"$FIX"
  echo '{"type":"user","message":{"content":"sub"}}' >"$ROOT/-proj/$SID/subagents/agent-1.jsonl"
  echo '{"type":"session.start","data":{}}' >"$TEST_TMP/cop/events.jsonl"
}

# One python run computes every value; tests read them back by key from $VALUES.
compute_values() {
  make_fixture
  ROOT="$ROOT" FIX="$FIX" SID="$SID" COP="$TEST_TMP/cop" DEST="$TEST_TMP/dest" PYTHONPATH="$DOTFILES_ROOT/bin/lib" python3 - >"$VALUES" <<'PY'
import os
from session_review.adapters import claude
full = claude.load(os.environ['FIX'], os.environ['SID'])
light = claude.load(os.environ['FIX'], os.environ['SID'], full=False)
ev = full['events']
tools = {e['args'].get('command', e['name']): e for e in ev if e['t'] == 'tool'}
lt = [e for e in light['events'] if e['t'] == 'tool']
print('users', [e['text'] for e in ev if e['t'] == 'user'])
print('ls', tools['ls']['ok'], tools['ls']['result'], tools['ls']['summary'])
print('edit', tools['Edit']['ok'], tools['Edit']['result'])
print('usage', full['usage'], full['counts']['turns'], full['counts']['subagents'])
print('markers', [e['kind'] for e in ev if e['t'] == 'marker'])
print('meta', full['project'], full['client'], full['started'], full['models'], full['ended_cleanly'], full['changes'])
print('peek', claude.peek(os.environ['FIX']))
print('detect', claude.detect(os.environ['FIX']), claude.detect(os.environ['COP'] + '/events.jsonl'), claude.detect(os.environ['ROOT']))
print('discover', [s for s, _ in claude.discover(os.environ['ROOT'])])
print('light', [e['t'] for e in light['events'] if e['t'] == 'assistant'], [e['result'] for e in lt], [e['ok'] for e in lt])
claude.copy(os.environ['FIX'], os.environ['DEST'])
PY
}

val() { grep "^$1 " "$VALUES" | cut -d' ' -f2-; }

test_user_events_filter_carriers_meta_sidechain() {
  assert_eq "$(val users)" "['fix the bug', 'no, the other file']" "only real human messages become user events"
}

test_tool_result_pairing_and_errors() {
  assert_eq "$(val ls)" "True a.py b.py List files" "result attaches by tool_use_id, summary from description"
  assert_eq "$(val edit)" "False boom" "is_error -> ok False"
}

test_usage_and_turns_counted_once_per_message_id() {
  assert_eq "$(val usage)" "{'input': 40, 'output': 27, 'cache': 7} 2 1" "duplicate message id counted once (last usage)"
}

test_markers() {
  assert_eq "$(val markers)" "['abort', 'compaction']" "interrupt -> abort, compact_boundary -> compaction"
}

test_metadata_and_changes() {
  assert_eq "$(val meta)" "/work/app claude-code 2026-03-01T10:00:00.000Z ['claude-x'] None {'added': 3, 'removed': 2, 'files': 1}" "metadata and change estimate"
  assert_eq "$(val peek)" "{'project': '/work/app', 'client': 'claude-code', 'started': '2026-03-01T10:00:00.000Z'}" "peek"
}

test_detect() {
  assert_eq "$(val detect)" "True False False" "detect: claude file yes, copilot events.jsonl and directories no"
}

test_discover_skips_subagents() {
  assert_eq "$(val discover)" "['$SID']" "subagents skipped"
}

test_light_mode() {
  assert_eq "$(val light)" "[] [None, None, None] [True, False, True]" "light mode: no assistant text, no results, ok still set"
}

test_copy() {
  assert_eq "$(ls "$TEST_TMP/dest")" "$SID.jsonl" "copy lands <stem>.jsonl in dest"
}

VALUES="$TEST_TMP/values.txt"
compute_values

run_tests "$@"
