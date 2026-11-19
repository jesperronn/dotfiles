"""Render one normalized session (see model.py) as a single self-contained HTML transcript page."""
import html
import json
import os
import re

from . import metrics, model

KEY_CSS = """
.keys{display:flex;flex-wrap:wrap;gap:4px 14px;align-items:center;margin:8px 0 2px;font-size:13px}.keys .k{color:var(--mut);font-size:11px;margin-right:3px}
.keys b{font-variant-numeric:tabular-nums;font-weight:600}.pill{display:inline-block;padding:0 7px;border-radius:10px}
.bad .pill{color:var(--badfg);background:color-mix(in srgb,var(--badfg) 16%,transparent)}.good .pill{color:#1a7f37;background:color-mix(in srgb,#1a7f37 16%,transparent)}.out .pill{color:#8250df;background:color-mix(in srgb,#8250df 16%,transparent)}
@media(prefers-color-scheme:dark){.good .pill{color:#3fb950;background:color-mix(in srgb,#3fb950 16%,transparent)}.out .pill{color:#d2a8ff;background:color-mix(in srgb,#d2a8ff 16%,transparent)}}
.chips{margin-top:6px}.chip{font-size:11px;padding:0 7px;border-radius:5px;border:1px solid var(--line);background:var(--bg);color:var(--mut);margin-right:3px;display:inline-block}
.timings{margin-top:6px;font-size:12px;color:var(--mut)}.timings b{color:var(--fg);font-weight:600}
.mark{display:flex;flex-wrap:wrap;gap:6px;align-items:center;margin-top:8px}.mark button{padding:3px 10px;border:1px solid var(--line);border-radius:14px;background:var(--card);color:var(--fg);cursor:pointer;font:inherit;font-size:12px}
.mark button.on{background:color-mix(in srgb,#0969da 16%,var(--bg));border-color:#0969da;box-shadow:0 0 0 1px #0969da}.mark #fav{font-size:18px;line-height:1;padding:0 8px;border-radius:6px}.mark #fav.on{color:#bf8700;border-color:#bf8700;box-shadow:0 0 0 1px #bf8700}
.mark input,.mark textarea{padding:4px 8px;border:1px solid var(--line);border-radius:6px;background:var(--bg);color:var(--fg);font:inherit;font-size:13px}.mark textarea{flex:1 1 100%;height:54px;resize:vertical}.mark input{width:220px}
.x{opacity:.55}.dot{display:inline-block;width:5px;height:5px;border-radius:50%;margin-right:4px;vertical-align:1px;background:var(--mut);opacity:.45}
.dot.neg{background:var(--badfg);opacity:.85}.dot.pos{background:#1a7f37;opacity:.85}
"""

CORRECTION_RE = re.compile(model.CORRECTION_PATTERN, re.I)
_HOME_RE = re.compile(r"/Users/[^/\s'\"]+")
_SECRET_RES = (
    re.compile(r"(?i)\b(authorization)\b\s*[:=]\s*(?:bearer|basic|token)?\s*[^\s'\",;]+"),
    re.compile(r"(?i)\b(?:bearer|basic)\s+[A-Za-z0-9._~+/=-]{6,}"),
    re.compile(r"\b(?:sk|pk|rk)-[A-Za-z0-9_-]{8,}"),
    re.compile(r"\b(?:gh[pousr]_[A-Za-z0-9]{16,}|github_pat_[A-Za-z0-9_]{16,})"),
    re.compile(r"\b[0-9a-fA-F]{32,}\b"),
)


def redact(text):
    text = _HOME_RE.sub("~", text)
    for rx in _SECRET_RES:
        text = rx.sub("[redacted]", text)
    return text


CSS = """
:root{--bg:#fff;--fg:#1f2328;--mut:#656d76;--line:#d0d7de;--user:#ddf4ff;--ai:#f6f8fa;--bad:#ffebe9;--badfg:#cf222e;--tool:#fff8c5;--code:#f6f8fa}
@media(prefers-color-scheme:dark){:root{--bg:#0d1117;--fg:#e6edf3;--mut:#8d96a0;--line:#30363d;--user:#0c2d4a;--ai:#161b22;--bad:#3b1219;--badfg:#ff7b72;--tool:#2d2a12;--code:#161b22}}
*{box-sizing:border-box}body{margin:0;background:var(--bg);color:var(--fg);font:15px/1.5 -apple-system,system-ui,sans-serif}
header{padding:16px 20px;border-bottom:1px solid var(--line)}h1{font-size:18px;margin:0 0 4px}
.meta{color:var(--mut);font-size:13px}.wrap{display:flex;align-items:flex-start}
nav{position:sticky;top:0;width:260px;max-height:100vh;overflow:auto;padding:12px;border-right:1px solid var(--line);font-size:12px;flex:none}
nav a{display:block;color:var(--fg);text-decoration:none;padding:3px 4px;border-radius:4px;white-space:nowrap;overflow:hidden;text-overflow:ellipsis}
nav a:hover{background:var(--ai)}nav a.fix{color:var(--badfg);font-weight:600}
main{flex:1;min-width:0;max-width:900px;padding:16px 20px}
.msg{border-radius:8px;padding:10px 14px;margin:10px 0;white-space:pre-wrap;word-break:break-word}
.user{background:var(--user)}.user.fix{outline:2px solid var(--badfg)}.assistant{background:var(--ai)}
.who{font-size:11px;color:var(--mut);text-transform:uppercase;letter-spacing:.04em;margin-bottom:4px}
details.tool{margin:4px 0 4px 18px;border:1px solid var(--line);border-radius:6px;font-size:13px}
details.tool.err{background:var(--bad);border-color:var(--badfg)}
details.tool summary{cursor:pointer;padding:4px 8px;font-family:ui-monospace,Menlo,monospace;overflow:hidden;text-overflow:ellipsis;white-space:nowrap}
details.tool pre{margin:0;padding:8px;background:var(--code);overflow:auto;max-height:340px;font-size:12px;white-space:pre-wrap;word-break:break-word}
.marker{text-align:center;color:var(--badfg);font-size:12px;margin:12px 0}.badge{font-size:11px;color:var(--badfg);margin-left:8px}
.navtools{position:sticky;top:-12px;margin:-12px -12px 6px;padding:10px 12px;background:var(--bg);border-bottom:1px solid var(--line);font-size:13px;cursor:pointer;z-index:1}body.notools details.tool{display:none}
@media(max-width:800px){nav{display:none}}
"""

