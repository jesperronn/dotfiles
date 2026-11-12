#!/usr/bin/env bash
# shellcheck disable=SC1090,SC1091,SC2088
set -euo pipefail

DOTFILES_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"

source "$DOTFILES_ROOT/bin/lib/bash_test.sh"

TEST_TMP="$(mktemp -d)"
cleanup_test_tmp() {
  rm -rf "$TEST_TMP"
}
trap 'cleanup_test_tmp' EXIT

LIB="$DOTFILES_ROOT/bin/lib"

# Prints "<harness> <scenario> -> <state> <bytes> <winner path> shared=<exists>" per scenario (temp HOMEs only).
STATES_PY="$TEST_TMP/states.py"
cat >"$STATES_PY" <<'PY'
import os, sys, tempfile
sys.path.insert(0, sys.argv[1])
from agent_insights.wiring import wiring_status, USER_FILES

PRIMARY = {"omp": ".omp/agent/AGENTS.md", "pi": ".pi/agent/AGENTS.md", "codex": ".codex/AGENTS.md",
           "copilot": ".copilot/copilot-instructions.md"}


def home(shared=True):
    h = tempfile.mkdtemp(dir=sys.argv[2])
    os.makedirs(os.path.join(h, ".agents"))
    if shared:
        open(os.path.join(h, ".agents", "AGENTS.md"), "w").write("shared rules\n")
    return h


def put(h, rel, kind):
    path = os.path.join(h, rel)
    os.makedirs(os.path.dirname(path), exist_ok=True)
    if kind == "empty":
        open(path, "w").close()
    elif kind == "separate-copy":
        open(path, "w").write("own rules, 15 b\n")
    elif kind == "linked":
        os.symlink(os.path.join(h, ".agents", "AGENTS.md"), path)
    elif kind == "other-link":  # symlink to a different, non-empty file
        other = os.path.join(h, "elsewhere.md")
        open(other, "w").write("elsewhere\n")
        os.symlink(other, path)


def show(label, h, harness):
    s = wiring_status(harness, h)
    files = ",".join(f"{f['path']}={f['state']}" for f in s["files"])
    fixes = " | ".join(" ; ".join(x["commands"]) for x in s["fixes"])
    print(f"{harness} {label} -> {s['state']} bytes={s['files'][0]['bytes']} winner={s['files'][0]['path']} "
          f"shared={s['shared']['exists']} files={files} fix=[{fixes}]")


for harness, rel in PRIMARY.items():
    for scenario in ("missing", "empty", "separate-copy", "linked", "other-link"):
        h = home()
        if scenario != "missing":
            put(h, rel, scenario)
        show(scenario, h, harness)

# pi applies its candidate order: first existing wins.
h = home(); put(h, ".pi/agent/CLAUDE.md", "separate-copy"); show("only-CLAUDE", h, "pi")
h = home(); put(h, ".pi/agent/CLAUDE.md", "separate-copy"); put(h, ".pi/agent/AGENTS.md", "linked"); show("AGENTS-beats-CLAUDE", h, "pi")
h = home(); put(h, ".pi/agent/AGENTS.override.md", "empty"); put(h, ".pi/agent/AGENTS.md", "linked"); show("override-wins", h, "pi")
# copilot loads two files: either one linked counts.
h = home(); put(h, ".copilot/copilot-instructions.md", "empty"); put(h, ".copilot/AGENTS.md", "linked"); show("second-file-linked", h, "copilot")
# a symlink to a missing shared file is missing, and the fix tells the user to create the shared file first.
h = home(shared=False); put(h, ".omp/agent/AGENTS.md", "linked"); show("dangling-link", h, "omp")
PY

