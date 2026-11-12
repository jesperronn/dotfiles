"""LLM-driven qualitative analysis (the /insights narrative layer) for agent_insights.

Pipeline: normalized sessions -> compact one-line digests (never transcripts) -> map calls
(one JSON summary per batch) -> one reduce call -> glance + six sections + suggestions + horizon -> HTML or Markdown.
The LLM is any shell command that reads the prompt on stdin and writes the answer on stdout;
the default is `claude -p`.
"""
from __future__ import annotations

import hashlib
import html
import json
import os
import re
import sys
import subprocess
from collections import Counter
from datetime import datetime, timezone

from . import common, wiring

DEFAULT_LLM = "claude -p"
DEFAULT_BATCH_SIZE = 40
PROMPT_CHARS = 400
LLM_TIMEOUT_SECONDS = 900

MAP_MARKER = "TASK: MAP"
REDUCE_MARKER = "TASK: REDUCE"

RULES = (
    "Rules: be specific; cite project names and concrete numbers from the data; no flattery or "
    "filler; say plainly when the data is too thin to support a claim; do not invent facts that "
    "are not in the data. Answer with a single JSON object and nothing else."
)


class AnalyzeError(Exception):
    """LLM call failed or its output could not be parsed; `raw` carries the last raw answer."""

    def __init__(self, message, raw=""):
        super().__init__(message)
        self.raw = raw


def _clean(text, limit):
    text = re.sub(r"\s+", " ", text or "").strip()
    return text if len(text) <= limit else text[: limit - 1] + "…"


def session_digest(s) -> str:
    """One compact line of normalized fields. Always emitted, even without a prompt or title."""
    parts = [
        (s["started"] or "?")[:10],
        f"project={s['project'] or '(unknown)'}",
    ]
    if s["title"]:
        parts.append(f"title={_clean(s['title'], 100)!r}")
    parts.append(f"user_turns={s['user_turns']}")
    tools = sorted(s["tool_calls"].items(), key=lambda kv: -kv[1])[:5]
    parts.append("tools=" + (",".join(f"{k}:{v}" for k, v in tools) or "none"))
    parts.append(f"tool_errors={s['tool_errors']}")
    if s.get("errors"):
        parts.append(f"errors={[_clean(e, common.ERROR_CHARS) for e in s['errors']]!r}")
    if s["models"]:
        parts.append("models=" + ",".join(s["models"][:3]))
    duration = common.duration_seconds(s)
    if duration is not None:
        parts.append(f"duration={common.fmt_duration(min(duration, common.MAX_SESSION_SECONDS))}")
    stops = s["extra"].get("stop_reasons")
    if isinstance(stops, dict) and stops:
        top = sorted(stops.items(), key=lambda kv: -kv[1])[:4]
        parts.append("stop_reasons=" + ",".join(f"{k}:{v}" for k, v in top))
    if s["extra"].get("thinking_level_last"):
        parts.append(f"thinking_last={_clean(str(s['extra']['thinking_level_last']), 20)}")
    if s["extra"].get("compactions"):
        parts.append(f"compactions={s['extra']['compactions']:g}")
    extras = [f"{k}={v:g}" for k, v in sorted(s["extra"].items())
              if k != "compactions" and isinstance(v, (int, float)) and not isinstance(v, bool) and v][:6]
    if extras:
        parts.append(" ".join(extras))
    t = s["tokens"]
    parts.append(f"tokens(in/out)={common.fmt_tokens(t.get('input', 0))}/{common.fmt_tokens(t.get('output', 0))}")
    if s["first_prompt"]:
        parts.append(f"first_prompt={_clean(s['first_prompt'], PROMPT_CHARS)!r}")
    return "- " + " | ".join(parts)


def build_digests(sessions):
    ordered = sorted(sessions, key=lambda x: x["started"] or "")
    return [session_digest(s) for s in ordered]


def batches(digests, size):
    size = max(1, size)
    return [digests[i:i + size] for i in range(0, len(digests), size)]


# ---- suggestion targets -------------------------------------------------------------------------

# Instruction-file suggestions are routed by scope; the LLM answers target 'AGENTS.md' plus a scope.
SCOPES = ("general", "harness", "project")
INSTRUCTION_TARGETS = {"general": "AGENTS.md (general)", "harness": "AGENTS.md (harness)",
                       "project": "AGENTS.md (project)"}
SHARED_FILE_WHERE = f"{wiring.SHARED} (shared, all harnesses)"

# Fixed enum the LLM must choose from -> (display name, where the snippet goes). The three AGENTS.md rows are
# resolved per harness/project by target_info(); their `where` here is only the generic text.
TARGETS = {
    "AGENTS.md (general)": ("General rules", SHARED_FILE_WHERE),
    "AGENTS.md (harness)": ("Harness-specific rules", "the harness's own user-level instruction file"),
    "AGENTS.md (project)": ("Project rules", "the project's AGENTS.md"),
    "omp config (~/.omp/agent/config.yml)": ("omp config", "~/.omp/agent/config.yml"),
    "omp models (~/.omp/agent/models.yml)": ("omp models", "~/.omp/agent/models.yml"),
    "pi settings (~/.pi/agent/settings.json)": ("pi settings", "~/.pi/agent/settings.json"),
    "omlx model settings": ("omlx model settings", "omlx admin UI or its per-model settings file"),
    "MTPLX config": ("MTPLX config", "the MTPLX server configuration"),
    "lm-studio model settings": ("LM Studio model settings", "LM Studio, per-model load/inference settings"),
    "litellm config": ("LiteLLM config", "the litellm proxy config.yaml"),
    "shell/prompt": ("Prompts to paste", "paste into the agent's prompt box or a shell"),
    "other": ("Other", "see the suggestion"),
}
LLM_TARGETS = ["AGENTS.md"] + [t for t in TARGETS if not t.startswith("AGENTS.md")]


def project_dir_name(project) -> str:
    return os.path.basename(str(project or "").strip().rstrip("/")) or "unspecified project"


def target_info(target, harness, project=""):
    """(display name, where) of a normalized target for this harness/project."""
    name, where = TARGETS[target]
    if target == INSTRUCTION_TARGETS["harness"]:
        where = wiring.HARNESS_INSTRUCTION_FILE.get(harness, where)
        name = f"{harness}-specific rules"
    elif target == INSTRUCTION_TARGETS["project"]:
        where = f"the project's AGENTS.md ({project_dir_name(project)})"
        name = f"Project rules ({project_dir_name(project)})"
    return name, where


CONFIDENCE = ("high", "medium", "low")
GLANCE_LABELS = (("working", "What's working"), ("hindering", "What's hindering you"),
                 ("quick_wins", "Quick wins to try"), ("ambitious", "Ambitious workflows"))

SUGGESTION_RULES = (
    "Suggestions: each is one concrete, copy-paste-ready change. 'target' must be exactly one of: "
    + "; ".join(f"'{t}'" for t in LLM_TARGETS) + ". Every suggestion also declares 'scope': 'general' "
    "(applies to any agent: git/commit rules, verification, safety, memory-bank, workflow), 'harness' (about "
    "one harness's tools, quirks, or one model's weaknesses in it, for example a todo tool or an edit tool) or "
    "'project' (one repository; then set 'project' to its directory name). Pick the narrowest correct scope; "
    "when unsure choose 'harness'; a rule that names a harness tool or model is never 'general'. With target "
    "'AGENTS.md' the scope picks the file: general goes to the shared ~/.agents/AGENTS.md read by all harnesses, "
    "harness to the analysed harness's own user-level instruction file, project to that project's AGENTS.md. "
    "Only recommend settings that really exist for that "
    "tool; never invent flag or key names. If you do not know the exact key, describe the intent in "
    "prose in 'why' and leave 'snippet' empty. For serving/model settings (context length, max output "
    "tokens, temperature/top_p/repetition penalty, chat template or tool-call parser, thinking/effort "
    "level, KV cache, quantization choice) state in 'evidence' which observed data motivates it (for "
    "example stop_reasons with 'length', repeated invalid tool arguments in errors, compactions, "
    "aborted turns, sessions open for the 12h cap), cite actual error text and counts, set "
    "'confidence' to high, medium or low, and put 'verify against the tool's docs' in 'why' when you "
    "are unsure. 'lang' is the snippet language (yaml, json, markdown, bash, text). AGENTS.md "
    "snippets must be ready-to-append Markdown bullets. Text meant to be pasted into the agent as a "
    "prompt goes to target 'shell/prompt'. Match existing keys when config files are provided. "
    "Give 3 to 10 suggestions, highest value first; none if the data supports none."
)


def map_prompt(harness, batch, index, total) -> str:
    return (
        f"{MAP_MARKER} (batch {index} of {total})\n"
        f"You are analysing usage logs of the coding agent '{harness}'. Below are compact digests of "
        f"{len(batch)} sessions (date, project, stats, stop reasons, compactions, last thinking level, "
        "a few redacted error messages, truncated first prompt).\n"
        f"{RULES}\n"
        'JSON schema: {"themes":[str],"projects":[{"name":str,"what":str}],"wins":[str],'
        '"friction":[str],"notable_prompts":[str]}\n\n'
        "SESSIONS:\n" + "\n".join(batch) + "\n"
    )


