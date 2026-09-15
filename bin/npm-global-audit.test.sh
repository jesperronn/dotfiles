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
TTY_PID=""
TTY_TRANSCRIPT=""
TEST_BG_PIDS=()
MODULE_CPU_LOG=""
MODULE_SLEEP_LOG=""

# Release test barriers so tracked commands can finish before their scratch
# directories are removed, even when an assertion interrupts a test.
release_test_barriers() {
  local started release
  [[ -n "$MODULE_TEMP_DIR" && -d "$MODULE_TEMP_DIR" ]] || return 0
  while IFS= read -r started; do
    release="${started%/started.*}/release.${started##*.}"
    : >"$release"
  done < <(find "$MODULE_TEMP_DIR" -type f -name 'started.*' 2>/dev/null)
  while IFS= read -r started; do
    : >"${started%/outdated.started}/outdated.release"
  done < <(find "$MODULE_TEMP_DIR" -type f -name 'outdated.started' 2>/dev/null)
}

track_test_pid() {
  TEST_BG_PIDS+=("$1")
}

untrack_test_pid() {
  local target="$1" pid remaining=()
  for pid in "${TEST_BG_PIDS[@]}"; do
    [[ "$pid" == "$target" ]] || remaining+=("$pid")
  done
  TEST_BG_PIDS=("${remaining[@]}")
}

