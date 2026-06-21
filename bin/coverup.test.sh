#!/usr/bin/env bash
# shellcheck disable=SC1090,SC1091

set -euo pipefail

DOTFILES_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
COVERUP_BIN="$DOTFILES_ROOT/bin/coverup"

source "$DOTFILES_ROOT/bin/lib/bash_test.sh"

TEST_TMP_DIR=""

setup_tmpdir() {
  TEST_TMP_DIR="$(mktemp -d)"
  trap 'rm -rf "$TEST_TMP_DIR"' EXIT
}

# Write a synthetic JaCoCo XML with three source files:
#   com/example/alpha/FullyCovered.java    — 0 missed lines, 0 missed branches (100%)
#   com/example/alpha/PartialCoverage.java — 30 missed lines, 5 missed branches (70%)
#   com/example/beta/NoCoverage.java       — 50 missed lines, 10 missed branches (0%)
write_fixture() {
  local dir="$1"
  mkdir -p "$dir/target/site/jacoco"
  cat > "$dir/target/site/jacoco/jacoco.xml" <<'XML'
<?xml version="1.0" encoding="UTF-8"?>
<report name="test">
  <package name="com/example/alpha">
    <sourcefile name="FullyCovered.java">
      <counter type="INSTRUCTION" missed="0" covered="100"/>
      <counter type="BRANCH" missed="0" covered="20"/>
    </sourcefile>
    <sourcefile name="PartialCoverage.java">
      <counter type="INSTRUCTION" missed="30" covered="70"/>
      <counter type="BRANCH" missed="5" covered="15"/>
    </sourcefile>
  </package>
  <package name="com/example/beta">
    <sourcefile name="NoCoverage.java">
      <counter type="INSTRUCTION" missed="50" covered="0"/>
      <counter type="BRANCH" missed="10" covered="0"/>
    </sourcefile>
  </package>
</report>
XML
}

test_help_exits_zero() {
  local output="" status=0
  capture_command output status "$COVERUP_BIN" --help
  assert_status "0" "$status" "--help exits 0"
  assert_contains "$output" "Usage: coverup" "--help shows usage"
  assert_contains "$output" "--sort" "--help mentions --sort"
  assert_contains "$output" "--verbose" "--help mentions --verbose"
  assert_contains "$output" "-- <path-filter>" "--help mentions path filter"
}

test_default_hides_fully_covered_files() {
  local fixture_dir="$TEST_TMP_DIR/default-hide"
  write_fixture "$fixture_dir"
  local output="" status=0
  capture_command output status "$COVERUP_BIN" --root "$fixture_dir"
  assert_status "0" "$status" "exits 0 in default mode"
  assert_not_contains "$output" "FullyCovered.java" "fully-covered file hidden by default"
  assert_contains "$output" "PartialCoverage.java" "partial-coverage file shown"
  assert_contains "$output" "NoCoverage.java" "no-coverage file shown"
}

test_default_footer_mentions_verbose() {
  local fixture_dir="$TEST_TMP_DIR/footer-verbose"
  write_fixture "$fixture_dir"
  local output="" status=0
  capture_command output status "$COVERUP_BIN" --root "$fixture_dir"
  assert_status "0" "$status" "exits 0"
  assert_contains "$output" "1 file(s) fully covered" "footer mentions fully-covered count"
  assert_contains "$output" "--verbose" "footer suggests --verbose"
}

test_default_footer_shows_gap_totals() {
  local fixture_dir="$TEST_TMP_DIR/gap-totals"
  write_fixture "$fixture_dir"
  local output="" status=0
  capture_command output status "$COVERUP_BIN" --root "$fixture_dir"
  assert_status "0" "$status" "exits 0"
  # missed lines: 30 + 50 = 80; missed branches: 5 + 10 = 15
  assert_contains "$output" "80 missed lines" "footer shows 80 missed lines"
  assert_contains "$output" "15 missed branches" "footer shows 15 missed branches"
  assert_contains "$output" "2 file(s) with gaps" "footer shows 2 files with gaps"
}

test_verbose_shows_all_files() {
  local fixture_dir="$TEST_TMP_DIR/verbose-all"
  write_fixture "$fixture_dir"
  local output="" status=0
  capture_command output status "$COVERUP_BIN" --root "$fixture_dir" --verbose
  assert_status "0" "$status" "--verbose exits 0"
  assert_contains "$output" "FullyCovered.java" "--verbose shows fully-covered file"
  assert_contains "$output" "PartialCoverage.java" "--verbose shows partial-coverage file"
  assert_contains "$output" "NoCoverage.java" "--verbose shows no-coverage file"
}

test_verbose_shows_checkmark_for_fully_covered() {
  local fixture_dir="$TEST_TMP_DIR/verbose-checkmark"
  write_fixture "$fixture_dir"
  local output="" status=0
  capture_command output status "$COVERUP_BIN" --root "$fixture_dir" --verbose
  assert_status "0" "$status" "--verbose exits 0"
  assert_contains "$output" "✅" "checkmark shown for fully-covered file in --verbose"
}

test_verbose_shows_jacoco_files_found() {
  local fixture_dir="$TEST_TMP_DIR/verbose-debug"
  write_fixture "$fixture_dir"
  local output="" status=0
  capture_command output status "$COVERUP_BIN" --root "$fixture_dir" --verbose
  assert_status "0" "$status" "--verbose exits 0"
  assert_contains "$output" "Scanning:" "--verbose shows scanning header"
  assert_contains "$output" "jacoco.xml" "--verbose lists jacoco.xml file found"
}

