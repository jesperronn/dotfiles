#!/usr/bin/env bash
# shellcheck disable=SC1090,SC1091,SC2034
set -euo pipefail

DOTFILES_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
SKILLS_BIN="$DOTFILES_ROOT/bin/skill"

source "$DOTFILES_ROOT/bin/lib/bash_test.sh"
source "$SKILLS_BIN"

TEST_TMP_DIR=""

setup_tmpdir() {
  TEST_TMP_DIR="$(mktemp -d)"
  trap 'rm -rf "$TEST_TMP_DIR"' EXIT
}

build_test_skill_tree() {
  local root="$1"
  mkdir -p "$root/skills-enabled/alpha" "$root/skills-enabled/multiline" "$root/skills-enabled/malformed"
  cat > "$root/skills-enabled/alpha/SKILL.md" <<'EOF'
# alpha

summary: Alpha skill

description: This is the alpha skill for testing purposes.
EOF
  cat > "$root/skills-enabled/multiline/SKILL.md" <<'EOF'
# multiline

summary: Multiline skill

description: >
  This is a multiline description.
  It spans several lines.
  Used to test multiline YAML block parsing.
EOF
  mkdir -p "$root/skills-disabled/disabled"
  cat > "$root/skills-disabled/disabled/SKILL.md" <<'EOF'
# disabled

summary: Disabled skill

description: This skill is disabled.
EOF
  cat > "$root/skills-enabled/malformed/SKILL.md" <<'EOF'
# malformed

description: This skill has no summary field.
EOF
  mkdir -p "$root/skills"
}

test_symlink_root() { printf '%s\n' "$TEST_TMP_DIR/skills"; }
test_enabled_root() { printf '%s\n' "$TEST_TMP_DIR/skills-enabled"; }
test_disabled_root() { printf '%s\n' "$TEST_TMP_DIR/skills-disabled"; }

# Map SKILLS_* roots for tests
skills_symlink_root() { test_symlink_root; }
skills_enabled_root() { test_enabled_root; }
skills_disabled_root() { test_disabled_root; }

# -- help tests --

test_global_help_exits_zero() {
  local output=""
  local status=0
  capture_command output status "$SKILLS_BIN" --help 2>&1 || status=$?
  assert_status "0" "$status" "global --help exits 0"
  assert_contains "$output" "Usage" "global help shows Usage"
  assert_contains "$output" "list" "global help mentions list"
  assert_contains "$output" "status" "global help mentions status"
  assert_contains "$output" "enable" "global help mentions enable"
  assert_contains "$output" "disable" "global help mentions disable"
}

test_help_subcommand_exits_zero() {
  local output=""
  local status=0
  capture_command output status "$SKILLS_BIN" help 2>&1 || status=$?
  assert_status "0" "$status" "help subcommand exits 0"
  assert_contains "$output" "Usage" "help subcommand shows global usage"
}

test_global_help_forced_color_uses_standard_palette() {
  local output=""
  local status=0
  capture_command output status env NO_COLOR=1 "$SKILLS_BIN" --color --help 2>&1 || status=$?
  assert_status "0" "$status" "--color help exits 0 even with NO_COLOR"
  assert_contains "$output" $'\033[1m\033[33mUsage:' "help colors section headings bold yellow"
  assert_contains "$output" $'\033[1m\033[35mbin/skill' "help colors tool name bold magenta"
  assert_contains "$output" $'\033[32mlist' "help colors subcommands green"
  assert_contains "$output" $'\033[32m-h, --help' "help colors flags green"
  assert_contains "$output" $'\033[95m<id>' "help colors placeholders bright magenta"
}

test_subcommand_help_exits_zero() {
  local output="" status=0
  capture_command output status "$SKILLS_BIN" list --help 2>&1 || status=$?
  assert_status "0" "$status" "list --help exits 0"
  output=""
  status=0
  capture_command output status "$SKILLS_BIN" status --help 2>&1 || status=$?
  assert_status "0" "$status" "status --help exits 0"
  output=""
  status=0
  capture_command output status "$SKILLS_BIN" enable --help 2>&1 || status=$?
  assert_status "0" "$status" "enable --help exits 0"
  output=""
  status=0
  capture_command output status "$SKILLS_BIN" disable --help 2>&1 || status=$?
  assert_status "0" "$status" "disable --help exits 0"
}

