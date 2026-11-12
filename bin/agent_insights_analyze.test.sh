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

  # One session carries a tool error (with a secret) so digests must show redacted errors=[...].
  echo '{"type":"message","id":"r1","timestamp":"2026-09-08T10:00:11.000Z","message":{"role":"toolResult","toolName":"bash","isError":true,"content":[{"type":"text","text":"tool exploded Bearer abcdef1234567890XYZ"}]}}' \
    >>"$ROOT/-src-beta/2026-09-08T10-00-00-000Z_beta0003.jsonl"
  # ...plus a thinking level, a length-truncated turn and a compaction for the richer digest fields.
  cat >>"$ROOT/-src-beta/2026-09-08T10-00-00-000Z_beta0003.jsonl" <<'JSONL'
{"type":"thinking_level_change","id":"t1","timestamp":"2026-09-08T10:00:12.000Z","thinkingLevel":"high"}
{"type":"message","id":"a2","timestamp":"2026-09-08T10:00:13.000Z","message":{"role":"assistant","model":"Q","provider":"p","stopReason":"length","usage":{"input":1,"output":1,"cacheRead":0,"cacheWrite":0,"cost":{"total":0}},"content":[]}}
{"type":"compaction","id":"k1","timestamp":"2026-09-08T10:00:14.000Z","summary":"s","tokensBefore":100}
JSONL

  # Config fixture with secrets (must be redacted) and a safe key (must survive).
  cat >"$TEST_TMP/cfg.yml" <<'CFG'
base_url: http://localhost:1234
api_key: sk-abc123def456ghi789xyz
headers:
  Authorization: Bearer abcdefghijklmnop123456
provider_tokens:
  - tok-one-secret-value
note: curl -H "Bearer zzzzzzzzzzzz1234"
default_model: qwen3-coder
workdir: /Users/someone/project
CFG

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

SECTIONS='"sections":[{"title":"What You Work On","paragraphs":["alpha and beta <b>x</b>","second para"],"bullets":["one"]},{"title":"How You Use omp","paragraphs":["p"],"bullets":[]},{"title":"Impressive Things You Did","paragraphs":[],"bullets":["w"]},{"title":"Where Things Go Wrong","paragraphs":["f"],"bullets":[]},{"title":"Existing Features to Try","paragraphs":[],"bullets":["e"]},{"title":"New Ways to Use It","paragraphs":["n"],"bullets":[]}]'
GLANCE='"glance":{"working":"GLANCE-WORKING","hindering":"GLANCE-HINDER","quick_wins":"GLANCE-QUICK","ambitious":"GLANCE-AMBIT"}'
HORIZON='"horizon":[{"title":"Overnight refactor","what":"HORIZON-WHAT","prompt":"HORIZON-STARTER-PROMPT"}]'
SUGGESTIONS='"suggestions":[{"target":"AGENTS.md","title":"Run tests <script>alert(3)</script>","why":"why-agents","evidence":"EVID-agents 3 aborted turns","snippet":"- Always run <script>alert(2)</script> tests","lang":"markdown","confidence":"high"},{"target":"omlx model settings","title":"Raise max output tokens","why":"why-omlx verify against the tool docs","evidence":"stopReason length x4","snippet":"","lang":"","confidence":"medium"},{"target":"omp config (~/.omp/agent/config.yml)","title":"Lower thinking","why":"why-omp","evidence":"thinking high","snippet":"thinkingLevel: low","lang":"yaml","confidence":"bogus"},{"target":"pasta","title":"Odd target","why":"w","evidence":"e","snippet":"SNIP-ODD","lang":"text","confidence":"low"}]'
REDUCE_JSON="{$GLANCE,$SECTIONS,$HORIZON,$SUGGESTIONS}"
MIN_JSON="{$SECTIONS}"
export REDUCE_JSON MARKER CALLS

# Runs analyze with the stub; sets OUT, ERR (files) and STATUS. Fresh call log per run; HOME is a temp dir.
run_analyze() {
  local mode="$1"; shift
  rm -rf "$CALLS" "$MARKER" "$TEST_TMP/prompts"; mkdir -p "$TEST_TMP/prompts"
  PROMPT_DIR="$TEST_TMP/prompts" STUB_MODE="$mode" STATUS=0
  export PROMPT_DIR STUB_MODE
  HOME="$TEST_TMP/home" "$SCRIPT_UNDER_TEST" omp analyze --root "$ROOT" --llm "$STUB" "$@" >"$TEST_TMP/out" 2>"$TEST_TMP/err" || STATUS=$?
  OUT="$(<"$TEST_TMP/out")"
  ERR="$(<"$TEST_TMP/err")"
}

