"""`agent_insights <harness> tune`: investigate one harness x model interaction.

Joins per-model waste metrics from the session logs (local, no LLM) with read-only evidence from the local
model servers (servers.py), then asks an LLM for a verdict, quantified waste hotspots and paste-ready
settings/rules. Reuses analyze.py for digests, redaction, config files, LLM plumbing and rendering.
"""
from __future__ import annotations

import json
import os
import re
import sys
import time
from collections import Counter

from . import analyze, common, servers, wiring

MIN_SESSIONS = 3
DIGEST_SESSIONS = 8
TUNE_MARKER = "TASK: TUNE"
TUNE_REDUCE_MARKER = "TASK: TUNE-REDUCE"

# ---- grouping and metrics (local, no LLM) -------------------------------------------------------


def select_groups(sessions, model_substr=None, min_sessions=MIN_SESSIONS):
    """[{model, raw, sessions, shared}] by normalized model, most sessions first.

    A session counts for every model in its list (`shared` counts those that used several). With
    `model_substr` only matching models are returned, with no session minimum.
    """
    groups = {}
    for s in sessions:
        models = {common.normalize_model(m) for m in s["models"]}
        for model in models:
            g = groups.setdefault(model, {"model": model, "raw": set(), "sessions": [], "shared": 0})
            g["sessions"].append(s)
            g["raw"].update(m for m in s["models"] if common.normalize_model(m) == model)
            g["shared"] += len(models) > 1
    if model_substr:
        picked = [g for m, g in groups.items() if model_substr.lower() in m]
    else:
        picked = [g for g in groups.values() if len(g["sessions"]) >= min_sessions]
    return sorted(picked, key=lambda g: (-len(g["sessions"]), g["model"]))


def _ratio(a, b):
    return a / b if b else None


def compute_metrics(group) -> dict:
    ss = group["sessions"]
    n = len(ss)
    users = sum(s["user_turns"] for s in ss)
    asst = sum(s["assistant_turns"] for s in ss)
    calls = sum(sum(s["tool_calls"].values()) for s in ss)
    errors = sum(s["tool_errors"] for s in ss)
    tok = {k: sum(s["tokens"].get(k, 0) for s in ss) for k in common.TOKEN_KEYS}
    stops = analyze.aggregate_stop_reasons(ss)
    stop_total = sum(stops.values())
    asst_err = sum(s["extra"].get("assistant_errors", 0) for s in ss)
    comp = sum(s["extra"].get("compactions", 0) for s in ss)
    long_open = sum(1 for s in ss if (common.duration_seconds(s) or 0) > common.MAX_SESSION_SECONDS)

    def waste(s):
        return (sum(s["tool_calls"].values()), s["tokens"].get("input", 0) + s["tokens"].get("output", 0))
    runaways = [{"date": (s["started"] or "?")[:10], "title": common.clean_error(s["title"] or s["first_prompt"] or "")[:80],
                 "project": s["project"] or "(unknown)", "tool_calls": waste(s)[0], "tokens": waste(s)[1],
                 "user_turns": s["user_turns"], "assistant_turns": s["assistant_turns"]}
                for s in sorted(ss, key=waste, reverse=True)[:3]]
    errs = Counter(e for s in ss for e in s["errors"])
    days = sorted(s["started"][:10] for s in ss if s["started"])
    return {
        "model": group["model"], "raw_names": sorted(group["raw"]), "sessions": n, "shared_sessions": group["shared"],
        "subagent_sessions": sum(1 for s in ss if s["extra"].get("subagent")),
        "first": days[0] if days else None, "last": days[-1] if days else None,
        "user_turns": users, "assistant_turns": asst, "tool_calls": calls, "tool_errors": errors,
        "assistant_per_user_turn": _ratio(asst, users), "tool_calls_per_user_turn": _ratio(calls, users),
        "tool_error_rate": _ratio(errors, calls), "assistant_error_rate": _ratio(asst_err, asst),
        "assistant_errors": asst_err, "stop_reasons": stops,
        "length_stop_share": _ratio(stops.get("length", 0), stop_total) if stop_total else None,
        "error_stop_share": _ratio(stops.get("error", 0), stop_total) if stop_total else None,
        "aborted_stop_share": _ratio(stops.get("aborted", 0), stop_total) if stop_total else None,
        "compactions": comp, "compactions_per_session": comp / n,
        "tokens": tok, "input_tokens_per_user_turn": _ratio(tok["input"], users),
        "output_tokens_per_user_turn": _ratio(tok["output"], users),
        "cache_read_ratio": _ratio(tok["cache_read"], tok["input"] + tok["cache_read"]),
        "sessions_open_over_12h": long_open, "runaways": runaways,
        "top_errors": [{"count": c, "message": m} for m, c in errs.most_common(5)],
    }


