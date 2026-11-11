#!/usr/bin/env bash
# shellcheck disable=SC1090,SC1091,SC2089,SC2090
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
STUB="$TEST_TMP/stub_llm"
CALLS="$TEST_TMP/calls.log"
MARKER="$TEST_TMP/llm_called"

# Writes one omp session: dir-name, id, cwd, date, prompt.
write_session() {
  local dir="$ROOT/$1"
  mkdir -p "$dir"
  cat >"$dir/${4}T10-00-00-000Z_$2.jsonl" <<JSONL
{"type":"session","version":3,"id":"$2","timestamp":"${4}T10:00:00.000Z","cwd":"$3"}
{"type":"message","id":"u1","timestamp":"${4}T10:00:02.000Z","message":{"role":"user","attribution":"user","content":"$5"}}
{"type":"message","id":"a1","timestamp":"${4}T10:00:10.000Z","message":{"role":"assistant","model":"Q","provider":"p","stopReason":"stop","usage":{"input":10,"output":5,"cacheRead":0,"cacheWrite":0,"cost":{"total":0}},"content":[{"type":"toolCall","id":"c1","name":"bash","arguments":{}}]}}
JSONL
}

build_fixture() {
  local i
  for i in 1 2 3 4 5; do
    write_session -src-alpha "alpha000$i" /work/alpha "2026-09-0$i" "alpha task number $i"
  done
  write_session -src-beta beta0001 /work/beta 2026-09-06 "beta task one"
  write_session -src-beta beta0002 /work/beta 2026-09-07 "inject <script>alert(1)</script> here"
  write_session -src-beta beta0003 /work/beta 2026-09-08 "beta task three"

  # Stub LLM: logs map/reduce, saves the prompt, answers per STUB_MODE.
  cat >"$STUB" <<'STUBEOF'
#!/usr/bin/env bash
prompt="$(</dev/stdin)"
: >"$MARKER"
if [[ "$prompt" == *"TASK: REDUCE"* ]]; then kind=reduce; else kind=map; fi
echo "$kind" >>"$CALLS"
mapfile -t lines <"$CALLS"
printf '%s\n' "$prompt" >"$PROMPT_DIR/$kind.${#lines[@]}.txt"
case "$STUB_MODE:$kind" in
  *:map) echo '{"themes":["t"],"projects":[],"wins":[],"friction":[],"notable_prompts":[]}' ;;
  fenced:reduce) printf 'Here you go:\n```json\n%s\n```\nbye\n' "$REDUCE_JSON" ;;
  malformed:reduce)
    if [[ -e "$PROMPT_DIR/retried" ]]; then echo "$REDUCE_JSON"; else : >"$PROMPT_DIR/retried"; echo '{"sections": [oops'; fi ;;
  bad:reduce) echo 'not json at all' ;;
  *:reduce) echo "$REDUCE_JSON" ;;
esac
STUBEOF
  chmod +x "$STUB"
}

REDUCE_JSON='{"sections":[{"title":"What You Work On","paragraphs":["alpha and beta <b>x</b>"],"bullets":["one"]},{"title":"How You Use omp","paragraphs":["p"],"bullets":[]},{"title":"Impressive Things You Did","paragraphs":[],"bullets":["w"]},{"title":"Where Things Go Wrong","paragraphs":["f"],"bullets":[]},{"title":"Existing Features to Try","paragraphs":[],"bullets":["e"]},{"title":"New Ways to Use It","paragraphs":["n"],"bullets":[]}]}'
export REDUCE_JSON MARKER CALLS

# Runs analyze with the stub; sets OUT, ERR (files) and STATUS. Fresh call log per run.
run_analyze() {
  local mode="$1"; shift
  rm -rf "$CALLS" "$MARKER" "$TEST_TMP/prompts"; mkdir -p "$TEST_TMP/prompts"
  PROMPT_DIR="$TEST_TMP/prompts" STUB_MODE="$mode" STATUS=0
  export PROMPT_DIR STUB_MODE
  "$SCRIPT_UNDER_TEST" omp analyze --root "$ROOT" --llm "$STUB" "$@" >"$TEST_TMP/out" 2>"$TEST_TMP/err" || STATUS=$?
  OUT="$(<"$TEST_TMP/out")"
  ERR="$(<"$TEST_TMP/err")"
}

call_count() {
  local n=0 line
  [[ -e "$CALLS" ]] || { echo 0; return; }
  while read -r line; do [[ "$line" == "$1" ]] && n=$((n + 1)); done <"$CALLS"
  echo "$n"
}

