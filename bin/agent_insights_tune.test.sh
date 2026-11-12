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

HOME_DIR="$TEST_TMP/home"
ROOT="$TEST_TMP/sessions"
STUB="$TEST_TMP/stub_llm"
CALLS="$TEST_TMP/calls.log"
MARKER="$TEST_TMP/llm_called"

# Builds fake sessions (omp format), fake omlx/MTPLX data under a temp HOME, and a stub LLM.
# Never touches the real HOME. Alpha: 4 sessions (one shared with beta, one 13h long, one with a compaction);
# beta: 3 sessions; gamma: 2 sessions (below the 3-session default threshold).
build_fixture() {
  python3 -I - "$ROOT" "$HOME_DIR" <<'PY'
import json, os, sqlite3, sys
from datetime import datetime, timedelta, timezone

root, home = sys.argv[1:3]
os.makedirs(root, exist_ok=True)


def ts(day, hour=10, plus=0):
    return (datetime.fromisoformat(f"{day}T{hour:02d}:00:00+00:00") + timedelta(seconds=plus)).strftime("%Y-%m-%dT%H:%M:%S.000Z")


def session(sid, day, models, errors=0, last_stop="stop", compaction=False, hours=0):
    lines = [{"type": "session", "version": 3, "id": sid, "timestamp": ts(day), "cwd": "/work/" + sid[:5]},
             {"type": "message", "id": "u", "timestamp": ts(day, plus=1),
              "message": {"role": "user", "attribution": "user", "content": f"task {sid}"}}]
    for i in range(4):
        stop = last_stop if i == 3 else "toolUse"
        lines.append({"type": "message", "id": f"a{i}", "timestamp": ts(day, plus=10 + i),
                      "message": {"role": "assistant", "model": models[i % len(models)].rsplit("/", 1)[-1],
                                  "provider": models[i % len(models)].rsplit("/", 1)[0], "stopReason": stop,
                                  "usage": {"input": 100, "output": 50, "cacheRead": 300, "cacheWrite": 0, "cost": {"total": 0}},
                                  "content": [{"type": "toolCall", "id": f"c{i}", "name": "bash", "arguments": {}}]}})
    for i in range(errors):
        lines.append({"type": "message", "id": f"r{i}", "timestamp": ts(day, plus=20 + i),
                      "message": {"role": "toolResult", "toolName": "bash", "isError": True,
                                  "content": [{"type": "text", "text": "boom: bad args"}]}})
    if compaction:
        lines.append({"type": "compaction", "id": "k", "timestamp": ts(day, plus=30), "summary": "s", "tokensBefore": 1})
    if hours:
        lines.append({"type": "custom", "id": "z", "timestamp": ts(day, plus=hours * 3600)})
    d = os.path.join(root, "-work-" + sid[:5])
    os.makedirs(d, exist_ok=True)
    with open(os.path.join(d, f"{day}T10-00-00-000Z_{sid}.jsonl"), "w") as fh:
        fh.write("\n".join(json.dumps(x) for x in lines) + "\n")


A1, A2, A3 = "omlx/Alpha-Model-4bit", "litellm/omlx/alpha-model-4bit", "lm-studio/Alpha-Model-4bit"
B = "mtplx/mtplx-beta-model"
session("alpha0001", "2026-09-01", [A1], errors=2, last_stop="length")
session("alpha0002", "2026-09-02", [A2], compaction=True)
session("alpha0003", "2026-09-02", [A3], hours=13)
session("alpha0004", "2026-09-03", [A1, B], errors=2)  # shared with beta
session("beta00001", "2026-09-02", [B])
session("beta00002", "2026-09-03", [B])
session("gamma0001", "2026-09-05", ["omlx/Gamma-Model"])
session("gamma0002", "2026-09-05", ["omlx/Gamma-Model"])

# ---- omlx ----
omlx = os.path.join(home, ".omlx")
os.makedirs(omlx)
json.dump({"version": "1.0", "server": {"port": 8000, "cors_origins": ["*"]},
           "scheduler": {"max_concurrent_requests": 10}, "idle_timeout": {"idle_timeout_seconds": 1800},
           "sampling": {"max_context_window": 32768, "max_tokens": 32768},
           "auth": {"api_key": "sk-OMLXSECRET0123456789", "secret_key": "deadbeef" * 8},
           "integrations": {"web_search_brave_api_key": "BRAVESECRET99887766"}},
          open(os.path.join(omlx, "settings.json"), "w"))
json.dump({"version": 1, "models": {
    "Alpha-Model-4bit": {"max_tokens": 2048, "enable_thinking": True, "thinking_budget_tokens": 800,
                         "qwen35_ane_prefill_fraction": 0.5, "hf_token": "hf_MODELSECRET0011223344", "ttl_seconds": 600},
    "Beta-Model": {"max_tokens": 4096}}}, open(os.path.join(omlx, "model_settings.json"), "w"))
json.dump({"per_model": {"Alpha-Model-4bit": {"prompt_tokens": 9000, "completion_tokens": 900, "cached_tokens": 4500,
                                                "requests": 77, "prefill_duration": 45.0, "generation_duration": 90.0}}},
          open(os.path.join(omlx, "stats.json"), "w"))


def epoch(text):
    return int(datetime.fromisoformat(text + "+00:00").timestamp())


con = sqlite3.connect(os.path.join(omlx, "usage.sqlite3"))
con.execute("""CREATE TABLE model_usage_hourly (timestamp_hour INTEGER NOT NULL, model_id TEXT NOT NULL,
  requests INTEGER NOT NULL, prompt_tokens INTEGER NOT NULL, completion_tokens INTEGER NOT NULL,
  cached_tokens INTEGER NOT NULL, prefill_seconds REAL NOT NULL, generation_seconds REAL NOT NULL,
  request_seconds REAL NOT NULL, timed_requests INTEGER NOT NULL, PRIMARY KEY (timestamp_hour, model_id)) WITHOUT ROWID""")
for when, model, req in (("2026-09-02T12:00:00", "Alpha-Model-4bit", 10), ("2026-08-01T12:00:00", "Alpha-Model-4bit", 999),
                         ("2026-09-02T13:00:00", "Beta-Model", 5)):
    con.execute("INSERT INTO model_usage_hourly VALUES (?,?,?,?,?,?,?,?,?,?)",
                (epoch(when), model, req, 1000, 100, 500, 5.0, 10.0, 20.0, req))
con.commit()
con.close()

logdir = os.path.join(home, "Library", "Application Support", "omlx", "logs")
os.makedirs(logdir)


def chat(day, clock, model, fr, tps=30.0):
    return (f"{day} {clock},100 - omlx.server - INFO - Chat completion: model={model}, 20 tokens in 2.00s "
            f"({tps} tok/s), prompt: 5000, finish_reason={fr}, max_tokens=1024, stream_model_ttft=1.50s\n")


with open(os.path.join(logdir, "server.log"), "w") as fh:
    for i in range(3000):  # in-window lines that a bounded tail must never reach
        fh.write(chat("2026-09-01", "09:00:00", "Alpha-Model-4bit", "length"))
    filler = "2026-09-02 11:00:00,100 - omlx.scheduler - INFO - Cache phase timings: " + "x" * 2000 + "\n"
    for i in range(1100):  # ~2.2 MB of non-matching recent lines
        fh.write(filler)
    fh.write(chat("2026-09-02", "12:00:01", "Alpha-Model-4bit", "tool_calls", 20.0))
    fh.write(chat("2026-09-02", "12:00:02", "Alpha-Model-4bit", "length", 40.0))
    fh.write(chat("2026-09-02", "12:00:03", "Alpha-Model-4bit", "stop", 30.0))
    fh.write(chat("2026-09-02", "12:00:04", "Beta-Model", "stop"))
    fh.write("2026-09-02 12:10:00,100 - omlx.engine_pool - INFO - Unloading model: Alpha-Model-4bit (immediate abort)\n")
    fh.write("2026-09-02 12:20:00,100 - omlx.engine_pool - INFO - Loading model: Alpha-Model-4bit\n")
    fh.write("2026-09-02 12:30:00,100 - omlx.server - ERROR - request failed: out of memory token=sk-LOGSECRET123456789\n")

# ---- MTPLX ----
mt = os.path.join(home, ".mtplx")
os.makedirs(os.path.join(mt, "logs"))
os.makedirs(os.path.join(mt, "metrics"))
json.dump({"model": "/Users/someone/.mtplx/models/Org--Beta-Model-MTPLX", "profile": "auto", "api_key": "sk-MTPLXSECRET0123456789",
           "model_selection": {"hf_model": "Org/Beta-Model-MTPLX", "variant": "speed"}}, open(os.path.join(mt, "quickstart.json"), "w"))
json.dump({"records": {"k1": {"key_material": {"model": "/x/Org--Beta-Model-MTPLX"}, "saved_at": "2026-08-19T07:54:24+0200",
                              "payload": {"best": {"mode": "D2", "depth": 2, "tok_s": 23.0, "multiplier_vs_ar": 2.6},
                                          "best_multiplier": {"ar_tok_s": 8.9, "verdict": "mtp_depth_wins"},
                                          "settings": {"depths": "1,2,3"}}}}},
          open(os.path.join(mt, "tuning.json"), "w"))
t0 = epoch("2026-09-02T12:00:00")
with open(os.path.join(mt, "metrics", "flight-8001.jsonl"), "w") as fh:
    for rid, reason in (("r1", "stop"), ("r2", "length")):
        fh.write(json.dumps({"ev": "begin", "ts": t0, "rid": rid, "model": "mtplx-beta-model", "prompt_tokens": 900}) + "\n")
        fh.write(json.dumps({"ev": "end", "ts": t0 + 5, "rid": rid, "reason": reason, "cancelled": False, "elapsed_s": 5.0,
                             "prompt_tokens": 900, "cached_tokens": 450, "decode_tok_s": 21.0, "ttft_s": 1.2}) + "\n")
with open(os.path.join(mt, "logs", "request-log-8001.jsonl"), "w") as fh:
    for i in range(3):
        fh.write(json.dumps({"logged_at_s": t0 + i, "prompt_tokens": 1000, "cached_tokens": 600, "decode_tok_s": 20.0 + i,
                             "prefill_tok_s": 300.0, "ttft_s": 2.0, "request_elapsed_s": 6.0, "cache_miss_reason": "new_session",
                             "accepted_by_depth": [3, 1], "drafted_by_depth": [4, 4], "repetition_stop_triggered": False}) + "\n")

# ---- omp harness config (secret must be redacted) ----
os.makedirs(os.path.join(home, ".omp", "agent"))
with open(os.path.join(home, ".omp", "agent", "config.yml"), "w") as fh:
    fh.write("default_model: alpha\napi_key: sk-OMPCONFIGSECRET0123456789\n")
PY

  cat >"$STUB" <<'STUBEOF'
#!/usr/bin/env bash
prompt="$(</dev/stdin)"
: >"$MARKER"
if [[ "$prompt" == *"TASK: TUNE-REDUCE"* ]]; then kind=reduce; else kind=model; fi
echo "$kind" >>"$CALLS"
mapfile -t lines <"$CALLS"
printf '%s\n' "$prompt" >"$PROMPT_DIR/$kind.${#lines[@]}.txt"
if [[ "$STUB_MODE" == bad ]]; then echo 'no json here'; exit 0; fi
if [[ $kind == reduce ]]; then
  echo '{"overview":{"paragraphs":["OVERVIEW-PARA"],"bullets":["OVERVIEW-BULLET"]},"ranking":[{"model":"alpha-model-4bit","decision":"needs tuning","why":"RANK-WHY"}]}'
else
  cat <<'JSON'
{"verdict":{"decision":"needs tuning","summary":"SUMMARY <script>alert(7)</script>","reasons":["REASON-ONE 25% errors"]},
 "hotspots":[{"title":"HOTSPOT-TITLE","quantified":"HOTSPOT-NUMBERS","evidence":"boom: bad args"}],
 "suggestions":[{"target":"omlx model settings","title":"Cap tokens <b>x</b>","why":"currently set to 2048","evidence":"length stops","snippet":"max_tokens: 1024","lang":"yaml","confidence":"medium"},
                {"target":"AGENTS.md","title":"Validate args","why":"w","evidence":"e","snippet":"- Check tool args","lang":"markdown","confidence":"high"}],
 "rules":["- RULE-BULLET one"],
 "retest":[{"measure":"tool error rate","how":"rerun tune","expect":"RETEST-DOWN"}]}
JSON
fi
STUBEOF
  chmod +x "$STUB"
}