def _f(value, digits=1, pct=False):
    if value is None:
        return "-"
    return f"{100 * value:.{digits}f}%" if pct else f"{value:,.{digits}f}"


def metric_rows(m):
    """[(label, value)] shared by the terminal table and the report's measured section."""
    stops = ", ".join(f"{k}:{v:g}" for k, v in list(m["stop_reasons"].items())[:5]) or "none recorded"
    t = m["tokens"]
    return [
        ("sessions", f"{m['sessions']} ({m['shared_sessions']} shared with other models, "
                     f"{m['subagent_sessions']} subagent)"),
        ("user turns", f"{m['user_turns']:,}"),
        ("assistant turns per user turn", _f(m["assistant_per_user_turn"])),
        ("tool calls per user turn", _f(m["tool_calls_per_user_turn"])),
        ("tool error rate", f"{_f(m['tool_error_rate'], 1, True)} ({m['tool_errors']:,} of {m['tool_calls']:,} calls)"),
        ("assistant error rate", f"{_f(m['assistant_error_rate'], 1, True)} ({m['assistant_errors']:,} of "
                                 f"{m['assistant_turns']:,} turns)"),
        ("stop reasons", f"{stops}; length {_f(m['length_stop_share'], 1, True)}, "
                         f"error {_f(m['error_stop_share'], 1, True)}, aborted {_f(m['aborted_stop_share'], 1, True)}"),
        ("compactions per session", f"{_f(m['compactions_per_session'], 2)} ({m['compactions']:g} total)"),
        ("tokens in / out per user turn", f"{_f(m['input_tokens_per_user_turn'], 0)} / "
                                          f"{_f(m['output_tokens_per_user_turn'], 0)}"),
        ("cache-read ratio", f"{_f(m['cache_read_ratio'], 1, True)} ({common.fmt_tokens(t['cache_read'])} read, "
                             f"{common.fmt_tokens(t['input'])} fresh input)"),
        ("sessions open over 12h", str(m["sessions_open_over_12h"])),
    ]


def runaway_lines(m):
    return [f"{r['date']} {r['tool_calls']:,} tool calls, {common.fmt_tokens(r['tokens'])} tokens, "
            f"{r['user_turns']} user / {r['assistant_turns']} assistant turns, {common.short_project(r['project'], 40)}: "
            f"{r['title']}" for r in m["runaways"]]


def error_lines(m):
    return [f"{e['count']}x (sessions): {e['message']}" for e in m["top_errors"]]


def evidence_text(records, bullet=""):
    if not records:
        return f"{bullet}(no server evidence found)"
    out = []
    for r in records:
        scan = (f"scanned {r['scanned']:,} of {r['total']:,} bytes" if r["scanned"] != r["total"]
                else f"{r['total']:,} bytes")
        out.append(f"[{r['server']}] {r['kind']} - {r['source']} (modified {r['mtime']} UTC, {scan})\n"
                   + "\n".join("    " + ln for ln in r["text"].splitlines()))
    return "\n".join(out)


def render_table(m, records, server_names, with_server=True) -> str:
    rows = metric_rows(m)
    width = max(len(k) for k, _ in rows)
    out = [f"== {m['model']}  [{m['first']} to {m['last']}]  raw names: {', '.join(m['raw_names'])} ==",
           f"  {'metric':<{width}}  value", f"  {'-' * width}  -----"]
    out += [f"  {k:<{width}}  {v}" for k, v in rows]
    for title, lines in (("runaway sessions (most tool calls)", runaway_lines(m)),
                         ("top repeated errors (sessions containing each)", error_lines(m))):
        out.append(f"  {title}:")
        out += [f"    {ln}" for ln in lines] or ["    none"]
    if with_server:
        out.append(f"  server evidence (servers considered: {', '.join(server_names)}):")
        out += ["    " + ln for ln in evidence_text(records).splitlines()]
    return "\n".join(out)