def reduce_prompt(harness, batch_jsons, stats, config="", span="") -> str:
    titles = section_titles(harness)
    schema = (
        '{"glance":{"working":str,"hindering":str,"quick_wins":str,"ambitious":str},'
        '"sections":[{"title":str,"paragraphs":[str],"bullets":[str]}],'
        '"horizon":[{"title":str,"what":str,"prompt":str}],'
        '"suggestions":[{"target":str,"title":str,"why":str,"evidence":str,"snippet":str,'
        '"lang":str,"scope":"general|harness|project","project":str,"confidence":"high|medium|low"}]}'
    )
    return (
        f"{REDUCE_MARKER}\n"
        f"You are writing a usage-insights report on the coding agent '{harness}' for its user. Below are "
        "per-batch JSON summaries of their sessions plus aggregate statistics. Produce:\n"
        "- 'glance': four short labelled points (1-2 sentences each): what is working, what is hindering, "
        "quick wins, ambitious workflows.\n"
        "- 'sections': exactly these six, in this order, using these exact titles:\n"
        + "\n".join(f"  {i}. {t}" for i, t in enumerate(titles, 1)) + "\n"
        f"  Write 'Existing Features to Try' about features of {harness} itself (and only {harness}) that fit "
        "the observed habits, and 'New Ways to Use It' with concrete workflows suggested by the data.\n"
        "- 'horizon': 2-3 ambitious ideas ('On the Horizon'); each has a title, what it is, and a starter "
        "'prompt' the user can paste into the agent to begin.\n"
        "- 'suggestions': paste-ready changes grouped later by target.\n"
        f"{SUGGESTION_RULES}\n"
        f"{wiring.wiring_text(harness)}"
        "If one model in stats.per_model clearly stands out (error_rate or length_stop_share far above the "
        f"others, with at least 3 sessions), end 'Where Things Go Wrong' with one line: run: agent_insights "
        f"{harness} tune --model <that model>.\n"
        "Local models are often served through omlx, MTPLX, LM Studio or litellm; many fixes belong in "
        "that serving layer or the harness config rather than in an instruction file.\n"
        f"{RULES}\n"
        f"JSON schema: {schema}\n\n"
        "AGGREGATE STATS:\n" + json.dumps(stats, indent=1, default=str) + "\n\n"
        + (f"{SNAPSHOT_RULE}Config snapshot taken {datetime.now(timezone.utc):%Y-%m-%d} UTC; analyzed sessions "
           f"span {span or 'unknown dates'}.\n"
           f"CONFIG FILES (read-only context, secrets redacted; do not echo them back):\n{config}\n\n"
           if config else "")
        + "BATCH SUMMARIES:\n" + "\n".join(json.dumps(b, ensure_ascii=False) for b in batch_jsons) + "\n"
    )


def section_titles(harness):
    return ["What You Work On", f"How You Use {harness}", "Impressive Things You Did",
            "Where Things Go Wrong", "Existing Features to Try", "New Ways to Use It"]


def aggregate_stop_reasons(sessions) -> dict:
    total = Counter()
    for s in sessions:
        stops = s["extra"].get("stop_reasons")
        if isinstance(stops, dict):
            for k, v in stops.items():
                if isinstance(v, (int, float)):
                    total[str(k)] += v
    return dict(total.most_common())


def error_rate(stats) -> float:
    return stats["tool_errors"] / stats["tool_calls"] if stats["tool_calls"] else 0.0


def per_model_rates(sessions, top):
    """{model: {sessions, error_rate, length_stop_share}} for the most-used models (pointer to `tune`)."""
    groups = {}
    for x in sessions:
        for model in {common.normalize_model(m) for m in x["models"]}:
            groups.setdefault(model, []).append(x)
    out = {}
    for model, items in sorted(groups.items(), key=lambda kv: -len(kv[1]))[:top]:
        calls = sum(sum(x["tool_calls"].values()) for x in items)
        stops = aggregate_stop_reasons(items)
        out[model] = {"sessions": len(items),
                      "error_rate": round(sum(x["tool_errors"] for x in items) / calls, 4) if calls else 0.0,
                      "length_stop_share": round(stops.get("length", 0) / sum(stops.values()), 4) if stops else 0.0}
    return out


def compact_stats(sessions, top):
    s = common.summarize(sessions)
    for key in ("days", "hours", "weekdays"):
        s.pop(key, None)
    for key in ("tools", "models", "projects"):
        s[key] = dict(list(s[key].items())[:top])
    s["stop_reasons"] = aggregate_stop_reasons(sessions)
    s["tool_error_rate"] = round(error_rate(s), 4)
    s["per_model"] = per_model_rates(sessions, top)
    levels = Counter(str(x["extra"]["thinking_level_last"]) for x in sessions
                     if x["extra"].get("thinking_level_last"))
    if levels:
        s["thinking_level_last_counts"] = dict(levels.most_common())
    return s


# ---- config context -----------------------------------------------------------------------------

CONFIG_CHARS = 6000

# harness -> files read by default as read-only context (settings/models, then global instruction files).
# Missing or empty files are skipped silently. Disable with --no-config.
DEFAULT_CONFIGS = {
    "omp": ("~/.omp/agent/config.yml", "~/.omp/agent/models.yml", "~/.omp/agent/AGENTS.md"),
    "pi": ("~/.pi/agent/settings.json", "~/.pi/agent/models.json", "~/.pi/agent/AGENTS.md"),
    "codex": ("~/.codex/config.toml", "~/.codex/AGENTS.md"),
    "copilot": ("~/.copilot/config.json", "~/.copilot/AGENTS.md", "~/.copilot/copilot-instructions.md"),
}

# A key is a secret when its name ENDS in one of these words (so maxTokens, idleThresholdTokens and
# magicKeywords are not secrets). camelCase names like githubToken are caught by _SECRET_CAMEL.
_SECRET_KEY_RE = re.compile(
    r"(^|_|-)(api[_-]?key|token|secret|password|passwd|authorization|auth[_-]?token|access[_-]?token"
    r"|bearer|credential)s?$", re.I)
_SECRET_CAMEL_RE = re.compile(r"[a-z0-9](?:Token|Secret|Password|ApiKey|Credential)$")
_KV_INLINE = re.compile(r"""(["']?)([\w.-]+)(["']?\s*[:=]\s*)((?:(?:bearer|basic|token)\s+)?(?:"[^"]*"|'[^']*'|[^\s,}\]#"']+))""",
                        re.I)
_KV_LINE = re.compile(r"""^(\s*(?:-\s+)?)["']?([\w.-]+)["']?\s*[:=]\s*(?:#.*|[{\[])?$""")


_COUNT_TOKENS_RE = re.compile(r"(max|min|budget|limit|count|num|result|chunk|total|size|length|window|context|prefill"
                              r"|output|input|response|reserved)", re.I)


def is_secret_key(name) -> bool:
    # snake_case counters such as max_tokens / thinking_budget_tokens are numbers, not credentials
    if name.lower().endswith("tokens") and _COUNT_TOKENS_RE.search(name) \
            and not re.search(r"(api|auth|access|secret|bearer|refresh)", name, re.I):
        return False
    return bool(_SECRET_KEY_RE.search(name) or _SECRET_CAMEL_RE.search(name))


def _redact_inline(match) -> str:
    if not is_secret_key(match.group(2)):
        return match.group(0)
    return match.group(1) + match.group(2) + match.group(3) + '"[redacted]"'


def redact_config(text) -> str:
    """Redact secret-keyed values (and nested blocks under them), secret-looking strings and home paths."""
    out, skip_indent = [], None
    for line in text.splitlines():
        indent = len(line) - len(line.lstrip())
        if skip_indent is not None:
            if line.strip() and indent > skip_indent:
                out.append(line[:indent] + "[redacted]")
                continue
            skip_indent = None
        m = _KV_LINE.match(line)
        if m and is_secret_key(m.group(2)):  # `apiKeys:` with the value on following lines
            skip_indent = indent
            out.append(line)
            continue
        out.append(_KV_INLINE.sub(_redact_inline, line))
    return common.redact_secrets("\n".join(out))


def config_candidates(harness, explicit=(), use_defaults=True):
    """[(full_path, 'default'|'explicit')]: existing non-empty default files, then explicit ones, de-duplicated."""
    found, seen = [], set()
    if use_defaults:
        for path in DEFAULT_CONFIGS.get(harness, ()):
            full = os.path.expanduser(path)
            if os.path.isfile(full) and os.path.getsize(full) > 0 and os.path.realpath(full) not in seen:
                seen.add(os.path.realpath(full))
                found.append((full, "default"))
    for path in explicit:
        full = os.path.expanduser(path)
        if os.path.realpath(full) not in seen:
            seen.add(os.path.realpath(full))
            found.append((full, "explicit"))
    return found


def load_config_files(candidates):
    """Return (prompt_text, [(display_path, bytes_included, origin)]). Raises OSError on unreadable files.

    `candidates` is [(path, origin)] (see config_candidates); plain path strings count as explicit.
    """
    blocks, included = [], []
    home = os.path.expanduser("~")
    for item in candidates:
        path, origin = (item, "explicit") if isinstance(item, str) else item
        full = os.path.expanduser(path)
        with open(full, encoding="utf-8", errors="replace") as fh:
            text = redact_config(fh.read())
        if len(text) > CONFIG_CHARS:
            text = text[:CONFIG_CHARS] + "\n[truncated]"
        shown = common.redact_secrets(os.path.abspath(full))
        shown = "~" + shown[len(home):] if shown.startswith(home) else shown
        modified = datetime.fromtimestamp(os.path.getmtime(full), timezone.utc).strftime("%Y-%m-%d")
        blocks.append(f"--- {shown} (modified {modified} UTC) ---\n{text}")
        included.append((shown, len(text.encode()), origin))
    return "\n\n".join(blocks), included


def config_summary(included) -> str:
    if not included:
        return "no config files"
    return (f"config files: {', '.join(f'{p} ({n} bytes) ({o})' for p, n, o in included)}; "
            f"{sum(n for _, n, _ in included)} config bytes")


def session_span(sessions) -> str:
    """'YYYY-MM-DD to YYYY-MM-DD' (UTC start dates) of the analyzed sessions."""
    days = sorted(s["started"][:10] for s in sessions if s.get("started"))
    return f"{days[0]} to {days[-1]}" if days else "unknown dates"


SNAPSHOT_RULE = (
    "CONFIG SNAPSHOT RULE: the config files below are a snapshot read at analysis time (today), not what "
    "the sessions ran with. Each header shows the file's last-modified date. If a file was modified after "
    "a session, or may have changed since the sessions ran, treat it as possibly different from what that "
    "session used and hedge accordingly. Never claim a past session misbehaved BECAUSE of a setting unless "
    "the session data shows it. When a suggestion depends on a config key that is already present, say "
    "'currently set to X in <file> (modified <date>)'. Files named AGENTS.md or *instructions* are the "
    "user's existing global instructions: do not recommend rules that are already there.\n"
)


# ---- LLM plumbing -------------------------------------------------------------------------------