# Runs tune with the temp HOME; sets OUT, ERR, STATUS. Fresh call log per run.
run_tune() {
  rm -rf "$CALLS" "$MARKER" "$TEST_TMP/prompts"
  mkdir -p "$TEST_TMP/prompts"
  PROMPT_DIR="$TEST_TMP/prompts" STUB_MODE="${STUB_MODE:-ok}" STATUS=0
  export PROMPT_DIR STUB_MODE MARKER CALLS
  HOME="$HOME_DIR" "$SCRIPT_UNDER_TEST" omp tune --root "$ROOT" --llm "$STUB" "$@" >"$TEST_TMP/out" 2>"$TEST_TMP/err" || STATUS=$?
  OUT="$(<"$TEST_TMP/out")"
  ERR="$(<"$TEST_TMP/err")"
}

call_count() {
  local n=0 line
  [[ -e "$CALLS" ]] || { echo 0; return; }
  while read -r line; do [[ "$line" == "$1" ]] && n=$((n + 1)); done <"$CALLS"
  echo "$n"
}

block_of() { # block_of <output> <model>: that model's block of the --no-llm table
  awk -v m="== $2" 'index($0, m) == 1 {on = 1; print; next} /^== / {on = 0} on' <<<"$1"
}

assert_no_secrets() { # assert_no_secrets <text> <label>
  local leak
  for leak in OMLXSECRET deadbeefdeadbeef BRAVESECRET MODELSECRET MTPLXSECRET LOGSECRET OMPCONFIGSECRET; do
    assert_not_contains "$1" "$leak" "$2: no secret $leak"
  done
}