def metrics_text(m) -> str:
    rows = [f"- {k}: {v}" for k, v in metric_rows(m)]
    return "\n".join(rows + ["- runaway sessions:"] + [f"  - {ln}" for ln in runaway_lines(m)]
                     + ["- top repeated errors (count = sessions containing the message; each session keeps at most 3):"]
                     + [f"  - {ln}" for ln in error_lines(m)])


def worst_digests(group):
    ranked = sorted(group["sessions"], key=lambda s: (s["tool_errors"] + sum(s["tool_calls"].values())), reverse=True)
    return [common.redact_secrets(analyze.session_digest(s)) for s in ranked[:DIGEST_SESSIONS]]


# ---- prompts -----------------------------------------------------------------------------------

TUNE_SCHEMA = (
    '{"verdict":{"decision":"keep|switch|needs tuning","summary":str,"reasons":[str]},'
    '"hotspots":[{"title":str,"quantified":str,"evidence":str}],'
    '"suggestions":[{"target":str,"title":str,"why":str,"evidence":str,"snippet":str,"lang":str,'
    '"scope":"general|harness|project","project":str,"confidence":"high|medium|low"}],'
    '"rules":[str],'
    '"retest":[{"measure":str,"how":str,"expect":str}]}'
)

TUNE_RULES = (
    "Goal: this local model should perform optimally with minimal waste (retries, runaway tool loops, over-long "
    "context, unnecessary thinking tokens, cold-start model reloads, wasted prefill). Produce:\n"
    "- 'verdict': decision is exactly one of keep, switch, needs tuning; 'summary' is one sentence; 'reasons' "
    "are quantified (cite numbers from the data).\n"
    "- 'hotspots': waste hotspots, each quantified from the data in 'quantified' with the supporting numbers or "
    "error text in 'evidence'.\n"
    "- 'suggestions': paste-ready settings to change. Put suggestions that cut WASTE first. Targets include "
    "'omlx model settings', 'MTPLX config', 'lm-studio model settings', 'omp config (~/.omp/agent/config.yml)', "
    "'pi settings (~/.pi/agent/settings.json)', 'litellm config', 'AGENTS.md' (with a scope) and 'shell/prompt'.\n"
    "- 'rules': instruction-file bullets for the analysed harness's own file (ready-to-append Markdown, each "
    "starting with '- ') that compensate for observed weaknesses of THIS model in this harness, for example "
    "malformed tool arguments, looping or over-long output. They have scope 'harness'; do not put general "
    "rules here.\n"
    "- 'retest': what to measure after changing something, how, and which number should move and in which "
    "direction.\n"
    "Evidence rules: only recommend settings that exist in the settings files shown below or that are "
    "well-known real settings of that server; never invent keys. Every recommendation cites observed evidence "
    "(numbers or error text). When a key is present in a shown file say 'currently set to X in <file> (modified "
    "<date>)'. Config and server files are a snapshot read today and may postdate the sessions: hedge, and "
    "never claim a past session misbehaved because of a setting unless the data shows it. Server evidence is "
    "limited to the shown dates and may be a partial tail of a log. Give a confidence label for every "
    "suggestion. If the data is too thin to support something, say so.\n"
)


def model_prompt(harness, m, digests, records, config, span) -> str:
    return (
        f"{TUNE_MARKER}\n"
        f"You are tuning the combination of the coding agent '{harness}' and the local model '{m['model']}' "
        f"(raw names in the sessions: {', '.join(m['raw_names'])}). Sessions span {span}. Sessions that used "
        "several models are counted in full for each model (see 'shared').\n"
        f"{TUNE_RULES}{analyze.SUGGESTION_RULES}\n{wiring.wiring_text(harness)}{analyze.RULES}\n"
        f"JSON schema: {TUNE_SCHEMA}\n\n"
        f"{analyze.SNAPSHOT_RULE}Server and config snapshot taken {time.strftime('%Y-%m-%d', time.gmtime())} UTC.\n\n"
        "SESSION METRICS FOR THIS MODEL (computed locally):\n" + metrics_text(m) + "\n\n"
        f"HIGHEST-WASTE SESSION DIGESTS (up to {DIGEST_SESSIONS}):\n" + "\n".join(digests) + "\n\n"
        "SERVER-SIDE EVIDENCE (read-only, secrets redacted; each block names its source file and modification "
        "date):\n" + evidence_text(records) + "\n\n"
        + (f"HARNESS CONFIG FILES (read-only context, secrets redacted; do not echo them back):\n{config}\n"
           if config else "")
    )


