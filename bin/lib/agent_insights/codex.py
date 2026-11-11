"""OpenAI Codex CLI / Codex Desktop session parser for agent_insights.

On-disk layout under DEFAULT_ROOT:
    YYYY/MM/DD/rollout-<local-ts>-<uuid>.jsonl        plain session log
    YYYY/MM/DD/rollout-<local-ts>-<uuid>.jsonl.zst    zstd-compressed session log (most of the real data)
Forked/subagent rollouts are named rollout-<ts>-<parent-uuid>_<uuid>.jsonl. `~/.codex/archived_sessions`
holds more of the same files but is not part of DEFAULT_ROOT (pass --root to read it).

Compressed files are read with the stdlib `compression.zstd` (Python 3.14+) or, failing that,
by piping through the `zstd` binary. If neither exists, .zst files are skipped.

Every line is {timestamp, ordinal, type, payload}. Record types used:
    session_meta        id, cwd, originator (codex_exec | Codex Desktop | codex-tui | codex_vscode ...),
                        cli_version, source ("cli", "exec", "vscode" or {"subagent": ...}), git.branch,
                        parent_thread_id/forked_from_id for subagents and forks
    turn_context        model, effort, approval_policy, sandbox_policy.type (one per turn)
    response_item       message (role user|assistant|developer), function_call / custom_tool_call (name),
                        function_call_output / custom_tool_call_output, web_search_call, reasoning (ignored)
    event_msg           item_completed {item: UserMessage | AgentMessage | CommandExecution(status,
                        exit_code) | FileChange(status, changes) | McpToolCall(status) ...},
                        token_count (info.total_token_usage, cumulative), task_started, turn_aborted
    token_usage_record  per-response usage with cumulative thread_token_usage
    compacted           context compaction
    session_index.jsonl (sibling of the root dir) maps session id -> thread_name, used as the title.

Older rollouts (2025 style, not present in the current real data but handled) have a bare header
{id, timestamp, instructions, git} and unwrapped records {type: message|function_call|...} plus
event_msg user_message / agent_message / exec_command_end / patch_apply_end / error.

Counting rules:
    tool_calls   function_call + custom_tool_call + local_shell_call names, plus web_search_call
                 as "web_search". The `exec` custom tool is a JS orchestrator whose nested tool calls
                 are not separate response_items, so they are not counted individually.
    tool_errors  item_completed items with status "failed" (CommandExecution, FileChange, McpToolCall,
                 ...), or old exec_command_end exit_code != 0 / patch_apply_end success false. If a
                 session has no such status events, falls back to inspecting tool outputs (exit code
                 lines, metadata.exit_code, "verification failed", "Script failed").
    tokens       the cumulative counters, never summed: last token_count total_token_usage vs last
                 token_usage_record.thread_token_usage, whichever has the larger total. input_tokens
                 includes cached and cache-write tokens (total == input + output), so
                 input = input_tokens - cached - cache_write, cache_read = cached_input_tokens,
                 cache_write = cache_write_input_tokens.
    cost         always None: Codex logs no dollar amounts.
    user_turns   UserMessage items (or old user_message events); falls back to response_item user
                 messages that are not injected context. assistant_turns: assistant messages.
Subagent rollouts (guardian auto-review, spawned agents) are separate sessions with extra["subagent"] = 1.
Forked rollouts replay parent history and so can double count its turns/tokens (extra["forked"] = 1).
"""
from __future__ import annotations

import json
import os
import re
import shutil
import subprocess
from collections import Counter

from . import common

DEFAULT_ROOT = "~/.codex/sessions"

_EXIT_RE = re.compile(r"Process exited with code (-?\d+)")
_EXIT_PREFIX_RE = re.compile(r"^Exit code: (-?\d+)")
_CONTEXT_PREFIXES = ("<environment_context", "<user_instructions", "<permissions", "# AGENTS.md",
                     "<turn_aborted", "<user_shell_command", "<skill", "<subagent")
_NOISE = ('"type":"reasoning"', '"type": "reasoning"', '"additional_tools"', '"world_state"')
_RESPONSE_TYPES = {"message", "function_call", "function_call_output", "custom_tool_call",
                   "custom_tool_call_output", "local_shell_call", "web_search_call", "reasoning"}