JS = """
document.getElementById('hide').addEventListener('change',function(e){document.body.classList.toggle('notools',!e.target.checked)});
"""


def arg_preview(args):
    if isinstance(args, dict):
        for key in ("command", "file_path", "path", "pattern", "query", "skill", "prompt", "description"):
            if isinstance(args.get(key), str):
                return args[key]
    return json.dumps(args, ensure_ascii=False) if args else ""


def timings_html(t, esc):
    if not t["wall"]:
        return ""
    d = metrics.fmt_dur
    parts = [f'wall clock <b>{d(t["wall"])}</b>', f'active <b>{d(t["active"])}</b> (agent <b>{d(t["agent"])}</b> · you <b>{d(t["you"])}</b>)']
    if t["away"] >= 60:
        parts.append(f'idle gaps over 10 min <b>{d(t["away"])}</b>')
    if t["per_prompt"]:
        parts.append(f'longest run <b>{d(t["longest"])}</b> (prompt {t["longest_prompt"]}) · median run <b>{d(t["median"])}</b>')
    tip = "Agent = time the assistant worked after each of your messages. You = short waits before your next message. Idle = gaps over 10 minutes (left open, away)."
    return f'<div class="timings" title="{esc(tip)}">{" · ".join(parts)}</div>'


def mark_html():
    roles = "".join(f'<button data-role="{r}">{r or "none"}</button>' for r in ("bad", "good", "outlier", ""))
    return (f'<div class="mark"><button id="fav" title="favourite">☆</button><span class="k">role</span>{roles}'
            f'<input id="tags" placeholder="tags, comma separated"><textarea id="note" placeholder="note: why this one?"></textarea></div>')


MARK_JS = """
(function(){var c=window.SR;if(!c)return;
var $=function(i){return document.getElementById(i)};
function read(){try{return JSON.parse(localStorage.getItem(c.key)||'{}')}catch(e){return {}}}
function mine(s){return s[c.id]||{fav:false,role:'',tags:'',note:''}}
function paint(){var v=mine(read());$('fav').textContent=v.fav?'\u2605':'\u2606';$('fav').classList.toggle('on',v.fav);
 document.querySelectorAll('.mark [data-role]').forEach(function(b){b.classList.toggle('on',b.dataset.role===v.role)});
 if(document.activeElement!==$('tags'))$('tags').value=v.tags;if(document.activeElement!==$('note'))$('note').value=v.note}
function update(f){var s=read(),v=mine(s);f(v);s[c.id]=v;
 Object.keys(s).forEach(function(k){var x=s[k];if(!x.fav&&!x.role&&!x.tags&&!x.note)delete s[k]});
 try{localStorage.setItem(c.key,JSON.stringify(s))}catch(e){}paint()}
$('fav').onclick=function(){update(function(v){v.fav=!v.fav})};
document.querySelectorAll('.mark [data-role]').forEach(function(b){b.onclick=function(){update(function(v){v.role=b.dataset.role})}});
$('tags').onchange=function(){update(function(v){v.tags=$('tags').value})};
$('note').onchange=function(){update(function(v){v.note=$('note').value})};
window.addEventListener('storage',function(e){if(e.key===c.key)paint()});
paint()})();
"""


