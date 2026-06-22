#!/usr/bin/env bash
# shellcheck disable=SC1090,SC1091

set -euo pipefail

DOTFILES_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
BIN="$DOTFILES_ROOT/bin/copilot-leaderboard"

source "$DOTFILES_ROOT/bin/lib/bash_test.sh"

TEST_TMP_DIR=""

setup_tmpdir() {
  TEST_TMP_DIR="$(mktemp -d)"
  trap 'rm -rf "$TEST_TMP_DIR"' EXIT
}

# Fixture: 3 users over 3 days in June 2026, metric = floor(ai_credits_used)
# alice:   100.9→100 | 50.7→50  | 20.3→20  | total=170
# bob:     80.1→80   | 60.5→60  | 40.9→40  | total=180
# charlie: 10.2→10   | 5.8→5    | (no day3) | total=15
# All total: 365 | avg per seat: 121.7
write_fixture() {
  local dir="$1"
  mkdir -p "$dir/archive"
  cat > "$dir/archive/2026-06-10.ndjson" <<'NDJSON'
{"user_login":"alice","day":"2026-06-01","ai_credits_used":100.9,"user_initiated_interaction_count":10,"code_acceptance_activity_count":5,"code_generation_activity_count":20,"loc_suggested_to_add_sum":100,"loc_added_sum":50,"report_start_day":"2026-05-14","report_end_day":"2026-06-10","organization_id":"123","enterprise_id":""}
{"user_login":"alice","day":"2026-06-02","ai_credits_used":50.7,"user_initiated_interaction_count":5,"code_acceptance_activity_count":3,"code_generation_activity_count":12,"loc_suggested_to_add_sum":60,"loc_added_sum":30,"report_start_day":"2026-05-14","report_end_day":"2026-06-10","organization_id":"123","enterprise_id":""}
{"user_login":"alice","day":"2026-06-03","ai_credits_used":20.3,"user_initiated_interaction_count":3,"code_acceptance_activity_count":2,"code_generation_activity_count":8,"loc_suggested_to_add_sum":40,"loc_added_sum":20,"report_start_day":"2026-05-14","report_end_day":"2026-06-10","organization_id":"123","enterprise_id":""}
{"user_login":"bob","day":"2026-06-01","ai_credits_used":80.1,"user_initiated_interaction_count":8,"code_acceptance_activity_count":2,"code_generation_activity_count":15,"loc_suggested_to_add_sum":80,"loc_added_sum":20,"report_start_day":"2026-05-14","report_end_day":"2026-06-10","organization_id":"123","enterprise_id":""}
{"user_login":"bob","day":"2026-06-02","ai_credits_used":60.5,"user_initiated_interaction_count":6,"code_acceptance_activity_count":1,"code_generation_activity_count":10,"loc_suggested_to_add_sum":50,"loc_added_sum":15,"report_start_day":"2026-05-14","report_end_day":"2026-06-10","organization_id":"123","enterprise_id":""}
{"user_login":"bob","day":"2026-06-03","ai_credits_used":40.9,"user_initiated_interaction_count":4,"code_acceptance_activity_count":0,"code_generation_activity_count":6,"loc_suggested_to_add_sum":30,"loc_added_sum":10,"report_start_day":"2026-05-14","report_end_day":"2026-06-10","organization_id":"123","enterprise_id":""}
{"user_login":"charlie","day":"2026-06-01","ai_credits_used":10.2,"user_initiated_interaction_count":2,"code_acceptance_activity_count":0,"code_generation_activity_count":3,"loc_suggested_to_add_sum":10,"loc_added_sum":0,"report_start_day":"2026-05-14","report_end_day":"2026-06-10","organization_id":"123","enterprise_id":""}
{"user_login":"charlie","day":"2026-06-02","ai_credits_used":5.8,"user_initiated_interaction_count":1,"code_acceptance_activity_count":0,"code_generation_activity_count":2,"loc_suggested_to_add_sum":5,"loc_added_sum":0,"report_start_day":"2026-05-14","report_end_day":"2026-06-10","organization_id":"123","enterprise_id":""}
NDJSON
}

test_help_exits_zero() {
  local output="" status=0
  capture_command output status "$BIN" --help
  assert_status "0" "$status" "--help exits 0"
  assert_contains "$output" "Usage:" "--help shows usage"
  assert_contains "$output" "--stil" "--help mentions --stil"
  assert_contains "$output" "--archive-dir" "--help mentions --archive-dir"
}

test_no_args_exits_nonzero() {
  local output="" status=0
  capture_command output status "$BIN"
  assert_status "1" "$status" "no args exits 1"
}

test_report_only_generates_markdown() {
  local dir="$TEST_TMP_DIR/basic"
  write_fixture "$dir"
  local output="" status=0
  capture_command output status "$BIN" --stil --report-only --archive-dir "$dir" --month 2026-06
  assert_status "0" "$status" "exits 0 with fixture archive"
  assert_contains "$output" "Copilot Leaderboard" "output contains title"
  assert_contains "$output" "buvm-stil" "output contains org label"
  assert_contains "$output" "June 2026" "output contains month name"
}

