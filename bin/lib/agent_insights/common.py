"""Shared session schema, filtering and report rendering for agent_insights.

A harness module (omp.py, copilot.py, ...) exposes:
    DEFAULT_ROOT: str            # e.g. "~/.omp/agent/sessions"
    load_sessions(root) -> list[dict]   # one normalized dict per session (see new_session)
Parsers must be tolerant: skip unreadable/corrupt lines, never raise on a bad file.
"""
from __future__ import annotations

import json
import re
from collections import Counter, defaultdict
from datetime import datetime, timezone

TOKEN_KEYS = ("input", "output", "cache_read", "cache_write")
MAX_SESSION_SECONDS = 12 * 3600  # resumed/left-open sessions span days; cap each when totalling time


MAX_ERRORS = 3
ERROR_CHARS = 200
_ERROR_INPUT_CHARS = 2000  # cap work per message before redaction; huge tool outputs are common
_HOME_RE = re.compile(r"/Users/[^/\s'\"]+")
_SECRET_PATTERNS = (
    re.compile(r"(?i)\b(authorization)\b\s*[:=]\s*(?:bearer|basic|token)?\s*[^\s'\",;]+"),
    re.compile(r"(?i)\b(?:bearer|basic)\s+[A-Za-z0-9._~+/=-]{6,}"),
    re.compile(r"\b(?:sk|pk|rk)-[A-Za-z0-9_-]{8,}"),
    re.compile(r"\b(?:gh[pousr]_[A-Za-z0-9]{16,}|github_pat_[A-Za-z0-9_]{16,})"),
    re.compile(r"\b[0-9a-fA-F]{32,}\b"),
)
_BLOB_RE = re.compile(r"[A-Za-z0-9+/=]{32,}")


def _redact_blob(match) -> str:
    text = match.group(0)
    # Long base64-ish run: redact only when it has a digit and a letter, so plain long paths/words survive.
    return "[redacted]" if re.search(r"\d", text) and re.search(r"[A-Za-z]", text) else text


def redact_secrets(text) -> str:
    """Replace secret-looking strings and /Users/<name> in `text`; whitespace and length are left alone."""
    text = _HOME_RE.sub("~", text)
    for pattern in _SECRET_PATTERNS:
        text = pattern.sub(lambda m: "Authorization: [redacted]" if m.group(0).lower().startswith("authorization")
                           else "[redacted]", text)
    return _BLOB_RE.sub(_redact_blob, text)


def clean_error(text) -> str:
    """Collapse whitespace, replace /Users/<name> with ~, redact secret-looking strings, truncate."""
    text = redact_secrets(re.sub(r"\s+", " ", str(text)[:_ERROR_INPUT_CHARS]).strip())
    return text if len(text) <= ERROR_CHARS else text[: ERROR_CHARS - 1] + "…"


def add_error(session: dict, text) -> None:
    """Record one error message on session["errors"] (distinct, at most MAX_ERRORS, redacted)."""
    if len(session["errors"]) >= MAX_ERRORS or not isinstance(text, str) or not text.strip():
        return
    cleaned = clean_error(text)
    if cleaned and cleaned not in session["errors"]:
        session["errors"].append(cleaned)


def new_session(harness: str, session_id: str) -> dict:
    """Return an empty normalized session. Parsers fill what their harness records; leave the rest as-is."""
    return {
        "harness": harness,
        "id": session_id,
        "project": None,        # working directory
        "title": None,
        "first_prompt": None,   # first user message, untruncated
        "started": None,        # ISO-8601 UTC string
        "ended": None,          # ISO-8601 UTC string (last event)
        "models": [],           # model names used, in order of first use
        "user_turns": 0,
        "assistant_turns": 0,
        "tool_calls": {},       # tool name -> count
        "tool_errors": 0,
        "errors": [],           # up to MAX_ERRORS distinct redacted error messages (tool/API failures only)
        "tokens": dict.fromkeys(TOKEN_KEYS, 0),
        "cost": None,           # float USD if the harness records it, else None
        "extra": {},            # harness-specific facts (premium requests, lines changed, ...)
        "source": None,         # path to the primary session file/dir
    }


ROUTING_PREFIXES = ("litellm/", "omlx/", "lm-studio/", "lmstudio/", "lms/", "mtplx/", "ollama/", "openrouter/")
VENDOR_DASH_PREFIXES = ("ornith-ai-",)


