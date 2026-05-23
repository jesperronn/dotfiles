#!/usr/bin/env python3
"""Inspect a filtered JSONL run log while ignoring any stray non-JSON lines.

Usage:
  python3 local-model-testrun-inspect.py run.jsonl
"""

from __future__ import annotations

import json
import re
import sys
from datetime import datetime
from pathlib import Path


TS_RE = re.compile(r"^(\d{4}-\d{2}-\d{2}T\d{2}:\d{2}:\d{2}(?:\.\d+)?Z)")
WARN_NEEDLE = "WARN codex_otel::events::session_telemetry:"


def parse_iso_z(value: str) -> datetime:
    if value.endswith("Z"):
        value = value[:-1] + "+00:00"
    return datetime.fromisoformat(value)


def main() -> int:
    if len(sys.argv) != 2:
        print("usage: python3 local-model-testrun-inspect.py <run.jsonl>", file=sys.stderr)
        return 2

    path = Path(sys.argv[1])
    if not path.is_file():
        print(f"missing file: {path}", file=sys.stderr)
        return 1

    json_events = []
    ignored_non_json = 0
    telemetry_warns = 0
    first_ts = None
    last_ts = None

    with path.open() as fh:
        for raw_line in fh:
            line = raw_line.rstrip("\n")

            match = TS_RE.match(line)
            if match:
                ts = parse_iso_z(match.group(1))
                first_ts = ts if first_ts is None else min(first_ts, ts)
                last_ts = ts if last_ts is None else max(last_ts, ts)

            if WARN_NEEDLE in line:
                telemetry_warns += 1

            if not line.startswith("{"):
                ignored_non_json += 1
                continue

            try:
                obj = json.loads(line)
            except json.JSONDecodeError:
                ignored_non_json += 1
                continue

            json_events.append(obj)

    print(f"log: {path}")
    print(f"json events: {len(json_events)}")
    print(f"ignored non-json lines: {ignored_non_json}")
    print(f"telemetry warn lines: {telemetry_warns}")
    if first_ts and last_ts:
        elapsed = (last_ts - first_ts).total_seconds()
        print(f"approx wall time from log timestamps: {elapsed:.2f}s")

    print("\nreasoning:")
    for obj in json_events:
        if obj.get("type") != "item.completed":
            continue
        item = obj.get("item", {})
        if item.get("type") == "reasoning":
            print(f"- {item.get('text', '').strip()}")

    print("\ncommands:")
    for obj in json_events:
        if obj.get("type") != "item.completed":
            continue
        item = obj.get("item", {})
        if item.get("type") != "command_execution":
            continue
        command = item.get("command", "").strip()
        exit_code = item.get("exit_code")
        status = item.get("status")
        print(f"- exit={exit_code} status={status} command={command}")

    print("\nfinal message:")
    for obj in json_events:
        if obj.get("type") != "item.completed":
            continue
        item = obj.get("item", {})
        if item.get("type") == "agent_message":
            print(item.get("text", "").strip())

    print("\nusage:")
    for obj in json_events:
        if obj.get("type") == "turn.completed":
            usage = obj.get("usage", {})
            print(json.dumps(usage, indent=2, sort_keys=True))

    return 0


if __name__ == "__main__":
    raise SystemExit(main())
