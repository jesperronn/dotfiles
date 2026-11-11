#!/usr/bin/env bash
# shellcheck disable=SC1090,SC1091
set -euo pipefail

# Hermetic: a stub `npm` on PATH serves three canned packages. Nothing here
# reads the real global npm tree or the network.
#   alpha-ok@1.0.0     up to date, 0 vulnerabilities
#   beta-crit@1.0.0    1 critical, outdated (latest 1.1.0)
#   gamma-multi@1.0.0  1 low + 1 high + 2 critical, up to date

DOTFILES_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
SCRIPT_UNDER_TEST="$DOTFILES_ROOT/bin/npm-global-audit"

source "$DOTFILES_ROOT/bin/lib/bash_test.sh"

MODULE_TEMP_DIR=""
MODULE_STUB_DIR=""
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

  find . -maxdepth 1 -type d -name "ptest_*" -exec rm -rf {} + 2>/dev/null || true
}
trap cleanup_test_temps EXIT

setup_module() {
  MODULE_TEMP_DIR="$(mktemp -d)"
  MODULE_STUB_DIR="${MODULE_TEMP_DIR}/stub"
  mkdir -p "$MODULE_STUB_DIR"
  MODULE_CPU_LOG="${MODULE_TEMP_DIR}/cpu.log"
  MODULE_SLEEP_LOG="${MODULE_TEMP_DIR}/sleep.log"
  : >"$MODULE_CPU_LOG"
  : >"$MODULE_SLEEP_LOG"
  export NPM_STUB_CPU_LOG="$MODULE_CPU_LOG"
  export NPM_STUB_SLEEP_LOG="$MODULE_SLEEP_LOG"

  # One npm stub for every test. Builtins only (no subprocess per call):
  # process spawning dominates this suite's runtime. `install` records the
  # spec under --prefix so `audit` can answer for it from canned JSON.
  cat >"${MODULE_STUB_DIR}/npm" <<'NPMSTUB'
#!/usr/bin/env bash
set -euo pipefail
[[ -z "${NPM_STUB_LOG:-}" ]] || printf '%s\n' "$*" >>"$NPM_STUB_LOG"
args=("$@")
cmd="" prefix="" last=""
for ((i = 0; i < ${#args[@]}; i++)); do
  case "${args[i]}" in
    --prefix) prefix="${args[i + 1]}"; ((i++)) || true ;;
    -*) ;;
    *) [[ -n "$cmd" ]] || cmd="${args[i]}"; last="${args[i]}" ;;
  esac
done
vulns() { printf '{"metadata":{"vulnerabilities":%s}}\n' "$1"; }
wait_for() {
  until [[ -e "$1" ]]; do
    [[ "${NPM_STUB_POLL_INTERVAL:-0}" == 0 ]] || sleep "$NPM_STUB_POLL_INTERVAL"
  done
}
case "$cmd" in
  ls)
    if [[ -n "${NPM_STUB_LIST_JSON:-}" ]]; then
      printf '%s\n' "$NPM_STUB_LIST_JSON"
    else
      printf '%s\n' '{"dependencies":{"alpha-ok":{"version":"1.0.0"},"beta-crit":{"version":"1.0.0"},"gamma-multi":{"version":"1.0.0"}}}'
    fi
    ;;
  install)
    [[ -z "$prefix" ]] || printf '%s\n' "$last" >"${prefix}/spec"
    [[ -z "${NPM_STUB_EVENT_LOG:-}" ]] || printf 'install-start %s\n' "$last" >>"$NPM_STUB_EVENT_LOG"
    if [[ -n "${NPM_STUB_BARRIER_DIR:-}" ]]; then
      safe="${last//[^[:alnum:]]/_}"
      : >"${NPM_STUB_BARRIER_DIR}/started.${safe}"
      wait_for "${NPM_STUB_BARRIER_DIR}/release.${safe}"
    fi
    [[ -z "${NPM_STUB_EVENT_LOG:-}" ]] || printf 'install-end %s\n' "$last" >>"$NPM_STUB_EVENT_LOG"
    ;;
  root)
    [[ -n "${NPM_STUB_ROOT:-}" ]] || exit 1
    printf '%s\n' "$NPM_STUB_ROOT"
    ;;
  audit)
    if [[ "$prefix" == */installed ]]; then
      lock="$(<"${prefix}/package-lock.json")"
      printf '%s' "$lock" >"${NPM_STUB_LOCK_COPY:-/dev/null}"
      vulns '{"total":7,"low":2,"moderate":1,"high":1,"critical":3,"info":0}'
      exit 0
    fi
    spec="$(<"${prefix}/spec")"
    if [[ "$spec" == "${NPM_STUB_FAIL_SPEC:-}" ]]; then
      printf 'registry unavailable\n' >&2
      exit 1
    fi
    case "$spec" in
      alpha-ok@1.0.0) vulns '{"total":0,"low":0,"moderate":0,"high":0,"critical":0,"info":0}' ;;
      beta-crit@1.0.0) vulns '{"total":1,"low":0,"moderate":0,"high":0,"critical":1,"info":0}' ;;
      gamma-multi@1.0.0) vulns '{"total":4,"low":1,"moderate":0,"high":1,"critical":2,"info":0}' ;;
      *) printf 'registry unavailable\n' >&2; exit 1 ;;
    esac
    ;;
  outdated)
    if [[ -n "${NPM_STUB_OUTDATED_BARRIER_DIR:-}" ]]; then
      : >"${NPM_STUB_OUTDATED_BARRIER_DIR}/outdated.started"
      wait_for "${NPM_STUB_OUTDATED_BARRIER_DIR}/outdated.release"
    fi
    printf '%s\n' '{"beta-crit":{"current":"1.0.0","latest":"1.1.0"}}'
    ;;
  *) printf 'npm stub: unknown command: %s\n' "$cmd" >&2; exit 1 ;;
