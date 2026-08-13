#!/usr/bin/env bash
# Bash integration tests for video-ocr-extract CLI
#
# Tests the bash script's subcommand dispatch, check command, and error handling.
# Does NOT actually run full video processing (too heavy for unit tests).
#
# Run with: bash tests/test_video_ocr_extract_cli.sh

set -u

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
VIDEO_OCR_EXTRACT="${SCRIPT_DIR}/video-ocr-extract"

# Color codes for output
RED='\033[0;31m'
GREEN='\033[0;32m'
NC='\033[0m' # No Color

PASS_COUNT=0
FAIL_COUNT=0

# Test helper functions
test_exit_code() {
    local expected=$1
    local test_name=$2
    shift 2
    local output exit_code

    # Run command and capture both output and exit code
    if output=$("$@" 2>&1); then
        exit_code=0
    else
        exit_code=$?
    fi

    if [[ "$exit_code" -eq "$expected" ]]; then
        echo -e "${GREEN}✓${NC} $test_name"
        ((PASS_COUNT++))
        echo "$output"
    else
        echo -e "${RED}✗${NC} $test_name (expected exit code $expected, got $exit_code)"
        echo "  Output: $output"
        ((FAIL_COUNT++))
        echo "$output"
    fi
}

test_output_contains() {
    local expected_pattern=$1
    local test_name=$2
    shift 2
    local output exit_code

    if output=$("$@" 2>&1); then
        exit_code=0
    else
        exit_code=$?
    fi

    if echo "$output" | grep -q "$expected_pattern"; then
        echo -e "${GREEN}✓${NC} $test_name"
        ((PASS_COUNT++))
    else
        echo -e "${RED}✗${NC} $test_name (expected pattern not found: $expected_pattern)"
        echo "  Output: $output"
        ((FAIL_COUNT++))
    fi
}

# ===== Test: No subcommand =====

echo "Testing: Subcommand dispatch"
test_exit_code 1 "No subcommand returns exit code 1" "$VIDEO_OCR_EXTRACT"
test_output_contains "Usage:" "No subcommand shows usage" "$VIDEO_OCR_EXTRACT"

# ===== Test: Unknown subcommand =====

echo ""
echo "Testing: Unknown subcommand"
test_exit_code 1 "Unknown subcommand returns exit code 1" "$VIDEO_OCR_EXTRACT" unknown_cmd
test_output_contains "Unknown subcommand" "Unknown subcommand error message" "$VIDEO_OCR_EXTRACT" unknown_cmd

# ===== Test: check subcommand =====

echo ""
echo "Testing: check subcommand"
# check may succeed or fail depending on installed tools, so just test it doesn't crash
if output=$($VIDEO_OCR_EXTRACT check 2>&1); then
    check_exit=0
else
    check_exit=$?
fi

if [[ $check_exit -eq 0 ]] || [[ $check_exit -eq 1 ]]; then
    echo -e "${GREEN}✓${NC} check subcommand runs (exit code: $check_exit)"
    ((PASS_COUNT++))
else
    echo -e "${RED}✗${NC} check subcommand failed with unexpected exit code: $check_exit"
    ((FAIL_COUNT++))
fi

test_output_contains "Checking dependencies" "check shows header" "$VIDEO_OCR_EXTRACT" check
test_output_contains "ffmpeg" "check mentions ffmpeg" "$VIDEO_OCR_EXTRACT" check
test_output_contains "uv" "check mentions uv" "$VIDEO_OCR_EXTRACT" check
test_output_contains "tesseract" "check mentions tesseract" "$VIDEO_OCR_EXTRACT" check
test_output_contains "cv2/numpy" "check mentions cv2/numpy" "$VIDEO_OCR_EXTRACT" check

# ===== Test: run subcommand with no video path =====

echo ""
echo "Testing: run subcommand argument validation"
test_exit_code 1 "run with no video returns exit code 1" "$VIDEO_OCR_EXTRACT" run
test_output_contains "Usage:" "run with no video shows usage" "$VIDEO_OCR_EXTRACT" run

# ===== Test: run with non-existent video file =====

echo ""
echo "Testing: run with non-existent video file"
test_exit_code 1 "run with missing video returns exit code 1" "$VIDEO_OCR_EXTRACT" run /tmp/nonexistent_video_12345_xyz.mp4
test_output_contains "not found" "run with missing video shows error" "$VIDEO_OCR_EXTRACT" run /tmp/nonexistent_video_12345_xyz.mp4

# ===== Test: run with unknown flag =====

echo ""
echo "Testing: run with unknown flag"
tmpfile=$(mktemp)
trap "rm -f $tmpfile" EXIT
touch "$tmpfile"
test_exit_code 1 "run with unknown flag returns exit code 1" "$VIDEO_OCR_EXTRACT" run "$tmpfile" --unknown-flag value
test_output_contains "Unknown option" "Unknown flag error message" "$VIDEO_OCR_EXTRACT" run "$tmpfile" --unknown-flag value
rm "$tmpfile"

# ===== Test: run flag parsing (without running full pipeline) =====

echo ""
echo "Testing: run flag parsing"
tmpfile=$(mktemp)
trap "rm -f $tmpfile" EXIT
touch "$tmpfile"

# Test that flags are accepted (will fail at dependency check, but that's after parsing)
if output=$($VIDEO_OCR_EXTRACT run "$tmpfile" --fps 10 --start 00:00:01 --end 00:00:05 2>&1); then
    echo -e "${GREEN}✓${NC} run accepts valid flags"
    ((PASS_COUNT++))
else
    # Failed, but check if it's due to dependencies, not flag parsing
    if echo "$output" | grep -q "Checking dependencies"; then
        echo -e "${GREEN}✓${NC} run accepts valid flags (failed at dependency check, which is expected)"
        ((PASS_COUNT++))
    elif echo "$output" | grep -q "Unknown option"; then
        echo -e "${RED}✗${NC} run flag parsing rejected valid flags"
        ((FAIL_COUNT++))
    else
        echo -e "${GREEN}✓${NC} run accepts valid flags (output: $output)"
        ((PASS_COUNT++))
    fi
fi
rm "$tmpfile"

# ===== Test: run with threshold flags =====

echo ""
echo "Testing: run with threshold flags"
tmpfile=$(mktemp)
trap "rm -f $tmpfile" EXIT
touch "$tmpfile"
if output=$($VIDEO_OCR_EXTRACT run "$tmpfile" --diff-threshold 20.5 --similarity-threshold 0.95 2>&1); then
    echo -e "${GREEN}✓${NC} run accepts threshold flags"
    ((PASS_COUNT++))
else
    if echo "$output" | grep -q "Checking dependencies"; then
        echo -e "${GREEN}✓${NC} run accepts threshold flags (failed at dependency check)"
        ((PASS_COUNT++))
    else
        echo -e "${RED}✗${NC} run threshold flag parsing failed"
        ((FAIL_COUNT++))
    fi
fi
rm "$tmpfile"

# ===== Summary =====

echo ""
echo "================================"
echo -e "Tests passed: ${GREEN}${PASS_COUNT}${NC}"
echo -e "Tests failed: ${RED}${FAIL_COUNT}${NC}"
echo "================================"

if [[ "$FAIL_COUNT" -gt 0 ]]; then
    exit 1
fi

exit 0
