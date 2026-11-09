#!/usr/bin/env bash
# shellcheck disable=SC1090,SC1091

set -euo pipefail

DOTFILES_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
SCRIPT_UNDER_TEST="$DOTFILES_ROOT/bin/gen_skills_readme"

source "$DOTFILES_ROOT/bin/lib/bash_test.sh"

TEST_TMP_DIR=""

cleanup_test_tmp() {
  [[ -n "$TEST_TMP_DIR" ]] && rm -rf "$TEST_TMP_DIR"
  return 0
}
trap 'cleanup_test_tmp' EXIT

new_skills_dir() {
  TEST_TMP_DIR="$(mktemp -d)"
  mkdir -p "$TEST_TMP_DIR/skills"
}

write_skill() {
  local name="$1"
  shift
  mkdir -p "$TEST_TMP_DIR/skills/$name"
  printf -- '---\n%s\n---\n\nbody\n' "$(printf '%s\n' "$@")" >"$TEST_TMP_DIR/skills/$name/SKILL.md"
}

test_summary_without_group_is_accepted() {
  new_skills_dir
  write_skill alpha 'name: alpha' 'summary: "Does alpha things."' 'description: Use when alpha.'
  local out status
  capture_command out status env SKILLS_DIR="$TEST_TMP_DIR/skills" python3 "$SCRIPT_UNDER_TEST"
  assert_status 0 "$status" "skill with summary but no group exits 0"
  assert_not_contains "$out" "missing" "no missing-field warning"
  assert_contains "$(cat "$TEST_TMP_DIR/skills/README.md")" '| **alpha** | Does alpha things. |' "skill listed in index"
}

test_group_is_ignored_and_index_is_flat_sorted() {
  new_skills_dir
  write_skill zeta 'name: zeta' 'group: domain' 'summary: "Zeta."' 'description: d'
  write_skill alpha 'name: alpha' 'summary: "Alpha."' 'description: d'
  local out status readme
  capture_command out status env SKILLS_DIR="$TEST_TMP_DIR/skills" python3 "$SCRIPT_UNDER_TEST"
  assert_status 0 "$status" "mixed group/no-group exits 0"
  readme="$(cat "$TEST_TMP_DIR/skills/README.md")"
  assert_not_contains "$readme" "## " "no group headings"
  assert_eq "alpha zeta" "$(grep -o '^| \*\*[a-z]*\*\*' <<<"$readme" | tr -d '|* ' | tr '\n' ' ' | gsed 's/ $//')" "rows sorted by name"
}

test_missing_summary_is_reported() {
  new_skills_dir
  write_skill nosum 'name: nosum' 'description: Use when x.'
  local out status
  capture_command out status env SKILLS_DIR="$TEST_TMP_DIR/skills" python3 "$SCRIPT_UNDER_TEST"
  assert_status 1 "$status" "skill without summary exits 1"
  assert_contains "$out" "nosum (missing: summary)" "missing summary reported"
  assert_not_contains "$out" "group" "group never mentioned"
}

test_symlinked_skill_is_skipped() {
  new_skills_dir
  write_skill alpha 'name: alpha' 'summary: "Alpha."' 'description: d'
  mkdir -p "$TEST_TMP_DIR/external/linked"
  printf -- '---\nname: linked\ndescription: d\n---\n' >"$TEST_TMP_DIR/external/linked/SKILL.md"
  ln -s "$TEST_TMP_DIR/external/linked" "$TEST_TMP_DIR/skills/linked"
  local out status
  capture_command out status env SKILLS_DIR="$TEST_TMP_DIR/skills" python3 "$SCRIPT_UNDER_TEST"
  assert_status 0 "$status" "symlinked skill without summary does not fail"
  assert_not_contains "$(cat "$TEST_TMP_DIR/skills/README.md")" "linked" "symlinked skill not listed"
}

run_tests "$@"