def key_numbers_html(m, esc):
    """The same key numbers and label chips as a row in the overview list (m = scored metrics dict)."""
    tips = metrics.METRIC_TIPS
    def kv(k, v, cls=""):
        val = f'<span class="pill"><b>{v}</b></span>' if cls else f"<b>{v}</b>"
        return f'<span class="{cls}" title="{esc(tips[k])}"><span class="k">{k}</span>{val}</span>'
    nums = "".join([kv("msgs", m["user_turns"]), kv("tokens", metrics.fmt_tok(m["tokens_total"])),
                    kv("err", f'{m["tool_errors"]}/{m["tool_calls"]}'), kv("bad", m["bad"], "bad"),
                    kv("good", m["good"], "good"), kv("out", m["outlier"], "out")])
    sent = {"neg": "negative", "pos": "positive", "": "neutral"}
    chips = "".join(
        f'<span class="chip" title="{esc(l["help"] + " [" + sent[l["sentiment"]] + "]")}"><i class="dot {l["sentiment"]}"></i>'
        f'{esc(l["name"])}<span class="x">{esc(l["text"][len(l["name"]):])}</span></span>' for l in m["labels"])
    return f'<div class="keys">{nums}</div><div class="chips">{chips}</div>'


def render_parts(session, max_result=1500, do_redact=True):
    """Build the transcript pieces (title, subtitle, nav, body). Cheap to keep until scores exist; see assemble()."""
    esc = (lambda s: html.escape(redact(s) if do_redact else s))
    items = session["events"]
    users = [i for i in items if i["t"] == "user"]
    tool_n = sum(1 for i in items if i["t"] == "tool")
    err_n = sum(1 for i in items if i["t"] == "tool" and not i["ok"])
    nav, body, n = [], [], 0
    tm = metrics.timings(items)
    hms = lambda ts: ts[11:19]  # noqa: E731
    for it in items:
        k = it["t"]
        if k == "user":
            n += 1
            run = tm["per_prompt"][n - 1] if n <= len(tm["per_prompt"]) else 0
            fix = n > 1 and len(it["text"]) < 600 and CORRECTION_RE.search(it["text"])
            cls = " fix" if fix else ""
            first = it["text"].strip().splitlines()[0][:60] if it["text"].strip() else "(empty)"
            nav.append(f'<a href="#u{n}" class="{cls.strip()}">{n}. {esc(first)}</a>')
            badge = '<span class="badge">possible correction</span>' if fix else ""
            body.append(f'<div class="msg user{cls}" id="u{n}"><div class="who">you · {hms(it["ts"])}{f" · agent worked {metrics.fmt_dur(run)}" if run >= 1 else ""}{badge}</div>{esc(it["text"])}</div>')
        elif k == "assistant":
            if it["text"].strip():
                body.append(f'<div class="msg assistant"><div class="who">assistant · {esc(it["model"])} · {hms(it["ts"])}</div>{esc(it["text"])}</div>')
        elif k == "tool":
            label = it["summary"] or arg_preview(it["args"])
            result = str(it["result"] or "")
            more = f"\n… [{len(result) - max_result} more chars]" if len(result) > max_result else ""
            args_txt = json.dumps(it["args"], indent=1, ensure_ascii=False) if it["args"] is not None else ""
            body.append(
                f'<details class="tool{"" if it["ok"] else " err"}"><summary>{"✗ " if not it["ok"] else ""}'
                f'{esc(it["name"])} — {esc(label[:140])}</summary>'
                f'<pre>{esc(args_txt[:max_result])}</pre><pre>{esc(result[:max_result] + more)}</pre></details>')
        else:
            body.append(f'<div class="marker">— {esc(it["text"])} · {hms(it["ts"])} —</div>')
    title = esc((users[0]["text"].strip().splitlines() or ["session"])[0][:90]) if users else "session"
    sub = (f'{esc(os.path.basename(session["project"].rstrip("/")))} · {esc(session["client"])} · '
           f'{session["started"][:10]} · {len(users)} prompts · {tool_n} tool calls · {err_n} failed')
    return {"title": title, "sub": sub, "nav": "".join(nav), "body": "".join(body), "esc": esc, "timings": tm}


def assemble(parts, m=None, storage=None):
    """Join render_parts() output into a page.

    With scored metrics `m` the header shows the overview's key numbers and labels. With `storage`
    ({"key", "id"}) it also gets favourite/role/tags/note controls that share the overview's browser storage."""
    keys = key_numbers_html(m, parts["esc"]) if m else ""
    tms = timings_html(parts["timings"], parts["esc"])
    mark, script = "", ""
    if storage:
        mark = mark_html()
        cfg = json.dumps({"key": storage["key"], "id": storage["id"]}).replace("</", "<\\/")
        script = f"<script>window.SR={cfg};{MARK_JS}</script>"
    return (f'<!doctype html><html lang="en"><head><meta charset="utf-8"><meta name="viewport" content="width=device-width,initial-scale=1">'
            f'<title>{parts["title"]}</title><style>{CSS}{KEY_CSS}</style></head><body><header><h1>{parts["title"]}</h1>'
            f'<div class="meta">{parts["sub"]}</div>{keys}{tms}{mark}'
            f'</header>'
            f'<div class="wrap"><nav><label class="navtools"><input type="checkbox" id="hide" checked> toggle tool calls</label>{parts["nav"]}</nav><main>{parts["body"]}</main></div><script>{JS}</script>{script}</body></html>')


def render(session, max_result=1500, do_redact=True, m=None, storage=None):
    """One-shot: transcript page for a normalized session (events loaded with full=True)."""
    return assemble(render_parts(session, max_result, do_redact), m, storage)
