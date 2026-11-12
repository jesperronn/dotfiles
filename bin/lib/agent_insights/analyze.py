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

from . import common

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

# Fixed enum the LLM must choose from -> (display name, where the snippet goes).
TARGETS = {
    "AGENTS.md": ("AGENTS.md", "append to ~/.claude/AGENTS.md (global) or the project's AGENTS.md"),
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
CONFIDENCE = ("high", "medium", "low")
GLANCE_LABELS = (("working", "What's working"), ("hindering", "What's hindering you"),
                 ("quick_wins", "Quick wins to try"), ("ambitious", "Ambitious workflows"))

SUGGESTION_RULES = (
    "Suggestions: each is one concrete, copy-paste-ready change. 'target' must be exactly one of: "
    + "; ".join(f"'{t}'" for t in TARGETS) + ". Only recommend settings that really exist for that "
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
        '"lang":str,"confidence":"high|medium|low"}]}'
    )
    return (
        f"{REDUCE_MARKER}\n"
        f"You are writing a usage-insights report on the coding agent '{harness}' for its user. Below are "
        "per-batch JSON summaries of their sessions plus aggregate statistics. Produce:\n"
        "- 'glance': four short labelled points (1-2 sentences each): what is working, what is hindering, "
        "quick wins, ambitious workflows.\n"
        "- 'sections': exactly these six, in this order, using these exact titles:\n"
        + "\n".join(f"  {i}. {t}" for i, t in enumerate(titles, 1)) + "\n"
        f"  Write 'Existing Features to Try' about features of {harness} and of Claude Code that fit the "
        "observed habits, and 'New Ways to Use It' with concrete workflows suggested by the data.\n"
        "- 'horizon': 2-3 ambitious ideas ('On the Horizon'); each has a title, what it is, and a starter "
        "'prompt' the user can paste into the agent to begin.\n"
        "- 'suggestions': paste-ready changes grouped later by target.\n"
        f"{SUGGESTION_RULES}\n"
        "If one model in stats.per_model clearly stands out (error_rate or length_stop_share far above the "
        f"others, with at least 3 sessions), end 'Where Things Go Wrong' with one line: run: agent_insights "
        f"{harness} tune --model <that model>.\n"
        "Local models are often served through omlx, MTPLX, LM Studio or litellm; many fixes belong in "
        "that serving layer or the harness config rather than in AGENTS.md.\n"
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
    target = _str(x.get("target")).strip()
    if target not in TARGETS:
        lowered = {t.lower(): t for t in TARGETS}
        target = lowered.get(target.lower(), "other")
    conf = _str(x.get("confidence")).strip().lower()
    return {"target": target, "title": _str(x.get("title")).strip() or "Untitled suggestion",
            "why": _str(x.get("why")).strip(), "evidence": _str(x.get("evidence")).strip(),
            "snippet": _str(x.get("snippet")).strip("\n"), "lang": _str(x.get("lang")).strip(),
            "confidence": conf if conf in CONFIDENCE else "low"}


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

def grouped_suggestions(suggestions):
    """[(target, [suggestion, ...])] in TARGETS order, empty targets dropped."""
    return [(t, [s for s in suggestions if s["target"] == t]) for t in TARGETS
            if any(s["target"] == t for s in suggestions)]


def render_markdown(harness, report, meta, title=None) -> str:
    out = [f"# {title or f'{harness} usage insights'}", "", f"_{meta}_", ""]
    if report["glance"]:
        out += ["## At a Glance", ""]
        out += [f"- **{label}:** {report['glance'][k]}" for k, label in GLANCE_LABELS if k in report["glance"]]
        out.append("")
    for sec in report["sections"]:
        out += [f"## {sec['title']}", ""]
        for p in sec["paragraphs"]:
            out += [p, ""]
        for b in sec["bullets"]:
            out.append(f"- {b}")
        if sec["bullets"]:
            out.append("")
    if report["suggestions"]:
        out += ["## Suggestions", ""]
        for target, items in grouped_suggestions(report["suggestions"]):
            name, where = TARGETS[target]
            out += [f"### {name} ({where})", ""]
            for s in items:
                out.append(f"- **{s['title']}** [{s['confidence']}] {s['why']}".rstrip())
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


HTML_CSS = """
:root { --bg:#f6f7f9; --fg:#1b1f27; --muted:#667085; --card:#fff; --line:#e4e7ec; --accent:#3b5bdb;
  --accent-soft:#edf1ff; --bar:#5b7cfa; --track:#eef0f4; --good:#2f9e6f; --warn:#c77d0a; --bad:#cf4a4a;
  --code-bg:#f2f4f8; --glance-a:#eef2ff; --glance-b:#f6efff; }
@media (prefers-color-scheme: dark) {
  :root { --bg:#14161b; --fg:#e6e8ee; --muted:#98a0b0; --card:#1d2027; --line:#2e323c; --accent:#8da2ff;
    --accent-soft:#252b45; --bar:#7c93ff; --track:#2a2e38; --good:#52c797; --warn:#e3a53f; --bad:#ec7777;
    --code-bg:#14161b; --glance-a:#232944; --glance-b:#2f2444; }
}
* { box-sizing:border-box; }
body { margin:0; background:var(--bg); color:var(--fg); font:15px/1.6 system-ui,-apple-system,Segoe UI,sans-serif; }
.wrap { max-width:960px; margin:0 auto; padding:2rem 1rem 4rem; }
header h1 { font-size:1.9rem; margin:0 0 .25rem; letter-spacing:-.02em; }
.subtitle { color:var(--muted); margin:0 0 1.25rem; }
nav.toc { display:flex; flex-wrap:wrap; gap:.4rem; margin:0 0 1.5rem; }
nav.toc a { font-size:.8rem; color:var(--accent); background:var(--accent-soft); padding:.25rem .65rem;
  border-radius:999px; text-decoration:none; }
.at-a-glance { background:linear-gradient(135deg,var(--glance-a),var(--glance-b)); border:1px solid var(--line);
  border-radius:14px; padding:1.1rem 1.4rem; margin-bottom:1.5rem; }
.at-a-glance h2 { margin:.1rem 0 .6rem; font-size:1.15rem; }
.glance-section { margin:.5rem 0; }
.glance-section strong { color:var(--accent); }
.stats-row { display:grid; grid-template-columns:repeat(auto-fit,minmax(130px,1fr)); gap:.75rem; margin-bottom:1.5rem; }
.stat { background:var(--card); border:1px solid var(--line); border-radius:12px; padding:.8rem 1rem; }
.stat-value { font-size:1.35rem; font-weight:650; }
.stat-label { font-size:.75rem; color:var(--muted); }
.charts-row { display:grid; grid-template-columns:repeat(auto-fit,minmax(min(100%,420px),1fr)); gap:1rem; margin-bottom:1.5rem; }
.chart-card { background:var(--card); border:1px solid var(--line); border-radius:12px; padding:1rem 1.1rem; min-width:0; }
.chart-title { font-weight:600; font-size:.85rem; margin-bottom:.6rem; }
.bar-row { display:flex; align-items:center; gap:.5rem; margin:.22rem 0; font-size:.78rem; }
.bar-label { flex:0 0 7.5rem; overflow:hidden; text-overflow:ellipsis; white-space:nowrap; color:var(--muted); }
.bar-track { flex:1; background:var(--track); border-radius:4px; height:.7rem; overflow:hidden; }
.bar-fill { background:var(--bar); height:100%; border-radius:4px; }
.bar-value { flex:0 0 2.6rem; text-align:right; font-variant-numeric:tabular-nums; }
.empty { color:var(--muted); font-size:.8rem; }
section.report { margin:2rem 0; }
section.report > h2 { font-size:1.3rem; margin:0 0 .4rem; letter-spacing:-.01em; }
.section-intro { color:var(--muted); margin:0 0 .8rem; }
.narrative { background:var(--card); border:1px solid var(--line); border-radius:12px; padding:.9rem 1.2rem; }
.narrative p { margin:.4rem 0; }
.narrative ul { margin:.4rem 0; padding-left:1.2rem; }
.target-group { margin:1.2rem 0; }
.target-group h3 { margin:0 0 .15rem; font-size:1.02rem; }
.target-path { color:var(--muted); font-size:.78rem; margin-bottom:.5rem; }
.claude-md-item, .horizon-card, .pattern-card { background:var(--card); border:1px solid var(--line);
  border-radius:12px; padding:.8rem 1rem; margin:.6rem 0; }
.cmd-row { display:flex; gap:.6rem; align-items:flex-start; }
.cmd-checkbox { margin-top:.35rem; width:1.05rem; height:1.05rem; }
.cmd-body { flex:1; min-width:0; }
.cmd-title { font-weight:600; }
.cmd-why, .cmd-evidence { color:var(--muted); font-size:.85rem; margin:.25rem 0; }
.cmd-evidence b { color:var(--fg); }
.done .cmd-title { text-decoration:line-through; opacity:.6; }
.badge { font-size:.68rem; text-transform:uppercase; letter-spacing:.04em; padding:.1rem .45rem; border-radius:999px;
  border:1px solid var(--line); margin-left:.4rem; vertical-align:middle; }
.badge.high { color:var(--good); } .badge.medium { color:var(--warn); } .badge.low { color:var(--bad); }
.code-row { display:flex; gap:.5rem; align-items:flex-start; margin-top:.4rem; }
pre.cmd-code { flex:1; margin:0; background:var(--code-bg); border:1px solid var(--line); border-radius:8px;
  padding:.6rem .75rem; overflow-x:auto; font:12.5px/1.5 ui-monospace,SFMono-Regular,Menlo,monospace; white-space:pre-wrap;
  word-break:break-word; min-width:0; }
.copy-btn { cursor:pointer; background:var(--accent-soft); color:var(--accent); border:1px solid var(--line);
  border-radius:8px; padding:.3rem .7rem; font:inherit; font-size:.78rem; white-space:nowrap; }
.copy-btn:hover { border-color:var(--accent); }
.copy-all-bar { display:flex; align-items:center; gap:.75rem; margin:.5rem 0 1rem; }
.copy-all-bar .copy-btn { background:var(--accent); color:var(--card); }
.horizon-title, .pattern-title { font-weight:600; }
.horizon-possible { color:var(--muted); margin:.2rem 0; }
.prompt-label { font-size:.7rem; text-transform:uppercase; color:var(--muted); letter-spacing:.05em; margin-top:.5rem; }
footer { color:var(--muted); font-size:.78rem; margin-top:2.5rem; }
@media (max-width:560px) { .bar-label { flex-basis:5rem; } .code-row { flex-direction:column; } }
"""

HTML_JS = """
(function () {
  var RID = document.body.getAttribute('data-report-id') || 'report';
  var KEY = 'agent_insights:' + RID + ':done';
  function load() { try { return JSON.parse(localStorage.getItem(KEY) || '{}') || {}; } catch (e) { return {}; } }
  function save(state) { try { localStorage.setItem(KEY, JSON.stringify(state)); } catch (e) {} }
  function copyText(text, btn) {
    var label = btn.getAttribute('data-label') || btn.textContent;
    btn.setAttribute('data-label', label);
    function ok() { btn.textContent = 'Copied'; setTimeout(function () { btn.textContent = label; }, 1500); }
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
  var boxes = document.querySelectorAll('.cmd-checkbox');
  Array.prototype.forEach.call(boxes, function (box) {
    var id = box.getAttribute('data-sid');
    box.checked = !!state[id];
    box.closest('.claude-md-item').classList.toggle('done', box.checked);
    box.addEventListener('change', function () {
      state[id] = box.checked ? 1 : 0;
      box.closest('.claude-md-item').classList.toggle('done', box.checked);
      save(state);
    });
  });
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
        Array.prototype.forEach.call(group.querySelectorAll('.claude-md-item'), function (item) {
          var box = item.querySelector('.cmd-checkbox');
          var code = item.querySelector('pre.cmd-code');
          if (box && box.checked && code && code.textContent.trim()) { chunks.push(code.textContent.trim()); }
        });
        if (chunks.length) {
          out.push('# ' + group.getAttribute('data-target') + ' -> ' + group.getAttribute('data-where') +
                   '\\n\\n' + chunks.join('\\n\\n'));
        }
      });
      copyText(out.length ? out.join('\\n\\n\\n') + '\\n' : '(nothing checked)', all);
    });
  }
})();
"""


def _bar_chart(esc, title, items):
    rows = []
    peak = max((v for _, v in items), default=0)
    for label, value in items:
        pct = 100.0 * value / peak if peak else 0
        rows.append(f'<div class="bar-row"><div class="bar-label" title="{esc(str(label))}">{esc(str(label))}'
                    f'</div><div class="bar-track"><div class="bar-fill" style="width:{pct:.1f}%"></div></div>'
                    f'<div class="bar-value">{esc(common.fmt_int(value))}</div></div>')
    body = "".join(rows) or '<div class="empty">no data</div>'
    return f'<div class="chart-card"><div class="chart-title">{esc(title)}</div>{body}</div>'


def _suggestion_html(esc, rid, n, s):
    sid = hashlib.sha1(f"{s['target']}|{s['title']}".encode()).hexdigest()[:10]
    block = [f'<div class="claude-md-item"><div class="cmd-row">'
             f'<input type="checkbox" class="cmd-checkbox" data-sid="{sid}" aria-label="Mark done / include in copy all">'
             f'<div class="cmd-body"><div><span class="cmd-title">{esc(s["title"])}</span>'
             f'<span class="badge {esc(s["confidence"])}">{esc(s["confidence"])}</span></div>']
    if s["why"]:
        block.append(f'<div class="cmd-why">{esc(s["why"])}</div>')
    if s["evidence"]:
        block.append(f'<div class="cmd-evidence"><b>Evidence:</b> {esc(s["evidence"])}</div>')
    if s["snippet"]:
        pid = f"snip-{n}"
        block.append(f'<div class="code-row"><pre class="cmd-code" id="{pid}" data-lang="{esc(s["lang"])}">'
                     f'{esc(s["snippet"])}</pre><button type="button" class="copy-btn" data-copy="{pid}">Copy</button></div>')
    block.append("</div></div></div>")
    return "".join(block)


def _glance_html(esc, report):
    if not report["glance"]:
        return ""
    rows = "".join(f'<div class="glance-section"><strong>{esc(label)}:</strong> {esc(report["glance"][k])}</div>'
                   for k, label in GLANCE_LABELS if k in report["glance"])
    return f'<div class="at-a-glance" id="glance"><h2>At a Glance</h2>{rows}</div>'


def render_html(harness, report, meta, stats=None, title=None, rid_tag="") -> str:
    esc = html.escape
    title = title or f"{harness} usage insights"
    rid = report_id(harness, stats) if stats else f"{harness}-{rid_tag}{datetime.now().strftime('%Y-%m-%d')}"
    toc, parts = [], []
    if stats:
        parts.append('<div class="stats-row" id="stats">' + "".join(
            f'<div class="stat"><div class="stat-value">{esc(v)}</div><div class="stat-label">{esc(l)}</div></div>'
            for v, l in stat_row(stats)) + "</div>")
        parts.append('<div class="charts-row" id="charts">' + "".join(
            _bar_chart(esc, t, items) for t, items in chart_data(stats)) + "</div>")
    for sec in report["sections"]:
        sid = "sec-" + slug(sec["title"])
        toc.append((sid, sec["title"]))
        paras = sec["paragraphs"]
        intro = f'<p class="section-intro">{esc(paras[0])}</p>' if paras else ""
        block = [f'<section class="report" id="{esc(sid)}"><h2>{esc(sec["title"])}</h2>{intro}']
        rest = paras[1:]
        if rest or sec["bullets"]:
            block.append('<div class="narrative">' + "".join(f"<p>{esc(p)}</p>" for p in rest))
            if sec["bullets"]:
                block.append("<ul>" + "".join(f"<li>{esc(b)}</li>" for b in sec["bullets"]) + "</ul>")
            block.append("</div>")
        block.append("</section>")
        parts.append("".join(block))
    if report["suggestions"]:
        toc.append(("suggestions", "Suggestions"))
        groups, n = [], 0
        for target, items in grouped_suggestions(report["suggestions"]):
            name, where = TARGETS[target]
            cards = []
            for s in items:
                n += 1
                cards.append(_suggestion_html(esc, rid, n, s))
            groups.append(f'<div class="target-group" data-target="{esc(name)}" data-where="{esc(where)}">'
                          f'<h3>{esc(name)}</h3><div class="target-path">{esc(where)}</div>{"".join(cards)}</div>')
        parts.append('<section class="report" id="suggestions"><h2>Suggestions, grouped by where they go</h2>'
                     '<p class="section-intro">Tick the ones you applied (remembered in this browser) or want to '
                     'copy together. Check each against the tool&#39;s docs before pasting.</p>'
                     '<div class="copy-all-bar"><button type="button" class="copy-btn" id="copy-all-checked">'
                     'Copy all checked</button></div>' + "".join(groups) + "</section>")
    if report["horizon"]:
        toc.append(("horizon", "On the Horizon"))
        cards = []
        for i, h in enumerate(report["horizon"], 1):
            card = [f'<div class="horizon-card"><div class="horizon-title">{esc(h["title"])}</div>'
                    f'<div class="horizon-possible">{esc(h["what"])}</div>']
            if h["prompt"]:
                card.append(f'<div class="prompt-label">Starter prompt</div><div class="code-row">'
                            f'<pre class="cmd-code" id="hz-{i}">{esc(h["prompt"])}</pre>'
                            f'<button type="button" class="copy-btn" data-copy="hz-{i}">Copy</button></div>')
            card.append("</div>")
            cards.append("".join(card))
        parts.append('<section class="report" id="horizon"><h2>On the Horizon</h2>'
                     '<p class="section-intro">Ambitious ideas worth a starter prompt.</p>' + "".join(cards) +
                     "</section>")
    nav = "".join(f'<a href="#{esc(i)}">{esc(t)}</a>' for i, t in toc)
    return (f'<!doctype html>\n<html lang="en"><head><meta charset="utf-8">\n'
            f'<meta name="viewport" content="width=device-width, initial-scale=1">\n'
            f'<title>{esc(title)}</title>\n<style>{HTML_CSS}</style></head>\n'
            f'<body data-report-id="{esc(rid)}"><div class="wrap">\n'
            f'<header><h1>{esc(title)}</h1><p class="subtitle">{esc(meta)}</p></header>\n'
            f'{_glance_html(esc, report)}\n<nav class="toc">{nav}</nav>\n' + "\n".join(parts) +
            f'\n<footer>Charts are computed locally from session logs; narrative and suggestions come from an '
            f'LLM and may be wrong. Report id {esc(rid)}.</footer>\n</div>\n<script>{HTML_JS}</script>\n'
            f'</body></html>\n')


def render(fmt, harness, report, meta, stats=None, title=None, rid_tag="") -> str:
    if fmt == "html":
        return render_html(harness, report, meta, stats, title, rid_tag)
    return render_markdown(harness, report, meta, title)


def meta_line(sessions) -> str:
    s = common.summarize(sessions)
    return (f"{s['sessions']} sessions, {(s['first'] or '?')[:10]} to {(s['last'] or '?')[:10]}, "
            "generated by an LLM from session digests; verify specifics")
