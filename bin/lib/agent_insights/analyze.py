"""LLM-driven qualitative analysis (the /insights narrative layer) for agent_insights.

Pipeline: normalized sessions -> compact one-line digests (never transcripts) -> map calls
(one JSON summary per batch) -> one reduce call -> six report sections -> Markdown or HTML.
The LLM is any shell command that reads the prompt on stdin and writes the answer on stdout;
the default is `claude -p`.
"""
from __future__ import annotations

import html
import json
import re
import sys
import subprocess

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
    extras = [f"{k}={v:g}" for k, v in sorted(s["extra"].items())
              if isinstance(v, (int, float)) and not isinstance(v, bool) and v][:6]
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


def map_prompt(harness, batch, index, total) -> str:
    return (
        f"{MAP_MARKER} (batch {index} of {total})\n"
        f"You are analysing usage logs of the coding agent '{harness}'. Below are compact digests of "
        f"{len(batch)} sessions (date, project, stats, a few redacted error messages, truncated first prompt).\n"
        f"{RULES}\n"
        'JSON schema: {"themes":[str],"projects":[{"name":str,"what":str}],"wins":[str],'
        '"friction":[str],"notable_prompts":[str]}\n\n'
        "SESSIONS:\n" + "\n".join(batch) + "\n"
    )


def reduce_prompt(harness, batch_jsons, stats) -> str:
    titles = section_titles(harness)
    return (
        f"{REDUCE_MARKER}\n"
        f"You are writing a usage-insights report on the coding agent '{harness}' for its user. Below are "
        "per-batch JSON summaries of their sessions plus aggregate statistics. Combine them into exactly "
        "these six sections, in this order, using these exact titles:\n"
        + "\n".join(f"{i}. {t}" for i, t in enumerate(titles, 1)) + "\n"
        f"Write 'Existing Features to Try' about features of {harness} and of Claude Code that fit the "
        "observed habits, and 'New Ways to Use It' with concrete workflows suggested by the data.\n"
        f"{RULES}\n"
        'JSON schema: {"sections":[{"title":str,"paragraphs":[str],"bullets":[str]}]}\n\n'
        "AGGREGATE STATS:\n" + json.dumps(stats, indent=1, default=str) + "\n\n"
        "BATCH SUMMARIES:\n" + "\n".join(json.dumps(b, ensure_ascii=False) for b in batch_jsons) + "\n"
    )


def section_titles(harness):
    return ["What You Work On", f"How You Use {harness}", "Impressive Things You Did",
            "Where Things Go Wrong", "Existing Features to Try", "New Ways to Use It"]


def compact_stats(sessions, top):
    s = common.summarize(sessions)
    for key in ("days", "hours", "weekdays"):
        s.pop(key, None)
    for key in ("tools", "models", "projects"):
        s[key] = dict(list(s[key].items())[:top])
    return s


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


def analyze(harness, sessions, cmd, batch_size, top):
    """Run map-reduce; returns the list of sections. Raises AnalyzeError on failure."""
    groups = batches(build_digests(sessions), batch_size)
    summaries = [ask_json(cmd, map_prompt(harness, g, i, len(groups)), f"batch {i}/{len(groups)}")
                 for i, g in enumerate(groups, 1)]
    result = ask_json(cmd, reduce_prompt(harness, summaries, compact_stats(sessions, top)), "reduce")
    sections = result.get("sections")
    if not isinstance(sections, list) or not sections:
        raise AnalyzeError("reduce: JSON had no 'sections' list", json.dumps(result, indent=1))
    return [normalize_section(x) for x in sections if isinstance(x, dict)]


def _strs(value):
    if isinstance(value, str):
        return [value]
    return [v if isinstance(v, str) else json.dumps(v, ensure_ascii=False)
            for v in value] if isinstance(value, list) else []


def normalize_section(x):
    return {"title": str(x.get("title") or "Untitled"),
            "paragraphs": _strs(x.get("paragraphs")), "bullets": _strs(x.get("bullets"))}


def dry_run_text(harness, sessions, cmd, batch_size, top) -> str:
    groups = batches(build_digests(sessions), batch_size)
    placeholder = reduce_prompt(harness, ["<JSON summary of each batch, from the map calls>"],
                                {"note": "aggregate common.summarize() stats go here"})
    return (f"=== MAP PROMPT (batch 1 of {len(groups)}; {len(groups)} map call(s) total) ===\n"
            f"{map_prompt(harness, groups[0], 1, len(groups))}\n"
            f"=== REDUCE PROMPT (placeholder; 1 call) ===\n{placeholder}\n"
            f"=== DRY RUN: no LLM call made; would pipe to: {cmd} ===")


def render_markdown(harness, sections, meta) -> str:
    out = [f"# {harness} usage insights", "", f"_{meta}_", ""]
    for sec in sections:
        out += [f"## {sec['title']}", ""]
        for p in sec["paragraphs"]:
            out += [p, ""]
        for b in sec["bullets"]:
            out.append(f"- {b}")
        if sec["bullets"]:
            out.append("")
    return "\n".join(out).rstrip() + "\n"


HTML_TEMPLATE = """<!doctype html>
<html lang="en"><head><meta charset="utf-8">
<meta name="viewport" content="width=device-width, initial-scale=1">
<title>{title}</title>
<style>
:root {{ --bg:#fafafa; --fg:#1d1d1f; --muted:#6b6b70; --card:#fff; --line:#e3e3e8; --accent:#3b5bdb; }}
@media (prefers-color-scheme: dark) {{
  :root {{ --bg:#16161a; --fg:#e8e8ec; --muted:#9a9aa3; --card:#1f1f25; --line:#33333b; --accent:#8da2ff; }}
}}
body {{ margin:0; background:var(--bg); color:var(--fg); font:16px/1.55 system-ui,sans-serif; }}
main {{ max-width:760px; margin:0 auto; padding:2rem 1rem 4rem; }}
h1 {{ font-size:1.6rem; margin-bottom:.2rem; }}
.meta {{ color:var(--muted); margin-top:0; }}
section {{ background:var(--card); border:1px solid var(--line); border-radius:10px; padding:1rem 1.25rem; margin:1.25rem 0; }}
h2 {{ font-size:1.15rem; color:var(--accent); margin-top:0; }}
</style></head><body><main>
<h1>{title}</h1><p class="meta">{meta}</p>
{body}
</main></body></html>
"""


def render_html(harness, sections, meta) -> str:
    esc = html.escape
    parts = []
    for sec in sections:
        block = [f"<section><h2>{esc(sec['title'])}</h2>"]
        block += [f"<p>{esc(p)}</p>" for p in sec["paragraphs"]]
        if sec["bullets"]:
            block.append("<ul>" + "".join(f"<li>{esc(b)}</li>" for b in sec["bullets"]) + "</ul>")
        block.append("</section>")
        parts.append("".join(block))
    return HTML_TEMPLATE.format(title=esc(f"{harness} usage insights"), meta=esc(meta),
                                body="\n".join(parts))


def render(fmt, harness, sections, meta) -> str:
    return (render_html if fmt == "html" else render_markdown)(harness, sections, meta)


def meta_line(sessions) -> str:
    s = common.summarize(sessions)
    return (f"{s['sessions']} sessions, {(s['first'] or '?')[:10]} to {(s['last'] or '?')[:10]}, "
            "generated by an LLM from session digests; verify specifics")