def normalize_model(name) -> str:
    """Collapse spelling/routing variants of one model name (report time only; raw names stay raw).

    Lowercase, strip routing prefixes repeatedly, drop any remaining `<vendor>/` path prefix (keep the
    last segment), then drop a known `<vendor>-` prefix. Quantization suffixes (4bit vs 6bit) and
    names like gpt-5.4 or gpt-oss:20b are left alone.
    """
    text = str(name).strip().lower()
    stripped = True
    while stripped:
        stripped = False
        for prefix in ROUTING_PREFIXES:
            if text.startswith(prefix) and text[len(prefix):] not in ("", "*"):
                text, stripped = text[len(prefix):], True
    last = text.rsplit("/", 1)[-1]
    if last and last != "*":
        text = last
    for prefix in VENDOR_DASH_PREFIXES:
        if text.startswith(prefix) and len(text) > len(prefix):
            text = text[len(prefix):]
    return text


def parse_ts(value):
    """Parse ISO-8601 strings or epoch seconds/millis into aware UTC datetime; None on failure."""
    if value is None or value == "":
        return None
    try:
        if isinstance(value, (int, float)):
            seconds = value / 1000 if value > 1e11 else value
            return datetime.fromtimestamp(seconds, tz=timezone.utc)
        text = str(value).replace("Z", "+00:00")
        parsed = datetime.fromisoformat(text)
        return parsed if parsed.tzinfo else parsed.replace(tzinfo=timezone.utc)
    except (ValueError, OverflowError, OSError):
        return None


def duration_seconds(session: dict):
    start, end = parse_ts(session["started"]), parse_ts(session["ended"])
    if start and end and end >= start:
        return (end - start).total_seconds()
    return None


def filter_sessions(sessions, since=None, until=None, project=None):
    """Keep sessions started within [since, until] (YYYY-MM-DD) whose project contains `project`."""
    since_dt = parse_ts(since + "T00:00:00+00:00") if since else None
    until_dt = parse_ts(until + "T23:59:59+00:00") if until else None
    out = []
    for session in sessions:
        started = parse_ts(session["started"])
        if since_dt and (not started or started < since_dt):
            continue
        if until_dt and (not started or started > until_dt):
            continue
        if project and project.lower() not in (session["project"] or "").lower():
            continue
        out.append(session)
    return out


def fmt_int(n) -> str:
    return f"{int(n):,}"


def fmt_tokens(n) -> str:
    n = float(n)
    for unit, size in (("B", 1e9), ("M", 1e6), ("k", 1e3)):
        if n >= size:
            return f"{n / size:.1f}{unit}"
    return str(int(n))


def fmt_duration(seconds) -> str:
    if seconds is None:
        return "-"
    seconds = int(seconds)
    hours, rest = divmod(seconds, 3600)
    minutes, secs = divmod(rest, 60)
    if hours:
        return f"{hours}h{minutes:02d}m"
    if minutes:
        return f"{minutes}m{secs:02d}s"
    return f"{secs}s"


def short_project(path, width=48) -> str:
    text = path or "(unknown)"
    return text if len(text) <= width else "…" + text[-(width - 1):]