test_no_llm_tables_grouping_and_server_evidence() {
  run_tune --no-llm --no-config
  assert_status "0" "$STATUS" "--no-llm exits 0"
  assert_eq "no" "$([[ -e $MARKER ]] && echo yes || echo no)" "--no-llm never calls the LLM"
  assert_not_contains "$OUT" "== gamma-model" "model below 3 sessions is not tuned by default"
  assert_eq "== alpha-model-4bit" "$(grep -m1 '^== ' <<<"$OUT" | cut -c1-19)" "most-used model comes first"

  local alpha beta
  alpha="$(block_of "$OUT" alpha-model-4bit)"
  beta="$(block_of "$OUT" mtplx-beta-model)"
  assert_contains "$alpha" "litellm/omlx/alpha-model-4bit" "routing-prefix variant grouped (litellm/omlx)"
  assert_contains "$alpha" "lm-studio/Alpha-Model-4bit" "routing-prefix variant grouped (lm-studio)"
  assert_contains "$alpha" "omlx/Alpha-Model-4bit" "routing-prefix variant grouped (omlx)"
  assert_contains "$alpha" "sessions                       4 (1 shared with other models" "alpha: 4 sessions, 1 shared"
  assert_contains "$alpha" "assistant turns per user turn  4.0" "alpha: assistant turns per user turn"
  assert_contains "$alpha" "tool calls per user turn       4.0" "alpha: tool calls per user turn"
  assert_contains "$alpha" "25.0% (4 of 16 calls)" "alpha: tool error rate"
  assert_contains "$alpha" "length 6.2%" "alpha: length stop share 1 of 16"
  assert_contains "$alpha" "compactions per session        0.25" "alpha: compactions per session"
  assert_contains "$alpha" "400 / 200" "alpha: tokens in/out per user turn"
  assert_contains "$alpha" "75.0% (" "alpha: cache-read ratio"
  assert_contains "$alpha" "sessions open over 12h         1" "alpha: one session open over 12h"
  assert_contains "$alpha" "2x (sessions): boom: bad args" "alpha: repeated error counted"
  assert_contains "$alpha" "runaway sessions" "alpha: runaway section"
  assert_contains "$beta" "sessions                       3 (1 shared with other models" "beta: 3 sessions incl. shared one"
  assert_contains "$beta" "16.7% (2 of 12 calls)" "beta: tool error rate"
  assert_contains "$beta" "1x (sessions): boom: bad args" "beta: repeated error counted once"

  # server evidence matched by model and by routing prefix
  assert_contains "$alpha" "servers considered: omlx, lmstudio" "alpha routing: omlx + lm-studio, no mtplx"
  assert_contains "$alpha" "requests=10 over 1 active hours" "omlx usage db: only in-window rows for alpha"
  assert_not_contains "$alpha" "requests=999" "omlx usage db: out-of-window row excluded"
  assert_contains "$alpha" "decode ~10.0 tok/s" "omlx usage db: decode tok/s aggregated"
  assert_contains "$alpha" "requests=77" "omlx stats.json lifetime totals for alpha"
  assert_contains "$alpha" '"max_tokens": 2048' "omlx per-model settings shown (max_tokens not treated as a secret)"
  assert_contains "$alpha" '"thinking_budget_tokens": 800' "omlx per-model thinking budget shown"
  assert_not_contains "$alpha" "qwen35_ane_prefill" "omlx noise keys filtered"
  assert_contains "$alpha" '"max_context_window": 32768' "omlx global settings shown"
  assert_contains "$alpha" "3 chat completions" "omlx log: only the bounded tail was parsed"
  assert_contains "$alpha" "length share 33%" "omlx log: finish_reason mix"
  assert_contains "$alpha" "scanned 2,000,000 of" "omlx log: tail bound reported (not read whole)"
  assert_contains "$alpha" "'unload': 1" "omlx log: unload event counted"
  assert_contains "$alpha" "'load': 1" "omlx log: load event counted"
  assert_contains "$alpha" "server-wide (not attributable to one model) in window: {'error': 1}" "omlx log: unattributed error kept server-wide"
  assert_contains "$alpha" "modified 20" "evidence carries source mtime"
  assert_not_contains "$alpha" "Beta-Model" "alpha evidence has no beta lines"
  assert_contains "$beta" "servers considered: mtplx" "beta routing: mtplx only"
  assert_not_contains "$beta" "usage db" "beta ran on mtplx: omlx evidence not applied"
  assert_contains "$beta" "best mode D2 (depth 2): 23.0 tok/s = 2.60x" "mtplx tuning.json record matched by model"
  assert_contains "$beta" "2 finished requests" "mtplx flight metrics aggregated"
  assert_contains "$beta" "end reasons {'stop': 1, 'length': 1}" "mtplx flight end reasons"
  assert_contains "$beta" "3 requests" "mtplx request log attributed via quickstart model"
  assert_contains "$beta" "MTP draft acceptance 50%" "mtplx draft acceptance"
  assert_no_secrets "$OUT" "table"
  assert_contains "$ERR" "server evidence" "timing line on stderr"

  run_tune --no-llm --no-config --no-server
  assert_status "0" "$STATUS" "--no-server exits 0"
  assert_not_contains "$OUT" "server evidence" "--no-server skips server evidence"
  assert_contains "$OUT" "25.0% (4 of 16 calls)" "--no-server keeps local metrics"
  assert_contains "$ERR" "0 records" "--no-server reads no files"

  run_tune --no-llm --no-config --model gamma
  assert_contains "$OUT" "== gamma-model" "--model includes models below the 3-session default"
  assert_not_contains "$OUT" "== alpha-model-4bit" "--model filters other models out"
  run_tune --no-llm --no-config --model ALPHA
  assert_contains "$OUT" "== alpha-model-4bit" "--model matches case-insensitively"
  assert_not_contains "$OUT" "== mtplx-beta-model" "--model excludes beta"
  run_tune --no-llm --no-config --model nothing-matches
  assert_status "1" "$STATUS" "--model without a match fails"
  assert_contains "$ERR" "no model matching" "no-match message"
}