esac
NPMSTUB

  # Builtin-only stubs for the CPU probes and sleep so they never touch the host.
  cat >"${MODULE_STUB_DIR}/getconf" <<'STUB'
#!/usr/bin/env bash
printf 'getconf %s\n' "$*" >>"$NPM_STUB_CPU_LOG"
printf '2\n'
STUB
  cat >"${MODULE_STUB_DIR}/sysctl" <<'STUB'
#!/usr/bin/env bash
printf 'sysctl %s\n' "$*" >>"$NPM_STUB_CPU_LOG"
printf '2\n'
STUB
  cat >"${MODULE_STUB_DIR}/sleep" <<'STUB'
#!/usr/bin/env bash
printf '%s\n' "${1:-}" >>"$NPM_STUB_SLEEP_LOG"
STUB
  chmod +x "${MODULE_STUB_DIR}/npm" "${MODULE_STUB_DIR}/getconf" "${MODULE_STUB_DIR}/sysctl" "${MODULE_STUB_DIR}/sleep"
}

# Scratch dir per test; clears the stub's behaviour switches.
prepare() {
  W_DIR="$(mktemp -d "${MODULE_TEMP_DIR}/test.XXXXXX")"
  W_STUB="$MODULE_STUB_DIR"
  unset NPM_STUB_ROOT NPM_STUB_LOCK_COPY NPM_STUB_LIST_JSON NPM_STUB_BARRIER_DIR \
    NPM_STUB_OUTDATED_BARRIER_DIR NPM_STUB_EVENT_LOG NPM_STUB_FAIL_SPEC NPM_STUB_LOG
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

# One plain run covers rows, severity totals, outdated reporting, the npm calls
# made, and that the CPU probe and sleeps stay stubbed.
test_plain_run_rows_totals_and_npm_calls() {
  prepare
  local log_file="${W_DIR}/npm.log" log="" bad_sleeps=""
  : >"$MODULE_CPU_LOG"
  : >"$MODULE_SLEEP_LOG"
  export NPM_STUB_LOG="$log_file"
  run_script "$W_STUB" "1"
  log="$(<"$log_file")"
  bad_sleeps="$(awk '$0 != "0"' "$MODULE_SLEEP_LOG")"

  assert_status "0" "$R_STATUS" "plain run exits 0"
  assert_contains "$R_OUTPUT" "alpha-ok@1.0.0     0 vulnerabilities" "up-to-date clean package reports zero"
  assert_not_contains "$R_OUTPUT" "alpha-ok@1.0.0     0 vulnerabilities —" "clean package carries no outdated note"
  assert_contains "$R_OUTPUT" "beta-crit@1.0.0    1 vulnerability (0 low, 0 moderate, 0 high, 1 critical) — outdated, 1.1.0 available" "single critical is singular and flagged outdated"
  assert_contains "$R_OUTPUT" "gamma-multi@1.0.0  4 vulnerabilities (1 low, 0 moderate, 1 high, 2 critical)" "mixed severities sum to the total"
  assert_not_contains "$R_OUTPUT" "gamma-multi@1.0.0  4 vulnerabilities (1 low, 0 moderate, 1 high, 2 critical) —" "up-to-date vulnerable package is not flagged outdated"
  assert_contains "$R_OUTPUT" "npm update -g beta-crit" "only the outdated package is offered for update"
  assert_not_contains "$R_OUTPUT" "npm update -g beta-crit alpha-ok" "up-to-date packages are not offered for update"
  assert_contains "$R_OUTPUT" "already on latest, needs manual review:" "up-to-date vulnerable package needs manual review"
  assert_contains "$R_OUTPUT" "  gamma-multi@1.0.0" "manual-review list names the vulnerable up-to-date package"
  assert_not_contains "$R_OUTPUT" "pending" "redirected output has no pending rows"
  assert_not_contains "$R_OUTPUT" "Resolving and auditing packages:" "redirected output has no progress status"
  assert_not_contains "$R_OUTPUT" $'\033[' "no ANSI escapes in plain mode"
  assert_not_contains "$R_OUTPUT" "Installed tree" "no installed line when npm root -g fails"

  assert_contains "$log" "--no-audit ls -g --depth=0 --json" "discovery uses safe ls flags"
  assert_contains "$log" "install --package-lock-only --ignore-scripts --no-audit beta-crit@1.0.0" "install pins the literal spec with safe flags"
  assert_contains "$log" "audit --json" "each package is audited as json"
  assert_contains "$log" "--no-audit outdated -g --json" "outdated lookup uses safe flags"
  assert_not_contains "$log" "update -g" "never runs npm update -g"
  assert_not_contains "$log" "audit fix" "never runs audit fix"
  assert_not_contains "$log" "--global audit" "never runs global audit"
  assert_contains "$(<"$MODULE_CPU_LOG")" "getconf _NPROCESSORS_ONLN" "default concurrency uses the PATH-shadowed CPU probe"
  assert_eq "" "$bad_sleeps" "script polling never performs a nonzero test wait"
}

test_audit_failure_continues() {
  prepare
  export NPM_STUB_FAIL_SPEC="beta-crit@1.0.0"
  run_script "$W_STUB" "1"

  assert_status "1" "$R_STATUS" "a package failure exits 1"
  assert_contains "$R_OUTPUT" "gamma-multi@1.0.0  4 vulnerabilities (1 low, 0 moderate, 1 high, 2 critical)" "successful package still renders"
  assert_contains "$R_OUTPUT" "beta-crit@1.0.0    audit failed: registry unavailable" "failure renders a readable row"
}

test_empty_packages() {
  prepare
  export NPM_STUB_LIST_JSON='{"dependencies":{}}'
  run_script "$W_STUB" "1"

  assert_status "0" "$R_STATUS" "empty global list exits 0"
  assert_contains "$R_OUTPUT" "No global npm packages found." "empty list emits no-packages message"
}

test_installed_tree_line() {
  prepare
  local root="${W_DIR}/root"
  mkdir -p "${root}/a/node_modules/b" "${root}/@s/c"
  printf '{"name":"a","version":"1.0.0","dependencies":{"b":"^1"}}' >"${root}/a/package.json"
  printf '{"name":"b","version":"1.2.0"}' >"${root}/a/node_modules/b/package.json"
  printf '{"name":"@s/c","version":"2.0.0"}' >"${root}/@s/c/package.json"
  export NPM_STUB_ROOT="$root" NPM_STUB_LOCK_COPY="${W_DIR}/lock.json"
  run_script "$W_STUB" "1"

  assert_contains "$R_OUTPUT" "Installed tree (3 packages): 7 vulnerabilities (2 low, 1 moderate, 1 high, 3 critical)" "installed tree line shows nested count and severities"
  assert_contains "$(<"${W_DIR}/lock.json")" '"node_modules/a/node_modules/b":{"version":"1.2.0"}' "lockfile keeps nested copy"
  assert_contains "$(<"${W_DIR}/lock.json")" '"node_modules/@s/c":{"version":"2.0.0"}' "lockfile keeps scoped package"
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
  wait_for_file "${barrier_dir}/started.$(spec_key 'alpha-ok@1.0.0')" && first_started=1
  wait_for_file "${barrier_dir}/started.$(spec_key 'beta-crit@1.0.0')" && second_started=1
  initial_events="$(<"$event_log")"
  release_package "$barrier_dir" "alpha-ok@1.0.0"
  release_package "$barrier_dir" "beta-crit@1.0.0"
  wait_for_file "${barrier_dir}/started.$(spec_key 'gamma-multi@1.0.0')"
  release_package "$barrier_dir" "gamma-multi@1.0.0"

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
  assert_contains "$initial_events" "install-start alpha-ok@1.0.0" "first bounded worker starts before release"
  assert_contains "$initial_events" "install-start beta-crit@1.0.0" "second bounded worker starts before release"
  assert_not_contains "$initial_events" "install-end" "neither initial worker completes before release"
  assert_not_contains "$initial_events" "install-start gamma-multi@1.0.0" "third worker remains queued at the two-job limit"
  assert_contains "$R_OUTPUT" "gamma-multi@1.0.0" "concurrent run retains every package output"
}

# The third sorted worker must be rendered while the first two remain blocked;
# this catches schedulers that wait for the oldest PID instead of completions.
# It also checks that the update lookup (held by its own barrier) neither blocks
# the package workers nor the redraw when its answer arrives late.
test_tty_out_of_order_completion_delayed_update_and_cleanup() {
  prepare
  local package_barrier="${W_DIR}/package-barrier"
  local outdated_barrier="${W_DIR}/outdated-barrier"
  mkdir -p "$package_barrier" "$outdated_barrier"
  start_tty_run "$package_barrier" "$outdated_barrier" 120

  local spec
  wait_for_file "${outdated_barrier}/outdated.started"
  for spec in "alpha-ok@1.0.0" "beta-crit@1.0.0" "gamma-multi@1.0.0"; do
    wait_for_file "${package_barrier}/started.$(spec_key "$spec")"
  done

  local initial_screen="" expected_pending="" mid="" before_update="" after_update=""
  initial_screen="$(render_visible_screen "$TTY_TRANSCRIPT" 120 24)"
  expected_pending="$(printf '%-17s  pending\n%-17s  pending\n%-17s  pending' \
    'alpha-ok@1.0.0' 'beta-crit@1.0.0' 'gamma-multi@1.0.0')"

  release_package "$package_barrier" "gamma-multi@1.0.0"
  wait_for_transcript "Resolving and auditing packages: 1/3 complete"
  mid="$(<"$TTY_TRANSCRIPT")"
  mid="${mid//$'\r'/}"

  release_package "$package_barrier" "beta-crit@1.0.0"
  wait_for_transcript "Resolving and auditing packages: 2/3 complete"
  before_update="$(<"$TTY_TRANSCRIPT")"
  before_update="${before_update//$'\r'/}"

  : >"${outdated_barrier}/outdated.release"
  wait_for_transcript "— outdated, 1.1.0 available"
  after_update="$(<"$TTY_TRANSCRIPT")"
  after_update="${after_update//$'\r'/}"

  release_package "$package_barrier" "alpha-ok@1.0.0"
  finish_tty_run
  local final="${R_OUTPUT//$'\r'/}" final_screen=""
  final_screen="$(render_visible_screen "$TTY_TRANSCRIPT" 120 24)"

  assert_status "0" "$R_STATUS" "TTY progress run exits 0"
  assert_contains "$initial_screen" "$expected_pending" "TTY initial frame lists every sorted package as pending"
  assert_eq "1" "$(count_occurrences "$initial_screen" 'Resolving and auditing packages: 0/3 complete')" "TTY initial frame has one primary status row"
  assert_contains "$initial_screen" "checking for updates..." "update phase renders while lookup is held"
  assert_contains "$mid" "alpha-ok@1.0.0     pending" "first row stays pending after the third worker finishes"
  assert_contains "$mid" "gamma-multi@1.0.0  4 vulnerabilities (1 low, 0 moderate, 1 high, 2 critical)" "third row is replaced out of order"
  assert_contains "$before_update" "beta-crit@1.0.0    1 vulnerability (0 low, 0 moderate, 0 high, 1 critical)" "package completes while update lookup is blocked"
  assert_not_contains "$before_update" "outdated, 1.1.0 available" "completed row has no update annotation yet"
  assert_contains "$after_update" "beta-crit@1.0.0    1 vulnerability (0 low, 0 moderate, 0 high, 1 critical) — outdated, 1.1.0 available" "completed row is redrawn when update data arrives"
  assert_contains "$after_update" "Resolving and auditing packages: 2/3 complete" "annotation redraw preserves completion count"
  assert_contains "$final_screen" "alpha-ok@1.0.0     0 vulnerabilities" "first result replaces the first sorted row"
  assert_contains "$final" $'\033[1A\033[2KNext:' "the transient status row is erased before Next"
  assert_not_contains "$final" $'Resolving and auditing packages: 3/3 complete\n\nNext:' "visible progress status is cleared before Next"
}

# The full table needs PROGRESS_TOTAL + 2 rows. With three packages, five rows
# is the smallest terminal that still shows it, four forces the compact status
# row; a small terminal exercises this without needing dozens of packages.
tty_small_terminal_run() {
  local rows="$1" package_barrier="${W_DIR}/package-barrier" outdated_barrier="${W_DIR}/outdated-barrier" spec
  mkdir -p "$package_barrier" "$outdated_barrier"
  start_tty_run "$package_barrier" "$outdated_barrier" 80 "$rows"
  wait_for_file "${outdated_barrier}/outdated.started"
  for spec in "alpha-ok@1.0.0" "beta-crit@1.0.0" "gamma-multi@1.0.0"; do
    wait_for_file "${package_barrier}/started.$(spec_key "$spec")"
  done
  release_package "$package_barrier" "gamma-multi@1.0.0"
  wait_for_transcript "Resolving and auditing packages: 1/3 complete"
  TTY_SCREEN="$(render_visible_screen "$TTY_TRANSCRIPT" 80 "$rows")"
  : >"${outdated_barrier}/outdated.release"
  release_package "$package_barrier" "alpha-ok@1.0.0"
  release_package "$package_barrier" "beta-crit@1.0.0"
  finish_tty_run
}

test_tty_full_table_when_rows_just_fit() {
  prepare
  tty_small_terminal_run 5

  assert_status "0" "$R_STATUS" "exact-fit TTY run exits 0"
  assert_eq "4" "$(printf '%s\n' "$TTY_SCREEN" | awk 'END { print NR }')" "three packages plus status fit as a full table on 5 rows"
  assert_contains "$TTY_SCREEN" "alpha-ok@1.0.0" "first package remains visible"
  assert_contains "$TTY_SCREEN" "gamma-multi@1.0.0  4 vulnerabilities" "out-of-order completed package remains visible"
  assert_contains "$TTY_SCREEN" "Resolving and auditing packages: 1/3 complete" "full-table run advances responsively"
  assert_contains "$TTY_SCREEN" "checking for updates..." "full-table run retains its update phase status"
}

test_tty_uses_compact_progress_when_full_table_exceeds_height() {
  prepare
  tty_small_terminal_run 4
  local final="${R_OUTPUT//$'\r'/}"

  assert_status "0" "$R_STATUS" "compact TTY run exits 0"
  assert_eq "1" "$(printf '%s\n' "$TTY_SCREEN" | awk 'END { print NR }')" "short terminal uses only one bounded progress row"
  assert_not_contains "$TTY_SCREEN" "pending" "compact progress does not render off-screen package rows"
  assert_contains "$TTY_SCREEN" "Resolving and auditing packages: 1/3 complete" "compact status advances after the first completion"
  assert_contains "$TTY_SCREEN" "checking for updates..." "compact mode retains the update phase"
  assert_contains "$final" "alpha-ok@1.0.0" "compact mode prints sorted final package rows after progress"
  assert_contains "$final" "gamma-multi@1.0.0" "compact mode prints every final package row"
}

# A narrow terminal truncates both columns; the final table must still show
# exactly one physical row per package rather than wrapping.
test_tty_narrow_terminal_keeps_one_physical_row_per_package() {
  prepare
  local screen=""
  start_tty_run "" "" 30
  finish_tty_run
  screen="$(render_visible_screen "$TTY_TRANSCRIPT" 30)"

  assert_status "0" "$R_STATUS" "narrow TTY run exits 0"
  assert_eq "alp…  0 vulnerabilities" "$(printf '%s\n' "$screen" | head -n 1)" "first package is truncated onto its own row"
  assert_contains "$(printf '%s\n' "$screen" | head -n 2)" "bet…  1 vulnerability" "second package is truncated onto its own row"
  assert_contains "$(printf '%s\n' "$screen" | head -n 3)" "gam…  4 vulnerabilities" "long result stays visible after truncation"
  assert_not_contains "$screen" "Resolving and auditing" "status row is cleared"
}

# Setup module before running tests
setup_module

run_tests "$@"