test_wiring_states_for_every_harness() {
  local out
  out="$(python3 -I "$STATES_PY" "$LIB" "$TEST_TMP")"
  local h
  for h in omp pi codex copilot; do
    assert_contains "$out" "$h missing -> missing bytes=0" "$h: missing file"
    assert_contains "$out" "$h empty -> empty bytes=0" "$h: 0-byte regular file is empty"
    assert_contains "$out" "$h separate-copy -> separate-copy bytes=16" "$h: own content is a separate copy"
    assert_contains "$out" "$h linked -> linked-to-shared bytes=13" "$h: symlink to the shared file"
    assert_contains "$out" "$h other-link -> separate-copy" "$h: symlink to some other file is a separate copy"
  done
  assert_contains "$out" "omp missing -> missing bytes=0 winner=~/.omp/agent/AGENTS.md shared=True files=~/.omp/agent/AGENTS.md=missing fix=[mkdir -p ~/.omp/agent && ln -s ~/.agents/AGENTS.md ~/.omp/agent/AGENTS.md]" "omp missing: mkdir -p + ln -s fix"
  assert_contains "$out" "codex empty -> empty bytes=0 winner=~/.codex/AGENTS.md shared=True files=~/.codex/AGENTS.md=empty fix=[# ~/.codex/AGENTS.md is a 0-byte regular file: it must be removed or replaced first ; mv ~/.codex/AGENTS.md ~/.codex/AGENTS.md.empty.bak && ln -s ~/.agents/AGENTS.md ~/.codex/AGENTS.md]" "codex empty: exact mv + ln -s fix"
  assert_contains "$out" "pi separate-copy -> separate-copy" "pi separate copy detected"
  assert_contains "$out" "mv ~/.pi/agent/AGENTS.md ~/.pi/agent/AGENTS.md.bak && ln -s ~/.agents/AGENTS.md ~/.pi/agent/AGENTS.md]" "pi separate-copy: backup + ln -s fix"
  assert_contains "$out" "copilot linked -> linked-to-shared bytes=13 winner=~/.copilot/copilot-instructions.md shared=True files=~/.copilot/copilot-instructions.md=linked-to-shared,~/.copilot/AGENTS.md=missing fix=[]" "linked: no fix command"
  assert_contains "$out" "pi only-CLAUDE -> separate-copy bytes=16 winner=~/.pi/agent/CLAUDE.md" "pi: a CLAUDE.md alone is the winning candidate"
  assert_contains "$out" "pi AGENTS-beats-CLAUDE -> linked-to-shared bytes=13 winner=~/.pi/agent/AGENTS.md" "pi: AGENTS.md is earlier than CLAUDE.md"
  assert_contains "$out" "pi override-wins -> empty bytes=0 winner=~/.pi/agent/AGENTS.override.md" "pi: AGENTS.override.md shadows a linked AGENTS.md"
  assert_contains "$out" "copilot second-file-linked -> linked-to-shared" "copilot: either of its two files linked counts"
  assert_contains "$out" "omp dangling-link -> missing bytes=0 winner=~/.omp/agent/AGENTS.md shared=False" "dangling link to a missing shared file is missing"
  assert_contains "$out" "# ~/.agents/AGENTS.md does not exist yet: create it first" "fix says to create the shared file first"
}

# Drives analyze + tune prompts and rendering for every harness with a stub LLM and a temp HOME per harness:
# omp missing, pi separate-copy, codex empty, copilot linked. Writes prompts and reports under argv[2].
REPORTS_PY="$TEST_TMP/reports.py"
cat >"$REPORTS_PY" <<'PY'
import json, os, sys
sys.path.insert(0, sys.argv[1])
out = sys.argv[2]
stub = sys.argv[3]
from agent_insights import analyze, common, tune

SETUP = {"omp": ("missing", ".omp/agent/AGENTS.md"), "pi": ("separate-copy", ".pi/agent/AGENTS.md"),
         "codex": ("empty", ".codex/AGENTS.md"), "copilot": ("linked", ".copilot/copilot-instructions.md")}
TUNE_JSON = {"verdict": {"decision": "keep", "summary": "fine"}, "rules": ["- model rule"],
             "suggestions": [{"target": "AGENTS.md", "scope": "general", "title": "Verify before done",
                              "snippet": "- Run tests", "lang": "markdown", "confidence": "high"}]}


def sessions(harness):
    rows = []
    for i in range(3):
        s = common.new_session(harness, f"s{i}")
        s.update(project="/work/alpha", started=f"2026-09-0{i + 1}T10:00:00Z", ended=f"2026-09-0{i + 1}T11:00:00Z",
                 models=["model-x"], user_turns=2, assistant_turns=3, first_prompt="do a thing")
        s["tool_calls"] = {"bash": 2}
        rows.append(s)
    return rows