def reduce_prompt(harness, per_model) -> str:
    schema = '{"overview":{"paragraphs":[str],"bullets":[str]},"ranking":[{"model":str,"decision":str,"why":str}]}'
    return (
        f"{TUNE_REDUCE_MARKER}\n"
        f"Below are per-model tuning results for the coding agent '{harness}'. Write 'overview': 1-2 short "
        "paragraphs comparing the models on waste (cite numbers from the results) and bullets of the highest-value "
        "cross-model changes. 'ranking' lists every model, best fit for this harness first, with its decision "
        f"and a one-line quantified 'why'.\n{analyze.RULES}\nJSON schema: {schema}\n\n"
        "MODEL RESULTS:\n" + "\n".join(json.dumps(r, ensure_ascii=False) for r in per_model) + "\n"
    )


# ---- LLM run and report assembly ---------------------------------------------------------------

def _s(value):
    return analyze._str(value).strip()


_DECISION_RE = re.compile(r"\s*(keep|switch|needs[ _-]tuning)\b[\s:.\u2014\u2013-]*(.*)", re.I | re.S)


def _norm_decision(text) -> str:
    text = re.sub(r"[ _-]+", " ", text.strip().lower())
    return text


def parse_verdict(value):
    """(decision, reason, reasons) from a verdict given as a string or as an object with varying key names."""
    decision, reason, reasons = "", "", []
    if isinstance(value, str):
        m = _DECISION_RE.match(value)
        decision, reason = (_norm_decision(m.group(1)), m.group(2).strip()) if m else ("", value.strip())
    elif isinstance(value, dict):
        raw = next((_s(value[k]) for k in ("decision", "verdict", "recommendation", "call") if _s(value.get(k))), "")
        m = _DECISION_RE.match(raw)
        decision, rest = (_norm_decision(m.group(1)), m.group(2).strip()) if m else (_norm_decision(raw), "")
        reason = next((_s(value[k]) for k in ("summary", "reason", "why", "rationale", "explanation")
                       if _s(value.get(k))), "") or rest
        reasons = [r for r in analyze._strs(value.get("reasons")) if r.strip()]
    return decision, reason, reasons


def verdict_line(res) -> str:
    """One line 'DECISION: reason', or a plain statement when the model returned no usable verdict."""
    decision, summary = res["decision"], res["summary"]
    if decision and summary:
        return f"{decision.upper()}: {summary}"
    return decision.upper() or summary or ("" if res["reasons"] else "No verdict returned")


def model_result(raw, m):
    """Tolerant normalization of one model's JSON answer."""
    decision, summary, reasons = parse_verdict(raw.get("verdict"))
    hot = raw.get("hotspots") if isinstance(raw.get("hotspots"), list) else []
    retest = raw.get("retest") if isinstance(raw.get("retest"), list) else []
    sugg = raw.get("suggestions") if isinstance(raw.get("suggestions"), list) else []
    return {
        "model": m["model"],
        "decision": decision, "summary": summary, "reasons": reasons,
        "hotspots": [{"title": _s(h.get("title")) or "Hotspot", "quantified": _s(h.get("quantified")),
                      "evidence": _s(h.get("evidence"))} for h in hot if isinstance(h, dict)],
        "rules": [analyze.strip_bullet(r).strip() for r in analyze._strs(raw.get("rules")) if r.strip()],
        "retest": [{"measure": _s(r.get("measure")), "how": _s(r.get("how")), "expect": _s(r.get("expect"))}
                   for r in retest if isinstance(r, dict)],
        "suggestions": [analyze.normalize_suggestion(x) for x in sugg
                        if isinstance(x, dict) and (x.get("title") or x.get("snippet"))],
    }


