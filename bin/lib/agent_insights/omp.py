"""omp (oh-my-pi) session parser for agent_insights.

On-disk layout under DEFAULT_ROOT:
    <encoded-cwd>/<timestamp>_<id>.jsonl            top-level session
    <encoded-cwd>/<timestamp>_<id>/<name>.jsonl     subagent (task tool) sessions of that parent
    plus .log/.md/.lock.os/.draft-only-session/.json/.webp artifacts, which are ignored.

Each *.jsonl is one session; every line is a JSON object with a `type`:
    session (id, timestamp, cwd, title, parentSession), title, title_change, model_change (model),
    thinking_level_change, message, compaction, custom/custom_message, model_usage (judge calls),
    session_init (only in subagent sessions: agent, task, resolvedModel).
Message roles: user (attribution user|agent), assistant (usage, model, stopReason, content blocks
incl. toolCall{name}), toolResult (isError), developer, fileMention (files[].path), pythonExecution.
Tool calls are counted from assistant toolCall blocks (the `tool_execution_start` custom records
duplicate them and are ignored). Tool errors are toolResult.isError == true.

Tombstones: `<name>.jsonl.tombstone` files are zero-byte markers beside a subagent jsonl. In the
real data the jsonl always still exists with full content, so a tombstone does NOT mean the data is
gone: such sessions are kept and flagged extra["tombstoned"] = 1.

Subagent sessions are reported as separate sessions (flagged extra["subagent"] = 1); their parent
carries extra["subagent_sessions"] = number of child jsonl files. Parent token usage does not
include children, so nothing is double counted, but session counts include both kinds.

Cost is the sum of usage.cost.total (0.0 for local models); None only when no usage was seen.
Files are streamed line by line; corrupt lines are skipped.
"""
from __future__ import annotations

import os
from collections import Counter

from json import loads as _loads

from . import common

DEFAULT_ROOT = "~/.omp/agent/sessions"


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


def _add_model(session, model):
    if isinstance(model, str) and model and model not in session["models"]:
        session["models"].append(model)


def parse_session(path):
    """Parse one jsonl file into a normalized session dict, or None if it has no events."""
    session = common.new_session("omp", os.path.splitext(os.path.basename(path))[0])
    stops, thinking = Counter(), []
    mentioned = set()
    extra = {"compactions": 0, "model_usage_calls": 0, "corrupt_lines": 0,
             "file_mentions": 0, "branch_summaries": 0, "assistant_errors": 0}
    first_ts = last_ts = None
    seen = False
    fallback_prompt = None
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
                session["title"] = ev.get("title") or session["title"]
                if isinstance(ts, str):
                    session["started"] = ts
                if ev.get("parentSession"):
                    extra["subagent"] = 1
            elif etype in ("title", "title_change"):
                session["title"] = ev.get("title") or session["title"]
            elif etype == "model_change":
                _add_model(session, ev.get("model"))
            elif etype == "thinking_level_change":
                level = ev.get("thinkingLevel") or ev.get("configured")
                if level:
                    thinking.append(level)
            elif etype == "compaction":
                extra["compactions"] += 1
            elif etype == "branch_summary":
                extra["branch_summaries"] += 1
            elif etype == "session_init":
                extra["subagent"] = 1
                if ev.get("agent"):
                    extra["subagent_kind"] = ev["agent"]
                _add_model(session, ev.get("resolvedModel"))
            elif etype == "model_usage":
                if _add_usage(session, ev.get("usage")):
                    extra["model_usage_calls"] += 1
                model, provider = ev.get("model"), ev.get("provider")
                if isinstance(model, str) and isinstance(provider, str) and provider and "/" not in model:
                    model = f"{provider}/{model}"
                _add_model(session, model)
            elif etype == "message":
                msg = ev.get("message")
                if not isinstance(msg, dict):
                    continue
                role = msg.get("role")
                if role == "user":
                    text = _text_of(msg.get("content"))
                    if msg.get("attribution") == "agent":
                        fallback_prompt = fallback_prompt or text
                    else:
                        session["user_turns"] += 1
                        if session["first_prompt"] is None and text:
                            session["first_prompt"] = text
                elif role == "assistant":
                    session["assistant_turns"] += 1
                    _add_usage(session, msg.get("usage"))
                    model, provider = msg.get("model"), msg.get("provider")
                    if isinstance(model, str) and isinstance(provider, str) and provider and "/" not in model:
                        model = f"{provider}/{model}"  # match model_change's "provider/model" naming
                    _add_model(session, model)
                    stop = msg.get("stopReason")
                    if stop:
                        stops[stop] += 1
                    if stop == "error" or msg.get("errorMessage"):
                        extra["assistant_errors"] += 1
                    content = msg.get("content")
                    if isinstance(content, list):
                        for block in content:
                            if isinstance(block, dict) and block.get("type") == "toolCall":
                                name = str(block.get("name") or "?")
                                session["tool_calls"][name] = session["tool_calls"].get(name, 0) + 1
                elif role == "toolResult":
                    if msg.get("isError") is True:
                        session["tool_errors"] += 1
                elif role == "fileMention":
                    for item in msg.get("files") or []:
                        if isinstance(item, dict) and item.get("path"):
                            mentioned.add(item["path"])
                            extra["file_mentions"] += 1
    if not seen:
        return None
    session["started"] = session["started"] or first_ts
    session["ended"] = last_ts
    session["first_prompt"] = session["first_prompt"] or fallback_prompt
    session["source"] = path
    extra["stop_reasons"] = dict(stops)
    if thinking:
        extra["thinking_levels"] = dict(Counter(thinking))
        extra["thinking_level_last"] = thinking[-1]
    if mentioned:
        extra["files_mentioned"] = sorted(mentioned)
    if os.path.exists(path + ".tombstone"):
        extra["tombstoned"] = 1
    if "subagent" not in extra:
        child_dir = path[: -len(".jsonl")]
        try:
            extra["subagent_sessions"] = sum(1 for n in os.listdir(child_dir) if n.endswith(".jsonl"))
        except OSError:
            extra["subagent_sessions"] = 0
    session["extra"] = {k: v for k, v in extra.items() if v != 0 or k in ("compactions", "subagent_sessions")}
    return session


def load_sessions(root):
    sessions = []
    for path in sorted(_find_jsonl(root)):
        parsed = parse_session(path)
        if parsed:
            sessions.append(parsed)
    return sessions