test_dry_run_prompts_and_redaction() {
  run_tune --dry-run
  assert_status "0" "$STATUS" "--dry-run exits 0"
  assert_eq "no" "$([[ -e $MARKER ]] && echo yes || echo no)" "--dry-run never calls the LLM"
  assert_eq "2" "$(grep -c '^TASK: TUNE$' <<<"$OUT")" "one prompt per model"
  assert_contains "$OUT" "TASK: TUNE-REDUCE" "reduce prompt shown for several models"
  assert_contains "$OUT" "SERVER-SIDE EVIDENCE" "prompt has the server evidence block"
  assert_contains "$OUT" "currently set to X in <file> (modified <date>)" "prompt asks for 'currently set to' phrasing"
  assert_contains "$OUT" "never invent keys" "prompt forbids invented keys"
  assert_contains "$OUT" "'omlx model settings'" "prompt lists suggestion targets"
  assert_contains "$OUT" "HIGHEST-WASTE SESSION DIGESTS" "prompt has session digests"
  assert_contains "$OUT" "config.yml" "default omp config file included"
  assert_contains "$OUT" 'api_key: "[redacted]"' "config key redacted"
  assert_no_secrets "$OUT" "dry-run prompts"
  assert_contains "$ERR" "dry run" "stderr says dry run"
  assert_contains "$ERR" "usage.sqlite3" "stderr lists server evidence files"
}