def summarize(sessions) -> dict:
    """Aggregate normalized sessions into a plain dict (also the --json payload)."""
    tokens = dict.fromkeys(TOKEN_KEYS, 0)
    tools, models, projects, days = Counter(), Counter(), Counter(), Counter()
    weekdays, hours = Counter(), Counter()
    cost, cost_known = 0.0, False
    durations, user_turns, assistant_turns, tool_errors = [], 0, 0, 0
    extra_totals = defaultdict(float)
    for s in sessions:
        for key in TOKEN_KEYS:
            tokens[key] += s["tokens"].get(key, 0)
        tools.update(s["tool_calls"])
        for model in {normalize_model(m) for m in s["models"]}:
            models[model] += 1
        projects[s["project"] or "(unknown)"] += 1
        started = parse_ts(s["started"])
        if started:
            days[started.date().isoformat()] += 1
            weekdays[started.strftime("%a")] += 1
            hours[started.hour] += 1
        if s["cost"] is not None:
            cost += s["cost"]
            cost_known = True
        d = duration_seconds(s)
        if d is not None:
            durations.append(min(d, MAX_SESSION_SECONDS))
        user_turns += s["user_turns"]
        assistant_turns += s["assistant_turns"]
        tool_errors += s["tool_errors"]
        for key, value in s["extra"].items():
            if isinstance(value, (int, float)) and not isinstance(value, bool):
                extra_totals[key] += value
    return {
        "sessions": len(sessions),
        "user_turns": user_turns,
        "assistant_turns": assistant_turns,
        "tool_calls": sum(tools.values()),
        "tool_errors": tool_errors,
        "tokens": tokens,
        "cost": cost if cost_known else None,
        "total_duration_seconds": sum(durations),
        "median_duration_seconds": sorted(durations)[len(durations) // 2] if durations else None,
        "tools": dict(tools.most_common()),
        "models": dict(models.most_common()),
        "projects": dict(projects.most_common()),
        "days": dict(sorted(days.items())),
        "weekdays": dict(weekdays),
        "hours": {str(h): c for h, c in sorted(hours.items())},
        "extra_totals": dict(extra_totals),
        "first": min((s["started"] for s in sessions if s["started"]), default=None),
        "last": max((s["started"] for s in sessions if s["started"]), default=None),
    }


def _bar(value, peak, width=24) -> str:
    return "▬" * max(1, round(width * value / peak)) if peak and value else ""


def _table(title, counter, limit, out, with_bar=True):
    if not counter:
        return
    out.append("")
    out.append(title)
    items = list(counter.items())[:limit]
    peak = max(v for _, v in items)
    label_w = min(max(len(str(k)) for k, _ in items), 50)
    for key, value in items:
        label = short_project(str(key), 50) if len(str(key)) > 50 else str(key)
        bar = f"  {_bar(value, peak)}" if with_bar else ""
        out.append(f"  {label:<{label_w}}  {fmt_int(value):>7}{bar}")


def render_report(harness: str, sessions, top=10, excluded_subagents=None) -> str:
    if not sessions:
        return f"{harness}: no sessions found."
    s = summarize(sessions)
    t = s["tokens"]
    out = [f"{harness} usage report", "=" * (len(harness) + 13)]
    out.append(f"Sessions: {fmt_int(s['sessions'])}   ({s['first'][:10] if s['first'] else '?'} → {s['last'][:10] if s['last'] else '?'})")
    if excluded_subagents is not None:
        out.append(f"Subagent sessions excluded (--no-subagents): {fmt_int(excluded_subagents)}")
    out.append(f"Turns: {fmt_int(s['user_turns'])} user / {fmt_int(s['assistant_turns'])} assistant   "
               f"Tool calls: {fmt_int(s['tool_calls'])} ({fmt_int(s['tool_errors'])} errors)")
    out.append(f"Time: {fmt_duration(s['total_duration_seconds'])} total (sessions capped at 12h), "
               f"{fmt_duration(s['median_duration_seconds'])} median session")
    out.append(f"Tokens: in {fmt_tokens(t['input'])}  out {fmt_tokens(t['output'])}  "
               f"cache-read {fmt_tokens(t['cache_read'])}  cache-write {fmt_tokens(t['cache_write'])}")
    out.append(f"Cost: {'$%.2f' % s['cost'] if s['cost'] is not None else 'not recorded'}")
    if s["extra_totals"]:
        out.append("Extra: " + "  ".join(f"{k}={fmt_int(v)}" for k, v in sorted(s["extra_totals"].items())))
    _table("Sessions per day (last 14 active days)", dict(list(s["days"].items())[-14:]), 14, out)
    _table("Sessions by weekday", {d: s["weekdays"].get(d, 0) for d in ("Mon", "Tue", "Wed", "Thu", "Fri", "Sat", "Sun")}, 7, out)
    _table("Top projects", s["projects"], top, out)
    _table("Models (sessions using)", s["models"], top, out)
    _table("Tools", s["tools"], top, out)
    longest = sorted(sessions, key=lambda x: duration_seconds(x) or 0, reverse=True)[:top]
    out.append("")
    out.append("Longest sessions")
    for x in longest:
        out.append(f"  {fmt_duration(duration_seconds(x)):>7}  {(x['started'] or '?')[:10]}  "
                   f"{short_project(x['project'], 30):<30}  {(x['title'] or x['first_prompt'] or '')[:50].replace(chr(10), ' ')}")
    return "\n".join(out)


def render_list(sessions, limit=30) -> str:
    rows = sorted(sessions, key=lambda x: x["started"] or "", reverse=True)[:limit]
    out = []
    for x in rows:
        out.append(f"{(x['started'] or '?')[:16]}  {x['id'][:8]}  {fmt_duration(duration_seconds(x)):>7}  "
                   f"{x['user_turns']:>3}t  {short_project(x['project'], 32):<32}  "
                   f"{(x['title'] or x['first_prompt'] or '')[:60].replace(chr(10), ' ')}")
    return "\n".join(out) if out else "no sessions found."


def render_json(harness, sessions, with_sessions=False) -> str:
    payload = {"harness": harness, "summary": summarize(sessions)}
    if with_sessions:
        payload["sessions"] = sessions
    return json.dumps(payload, indent=2, sort_keys=True, default=str)
