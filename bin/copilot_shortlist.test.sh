#!/usr/bin/env bash
# shellcheck disable=SC1090,SC1091

set -euo pipefail

DOTFILES_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
SCRIPT_UNDER_TEST="$DOTFILES_ROOT/bin/copilot_shortlist"

source "$DOTFILES_ROOT/bin/lib/bash_test.sh"

TEST_TMP="$(mktemp -d)"
cleanup_test_tmp() {
  rm -rf "$TEST_TMP"
}
trap 'cleanup_test_tmp' EXIT

ROOT="$TEST_TMP/session-state"

ev() { # ev <file> <type> <data-json> <time>
  printf '{"type":"%s","data":%s,"id":"x","timestamp":"2026-03-01T%s.000Z","parentId":null}\n' "$2" "$3" "$4" >>"$1"
}

mk_session() { # mk_session <id> <cwd>
  mkdir -p "$ROOT/$1"
  printf 'id: %s\ncwd: %s\nclient_name: copilot-intellij\ncreated_at: 2026-03-01T10:00:00.000Z\n' "$1" "$2" >"$ROOT/$1/workspace.yaml"
}

make_fixture() {
  local f i j
  rm -rf "$ROOT"
  mk_session badbadbad /work/alpha
  f="$ROOT/badbadbad/events.jsonl"
  ev "$f" user.message '{"content":"build the login page with tests"}' 10:00:00
  for i in 1 2 3 4 5; do
    ev "$f" assistant.turn_start '{}' "10:0$i:00"
    ev "$f" tool.execution_start '{"toolName":"bash","arguments":{"command":"npm test"}}' "10:0$i:01"
    ev "$f" tool.execution_complete '{"success":false,"error":{"message":"boom"}}' "10:0$i:02"
  done
  ev "$f" user.message '{"content":"no, do not touch the config files again please"}' 10:06:00
  ev "$f" user.message '{"content":"no, do not touch the config files again please"}' 10:07:00
  ev "$f" abort '{}' 10:08:00

  mk_session goodgoodgood /work/beta
  f="$ROOT/goodgoodgood/events.jsonl"
  ev "$f" user.message '{"content":"add a readme"}' 10:00:00
  for i in 1 2 3 4; do
    ev "$f" assistant.turn_start '{}' "10:0$i:00"
    for j in 1 2 3; do
      ev "$f" tool.execution_start "{\"toolName\":\"view\",\"arguments\":{\"path\":\"/f$i$j\"}}" "10:0$i:01"
    done
  done
  ev "$f" session.shutdown '{"shutdownType":"routine","codeChanges":{"linesAdded":120,"linesRemoved":2,"filesModified":["/a"]},"tokenDetails":{"output":{"tokenCount":500},"input":{"tokenCount":100}}}' 10:09:00

  mk_session benchbench /Users/jesper/src/local-model-evaluator-bench/x
  f="$ROOT/benchbench/events.jsonl"
  ev "$f" user.message '{"content":"bench"}' 10:00:00
  for i in 1 2 3; do ev "$f" assistant.turn_start '{}' "10:0$i:00"; done
}

run_cli() {
  NO_COLOR=1 "$SCRIPT_UNDER_TEST" --root "$ROOT" "$@"
}

test_bad_session_flagged_with_labels() {
  make_fixture
  local out
  out="$(run_cli --bucket bad --top 2)"
  assert_contains "$out" "badbadba" "bad session is listed"
  assert_contains "$out" "tool-loop" "identical failing tool call labelled as loop"
  assert_contains "$out" "user-corrections" "correction phrasing labelled"
  assert_contains "$out" "repeated-instruction" "restated instruction labelled"
  assert_contains "$out" "aborted" "abort labelled"
}

test_good_session_ranks_first_in_good_bucket() {
  make_fixture
  local first
  first="$(run_cli --bucket good --top 1 | sed -n '5p')"
  assert_contains "$first" "goodgood" "clean session tops the good bucket"
  assert_contains "$first" "+120/-2" "line changes shown"
}

test_bench_sessions_excluded_by_default() {
  make_fixture
  assert_not_contains "$(run_cli --bucket all)" "benchben" "bench session hidden"
  assert_contains "$(run_cli --include-bench --bucket all --top 5)" "benchben" "bench session shown with flag"
}

test_copy_writes_session_files() {
  make_fixture
  run_cli --bucket bad --top 1 --copy "$TEST_TMP/out" >/dev/null 2>&1
  assert_eq "yes" "$([[ -s "$TEST_TMP/out/badbadbad/events.jsonl" && -s "$TEST_TMP/out/badbadbad/workspace.yaml" ]] && echo yes || echo no)" "events and workspace copied"
}

test_json_format_parses() {
  make_fixture
  assert_eq "ok" "$(run_cli --format json --bucket bad --top 1 | python3 -c 'import json,sys; d=json.load(sys.stdin); print("ok" if d["bad"] else "no")')" "json output parses"
}

test_project_filter_keeps_only_matching_cwd() {
  make_fixture
  local out
  out="$(run_cli --project /work/beta --bucket all --top 5)"
  assert_contains "$out" "goodgood" "matching project kept"
  assert_not_contains "$out" "badbadba" "other project dropped"
}

run_tests "$@"
