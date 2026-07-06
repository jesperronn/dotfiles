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

strip_ansi() {
  perl -pe 's/\e\[[0-9;]*m//g'
}

write_config() {
  local path="$1"
  mkdir -p "$(dirname "$path")"
  cat > "$path" <<'TOML'
[accounts.stil]
label = "buvm-stil"
api_path = "orgs/buvm-stil"
archive_dir = "~/src/copilot-leaderboard-stil"
token_from_1password_item = "GITHUB_COPILOT_BUVM_STIL_USAGE"

[accounts.nine]
label = "nine"
api_path = "enterprises/nine"
archive_dir = "~/src/copilot-leaderboard-nine"
token_from_1password_item = "GITHUB_COPILOT_TOKEN_JRJ_NINE"
TOML
}

write_nine_only_config() {
  local path="$1"
  mkdir -p "$(dirname "$path")"
  cat > "$path" <<'TOML'
[accounts.nine]
label = "nine"
api_path = "enterprises/nine"
archive_dir = "~/src/copilot-leaderboard-nine"
token_from_1password_item = "GITHUB_COPILOT_TOKEN_JRJ_NINE"
TOML
}

# Fixture: 3 users over 3 days in June 2026, cells show "credits/interactions"
# alice:   100/10 | 50/5 | 20/3 | total=170/18
# bob:     80/8   | 60/6 | 40/4 | total=180/18
# charlie: 10/2   | 5/1  | (no day3) | total=15/3
# Grand total credits=365, interactions=39
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

capture_with_config() {
  local output_var="$1"
  local status_var="$2"
  local config_path="$3"
  shift 3
  capture_command "$output_var" "$status_var" env "COPILOT_LEADERBOARD_CONFIG=$config_path" "$@"
}

capture_with_default_config() {
  local output_var="$1"
  local status_var="$2"
  shift 2
  local config="$TEST_TMP_DIR/default-config.toml"
  [[ -f "$config" ]] || write_config "$config"
  capture_with_config "$output_var" "$status_var" "$config" "$@"
}

test_help_exits_zero() {
  local config="$TEST_TMP_DIR/help-config.toml"
  write_config "$config"
  local output="" status=0
  capture_with_config output status "$config" "$BIN" --help
  assert_status "0" "$status" "--help exits 0"
  assert_contains "$output" "Usage:" "--help shows usage"
  assert_contains "$output" "--only NAMES" "--help mentions --only"
  assert_contains "$output" "--all" "--help mentions --all"
  assert_contains "$output" "Available accounts:" "--help shows available accounts"
  assert_contains "$output" "nine, stil" "--help lists accounts"
  assert_contains "$output" "$config" "--help shows config path"
  assert_contains "$output" "Examples:" "--help shows examples"
  assert_contains "$output" "copilot-leaderboard --init" "--help shows init example"
  assert_contains "$output" "copilot-leaderboard --only nine,stil --month" "--help shows multi-account month example"
  assert_contains "$output" "Config format:" "--help shows config hint"
  if echo "$output" | grep -q -- "copilot-leaderboard --only nine --update"; then
    test_fail "--help should not include redundant single-account update example" "$output"
  else
    test_pass "--help omits redundant single-account update example"
  fi
  if echo "$output" | grep -q -- "copilot-leaderboard --all --report-only"; then
    test_fail "--help should not include redundant all report-only example" "$output"
  else
    test_pass "--help omits redundant all report-only example"
  fi
  if echo "$output" | grep -q -- "--stil\\|--nine"; then
    test_fail "--help should not advertise legacy aliases" "$output"
  else
    test_pass "--help hides legacy aliases"
  fi
}

test_no_args_exits_nonzero() {
  local output="" status=0
  local config="$TEST_TMP_DIR/no-args-config.toml"
  write_config "$config"
  capture_with_config output status "$config" "$BIN"
  assert_status "1" "$status" "no args exits 1"
  assert_contains "$output" "$config" "no-args help shows config path"
}

test_report_only_generates_markdown() {
  local dir="$TEST_TMP_DIR/basic"
  write_fixture "$dir"
  local output="" status=0
  capture_with_default_config output status "$BIN" --only stil --report-only --archive-dir "$dir" --month 2026-06
  assert_status "0" "$status" "exits 0 with fixture archive"
  assert_contains "$output" "Copilot Leaderboard" "output contains title"
  assert_contains "$output" "buvm-stil" "output contains org label"
  assert_contains "$output" "June 2026" "output contains month name"
}

test_all_users_present_in_table() {
  local dir="$TEST_TMP_DIR/users"
  write_fixture "$dir"
  local output="" status=0
  capture_with_default_config output status "$BIN" --only stil --report-only --archive-dir "$dir" --month 2026-06
  assert_status "0" "$status" "exits 0"
  assert_contains "$output" "alice" "alice in table"
  assert_contains "$output" "bob" "bob in table"
  assert_contains "$output" "charlie" "charlie in table"
  assert_contains "$output" "**All**" "All row present"
}

test_sort_order_most_active_first() {
  local dir="$TEST_TMP_DIR/sort"
  write_fixture "$dir"
  local output="" status=0
  capture_with_default_config output status "$BIN" --only stil --report-only --archive-dir "$dir" --month 2026-06
  assert_status "0" "$status" "exits 0"
  local alice_line bob_line charlie_line
  alice_line=$(echo "$output" | grep -n "alice" | head -1 | cut -d: -f1)
  bob_line=$(echo "$output" | grep -n "bob" | head -1 | cut -d: -f1)
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
  capture_with_default_config output status "$BIN" --only stil --report-only --archive-dir "$dir" --month 2026-06
  assert_status "0" "$status" "exits 0"
  assert_contains "$output" "365" "grand total credits 365 present in output"
  assert_contains "$output" "39" "grand total interactions 39 present in output"
}

