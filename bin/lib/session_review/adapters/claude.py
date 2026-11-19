"""Claude Code sessions: ~/.claude/projects/<mangled-project-dir>/<session-uuid>.jsonl (one JSON object per line)."""
import json
import os
import shutil

from .. import model

NAME = "claude"
DEFAULT_ROOT = "~/.claude/projects"

EXTRA_LABELS = {}

_DETECT_TYPES = {"user", "assistant", "summary", "system"}
_SKIP_PREFIXES = ("<command-name>", "<local-command", "<system-reminder>")
_INTERRUPTS = ("[Request interrupted by user]", "[Request interrupted by user for tool use]")
_SUBAGENT_TOOLS = {"Task", "Agent"}
_IGNORE_TOOLS = ["TodoWrite", "TaskCreate", "TaskUpdate", "TaskList", "ExitPlanMode", "Skill"]


def _has_type(line, name):
    """Cheap prefilter: real logs are compact JSON, but tolerate a space after the colon."""
    return f'"type":"{name}"' in line or f'"type": "{name}"' in line


def _parse(line):
    try:
        d = json.loads(line)
    except ValueError:
        return None
    return d if isinstance(d, dict) else None


def detect(path):
    p = os.path.expanduser(path)
    if not os.path.isfile(p) or not p.endswith(".jsonl") or os.path.basename(p) == "events.jsonl":
        return False
    try:
        with open(p, encoding="utf-8", errors="replace") as fh:
            for i, line in enumerate(fh):
                if i >= 10:
                    break
                d = _parse(line)
                if d is not None and d.get("type") in _DETECT_TYPES:
                    return True
    except OSError:
        pass
    return False


def discover(root):
    root = os.path.expanduser(root)
    found = []
    if os.path.isfile(root):
        return [(os.path.splitext(os.path.basename(root))[0], root)]
    for dirpath, dirnames, filenames in os.walk(root):
        dirnames[:] = [d for d in dirnames if d != "subagents"]
        for name in filenames:
            if name.endswith(".jsonl") and name != "events.jsonl":
                found.append((name[:-len(".jsonl")], os.path.join(dirpath, name)))
    return sorted(found)


def peek(path):
    project = started = ""
    try:
        with open(path, encoding="utf-8", errors="replace") as fh:
            for i, line in enumerate(fh):
                if i >= 100 or (project and started):
                    break
                d = _parse(line)
                if d is None:
                    continue
                project = project or (d.get("cwd") if isinstance(d.get("cwd"), str) else "")
                started = started or (d.get("timestamp") if isinstance(d.get("timestamp"), str) else "")
    except OSError:
        pass
    return {"project": project, "client": "claude-code", "started": started}


def copy(path, dest):
    os.makedirs(dest, exist_ok=True)
    shutil.copy2(path, os.path.join(dest, os.path.splitext(os.path.basename(path))[0] + ".jsonl"))


def _num(v):
    return v if isinstance(v, (int, float)) and not isinstance(v, bool) else 0


def _lines(text):
    return len(text.splitlines()) if isinstance(text, str) else 0


def _text_of(content):
    """Human text of a user message: a string, or the joined text blocks of a list."""
    if isinstance(content, str):
        return content
    if isinstance(content, list):
        return "\n".join(b.get("text", "") for b in content
                         if isinstance(b, dict) and b.get("type") == "text" and isinstance(b.get("text"), str))
    return ""


def _result_text(content):
    if isinstance(content, str):
        return content
    if isinstance(content, list):
        return "\n".join(b.get("text", "") for b in content if isinstance(b, dict) and isinstance(b.get("text"), str))
    return ""


def _count_change(inp, name, changes, files):
    """Estimate of code changes from tool inputs (Claude Code logs no diff stats): Write adds the lines of its
    content; Edit/MultiEdit add the lines of new_string and remove the lines of old_string."""
    if not isinstance(inp, dict):
        return
    if name == "Write":
        changes["added"] += _lines(inp.get("content"))
    elif name == "Edit":
        changes["added"] += _lines(inp.get("new_string"))
        changes["removed"] += _lines(inp.get("old_string"))
    elif name == "MultiEdit":
        for e in inp.get("edits") or []:
            if isinstance(e, dict):
                changes["added"] += _lines(e.get("new_string"))
                changes["removed"] += _lines(e.get("old_string"))
    else:
        return
    if isinstance(inp.get("file_path"), str):
        files.add(inp["file_path"])