test_dry_run_makes_no_llm_call() {
  run_analyze ok --dry-run
  assert_status "0" "$STATUS" "dry-run exits 0"
  assert_eq "no" "$([[ -e $MARKER ]] && echo yes || echo no)" "stub never invoked on dry-run"
  assert_contains "$OUT" "TASK: MAP" "dry-run shows map prompt"
  assert_contains "$OUT" "TASK: REDUCE" "dry-run shows reduce prompt"
  assert_contains "$OUT" "alpha task number 1" "dry-run shows digest content"
}

test_markdown_default_run() {
  run_analyze ok
  assert_status "0" "$STATUS" "analyze exits 0"
  local title
  for title in "What You Work On" "How You Use omp" "Impressive Things You Did" \
    "Where Things Go Wrong" "Existing Features to Try" "New Ways to Use It"; do
    assert_contains "$OUT" "## $title" "markdown section: $title"
  done
  assert_eq "1" "$(call_count map)" "default batch size 40 = 1 map call"
  assert_contains "$ERR" "sending 8 sessions" "privacy line: session count"
  assert_contains "$ERR" "digest bytes" "privacy line: byte count"
  assert_contains "$ERR" "$STUB" "privacy line: names receiving command"
  assert_contains "$(cat "$TEST_TMP"/prompts/map.*.txt)" "<script>alert(1)</script>" "fixture prompt reaches digest"
}

test_html_is_escaped_and_self_contained() {
  local payload='<script>alert(1)</script>'
  REDUCE_JSON="${REDUCE_JSON/<b>x<\/b>/$payload}"
  run_analyze ok --format html
  assert_contains "$OUT" "<!doctype html>" "html doctype"
  assert_contains "$OUT" "prefers-color-scheme: dark" "dark mode css"
  assert_contains "$OUT" "&lt;script&gt;alert(1)&lt;/script&gt;" "LLM text escaped"
  assert_not_contains "$OUT" "<script" "no raw script tag in html"
  assert_not_contains "$OUT" "http" "no external assets"
}

test_batching_and_digest_content() {
  run_analyze ok --batch-size 3
  assert_eq "3" "$(call_count map)" "8 sessions / batch 3 = 3 map calls"
  assert_eq "1" "$(call_count reduce)" "one reduce call"
  local prompt
  prompt="$(cat "$TEST_TMP/prompts/map.1.txt")"
  assert_contains "$prompt" "project=/work/alpha" "digest has project"
  assert_contains "$prompt" "tools=bash:1" "digest has tool mix"
  assert_contains "$prompt" "first_prompt='alpha task number 1'" "digest has first prompt"
  assert_contains "$(cat "$TEST_TMP"/prompts/reduce.*.txt)" '"sessions": 8' "reduce gets aggregate stats"
}

test_code_fenced_json_is_parsed() {
  run_analyze fenced
  assert_status "0" "$STATUS" "fenced json ok"
  assert_contains "$OUT" "## New Ways to Use It" "sections parsed from fenced output"
}

test_malformed_json_retried_once() {
  run_analyze malformed
  assert_status "0" "$STATUS" "retry succeeded"
  assert_eq "2" "$(call_count reduce)" "reduce called twice"
  assert_contains "$OUT" "## What You Work On" "report from retried answer"
}

test_persistent_failure_falls_back_and_exits_nonzero() {
  run_analyze bad
  assert_status "1" "$STATUS" "failure exits 1"
  assert_eq "2" "$(call_count reduce)" "exactly one retry"
  assert_contains "$ERR" "analyze failed" "clear stderr message"
  assert_contains "$OUT" "not json at all" "raw text emitted"
  assert_contains "$OUT" "## Raw LLM output" "raw text under single section"
}

test_project_filter_narrows_digest() {
  run_analyze ok --project beta --batch-size 100 --out "$TEST_TMP/report.md"
  local prompt
  prompt="$(cat "$TEST_TMP/prompts/map.1.txt")"
  assert_contains "$prompt" "beta task one" "beta kept"
  assert_not_contains "$prompt" "alpha task" "alpha dropped"
  assert_contains "$ERR" "sending 3 sessions" "privacy line counts filtered sessions"
  assert_eq "" "$OUT" "nothing on stdout with --out"
  assert_contains "$(<"$TEST_TMP/report.md")" "## What You Work On" "--out file has report"
}

build_fixture
run_tests "$@"