call_count() {
  local n=0 line
  [[ -e "$CALLS" ]] || { echo 0; return; }
  while read -r line; do [[ "$line" == "$1" ]] && n=$((n + 1)); done <"$CALLS"
  echo "$n"
}

test_dry_run_and_config_redaction() {
  run_analyze ok --dry-run --no-config
  assert_status "0" "$STATUS" "dry-run exits 0"
  assert_eq "no" "$([[ -e $MARKER ]] && echo yes || echo no)" "stub never invoked on dry-run"
  assert_contains "$OUT" "TASK: MAP" "dry-run shows map prompt"
  assert_contains "$OUT" "TASK: REDUCE" "dry-run shows reduce prompt"
  assert_contains "$OUT" "alpha task number 1" "dry-run shows digest content"
  assert_contains "$OUT" "tool_errors=1 | errors=['tool exploded [redacted]']" "failing session lists its redacted error"
  assert_not_contains "$OUT" "abcdef1234567890" "digest secret never reaches the prompt"
  assert_eq "1" "$(grep -c 'errors=\[' <<<"$OUT")" "only the session with errors gets an errors=[...] field"
  assert_contains "$OUT" "stop_reasons=stop:1,length:1" "digest has stop reasons"
  assert_contains "$OUT" "thinking_last=high" "digest has last thinking level"
  assert_contains "$OUT" "compactions=1" "digest has compactions"
  assert_contains "$OUT" "'shell/prompt'" "reduce prompt lists the target enum"
  assert_contains "$OUT" "never invent flag or key names" "reduce prompt forbids invented keys"
  assert_not_contains "$OUT" "CONFIG FILES (read-only" "no config context by default"
  assert_contains "$ERR" "no config files" "dry-run says no config sent"

  run_analyze ok --dry-run --no-config --config "$TEST_TMP/cfg.yml"
  assert_contains "$OUT" "CONFIG FILES (read-only" "config context included when asked"
  assert_contains "$OUT" "default_model: qwen3-coder" "safe key survives"
  assert_contains "$OUT" "base_url: http://localhost:1234" "other safe key survives"
  assert_contains "$OUT" "api_key: \"[redacted]\"" "api_key value redacted"
  local leak
  for leak in sk-abc123def456 abcdefghijklmnop123456 tok-one-secret zzzzzzzzzzzz1234 /Users/someone; do
    assert_not_contains "$OUT" "$leak" "config secret not in prompt: $leak"
  done
  assert_contains "$OUT" "workdir: ~/project" "home path replaced with ~"
  assert_contains "$ERR" "bytes" "config byte count reported"
  assert_contains "$ERR" "cfg.yml" "config file listed"
}

test_markdown_run_with_config_and_privacy_line() {
  run_analyze ok --format md --no-config --config "$TEST_TMP/cfg.yml"
  assert_status "0" "$STATUS" "analyze exits 0"
  local title
  for title in "At a Glance" "What You Work On" "How You Use omp" "Impressive Things You Did" \
    "Where Things Go Wrong" "Existing Features to Try" "New Ways to Use It" "On the Horizon" "Suggestions"; do
    assert_contains "$OUT" "## $title" "markdown section: $title"
  done
  assert_contains "$OUT" "### omp config (~/.omp/agent/config.yml)" "markdown groups by target"
  assert_contains "$OUT" "- Always run <script>alert(2)</script> tests" "markdown keeps snippet verbatim"
  assert_eq "1" "$(call_count map)" "default batch size 40 = 1 map call"
  assert_contains "$ERR" "sending 8 sessions" "privacy line: session count"
  assert_contains "$ERR" "digest bytes" "privacy line: byte count"
  assert_contains "$ERR" "$STUB" "privacy line: names receiving command"
  assert_contains "$ERR" "cfg.yml (" "privacy line lists config file"
  assert_contains "$ERR" " config bytes" "privacy line lists config byte total"
  assert_contains "$(cat "$TEST_TMP"/prompts/map.*.txt)" "<script>alert(1)</script>" "fixture prompt reaches digest"
  local reduce
  reduce="$(cat "$TEST_TMP"/prompts/reduce.*.txt)"
  assert_contains "$reduce" "default_model: qwen3-coder" "stub received safe config key"
  assert_contains "$reduce" '"length": 1' "reduce stats carry aggregate stop reasons"
  assert_contains "$reduce" '"tool_error_rate": 0.125' "reduce stats carry error rate"
  assert_not_contains "$reduce" "sk-abc123def456" "stub never received the API key"
  assert_not_contains "$reduce" "abcdefghijklmnop123456" "stub never received the Bearer token"
  assert_not_contains "$reduce" "tok-one-secret" "stub never received nested token"

  run_analyze ok --format md --no-config
  assert_contains "$ERR" "no config files" "privacy line: nothing sent by default"
  assert_not_contains "$(cat "$TEST_TMP"/prompts/reduce.*.txt)" "CONFIG FILES (read-only" "no config context by default"
}

