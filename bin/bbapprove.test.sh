#!/usr/bin/env bash
# shellcheck disable=SC1090,SC1091

set -euo pipefail

DOTFILES_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
SCRIPT_UNDER_TEST="$DOTFILES_ROOT/bin/bbapprove"

source "$DOTFILES_ROOT/bin/lib/bash_test.sh"

TEST_TMP=""
cleanup_test_tmp() { [[ -n "$TEST_TMP" ]] && rm -rf "$TEST_TMP"; return 0; }
trap 'cleanup_test_tmp' EXIT

setup_stubs() {
  TEST_TMP="$(mktemp -d)"
  mkdir -p "$TEST_TMP/bin"
  cat >"$TEST_TMP/bin/op" <<'STUB'
#!/usr/bin/env bash
echo "$*" >>"$STUB_OP_LOG"
printf 'op-token'
STUB
  cat >"$TEST_TMP/target" <<'STUB'
#!/usr/bin/env bash
printf 'token=%s args=%s\n' "${BBAPPROVE_TOKEN:-}" "$*"
STUB
  chmod +x "$TEST_TMP/bin/op" "$TEST_TMP/target"
  export STUB_OP_LOG="$TEST_TMP/op.log"
  : >"$STUB_OP_LOG"
  export BBAPPROVE_BIN="$TEST_TMP/target"
  unset BBAPPROVE_TOKEN || true
}

run_wrapper() { PATH="$TEST_TMP/bin:$PATH" "$SCRIPT_UNDER_TEST" "$@" 2>&1; }

test_fetches_token_and_passes_flags() {
  setup_stubs
  local out; out="$(run_wrapper --apply --disallow a,b URL)"
  assert_eq "$out" "token=op-token args=--apply --disallow a,b URL" "token from op and flags passed through"
  assert_contains "$(cat "$STUB_OP_LOG")" "item get BITBUCKET_TOKEN_JRJ --fields label=token --reveal" "op called with expected item"
  cleanup_test_tmp; TEST_TMP=""
}

test_preset_token_is_ignored() {
  setup_stubs
  local out; out="$(BBAPPROVE_TOKEN=other run_wrapper)"
  assert_eq "$out" "token=op-token args=" "always uses the 1Password token"
  assert_contains "$(cat "$STUB_OP_LOG")" "BITBUCKET_TOKEN_JRJ" "op called even with preset token"
  cleanup_test_tmp; TEST_TMP=""
}

test_missing_target_errors() {
  setup_stubs
  local out="" status=0
  out="$(BBAPPROVE_BIN="$TEST_TMP/nope" run_wrapper)" || status=$?
  assert_eq "$status" "127" "exit 127 when target missing"
  assert_contains "$out" "not found or not executable" "clear error message"
  cleanup_test_tmp; TEST_TMP=""
}

run_tests "$@"
