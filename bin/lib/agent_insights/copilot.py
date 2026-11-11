"""GitHub Copilot CLI sessions (~/.copilot/session-state/<uuid>/) -> normalized sessions.

Per session dir: workspace.yaml (metadata) and events.jsonl (event stream). Premium requests,
nano-AIU, code changes and per-model token usage come from session.shutdown events (one per run;
resumed sessions have several, which are summed). Sessions with no shutdown (crashed/open) fall
back to session.usage_record events for tokens. Copilot records no dollar cost, so cost stays None.
session.db (todos) is deliberately ignored: ephemeral planning state, no usage value.
"""
from __future__ import annotations

import json
import os
import re

from . import common

DEFAULT_ROOT = "~/.copilot/session-state"

_TYPE_RE = re.compile(r'^\{\s*"type"\s*:\s*"([^"]+)"')
_TS_RE = re.compile(r'"timestamp"\s*:\s*"([^"]+)"')
_TOOL_RE = re.compile(r'"toolName"\s*:\s*"([^"]+)"')
_PARSE_TYPES = {
    "session.start", "session.model_change", "session.resume", "user.message",
    "session.shutdown", "session.usage_record",
}


def _parse_workspace(path: str) -> dict:
    """Minimal top-level YAML reader: `key: value` and block scalars (`|`, `|-`, `>`)."""
    meta: dict = {}
    try:
        with open(path, encoding="utf-8", errors="replace") as fh:
            lines = fh.read().splitlines()
    except OSError:
        return meta
    i = 0
    while i < len(lines):
        m = re.match(r"^([A-Za-z_][\w-]*):\s*(.*)$", lines[i])
        i += 1
        if not m:
            continue
        key, val = m.group(1), m.group(2).strip()
        if val[:1] in ("|", ">"):
            block = []
            while i < len(lines) and (not lines[i].strip() or lines[i][:1] in (" ", "\t")):
                block.append(lines[i].strip())
                i += 1
            val = "\n".join(block).strip()
        elif len(val) >= 2 and val[0] == val[-1] and val[0] in "\"'":
            val = val[1:-1]
        meta[key] = val
    return meta


def _num(value) -> float:
    return value if isinstance(value, (int, float)) and not isinstance(value, bool) else 0


def _add_extra(extra: dict, key: str, amount) -> None:
    extra[key] = extra.get(key, 0) + amount


def _add_tokens(tokens: dict, usage: dict) -> None:
    cache_read = _num(usage.get("cacheReadTokens"))
    cache_write = _num(usage.get("cacheWriteTokens"))
    # Copilot's inputTokens includes cached tokens; report the uncached remainder as input.
    tokens["input"] += max(0, _num(usage.get("inputTokens")) - cache_read - cache_write)
    tokens["output"] += _num(usage.get("outputTokens"))
    tokens["cache_read"] += cache_read
    tokens["cache_write"] += cache_write


def _add_model(session: dict, name) -> None:
    if isinstance(name, str) and name and name not in session["models"]:
        session["models"].append(name)


def _title(meta: dict):
    name = (meta.get("name") or "").strip()
    first = next((ln.strip() for ln in name.splitlines() if ln.strip()), "")
    first = first.lstrip("# ").strip()
    return first[:120] or None


