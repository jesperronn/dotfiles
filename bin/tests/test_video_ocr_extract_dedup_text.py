"""
Pytest tests for video-ocr-extract-dedup-text.py

Strategy: Similar to the select_frames tests, this script uses PEP 723 shebangs.
We test core logic via importlib.util for unit tests (similarity function),
and integration tests via subprocess for the full main() flow.

For dedup tests, we create temporary .txt files with various similarity ratios.
"""

import importlib.util
import subprocess
import sys
import tempfile
from pathlib import Path

import pytest


# Load the script module dynamically
SCRIPT_PATH = Path(__file__).parent.parent / "video-ocr-extract-dedup-text.py"


def load_script_module():
    """Load the PEP 723 script as a module for unit testing."""
    spec = importlib.util.spec_from_file_location("dedup_text", SCRIPT_PATH)
    module = importlib.util.module_from_spec(spec)
    sys.modules["dedup_text"] = module
    spec.loader.exec_module(module)
    return module


# ===== Unit Tests (direct function testing) =====


class TestSimilarity:
    """Test the similarity function (SequenceMatcher ratio)."""

    def test_similarity_identical_strings(self):
        """Identical strings should have similarity = 1.0."""
        module = load_script_module()
        sim = module.similarity("hello world", "hello world")
        assert sim == 1.0

    def test_similarity_completely_different(self):
        """Completely different strings should have low similarity."""
        module = load_script_module()
        sim = module.similarity("abc", "xyz")
        assert sim < 0.5

    def test_similarity_empty_strings(self):
        """Two empty strings should have similarity = 1.0."""
        module = load_script_module()
        sim = module.similarity("", "")
        assert sim == 1.0

    def test_similarity_one_empty(self):
        """Empty vs. non-empty should have similarity = 0.0."""
        module = load_script_module()
        sim = module.similarity("", "hello")
        assert sim == 0.0

    def test_similarity_partial_overlap(self):
        """Partially overlapping strings should have intermediate similarity."""
        module = load_script_module()
        # These share "hello" in common
        sim1 = module.similarity("hello world", "hello there")
        # These are completely different
        sim2 = module.similarity("abc", "def")
        assert sim1 > sim2

    def test_similarity_case_sensitive(self):
        """Similarity is case-sensitive."""
        module = load_script_module()
        sim_same = module.similarity("Hello", "Hello")
        sim_diff = module.similarity("Hello", "hello")
        assert sim_same == 1.0
        assert sim_diff < 1.0


# ===== Integration Tests (subprocess-based) =====