test_llm_run_privacy_line_and_reports() {
  run_tune --out - --format md
  assert_status "0" "$STATUS" "md run exits 0"
  assert_eq "2" "$(call_count model)" "one LLM call per model"
  assert_eq "1" "$(call_count reduce)" "one reduce call for several models"
  assert_contains "$ERR" "tune: sending 2 models (alpha-model-4bit, mtplx-beta-model)" "privacy line: models"
  assert_contains "$ERR" "7 sessions" "privacy line: session count"
  assert_contains "$ERR" "digest bytes" "privacy line: digest bytes"
  assert_contains "$ERR" "server evidence files: " "privacy line: server files"
  assert_contains "$ERR" ".omlx/usage.sqlite3 (" "privacy line: usage db with bytes"
  assert_contains "$ERR" "2000000 of" "privacy line: tail-scanned bytes"
  assert_contains "$ERR" ".mtplx/tuning.json (" "privacy line: mtplx file"
  assert_contains "$ERR" "config.yml (" "privacy line: config file"
  assert_contains "$ERR" "to LLM command: $STUB" "privacy line: target command"
  local prompts
  prompts="$(cat "$TEST_TMP"/prompts/model.*.txt "$TEST_TMP"/prompts/reduce.*.txt)"
  assert_no_secrets "$prompts" "stub prompts"
  assert_contains "$prompts" "requests=10 over 1 active hours" "stub received omlx evidence"
  assert_contains "$prompts" "best mode D2" "stub received mtplx evidence"
  assert_not_contains "$(cat "$TEST_TMP"/prompts/model.1.txt)" "best mode D2" "alpha prompt carries no mtplx evidence"
  local t
  for t in "## Across models" "OVERVIEW-PARA" "RANK-WHY" "## Measured - alpha-model-4bit" "## Verdict - alpha-model-4bit" \
    "## Waste hotspots - mtplx-beta-model" "## Settings to change - mtplx-beta-model" "## Rules/prompts for this model - alpha-model-4bit" \
    "## Re-test checklist - mtplx-beta-model" "NEEDS TUNING: SUMMARY" "HOTSPOT-NUMBERS" "RETEST-DOWN" "RULE-BULLET one" \
    "### omlx model settings" "max_tokens: 1024" "Rules for alpha-model-4bit" "25.0% (4 of 16 calls)"; do
    assert_contains "$OUT" "$t" "md has: $t"
  done

  run_tune
  local file page today
  today="$(date +%F)"
  file="$HOME_DIR/.cache/agent_insights/omp-tune-$today.html"
  assert_status "0" "$STATUS" "html run exits 0"
  assert_contains "$ERR" "wrote $file" "default output path"
  page="$(<"$file")"
  for t in "<!doctype html>" "omp tune: alpha-model-4bit, mtplx-beta-model" "Across models" "Verdict - alpha-model-4bit" "Waste hotspots" \
    "Settings to change" "Rules/prompts for this model" "Re-test checklist" "Measured - mtplx-beta-model" "HOTSPOT-NUMBERS" "copy-btn"; do
    assert_contains "$page" "$t" "html has: $t"
  done
  assert_contains "$page" "SUMMARY &lt;script&gt;alert(7)&lt;/script&gt;" "injected summary text is escaped"
  assert_contains "$page" "Cap tokens &lt;b&gt;x&lt;/b&gt;" "injected suggestion title is escaped"
  assert_not_contains "$page" "<script>alert(7)" "no raw injected script"
  assert_eq "1" "$(grep -o '<script' <<<"$page" | wc -l | tr -d ' ')" "only the report's own script tag"

  run_tune --model alpha --out - --format md
  assert_eq "1" "$(call_count model)" "single model: one call"
  assert_eq "0" "$(call_count reduce)" "single model: no reduce call"
  assert_contains "$OUT" "## Verdict" "single model: plain section title"
  assert_not_contains "$OUT" "## Verdict - " "single model: no model suffix"
  assert_not_contains "$OUT" "Across models" "single model: no overview"

  STUB_MODE=bad run_tune --model alpha --out - --format md
  assert_status "1" "$STATUS" "unparseable LLM output fails"
  assert_contains "$OUT" "Raw LLM output (unparsed)" "raw output emitted on failure"
  assert_contains "$ERR" "tune failed" "failure reported"
}

test_analyze_points_to_tune() {
  local out
  out="$(HOME="$HOME_DIR" "$SCRIPT_UNDER_TEST" omp analyze --root "$ROOT" --dry-run --no-config 2>/dev/null)"
  assert_contains "$out" "agent_insights omp tune --model <that model>" "analyze reduce prompt points to tune"
  assert_contains "$out" "per_model" "analyze stats carry per-model rates"
}

build_fixture
run_tests "$@"