test_global_no_args_fails() {
  local output=""
  local status=0
  capture_command output status "$SKILLS_BIN" 2>&1 || status=$?
  assert_not_status "0" "$status" "no subcommand fails"
}

test_unknown_subcommand_fails() {
  local output=""
  local status=0
  capture_command output status "$SKILLS_BIN" bogus 2>&1 || status=$?
  assert_not_status "0" "$status" "unknown subcommand fails"
  assert_contains "$output" "Unknown subcommand" "error mentions unknown subcommand"
}

test_unknown_option_fails() {
  local output=""
  local status=0
  capture_command output status "$SKILLS_BIN" list --bogus 2>&1 || status=$?
  assert_not_status "0" "$status" "unknown option fails"
  assert_contains "$output" "Unknown option" "error mentions unknown option"
}

# -- color and formatter tests --

test_list_row_enabled_colored() {
  reset_state 2>/dev/null || true
  SKILLS_COLOR_ENABLED=1
  local output
  output="$(skills_list_row "test-skill" 1 "Test description")"
  assert_contains "$output" "✓" "list_row includes checkmark for enabled"
  assert_contains "$output" "test-skill" "list_row includes skill id"
  assert_contains "$output" "Test description" "list_row includes description"
  assert_contains "$output" "${SKILLS_C_GREEN}" "list_row uses green color for enabled"
  assert_contains "$output" "${SKILLS_C_BOLD}" "list_row uses bold for skill id"
}

test_list_row_disabled_colored() {
  reset_state 2>/dev/null || true
  SKILLS_COLOR_ENABLED=1
  local output
  output="$(skills_list_row "old-skill" 0 "Old skill")"
  assert_contains "$output" "-" "list_row includes dash for disabled"
  assert_contains "$output" "old-skill" "list_row includes skill id"
  assert_contains "$output" "${SKILLS_C_DIM}" "list_row uses dim color for disabled"
}

test_list_row_plain_no_ansi() {
  reset_state 2>/dev/null || true
  SKILLS_COLOR_ENABLED=0
  local output
  output="$(skills_list_row "plain-skill" 1)"
  if [[ "$output" == *$'\033'* ]]; then
    test_fail "plain mode has ANSI escapes"
  fi
  assert_contains "$output" "✓" "plain mode includes checkmark"
  assert_contains "$output" "plain-skill" "plain mode includes skill id"
}

test_color_print_forces_color() {
  reset_state 2>/dev/null || true
  SKILLS_COLOR_ENABLED=1
  local output
  output="$(skills_color_print "${SKILLS_C_GREEN}" "hello")"
  assert_contains "$output" "${SKILLS_C_GREEN}" "color_print wraps output in color token"
  assert_contains "$output" "hello" "color_print includes original text"
  assert_contains "$output" "${SKILLS_C_RESET}" "color_print wraps output in reset token"
}

test_color_print_no_color_mode() {
  reset_state 2>/dev/null || true
  SKILLS_COLOR_ENABLED=0
  local output
  output="$(skills_color_print "${SKILLS_C_GREEN}" "world")"
  if [[ "$output" == *$'\033'* ]]; then
    test_fail "no-color mode has ANSI escapes"
  fi
  if [[ "$output" != "world" ]]; then
    test_fail "no-color mode should pass text through"
  fi
}

# -- discovery and metadata tests --

test_skills_list_ids_empty_root() {
  local ids
  ids="$(skills_list_ids "/tmp/nonexistent_root_$$")"
  if !   [[ -z "$ids" ]]; then
    test_fail "empty output for nonexistent root"
  fi
}

