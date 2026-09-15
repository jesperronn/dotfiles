#!/usr/bin/env bash
# shellcheck disable=SC1090,SC1091
set -euo pipefail

DOTFILES_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
SCRIPT_UNDER_TEST="$DOTFILES_ROOT/bin/npm-global-audit"

source "$DOTFILES_ROOT/bin/lib/bash_test.sh"

# Create a fake `npm` in DIR that records every invocation to $NPM_STUB_LOG,
# returns a fixed global-list response for `ls`, records the installed spec to
# $NPM_STUB_SPEC_FILE for `install`, and dispatches `audit` responses by spec
# using an optional fixture file at $NPM_STUB_FIXTURES (canonical defaults when
# unset).
make_stub_npm() {
  local dir="$1"
  mkdir -p "$dir"
  cat >"$dir/npm" <<'NPMSTUB'
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
      node -e 'const fs=require("fs");const map=JSON.parse(fs.readFileSync(process.env.NPM_STUB_FIXTURES,"utf8")||"{}");const v=map[process.argv[1]]||null;if(v===null){process.stderr.write("registry unavailable\n");process.exit(1)}if(typeof v==="string"){process.stderr.write(v+"\n");process.exit(1)}if(v&&v.error){process.stderr.write(String(v.error)+"\n");process.exit(1)}process.stdout.write(JSON.stringify({metadata:{vulnerabilities:v}})+"\n")' "$spec"
    fi
    ;;
  *) printf 'npm stub: unknown command: %s\n' "$cmd" >&2; exit 1 ;;
esac
NPMSTUB
  chmod +x "$dir/npm"
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
  W_DIR="$(mktemp -d)"
  W_STUB="${W_DIR}/stub"
  W_SPEC="${W_DIR}/spec.txt"
  make_stub_npm "$W_STUB"
  export NPM_STUB_SPEC_FILE="$W_SPEC"
  unset NPM_STUB_FIXTURES
}

# Run the script under test with a stub npm dir; sets R_OUTPUT and R_STATUS.
# $1 = stub bin dir, $2 = NO_COLOR value ("" disables the override).
run_script() {
  local stub="$1"
  local color_mode="$2"
  shift 2

  R_OUTPUT=""
  R_STATUS=0
  capture_command R_OUTPUT R_STATUS env PATH="${stub}:${PATH}" "NO_COLOR=${color_mode}" \
    "$SCRIPT_UNDER_TEST" "$@"
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

  rm -rf "$W_DIR"
}

test_invocation_log_safety() {
  prepare
  local log_file="${W_DIR}/log.txt"

  R_OUTPUT=""
  R_STATUS=0
  capture_command R_OUTPUT R_STATUS env PATH="${W_STUB}:${PATH}" NO_COLOR=1 \
    NPM_STUB_LOG="$log_file" "$SCRIPT_UNDER_TEST"

  assert_status "0" "$R_STATUS" "safety run exits 0"
  assert_contains "$(cat "$log_file")" "--no-audit ls -g --depth=0 --json" "discovery uses safe ls flags"
  assert_contains "$(cat "$log_file")" "install --package-lock-only --ignore-scripts --no-audit jumbo-cli@3.23.0" "install pins spec with safe flags"
  assert_contains "$(cat "$log_file")" "cline@3.0.61" "install records a literal installed spec"
  assert_not_contains "$(cat "$log_file")" "update -g" "never runs npm update -g"
  assert_not_contains "$(cat "$log_file")" "audit fix" "never runs audit fix"
  assert_not_contains "$(cat "$log_file")" "--global audit" "never runs global audit"

  rm -rf "$W_DIR"
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

  rm -rf "$W_DIR"
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

  rm -rf "$W_DIR"
}

test_empty_packages() {
  local work_dir=""
  local stub_dir=""

  work_dir="$(mktemp -d)"
  stub_dir="${work_dir}/stub"
  mkdir -p "$stub_dir"
  # Stub whose global list is empty; discovery must short-circuit before audits.
  cat >"${stub_dir}/npm" <<'NPMEMPTY'
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
  chmod +x "${stub_dir}/npm"

  R_OUTPUT=""
  R_STATUS=0
  capture_command R_OUTPUT R_STATUS env PATH="${stub_dir}:${PATH}" NO_COLOR=1 "$SCRIPT_UNDER_TEST"

  assert_status "0" "$R_STATUS" "empty global list exits 0"
  assert_contains "$R_OUTPUT" "No global npm packages found." "empty list emits no-packages message"

  rm -rf "$work_dir"
}

test_help() {
  prepare
  run_script "$W_STUB" "1" --help

  assert_status "0" "$R_STATUS" "--help exits 0"
  assert_contains "$R_OUTPUT" "--color" "help mentions --color"
  assert_contains "$R_OUTPUT" "--no-color" "help mentions --no-color"
  assert_contains "$R_OUTPUT" "freshly resolved transitive dependencies" "help documents temporary resolution"

  rm -rf "$W_DIR"
}

test_color_flag_emits_sgr() {
  prepare
  run_script "$W_STUB" "" --color

  assert_status "0" "$R_STATUS" "--color run exits 0"
  assert_contains "$R_OUTPUT" $'\033[' "forced color emits an ANSI SGR sequence when captured"

  rm -rf "$W_DIR"
}

test_unknown_option_exits_2() {
  prepare
  run_script "$W_STUB" "1" --bogus

  assert_status "2" "$R_STATUS" "unknown option exits 2"
  assert_contains "$R_OUTPUT" "unknown option" "unknown option reports the problem"

  rm -rf "$W_DIR"
}

run_tests "$@"
