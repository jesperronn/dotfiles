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
elif [[ "$url" == *"activities"* ]]; then
  printf '{"isLastPage":true,"values":[{"comment":{"id":7,"state":"OPEN","author":{"slug":"reviewer","displayName":"Review Person"},"text":"Please fix this branch.","anchor":{"path":"src/app.rb","line":12,"lineType":"ADDED","fileType":"TO"},"comments":[{"author":{"slug":"author","displayName":"Test Author"},"text":"Fixed in latest commit.","state":"OPEN"}]}},{"comment":{"id":8,"state":"RESOLVED","updatedDate":"2026-01-02","author":{"slug":"reviewer","displayName":"Review Person"},"text":"Old concern.","anchor":{"path":"test/app_test.rb","line":4,"lineType":"CONTEXT","fileType":"TO"},"comments":[]}}]}\n200\n'
elif [[ "$url" == *"blocker-comments"* ]]; then
  printf '{"isLastPage":true,"values":[]}\n200\n'
elif [[ "$url" == *"pull-requests/42"* ]]; then
  printf '{"id":42,"title":"Test PR","state":"OPEN","author":{"user":{"slug":"test-user","displayName":"Test Author"}},"createdDate":"2026-01-01","updatedDate":"2026-01-01","fromRef":{"displayId":"feature","latestCommit":"abcdef1234567890","repository":{"slug":"repo","name":"Repo","project":{"key":"PROJ"}}},"toRef":{"displayId":"main"},"participants":[{"role":"REVIEWER","user":{"slug":"reviewer","displayName":"Review Person"},"status":"UNAPPROVED"}],"links":{"self":[{"href":"https://stash.example.test/projects/PROJ/repos/repo/pull-requests/42"}]}}\n200\n'
elif [[ "$url" == *"dashboard/pull-requests"* ]]; then
  printf '{"isLastPage":true,"values":[{"id":42,"title":"Test PR","state":"OPEN","author":{"user":{"slug":"author","displayName":"Test Author"}},"createdDate":"2026-01-01","fromRef":{"displayId":"feature","latestCommit":"abcdef1234567890","repository":{"slug":"repo","name":"Repo","project":{"key":"PROJ"}}},"toRef":{"displayId":"main"},"participants":[{"role":"REVIEWER","user":{"slug":"test-user"},"status":"UNAPPROVED"}],"links":{"self":[{"href":"https://stash.example.test/projects/PROJ/repos/repo/pull-requests/42"}]}}]}\n200\n'
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
  assert_contains "$output" "-i, --interactive" "help lists interactive show mode"
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

test_fetch_token_prints_waiting_message_for_op() {
  local output="" status=0
  : >"$BBPR_OP_MARKER"
  capture_command output status "$BBPR_BIN" review --short
  assert_status "0" "$status" "review --short succeeds with mocked op"
  assert_contains "$output" "Waiting for 1Password" "op-backed token lookup reports waiting text"
  assert_eq "mock-op" "$(cat "$BBPR_OP_MARKER")" "review still invokes the op mock"
}

test_review_default_emits_structured_markdown() {
  local output="" status=0

  capture_command output status "$BBPR_BIN" review
  assert_status "0" "$status" "review exits successfully"
  assert_contains "$output" "## Review Queue" "review prints a Markdown heading"
  assert_contains "$output" $'PROJ/repo/42\n**Test PR**\nTest Author ' "review prints the compact three-line PR block"
  assert_not_contains "$output" "- [ ] PROJ/repo/42" "review no longer prefixes PR specs with checklist markup"
  assert_not_contains "$output" "Title:" "review no longer prints the title label"
  assert_not_contains "$output" "URL:" "review no longer prints the URL label"
  assert_not_contains "$output" "https://stash.example.test/projects/PROJ/repos/repo/pull-requests/42 TA Test PR" "review no longer defaults to long flat lines"
}

test_review_renderer_bolds_title_and_marks_draft() {
  local output=""

  output="$(
    source "$BBPR_BIN"
    BBPR_COLOR_ENABLED=0
    bbpr_render_review_markdown '[{"id":42,"title":"Draft PR","draft":true,"author":{"user":{"slug":"author","displayName":"Test Author"}},"fromRef":{"repository":{"slug":"repo","project":{"key":"PROJ"}}},"participants":[{"role":"REVIEWER","status":"UNAPPROVED"}],"links":{"self":[{"href":"https://stash.example.test/projects/PROJ/repos/repo/pull-requests/42"}]}}]'
  )"

  assert_contains "$output" $'PROJ/repo/42\nDRAFT **Draft PR**\nTest Author UNAPPROVED' "review renderer emits spec, draft title, and author/status on exactly three lines"
  assert_not_contains "$output" "Title:" "review renderer removes the title label"
  assert_not_contains "$output" "https://stash.example.test/projects/PROJ/repos/repo/pull-requests/42" "review renderer removes the URL line from default output"
}