def _load_one(path: str, sid: str) -> dict:
    session = common.new_session("copilot", sid)
    session["source"] = path
    meta = _parse_workspace(os.path.join(path, "workspace.yaml"))
    session["project"] = meta.get("cwd") or meta.get("git_root") or None
    session["title"] = _title(meta)
    session["started"] = meta.get("created_at") or None
    extra = session["extra"]
    client = meta.get("client_name") or "unknown"
    extra["client_" + re.sub(r"\W+", "_", client).strip("_")] = 1

    events_path = os.path.join(path, "events.jsonl")
    if not os.path.isfile(events_path):
        extra["no_events"] = 1
        session["ended"] = meta.get("updated_at") or None
        return session

    shutdowns = 0
    usage_tokens = common.new_session("x", "x")["tokens"]
    last_ts = None
    first_ts = None
    try:
        fh = open(events_path, encoding="utf-8", errors="replace")
    except OSError:
        extra["no_events"] = 1
        return session
    with fh:
        for line in fh:
            m = _TYPE_RE.match(line)
            if not m:
                continue
            etype = m.group(1)
            ts = _TS_RE.search(line, max(0, len(line) - 160))
            if ts:
                last_ts = ts.group(1)
                first_ts = first_ts or last_ts
            if etype == "assistant.turn_start":
                session["assistant_turns"] += 1
            elif etype == "tool.execution_start":
                t = _TOOL_RE.search(line)
                if t:
                    calls = session["tool_calls"]
                    calls[t.group(1)] = calls.get(t.group(1), 0) + 1
            elif etype == "tool.execution_complete":
                if '"success":false' in line or '"success": false' in line:
                    session["tool_errors"] += 1
            elif etype == "abort":
                _add_extra(extra, "aborts", 1)
            elif etype == "session.compaction_complete":
                _add_extra(extra, "compactions", 1)
            elif etype in _PARSE_TYPES or etype == "session.error":
                try:
                    data = json.loads(line).get("data") or {}
                except ValueError:
                    continue
                if etype == "session.error":
                    _add_extra(extra, "session_errors", 1)
                elif etype == "session.start":
                    ctx = data.get("context") or {}
                    session["project"] = session["project"] or ctx.get("cwd")
                    session["started"] = session["started"] or data.get("startTime")
                elif etype == "session.model_change":
                    _add_model(session, data.get("newModel"))
                elif etype == "session.resume":
                    _add_model(session, data.get("selectedModel"))
                    _add_extra(extra, "resumes", 1)
                elif etype == "user.message":
                    session["user_turns"] += 1
                    if session["first_prompt"] is None and isinstance(data.get("content"), str):
                        session["first_prompt"] = data["content"]
                elif etype == "session.usage_record":
                    usage = data.get("usage") or {}
                    _add_tokens(usage_tokens, usage)
                    _add_model(session, usage.get("model"))
                elif etype == "session.shutdown":
                    shutdowns += 1
                    _apply_shutdown(session, data)

    if shutdowns == 0:
        extra["no_shutdown"] = 1
        session["tokens"] = usage_tokens
    session["started"] = session["started"] or first_ts
    session["ended"] = last_ts or meta.get("updated_at") or session["started"]
    if session["first_prompt"] and not session["title"]:
        session["title"] = session["first_prompt"].strip().splitlines()[0][:120]
    return session


def _apply_shutdown(session: dict, data: dict) -> None:
    extra = session["extra"]
    kind = re.sub(r"\W+", "_", str(data.get("shutdownType") or "unknown")).strip("_")
    _add_extra(extra, "shutdown_" + kind, 1)
    _add_extra(extra, "premium_requests", _num(data.get("totalPremiumRequests")))
    _add_extra(extra, "nano_aiu", _num(data.get("totalNanoAiu")))
    _add_extra(extra, "api_duration_ms", _num(data.get("totalApiDurationMs")))
    changes = data.get("codeChanges") or {}
    _add_extra(extra, "lines_added", _num(changes.get("linesAdded")))
    _add_extra(extra, "lines_removed", _num(changes.get("linesRemoved")))
    files = changes.get("filesModified")
    _add_extra(extra, "files_modified", len(files) if isinstance(files, list) else _num(changes.get("filesModifiedCount")))
    _add_model(session, data.get("currentModel"))
    metrics = data.get("modelMetrics") or {}
    if isinstance(metrics, dict):
        for model, info in metrics.items():
            _add_model(session, model)
            if isinstance(info, dict) and isinstance(info.get("usage"), dict):
                _add_tokens(session["tokens"], info["usage"])


def load_sessions(root: str) -> list[dict]:
    root = os.path.expanduser(root)
    sessions = []
    try:
        names = sorted(os.listdir(root))
    except OSError:
        return sessions
    for name in names:
        path = os.path.join(root, name)
        if not os.path.isdir(path):
            continue
        try:
            sessions.append(_load_one(path, name))
        except Exception:  # tolerate anything odd in one session; never abort the whole load
            continue
    return sessions
