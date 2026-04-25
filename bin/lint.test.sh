#!/usr/bin/env bash
# shellcheck disable=SC1090,SC1091,SC2016

set -euo pipefail

DOTFILES_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
LINT_BIN="$DOTFILES_ROOT/bin/lint"

source "$DOTFILES_ROOT/bin/lib/bash_test.sh"
source "$LINT_BIN" source

TEST_TMP_DIR=""
BASH_BIN="$(command -v bash)"

setup_tmpdir() {
  TEST_TMP_DIR="$(mktemp -d)"
  trap 'rm -rf "$TEST_TMP_DIR"' EXIT
}

make_stub_bin_dir() {
  mkdir -p "$TEST_TMP_DIR/stub-bin"
  printf '%s\n' "$TEST_TMP_DIR/stub-bin"
}

make_shell_file() {
  local file="$1"
  shift

  cat >"$file" <<EOF
#!/usr/bin/env bash
$*
EOF
  chmod +x "$file"
}

write_shellcheck_stub() {
  local stub_dir="$1"
  local body="$2"

  cat >"$stub_dir/shellcheck" <<EOF
#!/usr/bin/env bash
set -euo pipefail
$body
EOF
  chmod +x "$stub_dir/shellcheck"
}

write_patch_stub() {
  local stub_dir="$1"
  local body="$2"

  cat >"$stub_dir/patch" <<EOF
#!/usr/bin/env bash
set -euo pipefail
$body
EOF
  chmod +x "$stub_dir/patch"
}

test_help_mentions_new_options() {
  local output=""
  local status=0

  capture_command output status "$LINT_BIN" --help
  assert_status "1" "$status" "bin/lint --help exits without linting"
  assert_contains "$output" "--format FORMAT|-f FORMAT" "help lists long and short format flags"
  assert_contains "$output" '`offenses` (`o`), or `worst` (`w`)' "help lists format aliases"
  assert_contains "$output" "--autocorrect" "help lists autocorrect mode"
  assert_contains "$output" "rubocop --format offenses" "help documents offense summary inspiration"
}

test_help_palette() {
  local output=""
  local status=0

  lint_reset_state
  # shellcheck disable=SC2034
  LINT_COLOR_MODE="always"
  lint_parse_prereqs
  capture_command output status lint_usage

  assert_status "0" "$status" "lint_usage renders when color is enabled"
  assert_contains "$output" "${LINT_C_BOLD}${LINT_C_SECTION}Usage:${LINT_C_RESET}" "help colors section headings"
  assert_contains "$output" "${LINT_C_BOLD}${LINT_C_ACCENT}bin/lint${LINT_C_RESET}" "help colors the tool name"
  assert_contains "$output" "${LINT_C_GREEN}--format${LINT_C_RESET}" "help colors option names"
  assert_contains "$output" "${LINT_C_PLACEHOLDER}FORMAT${LINT_C_RESET}" "help colors placeholders"
}

test_format_offenses_groups_by_rule() {
  local work_dir="$TEST_TMP_DIR/offenses"
  local stub_dir=""
  local script_file="$work_dir/sample.sh"
  local output=""
  local status=0

  mkdir -p "$work_dir"
  stub_dir="$(make_stub_bin_dir)"
  make_shell_file "$script_file" 'printf "%s\n" "$1"'
  write_shellcheck_stub "$stub_dir" '
format="default"
while [[ $# -gt 0 ]]; do
  case "$1" in
    -x)
      shift
      ;;
    -f)
      format="$2"
      shift 2
      ;;
    *)
      file="$1"
      shift
      ;;
  esac
done
if [[ "$format" != "gcc" ]]; then
  printf "unexpected format: %s\n" "$format" >&2
  exit 99
