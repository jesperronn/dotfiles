#!/usr/bin/env bash
# shellcheck disable=SC1090,SC1091
set -euo pipefail

DOTFILES_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
SCRIPT_UNDER_TEST="$DOTFILES_ROOT/bin/npm-global-audit"

source "$DOTFILES_ROOT/bin/lib/bash_test.sh"

# Create stub npm binary once at module level (shared across all tests)
MODULE_TEMP_DIR=""
MODULE_STUB_DIR=""
MODULE_EMPTY_STUB_DIR=""
FAST_CAPTURE_FILE=""  # Reuse a single temp file for fast captures

# Global cleanup: remove temp directories
cleanup_test_temps() {
  [[ -n "$MODULE_TEMP_DIR" && -d "$MODULE_TEMP_DIR" ]] && rm -rf "$MODULE_TEMP_DIR" || true
  [[ -n "$FAST_CAPTURE_FILE" && -f "$FAST_CAPTURE_FILE" ]] && rm -f "$FAST_CAPTURE_FILE" || true
  find . -maxdepth 1 -type d -name "ptest_*" -exec rm -rf {} + 2>/dev/null || true
}
trap cleanup_test_temps EXIT

setup_module() {
  MODULE_TEMP_DIR="$(mktemp -d)"
  FAST_CAPTURE_FILE="${MODULE_TEMP_DIR}/capture.txt"
  touch "$FAST_CAPTURE_FILE"

  MODULE_STUB_DIR="${MODULE_TEMP_DIR}/stub"
  mkdir -p "$MODULE_STUB_DIR"

  # Write the npm stub once at module level using heredoc (fast)
  cat >"${MODULE_STUB_DIR}/npm" <<'NPMSTUB'
#!/usr/bin/env bash
set -euo pipefail
[[ -n "${NPM_STUB_LOG:-}" ]] && printf '%s\n' "$*" >>"$NPM_STUB_LOG"
cmd="" i=1 n=$#
while (( i <= n )); do
  eval "a=\${$i}"
  [[ "$a" == --prefix || "$a" == --root ]] && { ((i+=2)); continue; }
  [[ "$a" == -* ]] && { ((i++)); continue; }
  cmd="$a"
  break
  ((i++))
done
case "$cmd" in
  ls)
    printf '{"dependencies":{"jumbo-cli":{"version":"3.23.0"},"svgo":{"version":"4.1.0"},"cline":{"version":"3.0.61"}}}\n'
    ;;
  install)
    [[ -n "${NPM_STUB_SPEC_FILE:-}" && $# -gt 0 ]] && printf '%s\n' "${@: -1}" >"$NPM_STUB_SPEC_FILE"
    ;;
  audit)
    spec=""
    [[ -n "${NPM_STUB_SPEC_FILE:-}" && -f "$NPM_STUB_SPEC_FILE" ]] && spec="$(cat "$NPM_STUB_SPEC_FILE")"
    if [[ -z "${NPM_STUB_FIXTURES:-}" ]]; then
      case "$spec" in
        jumbo-cli@3.23.0) printf '{"metadata":{"vulnerabilities":{"total":0,"low":0,"moderate":0,"high":0,"critical":0,"info":0}}}\n' ;;
        svgo@4.1.0) printf '{"metadata":{"vulnerabilities":{"total":3,"low":2,"moderate":1,"high":0,"critical":0,"info":0}}}\n' ;;
        cline@3.0.61) printf '{"metadata":{"vulnerabilities":{"total":33,"low":8,"moderate":16,"high":9,"critical":0,"info":0}}}\n' ;;
        *) printf 'registry unavailable\n' >&2; exit 1 ;;
      esac
    else
      jq -r --arg spec "$spec" '.[$spec] | if . == null then error("registry unavailable") elif type == "string" then error(.) elif .error then error(.error) else {metadata: {vulnerabilities: .}} end | @json' "$NPM_STUB_FIXTURES" 2>/dev/null || (printf 'registry unavailable\n' >&2; exit 1)
    fi
    ;;
  *) printf 'npm stub: unknown command: %s\n' "$cmd" >&2; exit 1 ;;
