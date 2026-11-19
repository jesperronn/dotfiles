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
  assert_contains "$(cat "$OUT/index.html")" "s/aaaa1111.html" "index links to transcript"
}

test_embedded_data_cannot_break_out_of_script_tag() {
  run_overview
  local scripts
  scripts="$(grep -c '</script>' "$OUT/index.html")"
  assert_eq "1" "$scripts" "only the real closing script tag appears"
}

test_sessions_without_events_are_skipped() {
  run_overview
  assert_not_contains "$(cat "$OUT/index.html")" "empty-dir" "directory without events.jsonl skipped"
}

test_missing_directory_fails() {
  local rc=0
  "$SCRIPT_UNDER_TEST" "$TEST_TMP/nope" >/dev/null 2>&1 || rc=$?
  assert_not_status 0 "$rc" "missing sessions dir exits non-zero"
}

run_tests "$@"
