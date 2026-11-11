# shellcheck shell=bash
# project.sh — shared helpers for bin/ commands: ecosystem detection, step runner.
# Source it from bin/<command> (run those by path: bin/test); do not run it. Needs bash 3.2+.

# Exit codes. One set per project; change EX_USAGE to 64 if the project already uses it.
EX_FAILED=1
EX_USAGE=2
EX_TOOL_MISSING=9

PROJECT_ROOT="$(cd "${BASH_SOURCE[0]%/*}/../.." && pwd -P)"
DRY_RUN="${DRY_RUN:-0}"
VERBOSE="${VERBOSE:-0}"

if [[ -t 1 && -z "${NO_COLOR:-}" ]]; then
  C_BOLD=$'\e[1m' C_RED=$'\e[31m' C_GREEN=$'\e[32m' C_DIM=$'\e[2m' C_0=$'\e[0m'
else
  C_BOLD="" C_RED="" C_GREEN="" C_DIM="" C_0=""
fi

# Ecosystems (groups). Add one here and in group_detected plus the commands.
ALL_GROUPS="bash ruby js go java"
SELECTED_GROUPS=()

die_usage() {
  printf '%s: %s\n' "$(basename "$0")" "$1" >&2
  printf "Try '%s --help'.\n" "$(basename "$0")" >&2
  exit "$EX_USAGE"
}

# --- detection ---------------------------------------------------------------

has_file() { [[ -e "$PROJECT_ROOT/$1" ]]; }

group_detected() {
  case "$1" in
    bash) compgen -G "$PROJECT_ROOT/bin/*.sh" >/dev/null || compgen -G "$PROJECT_ROOT/test/*.sh" >/dev/null ;;
    ruby) has_file Gemfile ;;
    js) has_file package.json ;;
    go) has_file go.mod ;;
    java) has_file pom.xml || has_file build.gradle || has_file build.gradle.kts ;;
    *) return 1 ;;
  esac
}

is_group() {
  local g
  for g in $ALL_GROUPS; do [[ "$g" == "$1" ]] && return 0; done
  return 1
}

# Select a group from a --<group> flag. Returns 1 when the flag is not a group.
select_group_flag() {
  local g="${1#--}"
  is_group "$g" || return 1
  SELECTED_GROUPS+=("$g")
}

# Print the groups to act on: the selected ones, else every detected one.
groups_to_run() {
  local g
  if [[ ${#SELECTED_GROUPS[@]} -gt 0 ]]; then
    printf '%s\n' "${SELECTED_GROUPS[@]}"
  else
    for g in $ALL_GROUPS; do group_detected "$g" && echo "$g"; done
  fi
  return 0
}

is_rails() { has_file config/application.rb && has_file bin/rails; }
is_maven() { has_file pom.xml; }
is_gradle() { has_file build.gradle || has_file build.gradle.kts; }

# Prefer the project's wrapper over a global install.
java_tool() {
  if is_maven; then
    [[ -x "$PROJECT_ROOT/mvnw" ]] && echo ./mvnw || echo mvn
  else
    [[ -x "$PROJECT_ROOT/gradlew" ]] && echo ./gradlew || echo gradle
  fi
}

# Package manager from the lockfile; npm when there is none.
js_pm() {
  if has_file pnpm-lock.yaml; then
    echo pnpm
  elif has_file yarn.lock; then
    echo yarn
  else
    echo npm
  fi
}

# True when the build file mentions a word, e.g. build_file_mentions spotless.
build_file_mentions() {
  local f
  for f in pom.xml build.gradle build.gradle.kts; do
    [[ -f "$PROJECT_ROOT/$f" ]] && grep -q -- "$1" "$PROJECT_ROOT/$f" && return 0
  done
  return 1
}

join_csv() {
  local IFS=,
  echo "$*"
}

# --- paths -------------------------------------------------------------------

# Print PATH relative to the project root ('.' for the root itself). Fails when it does not exist.
root_rel() {
  local p="$1" abs
  if [[ -d "$p" ]]; then
    abs="$(cd "$p" && pwd -P)"
  elif [[ -e "$p" ]]; then
    abs="$(cd "$(dirname "$p")" && pwd -P)/$(basename "$p")"
  else
    return 1
  fi
  if [[ "$abs" == "$PROJECT_ROOT" ]]; then
    echo .
  else
    printf '%s\n' "${abs#"$PROJECT_ROOT"/}"
  fi
}

# --- steps -------------------------------------------------------------------

STEP_NAMES=()
STEP_RESULTS=() # ok | FAIL | MISSING | skip

record_step() {
  STEP_NAMES+=("$1")
  STEP_RESULTS+=("$2")
}

# run_step NAME CMD [ARGS...]: run in the project root, never abort the batch.
# Exit 127 (command not found) counts as a missing tool. --dry-run only prints.
run_step() {
  local name="$1" rc=0
  shift
  printf '%s==> %s%s\n' "$C_BOLD" "$name" "$C_0"
  if [[ "$DRY_RUN" == 1 ]]; then
    printf '+'
    printf ' %q' "$@"
    printf '\n'
    record_step "$name" ok
    return 0
  fi
  (cd "$PROJECT_ROOT" && "$@") || rc=$?
  case "$rc" in
    0) record_step "$name" ok ;;
    127) record_step "$name" MISSING ;;
    *) record_step "$name" FAIL ;;
  esac
}

skip_step() {
  printf '%s==> %s%s\n    skipped: %s\n' "$C_BOLD" "$1" "$C_0" "$2"
  record_step "$1" skip
}

# Print one line per step; return 0 all ok, 1 any failed, 9 a tool was missing.
print_summary() {
  local i rc=0 res color
  printf '\n'
  for i in "${!STEP_NAMES[@]}"; do
    res="${STEP_RESULTS[$i]}"
    case "$res" in
      ok) color="$C_GREEN" ;;
      skip) color="$C_DIM" ;;
      *) color="$C_RED" ;;
    esac
    printf '%s%-7s%s %s\n' "$color" "$res" "$C_0" "${STEP_NAMES[$i]}"
    [[ "$res" == FAIL ]] && rc="$EX_FAILED"
    [[ "$res" == MISSING && "$rc" -eq 0 ]] && rc="$EX_TOOL_MISSING"
  done
  return "$rc"
}