class TestDedupTextIntegration:
    """Integration tests invoking the dedup script via subprocess."""

    def test_main_no_duplicates(self, tmp_path):
        """When all texts are unique, all should be kept."""
        ocr_dir = tmp_path / "ocr"
        out_dir = tmp_path / "deduped"
        ocr_dir.mkdir()

        # Create three unique text files
        texts = [
            "Frame 1: This is unique text",
            "Frame 2: Completely different content here",
            "Frame 3: Another distinct piece of text",
        ]
        for i, text in enumerate(texts):
            path = ocr_dir / f"frame_{i:03d}.txt"
            path.write_text(text)

        cmd = [
            "uv",
            "run",
            str(SCRIPT_PATH),
            str(ocr_dir),
            "--out",
            str(out_dir),
            "--similarity-threshold",
            "0.9",
        ]
        result = subprocess.run(cmd, capture_output=True, text=True)

        assert result.returncode == 0
        assert "3 OCR files -> 3 unique" in result.stdout

        # Check files were copied (exclude deduped.txt which is the combined file)
        kept_files = [f for f in out_dir.glob("*.txt") if f.name != "deduped.txt"]
        assert len(kept_files) == 3

        # Check combined file
        combined = out_dir / "deduped.txt"
        assert combined.exists()
        combined_text = combined.read_text()
        assert "frame_000.txt" in combined_text
        assert "frame_001.txt" in combined_text
        assert "frame_002.txt" in combined_text

    def test_main_with_duplicates(self, tmp_path):
        """When some texts are very similar, duplicates should be removed."""
        ocr_dir = tmp_path / "ocr"
        out_dir = tmp_path / "deduped"
        ocr_dir.mkdir()

        # Create files: first two are nearly identical, third is unique
        texts = [
            "The quick brown fox jumps over the lazy dog",
            "The quick brown fox jumps over the lazy dog.",  # 99% similar
            "Completely different text here at the end",
        ]
        for i, text in enumerate(texts):
            path = ocr_dir / f"frame_{i:03d}.txt"
            path.write_text(text)

        cmd = [
            "uv",
            "run",
            str(SCRIPT_PATH),
            str(ocr_dir),
            "--out",
            str(out_dir),
            "--similarity-threshold",
            "0.9",
        ]
        result = subprocess.run(cmd, capture_output=True, text=True)

        assert result.returncode == 0
        # Should keep 2 (first and third), drop the second (similar to first)
        assert "3 OCR files -> 2 unique" in result.stdout

        kept_files = sorted([f for f in out_dir.glob("*.txt") if f.name != "deduped.txt"])
        assert len(kept_files) == 2
        # First file should always be kept
        assert "frame_000.txt" in [f.name for f in kept_files]

    def test_main_empty_directory(self, tmp_path):
        """Empty directory should return error."""
        ocr_dir = tmp_path / "empty_ocr"
        out_dir = tmp_path / "deduped"
        ocr_dir.mkdir()

        cmd = [
            "uv",
            "run",
            str(SCRIPT_PATH),
            str(ocr_dir),
            "--out",
            str(out_dir),
        ]
        result = subprocess.run(cmd, capture_output=True, text=True)

        assert result.returncode == 1
        assert "No files matching" in result.stderr

    def test_main_custom_pattern(self, tmp_path):
        """Test with custom file pattern (not .txt)."""
        ocr_dir = tmp_path / "ocr"
        out_dir = tmp_path / "deduped"
        ocr_dir.mkdir()

        # Create .log files instead of .txt (make them clearly different)
        texts = ["Configuration Settings Alpha", "Runtime Metrics Beta"]
        for i, text in enumerate(texts):
            path = ocr_dir / f"log_{i}.log"
            path.write_text(text)

        cmd = [
            "uv",
            "run",
            str(SCRIPT_PATH),
            str(ocr_dir),
            "--out",
            str(out_dir),
            "--pattern",
            "*.log",
        ]
        result = subprocess.run(cmd, capture_output=True, text=True)

        assert result.returncode == 0
        kept_files = list(out_dir.glob("*.log"))
        assert len(kept_files) == 2

    def test_main_deduped_txt_contains_headers(self, tmp_path):
        """The combined deduped.txt should contain # --- filename --- headers."""
        ocr_dir = tmp_path / "ocr"
        out_dir = tmp_path / "deduped"
        ocr_dir.mkdir()

        texts = ["Text A", "Text B"]
        for i, text in enumerate(texts):
            path = ocr_dir / f"frame_{i:03d}.txt"
            path.write_text(text)

        cmd = [
            "uv",
            "run",
            str(SCRIPT_PATH),
            str(ocr_dir),
            "--out",
            str(out_dir),
        ]
        result = subprocess.run(cmd, capture_output=True, text=True)

        assert result.returncode == 0

        combined = out_dir / "deduped.txt"
        combined_text = combined.read_text()

        # Check for headers
        assert "# --- frame_000.txt ---" in combined_text
        assert "# --- frame_001.txt ---" in combined_text
        # Check content is there
        assert "Text A" in combined_text
        assert "Text B" in combined_text

    def test_main_threshold_edge_case(self, tmp_path):
        """Test similarity threshold edge cases."""
        ocr_dir = tmp_path / "ocr"
        out_dir = tmp_path / "deduped"
        ocr_dir.mkdir()

        # Create two very similar texts
        text1 = "The quick brown fox"
        text2 = "The quick brown fox"  # Identical

        path1 = ocr_dir / "frame_000.txt"
        path2 = ocr_dir / "frame_001.txt"
        path1.write_text(text1)
        path2.write_text(text2)

        # With threshold 0.99, identical should be treated as duplicate
        cmd = [
            "uv",
            "run",
            str(SCRIPT_PATH),
            str(ocr_dir),
            "--out",
            str(out_dir),
            "--similarity-threshold",
            "0.99",
        ]
        result = subprocess.run(cmd, capture_output=True, text=True)

        assert result.returncode == 0
        assert "2 OCR files -> 1 unique" in result.stdout

    def test_main_keeps_first_occurrence(self, tmp_path):
        """Dedup should keep the first occurrence of a duplicate group."""
        ocr_dir = tmp_path / "ocr"
        out_dir = tmp_path / "deduped"
        ocr_dir.mkdir()

        # Create three nearly identical texts
        texts = [
            "Alpha content",
            "Alpha content.",  # Same as first
            "Alpha content!",  # Also nearly same
        ]
        for i, text in enumerate(texts):
            path = ocr_dir / f"frame_{i:03d}.txt"
            path.write_text(text)

        cmd = [
            "uv",
            "run",
            str(SCRIPT_PATH),
            str(ocr_dir),
            "--out",
            str(out_dir),
            "--similarity-threshold",
            "0.85",
        ]
        result = subprocess.run(cmd, capture_output=True, text=True)

        assert result.returncode == 0

        # Should keep only the first one (exclude deduped.txt)
        kept_files = sorted([f for f in out_dir.glob("*.txt") if f.name != "deduped.txt"])
        assert len(kept_files) == 1
        assert kept_files[0].name == "frame_000.txt"

    def test_main_preserves_file_content(self, tmp_path):
        """Deduped files should have original content preserved."""
        ocr_dir = tmp_path / "ocr"
        out_dir = tmp_path / "deduped"
        ocr_dir.mkdir()

        original_text = "Important OCR result with special chars: @#$%^&*()"
        path = ocr_dir / "frame_000.txt"
        path.write_text(original_text)

        cmd = [
            "uv",
            "run",
            str(SCRIPT_PATH),
            str(ocr_dir),
            "--out",
            str(out_dir),
        ]
        result = subprocess.run(cmd, capture_output=True, text=True)

        assert result.returncode == 0

        # Check the copied file
        copied = out_dir / "frame_000.txt"
        assert copied.read_text() == original_text