try:  # Python 3.14+
    from compression import zstd as _zstd
except ImportError:  # pragma: no cover - depends on interpreter
    _zstd = None


def _find_files(root):
    for dirpath, _dirs, files in os.walk(root):
        for name in files:
            if name.startswith("rollout-") and (name.endswith(".jsonl") or name.endswith(".jsonl.zst")):
                yield os.path.join(dirpath, name)


def _open_lines(path):
    """Yield decoded lines of a plain or zstd file; raises OSError on unreadable input."""
    if not path.endswith(".zst"):
        with open(path, encoding="utf-8", errors="replace") as handle:
            yield from handle
        return
    if _zstd is not None:
        with _zstd.open(path, "rt", encoding="utf-8", errors="replace") as handle:
            yield from handle
        return
    binary = shutil.which("zstd")
    if not binary:
        raise OSError("no zstd support")
    proc = subprocess.Popen([binary, "-dc", "--", path], stdout=subprocess.PIPE,
                            stderr=subprocess.DEVNULL, text=True, encoding="utf-8", errors="replace")
    try:
        yield from proc.stdout
    finally:
        proc.stdout.close()
        proc.wait()


def _num(value):
    return value if isinstance(value, (int, float)) and not isinstance(value, bool) else 0


def _add_model(session, model):
    if isinstance(model, str) and model and model not in session["models"]:
        session["models"].append(model)


def _text_of(content):
    if isinstance(content, str):
        return content
    if isinstance(content, list):
        return "\n".join(b.get("text", "") for b in content
                         if isinstance(b, dict) and isinstance(b.get("text"), str))
    return ""


def _usage(info):
    return info if isinstance(info, dict) and "total_tokens" in info else None


def _output_failed(text):
    """True if a tool output text reports a failure (used only when no status events exist)."""
    if not isinstance(text, str):
        return False
    head = text[:4000]
    match = _EXIT_RE.search(head) or _EXIT_PREFIX_RE.match(head)
    if match:
        return int(match.group(1)) != 0
    if head.startswith("{") and '"exit_code"' in head:
        try:
            meta = json.loads(text).get("metadata")
            if isinstance(meta, dict) and isinstance(meta.get("exit_code"), int):
                return meta["exit_code"] != 0
        except (ValueError, AttributeError):
            pass
    return head.startswith(("apply_patch verification failed", "Script failed", "exec_command failed"))


def _patch_stats(changes):
    """(files, added, removed) for a FileChange changes dict."""
    added = removed = 0
    paths = []
    for path, change in (changes or {}).items():
        if not isinstance(change, dict):
            continue
        paths.append(path)
        kind = change.get("type")
        if kind in ("add", "delete") and isinstance(change.get("content"), str):
            count = change["content"].count("\n") + (0 if change["content"].endswith("\n") or not change["content"] else 1)
            if kind == "add":
                added += count
            else:
                removed += count
        elif isinstance(change.get("unified_diff"), str):
            for line in change["unified_diff"].splitlines():
                if line.startswith("+") and not line.startswith("+++"):
                    added += 1
                elif line.startswith("-") and not line.startswith("---"):
                    removed += 1
    return paths, added, removed


def _load_titles(root):
    titles = {}
    path = os.path.join(os.path.dirname(os.path.normpath(root)), "session_index.jsonl")
    try:
        with open(path, encoding="utf-8", errors="replace") as handle:
            for line in handle:
                try:
                    row = json.loads(line)
                except ValueError:
                    continue
                if isinstance(row, dict) and row.get("id") and row.get("thread_name"):
                    titles[row["id"]] = row["thread_name"]
    except OSError:
        pass
    return titles


def _filename_id(path):
    name = os.path.basename(path).split(".jsonl")[0]
    match = re.search(r"([0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12})$", name)
    return match.group(1) if match else name


