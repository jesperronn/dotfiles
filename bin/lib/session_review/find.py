"""Finding sessions without knowing paths: every harness's default folder is searched.

Used by `list`, by `show` (id prefix, row number, --last, picker) and by the usage errors that suggest `try: ...`."""
import os
import shutil
import subprocess
import sys
from datetime import datetime, timezone

from . import adapters

BENCH_MARKERS = ("local-model-evaluator-bench", "local-model-editor-claud", "/private/tmp", "/private/var/folders")


def dim(text, stream=None):
    stream = stream or sys.stderr
    return f"\033[2m{text}\033[0m" if stream.isatty() and "NO_COLOR" not in os.environ else text


def fail(message, try_line=None):
    """Usage error: stderr, exit 2, optionally ending with a concrete `try:` command."""
    print(f"session_review: error: {message}", file=sys.stderr)
    if try_line:
        print(f"try: {try_line}", file=sys.stderr)
    raise SystemExit(2)


def _started(meta, path):
    if meta["started"]:
        return meta["started"]
    try:
        return datetime.fromtimestamp(os.path.getmtime(path), timezone.utc).isoformat()
    except OSError:
        return ""


def candidates(harness=None, root=None, project=None, since=None, include_bench=False, exclude=()):
    """Sessions from the named harness (default: all with an existing default folder), newest first.

    Each item: {harness, id, path, project, client, started}. `root` limits the search to one folder."""
    found = []
    if root:
        root = os.path.expanduser(root)
        mods = [adapters.get(harness)] if harness else [adapters.detect_folder(root) or adapters.get("copilot")]
        roots = {mods[0].NAME: root}
    else:
        mods = [adapters.get(harness)] if harness else [adapters.get(n) for n in adapters.names()]
        roots = {m.NAME: os.path.expanduser(m.DEFAULT_ROOT) for m in mods}
    skip = [] if include_bench else list(BENCH_MARKERS)
    skip += list(exclude)
    for mod in mods:
        folder = roots[mod.NAME]
        if not os.path.isdir(folder):
            continue
        for sid, path in mod.discover(folder):
            meta = mod.peek(path)
            if any(x in meta["project"] for x in skip):
                continue
            if project and os.path.expanduser(project) not in meta["project"]:
                continue
            started = _started(meta, path)
            if since and started[:10] < since:
                continue
            found.append({"harness": mod.NAME, "id": sid, "path": path, "project": meta["project"],
                          "client": meta["client"], "started": started})
    return sorted(found, key=lambda c: c["started"], reverse=True)


def first_prompt(item):
    session = adapters.get(item["harness"]).load(item["path"], item["id"], full=False)
    for e in session["events"]:
        if e["t"] == "user" and e["text"].strip():
            return " ".join(e["text"].split())
    return ""


def describe(item, number=None):
    """One human-readable row: number, id, date, harness, project, first prompt."""
    from . import metrics

    head = f"{number:>3}  " if number is not None else ""
    return (f"{head}{item['id'][:8]}  {item['started'][:16].replace('T', ' ')}  {item['harness']:<7}  "
            f"{metrics.project_name(item['project']):<22.22}  {first_prompt(item)[:70]}")


def pick_with_fzf(items):
    """Let the user choose with fzf; returns the item or None. Caller checks fzf and the terminal first."""
    lines = [describe(it, i) for i, it in enumerate(items, 1)]
    proc = subprocess.run(["fzf", "--prompt", "session> ", "--no-sort"], input="\n".join(lines), text=True,
                          stdout=subprocess.PIPE)
    if proc.returncode != 0 or not proc.stdout.strip():
        return None
    return items[int(proc.stdout.split()[0]) - 1]


def pick_numbered(items):
    for i, it in enumerate(items, 1):
        print(describe(it, i), file=sys.stderr)
    sys.stderr.write(dim("number (Enter = 1): "))
    sys.stderr.flush()
    answer = sys.stdin.readline().strip() or "1"
    if not answer.isdigit() or not 1 <= int(answer) <= len(items):
        fail(f"no row {answer!r}", "session_review list")
    return items[int(answer) - 1]


def interactive():
    return sys.stdin.isatty() and sys.stderr.isatty()


def choose_recent(harness=None, root=None, limit=15, last=False):
    """The `show` default: a picker on a terminal, else the most recent session."""
    items = candidates(harness, root)[:limit]
    if not items:
        fail("no sessions found" + (f" under {root}" if root else " in the default folders"),
             "session_review list --harness copilot --root <folder>")
    if last or not interactive():
        return items[0]
    if shutil.which("fzf"):
        return pick_with_fzf(items) or fail("nothing picked")
    return pick_numbered(items)


def lookup(arg, harness=None, root=None):
    """Resolve a row number (as printed by `list`) or an id prefix across all harnesses. Returns an item."""
    items = candidates(harness, root)
    if arg.isdigit() and len(arg) <= 3:
        n = int(arg)
        if not 1 <= n <= len(items):
            fail(f"no row {n} (list has {len(items)})", "session_review list")
        return items[n - 1]
    hits = [it for it in items if it["id"].startswith(arg)]
    if len(hits) == 1:
        return hits[0]
    if not hits:
        fail(f"no session id starts with {arg!r}", "session_review list")
    shown = "\n".join(f"  {h['harness']:<7} {h['id']}  {h['project']}" for h in hits[:8])
    fail(f"{arg!r} matches {len(hits)} sessions:\n{shown}", f"session_review show {hits[0]['id'][:12]}")
