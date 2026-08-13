#!/usr/bin/env -S uv run --script
# /// script
# requires-python = ">=3.11"
# dependencies = [
#     "opencv-python",
#     "numpy",
# ]
# ///
"""
video-ocr-extract-select-frames.py

Given a folder of sequentially-named frame images, group them into
"scenes" (based on frame-to-frame difference) and pick the sharpest
frame (highest Laplacian variance) from each scene.

Usable standalone, independent of video-ocr-extract:
    ./video-ocr-extract-select-frames.py frames/ --out best_frames/

Roadmap / later:
  - Optional perceptual-hash based grouping instead of raw pixel diff
  - Parallelize sharpness scoring across frames (currently sequential)
"""

import argparse
import shutil
import sys
from pathlib import Path

import cv2
import numpy as np


def sharpness_score(path: Path) -> float:
    img = cv2.imread(str(path), cv2.IMREAD_GRAYSCALE)
    if img is None:
        return -1.0
    return float(cv2.Laplacian(img, cv2.CV_64F).var())


def frame_diff(path_a: Path, path_b: Path) -> float:
    img_a = cv2.imread(str(path_a), cv2.IMREAD_GRAYSCALE)
    img_b = cv2.imread(str(path_b), cv2.IMREAD_GRAYSCALE)
    if img_a is None or img_b is None:
        return 0.0
    if img_a.shape != img_b.shape:
        return 255.0  # treat as a hard scene break
    return float(np.mean(cv2.absdiff(img_a, img_b)))


def group_into_scenes(frames: list[Path], diff_threshold: float) -> list[list[Path]]:
    groups: list[list[Path]] = []
    current: list[Path] = [frames[0]]

    for i in range(1, len(frames)):
        d = frame_diff(frames[i - 1], frames[i])
        if d > diff_threshold:
            groups.append(current)
            current = []
        current.append(frames[i])

    groups.append(current)
    return groups


def main() -> int:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("frames_dir", type=Path, help="Folder of extracted frame images")
    parser.add_argument("--out", type=Path, required=True, help="Folder to copy best frames into")
    parser.add_argument(
        "--diff-threshold",
        type=float,
        default=15.0,
        help="Mean pixel-diff above which a new scene is started (default: 15.0)",
    )
    parser.add_argument(
        "--pattern",
        default="*.png",
        help="Glob pattern for frame files inside frames_dir (default: *.png)",
    )
    args = parser.parse_args()

    frames = sorted(args.frames_dir.glob(args.pattern))
    if not frames:
        print(f"No frames matching {args.pattern} found in {args.frames_dir}", file=sys.stderr)
        return 1

    args.out.mkdir(parents=True, exist_ok=True)

    groups = group_into_scenes(frames, args.diff_threshold)

    best_frames = []
    for group in groups:
        best = max(group, key=sharpness_score)
        best_frames.append(best)

    for f in best_frames:
        shutil.copy2(f, args.out / f.name)

    print(f"Grouped {len(frames)} frames into {len(groups)} scenes.")
    print(f"Selected {len(best_frames)} sharpest frames -> {args.out}")
    return 0


if __name__ == "__main__":
    sys.exit(main())