def parse_json(text):
    """Tolerant JSON extraction: strips code fences, then takes the first balanced {...}."""
    text = (text or "").strip()
    fenced = re.search(r"```(?:json)?\s*(.*?)```", text, re.S | re.I)
    candidates = [fenced.group(1)] if fenced else []
    candidates.append(text)
    decoder = json.JSONDecoder()
    for cand in candidates:
        for m in re.finditer(r"\{", cand):
            try:
                obj, _ = decoder.raw_decode(cand[m.start():])
            except ValueError:
                continue
            if isinstance(obj, dict):
                return obj
    return None


def run_llm(cmd, prompt) -> str:
    try:
        proc = subprocess.run(cmd, shell=True, input=prompt, capture_output=True, text=True,
                              timeout=LLM_TIMEOUT_SECONDS)
    except subprocess.TimeoutExpired:
        raise AnalyzeError(f"LLM command timed out after {LLM_TIMEOUT_SECONDS}s: {cmd}")
    if proc.returncode != 0:
        raise AnalyzeError(f"LLM command exited {proc.returncode}: {cmd}\n{proc.stderr.strip()[:500]}",
                           proc.stdout)
    return proc.stdout


def ask_json(cmd, prompt, label):
    """Call the LLM and parse JSON; retry once on unparseable output, then raise AnalyzeError."""
    raw = ""
    for attempt in (1, 2):
        raw = run_llm(cmd, prompt)
        obj = parse_json(raw)
        if obj is not None:
            return obj
        print(f"agent_insights: {label}: could not parse JSON from LLM (attempt {attempt}/2)",
              file=sys.stderr)
    raise AnalyzeError(f"{label}: LLM output was not valid JSON after retry", raw)


def analyze(harness, sessions, cmd, batch_size, top, config=""):
    """Run map-reduce; returns a report dict (see normalize_report). Raises AnalyzeError on failure."""
    groups = batches(build_digests(sessions), batch_size)
    summaries = [ask_json(cmd, map_prompt(harness, g, i, len(groups)), f"batch {i}/{len(groups)}")
                 for i, g in enumerate(groups, 1)]
    result = ask_json(cmd, reduce_prompt(harness, summaries, compact_stats(sessions, top), config,
                                                 session_span(sessions)), "reduce")
    sections = result.get("sections")
    if not isinstance(sections, list) or not sections:
        raise AnalyzeError("reduce: JSON had no 'sections' list", json.dumps(result, indent=1))
    return normalize_report(result)


def _strs(value):
    if isinstance(value, str):
        return [value]
    return [v if isinstance(v, str) else json.dumps(v, ensure_ascii=False)
            for v in value] if isinstance(value, list) else []


def _str(value):
    if isinstance(value, list):
        return " ".join(_strs(value))
    return value if isinstance(value, str) else ("" if value is None else json.dumps(value, ensure_ascii=False))


def normalize_section(x):
    return {"title": str(x.get("title") or "Untitled"),
            "paragraphs": _strs(x.get("paragraphs")), "bullets": _strs(x.get("bullets"))}


def normalize_suggestion(x):
    raw_target = _str(x.get("target")).strip()
    low = raw_target.lower()
    scope = _str(x.get("scope")).strip().lower()
    if scope not in SCOPES:
        scope = "harness"  # missing/invalid scope: the safest place for a rule is the harness's own file
    if "agents.md" in low or "instructions" in low or raw_target in INSTRUCTION_TARGETS.values():
        target = INSTRUCTION_TARGETS[scope]
    elif raw_target in TARGETS:
        target = raw_target
    else:
        target = {t.lower(): t for t in TARGETS}.get(low, "other")
    conf = _str(x.get("confidence")).strip().lower()
    return {"target": target, "scope": scope, "project": project_dir_name(x.get("project")) if scope == "project" else "",
            "title": _str(x.get("title")).strip() or "Untitled suggestion",
            "why": _str(x.get("why")).strip(), "evidence": _str(x.get("evidence")).strip(),
            "snippet": _str(x.get("snippet")).strip("\n"), "lang": _str(x.get("lang")).strip(),
            "confidence": conf if conf in CONFIDENCE else "low"}


_BULLET_RE = re.compile(r"^\s*[-*\u2022]\s+")


def strip_bullet(text) -> str:
    """Drop one leading '- ' / '* ' so renderers can add their own bullet without doubling it."""
    return _BULLET_RE.sub("", str(text), count=1)


def normalize_report(result):
    """Tolerant normalization; missing glance/horizon/suggestions simply become empty."""
    glance_in = result.get("glance") if isinstance(result.get("glance"), dict) else {}
    glance = {k: _str(glance_in.get(k)).strip() for k, _ in GLANCE_LABELS}
    sections = result.get("sections")
    horizon = result.get("horizon")
    sugg = result.get("suggestions")
    return {
        "glance": {k: v for k, v in glance.items() if v},
        "sections": [normalize_section(x) for x in sections if isinstance(x, dict)]
        if isinstance(sections, list) else [],
        "horizon": [{"title": _str(h.get("title")).strip() or "Idea", "what": _str(h.get("what")).strip(),
                     "prompt": _str(h.get("prompt")).strip("\n")}
                    for h in horizon if isinstance(h, dict)] if isinstance(horizon, list) else [],
        "suggestions": [normalize_suggestion(x) for x in sugg
                        if isinstance(x, dict) and (x.get("title") or x.get("snippet"))]
        if isinstance(sugg, list) else [],
    }


def raw_report(raw):
    return normalize_report({"sections": [{"title": "Raw LLM output (unparsed)",
                                           "paragraphs": [raw or "(empty)"]}]})


def dry_run_text(harness, sessions, cmd, batch_size, top, config="") -> str:
    groups = batches(build_digests(sessions), batch_size)
    placeholder = reduce_prompt(harness, ["<JSON summary of each batch, from the map calls>"],
                                {"note": "aggregate common.summarize() stats go here"}, config,
                                session_span(sessions))
    return (f"=== MAP PROMPT (batch 1 of {len(groups)}; {len(groups)} map call(s) total) ===\n"
            f"{map_prompt(harness, groups[0], 1, len(groups))}\n"
            f"=== REDUCE PROMPT (placeholder; 1 call) ===\n{placeholder}\n"
            f"=== DRY RUN: no LLM call made; would pipe to: {cmd} ===")


# ---- Markdown -----------------------------------------------------------------------------------

def grouped_suggestions(harness, suggestions):
    """[{target, name, where, scope, items}]: instruction files General, Harness, Project first, then other
    targets in TARGETS order; empty groups dropped."""
    groups = []
    for scope in SCOPES:
        key = INSTRUCTION_TARGETS[scope]
        items = [s for s in suggestions if s["target"] == key]
        buckets = {}
        for s in items:
            buckets.setdefault(s.get("project", "") if scope == "project" else "", []).append(s)
        for project, bucket in buckets.items():
            name, where = target_info(key, harness, project)
            groups.append({"target": key, "name": name, "where": where, "scope": scope, "items": bucket})
    for t in TARGETS:
        if t in INSTRUCTION_TARGETS.values():
            continue
        items = [s for s in suggestions if s["target"] == t]
        if items:
            name, where = target_info(t, harness)
            groups.append({"target": t, "name": name, "where": where, "scope": "", "items": items})
    return groups


def general_warning(s, wired) -> str:
    """Warning for a general-scope instruction suggestion when this harness does not load the shared file."""
    if s["target"] != INSTRUCTION_TARGETS["general"] or not wired or wired["state"] == "linked-to-shared":
        return ""
    return (f"this harness does not currently load {wiring.SHARED} (state: {wired['state']}) \u2014 see Wiring")


def wiring_markdown(w) -> list:
    sh = w["shared"]
    out = ["## Wiring", "",
           f"- Shared file {sh['path']}: " + (f"exists, {sh['bytes']} bytes" if sh["exists"] else "missing")]
    for f in w["files"]:
        tag = " (loaded: first existing candidate)" if f["winner"] else ""
        out.append(f"- {f['path']}: **{f['state']}**, {f['bytes']} bytes{tag}")
    out += [f"- _{w['verified_note']}_", ""]
    for fix in w["fixes"]:
        out += [f"Fix for {fix['path']} (display only, nothing was run):", "", "```bash", *fix["commands"], "```", ""]
    return out


def render_markdown(harness, report, meta, title=None) -> str:
    wired = wiring.wiring_status(harness, os.path.expanduser("~"))
    out = [f"# {title or f'{harness} usage insights'}", "", f"_{meta}_", ""]
    if report["glance"]:
        out += ["## At a Glance", ""]
        out += [f"- **{label}:** {report['glance'][k]}" for k, label in GLANCE_LABELS if k in report["glance"]]
        out.append("")
    out += wiring_markdown(wired)
    for sec in report["sections"]:
        out += [f"## {sec['title']}", ""]
        for p in sec["paragraphs"]:
            out += [p, ""]
        for b in sec["bullets"]:
            out.append(f"- {strip_bullet(b)}")
        if sec["bullets"]:
            out.append("")
    if report["suggestions"]:
        out += ["## Suggestions", ""]
        for group in grouped_suggestions(harness, report["suggestions"]):
            out += [f"### {group['name']} ({group['where']})", ""]
            for s in group["items"]:
                out.append(f"- **{s['title']}** [{s['confidence']}] [scope: {s['scope']}] {s['why']}".rstrip())
                warning = general_warning(s, wired)
                if warning:
                    out.append(f"  - Warning: {warning}")
                if s["evidence"]:
                    out.append(f"  - Evidence: {s['evidence']}")
                if s["snippet"]:
                    out += ["", f"```{s['lang']}", s["snippet"], "```"]
                out.append("")
    if report["horizon"]:
        out += ["## On the Horizon", ""]
        for h in report["horizon"]:
            out += [f"### {h['title']}", "", h["what"], ""]
            if h["prompt"]:
                out += ["```text", h["prompt"], "```", ""]
    return "\n".join(out).rstrip() + "\n"


# ---- HTML ---------------------------------------------------------------------------------------

WEEKDAYS = ("Mon", "Tue", "Wed", "Thu", "Fri", "Sat", "Sun")


