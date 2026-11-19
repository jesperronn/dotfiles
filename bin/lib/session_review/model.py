"""The normalized session model every adapter produces. Everything downstream reads only this.

Session (plain dict, see new_session):
    id, harness, path        identity; `path` is what the adapter needs to reload/copy the session
    project                  working directory the agent ran in ("" if unknown)
    client                   harness front end (e.g. "copilot-intellij", "github/cli"); "" if unknown
    started, ended           ISO-8601 strings ("" if unknown)
    models                   distinct model names seen
    events                   ordered list of Event dicts (below)
    usage                    {"input": n, "output": n, "cache": n} billed tokens; cache reads may be 0 if unknown
    changes                  {"added": n, "removed": n, "files": n} code changes if the harness reports them
    counts                   optional harness counters: turns, permission_requests, subagents, skills, premium_requests
    ended_cleanly            True/False when the harness records a clean end, None when it has no such concept
    ignore_tools             tool names to ignore in loop detection (planning/bookkeeping tools)

Event dicts (ts is an ISO-8601 string or ""):
    {"t": "user",      "text": str, "ts": ts}                      a message the human typed
    {"t": "assistant", "text": str, "model": str, "ts": ts}        assistant prose (omitted in light mode)
    {"t": "tool",      "name": str, "args": any, "summary": str,
                       "result": str|None, "ok": bool, "ts": ts}   one tool call; result None in light mode
    {"t": "marker",    "kind": "abort"|"error"|"compaction"|"end", "text": str, "ts": ts}

Adapter module interface (adapters/<name>.py):
    NAME: str                                    harness id, equals the file name
    DEFAULT_ROOT: str                            where this harness stores sessions
    detect(path) -> bool                         does this file/dir look like one of this harness's sessions?
    discover(root) -> [(session_id, path)]       all sessions under root, sorted
    peek(path) -> {"project","client","started"} cheap metadata without loading events (for filters)
    load(path, sid, full=True) -> Session        full=False (light) skips assistant text and tool results
    copy(path, dest_dir) -> None                 copy one session into dest_dir so discover(dest_dir) finds it
    EXTRA_LABELS: {name: {"sentiment": "neg"|"pos"|"", "help": str}}   optional harness-specific label metadata
    extra_signals(metrics, cuts) -> [Signal]     optional; Signal = {"name","text","bad","out"} (+ label metadata
                                                 comes from EXTRA_LABELS)
"""

CORRECTION_PATTERN = (
    r"\b(no[,.!]|nope|don'?t|do not|stop|wrong|i said|i told you|again|still|instead|not what|you forgot|"
    r"you missed|revert|undo|why did you|that'?s not|nej|ikke|forkert|stadig|igen|jeg sagde|fortryd|hvorfor)\b"
)


def new_session(harness, sid, path):
    return {
        "id": sid, "harness": harness, "path": path, "project": "", "client": "", "started": "", "ended": "",
        "models": [], "events": [], "usage": {"input": 0, "output": 0, "cache": 0},
        "changes": {"added": 0, "removed": 0, "files": 0}, "counts": {}, "ended_cleanly": None, "ignore_tools": [],
    }


def add_model(session, name):
    if isinstance(name, str) and name and name not in session["models"]:
        session["models"].append(name)


def bump(session, key, amount=1):
    session["counts"][key] = session["counts"].get(key, 0) + amount
