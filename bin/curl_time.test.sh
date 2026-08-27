#!/usr/bin/env bash
# Tests for bin/curl_time
# Run: bin/test (discovers automatically)
#

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"

# shellcheck disable=SC1091
source bin/lib/bash_test.sh
# shellcheck disable=SC1091
source "${SCRIPT_DIR}/bin/curl_time" SOURCE

# ── Curl stub infrastructure ─────────────────────────────────────────────────
# Single top-level override that reads per-test state.  Eliminates nested
# function definitions (SC2329) while keeping each test self-contained.

_curl_stub_mode=""
_curl_stub_response=""
_curl_stub_output=""
_curl_stub_exit_code=0

reset_curl_stub() {
  _curl_stub_mode=""
  _curl_stub_response=""
  _curl_stub_output=""
  _curl_stub_exit_code=0
}

# shellcheck disable=SC2329
curl() {
  case "$_curl_stub_mode" in
  success)
    printf '%s' "$_curl_stub_response"
    ;;
  fail)
    printf '%s' "$_curl_stub_response"
    ;;
  error)
    printf '%s' "$_curl_stub_output" >&2
    return "$_curl_stub_exit_code"
    ;;
  timeout)
    return 28
    ;;
  esac
}

stub_curl_success() {
  reset_curl_stub
  _curl_stub_mode="success"
  _curl_stub_response='200|https://example.com|1.2.3.4|0.123|0.010|0.050|0.060'
}

stub_curl_fail() {
  reset_curl_stub
  _curl_stub_mode="fail"
  _curl_stub_response='500|https://example.com|1.2.3.4|0.200|0.015|0.100|0.150'
}

stub_curl_timing() {
  reset_curl_stub
  _curl_stub_mode="success"
  _curl_stub_response='200|https://example.com|1.2.3.4|0.500|0.050|0.200|0.250'
}

stub_curl_multi() {
  reset_curl_stub
  _curl_stub_mode="success"
}

stub_curl_multi_urls() {
  reset_curl_stub
  _curl_stub_mode="success"
}

stub_curl_error() {
  reset_curl_stub
  _curl_stub_mode="error"
  _curl_stub_output='curl: (7) Failed to connect to host port 99999: Connection refused'
  _curl_stub_exit_code=7
}

stub_curl_timeout() {
  reset_curl_stub
  _curl_stub_mode="timeout"
}

# Helper: build the curl response for a set of URLs (for multi-URL stubs).
_curl_stub_responses=()
_curl_stub_url_index=0

stub_curl_multi_set() {
  _curl_stub_responses=("$@")
  _curl_stub_url_index=0
}

# Override curl for multi-URL tests to cycle through responses.
curl() {
  case "$_curl_stub_mode" in
  multi)
    if [[ $_curl_stub_url_index -lt ${#_curl_stub_responses[@]} ]]; then
      printf '%s' "${_curl_stub_responses[$_curl_stub_url_index]}"
      _curl_stub_url_index=$((_curl_stub_url_index + 1))
    else
      printf '%s' "${_curl_stub_responses[-1]}"
    fi
    ;;
  multi_urls)
    # Last positional arg is the URL; build response from it.
    local url_arg="${*: -1}"
    local host="${url_arg#*://}"
    host="${host%%/*}"
    printf '200|https://%s|1.2.3.4|0.123|0.010|0.050|0.060' "$host"
    ;;
  error)
    printf '%s' "$_curl_stub_output" >&2
    return "$_curl_stub_exit_code"
    ;;
  timeout)
    return 28
    ;;
  *)
    printf '%s' "$_curl_stub_response"
    ;;
  esac
}

# ── Tests ────────────────────────────────────────────────────────────────────
test_single_url_success() {
  reset_curl_stub
  stub_curl_success
  local output status
  capture_command output status run_main "https://example.com" || true
  assert_contains "$output" "✓" "success line shows checkmark"
  assert_contains "$output" "example.com" "output contains URL"
  assert_contains "$output" "200 OK" "shows 200 OK status"
  assert_contains "$output" "1.2.3.4" "shows remote IP"
  assert_contains "$output" "Total:" "shows timing Total"
  assert_contains "$output" "TTFB:" "shows timing TTFB"
  assert_contains "$output" "DNS:" "shows timing DNS"
  assert_not_contains "$output" "Error" "no Error on success"
}