esac
NPMSTUB
  chmod +x "${MODULE_STUB_DIR}/npm"

  # Create empty npm stub at module level for test_empty_packages
  MODULE_EMPTY_STUB_DIR="${MODULE_TEMP_DIR}/empty"
  mkdir -p "$MODULE_EMPTY_STUB_DIR"
  cat >"${MODULE_EMPTY_STUB_DIR}/npm" <<'NPMEMPTY'
#!/usr/bin/env bash
set -euo pipefail
cmd=""
for a in "$@"; do
  if [[ "$a" == -* ]]; then continue; fi
  cmd="$a"
  break
done
if [[ "$cmd" == "ls" ]]; then
  printf '%s\n' '{"dependencies":{}}'
fi
NPMEMPTY
  chmod +x "${MODULE_EMPTY_STUB_DIR}/npm"
}

# No longer needed: stub is created once at module level
make_stub_npm() {
  :  # Stub creation now done at module load time
}

# Write a fixture file mapping an installed spec to either a vulnerabilities
# object or {"error": "<message>"} and echo its path.
write_fixture() {
  local file="$1"
  shift
  printf '%s' "$@" >"$file"
  printf '%s\n' "$file"
}

# Prepare a scratch dir with a stub npm and an installed-spec file whose path is
# exported so the script and its npm children share it. Resets fixtures.
prepare() {
  W_DIR="${MODULE_TEMP_DIR}/test_$$"
  mkdir -p "$W_DIR"
  W_STUB="$MODULE_STUB_DIR"
  W_SPEC="${W_DIR}/spec.txt"
  rm -f "$W_SPEC"  # Clear spec file from previous test
  export NPM_STUB_SPEC_FILE="$W_SPEC"
  unset NPM_STUB_FIXTURES
}

# Run the script under test with a stub npm dir; sets R_OUTPUT and R_STATUS.
# $1 = stub bin dir, $2 = NO_COLOR value ("" disables the override).
run_script() {
  local stub="$1"
  local color_mode="$2"
  shift 2

  R_STATUS=0
  set +e
  R_OUTPUT="$(env PATH="${stub}:${PATH}" "NO_COLOR=${color_mode}" "$SCRIPT_UNDER_TEST" "$@" 2>&1)"
  R_STATUS=$?
  set -e
}

test_output_rows_no_color() {
  prepare
  run_script "$W_STUB" "1"

  assert_status "0" "$R_STATUS" "plain run exits 0 with valid metadata"
  assert_contains "$R_OUTPUT" "jumbo-cli@3.23.0" "output shows jumbo-cli spec"
  assert_contains "$R_OUTPUT" "0 vulnerabilities" "jumbo-cli reports zero"
  assert_contains "$R_OUTPUT" "svgo@4.1.0" "output shows svgo spec"
  assert_contains "$R_OUTPUT" "3 vulnerabilities (2 low, 1 moderate, 0 high)" "svgo breakdown"
  assert_contains "$R_OUTPUT" "cline@3.0.61" "output shows cline spec"
  assert_contains "$R_OUTPUT" "33 vulnerabilities (8 low, 16 moderate, 9 high)" "cline breakdown"
  assert_not_contains "$R_OUTPUT" $'\033[' "no ANSI escapes in plain mode"
}

test_invocation_log_safety() {
  prepare
  local log_file="${W_DIR}/log.txt"

  R_STATUS=0
  set +e
  R_OUTPUT="$(env PATH="${W_STUB}:${PATH}" NO_COLOR=1 NPM_STUB_LOG="$log_file" "$SCRIPT_UNDER_TEST" 2>&1)"
  R_STATUS=$?
  set -e

  assert_status "0" "$R_STATUS" "safety run exits 0"
  assert_contains "$(cat "$log_file")" "--no-audit ls -g --depth=0 --json" "discovery uses safe ls flags"
  assert_contains "$(cat "$log_file")" "install --package-lock-only --ignore-scripts --no-audit jumbo-cli@3.23.0" "install pins spec with safe flags"
  assert_contains "$(cat "$log_file")" "cline@3.0.61" "install records a literal installed spec"
  assert_not_contains "$(cat "$log_file")" "update -g" "never runs npm update -g"
  assert_not_contains "$(cat "$log_file")" "audit fix" "never runs audit fix"
  assert_not_contains "$(cat "$log_file")" "--global audit" "never runs global audit"
}