def chart_data(stats, top=8):
    """[(chart title, [(label, value)])] computed locally from common.summarize(); no LLM involved."""
    hours = [(f"{h:02d}", stats["hours"].get(str(h), 0)) for h in range(24)]
    return [
        ("Sessions per day (last 30 active days)", list(stats["days"].items())[-30:]),
        ("Hour of day (UTC)", hours),
        ("Weekday", [(d, stats["weekdays"].get(d, 0)) for d in WEEKDAYS]),
        ("Top tools", list(stats["tools"].items())[:top]),
        ("Models (sessions using)", list(stats["models"].items())[:top]),
        ("Top projects", list(stats["projects"].items())[:top]),
    ]


def stat_row(stats):
    t = stats["tokens"]
    return [
        (common.fmt_int(stats["sessions"]), "Sessions"),
        (common.fmt_int(stats["user_turns"]), "User turns"),
        (common.fmt_int(stats["tool_calls"]), "Tool calls"),
        (f"{error_rate(stats) * 100:.1f}%", "Tool error rate"),
        (f"{common.fmt_tokens(t['input'])} / {common.fmt_tokens(t['output'])}", "Tokens in / out"),
        (common.fmt_duration(stats["total_duration_seconds"]), "Time (12h cap per session)"),
    ]


def slug(text):
    return re.sub(r"[^a-z0-9]+", "-", text.lower()).strip("-") or "section"


def report_id(harness, stats):
    key = f"{stats['sessions']}|{stats['first']}|{stats['last']}"
    return f"{harness}-{datetime.now().strftime('%Y-%m-%d')}-{hashlib.sha1(key.encode()).hexdigest()[:6]}"


def default_out_path(harness, tag=""):
    return os.path.join(os.path.expanduser("~/.cache/agent_insights"),
                        f"{harness}-{tag}{datetime.now().strftime('%Y-%m-%d')}.html")


HTML_THEME_LIGHT = r"""
  color-scheme:light;
  --bg:#f4f6fb; --surface:#ffffff; --surface-2:#f8fafc; --fg:#0f172a; --muted:#475569; --line:#e2e8f0;
  --shadow:0 1px 2px rgba(15,23,42,.06),0 4px 14px rgba(15,23,42,.06);
  --shadow-hover:0 2px 4px rgba(15,23,42,.08),0 10px 26px rgba(15,23,42,.12);
  --nav-bg:rgba(244,246,251,.88); --focus:#2563eb;
  --hero-a:#1e3a8a; --hero-b:#6d28d9; --hero-c:#be185d;
  --code-bg:#0f172a; --code-fg:#e2e8f0; --code-muted:#94a3b8; --code-btn:rgba(255,255,255,.12);
  --blue:#1d4ed8; --blue-soft:#dbeafe; --blue-bar:#3b82f6; --blue-bar2:#60a5fa;
  --violet:#6d28d9; --violet-soft:#ede9fe; --violet-bar:#8b5cf6; --violet-bar2:#a78bfa;
  --teal:#0f766e; --teal-soft:#ccfbf1; --teal-bar:#14b8a6; --teal-bar2:#5eead4;
  --green:#166534; --green-soft:#dcfce7; --green-bar:#22c55e; --green-bar2:#86efac;
  --amber:#92400e; --amber-soft:#fef3c7; --amber-bar:#f59e0b; --amber-bar2:#fcd34d;
  --red:#b91c1c; --red-soft:#fee2e2; --red-bar:#ef4444; --red-bar2:#fca5a5;
  --pink:#9d174d; --pink-soft:#fce7f3; --pink-bar:#ec4899; --pink-bar2:#f9a8d4;
"""

HTML_THEME_DARK = r"""
  color-scheme:dark;
  --bg:#0b1020; --surface:#141a2e; --surface-2:#1a2138; --fg:#e5e9f5; --muted:#a3adc4; --line:#2a3350;
  --shadow:0 1px 2px rgba(0,0,0,.4),0 4px 14px rgba(0,0,0,.3);
  --shadow-hover:0 2px 4px rgba(0,0,0,.5),0 10px 26px rgba(0,0,0,.5);
  --nav-bg:rgba(11,16,32,.88); --focus:#93c5fd;
  --hero-a:#1e2a5e; --hero-b:#3b1d6e; --hero-c:#5b1646;
  --code-bg:#0a0e1c; --code-fg:#e2e8f0; --code-muted:#94a3b8; --code-btn:rgba(255,255,255,.1);
  --blue:#93c5fd; --blue-soft:#1e2a52; --blue-bar:#60a5fa; --blue-bar2:#3b82f6;
  --violet:#c4b5fd; --violet-soft:#2c2352; --violet-bar:#a78bfa; --violet-bar2:#7c3aed;
  --teal:#5eead4; --teal-soft:#0f3a3a; --teal-bar:#2dd4bf; --teal-bar2:#0d9488;
  --green:#86efac; --green-soft:#12361f; --green-bar:#4ade80; --green-bar2:#16a34a;
  --amber:#fcd34d; --amber-soft:#3d2c0c; --amber-bar:#fbbf24; --amber-bar2:#d97706;
  --red:#fca5a5; --red-soft:#431a1f; --red-bar:#f87171; --red-bar2:#dc2626;
  --pink:#f9a8d4; --pink-soft:#431a33; --pink-bar:#f472b6; --pink-bar2:#db2777;
"""