test_day_columns_present() {
  local dir="$TEST_TMP_DIR/days"
  write_fixture "$dir"
  local output="" status=0
  capture_with_default_config output status "$BIN" --only stil --report-only --archive-dir "$dir" --month 2026-06
  assert_status "0" "$status" "exits 0"
  assert_contains "$output" "Month total" "Month total column header present"
  local header_line
  header_line=$(echo "$output" | grep "Month total" | head -1 | strip_ansi)
  assert_contains "$header_line" "| 1 " "day 1 column in header"
  assert_contains "$header_line" "| 2 " "day 2 column in header"
  assert_contains "$header_line" "| 3 " "day 3 column in header"
}

test_missing_day_shows_empty() {
  local dir="$TEST_TMP_DIR/missing"
  write_fixture "$dir"
  local output="" status=0
  capture_with_default_config output status "$BIN" --only stil --report-only --archive-dir "$dir" --month 2026-06
  assert_status "0" "$status" "exits 0"
  local charlie_line
  charlie_line=$(echo "$output" | grep "charlie" | head -1 | strip_ansi)
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
  capture_with_default_config output status "$BIN" --only stil --report-only --archive-dir "$dir" --month 2026-06
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
  capture_with_default_config output status "$BIN" --only stil --report-only --archive-dir "$dir" --month 2026-06
  assert_status "0" "$status" "exits 0"
  assert_contains "$output" "3 active seats" "seat count in metadata line"
}

test_dry_run_prints_urls_no_fetch() {
  local config="$TEST_TMP_DIR/dry-run-config.toml"
  write_config "$config"
  local output="" status=0
  capture_with_config output status "$config" "$BIN" --only stil --dry-run
  assert_status "0" "$status" "--dry-run exits 0"
  assert_contains "$output" "dry-run" "dry-run label in output"
  assert_contains "$output" "buvm-stil" "org slug in dry-run output"
  assert_contains "$output" "Using config: $config" "dry-run reports config path"
  assert_contains "$output" "Using account: stil" "dry-run reports selected account"
}

test_init_writes_template() {
  local config="$TEST_TMP_DIR/init/copilot-leaderboard.toml"
  local output="" status=0
  capture_command output status "$BIN" --init --config "$config"
  assert_status "0" "$status" "--init exits 0"
  assert_contains "$output" "Wrote $config" "--init reports path"
  assert_contains "$output" "Added example accounts" "--init explains template contents"
  assert_contains "$output" "Edit this file with your own account names" "--init tells user to customize config"
  assert_contains "$output" "copilot-leaderboard --help" "--init suggests checking discovered accounts"
  if [[ -f "$config" ]]; then
    test_pass "config file written"
  else
    test_fail "config file not written"
  fi
  local config_body
  config_body="$(cat "$config")"
  assert_contains "$config_body" "[accounts.account_acme]" "template includes generic example account"
  assert_contains "$config_body" "api_path = \"orgs/acme\"" "template includes org API path example"
  assert_contains "$config_body" "token_from_env" "template includes env example"
}

test_removed_legacy_flags_are_unknown_options() {
  local output="" status=0
  capture_command output status "$BIN" --stil
  assert_status "1" "$status" "--stil is removed"
  assert_contains "$output" "Unknown option: --stil" "--stil reports unknown option"

  output="" status=0
  capture_command output status "$BIN" --nine
  assert_status "1" "$status" "--nine is removed"
  assert_contains "$output" "Unknown option: --nine" "--nine reports unknown option"
}

test_only_unknown_account_fails_with_available_accounts() {
  local config="$TEST_TMP_DIR/unknown-config.toml"
  write_config "$config"
  local output="" status=0
  capture_with_config output status "$config" "$BIN" --only missing
  assert_status "1" "$status" "unknown --only exits 1"
  assert_contains "$output" "Unknown account(s): missing" "unknown account error"
  assert_contains "$output" "Available: nine, stil" "unknown account lists available names"
}

test_missing_config_does_not_use_builtin_accounts() {
  local config="$TEST_TMP_DIR/missing/copilot-leaderboard.toml"
  local output="" status=0
  capture_command output status "$BIN" --config "$config" --help
  assert_status "0" "$status" "missing config help exits 0"
  assert_contains "$output" "Available accounts:" "missing config help shows accounts section"
  assert_contains "$output" "(none)" "missing config has no built-in accounts"
  assert_contains "$output" "copilot-leaderboard --init" "missing config suggests init"
  assert_contains "$output" "$config" "missing config help shows config path"
}

test_missing_config_run_suggests_init() {
  local config="$TEST_TMP_DIR/missing-run/copilot-leaderboard.toml"
  local output="" status=0
  capture_command output status "$BIN" --config "$config" --only stil
  assert_status "1" "$status" "missing config run exits 1"
  assert_contains "$output" "Config not found: $config" "missing config run shows config path"
  assert_contains "$output" "copilot-leaderboard --init" "missing config run suggests init"
}

test_help_uses_live_toml_accounts_only() {
  local config="$TEST_TMP_DIR/nine-only.toml"
  write_nine_only_config "$config"
  local output="" status=0
  capture_with_config output status "$config" "$BIN" --help
  assert_status "0" "$status" "nine-only help exits 0"
  assert_contains "$output" "Available accounts:" "nine-only help shows accounts"
  assert_contains "$output" "nine" "nine-only help includes nine"
  if echo "$output" | grep -q "Available accounts:" && echo "$output" | grep -A1 "Available accounts:" | grep -q "stil"; then
    test_fail "nine-only help should not list removed stil account"
  else
    test_pass "nine-only help does not list removed stil account"
  fi
}

setup_tmpdir
run_tests "$@"