for harness, (kind, rel) in SETUP.items():
    home = os.path.join(out, "home-" + harness)
    os.makedirs(os.path.join(home, ".agents"))
    open(os.path.join(home, ".agents", "AGENTS.md"), "w").write("shared rules\n")
    path = os.path.join(home, rel)
    os.makedirs(os.path.dirname(path), exist_ok=True)
    if kind == "empty":
        open(path, "w").close()
    elif kind == "separate-copy":
        open(path, "w").write("own\n")
    elif kind == "linked":
        os.symlink(os.path.join(home, ".agents", "AGENTS.md"), path)
    os.environ["HOME"] = home
    os.environ["PROMPT_DIR"] = os.path.join(out, "prompts-" + harness)
    os.makedirs(os.environ["PROMPT_DIR"])
    ss = sessions(harness)
    report = analyze.analyze(harness, ss, stub, 40, 10, "")
    stats = common.summarize(ss)
    for fmt in ("html", "md"):
        text = analyze.render(fmt, harness, report, analyze.meta_line(ss), stats)
        open(os.path.join(out, f"{harness}.analyze.{fmt}"), "w").write(text)
    group = tune.select_groups(ss)[0]
    m = tune.compute_metrics(group)
    open(os.path.join(out, f"{harness}.tune.prompt.txt"), "w").write(
        tune.model_prompt(harness, m, tune.worst_digests(group), [], "", "2026-09-01 to 2026-09-03"))
    res = tune.model_result(TUNE_JSON, m)
    trep = tune.build_report([res], {m["model"]: m}, None, harness)
    for fmt in ("html", "md"):
        open(os.path.join(out, f"{harness}.tune.{fmt}"), "w").write(
            analyze.render(fmt, harness, trep, tune.tune_meta([m], len(ss)), None, f"{harness} tune", "tune-"))
    open(os.path.join(out, f"{harness}.dry.txt"), "w").write(analyze.dry_run_text(harness, ss, stub, 40, 10, ""))
PY

STUB="$TEST_TMP/stub_llm"
cat >"$STUB" <<'STUBEOF'
#!/usr/bin/env bash
prompt="$(</dev/stdin)"
n=$(find "$PROMPT_DIR" -type f | wc -l | tr -d ' ')
printf '%s\n' "$prompt" >"$PROMPT_DIR/prompt.$n.txt"
if [[ "$prompt" == *"TASK: REDUCE"* ]]; then
  cat <<'JSON'
{"glance":{"working":"w"},"sections":[{"title":"What You Work On","paragraphs":["p"],"bullets":["- dashed bullet"]}],
 "suggestions":[
  {"target":"AGENTS.md","scope":"general","title":"GEN-TITLE","why":"w","evidence":"e","snippet":"- general rule","lang":"markdown","confidence":"high"},
  {"target":"AGENTS.md","scope":"harness","title":"HARNESS-TITLE","why":"w","evidence":"e","snippet":"- harness rule","lang":"markdown","confidence":"high"},
  {"target":"AGENTS.md","scope":"project","project":"/work/alpha","title":"PROJECT-TITLE","why":"w","evidence":"e","snippet":"- project rule","lang":"markdown","confidence":"high"}]}
JSON
else
  echo '{"themes":["t"],"projects":[],"wins":[],"friction":[],"notable_prompts":[]}'
fi
STUBEOF
chmod +x "$STUB"