test_html_default_path_charts_and_suggestions() {
  run_analyze ok
  local file today
  today="$(date +%F)"
  file="$TEST_TMP/home/.cache/agent_insights/omp-$today.html"
  assert_status "0" "$STATUS" "html default exits 0"
  assert_eq "" "$OUT" "nothing on stdout by default"
  assert_contains "$ERR" "wrote $file" "final path printed to stderr"
  assert_eq "yes" "$([[ -f $file ]] && echo yes || echo no)" "default output file written under HOME cache"
  local page
  page="$(<"$file")"
  assert_contains "$page" "<!doctype html>" "html doctype"
  assert_contains "$page" "prefers-color-scheme: dark" "dark mode css"
  assert_contains "$page" "viewport" "responsive viewport meta"
  local t
  for t in "At a Glance" "What You Work On" "How You Use omp" "Impressive Things You Did" \
    "Where Things Go Wrong" "Existing Features to Try" "New Ways to Use It" "On the Horizon" "Suggestions" \
    GLANCE-WORKING GLANCE-HINDER GLANCE-QUICK GLANCE-AMBIT HORIZON-STARTER-PROMPT; do
    assert_contains "$page" "$t" "html has: $t"
  done
  for t in "Sessions per day" "Hour of day" "Weekday" "Top tools" "Models (sessions using)" "Top projects" \
    "2026-09-01" ">bash<" "/work/alpha" ">Tue<" "Tool error rate" "Tokens in / out" "12h cap" "bar-fill"; do
    assert_contains "$page" "$t" "chart/stat present: $t"
  done
  assert_contains "$page" "Run tests &lt;script&gt;alert(3)&lt;/script&gt;" "suggestion title escaped"
  assert_contains "$page" "- Always run &lt;script&gt;alert(2)&lt;/script&gt; tests" "suggestion snippet escaped"
  assert_eq "1" "$(grep -o '<script' <<<"$page" | wc -l | tr -d ' ')" "only the report's own script tag"
  assert_not_contains "$page" "http" "no external assets"
  assert_contains "$page" "localStorage" "done state persisted via localStorage"
  assert_contains "$page" "navigator.clipboard" "clipboard copy code"
  assert_contains "$page" "execCommand" "textarea fallback copy"
  assert_contains "$page" "Copy all checked" "copy all checked button"
  assert_contains "$page" 'class="cmd-checkbox"' "done checkboxes"
  assert_eq "3" "$(grep -o 'data-copy="snip-' <<<"$page" | wc -l | tr -d ' ')" "copy button only for suggestions with a snippet (3)"
  assert_contains "$page" 'data-copy="hz-1"' "horizon starter prompt has copy button"
  local a b c d
  a="${page%%data-target=\"AGENTS.md\"*}"; b="${page%%data-target=\"omp config*}"
  c="${page%%data-target=\"omlx model settings\"*}"; d="${page%%data-target=\"Other\"*}"
  assert_contains "$page" 'data-target="AGENTS.md"' "AGENTS.md group"
  assert_contains "$page" 'data-target="omlx model settings"' "omlx group"
  assert_contains "$page" 'data-target="Other"' "unknown target mapped to Other"
  local ordered=no
  if ((${#a} < ${#b} && ${#b} < ${#c} && ${#c} < ${#d})); then ordered=yes; fi
  assert_eq "yes" "$ordered" "groups in target-table order"
  assert_contains "$page" '<span class="badge low">low</span></div><div class="cmd-why">w</div>' "bogus confidence falls back to low (Other item)"

  run_analyze ok --out -
  assert_contains "$OUT" "<!doctype html>" "--out - prints html to stdout"
  assert_not_contains "$ERR" "wrote" "no file written for --out -"

  run_analyze ok --out "$TEST_TMP/nested/dir/r.html"
  assert_contains "$(<"$TEST_TMP/nested/dir/r.html")" "On the Horizon" "--out writes (creating dirs)"
}

test_html_without_suggestions_and_open() {
  REDUCE_JSON="$MIN_JSON" run_analyze ok --out - 
  assert_status "0" "$STATUS" "missing suggestions/glance/horizon tolerated"
  assert_contains "$OUT" "What You Work On" "sections still rendered"
  assert_contains "$OUT" "Sessions per day" "charts still rendered"
  assert_not_contains "$OUT" "Copy all checked" "no suggestions block"
  assert_not_contains "$OUT" "At a Glance" "no glance block"
  assert_not_contains "$OUT" 'id="horizon"' "no horizon block"

  mkdir -p "$TEST_TMP/bin"
  printf '#!/usr/bin/env bash\necho "$@" >"%s/opened"\n' "$TEST_TMP" >"$TEST_TMP/bin/open"
  cp "$TEST_TMP/bin/open" "$TEST_TMP/bin/xdg-open"; chmod +x "$TEST_TMP/bin/open" "$TEST_TMP/bin/xdg-open"
  PATH="$TEST_TMP/bin:$PATH" run_analyze ok --open --out "$TEST_TMP/o.html"
  assert_contains "$(<"$TEST_TMP/opened")" "$TEST_TMP/o.html" "--open launches the opener on the file"
}

test_batching_and_digest_content() {
  run_analyze ok --format md --batch-size 3
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
  run_analyze fenced --format md
  assert_status "0" "$STATUS" "fenced json ok"
  assert_contains "$OUT" "## New Ways to Use It" "sections parsed from fenced output"
}

test_malformed_json_retried_once() {
  run_analyze malformed --format md
  assert_status "0" "$STATUS" "retry succeeded"
  assert_eq "2" "$(call_count reduce)" "reduce called twice"
  assert_contains "$OUT" "## What You Work On" "report from retried answer"
}

test_persistent_failure_falls_back_and_exits_nonzero() {
  run_analyze bad --format md
  assert_status "1" "$STATUS" "failure exits 1"
  assert_eq "2" "$(call_count reduce)" "exactly one retry"
  assert_contains "$ERR" "analyze failed" "clear stderr message"
  assert_contains "$OUT" "not json at all" "raw text emitted"
  assert_contains "$OUT" "## Raw LLM output" "raw text under single section"
}

test_project_filter_narrows_digest() {
  run_analyze ok --format md --project beta --batch-size 100 --out "$TEST_TMP/report.md"
  local prompt
  prompt="$(cat "$TEST_TMP/prompts/map.1.txt")"
  assert_contains "$prompt" "beta task one" "beta kept"
  assert_not_contains "$prompt" "alpha task" "alpha dropped"
  assert_contains "$ERR" "sending 3 sessions" "privacy line counts filtered sessions"
  assert_eq "" "$OUT" "nothing on stdout with --out"
  assert_contains "$(<"$TEST_TMP/report.md")" "## What You Work On" "--out file has report"
}

# HOME with fake config + instruction files for every harness (secrets inside must never reach the stub).
build_home() {
  local h="$TEST_TMP/home"
  mkdir -p "$h/.omp/agent" "$h/.pi/agent" "$h/.codex" "$h/.copilot"
  cat >"$h/.omp/agent/config.yml" <<'CFG'
apiKey: sk-omp1234567890abcdef
maxTokens: 8192
contextWindow: 131072
idleThresholdTokens: 5
magicKeywords:
  - ultrawork
githubToken: plainsecretvalue
CFG
  printf 'models:\n  - name: qwen-omp\n    api_key: sk-models1234567890abc\n' >"$h/.omp/agent/models.yml"
  printf '{"defaultModel":"pi-model","apiKey":"sk-pi1234567890abcdef","maxTokens":4096}\n' >"$h/.pi/agent/settings.json"
  printf 'model = "codex-model"\nopenai_api_key = "sk-codex1234567890abc"\n' >"$h/.codex/config.toml"
  printf '{"model":"copilot-model","token":"ghp_0123456789abcdefghijklmnop"}\n' >"$h/.copilot/config.json"
  : >"$h/.codex/AGENTS.md"
  printf -- '- Always run lint before done RULE-ALREADY-THERE\n' >"$h/.copilot/copilot-instructions.md"
  touch -t 202608151200 "$h/.omp/agent/config.yml"
}

test_redaction_is_key_precise() {
  local out
  out="$(python3 -I - "$DOTFILES_ROOT/bin/lib" <<'PY'
import sys
sys.path.insert(0, sys.argv[1])
from agent_insights.analyze import redact_config
print(redact_config("apiKey: sk-abcdefghijklmnop\nmaxTokens: 8192\nidleThresholdTokens: 5\ncontextWindow: 4096\nmagicKeywords: [a]\nauth_token: hunter2\n"))
PY
)"
  assert_contains "$out" 'apiKey: "[redacted]"' "secret apiKey redacted"
  assert_contains "$out" 'auth_token: "[redacted]"' "auth_token redacted"
  assert_not_contains "$out" "hunter2" "plain secret value gone"
  assert_contains "$out" "maxTokens: 8192" "maxTokens count preserved"
  assert_contains "$out" "idleThresholdTokens: 5" "idleThresholdTokens preserved"
  assert_contains "$out" "contextWindow: 4096" "contextWindow preserved"
  assert_contains "$out" "magicKeywords: [a]" "magicKeywords preserved"
}

test_default_configs_and_snapshot() {
  run_analyze ok --dry-run
  assert_contains "$ERR" "config.yml (" "omp default config listed"
  assert_contains "$ERR" "(default)" "default files flagged (default)"
  assert_not_contains "$ERR" "(explicit)" "no explicit flag without --config"
  assert_contains "$ERR" "models.yml" "omp models.yml listed"
  assert_not_contains "$ERR" "AGENTS.md" "missing omp AGENTS.md skipped silently"
  assert_contains "$OUT" "maxTokens: 8192" "maxTokens survives into prompt"
  assert_contains "$OUT" "idleThresholdTokens: 5" "idleThresholdTokens survives into prompt"
  assert_contains "$OUT" "magicKeywords:" "magicKeywords survives into prompt"
  assert_contains "$OUT" "config.yml (modified 2026-08-15 UTC)" "mtime in block header"
  assert_contains "$OUT" "CONFIG SNAPSHOT RULE" "snapshot rule in reduce prompt"
  assert_contains "$OUT" "Never claim a past session misbehaved BECAUSE of a setting" "rule: no blaming settings"
  assert_contains "$OUT" "currently set to X in <file> (modified <date>)" "rule: phrasing for existing keys"
  assert_contains "$OUT" "span 2026-09-01 to 2026-09-08" "session date range in prompt"
  local leak
  for leak in sk-omp1234 sk-models1234 plainsecretvalue; do
    assert_not_contains "$OUT" "$leak" "default config secret not in prompt: $leak"
  done

  run_analyze ok --dry-run --no-config
  assert_contains "$ERR" "no config files" "--no-config reads nothing"
  assert_not_contains "$OUT" "CONFIG FILES (read-only" "--no-config: no config block"

  run_analyze ok --dry-run --config "$HOME_DIR/.omp/agent/config.yml" --config "$TEST_TMP/cfg.yml"
  assert_eq "1" "$(grep -o 'agent/config.yml (' <<<"$ERR" | wc -l | tr -d ' ')" "explicit duplicate of a default listed once"
  assert_contains "$ERR" "cfg.yml (" "extra explicit file listed"
  assert_contains "$ERR" "(explicit)" "explicit file flagged (explicit)"
  assert_contains "$OUT" "default_model: qwen3-coder" "explicit file content added"

  run_analyze ok --format md
  assert_not_contains "$(cat "$TEST_TMP"/prompts/reduce.*.txt)" "sk-omp1234" "stub never receives default-config secret"
  assert_contains "$(cat "$TEST_TMP"/prompts/reduce.*.txt)" "idleThresholdTokens: 5" "stub receives preserved setting"
}

test_other_harness_defaults() {
  local out leak
  out="$(HOME="$HOME_DIR" python3 -I - "$DOTFILES_ROOT/bin/lib" <<'PY'
import sys
sys.path.insert(0, sys.argv[1])
from agent_insights.analyze import config_candidates, load_config_files
for h in ("omp", "pi", "codex", "copilot"):
    text, inc = load_config_files(config_candidates(h))
    print(h, [(p, o) for p, _, o in inc])
    if h != "omp":
        print(text)
PY
)"
  assert_contains "$out" "('~/.pi/agent/settings.json', 'default')" "pi settings read by default"
  assert_contains "$out" "pi-model" "pi content present"
  assert_not_contains "$out" "pi/agent/models.json" "pi missing models.json skipped silently"
  assert_contains "$out" "('~/.codex/config.toml', 'default')" "codex config read by default"
  assert_not_contains "$out" "codex/AGENTS.md" "empty codex AGENTS.md skipped"
  assert_contains "$out" "('~/.copilot/config.json', 'default')" "copilot config read by default"
  assert_contains "$out" "('~/.copilot/copilot-instructions.md', 'default')" "copilot instructions read when present"
  assert_contains "$out" "RULE-ALREADY-THERE" "instruction content present"
  for leak in sk-pi1234 sk-codex1234 ghp_0123456789; do
    assert_not_contains "$out" "$leak" "secret redacted: $leak"
  done
}

HOME_DIR="$TEST_TMP/home"
build_fixture
build_home
run_tests "$@"