HTML_CSS_BODY = r"""
* { box-sizing:border-box; }
html { -webkit-text-size-adjust:100%; }
body { margin:0; background:var(--bg); color:var(--fg); overflow-wrap:break-word;
  font:15px/1.6 ui-sans-serif,system-ui,-apple-system,"Segoe UI",Roboto,"Helvetica Neue",Arial,sans-serif; }
body.has-bar { padding-bottom:4.5rem; }
code, pre { font-family:ui-monospace,SFMono-Regular,Menlo,Consolas,"Liberation Mono",monospace; }
code { font-size:.88em; background:var(--surface-2); border:1px solid var(--line); border-radius:5px; padding:.05rem .3rem; }
a { color:var(--blue); }
:focus-visible { outline:3px solid var(--focus); outline-offset:2px; border-radius:6px; }
.wrap { max-width:1000px; margin:0 auto; padding:16px 16px 4rem; }
.a-blue { --ac:var(--blue); --ac-soft:var(--blue-soft); --ac-bar:var(--blue-bar); --ac-bar2:var(--blue-bar2); }
.a-violet { --ac:var(--violet); --ac-soft:var(--violet-soft); --ac-bar:var(--violet-bar); --ac-bar2:var(--violet-bar2); }
.a-teal { --ac:var(--teal); --ac-soft:var(--teal-soft); --ac-bar:var(--teal-bar); --ac-bar2:var(--teal-bar2); }
.a-green { --ac:var(--green); --ac-soft:var(--green-soft); --ac-bar:var(--green-bar); --ac-bar2:var(--green-bar2); }
.a-amber { --ac:var(--amber); --ac-soft:var(--amber-soft); --ac-bar:var(--amber-bar); --ac-bar2:var(--amber-bar2); }
.a-red { --ac:var(--red); --ac-soft:var(--red-soft); --ac-bar:var(--red-bar); --ac-bar2:var(--red-bar2); }
.a-pink { --ac:var(--pink); --ac-soft:var(--pink-soft); --ac-bar:var(--pink-bar); --ac-bar2:var(--pink-bar2); }
.lift { transition:transform .15s ease,box-shadow .15s ease,border-color .15s ease; }
.lift:hover { transform:translateY(-2px); box-shadow:var(--shadow-hover); }

/* hero */
.hero { position:relative; overflow:hidden; color:#fff; border-radius:18px; padding:2rem 1.5rem 1.6rem; margin-bottom:12px;
  background:linear-gradient(135deg,var(--hero-a),var(--hero-b) 58%,var(--hero-c)); box-shadow:var(--shadow); }
.hero::before { content:""; position:absolute; right:-60px; top:-80px; width:260px; height:260px; border-radius:50%;
  background:radial-gradient(circle,rgba(255,255,255,.22),rgba(255,255,255,0) 70%); }
.hero::after { content:""; position:absolute; left:30%; bottom:-120px; width:320px; height:220px; border-radius:50%;
  background:radial-gradient(circle,rgba(255,255,255,.12),rgba(255,255,255,0) 70%); }
.hero > * { position:relative; z-index:1; }
.eyebrow { font-size:.72rem; text-transform:uppercase; letter-spacing:.14em; font-weight:700; color:#f1f5f9; margin:0 0 .5rem; }
.hero h1 { font-size:clamp(1.55rem,5vw,2.3rem); line-height:1.15; margin:0 0 .5rem; letter-spacing:-.02em; color:#fff; }
.subtitle { color:#f1f5f9; margin:0 0 1rem; max-width:44rem; }
.chips { display:flex; flex-wrap:wrap; gap:.45rem; }
.chip { font-size:.78rem; color:#fff; background:rgba(0,0,0,.26); border:1px solid rgba(255,255,255,.28);
  border-radius:999px; padding:.18rem .7rem; }
.chip b { font-weight:700; }

/* sticky nav */
nav.toc { position:sticky; top:0; z-index:30; display:flex; gap:.4rem; overflow-x:auto; padding:.55rem .25rem;
  margin:0 0 1.25rem; background:var(--nav-bg); -webkit-backdrop-filter:blur(8px); backdrop-filter:blur(8px);
  border-bottom:1px solid var(--line); scrollbar-width:thin; }
nav.toc a { flex:0 0 auto; font-size:.8rem; font-weight:600; color:var(--muted); text-decoration:none; white-space:nowrap;
  background:var(--surface); border:1px solid var(--line); padding:.28rem .75rem; border-radius:999px;
  transition:background .15s,color .15s,border-color .15s; }
nav.toc a:hover { color:var(--fg); border-color:var(--blue-bar); }
nav.toc a.active, nav.toc a[aria-current="true"] { color:#fff; background:var(--blue); border-color:var(--blue); }
:root[data-theme="dark"] nav.toc a.active, :root[data-theme="dark"] nav.toc a[aria-current="true"] { color:#0b1020; }
@media (prefers-color-scheme: dark) {
  :root:not([data-theme="light"]) nav.toc a.active, :root:not([data-theme="light"]) nav.toc a[aria-current="true"] { color:#0b1020; }
}
section, .at-a-glance, .wiring-card, .stats-row, .charts-row { scroll-margin-top:4.2rem; }
section.report:target > h2 { text-decoration:underline; text-decoration-color:var(--ac-bar); text-underline-offset:.3rem; }

/* at a glance */
.at-a-glance { margin:0 0 1.5rem; }
.at-a-glance > h2 { font-size:1.25rem; margin:0 0 .7rem; letter-spacing:-.01em; }
.glance-grid { display:grid; grid-template-columns:repeat(auto-fit,minmax(min(100%,230px),1fr)); gap:.8rem; }
.glance-card { background:linear-gradient(160deg,var(--ac-soft),var(--surface) 85%); border:1px solid var(--line);
  border-top:4px solid var(--ac-bar); border-radius:14px; padding:.85rem 1rem 1rem; box-shadow:var(--shadow); }
.glance-card h3 { margin:0 0 .35rem; font-size:.78rem; text-transform:uppercase; letter-spacing:.08em; color:var(--ac); }
.glance-card h3 a { color:inherit; text-decoration:none; }
.glance-card h3 a:hover { text-decoration:underline; }
.glance-card p { margin:0; font-size:.9rem; }

/* wiring callout */
.wiring-card { --ac:var(--green); --ac-soft:var(--green-soft); --ac-bar:var(--green-bar);
  background:var(--ac-soft); border:1px solid var(--ac-bar); border-left-width:6px; border-radius:14px;
  padding:.85rem 1.2rem 1rem; margin:0 0 1.5rem; }
.wiring-card.warn { --ac:var(--amber); --ac-soft:var(--amber-soft); --ac-bar:var(--amber-bar); }
.wiring-card.bad { --ac:var(--red); --ac-soft:var(--red-soft); --ac-bar:var(--red-bar); }
.wiring-card h2 { margin:.1rem 0 .5rem; font-size:1.05rem; color:var(--ac); display:flex; align-items:center; gap:.5rem; }
.wiring-card h2 svg { width:1.15rem; height:1.15rem; flex:0 0 auto; }
.wiring-card .wiring-status { font-weight:400; font-size:.85rem; }
.wiring-row { margin:.3rem 0; font-size:.88rem; color:var(--fg); }
.wiring-card .cmd-why { color:var(--fg); opacity:.85; }

/* stat tiles */
.stats-row { display:grid; grid-template-columns:repeat(auto-fit,minmax(min(100%,150px),1fr)); gap:.75rem; margin-bottom:1.25rem; }
.stat { position:relative; background:var(--surface); border:1px solid var(--line); border-radius:14px; padding:.85rem 1rem;
  box-shadow:var(--shadow); overflow:hidden; }
.stat::before { content:""; position:absolute; left:0; right:0; top:0; height:4px;
  background:linear-gradient(90deg,var(--ac-bar),var(--ac-bar2)); }
.stat-icon { width:2rem; height:2rem; border-radius:9px; background:var(--ac-soft); color:var(--ac); display:flex;
  align-items:center; justify-content:center; margin-bottom:.45rem; }
.stat-icon svg { width:1.1rem; height:1.1rem; fill:none; stroke:currentColor; stroke-width:2; stroke-linecap:round; stroke-linejoin:round; }
.stat-value { font-size:1.45rem; font-weight:750; line-height:1.2; letter-spacing:-.02em; font-variant-numeric:tabular-nums; }
.stat-label { font-size:.74rem; color:var(--muted); margin-top:.1rem; }

/* charts */
.charts-row { display:grid; grid-template-columns:repeat(auto-fit,minmax(min(100%,420px),1fr)); gap:1rem; margin-bottom:1.5rem; }
.chart-card { background:var(--surface); border:1px solid var(--line); border-top:4px solid var(--ac-bar); border-radius:14px;
  padding:.9rem 1.1rem 1rem; min-width:0; box-shadow:var(--shadow); }
.chart-title { font-weight:700; font-size:.86rem; margin-bottom:.6rem; color:var(--ac); }
.bar-row { display:flex; align-items:center; gap:.5rem; margin:.25rem 0; font-size:.78rem; }
.bar-label { flex:0 0 7.5rem; overflow:hidden; text-overflow:ellipsis; white-space:nowrap; color:var(--muted); }
.bar-track { flex:1; min-width:0; background:var(--ac-soft); border-radius:999px; height:.8rem; overflow:hidden; }
.bar-fill { background:linear-gradient(90deg,var(--ac-bar),var(--ac-bar2)); height:100%; border-radius:999px; min-width:2px; }
.bar-value { flex:0 0 3rem; text-align:right; font-weight:600; font-variant-numeric:tabular-nums; }
.empty { color:var(--muted); font-size:.82rem; }

/* section cards */
section.report { margin:1.6rem 0; }
section.card-sec { background:var(--surface); border:1px solid var(--line); border-left:6px solid var(--ac-bar);
  border-radius:14px; padding:1rem 1.2rem 1.1rem; box-shadow:var(--shadow); }
.kicker { display:inline-block; font-size:.68rem; font-weight:700; text-transform:uppercase; letter-spacing:.1em;
  color:var(--ac); background:var(--ac-soft); border-radius:999px; padding:.08rem .6rem; margin-bottom:.35rem; }
section.report > h2, section.report > .sec-head h2 { font-size:1.3rem; margin:0 0 .4rem; letter-spacing:-.01em; }
section.report > h2::before { content:""; display:inline-block; width:.35rem; height:1.1em; border-radius:3px; margin-right:.5rem;
  vertical-align:-.15em; background:linear-gradient(180deg,var(--ac-bar),var(--ac-bar2)); }
.sec-head h2 { margin:0; }
.section-intro { color:var(--muted); margin:0 0 .7rem; }
.narrative p { margin:.4rem 0; }
.narrative ul, section.card-sec > ul { margin:.4rem 0; padding-left:1.25rem; }
.narrative li::marker, section.card-sec li::marker { color:var(--ac-bar); }
.narrative li, section.card-sec > ul > li { margin:.25rem 0; }
.k-friction li::marker, .k-wins li::marker { font-weight:700; }

/* verdict banner */
.verdict { display:flex; flex-wrap:wrap; align-items:center; gap:.7rem 1rem; border-radius:12px; padding:.9rem 1.1rem; margin:.3rem 0 .6rem;
  background:linear-gradient(135deg,var(--ac-soft),var(--surface)); border:1px solid var(--ac-bar); }
.verdict-pill { font-size:.95rem; font-weight:800; letter-spacing:.06em; text-transform:uppercase; color:#fff;
  background:var(--ac); padding:.3rem .95rem; border-radius:999px; white-space:nowrap; }
:root[data-theme="dark"] .verdict-pill { color:#0b1020; }
@media (prefers-color-scheme: dark) { :root:not([data-theme="light"]) .verdict-pill { color:#0b1020; } }
.verdict-text { flex:1 1 16rem; min-width:0; font-size:1.02rem; font-weight:600; }

/* metrics grid, hotspots, checklist */
.metrics-grid { display:grid; grid-template-columns:repeat(auto-fit,minmax(min(100%,170px),1fr)); gap:.6rem; margin:.5rem 0; }
.metric { background:var(--ac-soft); border:1px solid var(--line); border-radius:10px; padding:.55rem .75rem; min-width:0; }
.metric-label { font-size:.7rem; text-transform:uppercase; letter-spacing:.06em; color:var(--muted); }
.metric-value { font-size:1.05rem; font-weight:700; color:var(--fg); font-variant-numeric:tabular-nums; }
.hotspots { display:grid; grid-template-columns:repeat(auto-fit,minmax(min(100%,280px),1fr)); gap:.75rem; margin:.5rem 0; }
.hotspot-card { background:var(--surface-2); border:1px solid var(--line); border-top:4px solid var(--ac-bar); border-radius:12px;
  padding:.7rem .9rem; }
.hotspot-title { font-weight:700; color:var(--ac); }
.hotspot-num { margin:.2rem 0; }
.hotspot-evidence { font-size:.82rem; color:var(--muted); font-family:ui-monospace,SFMono-Regular,Menlo,Consolas,monospace; }
.checklist { list-style:none; margin:.5rem 0; padding:0; }
.check-item { margin:.35rem 0; background:var(--surface-2); border:1px solid var(--line); border-radius:10px; }
.check-item label { display:flex; gap:.6rem; align-items:flex-start; padding:.55rem .8rem; cursor:pointer; }
.check-item .expect { display:block; font-size:.84rem; color:var(--green); font-weight:600; }
.check-item.done > label > span { opacity:.65; }

/* suggestions */
.target-group { margin:1.4rem 0; --ac:var(--teal); --ac-soft:var(--teal-soft); --ac-bar:var(--teal-bar); }
.target-group[data-scope="general"] { --ac:var(--blue); --ac-soft:var(--blue-soft); --ac-bar:var(--blue-bar); }
.target-group[data-scope="harness"] { --ac:var(--violet); --ac-soft:var(--violet-soft); --ac-bar:var(--violet-bar); }
.target-group[data-scope="project"] { --ac:var(--teal); --ac-soft:var(--teal-soft); --ac-bar:var(--teal-bar); }
.target-group[data-scope=""] { --ac:var(--pink); --ac-soft:var(--pink-soft); --ac-bar:var(--pink-bar); }
.group-head { display:flex; flex-wrap:wrap; align-items:center; gap:.4rem .6rem; }
.target-group h3 { margin:0; font-size:1.05rem; color:var(--ac); }
.target-path { color:var(--muted); font-size:.8rem; margin:.1rem 0 .5rem; }
.sugg-item, .horizon-card, .pattern-card { background:var(--surface); border:1px solid var(--line); border-left:5px solid var(--ac-bar);
  border-radius:12px; padding:.8rem 1rem; margin:.65rem 0; box-shadow:var(--shadow); }
.horizon-card { --ac:var(--amber); --ac-soft:var(--amber-soft); --ac-bar:var(--amber-bar); }
.cmd-row { display:flex; gap:.7rem; align-items:flex-start; }
.cmd-checkbox, .rt-box { margin:.3rem 0 0; width:1.15rem; height:1.15rem; flex:0 0 auto; accent-color:var(--green-bar); cursor:pointer; }
.cmd-body { flex:1; min-width:0; }
.cmd-title { font-weight:700; margin-right:.2rem; }
.cmd-why, .cmd-evidence { color:var(--muted); font-size:.87rem; margin:.25rem 0; }
.cmd-evidence b { color:var(--fg); }
.cmd-warn { color:var(--red); background:var(--red-soft); border-radius:8px; padding:.3rem .6rem; font-size:.85rem; margin:.35rem 0; }
.sugg-item.done { border-left-color:var(--green-bar); background:var(--surface-2); }
.sugg-item.done .cmd-title { text-decoration:line-through; opacity:.6; }
.badge { display:inline-block; font-size:.66rem; font-weight:700; text-transform:uppercase; letter-spacing:.06em;
  padding:.08rem .5rem; border-radius:999px; border:1px solid transparent; margin-left:.35rem; vertical-align:middle;
  color:var(--ac,var(--muted)); background:var(--ac-soft,var(--surface-2)); }
.group-head .badge { margin-left:0; }
.badge.high, .badge.good { color:var(--green); background:var(--green-soft); border-color:var(--green-bar); }
.badge.medium, .badge.warn { color:var(--amber); background:var(--amber-soft); border-color:var(--amber-bar); }
.badge.low, .badge.bad { color:var(--red); background:var(--red-soft); border-color:var(--red-bar); }
.badge.scope-general { color:var(--blue); background:var(--blue-soft); border-color:var(--blue-bar); }
.badge.scope-harness { color:var(--violet); background:var(--violet-soft); border-color:var(--violet-bar); }
.badge.scope-project { color:var(--teal); background:var(--teal-soft); border-color:var(--teal-bar); }
.badge.target-config { color:var(--pink); background:var(--pink-soft); border-color:var(--pink-bar); }
.badge.target-prompt { color:var(--amber); background:var(--amber-soft); border-color:var(--amber-bar); }
.badge.target-other { color:var(--muted); background:var(--surface-2); border-color:var(--line); }

/* code blocks */
.code-row { position:relative; margin-top:.5rem; }
.code-row::before { content:attr(data-lang); position:absolute; left:.8rem; top:.4rem; font-size:.66rem; letter-spacing:.08em;
  text-transform:uppercase; color:var(--code-muted); }
pre.cmd-code { margin:0; background:var(--code-bg); color:var(--code-fg); border:1px solid var(--line); border-radius:10px;
  padding:1.8rem .9rem .7rem; overflow:auto; max-height:26rem; font-size:12.5px; line-height:1.55; white-space:pre-wrap;
  overflow-wrap:anywhere; min-width:0; tab-size:2; }
.copy-btn { cursor:pointer; font:inherit; font-size:.78rem; font-weight:600; white-space:nowrap; color:var(--fg);
  background:var(--surface-2); border:1px solid var(--line); border-radius:8px; padding:.28rem .8rem;
  transition:background .15s,border-color .15s,color .15s; }
.copy-btn:hover { border-color:var(--blue-bar); }
.code-row .copy-btn { position:absolute; top:.4rem; right:.4rem; color:var(--code-fg); background:var(--code-btn);
  border-color:rgba(255,255,255,.22); padding:.15rem .65rem; }
.code-row .copy-btn:hover { background:rgba(255,255,255,.22); }
.copy-btn.copied, .code-row .copy-btn.copied { color:#052e16; background:#86efac; border-color:#4ade80; }
.prompt-label { font-size:.7rem; font-weight:700; text-transform:uppercase; color:var(--muted); letter-spacing:.07em; margin-top:.6rem; }
.horizon-title, .pattern-title { font-weight:700; font-size:1.02rem; color:var(--ac); }
.horizon-possible { color:var(--fg); margin:.25rem 0; }

/* floating copy-all bar */
.copy-all-bar { display:none; position:fixed; left:50%; bottom:14px; transform:translateX(-50%); z-index:40; align-items:center; gap:.75rem;
  max-width:calc(100vw - 32px); background:var(--surface); border:1px solid var(--line); border-radius:999px;
  padding:.4rem .5rem .4rem 1rem; box-shadow:var(--shadow-hover); }
.js .copy-all-bar.has-items { display:flex; }
.copy-all-bar .count { font-size:.85rem; font-weight:700; white-space:nowrap; }
.copy-all-bar.has-items .count { color:var(--green); }
.copy-all-bar .copy-btn { color:#fff; background:var(--blue); border-color:var(--blue); padding:.4rem 1rem; border-radius:999px; }
:root[data-theme="dark"] .copy-all-bar .copy-btn { color:#0b1020; }
@media (prefers-color-scheme: dark) { :root:not([data-theme="light"]) .copy-all-bar .copy-btn { color:#0b1020; } }
.copy-all-bar .copy-btn.copied { color:#052e16; background:#86efac; border-color:#4ade80; }
.copy-btn { display:none; }
.js .copy-btn { display:inline-block; }

footer { color:var(--muted); font-size:.8rem; margin-top:2.5rem; padding-top:1rem; border-top:1px solid var(--line); }
footer p { margin:.2rem 0; }

@media (max-width:560px) {
  .bar-label { flex-basis:5rem; }
  .hero { padding:1.4rem 1rem 1.2rem; border-radius:14px; }
  section.card-sec { padding:.85rem .9rem; }
  .copy-all-bar { left:16px; right:16px; transform:none; justify-content:space-between; }
}
@media (prefers-reduced-motion: no-preference) { html { scroll-behavior:smooth; } }
@media (prefers-reduced-motion: reduce) {
  *, *::before, *::after { transition:none !important; animation:none !important; scroll-behavior:auto !important; }
  .lift:hover { transform:none; }
}
@media print {
  body { background:#fff; color:#000; font-size:11pt; }
  body.has-bar { padding-bottom:0; }
  nav.toc, .copy-btn, .copy-all-bar, .js .copy-btn, .js .copy-all-bar { display:none !important; }
  .wrap { max-width:none; padding:0; }
  .hero { color:#000; background:#fff; border:1px solid #999; box-shadow:none; }
  .hero::before, .hero::after { display:none; }
  .hero h1, .eyebrow, .subtitle, .chip { color:#000; }
  .chip { background:#fff; border-color:#999; }
  .lift:hover { transform:none; box-shadow:none; }
  .stat, .chart-card, section.card-sec, .sugg-item, .horizon-card, .glance-card, .hotspot-card, .wiring-card, .verdict, .metric {
    box-shadow:none; break-inside:avoid; }
  pre.cmd-code { background:#f3f4f6; color:#111; max-height:none; overflow:visible; border-color:#999; }
  .code-row::before { color:#555; }
  .verdict-pill { color:#fff !important; }
  a { color:inherit; text-decoration:none; }
}
"""