def parse_session(path, titles=None):
    """Parse one rollout file into a normalized session dict, or None if it has no events."""
    session = common.new_session("codex", _filename_id(path))
    extra = {"turns": 0, "aborted_turns": 0, "compactions": 0, "web_searches": 0, "agents_spawned": 0,
             "patches": 0, "lines_added": 0, "lines_removed": 0, "api_errors": 0, "corrupt_lines": 0}
    efforts, sandboxes, approvals = Counter(), Counter(), Counter()
    patch_paths = set()
    tc_usage = tur_usage = None
    status_errors = output_errors = 0
    status_seen = False
    compacted_events = compaction_items = 0
    user_events = assistant_msgs = 0
    user_fallback = 0
    first_fallback = None
    first_ts = last_ts = None
    seen = False
    try:
        for line in _open_lines(path):
            line = line.strip()
            if not line or any(n in line[:160] for n in _NOISE):
                continue
            try:
                ev = json.loads(line)
            except ValueError:
                extra["corrupt_lines"] += 1
                continue
            if not isinstance(ev, dict):
                extra["corrupt_lines"] += 1
                continue
            seen = True
            etype = ev.get("type")
            ts = ev.get("timestamp")
            if "payload" in ev and isinstance(ev["payload"], dict):
                payload = ev["payload"]
            else:
                payload = ev  # old unwrapped format
                if etype is None and ("instructions" in ev or "git" in ev) and ev.get("id"):
                    etype = "session_meta"
                elif etype in _RESPONSE_TYPES:
                    etype = "response_item"
            if isinstance(ts, str):
                first_ts = first_ts or ts
                if last_ts is None or ts > last_ts:
                    last_ts = ts
            ptype = payload.get("type")

            if etype == "session_meta":
                session["id"] = payload.get("id") or session["id"]
                session["project"] = payload.get("cwd") or session["project"]
                if isinstance(payload.get("timestamp"), str):
                    session["started"] = payload["timestamp"]
                for key in ("originator", "cli_version", "model_provider"):
                    if isinstance(payload.get(key), str):
                        extra[key] = payload[key]
                git = payload.get("git")
                if isinstance(git, dict) and git.get("branch"):
                    extra["git_branch"] = git["branch"]
                source = payload.get("source")
                if isinstance(source, dict) and "subagent" in source:
                    extra["subagent"] = 1
                    sub = source["subagent"]
                    if isinstance(sub, dict) and sub:
                        extra["subagent_kind"] = ("guardian" if sub.get("other") == "guardian"
                                                  else next(iter(sub)))
                elif payload.get("parent_thread_id"):
                    extra["subagent"] = 1
                    extra["subagent_kind"] = "thread_spawn"
                elif isinstance(source, str):
                    extra["source"] = source
                if payload.get("forked_from_id"):
                    extra["forked"] = 1
            elif etype == "turn_context":
                _add_model(session, payload.get("model"))
                mode = payload.get("collaboration_mode")
                settings = mode.get("settings") if isinstance(mode, dict) else None
                effort = payload.get("effort") or (settings or {}).get("reasoning_effort")
                if effort:
                    efforts[str(effort)] += 1
                policy = payload.get("sandbox_policy")
                kind = policy.get("type") if isinstance(policy, dict) else policy
                if kind:
                    sandboxes[str(kind)] += 1
                if payload.get("approval_policy"):
                    approvals[str(payload["approval_policy"])] += 1
                if not session["project"] and payload.get("cwd"):
                    session["project"] = payload["cwd"]
            elif etype == "compacted":
                compacted_events += 1
            elif etype == "token_usage_record":
                usage = _usage(payload.get("thread_token_usage"))
                if usage and (tur_usage is None or _num(usage["total_tokens"]) >= _num(tur_usage["total_tokens"])):
                    tur_usage = usage
            elif etype == "response_item":
                if ptype == "message":
                    role = payload.get("role")
                    text = _text_of(payload.get("content"))
                    if role == "assistant":
                        assistant_msgs += 1
                    elif role == "user" and text and not text.lstrip().startswith(_CONTEXT_PREFIXES):
                        user_fallback += 1
                        first_fallback = first_fallback or text
                elif ptype in ("function_call", "custom_tool_call", "local_shell_call"):
                    name = str(payload.get("name") or ("local_shell" if ptype == "local_shell_call" else "?"))
                    session["tool_calls"][name] = session["tool_calls"].get(name, 0) + 1
                    if name == "spawn_agent":
                        extra["agents_spawned"] += 1
                elif ptype == "web_search_call":
                    session["tool_calls"]["web_search"] = session["tool_calls"].get("web_search", 0) + 1
                    extra["web_searches"] += 1
                elif ptype in ("function_call_output", "custom_tool_call_output"):
                    output = payload.get("output")
                    if isinstance(output, list):
                        output = _text_of(output)
                    if _output_failed(output):
                        output_errors += 1
                elif ptype == "compaction":
                    compaction_items += 1
            elif etype == "event_msg":
                if ptype == "item_completed":
                    item = payload.get("item")
                    if not isinstance(item, dict):
                        continue
                    itype = item.get("type")
                    if itype == "UserMessage":
                        user_events += 1
                        text = _text_of(item.get("content"))
                        if text and session["first_prompt"] is None:
                            session["first_prompt"] = text
                    elif itype in ("CommandExecution", "FileChange", "McpToolCall", "DynamicToolCall"):
                        status_seen = True
                        if item.get("status") == "failed":
                            status_errors += 1
                        elif itype == "FileChange":
                            paths, added, removed = _patch_stats(item.get("changes"))
                            extra["patches"] += 1
                            extra["lines_added"] += added
                            extra["lines_removed"] += removed
                            patch_paths.update(paths)
                elif ptype == "user_message":  # old format
                    user_events += 1
                    text = payload.get("message")
                    if isinstance(text, str) and text and session["first_prompt"] is None:
                        session["first_prompt"] = text
                elif ptype == "exec_command_end":  # old format
                    status_seen = True
                    if _num(payload.get("exit_code")) != 0:
                        status_errors += 1
                elif ptype == "patch_apply_end":  # old format
                    status_seen = True
                    if payload.get("success") is False:
                        status_errors += 1
                    else:
                        paths, added, removed = _patch_stats(payload.get("changes"))
                        extra["patches"] += 1
                        extra["lines_added"] += added
                        extra["lines_removed"] += removed
                        patch_paths.update(paths)
                elif ptype == "token_count":
                    info = payload.get("info")
                    usage = _usage(info.get("total_token_usage")) if isinstance(info, dict) else None
                    if usage:
                        tc_usage = usage
                elif ptype == "task_started":
                    extra["turns"] += 1
                elif ptype == "turn_aborted":
                    extra["aborted_turns"] += 1
                elif ptype == "error":
                    extra["api_errors"] += 1
                elif ptype == "thread_settings_applied":
                    settings = payload.get("thread_settings")
                    if isinstance(settings, dict):
                        _add_model(session, settings.get("model"))
    except OSError:
        return None
    if not seen:
        return None

    usage = max((u for u in (tc_usage, tur_usage) if u), key=lambda u: _num(u["total_tokens"]), default=None)
    if usage:
        cached, written = _num(usage.get("cached_input_tokens")), _num(usage.get("cache_write_input_tokens"))
        session["tokens"] = {"input": max(0, _num(usage.get("input_tokens")) - cached - written),
                             "output": _num(usage.get("output_tokens")),
                             "cache_read": cached, "cache_write": written}
        extra["reasoning_tokens"] = _num(usage.get("reasoning_output_tokens"))
    session["tool_errors"] = status_errors if status_seen else output_errors
    session["user_turns"] = user_events or user_fallback
    session["assistant_turns"] = assistant_msgs
    session["first_prompt"] = session["first_prompt"] or first_fallback
    session["started"] = session["started"] or first_ts
    session["ended"] = last_ts
    session["source"] = path
    if titles:
        session["title"] = titles.get(session["id"])
    extra["compactions"] = compacted_events or compaction_items
    extra["patch_files"] = len(patch_paths)
    if efforts:
        extra["efforts"] = dict(efforts)
    if sandboxes:
        extra["sandbox_policies"] = dict(sandboxes)
    if approvals:
        extra["approval_policies"] = dict(approvals)
    session["extra"] = {k: v for k, v in extra.items() if v != 0 or k == "turns"}
    return session


def load_sessions(root):
    titles = _load_titles(root)
    sessions = []
    for path in sorted(_find_files(root)):
        parsed = parse_session(path, titles)
        if parsed:
            sessions.append(parsed)
    return sessions
