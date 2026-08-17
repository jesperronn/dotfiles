#!/usr/bin/env bash
# shellcheck disable=SC1090,SC1091

set -euo pipefail

DOTFILES_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
BBPR_BIN="$DOTFILES_ROOT/bin/bbpr"

source "$DOTFILES_ROOT/bin/lib/bash_test.sh"

TEST_TMP_DIR=""

setup_tmpdir() {
  TEST_TMP_DIR="$(mktemp -d)"
  trap 'rm -rf "$TEST_TMP_DIR"' EXIT
  mkdir -p "$TEST_TMP_DIR/bin"

  cat >"$TEST_TMP_DIR/bin/op" <<'MOCK_OP'
#!/usr/bin/env bash
printf 'mock-op\n' >>"${BBPR_OP_MARKER:?}"
printf 'test-token'
MOCK_OP
  chmod +x "$TEST_TMP_DIR/bin/op"

  cat >"$TEST_TMP_DIR/bin/curl" <<'MOCK_CURL'
#!/usr/bin/env bash
set -euo pipefail
url="${!#}"
if [[ "$url" == *"application-properties"* && "$*" == *"-D -"* ]]; then
  printf 'HTTP/1.1 200 OK\r\nX-AUSERNAME: test-user\r\n\r\n200'
elif [[ "$url" == *"pull-requests/42"* ]]; then
  printf '{"id":42,"title":"Test PR","state":"OPEN","author":{"user":{"slug":"test-user"}},"createdDate":"2026-01-01","updatedDate":"2026-01-01","fromRef":{"displayId":"feature"},"toRef":{"displayId":"main"},"participants":[],"links":{"self":[{"href":"https://stash.example.test/projects/PROJ/repos/repo/pull-requests/42"}]}}\n200\n'
elif [[ "$url" == *"dashboard/pull-requests"* ]]; then
  printf '{"isLastPage":true,"values":[{"id":42,"title":"Test PR","state":"OPEN","author":{"user":{"slug":"author","displayName":"Test Author"}},"createdDate":"2026-01-01","fromRef":{"repository":{"slug":"repo","name":"Repo","project":{"key":"PROJ"}}},"participants":[{"role":"REVIEWER","user":{"slug":"test-user"},"status":"UNAPPROVED"}],"links":{"self":[{"href":"https://stash.example.test/projects/PROJ/repos/repo/pull-requests/42"}]}}]}\n200\n'
elif [[ "$url" == *"activities"* || "$url" == *"blocker-comments"* ]]; then
  printf '{"isLastPage":true,"values":[]}\n200\n'
else
  printf '{}\n200\n'
fi
MOCK_CURL
  chmod +x "$TEST_TMP_DIR/bin/curl"

  export BBPR_OP_MARKER="$TEST_TMP_DIR/op.calls"
  export PATH="$TEST_TMP_DIR/bin:$PATH"
}

test_help_lists_output_modes() {
  local output="" status=0
  capture_command output status "$BBPR_BIN" --help
  assert_status "0" "$status" "bbpr --help exits successfully"
  assert_contains "$output" "--short" "help lists --short"
  assert_contains "$output" "--long" "help lists --long"
  assert_contains "$output" "PROJ/REPO/NNN" "help lists slash PR identifiers"
}

test_show_accepts_bitbucket_urls() {
  local spec output="" status=0
  local -a specs=(
    "https://stash.example.test/projects/PROJ/repos/repo/pull-requests/42/overview"
    "https://stash.example.test/projects/PROJ/repos/repo/pull-requests/42"
    "projects/PROJ/repos/repo/pull-requests/42"
  )

  for spec in "${specs[@]}"; do
    capture_command output status "$BBPR_BIN" show "$spec"
    assert_status "0" "$status" "show accepts $spec"
    assert_contains "$output" "PR #42: Test PR" "show resolves $spec"
  done
}

test_show_uses_project_repository_path() {
  local output="" status=0
  capture_command output status "$BBPR_BIN" --verbose show PROJ/repo/42
  assert_status "0" "$status" "show succeeds with a normalized identifier"
  assert_contains "$output" "/projects/PROJ/repos/repo/pull-requests/42?withProperties=true" "show calls the project-scoped endpoint"
}

test_op_is_mocked_when_token_is_not_supplied() {
  local output="" status=0
  : >"$BBPR_OP_MARKER"
  capture_command output status "$BBPR_BIN" ping
  assert_status "0" "$status" "ping succeeds with the mocked op token"
  assert_eq "mock-op" "$(cat "$BBPR_OP_MARKER")" "ping invokes the test op mock"
}

test_review_short_and_long_output() {
  local output="" status=0
  capture_command output status "$BBPR_BIN" review --short
  assert_status "0" "$status" "review --short exits successfully"
  assert_contains "$output" "PROJ/repo/42" "review --short emits a show identifier"

  capture_command output status "$BBPR_BIN" review --long
  assert_status "0" "$status" "review --long exits successfully"
  assert_contains "$output" "https://stash.example.test/projects/PROJ/repos/repo/pull-requests/42" "review --long emits a clickable URL"
  assert_contains "$output" "TA Test PR" "review --long emits author initials and title"
}

test_list_commands_use_dashboard_api() {
  local output="" status=0
  capture_command output status "$BBPR_BIN" --verbose mine
  assert_status "0" "$status" "mine exits successfully"
  assert_contains "$output" "/dashboard/pull-requests" "mine uses the dashboard API"
  assert_contains "$output" "role=AUTHOR" "mine requests author PRs"

  capture_command output status "$BBPR_BIN" --verbose review
  assert_status "0" "$status" "review exits successfully"
  assert_contains "$output" "role=REVIEWER" "review requests reviewer PRs"

  capture_command output status "$BBPR_BIN" --verbose open
  assert_status "0" "$status" "open exits successfully"
  assert_not_contains "$output" "role=REVIEWER" "open does not apply the reviewer filter"
}

test_comments_accepts_normalized_url() {
  local output="" status=0
  capture_command output status "$BBPR_BIN" comments "https://stash.example.test/projects/PROJ/repos/repo/pull-requests/42/overview"
  assert_status "0" "$status" "comments accepts a Bitbucket URL"
}

setup_tmpdir
run_tests "$@"