HTML_CSS = (":root {" + HTML_THEME_LIGHT + "}\n@media (prefers-color-scheme: dark) {\n  :root:not([data-theme=\"light\"]) {"
            + HTML_THEME_DARK + "  }\n}\n:root[data-theme=\"dark\"] {" + HTML_THEME_DARK + "}\n" + HTML_CSS_BODY
            + "@media print {\n  :root, :root[data-theme=\"dark\"], :root:not([data-theme=\"light\"]) {" + HTML_THEME_LIGHT + "  }\n}\n")

HTML_JS = r"""
(function () {
  document.documentElement.className += ' js';
  var RID = document.body.getAttribute('data-report-id') || 'report';
  var KEY = 'agent_insights:' + RID + ':done';
  function load() { try { return JSON.parse(localStorage.getItem(KEY) || '{}') || {}; } catch (e) { return {}; } }
  function save(state) { try { localStorage.setItem(KEY, JSON.stringify(state)); } catch (e) {} }
  function copyText(text, btn) {
    var label = btn.getAttribute('data-label') || btn.textContent;
    btn.setAttribute('data-label', label);
    function ok() {
      btn.textContent = 'Copied'; btn.classList.add('copied');
      setTimeout(function () { btn.textContent = label; btn.classList.remove('copied'); }, 1500);
    }
    function fallback() {
      var ta = document.createElement('textarea');
      ta.value = text; ta.style.position = 'fixed'; ta.style.opacity = '0';
      document.body.appendChild(ta); ta.select();
      try { document.execCommand('copy'); ok(); } catch (e) {}
      document.body.removeChild(ta);
    }
    if (navigator.clipboard && navigator.clipboard.writeText) {
      navigator.clipboard.writeText(text).then(ok, fallback);
    } else { fallback(); }
  }
  var state = load();
  var bar = document.getElementById('copy-bar');
  var counter = document.getElementById('checked-count');
  function updateCount() {
    var n = document.querySelectorAll('.sugg-item .cmd-checkbox:checked').length;
    if (counter) { counter.textContent = n + ' checked'; }
    if (bar) { bar.classList.toggle('has-items', n > 0); }
  }
  if (bar) { document.body.classList.add('has-bar'); }
  Array.prototype.forEach.call(document.querySelectorAll('input[data-sid]'), function (box) {
    var id = box.getAttribute('data-sid');
    var holder = box.closest('.sugg-item, .check-item');
    box.checked = !!state[id];
    if (holder) { holder.classList.toggle('done', box.checked); }
    box.addEventListener('change', function () {
      state[id] = box.checked ? 1 : 0;
      if (holder) { holder.classList.toggle('done', box.checked); }
      save(state);
      updateCount();
    });
  });
  updateCount();
  Array.prototype.forEach.call(document.querySelectorAll('.copy-btn[data-copy]'), function (btn) {
    btn.addEventListener('click', function () {
      var el = document.getElementById(btn.getAttribute('data-copy'));
      if (el) { copyText(el.textContent, btn); }
    });
  });
  var all = document.getElementById('copy-all-checked');
  if (all) {
    all.addEventListener('click', function () {
      var out = [];
      Array.prototype.forEach.call(document.querySelectorAll('.target-group'), function (group) {
        var chunks = [];
        Array.prototype.forEach.call(group.querySelectorAll('.sugg-item'), function (item) {
          var box = item.querySelector('.cmd-checkbox');
          var code = item.querySelector('pre.cmd-code');
          if (box && box.checked && code && code.textContent.trim()) { chunks.push(code.textContent.trim()); }
        });
        if (chunks.length) {
          out.push('# ' + group.getAttribute('data-target') + ' -> ' + group.getAttribute('data-where') +
                   '\n\n' + chunks.join('\n\n'));
        }
      });
      copyText(out.length ? out.join('\n\n\n') + '\n' : '(nothing checked)', all);
    });
  }
  // active section highlight in the sticky nav (without JS the nav still works as plain anchors)
  var links = {};
  Array.prototype.forEach.call(document.querySelectorAll('nav.toc a[href^="#"]'), function (a) {
    links[a.getAttribute('href').slice(1)] = a;
  });
  function activate(id) {
    Object.keys(links).forEach(function (k) {
      var on = k === id;
      links[k].classList.toggle('active', on);
      if (on) { links[k].setAttribute('aria-current', 'true'); links[k].scrollIntoView({block: 'nearest', inline: 'nearest'}); }
      else { links[k].removeAttribute('aria-current'); }
    });
  }
  if ('IntersectionObserver' in window) {
    var io = new IntersectionObserver(function (entries) {
      entries.forEach(function (e) { if (e.isIntersecting) { activate(e.target.id); } });
    }, {rootMargin: '-15% 0px -75% 0px', threshold: 0});
    Object.keys(links).forEach(function (id) { var el = document.getElementById(id); if (el) { io.observe(el); } });
  }
})();
"""