test_critical_breakdown() {
  prepare
  local fixture_file
  fixture_file="$(write_fixture "${W_DIR}/fixture.json" \
    '{"jumbo-cli@3.23.0":{"total":0,"low":0,"moderate":0,"high":0,"critical":0,"info":0},' \
    '"svgo@4.1.0":{"total":3,"low":2,"moderate":1,"high":0,"critical":0,"info":0},' \
    '"cline@3.0.61":{"total":3,"low":0,"moderate":0,"high":1,"critical":2,"info":0}}')"
  export NPM_STUB_FIXTURES="$fixture_file"

  run_script "$W_STUB" "1"

  assert_status "0" "$R_STATUS" "critical fixture exits 0"
  assert_contains "$R_OUTPUT" "3 vulnerabilities (0 low, 0 moderate, 1 high, 2 critical)" "critical breakdown includes critical"
}

test_audit_failure_continues() {
  prepare
  local fixture_file
  fixture_file="$(write_fixture "${W_DIR}/fixture.json" \
    '{"jumbo-cli@3.23.0":{"total":0,"low":0,"moderate":0,"high":0,"critical":0,"info":0},' \
    '"svgo@4.1.0":{"error":"registry unavailable"},' \
    '"cline@3.0.61":{"total":33,"low":8,"moderate":16,"high":9,"critical":0,"info":0}}')"
  export NPM_STUB_FIXTURES="$fixture_file"

  run_script "$W_STUB" "1"

  assert_status "1" "$R_STATUS" "a package failure exits 1"
  assert_contains "$R_OUTPUT" "cline@3.0.61" "successful package still renders"
  assert_contains "$R_OUTPUT" "33 vulnerabilities (8 low, 16 moderate, 9 high)" "successful package row intact"
  assert_contains "$R_OUTPUT" "svgo@4.1.0" "failed package spec still listed"
  assert_contains "$R_OUTPUT" "audit failed: registry unavailable" "failure renders a readable row"
}

test_empty_packages() {
  R_STATUS=0
  set +e
  R_OUTPUT="$(env PATH="${MODULE_EMPTY_STUB_DIR}:${PATH}" NO_COLOR=1 "$SCRIPT_UNDER_TEST" 2>&1)"
  R_STATUS=$?
  set -e

  assert_status "0" "$R_STATUS" "empty global list exits 0"
  assert_contains "$R_OUTPUT" "No global npm packages found." "empty list emits no-packages message"
}

test_help() {
  prepare
  run_script "$W_STUB" "1" --help

  assert_status "0" "$R_STATUS" "--help exits 0"
  assert_contains "$R_OUTPUT" "--color" "help mentions --color"
  assert_contains "$R_OUTPUT" "--no-color" "help mentions --no-color"
  assert_contains "$R_OUTPUT" "freshly resolved transitive dependencies" "help documents temporary resolution"
}

test_color_flag_emits_sgr() {
  prepare
  run_script "$W_STUB" "" --color

  assert_status "0" "$R_STATUS" "--color run exits 0"
  assert_contains "$R_OUTPUT" $'\033[' "forced color emits an ANSI SGR sequence when captured"
}

test_unknown_option_exits_2() {
  prepare
  run_script "$W_STUB" "1" --bogus

  assert_status "2" "$R_STATUS" "unknown option exits 2"
  assert_contains "$R_OUTPUT" "unknown option" "unknown option reports the problem"
}

# Setup module before running tests
setup_module

run_tests "$@"