test_all_users_present_in_table() {
  local dir="$TEST_TMP_DIR/users"
  write_fixture "$dir"
  local output="" status=0
  capture_command output status "$BIN" --stil --report-only --archive-dir "$dir" --month 2026-06
  assert_status "0" "$status" "exits 0"
  assert_contains "$output" "alice"   "alice in table"
  assert_contains "$output" "bob"     "bob in table"
  assert_contains "$output" "charlie" "charlie in table"
  assert_contains "$output" "**All**" "All row present"
}

test_sort_order_most_active_first() {
  local dir="$TEST_TMP_DIR/sort"
  write_fixture "$dir"
  local output="" status=0
  capture_command output status "$BIN" --stil --report-only --archive-dir "$dir" --month 2026-06
  assert_status "0" "$status" "exits 0"
  local alice_line bob_line charlie_line
  alice_line=$(echo "$output"   | grep -n "alice"   | head -1 | cut -d: -f1)
  bob_line=$(echo "$output"     | grep -n "bob"     | head -1 | cut -d: -f1)
  charlie_line=$(echo "$output" | grep -n "charlie" | head -1 | cut -d: -f1)
  if [[ "$bob_line" -lt "$alice_line" ]]; then
    test_pass "bob (180) appears before alice (170)"
  else
    test_fail "bob (180) should appear before alice (170)"
  fi
  if [[ "$alice_line" -lt "$charlie_line" ]]; then
    test_pass "alice (170) appears before charlie (15)"
  else
    test_fail "alice (170) should appear before charlie (15)"
  fi
}

test_grand_total_correct() {
  local dir="$TEST_TMP_DIR/total"
  write_fixture "$dir"
  local output="" status=0
  capture_command output status "$BIN" --stil --report-only --archive-dir "$dir" --month 2026-06
  assert_status "0" "$status" "exits 0"
  # alice=170, bob=180, charlie=15, grand total=365
  assert_contains "$output" "365" "grand total 365 present in output"
}

test_day_columns_present() {
  local dir="$TEST_TMP_DIR/days"
  write_fixture "$dir"
  local output="" status=0
  capture_command output status "$BIN" --stil --report-only --archive-dir "$dir" --month 2026-06
  assert_status "0" "$status" "exits 0"
  # Day columns are day-of-month numbers: 1, 2, 3
  assert_contains "$output" "Month total" "Month total column header present"
  # Header row should contain day numbers 1 2 3
  local header_line
  header_line=$(echo "$output" | grep "Month total")
  assert_contains "$header_line" "| 1 " "day 1 column in header"
  assert_contains "$header_line" "| 2 " "day 2 column in header"
  assert_contains "$header_line" "| 3 " "day 3 column in header"
}

test_missing_day_shows_empty() {
  local dir="$TEST_TMP_DIR/missing"
  write_fixture "$dir"
  local output="" status=0
  capture_command output status "$BIN" --stil --report-only --archive-dir "$dir" --month 2026-06
  assert_status "0" "$status" "exits 0"
  # charlie has no entry for day 3 — that cell should be blank, leaving an empty table cell |   |
  local charlie_line
  charlie_line=$(echo "$output" | grep "charlie")
  # empty cell = pipe, spaces only, pipe — width varies with column content
  if echo "$charlie_line" | grep -qE '\|[[:space:]]+\|[[:space:]]*$'; then
    test_pass "charlie row ends with an empty cell for missing day"
  else
    test_fail "charlie row should end with an empty cell for missing day" "$charlie_line"
  fi
}

test_report_file_written() {
  local dir="$TEST_TMP_DIR/file"
  write_fixture "$dir"
  local output="" status=0
  capture_command output status "$BIN" --stil --report-only --archive-dir "$dir" --month 2026-06
  assert_status "0" "$status" "exits 0"
  if [[ -f "$dir/2026-06-report.md" ]]; then
    test_pass "2026-06-report.md written to archive dir"
  else
    test_fail "2026-06-report.md not found in archive dir"
  fi
}

test_seat_count_in_footer() {
  local dir="$TEST_TMP_DIR/seats"
  write_fixture "$dir"
  local output="" status=0
  capture_command output status "$BIN" --stil --report-only --archive-dir "$dir" --month 2026-06
  assert_status "0" "$status" "exits 0"
  assert_contains "$output" "3 active seats" "seat count in metadata line"
}

test_dry_run_prints_urls_no_fetch() {
  local output="" status=0
  capture_command output status "$BIN" --stil --dry-run
  assert_status "0" "$status" "--dry-run exits 0"
  assert_contains "$output" "dry-run" "dry-run label in output"
  assert_contains "$output" "buvm-stil" "org slug in dry-run output"
}

setup_tmpdir
run_tests "$@"