STAT_ICONS = (  # (accent, inline svg children on a 24x24 stroke grid); decorative, aria-hidden
    ("blue", '<rect x="3" y="4" width="18" height="6" rx="2"/><rect x="3" y="14" width="18" height="6" rx="2"/>'),
    ("violet", '<path d="M4 5h16v11H9l-5 4z"/>'),
    ("teal", '<path d="M8 8l-4 4 4 4M16 8l4 4-4 4M14 5l-4 14"/>'),
    ("red", '<path d="M12 4l9 16H3z"/><path d="M12 10v4M12 17v.5"/>'),
    ("amber", '<path d="M7 4v14M4 15l3 3 3-3M17 20V6M14 9l3-3 3 3"/>'),
    ("green", '<circle cx="12" cy="12" r="8"/><path d="M12 7v5l3 2"/>'),
)
CHART_ACCENTS = ("blue", "violet", "teal", "amber", "pink", "green")
SECTION_KINDS = (  # (title prefix lowercased, css kind, accent, kicker)
    ("what you work on", "work", "blue", "Work"), ("how you use", "usage", "violet", "Usage"),
    ("impressive", "wins", "green", "Wins"), ("where things go wrong", "friction", "red", "Friction"),
    ("existing features", "features", "teal", "Features"), ("new ways", "patterns", "pink", "Patterns"),
    ("across models", "work", "blue", "Overview"), ("measured", "measured", "blue", "Metrics"),
    ("verdict", "verdict", "amber", "Verdict"), ("waste hotspots", "hotspots", "red", "Hotspots"),
    ("settings to change", "features", "teal", "Settings"), ("rules/prompts", "patterns", "pink", "Rules"),
    ("re-test", "retest", "green", "Checklist"),
)
GLANCE_STYLE = {"working": ("green", "sec-impressive-things-you-did"), "hindering": ("red", "sec-where-things-go-wrong"),
                "quick_wins": ("amber", "sec-existing-features-to-try"), "ambitious": ("violet", "horizon")}
VERDICT_STYLE = {"KEEP": ("keep", "green"), "SWITCH": ("switch", "blue"), "NEEDS TUNING": ("tune", "amber")}
_VERDICT_RE = re.compile(r"^\s*(KEEP|SWITCH|NEEDS TUNING)\b\s*:?\s*(.*)$", re.S)
_METRIC_RE = re.compile(r"^([^:]{1,48}): (.+)$", re.S)
_HOTSPOT_RE = re.compile(r"^(.*?): (.*?)(?: \(evidence: (.*)\))?$", re.S)
_CONF_RE = re.compile(r"^\[(high|medium|low)\] (.*)$", re.S)


def _section_kind(title):
    low = title.lower()
    for prefix, kind, accent, kicker in SECTION_KINDS:
        if low.startswith(prefix):
            return kind, accent, kicker
    return "generic", "blue", "Notes"


def _bar_chart(esc, title, items, idx=0):
    rows = []
    peak = max((v for _, v in items), default=0)
    for label, value in items:
        pct = 100.0 * value / peak if peak else 0
        rows.append(f'<div class="bar-row"><div class="bar-label" title="{esc(str(label))}">{esc(str(label))}'
                    f'</div><div class="bar-track"><div class="bar-fill" style="width:{pct:.1f}%"></div></div>'
                    f'<div class="bar-value">{esc(common.fmt_int(value))}</div></div>')
    body = "".join(rows) or '<div class="empty">no data</div>'
    accent = CHART_ACCENTS[idx % len(CHART_ACCENTS)]
    return f'<div class="chart-card lift a-{accent}"><div class="chart-title">{esc(title)}</div>{body}</div>'


def _code_row(esc, pid, text, lang=""):
    return (f'<div class="code-row" data-lang="{esc(lang)}"><pre class="cmd-code" id="{pid}" data-lang="{esc(lang)}">'
            f'{esc(text)}</pre><button type="button" class="copy-btn" data-copy="{pid}">Copy</button></div>')


def _suggestion_html(esc, rid, n, s, wired=None):
    sid = hashlib.sha1(f"{s['target']}|{s['title']}".encode()).hexdigest()[:10]
    block = [f'<div class="sugg-item lift"><div class="cmd-row">'
             f'<input type="checkbox" class="cmd-checkbox" data-sid="{sid}" aria-label="Mark done / include in copy all">'
             f'<div class="cmd-body"><div><span class="cmd-title">{esc(s["title"])}</span>'
             f'<span class="badge {esc(s["confidence"])}">{esc(s["confidence"])}</span>'
             f'<span class="badge scope-{esc(s["scope"])}">{esc(s["scope"])}</span></div>']
    warning = general_warning(s, wired)
    if warning:
        block.append(f'<div class="cmd-warn">{esc(warning)}</div>')
    if s["why"]:
        block.append(f'<div class="cmd-why">{esc(s["why"])}</div>')
    if s["evidence"]:
        block.append(f'<div class="cmd-evidence"><b>Evidence:</b> {esc(s["evidence"])}</div>')
    if s["snippet"]:
        block.append(_code_row(esc, f"snip-{n}", s["snippet"], s["lang"]))
    block.append("</div></div></div>")
    return "".join(block)


def _glance_html(esc, report, ids):
    if not report["glance"]:
        return ""
    cards = []
    for k, label in GLANCE_LABELS:
        if k not in report["glance"]:
            continue
        accent, target = GLANCE_STYLE[k]
        head = f'<a href="#{target}">{esc(label)}</a>' if target in ids else esc(label)
        cards.append(f'<div class="glance-card lift a-{accent} g-{k}"><h3>{head}</h3><p>{esc(report["glance"][k])}</p></div>')
    return f'<div class="at-a-glance" id="glance"><h2>At a Glance</h2><div class="glance-grid">{"".join(cards)}</div></div>'


STATE_CLASS = {"linked-to-shared": "good", "separate-copy": "warn", "empty": "bad", "missing": "bad"}
WIRING_ICONS = {"good": '<path d="M5 12l5 5 9-10"/>', "warn": '<path d="M12 4l9 16H3z"/><path d="M12 10v4M12 17v.5"/>',
                "bad": '<circle cx="12" cy="12" r="8"/><path d="M9 9l6 6M15 9l-6 6"/>'}
WIRING_HEADLINE = {"good": "linked to the shared file", "warn": "has its own copy, not linked",
                   "bad": "does not load the shared file"}


def _wiring_html(esc, w, start=1):
    sh = w["shared"]
    level = STATE_CLASS.get(w.get("state"), "bad")
    rows = [f'<div class="wiring-row">Shared file <code>{esc(sh["path"])}</code>: '
            + (f'exists, {sh["bytes"]:,} bytes' if sh["exists"] else "<b>missing</b>") + "</div>"]
    for f in w["files"]:
        tag = " (loaded: first existing candidate)" if f["winner"] else ""
        rows.append(f'<div class="wiring-row"><code>{esc(f["path"])}</code>: '
                    f'<span class="badge {STATE_CLASS[f["state"]]}">{esc(f["state"])}</span> '
                    f'{f["bytes"]:,} bytes{esc(tag)}</div>')
    rows.append(f'<div class="cmd-why">{esc(w["verified_note"])}</div>')
    n = start
    for fix in w["fixes"]:
        pid = f"wiring-fix-{n}"
        n += 1
        rows.append(f'<div class="prompt-label">Fix for {esc(fix["path"])} (display only, nothing is run)</div>'
                    + _code_row(esc, pid, chr(10).join(fix["commands"]), "bash"))
    icon = f'<svg viewBox="0 0 24 24" fill="none" stroke="currentColor" stroke-width="2.2" stroke-linecap="round" stroke-linejoin="round" aria-hidden="true">{WIRING_ICONS[level]}</svg>'
    return (f'<div class="wiring-card {level}" id="wiring" role="note"><h2>{icon}Wiring '
            f'<span class="wiring-status">- {esc(WIRING_HEADLINE[level])}</span></h2>{"".join(rows)}</div>')


def _verdict_body(esc, sec):
    text = sec["paragraphs"][0] if sec["paragraphs"] else ""
    m = _VERDICT_RE.match(text)
    klass, accent, pill = "none", "blue", ""
    if m:
        klass, accent = VERDICT_STYLE[m.group(1)]
        pill = f'<span class="verdict-pill">{esc(m.group(1).lower())}</span>'
        text = m.group(2)
    banner = (f'<div class="verdict v-{klass} a-{accent}" role="status">{pill}'
              f'<div class="verdict-text">{esc(text)}</div></div>') if (pill or text) else ""
    reasons = "<ul>" + "".join(f"<li>{esc(strip_bullet(b))}</li>" for b in sec["bullets"]) + "</ul>" if sec["bullets"] else ""
    return banner + reasons


