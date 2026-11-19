"""GitHub Copilot (CLI and IDE) sessions: ~/.copilot/session-state/<uuid>/{workspace.yaml,events.jsonl}."""
import json
import os
import re
import shutil

from .. import model

NAME = "copilot"
DEFAULT_ROOT = "~/.copilot/session-state"

_TYPE_RE = re.compile(r'^\{"type":"([^"]+)"')
_TS_RE = re.compile(r'"timestamp":"([^"]+)"')
_CALL_ID_RE = re.compile(r'"toolCallId":"([^"]+)"')
_PARSED = {"user.message", "assistant.message", "tool.execution_start", "session.shutdown",
           "session.usage_record", "session.start", "session.model_change", "session.error"}

EXTRA_LABELS = {
    "permission-prompts": {"sentiment": "neg", "help": "Number of permission requests: approval friction."},
    "no-shutdown": {"sentiment": "neg", "help": "Session never ended cleanly (crash or left open); token totals are estimates."},
    "outlier-premium": {"sentiment": "", "help": "Top 5% of this folder for premium requests."},
}


def _workspace(path):
    meta = {}
    try:
        with open(os.path.join(path, "workspace.yaml"), encoding="utf-8", errors="replace") as fh:
            for line in fh:
                m = re.match(r"^(id|cwd|client_name|created_at):\s*(.*)$", line)
                if m:
                    meta[m.group(1)] = m.group(2).strip()
    except OSError:
        pass
    return meta


def detect(path):
    p = os.path.expanduser(path)
    if os.path.isfile(p):
        return os.path.basename(p) == "events.jsonl" and os.path.isfile(os.path.join(os.path.dirname(p), "workspace.yaml"))
    return os.path.isfile(os.path.join(p, "events.jsonl"))


def discover(root):
    root = os.path.expanduser(root)
    if not os.path.isdir(root):
        return []
    return [(d, os.path.join(root, d)) for d in sorted(os.listdir(root))
            if os.path.isfile(os.path.join(root, d, "events.jsonl"))]


def peek(path):
    meta = _workspace(path)
    return {"project": meta.get("cwd", ""), "client": meta.get("client_name", ""), "started": meta.get("created_at", "")}


def copy(path, dest):
    target = os.path.join(dest, os.path.basename(path.rstrip("/")))
    os.makedirs(target, exist_ok=True)
    for name in ("workspace.yaml", "events.jsonl"):
        src = os.path.join(path, name)
        if os.path.isfile(src):
            shutil.copy2(src, os.path.join(target, name))


def _num(v):
    return v if isinstance(v, (int, float)) and not isinstance(v, bool) else 0


