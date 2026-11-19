"""Build the overview page (index.html + sessions.json/.js) and one transcript per session."""
import json
import os
from datetime import datetime, timezone

from . import metrics, render

HERE = os.path.dirname(os.path.abspath(__file__))
STORAGE_PREFIX = "session_review_v1:"  # keep in sync with KEY in overview.html


def session_row(m, link):
    return {
        "id": m["id"], "id8": m["id"][:8], "harness": m["harness"], "date": m["started"][:10],
        "project": metrics.project_name(m["project"]), "client": m["client"], "userTurns": m["user_turns"],
        "turns": m["turns"], "minutes": round(m["duration_min"]), "tokens": m["tokens_total"],
        "toolCalls": m["tool_calls"], "toolErrors": m["tool_errors"], "added": m["lines_added"],
        "removed": m["lines_removed"], "bad": m["bad"], "good": m["good"], "outlier": m["outlier"],
        "labels": m["labels"], "prompt": render.redact(m["first_prompt"]), "link": link,
    }


def build(adapter, sessions_dir, out, max_result=1500, name=None, title=None):
    """Load every session under sessions_dir with `adapter`, write transcripts and the overview into `out`.

    Returns the path of index.html, or None when no sessions were found."""
    refs = adapter.discover(sessions_dir)
    if not refs:
        return None
    os.makedirs(os.path.join(out, "s"), exist_ok=True)
    ms, parts = [], []
    for sid, path in refs:
        session = adapter.load(path, sid, full=True)
        parts.append(render.render_parts(session, max_result, True))  # strings only; events are dropped, memory stays bounded
        ms.append(metrics.compute(session))
    metrics.score(ms)  # outlier cut-offs are relative to this folder, not your whole history
    name = name or os.path.basename(os.path.dirname(os.path.abspath(sessions_dir))) or "default"
    for m, p in zip(ms, parts):  # second pass: scores exist now, so transcripts show the list's key numbers and marks
        with open(os.path.join(out, "s", f"{m['id'][:8]}.html"), "w", encoding="utf-8") as fh:
            fh.write(render.assemble(p, m, {"key": STORAGE_PREFIX + name, "id": m["id"]}))
    rows = [session_row(m, f"s/{m['id'][:8]}.html") for m in ms]
    data = {"meta": {"name": name, "title": title or f"{name}: session overview",
                     "harnesses": sorted({r["harness"] for r in rows}), "metricTips": metrics.METRIC_TIPS,
                     "generated": datetime.now(timezone.utc).isoformat(timespec="seconds")},
            "sessions": rows}
    text = json.dumps(data, ensure_ascii=False)
    with open(os.path.join(out, "sessions.json"), "w", encoding="utf-8") as fh:
        fh.write(text)
    with open(os.path.join(out, "sessions.js"), "w", encoding="utf-8") as fh:  # file:// pages cannot fetch() JSON
        fh.write("window.OVERVIEW=" + text.replace("</", "<\\/") + ";\n")
    with open(os.path.join(HERE, "overview.html"), encoding="utf-8") as src, \
            open(os.path.join(out, "index.html"), "w", encoding="utf-8") as fh:
        fh.write(src.read())
    return os.path.join(out, "index.html")