def _measured_body(esc, sec):
    tiles, notes = [], []
    for b in sec["bullets"]:
        m = _METRIC_RE.match(b)
        if m and m.group(1).split(" ")[0] not in ("runaway", "error"):
            tiles.append(f'<div class="metric"><div class="metric-label">{esc(m.group(1))}</div>'
                         f'<div class="metric-value">{esc(m.group(2))}</div></div>')
        else:
            notes.append(f"<li>{esc(strip_bullet(b))}</li>")
    return (f'<div class="metrics-grid">{"".join(tiles)}</div>' if tiles else "") + \
           (f'<ul class="metric-notes">{"".join(notes)}</ul>' if notes else "")


def _hotspots_body(esc, sec):
    cards = []
    for b in sec["bullets"]:
        m = _HOTSPOT_RE.match(strip_bullet(b))
        title, num, ev = (m.group(1), m.group(2), m.group(3)) if m else (b, "", None)
        cards.append(f'<div class="hotspot-card lift"><div class="hotspot-title">{esc(title)}</div>'
                     + (f'<div class="hotspot-num">{esc(num)}</div>' if num else "")
                     + (f'<div class="hotspot-evidence">{esc(ev)}</div>' if ev else "") + "</div>")
    return f'<div class="hotspots">{"".join(cards)}</div>' if cards else ""


def _retest_body(esc, sec):
    items = []
    for b in sec["bullets"]:
        text = strip_bullet(b)
        main, sep, expect = text.partition(" -> ")
        sid = "rt" + hashlib.sha1(text.encode()).hexdigest()[:9]
        items.append(f'<li class="check-item"><label><input type="checkbox" class="rt-box" data-sid="{sid}">'
                     f'<span>{esc(main)}' + (f'<span class="expect">{esc(expect)}</span>' if sep else "")
                     + "</span></label></li>")
    return f'<ul class="checklist">{"".join(items)}</ul>' if items else ""


def _settings_bullets(esc, bullets):
    out = []
    for b in bullets:
        m = _CONF_RE.match(strip_bullet(b))
        out.append(f'<li><span class="badge {m.group(1)}">{m.group(1)}</span> {esc(m.group(2))}</li>' if m
                   else f"<li>{esc(strip_bullet(b))}</li>")
    return "<ul>" + "".join(out) + "</ul>" if out else ""


def _section_html(esc, sec, sid):
    kind, accent, kicker = _section_kind(sec["title"])
    paras = sec["paragraphs"]
    head = (f'<section class="report card-sec a-{accent} k-{kind}" id="{esc(sid)}">'
            f'<div class="sec-head"><span class="kicker">{esc(kicker)}</span><h2>{esc(sec["title"])}</h2></div>')
    if kind == "verdict":
        return head + _verdict_body(esc, sec) + "</section>"
    intro = f'<p class="section-intro">{esc(paras[0])}</p>' if paras else ""
    if kind == "measured":
        return head + intro + _measured_body(esc, sec) + "</section>"
    if kind == "hotspots":
        return head + intro + _hotspots_body(esc, sec) + "</section>"
    if kind == "retest":
        return head + intro + _retest_body(esc, sec) + "</section>"
    block = [head, intro]
    rest = paras[1:]
    if rest or sec["bullets"]:
        block.append('<div class="narrative">' + "".join(f"<p>{esc(p)}</p>" for p in rest))
        if sec["title"].lower().startswith("settings to change"):
            block.append(_settings_bullets(esc, sec["bullets"]))
        elif sec["bullets"]:
            block.append("<ul>" + "".join(f"<li>{esc(strip_bullet(b))}</li>" for b in sec["bullets"]) + "</ul>")
        block.append("</div>")
    block.append("</section>")
    return "".join(block)


def _target_badge(esc, group):
    if group["scope"]:
        return f'<span class="badge scope-{esc(group["scope"])}">{esc(group["scope"])}</span>'
    kind = {"shell/prompt": "prompt", "other": "other"}.get(group["target"], "config")
    label = {"prompt": "prompt", "other": "other", "config": "settings"}[kind]
    return f'<span class="badge target-{kind}">{label}</span>'


def _hero_html(esc, harness, title, meta, stats, rid_tag):
    chips = []
    if stats:
        chips.append(f'<span class="chip"><b>{esc(common.fmt_int(stats["sessions"]))}</b> sessions</span>')
        chips.append(f'<span class="chip">{esc((stats["first"] or "?")[:10])} to {esc((stats["last"] or "?")[:10])}</span>')
    chips.append(f'<span class="chip">harness: <b>{esc(harness)}</b></span>')
    if rid_tag:
        chips.append('<span class="chip">tune report</span>')
    chips.append('<span class="chip">generator: agent_insights + LLM</span>')
    return (f'<header class="hero"><p class="eyebrow">{esc(harness)} {"tune" if rid_tag else "insights"}</p>'
            f'<h1>{esc(title)}</h1><p class="subtitle">{esc(meta)}</p><div class="chips">{"".join(chips)}</div></header>')


def render_html(harness, report, meta, stats=None, title=None, rid_tag="") -> str:
    esc = html.escape
    wired = wiring.wiring_status(harness, os.path.expanduser("~"))
    title = title or f"{harness} usage insights"
    rid = report_id(harness, stats) if stats else f"{harness}-{rid_tag}{datetime.now().strftime('%Y-%m-%d')}"
    toc, parts = [], []
    if report["glance"]:
        toc.append(("glance", "At a Glance"))
    toc.append(("wiring", "Wiring"))
    if stats:
        toc.append(("stats", "Stats"))
        toc.append(("charts", "Activity"))
        tiles = []
        for i, (v, l) in enumerate(stat_row(stats)):
            accent, icon = STAT_ICONS[i % len(STAT_ICONS)]
            tiles.append(f'<div class="stat lift a-{accent}"><div class="stat-icon"><svg viewBox="0 0 24 24" aria-hidden="true">'
                         f'{icon}</svg></div><div class="stat-value">{esc(v)}</div><div class="stat-label">{esc(l)}</div></div>')
        parts.append('<div class="stats-row" id="stats">' + "".join(tiles) + "</div>")
        parts.append('<div class="charts-row" id="charts">' + "".join(
            _bar_chart(esc, t, items, i) for i, (t, items) in enumerate(chart_data(stats))) + "</div>")
    for sec in report["sections"]:
        sid = "sec-" + slug(sec["title"])
        toc.append((sid, sec["title"]))
        parts.append(_section_html(esc, sec, sid))
    if report["suggestions"]:
        toc.append(("suggestions", "Suggestions"))
        groups, n = [], 0
        for group in grouped_suggestions(harness, report["suggestions"]):
            name, where = group["name"], group["where"]
            cards = []
            for s in group["items"]:
                n += 1
                cards.append(_suggestion_html(esc, rid, n, s, wired))
            groups.append(f'<div class="target-group" data-target="{esc(name)}" data-where="{esc(where)}" '
                          f'data-scope="{esc(group["scope"])}">'
                          f'<div class="group-head"><h3>{esc(name)}</h3>{_target_badge(esc, group)}</div>'
                          f'<div class="target-path">{esc(where)}</div>{"".join(cards)}</div>')
        parts.append('<section class="report a-teal" id="suggestions"><h2>Suggestions, grouped by where they go</h2>'
                     '<p class="section-intro">Tick the ones you applied (remembered in this browser) or want to '
                     'copy together. Check each against the tool&#39;s docs before pasting.</p>'
                     + "".join(groups) + "</section>"
                     '<div class="copy-all-bar" id="copy-bar"><span class="count" id="checked-count" aria-live="polite">'
                     '0 checked</span><button type="button" class="copy-btn" id="copy-all-checked">'
                     'Copy all checked</button></div>')
    if report["horizon"]:
        toc.append(("horizon", "On the Horizon"))
        cards = []
        for i, h in enumerate(report["horizon"], 1):
            card = [f'<div class="horizon-card lift"><div class="horizon-title">{esc(h["title"])}</div>'
                    f'<div class="horizon-possible">{esc(h["what"])}</div>']
            if h["prompt"]:
                card.append('<div class="prompt-label">Starter prompt</div>' + _code_row(esc, f"hz-{i}", h["prompt"], "prompt"))
            card.append("</div>")
            cards.append("".join(card))
        parts.append('<section class="report a-amber" id="horizon"><h2>On the Horizon</h2>'
                     '<p class="section-intro">Ambitious ideas worth a starter prompt.</p>' + "".join(cards) +
                     "</section>")
    ids = {i for i, _ in toc}
    nav = "".join(f'<a href="#{esc(i)}">{esc(t)}</a>' for i, t in toc)
    now = datetime.now().strftime("%Y-%m-%d %H:%M")
    return (f'<!doctype html>\n<html lang="en"><head><meta charset="utf-8">\n'
            f'<meta name="viewport" content="width=device-width, initial-scale=1">\n'
            f'<title>{esc(title)}</title>\n<style>{HTML_CSS}</style></head>\n'
            f'<body data-report-id="{esc(rid)}"><div class="wrap">\n'
            f'{_hero_html(esc, harness, title, meta, stats, rid_tag)}\n<nav class="toc" aria-label="Sections">{nav}</nav>\n'
            f'{_glance_html(esc, report, ids)}\n{_wiring_html(esc, wired)}\n' + "\n".join(parts) +
            f'\n<footer><p>Generated {esc(now)} from local session digests; nothing leaves this page.</p>'
            f'<p>Charts are computed locally from session logs; narrative and suggestions come from an '
            f'LLM and may be wrong. Report id {esc(rid)}.</p></footer>\n</div>\n<script>{HTML_JS}</script>\n'
            f'</body></html>\n')



def render(fmt, harness, report, meta, stats=None, title=None, rid_tag="") -> str:
    if fmt == "html":
        return render_html(harness, report, meta, stats, title, rid_tag)
    return render_markdown(harness, report, meta, title)


def meta_line(sessions) -> str:
    s = common.summarize(sessions)
    return (f"{s['sessions']} sessions, {(s['first'] or '?')[:10]} to {(s['last'] or '?')[:10]}, "
            "generated by an LLM from session digests; verify specifics")
