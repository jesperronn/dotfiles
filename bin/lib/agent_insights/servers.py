"""Read-only, bounded evidence from local model servers (omlx, MTPLX, LM Studio, ollama).

Used by `agent_insights <harness> tune`. Every source is optional and parsed tolerantly: a missing,
unreadable or oddly shaped file yields no record, never an exception. Big logs are only tailed (the last
TAIL_BYTES), SQLite is opened with mode=ro, and every record carries its source path and modification
date (UTC) so the LLM can hedge about snapshots. Record text is secret-redacted before it leaves here.

A record is {"server", "kind", "source", "mtime", "text", "scanned", "total"}; `scanned`/`total` are the
bytes looked at vs the file size (equal for small files).
"""
from __future__ import annotations

import json
import os
import re
import sqlite3
from collections import Counter, defaultdict
from datetime import datetime, timezone

from . import analyze, common

TAIL_BYTES = 2_000_000          # server logs / jsonl logs: only the last ~2 MB
JSONL_TAIL_BYTES = 1_500_000
RECORD_CHARS = 3000
SAMPLE_CHARS = 200
SAMPLES = 5
MAX_ROTATED = 4

SERVERS = ("omlx", "mtplx", "lmstudio", "ollama")
# routing prefix in a raw model name -> server
PREFIX_SERVER = {"omlx": "omlx", "mtplx": "mtplx", "lm-studio": "lmstudio", "lmstudio": "lmstudio",
                 "lms": "lmstudio", "ollama": "ollama"}


def servers_for(raw_names) -> list:
    """Servers a model ran on, from routing prefixes (litellm/omlx/x -> omlx); every server when unknown."""
    found = set()
    for raw in raw_names:
        parts = str(raw).lower().split("/")
        while parts and parts[0] == "litellm":
            parts = parts[1:]
        if len(parts) > 1 and parts[0] in PREFIX_SERVER:
            found.add(PREFIX_SERVER[parts[0]])
    return [s for s in SERVERS if s in found] or list(SERVERS)


def token_key(name) -> frozenset:
    """Order/vendor-insensitive identity of a model name: 'Youssofal--Qwen3.8-27B-MTPLX-Speed' ~ 'mtplx-qwen38-27b-speed'."""
    text = str(name).lower().rsplit("--", 1)[-1].rsplit("/", 1)[-1].replace(".", "")
    return frozenset(t for t in re.split(r"[^a-z0-9]+", text) if t and t != "mtplx")


def same_model(a, b) -> bool:
    a, b = common.normalize_model(a), common.normalize_model(b)
    return bool(a) and bool(b) and (a == b or (len(token_key(a)) >= 2 and token_key(a) == token_key(b)))


def _pct(values, q):
    if not values:
        return None
    ordered = sorted(values)
    return ordered[min(len(ordered) - 1, int(round(q * (len(ordered) - 1))))]


def _num(value, digits=1):
    if value is None:
        return "-"
    return f"{value:.{digits}f}" if isinstance(value, float) else f"{value:,}"


def _dist(values, digits=1) -> str:
    if not values:
        return "n/a"
    return (f"p50 {_num(_pct(values, .5), digits)} / p95 {_num(_pct(values, .95), digits)} "
            f"/ max {_num(max(values), digits)}")


def _day(dt) -> str:
    return dt.strftime("%Y-%m-%d")


class Window:
    """Inclusive UTC date window (day strings; either end may be open)."""

    def __init__(self, since=None, until=None):
        self.since, self.until = since, until

    def has_day(self, day) -> bool:
        return (not self.since or day >= self.since) and (not self.until or day <= self.until)

    def has_epoch(self, seconds) -> bool:
        dt = common.parse_ts(seconds)
        return bool(dt) and self.has_day(_day(dt))

    def __str__(self):
        return f"{self.since or '...'} to {self.until or '...'}"


def tail_text(path, limit):
    """(lines, scanned_bytes, total_bytes) of the last `limit` bytes; a cut first line is dropped."""
    try:
        total = os.path.getsize(path)
        with open(path, "rb") as fh:
            start = max(0, total - limit)
            fh.seek(start)
            data = fh.read(limit)
    except OSError:
        return [], 0, 0
    lines = data.decode("utf-8", errors="replace").splitlines()
    if start > 0 and lines:
        lines = lines[1:]
    return lines, len(data), total