test_single_url_failure() {
  reset_curl_stub
  stub_curl_fail
  local output
  capture_command output status run_main "https://example.com" || true
  assert_contains "$output" "✗" "failure shows X mark"
  assert_contains "$output" "500 FAIL" "shows 500 FAIL"
  assert_contains "$output" "Total:" "still shows Total"
}

test_multiple_urls() {
  reset_curl_stub
  stub_curl_multi_set \
    '200|https://a.com|1.1.1.1|0.100|0.010|0.040|0.050' \
    '200|https://b.com|2.2.2.2|0.200|0.020|0.080|0.100' \
    '404|https://c.com|3.3.3.3|0.150|0.015|0.060|0.070'
  local output
  capture_command output status run_main \
    "https://a.com" "https://b.com" "https://c.com" || true
  assert_contains "$output" "a.com" "first URL appears"
  assert_contains "$output" "b.com" "second URL appears"
  assert_contains "$output" "c.com" "third URL appears"
  # Count checkmarks: a.com and b.com are 200 (✓), c.com is 404 (✗)
  local stripped check_count fail_count
  stripped=$(printf '%s' "$output" | sed 's/\x1b\[[0-9;]*m//g')
  check_count=$(grep -c '✓' <<<"$stripped" || true)
  assert_eq 2 "$check_count" "exactly 2 success marks"
  fail_count=$(grep -c '✗' <<<"$stripped" || true)
  assert_eq 1 "$fail_count" "exactly 1 failure mark"
}

test_max_urls() {
  reset_curl_stub
  stub_curl_multi_urls
  local output
  capture_command output status run_main \
    "https://u1.com" "https://u2.com" "https://u3.com" \
    "https://u4.com" "https://u5.com" "https://u6.com" \
    "https://u7.com" "https://u8.com" "https://u9.com" || true
  assert_contains "$output" "u1.com" "first URL appears"
  assert_contains "$output" "u9.com" "ninth URL appears"
}

test_too_many_urls() {
  local output status
  capture_command output status run_main \
    "https://u1.com" "https://u2.com" "https://u3.com" \
    "https://u4.com" "https://u5.com" "https://u6.com" \
    "https://u7.com" "https://u8.com" "https://u9.com" \
    "https://u10.com" || true
  assert_status 1 "$status" "exits 1 for 10 URLs"
  assert_contains "$output" "too many" "error mentions too many"
}

test_no_urls() {
  local output status
  capture_command output status run_main || true
  assert_status 1 "$status" "exits 1 with no URLs"
}

test_no_urls_exit_code() {
  local output status
  capture_command output status run_main || true
  assert_status 1 "$status" "explicit exit code 1"
}

test_verbose_flag_no_error() {
  reset_curl_stub
  stub_curl_success
  local output
  capture_command output status run_main --verbose "https://example.com" || true
  assert_contains "$output" "✓" "still shows success"
  assert_not_contains "$output" "Verbose error" "no error line on success"
}

test_verbose_flag_with_error() {
  reset_curl_stub
  stub_curl_error
  local output
  capture_command output status run_main --verbose "https://example.com" || true
  assert_contains "$output" "Verbose error" "verbose shows error details"
}

test_verbose_flag_off_no_error_line() {
  reset_curl_stub
  stub_curl_error
  local output
  capture_command output status run_main "https://example.com" || true
  assert_not_contains "$output" "Verbose error" "no error line without --verbose"
}

test_help_flag() {
  local output status
  capture_command output status run_main --help || true
  assert_status 0 "$status" "help exits 0"
  assert_contains "$output" "Usage" "shows Usage"
  assert_contains "$output" "URL" "shows URL in usage"
  assert_contains "$output" "--verbose" "lists --verbose flag"
}

test_help_flag_short() {
  local output status
  capture_command output status run_main -h || true
  assert_status 0 "$status" "short help exits 0"
  assert_contains "$output" "Usage" "shows Usage"
}

test_timing_values() {
  reset_curl_stub
  stub_curl_timing
  local output
  capture_command output status run_main "https://example.com" || true
  assert_contains "$output" "Total: 500 ms" "Total timing correct"
  assert_contains "$output" "TTFB: 250 ms" "TTFB timing correct"
  assert_contains "$output" "DNS: 50 ms" "DNS timing correct"
}

test_connection_refused() {
  reset_curl_stub
  stub_curl_error
  local output
  capture_command output status run_main "https://localhost:99999" || true
  assert_contains "$output" "✗" "connection refused shows X"
  assert_contains "$output" "Total:" "still shows Total"
}

run_tests
