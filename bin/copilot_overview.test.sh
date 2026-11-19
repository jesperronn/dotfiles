#!/usr/bin/env bash
# shellcheck disable=SC1090,SC1091

set -euo pipefail

DOTFILES_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
SCRIPT_UNDER_TEST="$DOTFILES_ROOT/bin/copilot_overview"

source "$DOTFILES_ROOT/bin/lib/bash_test.sh"

TEST_TMP="$(mktemp -d)"
cleanup_test_tmp() {
  rm -rf "$TEST_TMP"
}
trap 'cleanup_test_tmp' EXIT

SESSIONS="$TEST_TMP/sessions"
OUT="$TEST_TMP/overview"

make_fixture() {
  local id d
  rm -rf "$SESSIONS" "$OUT"
  for id in aaaa1111-x bbbb2222-y; do
    d="$SESSIONS/$id"
    mkdir -p "$d"
    printf 'id: %s\ncwd: /work/%s\nclient_name: copilot-intellij\ncreated_at: 2026-03-01T10:00:00.000Z\n' "$id" "$id" >"$d/workspace.yaml"
    {
      echo '{"type":"user.message","data":{"content":"do </script> thing"},"timestamp":"2026-03-01T10:00:00.000Z"}'
      echo '{"type":"assistant.turn_start","data":{},"timestamp":"2026-03-01T10:00:01.000Z"}'
      echo '{"type":"tool.execution_start","data":{"toolName":"view","arguments":{"path":"/a"}},"timestamp":"2026-03-01T10:00:02.000Z"}'
    } >"$d/events.jsonl"
  done
  mkdir -p "$SESSIONS/empty-dir"
}

run_overview() {
  make_fixture
  NO_COLOR=1 "$SCRIPT_UNDER_TEST" "$SESSIONS" >/dev/null
}

test_writes_index_and_one_page_per_session() {
  run_overview
  assert_eq "yes" "$([[ -s "$OUT/index.html" && -s "$OUT/s/aaaa1111.html" && -s "$OUT/s/bbbb2222.html" ]] && echo yes || echo no)" "index and transcripts written"
  assert_contains "$(cat "$OUT/sessions.json")" "s/aaaa1111.html" "list links to transcript"
}

test_index_is_generic_and_data_lives_in_sessions_files() {
  run_overview
  assert_contains "$(cat "$OUT/index.html")" 'src="sessions.js"' "index loads sessions.js"
  assert_not_contains "$(cat "$OUT/index.html")" "aaaa1111" "no session data baked into index"
  assert_eq "2" "$(python3 -c 'import json,sys; print(len(json.load(open(sys.argv[1]))))' "$OUT/sessions.json")" "sessions.json lists both sessions"
  assert_eq "0" "$(grep -c '</' "$OUT/sessions.js")" "sessions.js cannot close a script tag early"
  assert_contains "$(cat "$OUT/sessions.js")" "window.SESSIONS=" "sessions.js assigns the list"
}

test_sessions_without_events_are_skipped() {
  run_overview
  assert_not_contains "$(cat "$OUT/sessions.json")" "empty-dir" "directory without events.jsonl skipped"
}

test_missing_directory_fails() {
  local rc=0
  "$SCRIPT_UNDER_TEST" "$TEST_TMP/nope" >/dev/null 2>&1 || rc=$?
  assert_not_status 0 "$rc" "missing sessions dir exits non-zero"
}

run_tests "$@"
