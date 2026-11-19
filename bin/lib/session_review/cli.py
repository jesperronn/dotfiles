"""session_review command line: shortlist | show | overview, over any harness adapter."""
import argparse
import json
import os
import subprocess
import sys

from . import adapters, metrics, overview, render

BENCH_MARKERS = ("local-model-evaluator-bench", "local-model-editor-claud", "/private/tmp", "/private/var/folders")
HEADER = ["id", "date", "project", "client", "usr", "turns", "dur", "tokens", "err/calls", "lines",
          "bad", "good", "outl", "labels", "first prompt"]


def open_file(path):
    subprocess.run(["open" if sys.platform == "darwin" else "xdg-open", path], check=False)


def pick_adapter(harness, root=None, explicit_root=False):
    if harness:
        return adapters.get(harness)
    if explicit_root:
        mod = adapters.detect_folder(root) or adapters.detect(root)
        if mod:
            return mod
        raise SystemExit(f"session_review: cannot tell which harness {root} belongs to; pass --harness")
    return adapters.get("copilot")


def row(m):
    return [m["id"][:8], m["started"][:10], metrics.project_name(m["project"]), m["client"][-8:],
            str(m["user_turns"]), str(m["turns"]), f"{m['duration_min']:.0f}m", metrics.fmt_tok(m["tokens_total"]),
            f"{m['tool_errors']}/{m['tool_calls']}", f"+{m['lines_added']}/-{m['lines_removed']}",
            f"{m['bad']:g}", f"{m['good']:g}", f"{m['outlier']:g}", ", ".join(label["text"] for label in m["labels"]),
            m["first_prompt"]]


def render_table(rows):
    caps = {"labels": 120, "first prompt": 70}
    widths = [min(max(len(r[i]) for r in [HEADER] + rows), caps.get(HEADER[i], 40)) for i in range(len(HEADER))]
    return "\n".join("  ".join(c[:widths[i]].ljust(widths[i]) for i, c in enumerate(r)).rstrip() for r in [HEADER] + rows)


# ---------------------------------------------------------------- shortlist

def cmd_shortlist(args):
    root = os.path.expanduser(args.root or "")
    adapter = pick_adapter(args.harness, root, bool(args.root))
    root = os.path.expanduser(args.root or adapter.DEFAULT_ROOT)
    if not os.path.isdir(root):
        print(f"session_review: no such directory: {root}", file=sys.stderr)
        return 1
    excludes = [] if args.include_bench else list(BENCH_MARKERS) + args.exclude
    project_filter = os.path.expanduser(args.project) if args.project else None
    ms = []
    for sid, path in adapter.discover(root):
        meta = adapter.peek(path)
        if any(x in meta["project"] for x in excludes):
            continue
        if project_filter and project_filter not in meta["project"]:
            continue
        if args.since and meta["started"][:10] < args.since:
            continue
        m = metrics.compute(adapter.load(path, sid, full=False))
        if m["turns"] >= args.min_turns:
            ms.append(m)
    if not ms:
        print("session_review: no sessions matched.", file=sys.stderr)
        return 1
    metrics.score(ms)
    buckets = ["bad", "good", "outlier"] if args.bucket == "all" else [args.bucket]
    chosen = {b: sorted(ms, key=lambda m, b=b: m[b if b != "outlier" else "outlier"], reverse=True)[:args.top] for b in buckets}
    if args.format == "json":
        slim = {b: [{k: v for k, v in m.items() if k not in ("user_msgs", "counts")} for m in lst] for b, lst in chosen.items()}
        print(json.dumps(slim, indent=2, default=str))
    else:
        print(f"{len(ms)} sessions analysed (bench excluded: {not args.include_bench})")
        for b, lst in chosen.items():
            print(f"\n== {b.upper()} ==")
            rows = [row(m) for m in lst]
            print(render_table(rows) if args.format == "table" else "\n".join("\t".join(r) for r in [HEADER] + rows))
        if args.recurring:
            rec = metrics.recurring_instructions(ms, args.recurring)
            if rec:
                print(f"\n== RECURRING INSTRUCTIONS (typed in follow-ups across >= {args.recurring} sessions) ==")
                for n, sent in rec:
                    print(f"{n:>4}  {sent}")
    if args.copy:
        dest = os.path.expanduser(args.copy)
        picked = {m["id"]: m for lst in chosen.values() for m in lst}
        for m in picked.values():
            adapter.copy(m["path"], dest)
        print(f"\ncopied {len(picked)} sessions to {dest}", file=sys.stderr)
    return 0


# --------------------------------------------------------------------- show

