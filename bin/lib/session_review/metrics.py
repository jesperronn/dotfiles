"""Generic metrics, scoring and labels computed from normalized sessions (see model.py)."""
import json
import os
import re
from collections import Counter
from datetime import datetime

from . import adapters, model

IDLE_GAP_SECONDS = 600  # IDE sessions stay open for days; count only gaps shorter than this as active time
CORRECTION_RE = re.compile(model.CORRECTION_PATTERN, re.I)
SENTENCE_RE = re.compile(r"[^.!?\n]{15,200}")

# Label metadata for the generic labels; adapters add theirs via EXTRA_LABELS. Sentiment: neg / pos / "" (neutral).
LABELS = {
    "repeated-instruction": ("neg", "You restated an earlier message (60%+ same words): the first instruction was not acted on."),
    "user-corrections": ("neg", "Follow-ups that read as a correction: no, don't, I said, again, stop, nej, igen ..."),
    "tool-loop": ("neg", "The same tool call with identical arguments ran 4+ times."),
    "error-rate": ("neg", "20%+ of tool calls failed."),
    "aborted": ("neg", "You interrupted the agent (count shown)."),
    "abandoned": ("neg", "Ended on your message or an abort, with no code written."),
    "burn-no-edits": ("neg", "Top 5% token use but no lines changed."),
    "session-errors": ("neg", "The harness reported session-level errors."),
    "compacted": ("", "The context window was compacted (count shown): a very long session."),
    "clean-run": ("pos", "Finished with real changes, few prompts and almost no errors."),
    "outlier-tokens": ("", "Top 5% of this folder for tokens."),
    "outlier-duration": ("", "Top 5% of this folder for active minutes."),
    "outlier-turns": ("", "Top 5% of this folder for assistant turns."),
    "outlier-tool-calls": ("", "Top 5% of this folder for tool calls."),
    "subagents": ("", "Spawned 3+ subagents."),
    "big-diff": ("", "2000+ lines added."),
    "starts-handoff": ("", "The first message refers to a handoff (handoff, hand-off, handover): the session continues earlier work."),
    "ends-handoff": ("", "A handoff is written or discussed in the last 12 events: the session ends by passing work on."),
    "ends-plan": ("", "A plan is written or discussed in the last 12 events (or plan mode was exited): the session ends with a plan."),
}
MAX_LABELS = 8
METRIC_TIPS = {
    "date": "Date the session started.",
    "msgs": "Messages you typed in this session. Many messages usually means a lot of steering.",
    "tokens": "Tokens the model read (uncached) plus wrote. Cached re-reads are not counted.",
    "err": "Failed tool calls / all tool calls (file not found, command failed, ...).",
    "bad": "Struggle score: tool errors, loops, corrections, repeated instructions, aborts. Higher = worse.",
    "good": "Smooth-run score: finished with real code changes, few messages, few errors. Higher = better.",
    "out": "Outlier score: unusually many tokens, minutes, turns, tool calls, or a huge diff, compared with this folder.",
}


HANDOFF_RE = re.compile(r"hand[-_ ]?off|handover", re.I)
PLAN_RE = re.compile(r"(?<![a-z])plan(?:s|ning)?(?![a-z])", re.I)  # whole word: "explain" must not match
TAIL_EVENTS = 12


def _tail_blob(events):
    """Text of the last few user messages and tool calls (names, paths, arguments), for structural labels.

    Assistant prose is left out on purpose: light mode does not load it, so labels stay identical in both modes."""
    parts = []
    for e in events[-TAIL_EVENTS:]:
        if e["t"] == "user":
            parts.append(e["text"][:800])
        elif e["t"] == "tool":
            parts.append(e["name"] + " " + json.dumps(e["args"], default=str)[:600])
    return "\n".join(parts)


def words(text):
    return re.findall(r"\w+", text.lower())


def jaccard(a, b):
    return len(a & b) / len(a | b) if a and b else 0.0


def near_duplicates(msgs):
    """Count user messages restating an earlier one in the same session (word-set Jaccard >= 0.6)."""
    sets = [set(words(u)) for u in msgs if len(words(u)) >= 5]
    return sum(1 for i, s in enumerate(sets) if any(jaccard(s, p) >= 0.6 for p in sets[:i]))


def _epoch(ts):
    try:
        return datetime.fromisoformat(ts.replace("Z", "+00:00")).timestamp()
    except (ValueError, AttributeError):
        return None


def fmt_dur(sec):
    sec = int(round(sec))
    if sec < 60:
        return f"{sec}s"
    if sec < 3600:
        return f"{sec // 60}m {sec % 60:02d}s"
    return f"{sec // 3600}h {sec % 3600 // 60:02d}m"


