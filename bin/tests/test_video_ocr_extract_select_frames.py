"""
Pytest tests for video-ocr-extract-select-frames.py

Strategy: This script uses PEP 723 shebangs and is not directly importable.
We invoke it via subprocess (uv run) to test integration, and use direct
function testing via importlib.util for unit tests on core logic.

For sharpness_score and frame_diff, we create synthetic PNG images in temp
directories using cv2/numpy. For group_into_scenes, we test directly by
importing the module via spec_from_file_location.
"""

import importlib.util
import subprocess
import sys
import tempfile
from pathlib import Path
from unittest.mock import patch

import cv2
import numpy as np
import pytest


# Load the script module dynamically (PEP 723 script with shebang)
SCRIPT_PATH = Path(__file__).parent.parent / "video-ocr-extract-select-frames.py"


def load_script_module():
    """Load the PEP 723 script as a module for unit testing core functions."""
    spec = importlib.util.spec_from_file_location("select_frames", SCRIPT_PATH)
    module = importlib.util.module_from_spec(spec)
    sys.modules["select_frames"] = module
    spec.loader.exec_module(module)
    return module


# ===== Unit Tests (direct function testing) =====


class TestSharpnessScore:
    """Test the sharpness_score function (Laplacian variance)."""

    def test_sharpness_score_sharp_image(self, tmp_path):
        """A sharp image (high variance) should score higher than a blurry one."""
        module = load_script_module()

        # Create a sharp image: checkerboard pattern (high-frequency content)
        sharp = np.zeros((100, 100), dtype=np.uint8)
        sharp[::2, ::2] = 255
        sharp[1::2, 1::2] = 255
        sharp_path = tmp_path / "sharp.png"
        cv2.imwrite(str(sharp_path), sharp)

        # Create a blurry image: mostly uniform with slight gradient
        blurry = np.ones((100, 100), dtype=np.uint8) * 128
        blurry_path = tmp_path / "blurry.png"
        cv2.imwrite(str(blurry_path), blurry)

        sharp_score = module.sharpness_score(sharp_path)
        blurry_score = module.sharpness_score(blurry_path)

        assert sharp_score > blurry_score
        assert sharp_score > 0

    def test_sharpness_score_uniform_image(self, tmp_path):
        """A completely uniform image should have zero (or near-zero) variance."""
        module = load_script_module()

        uniform = np.ones((50, 50), dtype=np.uint8) * 200
        path = tmp_path / "uniform.png"
        cv2.imwrite(str(path), uniform)

        score = module.sharpness_score(path)
        assert score >= 0  # Laplacian of uniform is 0

    def test_sharpness_score_missing_file(self, tmp_path):
        """Reading a non-existent file should return -1.0."""
        module = load_script_module()
        score = module.sharpness_score(tmp_path / "does_not_exist.png")
        assert score == -1.0


class TestFrameDiff:
    """Test the frame_diff function (mean pixel difference)."""

    def test_frame_diff_identical(self, tmp_path):
        """Identical images should have zero difference."""
        module = load_script_module()

        img = np.ones((50, 50), dtype=np.uint8) * 100
        path1 = tmp_path / "img1.png"
        path2 = tmp_path / "img2.png"
        cv2.imwrite(str(path1), img)
        cv2.imwrite(str(path2), img)

        diff = module.frame_diff(path1, path2)
        assert diff == 0.0

    def test_frame_diff_completely_different(self, tmp_path):
        """Images with opposite colors should have high difference."""
        module = load_script_module()

        img1 = np.zeros((50, 50), dtype=np.uint8)
        img2 = np.ones((50, 50), dtype=np.uint8) * 255
        path1 = tmp_path / "img1.png"
        path2 = tmp_path / "img2.png"
        cv2.imwrite(str(path1), img1)
        cv2.imwrite(str(path2), img2)

        diff = module.frame_diff(path1, path2)
        assert diff > 200  # Should be close to 255

    def test_frame_diff_shape_mismatch(self, tmp_path):
        """Images with different shapes should be treated as a hard scene break (255.0)."""
        module = load_script_module()

        img1 = np.zeros((50, 50), dtype=np.uint8)
        img2 = np.zeros((100, 100), dtype=np.uint8)
        path1 = tmp_path / "img1.png"
        path2 = tmp_path / "img2.png"
        cv2.imwrite(str(path1), img1)
        cv2.imwrite(str(path2), img2)

        diff = module.frame_diff(path1, path2)
        assert diff == 255.0

    def test_frame_diff_missing_file(self, tmp_path):
        """Missing file should return 0.0 (no diff to measure)."""
        module = load_script_module()

        img = np.zeros((50, 50), dtype=np.uint8)
        path1 = tmp_path / "exists.png"
        path2 = tmp_path / "does_not_exist.png"
        cv2.imwrite(str(path1), img)

        diff = module.frame_diff(path1, path2)
        assert diff == 0.0


