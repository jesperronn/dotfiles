"""Local wiring check: does each harness load the user's shared ~/.agents/AGENTS.md? (no LLM, read-only)

`wiring_status(harness, home)` inspects the harness's user-level instruction file(s) and classifies each as
missing / empty / separate-copy / linked-to-shared. Nothing here ever changes files; fix commands are
returned as display-only text.
"""
from __future__ import annotations

import os

SHARED = "~/.agents/AGENTS.md"
STATES = ("missing", "empty", "separate-copy", "linked-to-shared")

# pi checks these names in ~/.pi/agent (first existing wins); source-verified in pi's resource-loader.
PI_CANDIDATES = ("AGENTS.override.md", "AGENTS.md", "AGENTS.MD", "CLAUDE.md", "CLAUDE.MD")

# Where each harness reads its user-level instructions; the first entry is the one a fix command targets.
USER_FILES = {
    "omp": ("~/.omp/agent/AGENTS.md",),
    "pi": tuple(f"~/.pi/agent/{n}" for n in PI_CANDIDATES),
    "codex": ("~/.codex/AGENTS.md",),
    "copilot": ("~/.copilot/copilot-instructions.md", "~/.copilot/AGENTS.md"),
}
# The user-level file a harness-scope instruction suggestion is appended to.
HARNESS_INSTRUCTION_FILE = {
    "omp": "~/.omp/agent/AGENTS.md", "pi": "~/.pi/agent/AGENTS.md", "codex": "~/.codex/AGENTS.md",
    "copilot": "~/.copilot/copilot-instructions.md",
}
VERIFIED_NOTE = {
    "omp": "source-verified: omp's changelog shows it reads user-level ~/.omp/agent/AGENTS.md (project and "
           "ancestor instruction files are loaded as well)",
    "pi": "source-verified in pi's resource-loader: the first existing of its candidate names in ~/.pi/agent "
          "wins, and the same names are also read in the working directory and its ancestors",
    "codex": "documented behaviour, not source-verified here: codex reads ~/.codex/AGENTS.md",
    "copilot": "documented behaviour, not source-verified here: the copilot CLI reads "
               "~/.copilot/copilot-instructions.md and possibly ~/.copilot/AGENTS.md",
}


def _display(path, home):
    return "~" + path[len(home):] if path.startswith(home + os.sep) else path


def _classify(path, shared_real):
    """(state, bytes) of one instruction file."""
    if not os.path.exists(path):  # missing, or a dangling symlink
        return "missing", 0
    size = os.path.getsize(path)
    if os.path.realpath(path) == shared_real:
        return "linked-to-shared", size
    return ("empty" if size == 0 else "separate-copy"), size


def fix_commands(state, path, shared_exists):
    """Display-only shell lines that would wire `path` to the shared file ([] when already linked)."""
    link = f"ln -s {SHARED} {path}"
    parent = os.path.dirname(path)
    lines = [] if shared_exists else [f"# {SHARED} does not exist yet: create it first (mkdir -p ~/.agents)"]
    if state == "missing":
        return lines + [f"mkdir -p {parent} && {link}"]
    if state == "empty":
        return lines + [f"# {path} is a 0-byte regular file: it must be removed or replaced first",
                        f"mv {path} {path}.empty.bak && {link}"]
    if state == "separate-copy":
        return lines + [f"# {path} has its own content: merge any rules you want to keep into {SHARED} first",
                        f"diff {path} {SHARED}",
                        f"mv {path} {path}.bak && {link}"]
    return []


def wiring_status(harness, home) -> dict:
    """Wiring of `harness` against the shared file, with HOME = `home`.

    Returns {harness, shared:{path, exists, bytes}, files:[{path, state, bytes, winner}], state, verified_note,
    fixes:[{path, state, commands}]}. `state` is the best state over the loaded file(s). For pi only the winning
    candidate counts (reported in `winner`); for copilot both files are loaded, so either may link.
    """
    shared_full = os.path.join(home, ".agents", "AGENTS.md")
    shared_exists = os.path.isfile(shared_full)
    shared_real = os.path.realpath(shared_full)
    shared = {"path": SHARED, "exists": shared_exists, "bytes": os.path.getsize(shared_full) if shared_exists else 0}
    names = USER_FILES.get(harness, ())
    fulls = [os.path.join(home, n[2:]) for n in names]  # n starts with "~/"
    files = []
    if harness == "pi":
        existing = [(n, f) for n, f in zip(names, fulls) if os.path.lexists(f)]
        picked = existing[:1] or [(names[1], fulls[1])]  # nothing exists: AGENTS.md is the file to create
        for n, f in picked:
            state, size = _classify(f, shared_real)
            files.append({"path": n, "state": state, "bytes": size, "winner": bool(existing)})
    else:
        for n, f in zip(names, fulls):
            state, size = _classify(f, shared_real)
            files.append({"path": n, "state": state, "bytes": size, "winner": False})
    order = {s: i for i, s in enumerate(STATES)}
    overall = max((f["state"] for f in files), key=lambda s: order[s], default="missing")
    fixes = []
    if overall != "linked-to-shared" and files:
        target = files[0]
        fixes.append({"path": target["path"], "state": target["state"],
                      "commands": fix_commands(target["state"], target["path"], shared_exists)})
    return {"harness": harness, "shared": shared, "files": files, "state": overall,
            "verified_note": VERIFIED_NOTE.get(harness, "unknown harness"), "fixes": fixes}


def prompt_block(status) -> str:
    """Compact WIRING block for LLM prompts."""
    sh = status["shared"]
    lines = [f"WIRING (checked locally on this machine, no LLM): shared file {sh['path']} "
             + (f"exists ({sh['bytes']} bytes)." if sh["exists"] else "does not exist.")]
    for f in status["files"]:
        tag = " (first existing candidate, the one pi loads)" if f["winner"] else ""
        lines.append(f"- {status['harness']} user-level instruction file {f['path']}: {f['state']}, "
                     f"{f['bytes']} bytes{tag}.")
    if status["state"] == "linked-to-shared":
        lines.append("Meaning: this harness already loads the shared file, so GENERAL rules reach it. Never "
                     "recommend adding general rules to this harness's own file (it is a symlink to the shared file "
                     "and they would duplicate); put general rules in the shared file only.")
    else:
        lines.append(f"Meaning: this harness does NOT load the shared file (state: {status['state']}), so general "
                     "rules placed there do not reach it yet; the report separately tells the user how to wire it.")
    return "\n".join(lines) + "\n"


def wiring_text(harness, home=None) -> str:
    return prompt_block(wiring_status(harness, home or os.path.expanduser("~")))