fi
cat <<OUT
$file:1:1: note: Double quote to prevent globbing and word splitting. [SC2086]
$file:2:1: note: Later duplicate message should not replace the first summary. [SC2086]
$file:3:1: info: Prefer a parameter expansion replacement instead. [SC2001]
OUT
exit 1
'

  capture_command output status env PATH="$stub_dir:$PATH" "$LINT_BIN" --format offenses "$script_file"
  assert_status "1" "$status" "offenses format returns non-zero when offenses exist"
  assert_contains "$output" "shellcheck offenses by rule" "offenses format prints summary heading"
  assert_contains "$output" "2 SC2086 (note): Double quote to prevent globbing and word splitting." "offenses format includes first severity and message for repeated rules"
  assert_contains "$output" "1 SC2001 (info): Prefer a parameter expansion replacement instead." "offenses format includes single-rule summaries"
}

test_format_short_flag_and_alias_group_by_rule() {
  local work_dir="$TEST_TMP_DIR/offenses-short"
  local stub_dir=""
  local script_file="$work_dir/sample.sh"
  local output=""
  local status=0

  mkdir -p "$work_dir"
  stub_dir="$(make_stub_bin_dir)"
  make_shell_file "$script_file" 'printf "%s\n" "$1"'
  write_shellcheck_stub "$stub_dir" '
format="default"
while [[ $# -gt 0 ]]; do
  case "$1" in
    -x)
      shift
      ;;
    -f)
      format="$2"
      shift 2
      ;;
    *)
      file="$1"
      shift
      ;;
  esac
done
if [[ "$format" != "gcc" ]]; then
  printf "unexpected format: %s\n" "$format" >&2
  exit 99
fi
cat <<OUT
$file:1:1: warning: Quote this to avoid word splitting. [SC2086]
$file:2:1: warning: Duplicate warning should still keep the first summary. [SC2086]
OUT
exit 1
'

  capture_command output status env PATH="$stub_dir:$PATH" "$LINT_BIN" -f o "$script_file"
  assert_status "1" "$status" "short format flag keeps offense exit status"
  assert_contains "$output" "shellcheck offenses by rule" "short format alias selects offenses summary"
  assert_contains "$output" "2 SC2086 (warning): Quote this to avoid word splitting." "short format alias still groups by rule with summary text"
}

test_format_worst_groups_by_file() {
  local work_dir="$DOTFILES_ROOT/bin/.lint-test-worst"
  local stub_dir=""
  local file_a="$work_dir/a.sh"
  local file_b="$work_dir/b.sh"
  local output=""
  local status=0

  rm -rf "$work_dir"
  mkdir -p "$work_dir"
  stub_dir="$(make_stub_bin_dir)"
  make_shell_file "$file_a" 'printf "a\n"'
  make_shell_file "$file_b" 'printf "b\n"'
  write_shellcheck_stub "$stub_dir" '
format="default"
declare -a files=()
while [[ $# -gt 0 ]]; do
  case "$1" in
    -x)
      shift
      ;;
    -f)
      format="$2"
      shift 2
      ;;
    *)
      files+=("$1")
      shift
      ;;
  esac
done
if [[ "$format" != "gcc" ]]; then
  printf "unexpected format: %s\n" "$format" >&2
  exit 99
fi
cat <<OUT
${files[0]}:1:1: note: first [SC2086]
${files[0]}:2:1: note: second [SC2086]
${files[1]}:1:1: note: third [SC2001]
OUT
exit 1
'

  capture_command output status env PATH="$stub_dir:$PATH" "$LINT_BIN" --format worst "$file_a" "$file_b"
  assert_status "1" "$status" "worst format returns non-zero when offenses exist"
  assert_contains "$output" "shellcheck offenses by file" "worst format prints summary heading"
  assert_contains "$output" "2 bin/.lint-test-worst/a.sh" "worst format counts per-file offenses with repo-relative paths"
  assert_contains "$output" "1 bin/.lint-test-worst/b.sh" "worst format includes files with one offense using repo-relative paths"

  rm -rf "$work_dir"
}