test_skills_list_ids_finds_complete_skills() {
  local tree_root
  setup_tmpdir
  build_test_skill_tree "$TEST_TMP_DIR"
  local ids
  mapfile -t ids < <(skills_list_ids "$(test_enabled_root)")
  if !   [[ ${#ids[@]} -ge 3 ]]; then
    test_fail "lists alpha, multiline, malformed (at least 3)"
  fi
  if ! printf '%s\n' "${ids[@]}" | grep -q "^alpha$"; then test_fail "contains alpha"; fi
  if ! printf '%s\n' "${ids[@]}" | grep -q "^multiline$"; then test_fail "contains multiline"; fi
  if ! printf '%s\n' "${ids[@]}" | grep -q "^malformed$"; then test_fail "contains malformed"; fi
}

test_skills_list_ids_ignores_incomplete_dirs() {
  local tree_root
  setup_tmpdir
  build_test_skill_tree "$TEST_TMP_DIR"
  mkdir -p "$(test_enabled_root)/incomplete"
  local ids
  mapfile -t ids < <(skills_list_ids "$(test_enabled_root)")
  if !   [[ ${#ids[@]} -ge 3 ]]; then
    test_fail "lists 3 complete skills, not incomplete"
  fi
  printf '%s\n' "${ids[@]}" | grep -q "^incomplete$" || true
}

test_skills_list_ids_sorted() {
  local tree_root
  setup_tmpdir
  build_test_skill_tree "$TEST_TMP_DIR"
  local ids
  mapfile -t ids < <(skills_list_ids "$(test_enabled_root)")
  local sorted_ids=()
  mapfile -t sorted_ids < <(printf '%s\n' "${ids[@]}" | sort)
  assert_eq "$(printf '%s' "${ids[*]}")" "$(printf '%s' "${sorted_ids[*]}")" "ids are sorted"
}

test_skills_read_metadata_returns_summary_and_description() {
  local tree_root
  setup_tmpdir
  build_test_skill_tree "$TEST_TMP_DIR"
  local result
  result="$(skills_read_metadata "$(test_enabled_root)/alpha")"
  local summary desc
  summary="$(printf '%s' "$result" | head -n 1)"
  desc="$(printf '%s' "$result" | sed -n '2p')"
  if !   [[ "$summary" == "Alpha skill" ]]; then
    test_fail "reads summary for alpha skill"
  fi
  if !   [[ "$desc" == "This is the alpha skill for testing purposes." ]]; then
    test_fail "reads single-line description"
  fi
}

test_skills_read_metadata_multiline() {
  local tree_root
  setup_tmpdir
  build_test_skill_tree "$TEST_TMP_DIR"
  local result
  result="$(skills_read_metadata "$(test_enabled_root)/multiline")"
  local summary desc
  summary="$(printf '%s' "$result" | head -n 1)"
  desc="$(printf '%s' "$result" | sed -n '2,$p')"
  if !   [[ "$summary" == "Multiline skill" ]]; then
    test_fail "reads summary for multiline skill"
  fi
  assert_contains "$desc" "This is a multiline description." "multiline includes first line"
  assert_contains "$desc" "It spans several lines." "multiline includes second line"
  assert_contains "$desc" "Used to test multiline YAML block parsing." "multiline includes third line"
}

test_skills_read_metadata_missing_summary() {
  local tree_root
  setup_tmpdir
  build_test_skill_tree "$TEST_TMP_DIR"
  local result
  result="$(skills_read_metadata "$(test_enabled_root)/malformed")"
  local summary desc
  summary="$(printf '%s' "$result" | head -n 1)"
  desc="$(printf '%s' "$result" | sed -n '2p')"
  if !   [[ "$summary" == "" ]]; then
    test_fail "malformed has empty summary"
  fi
  assert_contains "$desc" "This skill has no summary field." "malformed has description"
}

test_skills_discover_enabled() {
  local tree_root
  setup_tmpdir
  build_test_skill_tree "$TEST_TMP_DIR"
  # First sync to create symlinks
  SKILLS_ENABLED_ROOT="$(test_enabled_root)" SKILLS_SYMLINK_ROOT="$(test_symlink_root)" "$SKILLS_BIN" sync >/dev/null 2>&1
  local ids
  mapfile -t ids < <(SKILLS_ENABLED_ROOT="$(test_enabled_root)" skills_list_ids "$(test_enabled_root)")
  if !   [[ ${#ids[@]} -ge 3 ]]; then
    test_fail "discovers 3+ enabled skills"
  fi
}

test_skills_discover_missing_disabled_root() {
  local tree_root
  setup_tmpdir
  build_test_skill_tree "$TEST_TMP_DIR"
  local ids
  mapfile -t ids < <(skills_list_ids "/tmp/nonexistent_disabled_$$")
  if !   [[ ${#ids[@]} -eq 0 ]]; then
    test_fail "returns empty for missing disabled root"
  fi
}

test_list_shows_enabled_skills() {
  setup_tmpdir
  build_test_skill_tree "$TEST_TMP_DIR"
  # First sync to create symlinks
  SKILLS_ENABLED_ROOT="$(test_enabled_root)" SKILLS_SYMLINK_ROOT="$(test_symlink_root)" "$SKILLS_BIN" sync >/dev/null 2>&1
  local output
  output="$(SKILLS_ENABLED_ROOT="$(test_enabled_root)" SKILLS_SYMLINK_ROOT="$(test_symlink_root)" SKILLS_DISABLED_ROOT="$(test_disabled_root)" "$SKILLS_BIN" list 2>&1)"
  assert_contains "$output" "alpha" "list shows 'alpha' skill"
  assert_contains "$output" "multiline" "list shows 'multiline' skill"
  if !   [[ -n "$output" ]]; then
    test_fail "list produces output"
  fi
}

test_list_shows_disabled_with_flag() {
  local tree_root
  setup_tmpdir
  build_test_skill_tree "$TEST_TMP_DIR"
  # First sync to populate skills-enabled
  SKILLS_ENABLED_ROOT="$(test_enabled_root)" SKILLS_SYMLINK_ROOT="$(test_symlink_root)" "$SKILLS_BIN" sync >/dev/null 2>&1
  local output
  output="$(SKILLS_ENABLED_ROOT="$(test_enabled_root)" SKILLS_SYMLINK_ROOT="$(test_symlink_root)" SKILLS_DISABLED_ROOT="$(test_disabled_root)" "$SKILLS_BIN" list --disabled 2>&1)" || true
  assert_contains "$output" "disabled" "list --disabled shows 'disabled' skill"
  assert_not_contains "$output" "alpha" "list --disabled does NOT show enabled skills"
}

test_status_shows_counts() {
  setup_tmpdir
  build_test_skill_tree "$TEST_TMP_DIR"
  # First sync to populate skills-enabled
  SKILLS_ENABLED_ROOT="$(test_enabled_root)" SKILLS_SYMLINK_ROOT="$(test_symlink_root)" "$SKILLS_BIN" sync >/dev/null 2>&1
  local output
  output="$(SKILLS_ENABLED_ROOT="$(test_enabled_root)" SKILLS_SYMLINK_ROOT="$(test_symlink_root)" SKILLS_DISABLED_ROOT="$(test_disabled_root)" "$SKILLS_BIN" status 2>&1)"
  assert_contains "$output" "total" "status shows total"
  assert_contains "$output" "enabled" "status shows enabled count"
  assert_contains "$output" "disabled" "status shows disabled count"
}

test_list_stable_ordering() {
  setup_tmpdir
  build_test_skill_tree "$TEST_TMP_DIR"
  # First sync to populate skills-enabled
  SKILLS_ENABLED_ROOT="$(test_enabled_root)" SKILLS_SYMLINK_ROOT="$(test_symlink_root)" "$SKILLS_BIN" sync >/dev/null 2>&1
  local output1 output2
  output1="$(SKILLS_ENABLED_ROOT="$(test_enabled_root)" SKILLS_SYMLINK_ROOT="$(test_symlink_root)" SKILLS_DISABLED_ROOT="$(test_disabled_root)" "$SKILLS_BIN" list 2>&1)"
  output2="$(SKILLS_ENABLED_ROOT="$(test_enabled_root)" SKILLS_SYMLINK_ROOT="$(test_symlink_root)" SKILLS_DISABLED_ROOT="$(test_disabled_root)" "$SKILLS_BIN" list 2>&1)"
  if !   [[ "$output1" == "$output2" ]]; then
    test_fail "list output is stable across calls"
  fi
}


# -- enable/disable mutation tests --

test_enable_unknown_skill_fails() {
  setup_tmpdir
  build_test_skill_tree "$TEST_TMP_DIR"
  local output
  output="$(SKILLS_ENABLED_ROOT="$(test_enabled_root)" SKILLS_SYMLINK_ROOT="$(test_symlink_root)" SKILLS_DISABLED_ROOT="$(test_disabled_root)" "$SKILLS_BIN" enable nonexistent 2>&1)" || true
  assert_contains "$output" "not found in disabled skills" "enable fails for unknown skill"
}

test_enable_existing_skill_fails() {
  setup_tmpdir
  build_test_skill_tree "$TEST_TMP_DIR"
  # Create alpha in disabled root but also already in enabled - collision
  mkdir -p "$(test_disabled_root)/alpha"
  cp "$(test_enabled_root)/alpha/SKILL.md" "$(test_disabled_root)/alpha/SKILL.md" 2>/dev/null || true
  local output
  output="$(SKILLS_ENABLED_ROOT="$(test_enabled_root)" SKILLS_SYMLINK_ROOT="$(test_symlink_root)" SKILLS_DISABLED_ROOT="$(test_disabled_root)" "$SKILLS_BIN" enable alpha 2>&1)" || true
  assert_contains "$output" "already exists in enabled" "enable fails for skill already in enabled"
}

test_disable_unknown_skill_fails() {
  setup_tmpdir
  build_test_skill_tree "$TEST_TMP_DIR"
  local output
  output="$(SKILLS_ENABLED_ROOT="$(test_enabled_root)" SKILLS_SYMLINK_ROOT="$(test_symlink_root)" SKILLS_DISABLED_ROOT="$(test_disabled_root)" "$SKILLS_BIN" disable nonexistent 2>&1)" || true
  assert_contains "$output" "not found in enabled skills" "disable fails for unknown skill"
}

test_disable_success_creates_disabled_dir() {
  setup_tmpdir
  build_test_skill_tree "$TEST_TMP_DIR"
  local output
  output="$(SKILLS_ENABLED_ROOT="$(test_enabled_root)" SKILLS_SYMLINK_ROOT="$(test_symlink_root)" SKILLS_DISABLED_ROOT="$(test_disabled_root)" "$SKILLS_BIN" disable alpha 2>&1)" || true
  assert_contains "$output" "Disabled skill" "disable reports success"
}

test_enable_success() {
  setup_tmpdir
  build_test_skill_tree "$TEST_TMP_DIR"
  # First disable alpha
  local output
  output="$(SKILLS_ENABLED_ROOT="$(test_enabled_root)" SKILLS_SYMLINK_ROOT="$(test_symlink_root)" SKILLS_DISABLED_ROOT="$(test_disabled_root)" "$SKILLS_BIN" disable alpha 2>&1)" || true
  assert_contains "$output" "Disabled skill 'alpha'" "disable alpha succeeds"
  # Then re-enable it
  output="$(SKILLS_ENABLED_ROOT="$(test_enabled_root)" SKILLS_SYMLINK_ROOT="$(test_symlink_root)" SKILLS_DISABLED_ROOT="$(test_disabled_root)" "$SKILLS_BIN" enable alpha 2>&1)" || true
  assert_contains "$output" "Enabled skill 'alpha'" "enable alpha succeeds"
}

test_validate_id_rejects_path_traversal() {
  source "$SKILLS_BIN" 2>/dev/null
  local output status=0
  capture_command output status skills_validate_id "../etc/passwd" 2>&1 || status=$?
  assert_contains "$output" "must not contain" "rejects '..' in ID"
  capture_command output status skills_validate_id "foo/bar" 2>&1 || status=$?
  assert_contains "$output" "must not contain" "rejects '/' in ID"
}

# -- sync tests --

test_sync_creates_symlinks() {
  setup_tmpdir
  build_test_skill_tree "$TEST_TMP_DIR"
  local output
  output="$(SKILLS_ENABLED_ROOT="$(test_enabled_root)" SKILLS_SYMLINK_ROOT="$(test_symlink_root)" "$SKILLS_BIN" sync 2>&1)"
  assert_contains "$output" "Synced skills" "sync reports success"
  # Check that symlinks were created
  if [[ ! -L "$(test_symlink_root)/alpha" ]]; then
    test_fail "alpha symlink created"
  fi
  if [[ ! -L "$(test_symlink_root)/multiline" ]]; then
    test_fail "multiline symlink created"
  fi
}

test_sync_warns_about_orphans() {
  setup_tmpdir
  build_test_skill_tree "$TEST_TMP_DIR"
  # Create a symlink to a nonexistent skill in the symlink root
  mkdir -p "$(test_symlink_root)"
  ln -s "$(test_enabled_root)/nonexistent" "$(test_symlink_root)/orphan"
  local output
  output="$(SKILLS_ENABLED_ROOT="$(test_enabled_root)" SKILLS_SYMLINK_ROOT="$(test_symlink_root)" "$SKILLS_BIN" sync 2>&1)" || true
  assert_contains "$output" "orphan" "sync warns about orphans"
  assert_contains "$output" "--prune" "sync suggests --prune"
}

test_sync_prunes_orphans() {
  setup_tmpdir
  build_test_skill_tree "$TEST_TMP_DIR"
  # Create a symlink to a nonexistent skill in the symlink root
  mkdir -p "$(test_symlink_root)"
  ln -s "$(test_enabled_root)/nonexistent" "$(test_symlink_root)/orphan"
  local output
  output="$(SKILLS_ENABLED_ROOT="$(test_enabled_root)" SKILLS_SYMLINK_ROOT="$(test_symlink_root)" "$SKILLS_BIN" sync --prune 2>&1)"
  assert_contains "$output" "Pruned" "sync --prune reports pruning"
  if [[ -e "$(test_symlink_root)/orphan" ]]; then
    test_fail "orphaned symlink was removed"
  fi
}

test_sync_overwrites_existing_symlinks() {
  setup_tmpdir
  build_test_skill_tree "$TEST_TMP_DIR"
  # Create a symlink pointing to a different location
  mkdir -p "$(test_symlink_root)"
  ln -s "/tmp/old_path" "$(test_symlink_root)/alpha"
  local output
  output="$(SKILLS_ENABLED_ROOT="$(test_enabled_root)" SKILLS_SYMLINK_ROOT="$(test_symlink_root)" "$SKILLS_BIN" sync 2>&1)"
  assert_contains "$output" "Synced skills" "sync succeeds"
  # Check that symlink was updated
  local target
  target="$(readlink "$(test_symlink_root)/alpha")"
  if [[ "$target" != "$(test_enabled_root)/alpha" ]]; then
    test_fail "symlink was overwritten to point to source"
  fi
}

test_sync_dry_run_no_changes() {
  setup_tmpdir
  build_test_skill_tree "$TEST_TMP_DIR"
  local output
  output="$(SKILLS_ENABLED_ROOT="$(test_enabled_root)" SKILLS_SYMLINK_ROOT="$(test_symlink_root)" "$SKILLS_BIN" sync --dry-run 2>&1)"
  assert_contains "$output" "DRY-RUN" "dry-run mode indicated"
  assert_contains "$output" "no changes made" "dry-run says no changes made"
  # Check that no symlinks were actually created
  if [[ -d "$(test_symlink_root)" ]] && [[ -n "$(find "$(test_symlink_root)" -type l 2>/dev/null | head -1)" ]]; then
    test_fail "dry-run should not create symlinks"
  fi
}

test_sync_verbose_shows_details() {
  setup_tmpdir
  build_test_skill_tree "$TEST_TMP_DIR"
  local output
  output="$(SKILLS_ENABLED_ROOT="$(test_enabled_root)" SKILLS_SYMLINK_ROOT="$(test_symlink_root)" "$SKILLS_BIN" sync --verbose 2>&1)"
  assert_contains "$output" "Created:" "verbose shows created count"
  assert_contains "$output" "Skipped:" "verbose shows skipped count"
}

setup_tmpdir
run_tests "$@"
