"""pi coding agent session parser for agent_insights.

On-disk layout under DEFAULT_ROOT:
    <encoded-cwd>/<timestamp>_<id>.jsonl      one session per file (no subagent/child sessions)

Every line is a JSON object with a `type` (session format version 3):
    session (id, timestamp, cwd), model_change (provider, modelId), thinking_level_change
    (thinkingLevel), message, compaction (usage, tokensBefore), context_edit.
Message roles: user, assistant (usage{input,output,cacheRead,cacheWrite,cost.total}, model,
provider, stopReason, errorMessage, content blocks incl. toolCall{name}), toolResult (isError),
system (prompt snapshot, ignored). pi records no title and no parent/child sessions.

Models are named "provider/model" (same as omp). Cost is the sum of usage.cost.total (0.0 for
local models); None only when no usage was seen. Compaction summaries are LLM calls with their own
usage, which is added to the token and cost totals. Files are streamed line by line; corrupt
lines are skipped and counted.
"""
from __future__ import annotations

import os
from collections import Counter
from json import loads as _loads

from . import common

DEFAULT_ROOT = "~/.pi/agent/sessions"


def _find_jsonl(root):
    for dirpath, _dirs, files in os.walk(root):
        for name in files:
            if name.endswith(".jsonl"):
                yield os.path.join(dirpath, name)


def _num(value):
    return value if isinstance(value, (int, float)) and not isinstance(value, bool) else 0


def _text_of(content):
    if isinstance(content, str):
        return content
    if isinstance(content, list):
        return "\n".join(b.get("text", "") for b in content
                         if isinstance(b, dict) and b.get("type") == "text")
    return ""


def _add_usage(session, usage):
    if not isinstance(usage, dict):
        return False
    tokens = session["tokens"]
    tokens["input"] += _num(usage.get("input"))
    tokens["output"] += _num(usage.get("output"))
    tokens["cache_read"] += _num(usage.get("cacheRead"))
    tokens["cache_write"] += _num(usage.get("cacheWrite"))
    cost = usage.get("cost")
    session["cost"] = (session["cost"] or 0.0) + float(_num(cost.get("total") if isinstance(cost, dict) else cost))
    return True


def _add_model(session, provider, model):
    if not isinstance(model, str) or not model:
        return
    if isinstance(provider, str) and provider:
        model = f"{provider}/{model}"
    if model not in session["models"]:
        session["models"].append(model)


def parse_session(path):
    """Parse one jsonl file into a normalized session dict, or None if it has no events."""
    session = common.new_session("pi", os.path.splitext(os.path.basename(path))[0])
    stops, thinking = Counter(), []
    extra = {"compactions": 0, "corrupt_lines": 0, "assistant_errors": 0, "context_edits": 0}
    first_ts = last_ts = None
    seen = False
    try:
        handle = open(path, encoding="utf-8", errors="replace")
    except OSError:
        return None
    with handle:
        for line in handle:
            line = line.strip()
            if not line:
                continue
            try:
                ev = _loads(line)
            except ValueError:
                extra["corrupt_lines"] += 1
                continue
            if not isinstance(ev, dict):
                extra["corrupt_lines"] += 1
                continue
            seen = True
            etype = ev.get("type")
            ts = ev.get("timestamp")
            if isinstance(ts, str):
                first_ts = first_ts or ts
                last_ts = ts
            if etype == "session":
                session["id"] = ev.get("id") or session["id"]
                session["project"] = ev.get("cwd") or session["project"]
                if isinstance(ts, str):
                    session["started"] = ts
            elif etype == "model_change":
                _add_model(session, ev.get("provider"), ev.get("modelId"))
            elif etype == "thinking_level_change":
                if ev.get("thinkingLevel"):
                    thinking.append(ev["thinkingLevel"])
            elif etype == "compaction":
                extra["compactions"] += 1
                _add_usage(session, ev.get("usage"))
                if _num(ev.get("tokensBefore")):
                    extra["compacted_tokens"] = extra.get("compacted_tokens", 0) + ev["tokensBefore"]
            elif etype == "context_edit":
                extra["context_edits"] += 1
            elif etype == "message":
                msg = ev.get("message")
                if not isinstance(msg, dict):
                    continue
                role = msg.get("role")
                if role == "user":
                    session["user_turns"] += 1
                    text = _text_of(msg.get("content"))
                    if session["first_prompt"] is None and text:
                        session["first_prompt"] = text
                elif role == "assistant":
                    session["assistant_turns"] += 1
                    _add_usage(session, msg.get("usage"))
                    _add_model(session, msg.get("provider"), msg.get("model"))
                    stop = msg.get("stopReason")
                    if stop:
                        stops[stop] += 1
                    if stop == "error" or msg.get("errorMessage"):
                        extra["assistant_errors"] += 1
                        common.add_error(session, msg.get("errorMessage"))
                    content = msg.get("content")
                    if isinstance(content, list):
                        for block in content:
                            if isinstance(block, dict) and block.get("type") == "toolCall":
                                name = str(block.get("name") or "?")
                                session["tool_calls"][name] = session["tool_calls"].get(name, 0) + 1
                elif role == "toolResult":
                    if msg.get("isError") is True:
                        session["tool_errors"] += 1
                        common.add_error(session, _text_of(msg.get("content")))
    if not seen:
        return None
    session["started"] = session["started"] or first_ts
    session["ended"] = last_ts
    session["source"] = path
    extra["stop_reasons"] = dict(stops)
    if thinking:
        extra["thinking_levels"] = dict(Counter(thinking))
        extra["thinking_level_last"] = thinking[-1]
    session["extra"] = {k: v for k, v in extra.items() if v != 0 or k == "compactions"}
    return session


def load_sessions(root):
    sessions = []
    for path in sorted(_find_jsonl(root)):
        parsed = parse_session(path)
        if parsed:
            sessions.append(parsed)
    return sessions