test_verbose_footer_shows_full_summary() {
  local fixture_dir="$TEST_TMP_DIR/verbose-footer"
  write_fixture "$fixture_dir"
  local output="" status=0
  capture_command output status "$COVERUP_BIN" --root "$fixture_dir" --verbose
  assert_status "0" "$status" "--verbose exits 0"
  assert_contains "$output" "3 file(s) total" "--verbose footer shows total file count"
  assert_contains "$output" "2 with gaps" "--verbose footer shows gap count"
  assert_contains "$output" "1 fully covered" "--verbose footer shows fully-covered count"
}

test_path_filter_includes_matching_files() {
  local fixture_dir="$TEST_TMP_DIR/filter-include"
  write_fixture "$fixture_dir"
  local output="" status=0
  # alpha has FullyCovered (hidden) and PartialCoverage (shown), so 1 with gaps + 1 fully covered
  capture_command output status "$COVERUP_BIN" --root "$fixture_dir" -- alpha
  assert_status "0" "$status" "path filter exits 0"
  assert_contains "$output" "PartialCoverage.java" "alpha filter includes PartialCoverage.java"
  assert_not_contains "$output" "NoCoverage.java" "alpha filter excludes beta/NoCoverage.java"
}

test_path_filter_excludes_non_matching() {
  local fixture_dir="$TEST_TMP_DIR/filter-exclude"
  write_fixture "$fixture_dir"
  local output="" status=0
  capture_command output status "$COVERUP_BIN" --root "$fixture_dir" -- beta
  assert_status "0" "$status" "beta filter exits 0"
  assert_not_contains "$output" "FullyCovered.java" "beta filter excludes alpha files"
  assert_contains "$output" "NoCoverage.java" "beta filter includes NoCoverage.java"
  assert_contains "$output" "1 file(s) with gaps" "footer shows 1 file with gaps"
}

test_sort_percentage_worst_first() {
  local fixture_dir="$TEST_TMP_DIR/sort-pct"
  write_fixture "$fixture_dir"
  local output="" status=0
  # In default mode only NoCoverage and PartialCoverage are shown; NoCoverage (0%) must be first
  capture_command output status "$COVERUP_BIN" --root "$fixture_dir" --sort percentage
  assert_status "0" "$status" "--sort percentage exits 0"
  local nc_line pc_line
  nc_line=$(echo "$output" | grep -n "NoCoverage" | cut -d: -f1)
  pc_line=$(echo "$output" | grep -n "PartialCoverage" | cut -d: -f1)
  if [[ "$nc_line" -lt "$pc_line" ]]; then
    test_pass "NoCoverage (0%) appears before PartialCoverage (70%) with --sort percentage"
  else
    test_fail "NoCoverage (0%) should appear before PartialCoverage (70%) with --sort percentage"
  fi
}

test_sort_lines_highest_missed_first() {
  local fixture_dir="$TEST_TMP_DIR/sort-lines"
  write_fixture "$fixture_dir"
  local output="" status=0
  capture_command output status "$COVERUP_BIN" --root "$fixture_dir" --sort lines
  assert_status "0" "$status" "--sort lines exits 0"
  local nc_line pc_line
  nc_line=$(echo "$output" | grep -n "NoCoverage" | cut -d: -f1)
  pc_line=$(echo "$output" | grep -n "PartialCoverage" | cut -d: -f1)
  if [[ "$nc_line" -lt "$pc_line" ]]; then
    test_pass "NoCoverage (50 missed lines) appears before PartialCoverage (30) with --sort lines"
  else
    test_fail "NoCoverage (50 missed lines) should appear before PartialCoverage (30) with --sort lines"
  fi
}

test_sort_branches_highest_missed_first() {
  local fixture_dir="$TEST_TMP_DIR/sort-branches"
  write_fixture "$fixture_dir"
  local output="" status=0
  capture_command output status "$COVERUP_BIN" --root "$fixture_dir" --sort branches
  assert_status "0" "$status" "--sort branches exits 0"
  local nc_line pc_line
  nc_line=$(echo "$output" | grep -n "NoCoverage" | cut -d: -f1)
  pc_line=$(echo "$output" | grep -n "PartialCoverage" | cut -d: -f1)
  if [[ "$nc_line" -lt "$pc_line" ]]; then
    test_pass "NoCoverage (10 missed branches) appears before PartialCoverage (5) with --sort branches"
  else
    test_fail "NoCoverage (10 missed branches) should appear before PartialCoverage (5) with --sort branches"
  fi
}

test_sort_total_default_highest_first() {
  local fixture_dir="$TEST_TMP_DIR/sort-total"
  write_fixture "$fixture_dir"
  local output="" status=0
  capture_command output status "$COVERUP_BIN" --root "$fixture_dir" --sort total
  assert_status "0" "$status" "--sort total exits 0"
  local nc_line pc_line
  nc_line=$(echo "$output" | grep -n "NoCoverage" | cut -d: -f1)
  pc_line=$(echo "$output" | grep -n "PartialCoverage" | cut -d: -f1)
  if [[ "$nc_line" -lt "$pc_line" ]]; then
    test_pass "NoCoverage (60 total missed) appears before PartialCoverage (35) with --sort total"
  else
    test_fail "NoCoverage (60 total missed) should appear before PartialCoverage (35) with --sort total"
  fi
}

test_partial_coverage_no_checkmark() {
  local fixture_dir="$TEST_TMP_DIR/no-checkmark"
  write_fixture "$fixture_dir"
  local output="" status=0
  capture_command output status "$COVERUP_BIN" --root "$fixture_dir" -- PartialCoverage
  assert_status "0" "$status" "partial coverage exits 0"
  assert_not_contains "$output" "✅" "no checkmark for partially-covered file"
}

setup_tmpdir
run_tests "$@"
