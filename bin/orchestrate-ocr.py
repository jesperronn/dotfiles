#!/usr/bin/env -S uv run --script
# /// script
# requires-python = ">=3.11"
# dependencies = [
#     "opencv-python",
#     "numpy",
# ]
# ///
"""
orchestrate-ocr.py

Orchestrates the video OCR pipeline by fanning out subtasks:
1. Selects frames from multiple source directories concurrently.
2. Runs OCR on the selected frames concurrently.
3. Deduplicates text from the OCR results concurrently.

Usage:
    ./orchestrate-ocr.py --sources source1/ source2/ --out-dir output/

Roadmap / later:
  - Add support for resuming partial runs
  - Add progress bar for long-running tasks
  - Add configuration file support for thresholds
  - Support alternative OCR engines (e.g., PaddleOCR, EasyOCR)
"""

import argparse
import shutil
import sys
from concurrent.futures import ThreadPoolExecutor, as_completed
from pathlib import Path
import subprocess


def run_select_frames(frames_dir: Path, out_dir: Path, diff_threshold: float) -> tuple[Path, int]:
    """Run video-ocr-extract-select-frames.py on a single source directory."""
    out_frames_dir = out_dir / "best_frames" / frames_dir.name
    out_frames_dir.mkdir(parents=True, exist_ok=True)

    script_path = Path(__file__).parent / "video-ocr-extract-select-frames.py"
    cmd = [
        sys.executable,
        str(script_path),
        str(frames_dir),
        "--out", str(out_frames_dir),
        "--diff-threshold", str(diff_threshold),
    ]

    print(f"Starting frame selection for {frames_dir.name}...")
    result = subprocess.run(cmd, capture_output=True, text=True)
    if result.returncode != 0:
        print(f"Error in frame selection for {frames_dir.name}: {result.stderr}", file=sys.stderr)
        return frames_dir, 0

    # Count selected frames by listing the output directory
    selected_count = len(list(out_frames_dir.glob("*.png")))
    print(f"Selected {selected_count} frames from {frames_dir.name}.")
    return frames_dir, selected_count


def run_ocr(frames_dir: Path, out_dir: Path) -> tuple[Path, int]:
    """Run tesseract on selected frames to extract text."""
    out_ocr_dir = out_dir / "ocr_text" / frames_dir.name
    out_ocr_dir.mkdir(parents=True, exist_ok=True)

    # Assuming tesseract is installed and available in PATH
    # tesseract <input_image> <output_base> -l eng
    selected_frames = list(frames_dir.glob("*.png"))
    if not selected_frames:
        print(f"No frames found in {frames_dir} for OCR.")
        return frames_dir, 0

    ocr_count = 0
    for frame in selected_frames:
        # tesseract outputs to <output_base>.txt
        cmd = ["tesseract", str(frame), str(out_ocr_dir / frame.stem), "-l", "eng"]
        result = subprocess.run(cmd, capture_output=True, text=True)
        if result.returncode == 0:
            ocr_count += 1
        else:
            print(f"Warning: tesseract failed for {frame.name}: {result.stderr}", file=sys.stderr)

    print(f"OCR completed for {ocr_count}/{len(selected_frames)} frames in {frames_dir.name}.")
    return frames_dir, ocr_count


def run_dedup_text(ocr_dir: Path, out_dir: Path, similarity_threshold: float) -> tuple[Path, int]:
    """Run video-ocr-extract-dedup-text.py on a single OCR directory."""
    out_dedup_dir = out_dir / "deduped_text" / ocr_dir.name
    out_dedup_dir.mkdir(parents=True, exist_ok=True)

    script_path = Path(__file__).parent / "video-ocr-extract-dedup-text.py"
    cmd = [
        sys.executable,
        str(script_path),
        str(ocr_dir),
        "--out", str(out_dedup_dir),
        "--similarity-threshold", str(similarity_threshold),
    ]

    print(f"Starting text deduplication for {ocr_dir.name}...")
    result = subprocess.run(cmd, capture_output=True, text=True)
    if result.returncode != 0:
        print(f"Error in text deduplication for {ocr_dir.name}: {result.stderr}", file=sys.stderr)
        return ocr_dir, 0

    # Count deduped files by listing the output directory
    deduped_count = len(list(out_dedup_dir.glob("*.txt")))
    print(f"Deduped to {deduped_count} files from {ocr_dir.name}.")
    return ocr_dir, deduped_count


def main() -> int:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--sources", type=Path, required=True, nargs="+", help="Source directories for frame extraction")
    parser.add_argument("--out-dir", type=Path, required=True, help="Output directory for all results")
    parser.add_argument(
        "--diff-threshold",
        type=float,
        default=15.0,
        help="Diff threshold for frame selection (default: 15.0)",
    )
    parser.add_argument(
        "--similarity-threshold",
        type=float,
        default=0.9,
        help="Similarity threshold for text deduplication (default: 0.9)",
    )
    parser.add_argument(
        "--max-workers",
        type=int,
        default=4,
        help="Maximum number of concurrent workers (default: 4)",
    )
    args = parser.parse_args()

    args.out_dir.mkdir(parents=True, exist_ok=True)

    # Phase 1: Fan out frame selection
    print("Phase 1: Selecting frames...")
    frame_results = {}
    with ThreadPoolExecutor(max_workers=args.max_workers) as executor:
        futures = {
            executor.submit(run_select_frames, src, args.out_dir, args.diff_threshold): src
            for src in args.sources
        }
        for future in as_completed(futures):
            src = futures[future]
            try:
                _, count = future.result()
                frame_results[src] = count
            except Exception as e:
                print(f"Exception in frame selection for {src}: {e}", file=sys.stderr)

    # Phase 2: Fan out OCR
    print("Phase 2: Running OCR on selected frames...")
    ocr_results = {}
    with ThreadPoolExecutor(max_workers=args.max_workers) as executor:
        futures = {
            executor.submit(run_ocr, out_frames_dir, args.out_dir): out_frames_dir
            for out_frames_dir in [args.out_dir / "best_frames" / src.name for src in args.sources]
            if (args.out_dir / "best_frames" / src.name).exists()
        }
        for future in as_completed(futures):
            src = futures[future]
            try:
                _, count = future.result()
                ocr_results[src] = count
            except Exception as e:
                print(f"Exception in OCR for {src}: {e}", file=sys.stderr)

    # Phase 3: Fan out text deduplication
    print("Phase 3: Deduplicating text...")
    dedup_results = {}
    with ThreadPoolExecutor(max_workers=args.max_workers) as executor:
        futures = {
            executor.submit(run_dedup_text, ocr_dir, args.out_dir, args.similarity_threshold): ocr_dir
            for ocr_dir in [args.out_dir / "ocr_text" / src.name for src in args.sources]
            if (args.out_dir / "ocr_text" / src.name).exists()
        }
        for future in as_completed(futures):
            ocr_src = futures[future]
            try:
                _, count = future.result()
                dedup_results[ocr_src] = count
            except Exception as e:
                print(f"Exception in text deduplication for {ocr_src}: {e}", file=sys.stderr)

    # Summary
    print("\n--- Summary ---")
    print("Frame Selection Results:")
    for src, count in frame_results.items():
        print(f"  {src.name}: {count} frames selected")

    print("OCR Results:")
    for src, count in ocr_results.items():
        print(f"  {src.name}: {count} frames OCR'd")

    print("Text Deduplication Results:")
    for ocr_src, count in dedup_results.items():
        print(f"  {ocr_src.name}: {count} files deduped")

    print(f"Results saved to {args.out_dir}")
    return 0


if __name__ == "__main__":
    sys.exit(main())