def resolve(arg, adapter, root):
    """Return (adapter, session_id, path) for an id prefix, a session dir/file, or an events file."""
    p = os.path.expanduser(arg)
    if os.path.exists(p):
        mod = adapter or adapters.detect(p) or adapters.detect(os.path.dirname(os.path.abspath(p)))
        if mod is None:
            raise SystemExit(f"session_review: cannot tell which harness {arg} belongs to; pass --harness")
        path = os.path.dirname(os.path.abspath(p)) if os.path.isfile(p) and os.path.basename(p) == "events.jsonl" else p
        return mod, os.path.basename(path.rstrip("/")).removesuffix(".jsonl"), path
    mod = adapter or adapters.get("copilot")
    hits = [(sid, path) for sid, path in mod.discover(os.path.expanduser(root or mod.DEFAULT_ROOT)) if sid.startswith(arg)]
    if len(hits) != 1:
        raise SystemExit(f"session_review: {'no' if not hits else 'ambiguous'} session matches {arg!r}"
                         + (f": {', '.join(h[0] for h in hits[:5])}" if hits else ""))
    return mod, hits[0][0], hits[0][1]


def cmd_show(args):
    adapter = adapters.get(args.harness) if args.harness else None
    mod, sid, path = resolve(args.session, adapter, args.root)
    session = mod.load(path, sid, full=True)
    if not session["events"]:
        print(f"session_review: no events in {path}", file=sys.stderr)
        return 1
    m = metrics.compute(session)
    metrics.score([m], outliers=False)  # one session alone has no peers, so no relative outlier labels
    page = render.render(session, max(0, args.max_result), not args.no_redact, m)
    out = os.path.expanduser(args.out) if args.out else os.path.expanduser(f"~/.cache/session_review/{sid[:8]}.html")
    os.makedirs(os.path.dirname(os.path.abspath(out)), exist_ok=True)
    with open(out, "w", encoding="utf-8") as fh:
        fh.write(page)
    print(out)
    if args.open:
        open_file(out)
    return 0


# ----------------------------------------------------------------- overview

def cmd_overview(args):
    root = os.path.abspath(os.path.expanduser(args.sessions))
    if not os.path.isdir(root):
        print(f"session_review: no such directory: {root}", file=sys.stderr)
        return 1
    adapter = pick_adapter(args.harness, root, True)
    out = os.path.abspath(os.path.expanduser(args.out)) if args.out else os.path.join(os.path.dirname(root), "overview")
    index = overview.build(adapter, root, out, max(0, args.max_result), args.name, args.title)
    if index is None:
        print(f"session_review: no {adapter.NAME} sessions found in {root}.", file=sys.stderr)
        return 1
    print(index)
    if args.open:
        open_file(index)
    return 0


def main(argv=None):
    p = argparse.ArgumentParser(prog="session_review", description=__doc__)
    sub = p.add_subparsers(dest="cmd", required=True)
    harness_help = f"harness adapter ({', '.join(adapters.names())}); default: detected from --root, else copilot"

    s = sub.add_parser("shortlist", help="rank sessions as bad/good/outlier examples")
    s.add_argument("--harness", help=harness_help)
    s.add_argument("--root", help="session folder (default: the harness's standard location)")
    s.add_argument("--since", help="only sessions started on/after YYYY-MM-DD")
    s.add_argument("--project", help="only sessions whose cwd contains this text (~ is expanded)")
    s.add_argument("--exclude", action="append", default=[], metavar="TEXT", help="also skip sessions whose cwd contains TEXT")
    s.add_argument("--include-bench", action="store_true", help="include benchmark/sandbox sessions (excluded by default)")
    s.add_argument("--bucket", choices=("bad", "good", "outlier", "all"), default="all")
    s.add_argument("--top", type=int, default=12)
    s.add_argument("--min-turns", type=int, default=3, help="skip trivial sessions with fewer assistant turns")
    s.add_argument("--format", choices=("table", "tsv", "json"), default="table")
    s.add_argument("--copy", metavar="DIR", help="copy listed sessions into DIR")
    s.add_argument("--recurring", type=int, default=3, metavar="N", help="list sentences repeated across >= N sessions (0 disables)")
    s.set_defaults(func=cmd_shortlist)

    s = sub.add_parser("show", help="render one session as an HTML transcript")
    s.add_argument("session", help="session id prefix, session dir/file, or events.jsonl path")
    s.add_argument("--harness", help=harness_help)
    s.add_argument("--root", help="session folder to search for an id prefix")
    s.add_argument("--out", help="output file (default ~/.cache/session_review/<id8>.html)")
    s.add_argument("--open", action="store_true")
    s.add_argument("--max-result", type=int, default=1500, help="max chars of each tool argument/result shown")
    s.add_argument("--no-redact", action="store_true", help="keep home paths and secret-looking strings")
    s.set_defaults(func=cmd_show)

    s = sub.add_parser("overview", help="build an overview page of a folder of copied sessions")
    s.add_argument("sessions", help="folder of copied sessions")
    s.add_argument("--harness", help=harness_help)
    s.add_argument("--out", help="output directory (default: <sessions>/../overview)")
    s.add_argument("--name", help="investigation name; keys the browser-stored stars and notes (default: parent folder name)")
    s.add_argument("--title", help="page title")
    s.add_argument("--max-result", type=int, default=1500)
    s.add_argument("--open", action="store_true")
    s.set_defaults(func=cmd_overview)

    args = p.parse_args(argv)
    return args.func(args)
