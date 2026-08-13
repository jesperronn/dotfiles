#!/usr/bin/env -S uv run --script
# /// script
# requires-python = ">=3.11"
# dependencies = []
# ///
"""
video-ocr-extract-dedup-text.py

Given a folder of OCR .txt files (one per selected frame), remove
near-duplicate texts (same screen/content seen again later in the
recording) using fuzzy similarity, keeping the first occurrence of
each unique block in original order.

Usable standalone:
    ./video-ocr-extract-dedup-text.py ocr/ --out ocr_deduped/

Roadmap / later:
  - Per-line dedup instead of whole-file dedup (for partial overlaps
    where a scene shows the same file scrolled slightly further)
  - Configurable normalization (strip whitespace/case before compare)
"""

import argparse
import shutil
import sys
from difflib import SequenceMatcher
from pathlib import Path


def similarity(a: str, b: str) -> float:
    return SequenceMatcher(None, a, b).ratio()


def main() -> int:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("ocr_dir", type=Path, help="Folder of OCR .txt files")
    parser.add_argument("--out", type=Path, required=True, help="Folder for deduped .txt files")
    parser.add_argument(
        "--similarity-threshold",
        type=float,
        default=0.9,
        help="Ratio (0-1) above which two texts are considered duplicates (default: 0.9)",
    )
    parser.add_argument("--pattern", default="*.txt", help="Glob pattern (default: *.txt)")
    args = parser.parse_args()

    files = sorted(args.ocr_dir.glob(args.pattern))
    if not files:
        print(f"No files matching {args.pattern} found in {args.ocr_dir}", file=sys.stderr)
        return 1

    args.out.mkdir(parents=True, exist_ok=True)

    kept: list[tuple[Path, str]] = []

    for f in files:
        text = f.read_text(errors="ignore")
        is_dup = False
        for _, kept_text in kept:
            if similarity(text, kept_text) >= args.similarity_threshold:
                is_dup = True
                break
        if not is_dup:
            kept.append((f, text))

    for f, _ in kept:
        shutil.copy2(f, args.out / f.name)

    combined = args.out / "deduped.txt"
    with combined.open("w") as out_f:
        for f, text in kept:
            out_f.write(f"# --- {f.name} ---\n")
            out_f.write(text)
            out_f.write("\n\n")

    print(f"{len(files)} OCR files -> {len(kept)} unique after dedup.")
    print(f"Deduped files + combined text -> {args.out}")
    return 0


if __name__ == "__main__":
    sys.exit(main())