def load(path, sid, full=True):
    s = model.new_session(NAME, sid, path)
    s["client"] = "claude-code"
    s["ignore_tools"] = list(_IGNORE_TOOLS)
    events, tools, files = s["events"], {}, set()
    msg_usage = {}  # message id -> (input, output, cache); streamed chunks repeat the id, keep the last
    first_ts = last_ts = ""
    boundary_pending = False
    with open(path, encoding="utf-8", errors="replace") as fh:
        for line in fh:
            is_user = _has_type(line, "user")
            is_asst = not is_user and _has_type(line, "assistant")
            is_boundary = not is_user and not is_asst and "compact_boundary" in line
            if not (is_user or is_asst or is_boundary):
                continue
            d = _parse(line)
            if d is None or d.get("isSidechain") is True:
                continue
            etype = d.get("type")
            ts = d.get("timestamp") if isinstance(d.get("timestamp"), str) else ""
            if ts:
                first_ts, last_ts = first_ts or ts, ts
            if not s["project"] and isinstance(d.get("cwd"), str):
                s["project"] = d["cwd"]
            if etype == "system":
                if d.get("subtype") == "compact_boundary":
                    events.append({"t": "marker", "kind": "compaction", "text": "context compacted", "ts": ts})
                    boundary_pending = True
                continue
            msg = d.get("message")
            if not isinstance(msg, dict):
                continue
            content = msg.get("content")
            if etype == "assistant":
                mid = msg.get("id") or d.get("uuid") or f"line{len(msg_usage)}"
                u = msg.get("usage") if isinstance(msg.get("usage"), dict) else {}
                msg_usage[mid] = (_num(u.get("input_tokens")), _num(u.get("output_tokens")),
                                  _num(u.get("cache_read_input_tokens")) + _num(u.get("cache_creation_input_tokens")))
                if msg.get("model") != "<synthetic>":
                    model.add_model(s, msg.get("model"))
                if not isinstance(content, list):
                    continue
                for b in content:
                    if not isinstance(b, dict):
                        continue
                    if b.get("type") == "text":
                        if full and isinstance(b.get("text"), str) and b["text"].strip():
                            events.append({"t": "assistant", "text": b["text"], "model": msg.get("model") or "", "ts": ts})
                    elif b.get("type") == "tool_use":
                        tid, name = b.get("id"), b.get("name") or "?"
                        if tid in tools:
                            continue
                        inp = b.get("input")
                        summary = ""
                        if isinstance(inp, dict):
                            prompt = inp.get("prompt")
                            summary = inp.get("description") or (prompt[:80] if isinstance(prompt, str) else "")
                        item = {"t": "tool", "name": name, "args": inp, "summary": summary or "",
                                "result": None, "ok": True, "ts": ts}
                        tools[tid] = item
                        events.append(item)
                        if name in _SUBAGENT_TOOLS:
                            model.bump(s, "subagents")
                        elif name == "Skill":
                            model.bump(s, "skills")
                        _count_change(inp, name, s["changes"], files)
                continue
            # user entry
            if d.get("isMeta") is True:
                continue
            if d.get("isCompactSummary") is True:
                if not boundary_pending:
                    events.append({"t": "marker", "kind": "compaction", "text": "context compacted", "ts": ts})
                boundary_pending = False
                continue
            if isinstance(content, list):
                for b in content:
                    if isinstance(b, dict) and b.get("type") == "tool_result":
                        item = tools.get(b.get("tool_use_id"))
                        if item is None:
                            continue
                        item["ok"] = b.get("is_error") is not True
                        if full:
                            item["result"] = _result_text(b.get("content"))
            text = _text_of(content)
            stripped = text.strip()
            if not stripped or stripped.startswith(_SKIP_PREFIXES):
                continue
            if stripped in _INTERRUPTS:
                events.append({"t": "marker", "kind": "abort", "text": "aborted by user", "ts": ts})
            else:
                events.append({"t": "user", "text": text, "ts": ts})
    u = s["usage"]
    for i, o, c in msg_usage.values():
        u["input"] += i
        u["output"] += o
        u["cache"] += c
    s["counts"]["turns"] = len(msg_usage)
    s["changes"]["files"] = len(files)
    s["started"], s["ended"] = first_ts, last_ts or first_ts
    return s


def extra_signals(m, cuts):
    """No Claude-specific labels yet."""
    return []