def timings(events):
    """Split a session's clock into agent work, your time, and idle time (gaps over IDLE_GAP_SECONDS).

    Each user message starts a "run" lasting until the next user message. agent = active time inside runs;
    you = short waits between the end of a run and your next message; away = every gap over the idle limit.
    per_prompt[i] = agent seconds for your i-th message."""
    stamped = [(i, _epoch(e.get("ts", ""))) for i, e in enumerate(events)]
    stamped = [(i, t) for i, t in stamped if t is not None]
    t = {"wall": 0.0, "active": 0.0, "agent": 0.0, "you": 0.0, "away": 0.0, "per_prompt": [], "longest": 0.0, "longest_prompt": 0, "median": 0.0}
    if len(stamped) < 2:
        return t
    t["wall"] = stamped[-1][1] - stamped[0][1]
    user_idx = [i for i, e in enumerate(events) if e["t"] == "user"]
    bounds = user_idx + [len(events)]
    for k, start in enumerate(user_idx):
        seg = [(i, ts) for i, ts in stamped if start <= i < bounds[k + 1]]
        work = 0.0
        for (_, a), (_, b) in zip(seg, seg[1:]):
            gap = b - a
            if 0 < gap <= IDLE_GAP_SECONDS:
                work += gap
            elif gap > IDLE_GAP_SECONDS:
                t["away"] += gap
        t["agent"] += work
        t["per_prompt"].append(work)
        if k + 1 < len(user_idx) and seg:
            nxt = next((ts for i, ts in stamped if i >= user_idx[k + 1]), None)
            if nxt is not None and nxt > seg[-1][1]:
                gap = nxt - seg[-1][1]
                t["you" if gap <= IDLE_GAP_SECONDS else "away"] += gap
    t["active"] = t["agent"] + t["you"]
    if t["per_prompt"]:
        runs = sorted(t["per_prompt"])
        t["median"] = runs[len(runs) // 2]
        t["longest"] = runs[-1]
        t["longest_prompt"] = t["per_prompt"].index(t["longest"]) + 1
    return t


def compute(s):
    """One flat metrics dict for a normalized session (everything scoring and the UI need)."""
    ev = s["events"]
    users = [e["text"] for e in ev if e["t"] == "user"]
    tools = [e for e in ev if e["t"] == "tool"]
    markers = Counter(e["kind"] for e in ev if e["t"] == "marker")
    ignore = set(s["ignore_tools"])
    calls = Counter((e["name"], json.dumps(e["args"], sort_keys=True, default=str)[:300]) for e in tools)
    follow = users[1:]  # the first message is usually a pasted plan/spec; do not flag it
    first = users[0].strip().splitlines()[0][:100] if users and users[0].strip() else ""
    last = ev[-1] if ev else None
    tm = timings(ev)
    m = {
        "id": s["id"], "harness": s["harness"], "path": s["path"], "project": s["project"], "client": s["client"],
        "started": s["started"], "first_prompt": first, "user_msgs": users, "user_turns": len(users),
        "turns": s["counts"].get("turns", 0), "tool_calls": len(tools), "tool_errors": sum(1 for e in tools if not e["ok"]),
        "aborts": markers["abort"], "compactions": markers["compaction"], "session_errors": markers["error"],
        "subagents": s["counts"].get("subagents", 0), "counts": s["counts"], "ended_cleanly": s["ended_cleanly"],
        "lines_added": s["changes"]["added"], "lines_removed": s["changes"]["removed"], "files_modified": s["changes"]["files"],
        "tokens_total": s["usage"]["input"] + s["usage"]["output"], "timings": tm, "duration_min": tm["active"] / 60,
        "max_repeat": max(calls.values()) if calls else 0,
        "loops": sum(1 for k, n in calls.items() if n >= 4 and k[0] not in ignore),
        "corrections": sum(1 for u in follow if len(u) < 600 and CORRECTION_RE.search(u)),
        "reprompts": near_duplicates(follow),
        "starts_handoff": bool(users and HANDOFF_RE.search(users[0][:600])),
        "ends_handoff": bool(HANDOFF_RE.search(_tail_blob(ev))),
        "ends_plan": bool(PLAN_RE.search(_tail_blob(ev))),
        "last_kind": None if last is None else (last["kind"] if last["t"] == "marker" else last["t"]),
    }
    return m


def _percentile_cut(values, pct=0.95):
    vals = sorted(values)
    return vals[int(len(vals) * pct)] if vals else 0


def _label(name, text, extra):
    sentiment, help_ = LABELS.get(name) or (extra.get(name, {}).get("sentiment", ""), extra.get(name, {}).get("help", name))
    return {"name": name, "text": text, "sentiment": sentiment, "help": help_}


def fmt_tok(n):
    return f"{n / 1e6:.1f}M" if n >= 1e6 else f"{n / 1e3:.0f}k" if n >= 1e3 else str(int(n))


def score(metrics, outliers=True):
    """Attach bad/good/outlier scores and labels (list of {name,text,sentiment,help}) to each metrics dict, in place.

    outliers=False disables the relative outlier/burn labels (use it when scoring a single session on its own)."""
    cut = {k: _percentile_cut([m[k] for m in metrics]) for k in ("tokens_total", "duration_min", "turns", "tool_calls")}
    cut["premium"] = _percentile_cut([m["counts"].get("premium_requests", 0) for m in metrics])
    if not outliers:
        cut = {k: float("inf") for k in cut}
    for m in metrics:
        adapter = adapters.get(m["harness"])
        extra_meta = getattr(adapter, "EXTRA_LABELS", {})
        signals = adapter.extra_signals(m, cut) if hasattr(adapter, "extra_signals") else []
        err_rate = m["tool_errors"] / m["tool_calls"] if m["tool_calls"] else 0.0
        m["err_rate"] = err_rate
        crashed = m["ended_cleanly"] is False
        abandoned = m["last_kind"] in ("user", "abort") or (m["aborts"] > 0 and m["lines_added"] == 0)
        neg, pos = [], []
        bad = min(m["tool_errors"], 30) * 0.5 + (err_rate * 20 if m["tool_calls"] >= 10 else 0)
        bad += m["loops"] * 4 + min(m["corrections"], 8) * 3 + min(m["reprompts"], 6) * 4
        bad += m["aborts"] * 3 + m["session_errors"] * 3 + (6 if crashed else 0) + (5 if abandoned else 0)
        bad += m["compactions"] * 2 + sum(sig["bad"] for sig in signals)
        if m["tokens_total"] >= cut["tokens_total"] and m["lines_added"] == 0:
            bad += 8
            neg.append(("burn-no-edits", "burn-no-edits"))
        if m["reprompts"]:
            neg.append(("repeated-instruction", f"repeated-instruction x{m['reprompts']}"))
        if m["corrections"]:
            neg.append(("user-corrections", f"user-corrections x{m['corrections']}"))
        if m["loops"]:
            neg.append(("tool-loop", f"tool-loop x{m['loops']} (max {m['max_repeat']})"))
        if err_rate >= 0.2 and m["tool_calls"] >= 10:
            neg.append(("error-rate", f"error-rate {err_rate:.0%}"))
        if m["aborts"]:
            neg.append(("aborted", f"aborted x{m['aborts']}"))
        if abandoned:
            neg.append(("abandoned", "abandoned"))
        if m["compactions"]:
            neg.append(("compacted", f"compacted x{m['compactions']}"))
        if m["session_errors"]:
            neg.append(("session-errors", f"session-errors x{m['session_errors']}"))

        good = 0.0
        if not crashed and not abandoned:
            good += 6
        if m["lines_added"] > 0:
            good += 6
        if m["user_turns"] <= 3:
            good += 4
        if m["tool_calls"] >= 5:
            good += 3
        good += min(m["lines_added"], 300) / 60 + min(m["tool_calls"], 40) / 10  # tie-break: real work done
        if m["lines_added"] < 10 or m["tool_calls"] < 10:
            good -= 6  # trivial one-liners make poor talk examples
        good -= bad * 0.7
        if good > 8 and m["lines_added"] >= 10 and bad < 4:
            pos.append(("clean-run", "clean-run"))

        out, outs = 0.0, []
        for key, tag in (("tokens_total", "outlier-tokens"), ("duration_min", "outlier-duration"),
                         ("turns", "outlier-turns"), ("tool_calls", "outlier-tool-calls")):
            if m[key] >= cut[key] and m[key] > 0:
                out += 3
                outs.append((tag, tag))
        if m["subagents"] >= 3:
            out += 2
            outs.append(("subagents", f"subagents x{m['subagents']}"))
        if m["lines_added"] >= 2000:
            out += 2
            outs.append(("big-diff", f"big-diff +{m['lines_added']}"))
        out += sum(sig["out"] for sig in signals)
        extra_pairs = [(sig["name"], sig["text"]) for sig in signals]
        m["bad"], m["good"], m["outlier"] = round(bad, 1), round(good, 1), round(out, 1)
        scored = [_label(n, t, extra_meta) for n, t in (neg + extra_pairs + pos + outs)][:MAX_LABELS]
        shape = [("starts-handoff", m["starts_handoff"]), ("ends-handoff", m["ends_handoff"]), ("ends-plan", m["ends_plan"])]
        m["labels"] = scored + [_label(n, n, extra_meta) for n, on in shape if on]  # structural labels sit outside the cap
    return metrics


def recurring_instructions(sessions, min_sessions):
    """Sentences typed in follow-up messages across several sessions: candidate unspoken requirements."""
    seen = {}
    for s in sessions:
        for u in s["user_msgs"][1:]:
            if len(u) > 800:
                continue
            for sent in SENTENCE_RE.findall(u):
                key = " ".join(words(sent))
                if len(key.split()) >= 4:
                    seen.setdefault(key, set()).add(s["id"])
    return sorted(((len(v), k) for k, v in seen.items() if len(v) >= min_sessions), reverse=True)[:15]


def project_name(cwd):
    """Short project name from a cwd: last path part, with a worktree suffix (-wt) folded into its repo."""
    name = os.path.basename(cwd.rstrip("/")) or "/"
    return name[:-3] if name.endswith("-wt") and len(name) > 3 else name
