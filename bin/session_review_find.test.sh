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

FAKE_HOME="$TEST_TMP/home"

mk_copilot() { # mk_copilot <id> <date> <prompt>
  local d="$FAKE_HOME/.copilot/session-state/$1"
  mkdir -p "$d"
  printf 'id: %s\ncwd: /work/alpha\nclient_name: copilot-intellij\ncreated_at: %sT10:00:00.000Z\n' "$1" "$2" >"$d/workspace.yaml"
  printf '{"type":"user.message","data":{"content":"%s"},"id":"x","timestamp":"%sT10:00:00.000Z","parentId":null}\n' "$3" "$2" >"$d/events.jsonl"
}

mk_claude() { # mk_claude <id> <date> <prompt>
  mkdir -p "$FAKE_HOME/.claude/projects/-work-beta"
  printf '{"type":"user","message":{"role":"user","content":"%s"},"cwd":"/work/beta","timestamp":"%sT10:00:00.000Z"}\n' "$3" "$2" \
    >"$FAKE_HOME/.claude/projects/-work-beta/$1.jsonl"
}

make_fixture() {
  rm -rf "$FAKE_HOME"
  mk_copilot cafe0001-aaaa 2026-03-01 "older copilot task"
  mk_copilot cafe0002-bbbb 2026-03-02 "newer copilot task"
  mk_claude beef0001-cccc 2026-03-03 "newest claude task"
}

sr() { # sr <args...>: no terminal, no colour, fake HOME; sets OUT and STATUS
  STATUS=0
  OUT="$(HOME="$FAKE_HOME" NO_COLOR=1 "$SCRIPT_UNDER_TEST" "$@" 2>&1 </dev/null)" || STATUS=$?
}

test_list_searches_all_harnesses_newest_first() {
  make_fixture
  sr list
  assert_status "0" "$STATUS" "list exits 0"
  assert_contains "$OUT" "newest claude task" "claude session listed without a path"
  assert_contains "$OUT" "older copilot task" "copilot session listed"
  assert_eq "beef0001" "$(grep -o 'beef0001\|cafe0002\|cafe0001' <<<"$OUT" | head -1)" "newest session is row 1"
  assert_contains "$OUT" "next: session_review show" "list ends with the next step"
  sr list --harness copilot
  assert_not_contains "$OUT" "claude task" "--harness narrows the list"
  sr list --project beta
  assert_not_contains "$OUT" "copilot task" "--project filters"
}

test_show_resolves_row_id_prefix_and_default() {
  make_fixture
  sr show --last --out "$TEST_TMP/o1.html"
  assert_contains "$OUT" "using claude session beef0001" "--last picks the newest and says which"
  assert_eq "yes" "$([[ -s $TEST_TMP/o1.html ]] && echo yes || echo no)" "page written"
  sr show --out "$TEST_TMP/o2.html"
  assert_contains "$OUT" "using claude session beef0001" "no argument and no terminal: latest"
  sr show 3 --out "$TEST_TMP/o3.html"
  assert_contains "$OUT" "using copilot session cafe0001" "row number from list"
  sr show cafe0002 --out "$TEST_TMP/o4.html"
  assert_contains "$OUT" "using copilot session cafe0002" "id prefix found without --harness or --root"
}

test_errors_end_with_a_try_line() {
  make_fixture
  sr show nomatch
  assert_status "2" "$STATUS" "unknown id exits 2"
  assert_contains "$OUT" "try: session_review list" "unknown id suggests list"
  sr show cafe
  assert_status "2" "$STATUS" "ambiguous prefix exits 2"
  assert_contains "$OUT" "matches 2 sessions" "ambiguity explained"
  assert_contains "$OUT" "try: session_review show cafe000" "ambiguity suggests a longer prefix"
  sr show 7
  assert_contains "$OUT" "no row 7 (list has 3)" "row out of range explained"
  rm -rf "$FAKE_HOME"
  sr list
  assert_status "2" "$STATUS" "nothing found exits 2"
  # shellcheck disable=SC2088  # literal ~ is what the tool prints
  assert_contains "$OUT" "~/.copilot/session-state" "error names the folders searched"
}

test_help_is_navigable() {
  sr --help
  # shellcheck disable=SC2088  # literal ~ is what the tool prints
  assert_contains "$OUT" "~/.copilot/session-state" "top help lists where copilot sessions live"
  # shellcheck disable=SC2088
  assert_contains "$OUT" "~/.claude/projects" "top help lists where claude sessions live"
  assert_contains "$OUT" "session_review show 3" "top help has examples"
  sr --help show
  assert_contains "$OUT" "usage: session_review show" "--help before the subcommand explains the subcommand"
  assert_contains "$OUT" "Examples:" "subcommand help has examples"
}

test_picker_on_a_terminal_uses_fzf() {
  make_fixture
  mkdir -p "$TEST_TMP/bin"
  printf '#!/usr/bin/env bash\nhead -2 | tail -1\n' >"$TEST_TMP/bin/fzf"
  chmod +x "$TEST_TMP/bin/fzf"
  local got
  got="$(PATH="$TEST_TMP/bin:$PATH" HOME="$FAKE_HOME" NO_COLOR=1 python3 - "$SCRIPT_UNDER_TEST" "$TEST_TMP/o5.html" <<'PY'
import os, pty, sys
script, out = sys.argv[1:3]
pid, fd = pty.fork()
if pid == 0:
    os.execv(script, [script, "show", "--out", out])
buf = b""
while True:
    try:
        chunk = os.read(fd, 4096)
    except OSError:
        break
    if not chunk:
        break
    buf += chunk
os.waitpid(pid, 0)
print(buf.decode(errors="replace"))
PY
)"
  assert_contains "$got" "using copilot session cafe0002" "fzf's choice (row 2) is opened"
}

run_tests "$@"