def build_report(results, metrics_by_model, overview=None, harness=""):
    """Combine per-model results into one analyze-style report dict (sections + suggestions)."""
    multi = len(results) > 1
    sections, suggestions = [], []
    if overview:
        ov = overview.get("overview") if isinstance(overview.get("overview"), dict) else {}
        ranking = overview.get("ranking") if isinstance(overview.get("ranking"), list) else []
        sections.append({"title": "Across models", "paragraphs": analyze._strs(ov.get("paragraphs")),
                         "bullets": analyze._strs(ov.get("bullets"))
                         + [f"{_s(r.get('model'))}: {_s(r.get('decision'))} - {_s(r.get('why'))}"
                            for r in ranking if isinstance(r, dict)]})
    for res in results:
        m = metrics_by_model[res["model"]]
        sfx = f" - {res['model']}" if multi else ""
        sections.append({"title": f"Measured{sfx}",
                         "paragraphs": [f"Computed locally from {m['sessions']} sessions ({m['first']} to {m['last']}); "
                                        "no LLM involved."],
                         "bullets": [f"{k}: {v}" for k, v in metric_rows(m)]
                         + [f"runaway: {ln}" for ln in runaway_lines(m)] + [f"error: {ln}" for ln in error_lines(m)]})
        sections.append({"title": f"Verdict{sfx}",
                         "paragraphs": [p for p in [verdict_line(res)] if p],
                         "bullets": res["reasons"]})
        sections.append({"title": f"Waste hotspots{sfx}", "paragraphs": [],
                         "bullets": [f"{h['title']}: {h['quantified']}" + (f" (evidence: {h['evidence']})" if h["evidence"] else "")
                                     for h in res["hotspots"]]})
        sections.append({"title": f"Settings to change{sfx}",
                         "paragraphs": [f"{len(res['suggestions'])} paste-ready suggestions, grouped by where they go, "
                                        "in the Suggestions section below."],
                         "bullets": [f"[{s['confidence']}] {s['title']} ({analyze.target_info(s['target'], harness, s['project'])[0]})"
                                     for s in res["suggestions"]]})
        sections.append({"title": f"Rules/prompts for this model{sfx}", "paragraphs": [], "bullets": res["rules"]})
        sections.append({"title": f"Re-test checklist{sfx}", "paragraphs": [],
                         "bullets": [f"{r['measure']}: {r['how']} -> expect {r['expect']}".strip() for r in res["retest"]]})
        for s in res["suggestions"]:
            s = dict(s)
            if multi:
                s["title"] = f"[{res['model']}] {s['title']}"
            suggestions.append(s)
        if res["rules"]:
            suggestions.append({"target": analyze.INSTRUCTION_TARGETS["harness"], "scope": "harness", "project": "",
                                "title": f"Rules for {res['model']}",
                                "why": "Bullets compensating for weaknesses of this model observed in the sessions.",
                                "evidence": res["summary"], "snippet": "\n".join(f"- {r}" for r in res["rules"]),
                                "lang": "markdown", "confidence": "medium"})
    return {"glance": {}, "sections": sections, "horizon": [], "suggestions": suggestions}


def tune_models(harness, groups, metrics, evidence, digests, config, cmd):
    """Run one LLM call per model plus a reduce when several; returns the combined report dict."""
    results = []
    for g, m in zip(groups, metrics):
        span = f"{m['first']} to {m['last']}"
        prompt = model_prompt(harness, m, digests[m["model"]], evidence[m["model"]], config, span)
        raw = analyze.ask_json(cmd, prompt, f"tune {m['model']}")
        results.append(model_result(raw, m))
    overview = None
    if len(results) > 1:
        brief = [{"model": r["model"], "decision": r["decision"], "summary": r["summary"], "reasons": r["reasons"],
                  "hotspots": [h["title"] + ": " + h["quantified"] for h in r["hotspots"]],
                  "suggestions": [s["title"] for s in r["suggestions"]]} for r in results]
        overview = analyze.ask_json(cmd, reduce_prompt(harness, brief), "tune reduce")
    return build_report(results, {m["model"]: m for m in metrics}, overview, harness)


def tune_meta(metrics, total) -> str:
    """Header line: per-model session counts against the sessions in range (sessions can use several models)."""
    first = min((m["first"] for m in metrics if m["first"]), default="?")
    last = max((m["last"] for m in metrics if m["last"]), default="?")
    if len(metrics) == 1:
        counts = f"{metrics[0]['sessions']} sessions using this model of {total} in range"
    else:
        counts = (", ".join(f"{m['model']} {m['sessions']}" for m in metrics)
                  + f" sessions ({total} in range; a session using several models counts for each)")
    return (f"{len(metrics)} model(s): {counts}, {first} to {last}; verdicts by an LLM from local metrics and "
            "server evidence; verify specifics")


def _cfg_summary(included):
    return analyze.config_summary(included)


def _evidence_summary(all_records) -> str:
    rows = servers.sources_summary(all_records)
    if not rows:
        return "no server evidence files"
    return "server evidence files: " + ", ".join(
        f"{p} ({sent} bytes sent" + (f", {scanned} of {total} scanned" if scanned != total else "") + ")"
        for p, sent, scanned, total in rows)