test_review_renderer_uses_isdraft_fallback_and_color_styles() {
  local output="" esc
  esc=$'\033'

  output="$(
    source "$BBPR_BIN"
    BBPR_COLOR_ENABLED=1
    bbpr_render_review_markdown '[{"id":43,"title":"Color Draft","isDraft":true,"author":{"user":{"slug":"author","displayName":"Test Author"}},"fromRef":{"repository":{"slug":"repo","project":{"key":"PROJ"}}},"participants":[{"role":"REVIEWER","status":"NEEDS_WORK"}],"links":{"self":[{"href":"https://stash.example.test/projects/PROJ/repos/repo/pull-requests/43"}]}}]'
  )"

  assert_contains "$output" "${esc}[1m${esc}[34mPROJ/repo/43${esc}[0m" "review renderer keeps the colored spec on its own line"
  assert_contains "$output" "${esc}[35mDRAFT${esc}[0m **${esc}[1m${esc}[36mColor Draft${esc}[0m**" "review renderer keeps the draft marker and colored bold title together"
  assert_contains "$output" "${esc}[32mTest Author${esc}[0m" "review renderer keeps author coloring"
  assert_contains "$output" "${esc}[31mNEEDS WORK${esc}[0m" "review renderer colors important status values"
  assert_contains "$output" "${esc}[35mDRAFT${esc}[0m" "review renderer colors the draft marker from isDraft"
}

test_review_short_adds_next_step_hint() {
  local output="" status=0

  capture_command output status "$BBPR_BIN" review --short
  assert_status "0" "$status" "review --short exits successfully"
  assert_contains "$output" "PROJ/repo/42" "review --short still emits a show identifier"
  assert_contains "$output" "next: bbpr show PROJ/repo/42" "review --short adds the next-step hint"
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

test_review_long_preserves_clickable_lines() {
  local output="" status=0

  capture_command output status "$BBPR_BIN" review --long
  assert_status "0" "$status" "review --long exits successfully"
  assert_contains "$output" "https://stash.example.test/projects/PROJ/repos/repo/pull-requests/42" "review --long keeps clickable URLs"
  assert_contains "$output" "TA Test PR" "review --long keeps author initials and title"
  assert_not_contains "$output" "## Review Queue" "review --long bypasses Markdown mode"
}

test_show_default_emits_structured_reviewer_handoff() {
  local output="" status=0

  capture_command output status "$BBPR_BIN" show PROJ/repo/42
  assert_status "0" "$status" "show exits successfully"
  assert_contains "$output" "## PR #42: Test PR" "show prints a structured Markdown heading"
  assert_contains "$output" "Branch: feature -> main" "show includes source and destination branches"
  assert_contains "$output" "Latest Commit: abcdef1234567890" "show includes the latest source commit"
  assert_contains "$output" "Relevant Files: src/app.rb, test/app_test.rb" "show summarizes relevant files from review comments"
  assert_contains "$output" "Review Person: Please fix this branch." "show includes open comments"
  assert_contains "$output" "Test Author: Fixed in latest commit." "show includes comment replies"
  assert_contains "$output" "Resolved Comments" "show includes resolved review context"
}

test_show_json_behavior_is_preserved() {
  local output="" status=0

  capture_command output status "$BBPR_BIN" show --json PROJ/repo/42
  assert_status "0" "$status" "show --json exits successfully"
  assert_contains "$output" '"id": 42' "show --json keeps the PR id field"
  assert_contains "$output" '"sourceBranch": "feature"' "show --json keeps branch fields"
  assert_contains "$output" '"comments": [' "show --json keeps comments collection"
  assert_contains "$output" '"text": "Please fix this branch."' "show --json keeps comment text"
}

test_show_interactive_requires_fzf() {
  local output="" status=0
  local path_without_fzf="$TEST_TMP_DIR/bin:/usr/bin:/bin"

  rm -f "$TEST_TMP_DIR/bin/fzf"
  capture_command output status env PATH="$path_without_fzf" "$BBPR_BIN" show --interactive
  assert_status "1" "$status" "show --interactive fails without fzf"
  assert_contains "$output" "fzf is not installed or not on PATH" "interactive mode explains the missing dependency"
}

test_show_interactive_short_flag_requires_fzf() {
  local output="" status=0
  local path_without_fzf="$TEST_TMP_DIR/bin:/usr/bin:/bin"

  rm -f "$TEST_TMP_DIR/bin/fzf"
  capture_command output status env PATH="$path_without_fzf" "$BBPR_BIN" show -i
  assert_status "1" "$status" "show -i fails without fzf"
  assert_contains "$output" "fzf is not installed or not on PATH" "short interactive flag explains the missing dependency"
}

test_show_interactive_uses_fzf_preview() {
  local output="" status=0

  cat >"$TEST_TMP_DIR/bin/fzf" <<'MOCK_FZF'
#!/usr/bin/env bash
printf '%s\n' "$*" >"${BBPR_FZF_ARGS_LOG:?}"
cat >"${BBPR_FZF_INPUT_LOG:?}"
printf 'PROJ/repo/42\tTest PR\tTest Author\n'
MOCK_FZF
  chmod +x "$TEST_TMP_DIR/bin/fzf"

  export BBPR_FZF_ARGS_LOG="$TEST_TMP_DIR/fzf.args"
  export BBPR_FZF_INPUT_LOG="$TEST_TMP_DIR/fzf.input"

  capture_command output status "$BBPR_BIN" show --interactive
  assert_status "0" "$status" "show --interactive succeeds with mocked fzf"
  assert_contains "$(cat "$BBPR_FZF_ARGS_LOG")" "--preview" "interactive mode configures fzf preview"
  assert_contains "$(cat "$BBPR_FZF_ARGS_LOG")" "bbpr show" "interactive preview reuses the show subcommand"
  assert_contains "$(cat "$BBPR_FZF_INPUT_LOG")" "PROJ/repo/42" "interactive mode offers review PR identifiers to fzf"
  assert_contains "$output" "## PR #42: Test PR" "interactive selection prints the chosen PR details"
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