# Global cleanup: reap background commands before removing their barriers.
cleanup_test_temps() {
  local pid running
  set +e
  for pid in "${TEST_BG_PIDS[@]}"; do
    while :; do
      running=" $(jobs -pr) "
      [[ "$running" == *" $pid "* ]] || break
      release_test_barriers
    done
    wait "$pid" 2>/dev/null
  done
  set -e
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
  MODULE_CPU_LOG="${MODULE_TEMP_DIR}/cpu.log"
  MODULE_SLEEP_LOG="${MODULE_TEMP_DIR}/sleep.log"
  : >"$MODULE_CPU_LOG"
  : >"$MODULE_SLEEP_LOG"
  export NPM_STUB_CPU_LOG="$MODULE_CPU_LOG"
  export NPM_STUB_SLEEP_LOG="$MODULE_SLEEP_LOG"

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
    if [[ -n "${NPM_STUB_LIST_JSON:-}" ]]; then
      printf '%s\n' "$NPM_STUB_LIST_JSON"
    else
      printf '{"dependencies":{"jumbo-cli":{"version":"3.23.0"},"svgo":{"version":"4.1.0"},"cline":{"version":"3.0.61"}}}\n'
    fi
    ;;
  install)
    prefix=""
    for ((i = 1; i <= $#; i++)); do
      eval "a=\${$i}"
      if [[ "$a" == "--prefix" ]]; then
        ((i++))
        eval "prefix=\${$i}"
        break
      fi
    done
    spec="${*: -1}"
    if [[ -n "$prefix" ]]; then
      printf '%s\n' "$spec" >"${prefix}/.npm-global-audit-spec"
    fi
    [[ -n "${NPM_STUB_SPEC_FILE:-}" ]] && printf '%s\n' "$spec" >"$NPM_STUB_SPEC_FILE"
    if [[ -n "${NPM_STUB_EVENT_LOG:-}" ]]; then
      printf 'install-start %s\n' "$spec" >>"$NPM_STUB_EVENT_LOG"
    fi
    if [[ -n "${NPM_STUB_BARRIER_DIR:-}" ]]; then
      safe="${spec//[^[:alnum:]]/_}"
      : >"${NPM_STUB_BARRIER_DIR}/started.${safe}"
      while [[ ! -e "${NPM_STUB_BARRIER_DIR}/release.${safe}" ]]; do
        if [[ "${NPM_STUB_POLL_INTERVAL:-0}" == "0" ]]; then :; else sleep "$NPM_STUB_POLL_INTERVAL"; fi
      done
    fi
    [[ -n "${NPM_STUB_EVENT_LOG:-}" ]] && printf 'install-end %s\n' "$spec" >>"$NPM_STUB_EVENT_LOG"
    :
    ;;
  audit)
    spec=""
    prefix=""
    for ((i = 1; i <= $#; i++)); do
      eval "a=\${$i}"
      if [[ "$a" == "--prefix" ]]; then
        ((i++))
        eval "prefix=\${$i}"
        break
      fi
    done
    [[ -n "$prefix" && -f "${prefix}/.npm-global-audit-spec" ]] && spec="$(cat "${prefix}/.npm-global-audit-spec")"
    [[ -z "$spec" && -n "${NPM_STUB_SPEC_FILE:-}" && -f "$NPM_STUB_SPEC_FILE" ]] && spec="$(cat "$NPM_STUB_SPEC_FILE")"
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
  outdated)
    if [[ -n "${NPM_STUB_OUTDATED_BARRIER_DIR:-}" ]]; then
      : >"${NPM_STUB_OUTDATED_BARRIER_DIR}/outdated.started"
      while [[ ! -e "${NPM_STUB_OUTDATED_BARRIER_DIR}/outdated.release" ]]; do
        if [[ "${NPM_STUB_POLL_INTERVAL:-0}" == "0" ]]; then :; else sleep "$NPM_STUB_POLL_INTERVAL"; fi
      done
    fi
    printf '%s\n' '{"jumbo-cli":{"current":"3.23.0","latest":"3.24.0"}}'
    ;;
  *) printf 'npm stub: unknown command: %s\n' "$cmd" >&2; exit 1 ;;
esac
NPMSTUB
  chmod +x "${MODULE_STUB_DIR}/npm"

  cat >"${MODULE_STUB_DIR}/getconf" <<'GETCONFSTUB'
#!/usr/bin/env bash
set -euo pipefail
printf 'getconf %s\n' "$*" >>"$NPM_STUB_CPU_LOG"
printf '2\n'
GETCONFSTUB
  chmod +x "${MODULE_STUB_DIR}/getconf"

  cat >"${MODULE_STUB_DIR}/sysctl" <<'SYSCTLSTUB'
#!/usr/bin/env bash
set -euo pipefail
printf 'sysctl %s\n' "$*" >>"$NPM_STUB_CPU_LOG"
printf '2\n'
SYSCTLSTUB
  chmod +x "${MODULE_STUB_DIR}/sysctl"

  cat >"${MODULE_STUB_DIR}/sleep" <<'SLEEPSTUB'
#!/usr/bin/env bash
set -euo pipefail
printf '%s\n' "${1:-}" >>"$NPM_STUB_SLEEP_LOG"
SLEEPSTUB
  chmod +x "${MODULE_STUB_DIR}/sleep"

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

MANY_SPECS=()

prepare_many_package_data() {
  local count="$1" list_json='{"dependencies":{' fixture_json='{' separator="" index name spec
  MANY_SPECS=()
  for ((index = 1; index <= count; index++)); do
    printf -v name 'package-%02d' "$index"
    spec="${name}@1.0.0"
    MANY_SPECS+=("$spec")
    list_json+="${separator}\"${name}\":{\"version\":\"1.0.0\"}"
    fixture_json+="${separator}\"${spec}\":{\"total\":0,\"low\":0,\"moderate\":0,\"high\":0,\"critical\":0,\"info\":0}"
    separator=","
  done
  list_json+='}}'
  fixture_json+='}'
  export NPM_STUB_LIST_JSON="$list_json"
  printf '%s' "$fixture_json" >"${W_DIR}/many-fixtures.json"
  export NPM_STUB_FIXTURES="${W_DIR}/many-fixtures.json"
}

# Prepare a scratch dir with a stub npm and an installed-spec file whose path is
# exported so the script and its npm children share it. Resets fixtures.
prepare() {
  W_DIR="$(mktemp -d "${MODULE_TEMP_DIR}/test.XXXXXX")"
  W_STUB="$MODULE_STUB_DIR"
  W_SPEC="${W_DIR}/spec.txt"
  rm -f "$W_SPEC"  # Clear spec file from previous test
  export NPM_STUB_SPEC_FILE="$W_SPEC"
  unset NPM_STUB_FIXTURES NPM_STUB_LIST_JSON NPM_STUB_BARRIER_DIR NPM_STUB_OUTDATED_BARRIER_DIR NPM_STUB_EVENT_LOG
}

spec_key() {
  local spec="$1"
  printf '%s' "${spec//[^[:alnum:]]/_}"
}

wait_for_file() {
  local file="$1" attempt
  for ((attempt = 0; attempt < 1000; attempt++)); do
    [[ -e "$file" ]] && return 0
    sleep "${TEST_POLL_INTERVAL:-0}"
  done
  return 1
}

wait_for_transcript() {
  local needle="$1" attempt text=""
  for ((attempt = 0; attempt < 1000; attempt++)); do
    [[ -f "$TTY_TRANSCRIPT" ]] && text="$(<"$TTY_TRANSCRIPT")"
    [[ "$text" == *"$needle"* ]] && return 0
    sleep "${TEST_POLL_INTERVAL:-0}"
  done
  return 1
}

release_package() {
  local barrier_dir="$1" spec="$2"
  : >"${barrier_dir}/release.$(spec_key "$spec")"
}

start_tty_run() {
  local package_barrier="$1" outdated_barrier="$2" columns="${3:-80}" rows="${4:-24}"
  TTY_TRANSCRIPT="${W_DIR}/tty.transcript"
  env PATH="${W_STUB}:${PATH}" NO_COLOR=1 \
    NPM_STUB_BARRIER_DIR="$package_barrier" \
    NPM_STUB_OUTDATED_BARRIER_DIR="$outdated_barrier" \
    NPM_STUB_POLL_INTERVAL=0 NPM_GLOBAL_AUDIT_POLL_INTERVAL=0 \
    NPM_GLOBAL_AUDIT_TTY_COLUMNS="$columns" \
    NPM_GLOBAL_AUDIT_TTY_ROWS="$rows" \
    /usr/bin/script -q /dev/null "$SCRIPT_UNDER_TEST" --jobs 3 \
    >"$TTY_TRANSCRIPT" 2>&1 &
  TTY_PID=$!
  track_test_pid "$TTY_PID"
}

finish_tty_run() {
  R_STATUS=0
  set +e
  wait "$TTY_PID"
  R_STATUS=$?
  set -e
  untrack_test_pid "$TTY_PID"
  TTY_PID=""
  R_OUTPUT="$(<"$TTY_TRANSCRIPT")"
}

count_occurrences() {
  local text="$1" needle="$2" count=0
  while [[ "$text" == *"$needle"* ]]; do
    text="${text#*"$needle"}"
    count=$((count + 1))
  done
  printf '%s' "$count"
}

# Replay the progress UI at a fixed terminal width. This checks the screen
# resulting from cursor movement instead of merely matching raw escape bytes.
render_visible_screen() {
  local transcript_file="$1" columns="$2" rows="${3:-200}"
  node -e '
    const fs = require("fs");
    const input = fs.readFileSync(process.argv[1], "utf8");
    const width = Number(process.argv[2]);
    const height = Number(process.argv[3]);
    const rows = Array.from({length: height}, () => Array(width).fill(" "));
    let row = 0, col = 0, wrap = true, wrapPending = false;
    function move(delta) {
      row = Math.max(0, Math.min(height - 1, row + delta));
      wrapPending = false;
    }
    function lineFeed() {
      if (row === height - 1) {
        rows.shift();
        rows.push(Array(width).fill(" "));
      } else {
        row++;
      }
      wrapPending = false;
    }
    for (let i = 0; i < input.length;) {
      const ch = input[i];
      if (ch === "\u001b" && input[i + 1] === "[") {
        const match = input.slice(i + 2).match(/^([?0-9;]*)([A-Za-z])/);
        if (match) {
          const param = match[1], command = match[2];
          const amount = Number(param || 1);
          if (command === "A") move(-amount);
          else if (command === "B") move(amount);
          else if (command === "K" && (param === "2" || param === "")) rows[row].fill(" ");
          else if (command === "l" && param === "?7") { wrap = false; wrapPending = false; }
          else if (command === "h" && param === "?7") { wrap = true; wrapPending = false; }
          i += match[0].length + 2;
          continue;
        }
      }
      if (ch === "\r") { col = 0; wrapPending = false; i++; continue; }
      if (ch === "\n") { lineFeed(); i++; continue; }
      if (ch === "\b") { col = Math.max(0, col - 1); wrapPending = false; i++; continue; }
      if (ch < " ") { i++; continue; }
      if (wrap && wrapPending) { lineFeed(); col = 0; }
      rows[row][col] = ch;
      if (col < width - 1) col++;
      else if (wrap) wrapPending = true;
      i++;
    }
    process.stdout.write(rows.map((chars) => chars.join("").replace(/ +$/, ""))
      .filter((line) => line.length > 0).join("\n"));
  ' "$transcript_file" "$columns" "$rows"
}

# Run the script under test with a stub npm dir; sets R_OUTPUT and R_STATUS.
# $1 = stub bin dir, $2 = NO_COLOR value ("" disables the override).
run_script() {
  local stub="$1"
  local color_mode="$2"
  shift 2

  R_STATUS=0
  set +e
  R_OUTPUT="$(env PATH="${stub}:${PATH}" "NO_COLOR=${color_mode}" \
    NPM_GLOBAL_AUDIT_POLL_INTERVAL=0 "$SCRIPT_UNDER_TEST" "$@" 2>&1)"
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
  assert_not_contains "$R_OUTPUT" "pending" "redirected output has no pending rows"
  assert_not_contains "$R_OUTPUT" "Resolving and auditing packages:" "redirected output has no progress status"
  assert_not_contains "$R_OUTPUT" $'\033[' "no ANSI escapes in plain mode"
}

test_invocation_log_safety() {
  prepare
  local log_file="${W_DIR}/log.txt"

  R_STATUS=0
  set +e
  R_OUTPUT="$(env PATH="${W_STUB}:${PATH}" NO_COLOR=1 NPM_STUB_LOG="$log_file" \
    NPM_GLOBAL_AUDIT_POLL_INTERVAL=0 "$SCRIPT_UNDER_TEST" 2>&1)"
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
  R_OUTPUT="$(env PATH="${MODULE_EMPTY_STUB_DIR}:${MODULE_STUB_DIR}:${PATH}" NO_COLOR=1 \
    NPM_GLOBAL_AUDIT_POLL_INTERVAL=0 "$SCRIPT_UNDER_TEST" 2>&1)"
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

# A regression in the worker limiter would serialize the second install after
# the first has completed. The event order is observable at the fake npm
# boundary and does not depend on timing measurements.
test_jobs_run_multiple_packages_before_first_install_finishes() {
  prepare
  local event_log="${W_DIR}/events.txt"
  local barrier_dir="${W_DIR}/barrier"
  mkdir -p "$barrier_dir"

  env PATH="${W_STUB}:${PATH}" NO_COLOR=1 NPM_STUB_EVENT_LOG="$event_log" \
    NPM_STUB_BARRIER_DIR="$barrier_dir" NPM_STUB_POLL_INTERVAL=0 \
    NPM_GLOBAL_AUDIT_POLL_INTERVAL=0 "$SCRIPT_UNDER_TEST" --jobs 2 \
    >"${W_DIR}/parallel.output" 2>&1 &
  local run_pid=$!
  track_test_pid "$run_pid"

  local first_started=0 second_started=0 initial_events=""
  wait_for_file "${barrier_dir}/started.$(spec_key 'cline@3.0.61')" && first_started=1
  wait_for_file "${barrier_dir}/started.$(spec_key 'jumbo-cli@3.23.0')" && second_started=1
  initial_events="$(<"$event_log")"
  release_package "$barrier_dir" "cline@3.0.61"
  release_package "$barrier_dir" "jumbo-cli@3.23.0"
  wait_for_file "${barrier_dir}/started.$(spec_key 'svgo@4.1.0')"
  release_package "$barrier_dir" "svgo@4.1.0"

  R_STATUS=0
  set +e
  wait "$run_pid"
  R_STATUS=$?
  set -e
  untrack_test_pid "$run_pid"
  R_OUTPUT="$(<"${W_DIR}/parallel.output")"

  assert_status "0" "$R_STATUS" "two workers complete valid package audits"
  assert_status "1" "$first_started" "first install reaches the barrier"
  assert_status "1" "$second_started" "second install starts before the first is released"
  assert_contains "$initial_events" "install-start cline@3.0.61" "first bounded worker starts before release"
  assert_contains "$initial_events" "install-start jumbo-cli@3.23.0" "second bounded worker starts before release"
  assert_not_contains "$initial_events" "install-end" "neither initial worker completes before release"
  assert_not_contains "$initial_events" "install-start svgo@4.1.0" "third worker remains queued at the two-job limit"
  assert_contains "$R_OUTPUT" "cline@3.0.61" "concurrent run retains package output"
  assert_contains "$R_OUTPUT" "jumbo-cli@3.23.0" "concurrent run retains every package output"
}

# The third sorted worker must be rendered while the first two remain blocked;
# this catches schedulers that wait for the oldest PID instead of completions.
test_tty_renders_initial_frame_out_of_order_completion_and_cleanup() {
  prepare
  local barrier_dir="${W_DIR}/barrier"
  mkdir -p "$barrier_dir"
  start_tty_run "$barrier_dir" ""

  local spec
  for spec in "cline@3.0.61" "jumbo-cli@3.23.0" "svgo@4.1.0"; do
    wait_for_file "${barrier_dir}/started.$(spec_key "$spec")"
  done

  local initial="" expected_pending=""
  initial="$(<"$TTY_TRANSCRIPT")"
  initial="${initial//$'\r'/}"
  expected_pending="$(printf '%-16s  pending\n%-16s  pending\n%-16s  pending' \
    'cline@3.0.61' 'jumbo-cli@3.23.0' 'svgo@4.1.0')"

  release_package "$barrier_dir" "svgo@4.1.0"
  local third_rendered=0
  wait_for_transcript "svgo@4.1.0        3 vulnerabilities (2 low, 1 moderate, 0 high)" && third_rendered=1
  local mid=""
  mid="$(<"$TTY_TRANSCRIPT")"
  mid="${mid//$'\r'/}"

  release_package "$barrier_dir" "cline@3.0.61"
  release_package "$barrier_dir" "jumbo-cli@3.23.0"
  finish_tty_run
  local final="${R_OUTPUT//$'\r'/}"

  assert_status "0" "$R_STATUS" "TTY progress run exits 0"
  assert_contains "$initial" "$expected_pending" "TTY initial frame lists every sorted package as pending"
  assert_eq "1" "$(count_occurrences "$initial" 'Resolving and auditing packages: 0/3 complete')" "TTY initial frame has one primary status row"
  assert_status "1" "$third_rendered" "third worker replaces its row before earlier workers are released"
  assert_contains "$mid" "cline@3.0.61      pending" "first row remains pending after third worker finishes"
  assert_contains "$mid" "jumbo-cli@3.23.0  pending" "second row remains pending after third worker finishes"
  assert_contains "$mid" "Resolving and auditing packages: 1/3 complete" "out-of-order completion increments progress"
  assert_contains "$final" $'\033[3A\033[2Kcline@3.0.61      33 vulnerabilities (8 low, 16 moderate, 9 high)' "first result replaces the first sorted row"
  assert_contains "$final" $'\033[2A\033[2Kjumbo-cli@3.23.0  0 vulnerabilities — outdated, 3.24.0 available' "second result replaces the second sorted row"
  assert_contains "$final" $'\033[1A\033[2Ksvgo@4.1.0        3 vulnerabilities (2 low, 1 moderate, 0 high)' "third result replaces the third sorted row"
  assert_contains "$final" $'\033[2K\033[1B\033[2K\033[1A\033[?7h\nNext:' "transient rows are erased and autowrap restored before Next"
  assert_not_contains "$final" $'Resolving and auditing packages: 3/3 complete\n\nNext:' "visible progress status is cleared before Next"
}

test_tty_does_not_block_workers_on_update_lookup() {
  prepare
  local package_barrier="${W_DIR}/package-barrier"
  local outdated_barrier="${W_DIR}/outdated-barrier"
  mkdir -p "$package_barrier" "$outdated_barrier"
  start_tty_run "$package_barrier" "$outdated_barrier"

  local outdated_started=0 pending_rendered=0 install_started=0
  wait_for_file "${outdated_barrier}/outdated.started" && outdated_started=1
  wait_for_transcript "Checking for available updates..." && pending_rendered=1
  wait_for_file "${package_barrier}/started.$(spec_key 'cline@3.0.61')" && install_started=1

  : >"${outdated_barrier}/outdated.release"
  local spec
  for spec in "cline@3.0.61" "jumbo-cli@3.23.0" "svgo@4.1.0"; do
    wait_for_file "${package_barrier}/started.$(spec_key "$spec")"
    release_package "$package_barrier" "$spec"
  done
  finish_tty_run

  assert_status "0" "$R_STATUS" "TTY run with delayed update lookup exits 0"
  assert_status "1" "$outdated_started" "update lookup reaches its test-controlled barrier"
  assert_status "1" "$pending_rendered" "pending rows and update phase render while lookup is held"
  assert_status "1" "$install_started" "package work starts before update lookup is released"
  assert_contains "${R_OUTPUT//$'\r'/}" "Checking for available updates..." "TTY identifies the held update phase"
}

test_tty_completed_row_gains_delayed_update_annotation() {
  prepare
  local package_barrier="${W_DIR}/package-barrier"
  local outdated_barrier="${W_DIR}/outdated-barrier"
  local spec before_update="" after_update=""
  mkdir -p "$package_barrier" "$outdated_barrier"
  start_tty_run "$package_barrier" "$outdated_barrier"

  wait_for_file "${outdated_barrier}/outdated.started"
  for spec in "cline@3.0.61" "jumbo-cli@3.23.0" "svgo@4.1.0"; do
    wait_for_file "${package_barrier}/started.$(spec_key "$spec")"
  done
  release_package "$package_barrier" "jumbo-cli@3.23.0"
  wait_for_transcript "Resolving and auditing packages: 1/3 complete"
  before_update="$(<"$TTY_TRANSCRIPT")"

  : >"${outdated_barrier}/outdated.release"
  wait_for_transcript "0 vulnerabilities — outdated, 3.24.0 available"
  after_update="$(<"$TTY_TRANSCRIPT")"

  release_package "$package_barrier" "cline@3.0.61"
  release_package "$package_barrier" "svgo@4.1.0"
  finish_tty_run

  assert_contains "${before_update//$'\r'/}" "jumbo-cli@3.23.0  0 vulnerabilities" "package completes while update lookup is blocked"
  assert_not_contains "$before_update" "outdated, 3.24.0 available" "completed row initially has no unavailable update annotation"
  assert_contains "${after_update//$'\r'/}" "jumbo-cli@3.23.0  0 vulnerabilities — outdated, 3.24.0 available" "completed row is redrawn when update data arrives"
  assert_contains "${after_update//$'\r'/}" "Resolving and auditing packages: 1/3 complete" "annotation redraw preserves completion count"
}

test_tty_twenty_packages_uses_responsive_full_table_on_24_rows() {
  prepare
  local package_barrier="${W_DIR}/package-barrier"
  local outdated_barrier="${W_DIR}/outdated-barrier"
  local spec screen=""
  mkdir -p "$package_barrier" "$outdated_barrier"
  prepare_many_package_data 20
  start_tty_run "$package_barrier" "$outdated_barrier" 80 24

  wait_for_file "${outdated_barrier}/outdated.started"
  for spec in "${MANY_SPECS[@]:0:3}"; do
    wait_for_file "${package_barrier}/started.$(spec_key "$spec")"
  done
  release_package "$package_barrier" "${MANY_SPECS[2]}"
  wait_for_transcript "Resolving and auditing packages: 1/20 complete"
  screen="$(render_visible_screen "$TTY_TRANSCRIPT" 80 24)"

  : >"${outdated_barrier}/outdated.release"
  for spec in "${MANY_SPECS[@]}"; do
    release_package "$package_barrier" "$spec"
  done
  finish_tty_run

  assert_eq "22" "$(printf '%s\n' "$screen" | awk 'END { print NR }')" "20-package progress fits as a full table on a 24-row terminal"
  assert_contains "$screen" "package-01@1.0.0" "first package remains visible"
  assert_contains "$screen" "package-03@1.0.0" "out-of-order completed package remains visible"
  assert_contains "$screen" "Resolving and auditing packages: 1/20 complete" "20-package run advances responsively"
  assert_contains "$screen" "Checking for available updates..." "20-package run retains its update phase row"
}

test_tty_uses_compact_progress_when_full_table_exceeds_height() {
  prepare
  local package_barrier="${W_DIR}/package-barrier"
  local outdated_barrier="${W_DIR}/outdated-barrier"
  local spec screen="" final=""
  mkdir -p "$package_barrier" "$outdated_barrier"
  prepare_many_package_data 23
  start_tty_run "$package_barrier" "$outdated_barrier" 80 24

  wait_for_file "${outdated_barrier}/outdated.started"
  for spec in "${MANY_SPECS[@]:0:3}"; do
    wait_for_file "${package_barrier}/started.$(spec_key "$spec")"
  done
  release_package "$package_barrier" "${MANY_SPECS[0]}"
  wait_for_transcript "Resolving and auditing packages: 1/23 complete"
  screen="$(render_visible_screen "$TTY_TRANSCRIPT" 80 24)"

  : >"${outdated_barrier}/outdated.release"
  for spec in "${MANY_SPECS[@]}"; do
    release_package "$package_barrier" "$spec"
  done
  finish_tty_run
  final="${R_OUTPUT//$'\r'/}"

  assert_eq "2" "$(printf '%s\n' "$screen" | awk 'END { print NR }')" "23-package run uses only two bounded progress rows on a 24-row terminal"
  assert_not_contains "$screen" "pending" "compact progress does not render off-screen package rows"
  assert_contains "$screen" "Resolving and auditing packages: 1/23 complete" "compact status advances after the first completion"
  assert_contains "$screen" "Checking for available updates..." "compact mode retains the update phase"
  assert_contains "$final" "package-01@1.0.0" "compact mode prints sorted final package rows after progress"
  assert_contains "$final" "package-23@1.0.0" "compact mode prints every final package row"
}

test_tty_long_result_keeps_one_physical_row_per_package() {
  prepare
  local barrier_dir="${W_DIR}/barrier"
  local outdated_barrier="${W_DIR}/outdated-barrier"
  local first="alpha-short@1.0.0"
  local second="beta-short@1.0.0"
  local third="zeta-package-with-an-extremely-long-scoped-result-name@1.0.0"
  local fixture_file=""
  mkdir -p "$barrier_dir" "$outdated_barrier"
  export NPM_STUB_LIST_JSON='{"dependencies":{"zeta-package-with-an-extremely-long-scoped-result-name":{"version":"1.0.0"},"beta-short":{"version":"1.0.0"},"alpha-short":{"version":"1.0.0"}}}'
  fixture_file="$(write_fixture "${W_DIR}/fixture.json" \
    '{"alpha-short@1.0.0":{"total":0,"low":0,"moderate":0,"high":0,"critical":0,"info":0},' \
    '"beta-short@1.0.0":{"total":0,"low":0,"moderate":0,"high":0,"critical":0,"info":0},' \
    '"zeta-package-with-an-extremely-long-scoped-result-name@1.0.0":{"total":333,"low":88,"moderate":166,"high":79,"critical":0,"info":0}}')"
  export NPM_STUB_FIXTURES="$fixture_file"
  start_tty_run "$barrier_dir" "$outdated_barrier" 60

  local spec
  wait_for_file "${outdated_barrier}/outdated.started"
  for spec in "$first" "$second" "$third"; do
    wait_for_file "${barrier_dir}/started.$(spec_key "$spec")"
  done
  release_package "$barrier_dir" "$third"
  wait_for_transcript "Resolving and auditing packages: 1/3 complete"
  local screen=""
  screen="$(render_visible_screen "$TTY_TRANSCRIPT" 60)"

  : >"${outdated_barrier}/outdated.release"
  release_package "$barrier_dir" "$first"
  release_package "$barrier_dir" "$second"
  finish_tty_run

  assert_eq "5" "$(printf '%s\n' "$screen" | awk 'END { print NR }')" "narrow TTY keeps package and transient rows physically separate"
  assert_contains "$screen" "alpha-short@1.0.0" "first pending package remains on its row"
  assert_contains "$screen" "beta-short@1.0.0" "second pending package remains on its row"
  assert_contains "$screen" "zeta-package-with-an-extremely" "long completed package remains on the third row"
  assert_contains "$screen" "333 vulnerabilities" "long completed result stays visible after truncation"
  assert_contains "$screen" "Resolving and auditing packages: 1/3 complete" "status remains on its own physical row"
  assert_contains "$screen" "Checking for available updates..." "update phase remains on its own physical row"
}

test_zz_test_harness_stubs_cpu_and_uses_only_zero_polling() {
  local bad_sleeps=""
  prepare
  : >"$MODULE_CPU_LOG"
  : >"$MODULE_SLEEP_LOG"
  run_script "$W_STUB" "1"
  bad_sleeps="$(awk '$0 != "0"' "$MODULE_SLEEP_LOG")"
  assert_status "0" "$R_STATUS" "ordinary mocked run exits successfully"
  assert_contains "$(<"$MODULE_CPU_LOG")" "getconf _NPROCESSORS_ONLN" "default concurrency uses the PATH-shadowed CPU probe"
  assert_eq "" "$bad_sleeps" "script polling never performs a nonzero test wait"
}

# Setup module before running tests
setup_module

run_tests "$@"