test_no_claude_file_mentions_and_wiring_in_reports() {
  local out="$TEST_TMP/reports"
  mkdir -p "$out"
  python3 -I "$REPORTS_PY" "$LIB" "$out" "$STUB"
  local h f n=0 text
  for h in omp pi codex copilot; do
    for f in "$out/prompts-$h"/*.txt "$out/$h".*; do
      text="$(<"$f")"
      assert_not_contains "$text" "CLAUDE.md" "$h: no CLAUDE.md in ${f##*/}"
      assert_not_contains "$text" ".claude/" "$h: no .claude/ in ${f##*/}"
      n=$((n + 1))
    done
    assert_contains "$(<"$out/$h.dry.txt")" "WIRING (checked locally" "$h: analyze prompt has the WIRING block"
    assert_contains "$(<"$out/$h.tune.prompt.txt")" "WIRING (checked locally" "$h: tune prompt has the WIRING block"
    assert_contains "$(<"$out/$h.dry.txt")" "Existing Features to Try' about features of $h itself" "$h: features guidance is about this harness only"
    assert_contains "$(<"$out/$h.analyze.html")" 'id="wiring"' "$h: html has the Wiring card"
    assert_contains "$(<"$out/$h.analyze.md")" "## Wiring" "$h: md has the Wiring section"
    assert_contains "$(<"$out/$h.tune.html")" 'id="wiring"' "$h: tune html has the Wiring card"
  done
  assert_eq "yes" "$([[ $n -gt 0 ]] && echo yes || echo no)" "files were scanned"

  local omp pi codex copilot
  omp="$(<"$out/omp.analyze.md")"; pi="$(<"$out/pi.analyze.md")"
  codex="$(<"$out/codex.analyze.md")"; copilot="$(<"$out/copilot.analyze.md")"
  # Wiring card: state per harness, fix commands, and the verified note.
  assert_contains "$omp" "~/.omp/agent/AGENTS.md: **missing**" "omp wiring state"
  assert_contains "$omp" "mkdir -p ~/.omp/agent && ln -s ~/.agents/AGENTS.md ~/.omp/agent/AGENTS.md" "omp fix command shown"
  assert_contains "$omp" "source-verified: omp" "omp note: source-verified"
  assert_contains "$pi" "~/.pi/agent/AGENTS.md: **separate-copy**" "pi wiring state"
  assert_contains "$pi" "mv ~/.pi/agent/AGENTS.md ~/.pi/agent/AGENTS.md.bak && ln -s ~/.agents/AGENTS.md ~/.pi/agent/AGENTS.md" "pi fix command shown"
  assert_contains "$pi" "source-verified in pi's resource-loader" "pi note: source-verified"
  assert_contains "$codex" "~/.codex/AGENTS.md: **empty**" "codex wiring state"
  assert_contains "$codex" "0-byte regular file" "codex empty-file explanation"
  assert_contains "$codex" "mv ~/.codex/AGENTS.md ~/.codex/AGENTS.md.empty.bak && ln -s ~/.agents/AGENTS.md ~/.codex/AGENTS.md" "codex exact mv + ln -s"
  assert_contains "$codex" "documented behaviour, not source-verified here" "codex note: not source-verified"
  assert_contains "$copilot" "~/.copilot/copilot-instructions.md: **linked-to-shared**" "copilot linked state"
  assert_contains "$copilot" "documented behaviour, not source-verified here" "copilot note: not source-verified"
  assert_not_contains "$copilot" "Fix for" "linked harness gets no fix command"
  assert_contains "$(<"$out/omp.analyze.html")" 'data-copy="wiring-fix-1"' "html fix command has a copy button"
  assert_not_contains "$(<"$out/copilot.analyze.html")" "wiring-fix-1" "html: no copy button when linked"

  # Warning on general suggestions only for unwired harnesses.
  local h
  for h in omp pi codex; do
    assert_contains "$(<"$out/$h.analyze.md")" "this harness does not currently load ~/.agents/AGENTS.md (state: " "$h: general suggestion warns"
    assert_contains "$(<"$out/$h.analyze.html")" "does not currently load ~/.agents/AGENTS.md (state: " "$h: html warns"
    assert_contains "$(<"$out/$h.analyze.md")" "see Wiring" "$h: warning points at Wiring"
  done
  assert_contains "$omp" "(state: missing)" "omp warning names its state"
  assert_contains "$pi" "(state: separate-copy)" "pi warning names its state"
  assert_contains "$codex" "(state: empty)" "codex warning names its state"
  assert_not_contains "$copilot" "does not currently load" "copilot linked: no warning"
  assert_eq "1" "$(grep -c 'Warning:' <<<"$omp")" "warning only on the single general suggestion"

  # Scope routing and dash handling in a rendered report.
  assert_contains "$omp" "### General rules (~/.agents/AGENTS.md (shared, all harnesses))" "general heading"
  assert_contains "$omp" "### omp-specific rules (~/.omp/agent/AGENTS.md)" "harness heading"
  assert_contains "$copilot" "### copilot-specific rules (~/.copilot/copilot-instructions.md)" "copilot harness file"
  assert_contains "$codex" "### codex-specific rules (~/.codex/AGENTS.md)" "codex harness file"
  assert_contains "$pi" "### pi-specific rules (~/.pi/agent/AGENTS.md)" "pi harness file"
  assert_contains "$omp" "### Project rules (alpha) (the project's AGENTS.md (alpha))" "project heading"
  assert_contains "$omp" "- dashed bullet" "section bullet rendered"
  assert_not_contains "$omp" "- - dashed" "section bullet not doubled"
  # The prompts tell the model general rules already arrive when linked, and not otherwise.
  assert_contains "$(<"$out/copilot.dry.txt")" "Never recommend adding general rules to this harness's own file" "linked: no duplicate general rules"
  assert_contains "$(<"$out/omp.dry.txt")" "does NOT load the shared file (state: missing)" "unwired: prompt says so"
}

run_tests "$@"
