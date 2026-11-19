#!/usr/bin/env bash
# shellcheck disable=SC1090,SC1091

set -euo pipefail

DOTFILES_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
SCRIPT_UNDER_TEST="$DOTFILES_ROOT/bin/copilot_show"

source "$DOTFILES_ROOT/bin/lib/bash_test.sh"

TEST_TMP="$(mktemp -d)"
cleanup_test_tmp() {
  rm -rf "$TEST_TMP"
}
trap 'cleanup_test_tmp' EXIT

ROOT="$TEST_TMP/session-state"
OUT="$TEST_TMP/out.html"

make_fixture() {
  local d="$ROOT/abcd1234-demo"
  mkdir -p "$d"
  printf 'id: abcd1234-demo\ncwd: /Users/someone/src/stil/api\nclient_name: copilot-intellij\ncreated_at: 2026-03-01T10:00:00.000Z\n' >"$d/workspace.yaml"
  {
    echo '{"type":"user.message","data":{"content":"fix the <login> bug"},"timestamp":"2026-03-01T10:00:00.000Z"}'
    echo '{"type":"assistant.message","data":{"content":"Looking at /Users/someone/src/stil/api now","model":"gpt-x","toolRequests":[{"toolCallId":"c1","name":"bash","arguments":{"command":"npm test"},"intentionSummary":"Run tests"},{"toolCallId":"c2","name":"view","arguments":{"path":"/nope"}}]},"timestamp":"2026-03-01T10:00:01.000Z"}'
    echo '{"type":"tool.execution_complete","data":{"toolCallId":"c1","success":true,"result":{"content":"all green"}},"timestamp":"2026-03-01T10:00:02.000Z"}'
    echo '{"type":"tool.execution_complete","data":{"toolCallId":"c2","success":false,"error":{"message":"Path does not exist"}},"timestamp":"2026-03-01T10:00:03.000Z"}'
    echo '{"type":"user.message","data":{"content":"no, I said the other file"},"timestamp":"2026-03-01T10:01:00.000Z"}'
    echo '{"type":"abort","data":{},"timestamp":"2026-03-01T10:02:00.000Z"}'
  } >"$d/events.jsonl"
}

render() {
  make_fixture
  NO_COLOR=1 "$SCRIPT_UNDER_TEST" --root "$ROOT" "$@" --out "$OUT" >/dev/null
  cat "$OUT"
}

test_renders_prompts_tools_and_summary() {
  local page
  page="$(render abcd1234)"
  assert_contains "$page" "2 prompts · 2 tool calls · 1 failed" "header stats"
  assert_contains "$page" "Run tests" "tool intent summary shown"
  assert_contains "$page" "all green" "tool result shown"
  assert_contains "$page" "✗ view" "failed tool marked"
  assert_contains "$page" "aborted by user" "abort marker shown"
}

test_escapes_html_and_redacts_home() {
  local page
  page="$(render abcd1234)"
  assert_contains "$page" "fix the &lt;login&gt; bug" "user text is HTML-escaped"
  assert_not_contains "$page" "/Users/someone" "home path redacted"
}

test_flags_possible_correction() {
  assert_contains "$(render abcd1234)" "possible correction" "correction-style follow-up flagged"
}

test_ambiguous_or_missing_id_fails() {
  make_fixture
  local rc=0
  "$SCRIPT_UNDER_TEST" --root "$ROOT" zzzz >/dev/null 2>&1 || rc=$?
  assert_not_status 0 "$rc" "unknown session id exits non-zero"
}

run_tests "$@"