test_format_short_alias_groups_by_file() {
  local work_dir="$DOTFILES_ROOT/bin/.lint-test-worst-short"
  local stub_dir=""
  local file_a="$work_dir/a.sh"
  local file_b="$work_dir/b.sh"
  local output=""
  local status=0

  rm -rf "$work_dir"
  mkdir -p "$work_dir"
  stub_dir="$(make_stub_bin_dir)"
  make_shell_file "$file_a" 'printf "a\n"'
  make_shell_file "$file_b" 'printf "b\n"'
  write_shellcheck_stub "$stub_dir" '
format="default"
declare -a files=()
while [[ $# -gt 0 ]]; do
  case "$1" in
    -x)
      shift
      ;;
    -f)
      format="$2"
      shift 2
      ;;
    *)
      files+=("$1")
      shift
      ;;
  esac
done
if [[ "$format" != "gcc" ]]; then
  printf "unexpected format: %s\n" "$format" >&2
  exit 99
fi
cat <<OUT
${files[0]}:1:1: note: first [SC2086]
${files[1]}:1:1: note: third [SC2001]
${files[1]}:2:1: note: fourth [SC2001]
OUT
exit 1
'

  capture_command output status env PATH="$stub_dir:$PATH" "$LINT_BIN" --format w "$file_a" "$file_b"
  assert_status "1" "$status" "short worst alias keeps offense exit status"
  assert_contains "$output" "shellcheck offenses by file" "short worst alias selects per-file summary"
  assert_contains "$output" "2 bin/.lint-test-worst-short/b.sh" "short worst alias still groups by repo-relative file path"

  rm -rf "$work_dir"
}

test_autocorrect_applies_shellcheck_patch() {
  local work_dir="$TEST_TMP_DIR/autocorrect"
  local stub_dir=""
  local script_file="$work_dir/fixme.sh"
  local output=""
  local status=0
  local script_contents=""
  local patch_log="$TEST_TMP_DIR/patch.log"

  mkdir -p "$work_dir"
  stub_dir="$(make_stub_bin_dir)"
  cat >"$script_file" <<'EOF'
#!/usr/bin/env bash
foo=${1:-value}
echo $foo
EOF
  chmod +x "$script_file"

  write_shellcheck_stub "$stub_dir" '
format="default"
file=""
while [[ $# -gt 0 ]]; do
  case "$1" in
    -x)
      shift
      ;;
    -f)
      format="$2"
      shift 2
      ;;
    *)
      file="$1"
      shift
      ;;
  esac
done
if grep -q "echo \\\$foo" "$file"; then
  if [[ "$format" == "diff" ]]; then
    printf "%s\n" "--- $file" "+++ $file" "@@" "-echo \$foo" "+echo \"\$foo\""
    exit 1
  fi
  printf "%s:3:1: note: quote this [SC2086]\n" "$file"
  exit 1
fi
exit 0
'
  write_patch_stub "$stub_dir" '
printf "%s\n" "$1" >>"'"$patch_log"'"
cat >/dev/null
file_contents="$(cat "$1")"
file_contents="${file_contents//echo \$foo/echo \"\$foo\"}"
printf "%s\n" "$file_contents" >"$1"
'

  capture_command output status env PATH="$stub_dir:$PATH" "$LINT_BIN" --autocorrect "$script_file"
  script_contents="$(cat "$script_file")"

  assert_status "0" "$status" "autocorrect exits zero after patch removes offenses"
  assert_contains "$output" "autocorrect $script_file" "autocorrect announces the patched file"
  assert_eq "$script_file" "$(cat "$patch_log")" "autocorrect pipes the diff into patch for the target file"
  assert_contains "$script_contents" 'echo "$foo"' "autocorrect updates the shell file contents"
}

test_autocorrect_requires_shellcheck() {
  local work_dir="$TEST_TMP_DIR/no-shellcheck"
  local script_file="$work_dir/sample.sh"
  local output=""
  local status=0

  mkdir -p "$work_dir"
  make_shell_file "$script_file" 'printf "ok\n"'

  capture_command output status env PATH="/usr/bin:/bin" "$BASH_BIN" "$LINT_BIN" --autocorrect "$script_file"
  assert_status "1" "$status" "autocorrect fails when shellcheck is unavailable"
  assert_contains "$output" "shellcheck not installed; skipping." "autocorrect explains the missing shellcheck dependency"
}

setup_tmpdir
run_tests "$@"
