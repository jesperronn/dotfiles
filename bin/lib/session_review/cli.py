"""session_review command line: list | shortlist | show | overview, over any harness adapter."""
import argparse
import json
import os
import subprocess
import sys

from . import adapters, find, metrics, overview, render

BENCH_MARKERS = find.BENCH_MARKERS
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
        find.fail(f"cannot tell which harness {root} belongs to", "add --harness " + "|".join(adapters.names()))
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
        find.fail(f"no such directory: {root}", "session_review list")
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
        find.fail("no sessions matched", "session_review list  (or loosen --project / --since / --min-turns)")
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
            find.fail(f"cannot tell which harness {arg} belongs to", "add --harness " + "|".join(adapters.names()))
        path = os.path.dirname(os.path.abspath(p)) if os.path.isfile(p) and os.path.basename(p) == "events.jsonl" else p
        return mod, os.path.basename(path.rstrip("/")).removesuffix(".jsonl"), path
    item = find.lookup(arg, adapter.NAME if adapter else None, root)
    print(find.dim(f"session_review: using {item['harness']} session {item['id']}"), file=sys.stderr)
    return adapters.get(item["harness"]), item["id"], item["path"]


def cmd_show(args):
    adapter = adapters.get(args.harness) if args.harness else None
    if args.session:
        mod, sid, path = resolve(args.session, adapter, args.root)
    else:  # no argument: most recent (--last or no terminal), else pick
        item = find.choose_recent(args.harness, args.root, last=args.last)
        print(find.dim(f"session_review: using {item['harness']} session {item['id']}"), file=sys.stderr)
        mod, sid, path = adapters.get(item["harness"]), item["id"], item["path"]
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


# --------------------------------------------------------------------- list

def cmd_list(args):
    items = find.candidates(args.harness, args.root, args.project, args.since, args.include_bench, args.exclude)
    if not items:
        where = args.root or ", ".join(f"{n}: {adapters.get(n).DEFAULT_ROOT}" for n in adapters.names())
        find.fail(f"no sessions found ({where})", "session_review list --include-bench  (or drop --project / --since)")
    shown = items[:args.limit]
    for i, it in enumerate(shown, 1):
        print(find.describe(it, i))
    more = f" ({len(items) - len(shown)} more; raise --limit)" if len(items) > len(shown) else ""
    print(find.dim(f"next: session_review show <#|id>   e.g. session_review show 1{more}"), file=sys.stderr)
    return 0


# ----------------------------------------------------------------- overview

def cmd_overview(args):
    root = os.path.abspath(os.path.expanduser(args.sessions))
    if not os.path.isdir(root):
        find.fail(f"no such directory: {root}", "session_review shortlist --copy <dir> ...  (copies sessions into a folder first)")
    adapter = pick_adapter(args.harness, root, True)
    out = os.path.abspath(os.path.expanduser(args.out)) if args.out else os.path.join(os.path.dirname(root), "overview")
    index = overview.build(adapter, root, out, max(0, args.max_result), args.name, args.title)
    if index is None:
        find.fail(f"no {adapter.NAME} sessions found in {root}", "session_review list --root " + root)
    print(index)
    if args.open:
        open_file(index)
    return 0


SUBCOMMANDS = ("list", "shortlist", "show", "overview")


def main(argv=None):
    argv = list(sys.argv[1:] if argv is None else argv)
    for helper in ("-h", "--help"):  # `session_review --help show` should explain show
        if helper in argv and argv.index(helper) < len(argv) - 1 and argv[argv.index(helper) + 1] in SUBCOMMANDS:
            k = argv.index(helper)
            argv[k], argv[k + 1] = argv[k + 1], argv[k]
    locations = "\n".join(f"  {n:<8} {adapters.get(n).DEFAULT_ROOT}" for n in adapters.names())
    p = argparse.ArgumentParser(prog="session_review", description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter,
                                epilog=f"Where the sessions are (searched automatically, no paths needed):\n{locations}\n\n"
                                       "Start here:\n  session_review list              recent sessions, newest first\n"
                                       "  session_review show              open the latest (or pick, on a terminal)\n"
                                       "  session_review show 3            row 3 of `list`; or an id prefix\n"
                                       "  session_review shortlist --project myrepo --top 10")
    sub = p.add_subparsers(dest="cmd", required=True)
    harness_help = f"harness adapter ({', '.join(adapters.names())}); default: detected from --root, else copilot"

    s = sub.add_parser("list", help="recent sessions from every harness, newest first", formatter_class=argparse.RawDescriptionHelpFormatter,
                       epilog="Examples:\n  session_review list\n  session_review list --harness claude --project dotfiles --since 2026-11-01\n  session_review list --limit 50")
    s.add_argument("--harness", help=harness_help)
    s.add_argument("--root", help="search one folder instead of the harness defaults")
    s.add_argument("--project", help="only sessions whose cwd contains this text (~ is expanded)")
    s.add_argument("--since", help="only sessions started on/after YYYY-MM-DD")
    s.add_argument("--exclude", action="append", default=[], metavar="TEXT", help="also skip sessions whose cwd contains TEXT")
    s.add_argument("--include-bench", action="store_true", help="include benchmark/sandbox sessions")
    s.add_argument("--limit", type=int, default=20, help="rows to print (default 20)")
    s.set_defaults(func=cmd_list)

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

    s = sub.add_parser("show", help="render one session as an HTML transcript", formatter_class=argparse.RawDescriptionHelpFormatter,
                       epilog="Examples:\n  session_review show              latest session (a picker on a terminal)\n"
                              "  session_review show 3 --open     row 3 of `session_review list`\n"
                              "  session_review show 1a2b3c4d     id prefix, any harness")
    s.add_argument("session", nargs="?", help="row number from `list`, id prefix, or a session dir/file path "
                                              "(omit: pick on a terminal, else the latest)")
    s.add_argument("--last", action="store_true", help="open the most recent session without asking")
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
