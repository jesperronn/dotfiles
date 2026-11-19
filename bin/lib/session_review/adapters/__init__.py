"""Adapter registry. An adapter is a module in this package named after its harness; see ../model.py."""
import importlib
import os

_NAMES = ("copilot", "claude")


def names():
    return [n for n in _NAMES if os.path.isfile(os.path.join(os.path.dirname(__file__), n + ".py"))]


def get(name):
    if name not in names():
        raise SystemExit(f"session_review: unknown harness {name!r} (available: {', '.join(names())})")
    return importlib.import_module(f"{__name__}.{name}")


def detect(path):
    """Return the adapter whose detect() accepts `path`, else None."""
    for n in names():
        mod = get(n)
        if mod.detect(path):
            return mod
    return None


def detect_folder(root):
    """Pick the adapter for a folder of sessions by sampling its entries."""
    root = os.path.expanduser(root)
    for n in names():
        mod = get(n)
        try:
            if mod.discover(root):
                return mod
        except OSError:
            continue
    return None