class Evidence:
    """Parses each server source at most once; `for_model` filters the parsed data per model and window."""

    def __init__(self, home=None):
        self.home = home or os.path.expanduser("~")
        self._cache = {}

    # -- helpers --------------------------------------------------------------------------------
    def _p(self, *parts):
        return os.path.join(self.home, *parts)

    def _shown(self, path):
        text = os.path.abspath(path)
        text = "~" + text[len(self.home):] if text.startswith(self.home) else text
        return common.redact_secrets(text)

    def _mtime(self, path):
        try:
            return datetime.fromtimestamp(os.path.getmtime(path), timezone.utc).strftime("%Y-%m-%d")
        except OSError:
            return "?"

    def _rec(self, server, kind, path, text, scanned=None, total=None):
        try:
            size = os.path.getsize(path)
        except OSError:
            size = 0
        text = common.redact_secrets(text)
        if len(text) > RECORD_CHARS:
            text = text[:RECORD_CHARS] + "\n[truncated]"
        return {"server": server, "kind": kind, "source": self._shown(path), "mtime": self._mtime(path),
                "text": text, "scanned": size if scanned is None else scanned,
                "total": size if total is None else total}

    def _cached(self, key, fn):
        if key not in self._cache:
            try:
                self._cache[key] = fn()
            except Exception:  # tolerant by contract: bad evidence must never break tune
                self._cache[key] = None
        return self._cache[key]

    def _json(self, *parts):
        path = self._p(*parts)

        def load():
            with open(path, encoding="utf-8", errors="replace") as fh:
                return json.load(fh)
        return path, self._cached(("json", path), load)

    def _scrub(self, obj):
        """Drop secret-looking keys (and auth/host noise) from parsed JSON before it is shown."""
        if isinstance(obj, dict):
            return {k: self._scrub(v) for k, v in obj.items()
                    if not analyze.is_secret_key(str(k))
                    and not re.search(r"(secret|password|credential|auth|api_?key|sub_keys|_key$|token$|cors|alias)",
                                      str(k), re.I)}
        if isinstance(obj, list):
            return [self._scrub(v) for v in obj[:20]]
        return obj

    def _dump(self, obj):
        return analyze.redact_config(json.dumps(self._scrub(obj), indent=1, ensure_ascii=False, default=str))

    # -- public ---------------------------------------------------------------------------------
    def for_model(self, model, raw_names, win) -> list:
        records = []
        for server in servers_for(raw_names):
            collect = getattr(self, f"_{server}")
            try:
                records += collect(model, win)
            except Exception:
                continue
        return records

    # -- omlx -----------------------------------------------------------------------------------
    OMLX_KEEP = re.compile(r"(max_context|max_tokens|max_tool_result|temperature|top_p|top_k|min_p|repetition|"
                           r"presence|frequency|ttl|pinned|thinking|reasoning|chat_template|tool_call|parser|"
                           r"turboquant|specprefill|dflash|force_sampling|preserve|kv_|context)", re.I)
    OMLX_NOISE = re.compile(r"(ane_prefill|engram|ple_ssd|expert_offload|oq_a8|ced_prefill|dflash_(?!enabled))", re.I)
    OMLX_SECTIONS = ("server", "model", "memory", "scheduler", "cache", "sampling", "idle_timeout", "logging")

    def _omlx_model_keys(self, settings):
        return {k: v for k, v in settings.items()
                if self.OMLX_KEEP.search(k) and not self.OMLX_NOISE.search(k)}

    def _omlx(self, model, win):
        out = []
        base = self._p(".omlx")
        path, data = self._json(".omlx", "settings.json")
        if isinstance(data, dict):
            keep = {k: data[k] for k in self.OMLX_SECTIONS if k in data}
            out.append(self._rec("omlx", "server settings", path,
                                 "omlx global settings.json (secrets and auth removed):\n" + self._dump(keep)))
        path, data = self._json(".omlx", "model_settings.json")
        models = data.get("models") if isinstance(data, dict) else None
        for name, settings in (models or {}).items():
            if same_model(name, model) and isinstance(settings, dict):
                out.append(self._rec("omlx", "model settings", path,
                                     f"omlx per-model settings for '{name}' (only tuning-relevant keys):\n"
                                     + self._dump(self._omlx_model_keys(settings))))
        path, data = self._json(".omlx", "model_profiles.json")
        profiles = data.get("profiles") if isinstance(data, dict) else None
        for name, profs in (profiles or {}).items():
            if same_model(name, model) and isinstance(profs, dict):
                out.append(self._rec("omlx", "model profiles", path,
                                     f"omlx profiles for '{name}':\n" + self._dump(
                                         {p: (v.get("settings") if isinstance(v, dict) else v)
                                          for p, v in profs.items()})))
        path, data = self._json(".omlx", "stats.json")
        per = data.get("per_model") if isinstance(data, dict) else None
        for name, st in (per or {}).items():
            if same_model(name, model) and isinstance(st, dict):
                out.append(self._rec("omlx", "lifetime stats", path, "omlx stats.json lifetime totals for "
                                     f"'{name}' (NOT limited to the session dates): " + self._stat_line(st)))
        out += self._omlx_usage(model, win, os.path.join(base, "usage.sqlite3"))
        out += self._omlx_logs(model, win)
        return out

    @staticmethod
    def _stat_line(st):
        req, prompt, comp = st.get("requests", 0), st.get("prompt_tokens", 0), st.get("completion_tokens", 0)
        cached = st.get("cached_tokens", 0)
        pre, gen = st.get("prefill_duration") or 0, st.get("generation_duration") or 0
        parts = [f"requests={req:,}", f"prompt_tokens={prompt:,}", f"completion_tokens={comp:,}",
                 f"cached_tokens={cached:,} ({100 * cached / prompt:.0f}% of prompt)" if prompt else "cached_tokens=0"]
        if pre:
            parts.append(f"prefill~{max(prompt - cached, 0) / pre:.0f} tok/s")
        if gen:
            parts.append(f"decode~{comp / gen:.1f} tok/s")
        return ", ".join(parts)

    def _omlx_usage(self, model, win, path):
        if not os.path.isfile(path):
            return []

        def load():
            con = sqlite3.connect(f"file:{path}?mode=ro", uri=True, timeout=1)
            try:
                cols = [r[1] for r in con.execute("PRAGMA table_info(model_usage_hourly)")]
                rows = con.execute("SELECT * FROM model_usage_hourly ORDER BY timestamp_hour DESC LIMIT 200000").fetchall()
                return cols, rows
            finally:
                con.close()
        got = self._cached(("omlx-usage", path), load)
        if not got or not got[0]:
            return [self._rec("omlx", "usage db", path, "omlx usage.sqlite3 could not be read (no model_usage_hourly table).")]
        cols, rows = got
        idx = {c: i for i, c in enumerate(cols)}
        hours = [r[idx["timestamp_hour"]] for r in rows if "timestamp_hour" in idx]
        span = (f"db covers {_day(common.parse_ts(min(hours)))} to {_day(common.parse_ts(max(hours)))}"
                if hours else "db is empty")
        agg = defaultdict(float)
        for r in rows:
            if not same_model(r[idx["model_id"]], model) or not win.has_epoch(r[idx["timestamp_hour"]]):
                continue
            for c in cols:
                if c not in ("timestamp_hour", "model_id") and isinstance(r[idx[c]], (int, float)):
                    agg[c] += r[idx[c]]
            agg["hours"] += 1
        if not agg:
            return [self._rec("omlx", "usage db", path, f"omlx usage.sqlite3: no rows for this model in {win}; {span}.")]
        req, prompt, cached = agg["requests"], agg["prompt_tokens"], agg["cached_tokens"]
        text = [f"omlx usage.sqlite3 (hourly table model_usage_hourly), window {win}; {span}:",
                f"requests={int(req):,} over {int(agg['hours'])} active hours, prompt_tokens={int(prompt):,}, "
                f"completion_tokens={int(agg['completion_tokens']):,}, "
                f"cache hit={100 * cached / prompt:.0f}% of prompt tokens" if prompt else f"requests={int(req):,}"]
        if agg.get("prefill_seconds"):
            text.append(f"prefill ~{max(prompt - cached, 0) / agg['prefill_seconds']:.0f} tok/s (uncached tokens / prefill s)")
        if agg.get("generation_seconds"):
            text.append(f"decode ~{agg['completion_tokens'] / agg['generation_seconds']:.1f} tok/s")
        if agg.get("timed_requests"):
            text.append(f"mean request time {agg['request_seconds'] / agg['timed_requests']:.1f}s over "
                        f"{int(agg['timed_requests'])} timed requests")
        for c in cols:
            if "error" in c.lower() or "fail" in c.lower():
                text.append(f"{c}={int(agg.get(c, 0))}")
        if not any("error" in c.lower() for c in cols):
            text.append("(table has no error or latency-percentile columns)")
        return [self._rec("omlx", "usage db", path, "\n".join(text))]

    LOG_LINE = re.compile(r"^(\d{4}-\d{2}-\d{2}) (\d{2}:\d{2}:\d{2})[,.]\d+ - ([\w.]+) - (\w+) - (.*)$")
    CHAT = re.compile(r"Chat completion: model=(?P<m>[^,]+), (?P<tok>\d+) tokens in (?P<s>[\d.]+)s "
                      r"\((?P<tps>[\d.]+) tok/s\), prompt: (?P<p>\d+), finish_reason=(?P<fr>[\w-]+)"
                      r"(?:.*?max_tokens=(?P<mx>\d+))?(?:.*?stream_model_ttft=(?P<ttft>[\d.]+)s)?")
    EVENT_KINDS = (("load", re.compile(r"\bLoading model\b")), ("unload", re.compile(r"\bUnloading model\b")),
                   ("ttl-expiry", re.compile(r"\bTTL expired\b")),
                   ("tool-result-truncated", re.compile(r"Tool result truncated")),
                   ("throttle/eviction", re.compile(r"throttl|LRU eviction|headroom|prefill-eviction", re.I)),
                   ("error", re.compile(r"\b(error|exception|traceback|timed? ?out|timeout|oom|out of memory|failed)\b", re.I)))

    EVENT_GATE = ("loading", "unloading", "ttl", "truncated", "throttl", "evict", "headroom", "error", "exception",
                  "timeout", "timed", "oom", "out of memory", "failed", "traceback")

    def _parse_log(self, path):
        lines, scanned, total = tail_text(path, TAIL_BYTES)
        chats, events, seen_day, seen_time, days = [], [], None, "", set()
        for line in lines:
            m = self.LOG_LINE.match(line)
            if m:
                seen_day, seen_time, level = m.group(1), m.group(2), m.group(4)
                msg = re.sub(r"^\[[^\]]*\] - ", "", m.group(5))  # rotated logs prefix a request-id slot
                days.add(seen_day)
            elif seen_day and re.match(r"(Traceback|\s+File |\w*(Error|Exception))", line):
                level, msg = "ERROR", line
            else:
                continue
            c = self.CHAT.search(msg) if "Chat completion" in msg else None
            if c:
                chats.append((seen_day, seen_time, c.group("m"), int(c.group("tok")), float(c.group("s")),
                              float(c.group("tps")), int(c.group("p")), c.group("fr"), c.group("mx"),
                              float(c.group("ttft")) if c.group("ttft") else None))
                continue
            kind = None
            if level == "INFO" and not any(w in msg.lower() for w in self.EVENT_GATE):
                continue  # cheap pre-filter: most INFO lines are neither events nor errors
            for name, rx in self.EVENT_KINDS:
                if rx.search(re.sub(r"\berrors=\d+", "", msg)):
                    kind = name
                    break
            if kind is None and level in ("ERROR", "CRITICAL", "WARNING"):
                kind = "warning" if level == "WARNING" else "error"
            if kind:
                events.append((seen_day, seen_time, kind, msg))
        return {"chats": chats, "events": events, "scanned": scanned, "total": total,
                "first": min(days, default=None), "last": max(days, default=None)}

    def _omlx_log_files(self, win):
        files = [os.path.join(self.home, "Library", "Application Support", "omlx", "logs", "server.log"),
                 self._p(".omlx", "logs", "server.log")]
        logdir = self._p(".omlx", "logs")
        try:
            names = sorted(n for n in os.listdir(logdir) if re.fullmatch(r"server\.log\.\d{4}-\d{2}-\d{2}", n))
        except OSError:
            names = []
        rotated = [n for n in names if win.has_day(n.rsplit(".", 1)[-1])]
        files += [os.path.join(logdir, n) for n in rotated[-MAX_ROTATED:]]
        return [f for f in files if os.path.isfile(f)]

    def _omlx_logs(self, model, win):
        out, empties, seen_lines = [], [], set()
        pat = re.compile(r"(?<![\w.-])" + re.escape(model) + r"(?![\w.-])", re.I)
        server_wide = Counter()
        wide_samples = {}
        for path in self._omlx_log_files(win):
            parsed = self._cached(("omlx-log", path), lambda p=path: self._parse_log(p))
            if not parsed:
                continue
            chats = [c for c in parsed["chats"] if win.has_day(c[0]) and same_model(c[2], model)]
            ev_model = [e for e in parsed["events"] if win.has_day(e[0]) and pat.search(e[3].split("Available models")[0])]
            ev_wide = [e for e in parsed["events"] if win.has_day(e[0]) and not pat.search(e[3].split("Available models")[0])
                       and e[2] in ("error", "warning", "throttle/eviction", "tool-result-truncated")]
            fresh = lambda items, key: [x for x in items if key(x) not in seen_lines and not seen_lines.add(key(x))]  # noqa: E731
            chats = fresh(chats, lambda c: ("c",) + c)
            ev_model = fresh(ev_model, lambda e: ("e",) + e)
            ev_wide = fresh(ev_wide, lambda e: ("e",) + e)
            for e in ev_wide:
                server_wide[e[2]] += 1
                key = re.sub(r"\d+", "N", e[3])[:80]
                wide_samples.setdefault(key, e[3])
            cov = f"log tail covers {parsed['first'] or '?'} to {parsed['last'] or '?'}"
            if not chats and not ev_model:
                empties.append(self._rec("omlx", "server log", path,
                                     f"omlx {os.path.basename(path)}: no lines for this model in {win}; {cov}.",
                                     parsed["scanned"], parsed["total"]))
                continue
            text = [f"omlx {os.path.basename(path)} (last {parsed['scanned']:,} of {parsed['total']:,} bytes scanned; "
                    f"{cov}; window {win}):"]
            if chats:
                fr = Counter(c[7] for c in chats)
                length = sum(1 for c in chats if c[7] == "length")
                text.append(f"{len(chats)} chat completions: finish_reason mix {dict(fr.most_common())} "
                            f"(length share {100 * length / len(chats):.0f}%)")
                text.append("decode tok/s " + _dist([c[5] for c in chats]) + "; prompt tokens " +
                            _dist([float(c[6]) for c in chats], 0) + "; completion tokens " +
                            _dist([float(c[3]) for c in chats], 0))
                ttft = [c[9] for c in chats if c[9] is not None]
                if ttft:
                    text.append("time to first token s " + _dist(ttft))
                maxes = Counter(c[8] for c in chats if c[8])
                if maxes:
                    text.append(f"request max_tokens values: {dict(maxes.most_common(4))}")
            if ev_model:
                kinds = Counter(e[2] for e in ev_model)
                text.append(f"events mentioning this model: {dict(kinds.most_common())} "
                            "(each 'load' after an 'unload' is a cold start)")
                text += self._samples(ev_model)
            out.append(self._rec("omlx", "server log", path, "\n".join(text), parsed["scanned"], parsed["total"]))
        if not out:
            out = empties[:1]  # one 'nothing found' note (with log coverage) instead of one per rotated file
        if server_wide and out:
            samples = [f"  - {common.clean_error(v)[:SAMPLE_CHARS]}" for v in list(wide_samples.values())[:SAMPLES]]
            out[-1]["text"] += ("\nserver-wide (not attributable to one model) in window: "
                                f"{dict(server_wide.most_common())}\n" + "\n".join(samples))
        return out

    def _samples(self, events):
        picked, seen = [], set()
        for day, _time, kind, msg in events:
            if kind == "load":
                continue
            key = re.sub(r"\d+", "N", msg)[:80]
            if key in seen:
                continue
            seen.add(key)
            picked.append(f"  - [{day}] {kind}: {common.clean_error(msg)[:SAMPLE_CHARS]}")
            if len(picked) >= SAMPLES:
                break
        return picked

    # -- MTPLX ----------------------------------------------------------------------------------
    def _mtplx(self, model, win):
        out = []
        path, data = self._json(".mtplx", "quickstart.json")
        if isinstance(data, dict):
            selection = data.get("model_selection") if isinstance(data.get("model_selection"), dict) else {}
            if same_model(os.path.basename(str(data.get("model", ""))), model) \
                    or same_model(selection.get("hf_model", ""), model):
                keep = {k: data[k] for k in ("model", "profile", "max", "target", "saved_at") if k in data}
                keep.update({k: selection[k] for k in ("variant", "precision", "chip", "memory_gib") if k in selection})
                out.append(self._rec("mtplx", "quickstart", path, "MTPLX quickstart.json:\n" + self._dump(keep)))
        path, data = self._json(".mtplx", "tuning.json")
        records = data.get("records") if isinstance(data, dict) else None
        for rec in (records or {}).values():
            if not isinstance(rec, dict):
                continue
            km, payload = rec.get("key_material") or {}, rec.get("payload") or {}
            if not same_model(os.path.basename(str(km.get("model", ""))), model):
                continue
            best, bm = payload.get("best") or {}, payload.get("best_multiplier") or {}
            settings = payload.get("settings") or {}
            lines = [f"MTPLX tuning.json record for {os.path.basename(str(km.get('model')))} saved {rec.get('saved_at')}:",
                     f"best mode {best.get('mode')} (depth {best.get('depth')}): {_num(best.get('tok_s'))} tok/s = "
                     f"{_num(best.get('multiplier_vs_ar'), 2)}x autoregressive ({_num(bm.get('ar_tok_s'))} tok/s); "
                     f"verdict {bm.get('verdict')}; depths tried {settings.get('depths')}; "
                     f"fans pinned {payload.get('fans_pinned')}"]
            out.append(self._rec("mtplx", "tuning", path, "\n".join(lines)))
        out += self._mtplx_flight_and_requests(model, win)
        return out

    def _mtplx_files(self, sub, prefix):
        d = self._p(".mtplx", sub)
        try:
            return sorted((n, os.path.join(d, n)) for n in os.listdir(d)
                          if re.fullmatch(prefix + r"-\d+\.jsonl", n))
        except OSError:
            return []

    def _parse_jsonl(self, path):
        lines, scanned, total = tail_text(path, JSONL_TAIL_BYTES)
        rows = []
        for line in lines:
            try:
                obj = json.loads(line)
            except ValueError:
                continue
            if isinstance(obj, dict):
                rows.append(obj)
        return rows, scanned, total

    def _mtplx_flight_and_requests(self, model, win):
        out, port_models = [], {}
        for name, path in self._mtplx_files("metrics", "flight"):
            port = re.search(r"-(\d+)\.jsonl", name).group(1)
            got = self._cached(("jsonl", path), lambda p=path: self._parse_jsonl(p))
            if not got:
                continue
            rows, scanned, total = got
            rid_model, ends = {}, []
            for r in rows:
                if r.get("ev") == "begin" and r.get("rid"):
                    rid_model[r["rid"]] = r.get("model")
            port_models[port] = {m for m in rid_model.values() if m}
            for r in rows:
                if r.get("ev") == "end" and same_model(rid_model.get(r.get("rid"), ""), model) and win.has_epoch(r.get("ts")):
                    ends.append(r)
            ts = [r["ts"] for r in rows if isinstance(r.get("ts"), (int, float))]
            cov = (f"tail covers {_day(common.parse_ts(min(ts)))} to {_day(common.parse_ts(max(ts)))}" if ts else "tail empty")
            if not ends:
                if any(same_model(m, model) for m in port_models[port]):
                    out.append(self._rec("mtplx", "flight metrics", path,
                                         f"MTPLX {name}: no finished requests for this model in {win}; {cov}.", scanned, total))
                continue
            reasons = Counter(r.get("reason") for r in ends)
            text = [f"MTPLX {name} (last {scanned:,} of {total:,} bytes; {cov}; window {win}): {len(ends)} finished requests",
                    f"end reasons {dict(reasons.most_common())}; cancelled={sum(1 for r in ends if r.get('cancelled'))}",
                    "decode tok/s " + _dist([r["decode_tok_s"] for r in ends if isinstance(r.get("decode_tok_s"), (int, float))]),
                    "time to first token s " + _dist([r["ttft_s"] for r in ends if isinstance(r.get("ttft_s"), (int, float))]),
                    "request elapsed s " + _dist([r["elapsed_s"] for r in ends if isinstance(r.get("elapsed_s"), (int, float))]),
                    "prompt tokens " + _dist([float(r["prompt_tokens"]) for r in ends if isinstance(r.get("prompt_tokens"), (int, float))], 0)]
            hit = [r["cached_tokens"] / r["prompt_tokens"] for r in ends
                   if isinstance(r.get("cached_tokens"), (int, float)) and r.get("prompt_tokens")]
            if hit:
                text.append(f"prompt cache hit rate per request {_dist([100 * h for h in hit], 0)} %")
            out.append(self._rec("mtplx", "flight metrics", path, "\n".join(text), scanned, total))
        quick_model = None
        _, quick = self._json(".mtplx", "quickstart.json")
        if isinstance(quick, dict):
            quick_model = os.path.basename(str(quick.get("model", "")))
        for name, path in self._mtplx_files("logs", "request-log"):
            port = re.search(r"-(\d+)\.jsonl", name).group(1)
            if port in port_models:
                if not any(same_model(m, model) for m in port_models[port]):
                    continue
                how = "attributed via flight metrics of the same port"
            elif quick_model and same_model(quick_model, model):
                how = "request log has no model field; attributed via quickstart.json model"
            else:
                continue
            got = self._cached(("jsonl", path), lambda p=path: self._parse_jsonl(p))
            if not got:
                continue
            rows, scanned, total = got
            stamps = [r["logged_at_s"] for r in rows if isinstance(r.get("logged_at_s"), (int, float))]
            cov = (f"tail covers {_day(common.parse_ts(min(stamps)))} to {_day(common.parse_ts(max(stamps)))}" if stamps else "tail empty")
            mine = [r for r in rows if win.has_epoch(r.get("logged_at_s"))]
            if not mine:
                out.append(self._rec("mtplx", "request log", path, f"MTPLX {name}: no requests in {win}; {cov}.", scanned, total))
                continue
            out.append(self._rec("mtplx", "request log", path, self._request_log_text(name, mine, win, cov, how, scanned, total),
                                 scanned, total))
        return out

    @staticmethod
    def _request_log_text(name, rows, win, cov, how, scanned, total):
        def col(key):
            return [r[key] for r in rows if isinstance(r.get(key), (int, float)) and not isinstance(r.get(key), bool)]
        text = [f"MTPLX {name} ({how}; last {scanned:,} of {total:,} bytes; {cov}; window {win}): {len(rows)} requests",
                "decode tok/s " + _dist(col("decode_tok_s")), "prefill tok/s " + _dist(col("prefill_tok_s")),
                "time to first token s " + _dist(col("ttft_s")), "request elapsed s " + _dist(col("request_elapsed_s")),
                "prompt tokens " + _dist([float(x) for x in col("prompt_tokens")], 0)]
        cached, prompt = sum(col("cached_tokens")), sum(col("prompt_tokens"))
        if prompt:
            text.append(f"prompt cache hit {100 * cached / prompt:.0f}% of prompt tokens")
        misses = Counter(str(r["cache_miss_reason"]) for r in rows if r.get("cache_miss_reason"))
        if misses:
            text.append(f"cache miss reasons {dict(misses.most_common(4))}")
        flags = {k: sum(1 for r in rows if r.get(k)) for k in ("repetition_stop_triggered", "loop_guard", "thinking_guard")}
        text.append("guards triggered: " + ", ".join(f"{k}={v}" for k, v in flags.items()))
        acc, drf = sum(sum(r["accepted_by_depth"]) for r in rows if isinstance(r.get("accepted_by_depth"), list)), \
            sum(sum(r["drafted_by_depth"]) for r in rows if isinstance(r.get("drafted_by_depth"), list))
        if drf:
            text.append(f"MTP draft acceptance {100 * acc / drf:.0f}% ({acc:,}/{drf:,} drafted tokens)")
        caps = Counter(r.get("effective_max_tokens") for r in rows if r.get("effective_max_tokens"))
        if caps:
            text.append(f"effective_max_tokens {dict(caps.most_common(3))}")
        mem = col("peak_memory_bytes")
        if mem:
            text.append(f"peak memory max {max(mem) / 2**30:.1f} GiB")
        return "\n".join(text)

    # -- LM Studio ------------------------------------------------------------------------------
    def _lmstudio(self, model, win):
        out = []
        path, data = self._json(".lmstudio", "settings.json")
        if isinstance(data, dict):
            keep = {k: data[k] for k in ("defaultContextLength", "modelLoadingGuardrails", "enableLocalService") if k in data}
            dev = data.get("developer") if isinstance(data.get("developer"), dict) else {}
            keep.update({k: dev[k] for k in ("jitModelTTL", "unloadPreviousJITModelOnLoad", "separateReasoningContentInAPI") if k in dev})
            chat = data.get("chat") if isinstance(data.get("chat"), dict) else {}
            if "unloadPreviousModelOnSelect" in chat:
                keep["chat.unloadPreviousModelOnSelect"] = chat["unloadPreviousModelOnSelect"]
            if keep:
                out.append(self._rec("lmstudio", "app settings", path, "LM Studio settings.json (relevant keys):\n" + self._dump(keep)))
        root = self._p(".lmstudio", ".internal", "user-concrete-model-default-config")
        if os.path.isdir(root):
            for dirpath, _dirs, files in os.walk(root):
                for fname in files:
                    if fname.endswith(".json") and same_model(fname[:-5], model):
                        full = os.path.join(dirpath, fname)
                        try:
                            with open(full, encoding="utf-8", errors="replace") as fh:
                                cfg = json.load(fh)
                        except (OSError, ValueError):
                            continue
                        fields = {}
                        for section in ("load", "operation"):
                            for f in ((cfg.get(section) or {}).get("fields") or []):
                                if isinstance(f, dict) and "key" in f:
                                    fields[f["key"]] = f.get("value")
                        out.append(self._rec("lmstudio", "model config", full,
                                             f"LM Studio per-model defaults for {fname[:-5]} (context length, GPU offload, parallel sessions, sampling):\n"
                                             + self._dump(fields)))
        out += self._lmstudio_logs(model, win)
        return out

    def _lmstudio_logs(self, model, win):
        out = []
        base = self._p(".lmstudio", "server-logs")
        pat = re.compile(r"(?<![\w.-])" + re.escape(model) + r"(?![\w.-])", re.I)
        files = []
        try:
            for month in sorted(os.listdir(base)):
                mdir = os.path.join(base, month)
                for n in sorted(os.listdir(mdir)) if os.path.isdir(mdir) else []:
                    m = re.match(r"(\d{4}-\d{2}-\d{2})", n)
                    if m and win.has_day(m.group(1)):
                        files.append(os.path.join(mdir, n))
        except OSError:
            return out
        for path in files[-MAX_ROTATED:]:
            lines, scanned, total = tail_text(path, TAIL_BYTES)
            hits = [ln for ln in lines if pat.search(ln) and re.search(r"error|fail|timeout|out of memory|unload|exceed", ln, re.I)]
            if not hits:
                continue
            seen, picked = set(), []
            for ln in hits:
                key = re.sub(r"\d+", "N", ln)[:80]
                if key not in seen and len(picked) < SAMPLES:
                    seen.add(key)
                    picked.append(f"  - {common.clean_error(ln)[:SAMPLE_CHARS]}")
            out.append(self._rec("lmstudio", "server log", path,
                                 f"LM Studio {os.path.basename(path)}: {len(hits)} error/unload lines mentioning the model:\n"
                                 + "\n".join(picked), scanned, total))
        return out

    # -- ollama ---------------------------------------------------------------------------------
    def _ollama(self, model, win):
        out = []
        mdir = self._p(".ollama", "modelfiles")
        try:
            names = sorted(os.listdir(mdir))
        except OSError:
            names = []
        for name in names:
            full = os.path.join(mdir, name)
            if not os.path.isfile(full):
                continue
            try:
                with open(full, encoding="utf-8", errors="replace") as fh:
                    body = fh.read(4000)
            except OSError:
                continue
            frm = re.search(r"^FROM\s+(\S+)", body, re.M)
            stem = re.sub(r"\.modelfile$", "", name, flags=re.I)
            if same_model(stem, model) or (frm and same_model(frm.group(1), model)):
                out.append(self._rec("ollama", "modelfile", full, f"ollama Modelfile {name}:\n{body.strip()}"))
        path, data = self._json(".ollama", "config.json")
        integrations = data.get("integrations") if isinstance(data, dict) else None
        used = sorted(k for k, v in (integrations or {}).items()
                      if isinstance(v, dict) and any(same_model(m, model) for m in v.get("models") or []))
        if used:
            out.append(self._rec("ollama", "config", path, f"ollama config.json lists this model for integrations: {', '.join(used)}"))
        return out


def window_for(sessions) -> Window:
    """UTC day window spanning the sessions' start..end dates."""
    days = []
    for s in sessions:
        for key in ("started", "ended"):
            dt = common.parse_ts(s.get(key))
            if dt:
                days.append(_day(dt))
    return Window(min(days), max(days)) if days else Window()


def sources_summary(records) -> list:
    """[(source, bytes_sent, bytes_scanned, total_bytes)] merged by source path."""
    merged = {}
    for r in records:
        m = merged.setdefault(r["source"], [0, 0, 0])
        m[0] += len(r["text"].encode())
        m[1] = max(m[1], r["scanned"])
        m[2] = max(m[2], r["total"])
    return [(k, *v) for k, v in sorted(merged.items())]