def load(path, sid, full=True):
    s = model.new_session(NAME, sid, path)
    meta = _workspace(path)
    s["project"], s["client"], s["started"] = meta.get("cwd", ""), meta.get("client_name", ""), meta.get("created_at", "")
    s["ignore_tools"] = ["skill", "report_intent"]
    events, tools = s["events"], {}
    usage_rec = {"input": 0, "output": 0}
    shutdowns, first_ts, last_ts = 0, None, None
    with open(os.path.join(path, "events.jsonl"), encoding="utf-8", errors="replace") as fh:
        for line in fh:
            m = _TYPE_RE.match(line)
            if not m:
                continue
            etype = m.group(1)
            ts_m = _TS_RE.search(line, max(0, len(line) - 200))
            ts = ts_m.group(1) if ts_m else ""
            if ts:
                first_ts, last_ts = first_ts or ts, ts
            if etype == "assistant.turn_start":
                model.bump(s, "turns")
            elif etype == "permission.requested":
                model.bump(s, "permission_requests")
            elif etype == "skill.invoked":
                model.bump(s, "skills")
            elif etype == "subagent.started":
                model.bump(s, "subagents")
            elif etype == "assistant.message" and not full:
                events.append({"t": "assistant", "text": "", "model": "", "ts": ts})
            elif etype == "abort":
                events.append({"t": "marker", "kind": "abort", "text": "aborted by user", "ts": ts})
            elif etype == "session.compaction_complete":
                events.append({"t": "marker", "kind": "compaction", "text": "context compacted", "ts": ts})
            elif etype == "tool.execution_complete":
                cid = _CALL_ID_RE.search(line, 0, 300)
                item = tools.get(cid.group(1)) if cid else None
                failed = '"success":false' in line
                if item is None or not (full or failed):
                    continue
                try:
                    d = json.loads(line).get("data") or {}
                except ValueError:
                    continue
                item["ok"] = d.get("success") is not False
                err = d.get("error")
                item["result"] = (err.get("message") if isinstance(err, dict) else err) or (d.get("result") or {}).get("content") or ""
            elif etype in _PARSED:
                try:
                    d = json.loads(line).get("data") or {}
                except ValueError:
                    continue
                if etype == "user.message":
                    if isinstance(d.get("content"), str):
                        events.append({"t": "user", "text": d["content"], "ts": ts})
                elif etype == "assistant.message":
                    if (d.get("content") or "").strip():
                        events.append({"t": "assistant", "text": d["content"], "model": d.get("model", ""), "ts": ts})
                    for req in d.get("toolRequests") or []:  # full mode only (light mode never parses this line)
                        item = {"t": "tool", "name": req.get("name", "?"), "args": req.get("arguments"),
                                "summary": req.get("intentionSummary") or "", "result": None, "ok": True, "ts": ts}
                        tools[req.get("toolCallId")] = item
                        events.append(item)
                elif etype == "tool.execution_start":
                    if d.get("toolCallId") and d["toolCallId"] in tools:  # already created from the assistant message
                        model.add_model(s, d.get("model"))
                        continue
                    item = {"t": "tool", "name": d.get("toolName", "?"), "args": d.get("arguments"), "summary": "",
                            "result": None, "ok": True, "ts": ts}
                    if isinstance(d.get("arguments"), dict):
                        item["summary"] = d["arguments"].get("description") or d["arguments"].get("intent") or ""
                    tools[d.get("toolCallId")] = item
                    events.append(item)
                    model.add_model(s, d.get("model"))
                elif etype == "session.error":
                    events.append({"t": "marker", "kind": "error", "text": "session error: " + str(d.get("message", ""))[:200], "ts": ts})
                elif etype == "session.model_change":
                    model.add_model(s, d.get("newModel"))
                elif etype == "session.usage_record":
                    u = d.get("usage") or {}
                    usage_rec["input"] += _num(u.get("inputTokens"))
                    usage_rec["output"] += _num(u.get("outputTokens"))
                    model.add_model(s, u.get("model"))
                elif etype == "session.start":
                    s["project"] = s["project"] or (d.get("context") or {}).get("cwd", "")
                    s["started"] = s["started"] or d.get("startTime", "")
                elif etype == "session.shutdown":
                    shutdowns += 1
                    events.append({"t": "marker", "kind": "end", "text": f"session ended ({d.get('shutdownType')})", "ts": ts})
                    td = d.get("tokenDetails") or {}
                    tok = lambda k: _num((td.get(k) or {}).get("tokenCount"))  # noqa: E731
                    s["usage"]["output"] += tok("output")
                    s["usage"]["input"] += tok("input")
                    s["usage"]["cache"] += tok("cache_read") + tok("cache_write")
                    model.bump(s, "premium_requests", _num(d.get("totalPremiumRequests")))
                    cc = d.get("codeChanges") or {}
                    s["changes"]["added"] += _num(cc.get("linesAdded"))
                    s["changes"]["removed"] += _num(cc.get("linesRemoved"))
                    files = cc.get("filesModified")
                    s["changes"]["files"] += len(files) if isinstance(files, list) else 0
    if shutdowns == 0:
        s["usage"]["input"], s["usage"]["output"] = usage_rec["input"], usage_rec["output"]
    s["ended_cleanly"] = shutdowns > 0
    s["started"] = s["started"] or first_ts or ""
    s["ended"] = last_ts or s["started"]
    return s


def extra_signals(m, cuts):
    """Copilot-only labels: permission friction, crash without shutdown, premium-request outliers."""
    out = []
    if m["counts"].get("permission_requests", 0) >= 30:
        out.append({"name": "permission-prompts", "text": f"permission-prompts {m['counts']['permission_requests']}", "bad": 3, "out": 0})
    if m["ended_cleanly"] is False:
        out.append({"name": "no-shutdown", "text": "no-shutdown", "bad": 0, "out": 0})
    prem = m["counts"].get("premium_requests", 0)
    if prem and prem >= cuts.get("premium", 0) > 0:
        out.append({"name": "outlier-premium", "text": "outlier-premium", "bad": 0, "out": 3})
    return out