class TestGroupIntoScenes:
    """Test the group_into_scenes function (scene grouping logic)."""

    def test_group_into_scenes_single_group(self, tmp_path):
        """Frames with small differences should all be in one group."""
        module = load_script_module()

        # Create 5 nearly identical frames
        frames = []
        base = np.ones((50, 50), dtype=np.uint8) * 100
        for i in range(5):
            # Add tiny variation
            img = base.copy().astype(float)
            img += np.random.randn(50, 50) * 2
            img = np.clip(img, 0, 255).astype(np.uint8)
            path = tmp_path / f"frame_{i:03d}.png"
            cv2.imwrite(str(path), img)
            frames.append(path)

        groups = module.group_into_scenes(frames, diff_threshold=10.0)

        assert len(groups) == 1
        assert len(groups[0]) == 5

    def test_group_into_scenes_multiple_groups(self, tmp_path):
        """Frames with large differences should be in separate groups."""
        module = load_script_module()

        frames = []

        # Group 1: dark frames
        for i in range(3):
            img = np.ones((50, 50), dtype=np.uint8) * 50
            path = tmp_path / f"frame_{i:03d}.png"
            cv2.imwrite(str(path), img)
            frames.append(path)

        # Group 2: bright frames (large diff causes scene break)
        for i in range(3, 6):
            img = np.ones((50, 50), dtype=np.uint8) * 200
            path = tmp_path / f"frame_{i:03d}.png"
            cv2.imwrite(str(path), img)
            frames.append(path)

        groups = module.group_into_scenes(frames, diff_threshold=50.0)

        assert len(groups) == 2
        assert len(groups[0]) == 3
        assert len(groups[1]) == 3

    def test_group_into_scenes_low_threshold(self, tmp_path):
        """Very low threshold should create many groups."""
        module = load_script_module()

        frames = []
        for i in range(5):
            img = np.ones((50, 50), dtype=np.uint8) * (50 + i * 10)
            path = tmp_path / f"frame_{i:03d}.png"
            cv2.imwrite(str(path), img)
            frames.append(path)

        groups = module.group_into_scenes(frames, diff_threshold=1.0)

        # With low threshold, we should get multiple groups
        assert len(groups) > 1


# ===== Integration Tests (subprocess-based) =====


class TestSelectFramesIntegration:
    """Integration tests invoking the script via subprocess."""

    def test_main_success(self, tmp_path):
        """Happy path: create frames, run script, check output."""
        frames_dir = tmp_path / "frames"
        out_dir = tmp_path / "best_frames"
        frames_dir.mkdir()

        # Create a few test frames
        for i in range(3):
            img = np.ones((50, 50), dtype=np.uint8) * (100 + i * 20)
            path = frames_dir / f"frame_{i:03d}.png"
            cv2.imwrite(str(path), img)

        cmd = [
            "uv",
            "run",
            str(SCRIPT_PATH),
            str(frames_dir),
            "--out",
            str(out_dir),
            "--diff-threshold",
            "50.0",
        ]
        result = subprocess.run(cmd, capture_output=True, text=True)

        assert result.returncode == 0
        assert "Grouped" in result.stdout
        assert "Selected" in result.stdout

        # Check that best_frames directory was created and has files
        assert out_dir.exists()
        best_files = list(out_dir.glob("*.png"))
        assert len(best_files) > 0

    def test_main_no_frames_found(self, tmp_path):
        """No matching frames in directory should return error."""
        frames_dir = tmp_path / "empty_frames"
        frames_dir.mkdir()
        out_dir = tmp_path / "best_frames"

        cmd = [
            "uv",
            "run",
            str(SCRIPT_PATH),
            str(frames_dir),
            "--out",
            str(out_dir),
            "--pattern",
            "*.png",
        ]
        result = subprocess.run(cmd, capture_output=True, text=True)

        assert result.returncode == 1
        assert "No frames matching" in result.stderr

    def test_main_custom_pattern(self, tmp_path):
        """Test with custom file pattern (e.g., jpg instead of png)."""
        frames_dir = tmp_path / "frames"
        out_dir = tmp_path / "best_frames"
        frames_dir.mkdir()

        # Create a jpg file
        img = np.ones((50, 50), dtype=np.uint8) * 100
        path = frames_dir / "frame_001.jpg"
        cv2.imwrite(str(path), img)

        cmd = [
            "uv",
            "run",
            str(SCRIPT_PATH),
            str(frames_dir),
            "--out",
            str(out_dir),
            "--pattern",
            "*.jpg",
        ]
        result = subprocess.run(cmd, capture_output=True, text=True)

        assert result.returncode == 0
        best_files = list(out_dir.glob("*.jpg"))
        assert len(best_files) == 1

    def test_main_missing_frames_dir(self, tmp_path):
        """Non-existent frames directory should fail."""
        frames_dir = tmp_path / "nonexistent"
        out_dir = tmp_path / "best_frames"

        cmd = [
            "uv",
            "run",
            str(SCRIPT_PATH),
            str(frames_dir),
            "--out",
            str(out_dir),
        ]
        result = subprocess.run(cmd, capture_output=True, text=True)

        # The script will fail because glob won't find anything
        assert result.returncode == 1