def run_tune(args, sessions, open_file) -> int:
    t0 = time.monotonic()
    if not sessions:
        print(f"{args.harness}: no sessions found.", file=sys.stderr)
        return 1
    groups = select_groups(sessions, args.model)
    if not groups:
        what = f"no model matching '{args.model}'" if args.model else \
            f"no model with at least {MIN_SESSIONS} sessions in range (use --model SUBSTR to pick one)"
        print(f"agent_insights: tune: {what}.", file=sys.stderr)
        return 1
    metrics = [compute_metrics(g) for g in groups]
    evidence = {m["model"]: [] for m in metrics}
    t_server = 0.0
    if not args.no_server:
        t1 = time.monotonic()
        ev = servers.Evidence()
        for g, m in zip(groups, metrics):
            evidence[m["model"]] = ev.for_model(m["model"], g["raw"], servers.window_for(g["sessions"]))
        t_server = time.monotonic() - t1
    all_records = [r for recs in evidence.values() for r in recs]
    if args.no_llm:
        for g, m in zip(groups, metrics):
            print(render_table(m, evidence[m["model"]], servers.servers_for(g["raw"]), not args.no_server))
            print()
        print(f"agent_insights: tune: {len(groups)} model(s), {len(sessions)} sessions in range; "
              f"server evidence {len(all_records)} records from {len({r['source'] for r in all_records})} files "
              f"in {t_server:.2f}s; total {time.monotonic() - t0:.2f}s (after session load)", file=sys.stderr)
        return 0
    try:
        config_text, included = analyze.load_config_files(
            analyze.config_candidates(args.harness, args.config or [], not args.no_config))
    except OSError as exc:
        print(f"agent_insights: cannot read --config file: {exc}", file=sys.stderr)
        return 1
    cmd = args.llm or analyze.DEFAULT_LLM
    digests = {m["model"]: worst_digests(g) for g, m in zip(groups, metrics)}
    if args.dry_run:
        for g, m in zip(groups, metrics):
            print(f"=== TUNE PROMPT: {m['model']} ===")
            print(model_prompt(args.harness, m, digests[m["model"]], evidence[m["model"]], config_text,
                               f"{m['first']} to {m['last']}"))
        if len(groups) > 1:
            print("=== TUNE REDUCE PROMPT (placeholder; 1 call) ===")
            print(reduce_prompt(args.harness, ["<per-model result JSON from the calls above>"]))
        print(f"=== DRY RUN: no LLM call made; would pipe {len(groups) + (len(groups) > 1)} prompt(s) to: {cmd} ===")
        print(f"agent_insights: dry run; {_evidence_summary(all_records)}; {_cfg_summary(included)}", file=sys.stderr)
        return 0
    digest_bytes = sum(len(metrics_text(m).encode()) + sum(len(d.encode()) + 1 for d in digests[m["model"]])
                       for m in metrics)
    print(f"agent_insights: tune: sending {len(groups)} models ({', '.join(m['model'] for m in metrics)}), "
          f"{sum(m['sessions'] for m in metrics)} sessions ({digest_bytes} digest bytes, no full transcripts); "
          f"{_evidence_summary(all_records)}; {_cfg_summary(included)}; to LLM command: {cmd}", file=sys.stderr)
    status = 0
    try:
        report = tune_models(args.harness, groups, metrics, evidence, digests, config_text, cmd)
    except analyze.AnalyzeError as exc:
        print(f"agent_insights: tune failed: {exc}; emitting raw LLM output", file=sys.stderr)
        report = analyze.raw_report(exc.raw)
        status = 1
    title = f"{args.harness} tune: " + ", ".join(m["model"] for m in metrics)
    meta = tune_meta(metrics, len(sessions))
    text = analyze.render(args.format, args.harness, report, meta, None, title, "tune-")
    if args.out == "-" or (args.format == "md" and not args.out):
        sys.stdout.write(text)
        return status
    path = os.path.expanduser(args.out) if args.out else analyze.default_out_path(args.harness, "tune-")
    os.makedirs(os.path.dirname(os.path.abspath(path)), exist_ok=True)
    with open(path, "w", encoding="utf-8") as fh:
        fh.write(text)
    print(f"agent_insights: wrote {path}", file=sys.stderr)
    if args.open:
        open_file(path)
    return status
