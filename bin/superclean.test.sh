#!/usr/bin/env bash
# shellcheck disable=SC1091

set -euo pipefail

DOTFILES="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
SUPERCLEAN_BIN="$DOTFILES/bin/superclean"

source "$DOTFILES/bin/lib/bash_test.sh"
source "$SUPERCLEAN_BIN" source

reload_superclean_functions() {
  trap - EXIT INT TERM
  source "$SUPERCLEAN_BIN" source
}

superclean_reset_state() {
  SUPER_CLEAN_DRY_RUN=0
  SUPER_CLEAN_VERBOSE=0
  SUPER_CLEAN_INTERACTIVE=0
  SUPER_CLEAN_AGGRESSIVE=0
  SUPER_CLEAN_COLOR_ENABLED=1
  SUPER_CLEAN_SUDO_ENABLED=1
  SUPER_CLEAN_HAS_FD=0
  SUPER_CLEAN_HAS_FZF=0
  SUPER_CLEAN_SUDO_CHECKED=0
  SUPER_CLEAN_TOUCH_ID_SUDO_AVAILABLE=0
  SUPER_CLEAN_SUDO_SESSION_READY=0
  SUPER_CLEAN_INSTALLED_APP_KEYS_CACHED=0
  SUPER_CLEAN_GROUP_NODE=1
  SUPER_CLEAN_GROUP_JAVA=1
  SUPER_CLEAN_GROUP_RUBY=1
  SUPER_CLEAN_GROUP_GO=1
  SUPER_CLEAN_GROUP_BREW=1
  SUPER_CLEAN_GROUP_APPS=1
  SUPER_CLEAN_GROUP_LOGS=1
  SUPER_CLEAN_GROUP_HOOKS=1
  SUPER_CLEAN_GROUP_CONTAINERS=1
  SUPER_CLEAN_POSITIVE_GROUP_FLAGS=0
  SUPER_CLEAN_TOTAL_RECLAIMED_KB=0
  SUPER_CLEAN_TOTAL_COMMAND_ESTIMATE_KB=0
  SUPER_CLEAN_START_AVAIL_KB=0
  SUPER_CLEAN_TARGET_DIRS_CACHED=0
  SUPER_CLEAN_HOOKS_CACHED=0
  SUPER_CLEAN_DISCOVERED_TARGET_DIRS=""
  SUPER_CLEAN_DISCOVERED_HOOKS=""
  SUPER_CLEAN_INSTALLED_APP_KEYS=""
  SUPER_CLEAN_LIVE_SCAN_ACTIVE=0
  SUPER_CLEAN_ROOTS=(
    "$HOME/src"
    "$HOME/projects"
  )
}

test_basic_flags_and_formatting() {
  local tmp_root=""
  local sum_kb=0
  local emitted_keys=""
  local installed_keys=""
  local ranked_entries=""

  superclean_reset_state
  superclean_parse_args --dry-run --verbose --interactive --aggressive
  assert_eq "1" "$SUPER_CLEAN_DRY_RUN" "dry-run flag"
  assert_eq "1" "$SUPER_CLEAN_VERBOSE" "verbose flag"
  assert_eq "1" "$SUPER_CLEAN_INTERACTIVE" "interactive flag"
  assert_eq "1" "$SUPER_CLEAN_AGGRESSIVE" "aggressive flag"

  superclean_reset_state
  superclean_parse_args --no-sudo
  assert_eq "0" "$SUPER_CLEAN_SUDO_ENABLED" "no-sudo flag"
  superclean_reset_state
  superclean_parse_args --sudo
  assert_eq "1" "$SUPER_CLEAN_SUDO_ENABLED" "sudo flag"

  superclean_reset_state
  superclean_parse_args --no-color
  assert_eq "0" "$SUPER_CLEAN_COLOR_ENABLED" "no-color flag"
  superclean_reset_state
  superclean_parse_args --color
  assert_eq "1" "$SUPER_CLEAN_COLOR_ENABLED" "color flag"

  superclean_reset_state
  superclean_parse_args --node --java
  assert_eq "1" "$SUPER_CLEAN_GROUP_NODE" "node group enabled"
  assert_eq "1" "$SUPER_CLEAN_GROUP_JAVA" "java group enabled"
  assert_eq "0" "$SUPER_CLEAN_GROUP_RUBY" "ruby group disabled by positive selection"
  assert_eq "0" "$SUPER_CLEAN_GROUP_GO" "go group disabled by positive selection"
  assert_eq "0" "$SUPER_CLEAN_GROUP_BREW" "brew group disabled by positive selection"
  assert_eq "0" "$SUPER_CLEAN_GROUP_APPS" "apps group disabled by positive selection"

  superclean_reset_state
  superclean_parse_args --no-java --no-hooks --no-brew
  assert_eq "0" "$SUPER_CLEAN_GROUP_JAVA" "java group disabled"
  assert_eq "0" "$SUPER_CLEAN_GROUP_HOOKS" "hooks group disabled"
  assert_eq "0" "$SUPER_CLEAN_GROUP_BREW" "brew group disabled"
  assert_eq "1" "$SUPER_CLEAN_GROUP_NODE" "node group remains enabled"

  superclean_reset_state
  superclean_parse_args --apps
  assert_eq "1" "$SUPER_CLEAN_GROUP_APPS" "apps group enabled"
  assert_eq "0" "$SUPER_CLEAN_GROUP_NODE" "node group disabled by apps only mode"
  assert_eq "0" "$SUPER_CLEAN_GROUP_JAVA" "java group disabled by apps only mode"
  assert_eq "0" "$SUPER_CLEAN_GROUP_HOOKS" "hooks group disabled by apps only mode"

  assert_eq "10.0 KB" "$(superclean_format_kb 10)" "format small kb"
  assert_eq "2.0 MB" "$(superclean_format_kb 2048)" "format mb"
  assert_eq "2.00 GB" "$(superclean_format_kb 2097152)" "format gb"

  tmp_root="$(mktemp -d)"
  mkdir -p "$tmp_root/demo"
  du() { return 1; }
  assert_eq "0" "$(superclean_path_size_kb "$tmp_root/demo")" "path size falls back to zero when du fails"
  unset -f du
  rm -rf "$tmp_root"

  tmp_root="$(mktemp -d)"
  mkdir -p "$tmp_root/a" "$tmp_root/b"
  printf '1234567890' >"$tmp_root/a/file"
  printf '12345678901234567890' >"$tmp_root/b/file"
  sum_kb="$(superclean_sum_paths_kb "$tmp_root/a" "$tmp_root/b")"
  if (( sum_kb <= 0 )); then
    test_fail "sum paths" "Expected positive KB sum" "Actual: [$sum_kb]"
  fi
  rm -rf "$tmp_root"

  assert_eq " (est. 2.0 MB)" "$(superclean_format_estimate_suffix 2048)" "estimate suffix"
  assert_eq "" "$(superclean_format_estimate_suffix 0)" "empty estimate suffix"

  assert_eq "devwarpwarpstable" "$(superclean_normalize_app_key 'dev.warp.Warp-Stable')" "normalize bundle-like support dir"
  emitted_keys="$(superclean_emit_name_keys 'dev.warp.Warp-Stable' | tr '\n' ' ')"
  assert_contains "$emitted_keys" "warp" "emit name keys includes normalized app name"

  assert_eq "apps" "$(superclean_classify_library_dir "$HOME/Library/Caches")" "caches classified as apps"
  assert_eq "system" "$(superclean_classify_library_dir "$HOME/Library/Mail")" "mail classified as system"
  assert_eq "review" "$(superclean_classify_library_dir "$HOME/Library/Fonts")" "fonts classified as review"

  installed_keys="$(printf 'warp\nvisualstudiocode\ncode\n')"
  tmp_root="$(mktemp -d)"
  mkdir -p "$tmp_root/dev.warp.Warp-Stable" "$tmp_root/LM Studio" "$tmp_root/com.apple.Safari"
  assert_eq "installed" "$(superclean_classify_app_support_dir "$tmp_root/dev.warp.Warp-Stable" "$installed_keys")" "warp support dir matches installed app"
  assert_eq "orphan-review" "$(superclean_classify_app_support_dir "$tmp_root/LM Studio" "$installed_keys")" "unmatched support dir becomes orphan review"
  assert_eq "system" "$(superclean_classify_app_support_dir "$tmp_root/com.apple.Safari" "$installed_keys")" "apple support dir classified as system"
  rm -rf "$tmp_root"

  tmp_root="$(mktemp -d)"
  mkdir -p "$tmp_root/parent/dir-a"
  printf 'demo' >"$tmp_root/parent/file-a"
  ranked_entries="$(superclean_emit_ranked_child_entries "$tmp_root/parent")"
  assert_contains "$ranked_entries" "$tmp_root/parent/dir-a" "ranked child entries include directories"
  assert_contains "$ranked_entries" "$tmp_root/parent/file-a" "ranked child entries include files"
  rm -rf "$tmp_root"
}

test_discovery_and_heuristics() {
  local tmp_root=""
  local actual_roots=""
  local expected_roots=""
  local actual_targets=""
  local expected_targets=""
  local actual_filtered=""
  local expected_filtered=""
  local actual_hooks=""
  local actual_makefiles=""
  local git_status=1
  local direnv_status=1
  local node_status=1
  local vendored_hook_status=1
  local normal_hook_status=1
  local protected_path_status=1
  local writable_path_status=1
  local protected_hook_status=1
  local writable_hook_status=1

  assert_eq "a,b,c" "$(superclean_join_by "," a b c)" "join multiple"
  assert_eq "solo" "$(superclean_join_by "," solo)" "join single"
  assert_eq "" "$(superclean_join_by ",")" "join empty"

  tmp_root="$(mktemp -d)"
  mkdir -p "$tmp_root/src" "$tmp_root/projects"
  SUPER_CLEAN_ROOTS=("$tmp_root/src" "$tmp_root/projects" "$tmp_root/missing")
  actual_roots="$(superclean_existing_roots)"
  expected_roots="$(printf '%s\n%s' "$tmp_root/src" "$tmp_root/projects")"
  assert_eq "$expected_roots" "$actual_roots" "existing roots only keep present paths"
  rm -rf "$tmp_root"

  if superclean_should_exclude_dir "/tmp/demo/.git"; then git_status=0; fi
  if superclean_should_exclude_dir "/tmp/demo/.direnv"; then direnv_status=0; fi
  if superclean_should_exclude_dir "/tmp/demo/node_modules"; then node_status=0; fi
  assert_status "0" "$git_status" "exclude .git"
  assert_status "0" "$direnv_status" "exclude .direnv"
  assert_status "1" "$node_status" "do not exclude node_modules"

  superclean_reset_state
  tmp_root="$(mktemp -d)"
  mkdir -p "$tmp_root/src/app/node_modules" "$tmp_root/src/app/target" "$tmp_root/src/app/.git" "$tmp_root/projects"
  SUPER_CLEAN_ROOTS=("$tmp_root/src" "$tmp_root/projects")
  SUPER_CLEAN_HAS_FD=0
  SUPER_CLEAN_AGGRESSIVE=0
  actual_targets="$(superclean_discover_target_dirs | sort)"
  expected_targets="$(printf '%s\n%s' "$tmp_root/src/app/node_modules" "$tmp_root/src/app/target")"
  assert_eq "$expected_targets" "$actual_targets" "discover deep scan dirs"
  rm -rf "$tmp_root"

  superclean_reset_state
  actual_filtered="$(printf '%s\n%s\n%s' \
    "/tmp/demo/node_modules/" \
    "/tmp/demo/node_modules/pkg/node_modules/" \
    "/tmp/demo/target/" | sort | superclean_filter_nested_targets)"
  expected_filtered="$(printf '%s\n%s' "/tmp/demo/node_modules" "/tmp/demo/target")"
  assert_eq "$expected_filtered" "$actual_filtered" "drop nested cleanup dirs"

  superclean_reset_state
  tmp_root="$(mktemp -d)"
  mkdir -p "$tmp_root/src/app/bin" "$tmp_root/src/app/scripts" "$tmp_root/projects"
  printf '#!/usr/bin/env bash\n' >"$tmp_root/src/app/bin/cleanup"
  chmod +x "$tmp_root/src/app/bin/cleanup"
  printf '#!/usr/bin/env bash\n' >"$tmp_root/src/app/scripts/clean.sh"
  chmod +x "$tmp_root/src/app/scripts/clean.sh"
  SUPER_CLEAN_ROOTS=("$tmp_root/src" "$tmp_root/projects")
  SUPER_CLEAN_HAS_FD=0
  actual_hooks="$(superclean_find_unique_hooks)"
  assert_eq "$tmp_root/src/app/bin/cleanup" "$actual_hooks" "dedupe hooks per project"
  rm -rf "$tmp_root"

  superclean_reset_state
  if superclean_should_skip_hook_path "/tmp/app/node_modules/pkg/Makefile"; then vendored_hook_status=0; fi
  if superclean_should_skip_hook_path "/tmp/app/bin/cleanup"; then normal_hook_status=0; fi
  assert_status "0" "$vendored_hook_status" "skip vendored hooks"
  assert_status "1" "$normal_hook_status" "keep project hooks"

  superclean_reset_state
  tmp_root="$(mktemp -d)"
  mkdir -p "$tmp_root/owned"
  if superclean_path_needs_sudo "/"; then protected_path_status=0; fi
  if superclean_path_needs_sudo "$tmp_root/owned"; then writable_path_status=0; fi
  assert_status "0" "$protected_path_status" "non-owned path flagged for sudo"
  assert_status "1" "$writable_path_status" "owned path does not need sudo"
  rm -rf "$tmp_root"

  superclean_reset_state
  tmp_root="$(mktemp -d)"
  mkdir -p "$tmp_root/src/app/bin" "$tmp_root/projects"
  printf '#!/usr/bin/env bash\n' >"$tmp_root/src/app/bin/cleanup"
  chmod +x "$tmp_root/src/app/bin/cleanup"
  if superclean_hook_needs_sudo "/usr/bin/cleanup"; then protected_hook_status=0; fi
  if superclean_hook_needs_sudo "$tmp_root/src/app/bin/cleanup"; then writable_hook_status=0; fi
  assert_status "0" "$protected_hook_status" "non-owned hook root flagged for sudo"
  assert_status "1" "$writable_hook_status" "owned hook root does not need sudo"
  rm -rf "$tmp_root"

  superclean_reset_state
  tmp_root="$(mktemp -d)"
  mkdir -p "$tmp_root/src/team/repo" "$tmp_root/src/team/repo/vendor/deep" "$tmp_root/projects"
  printf 'clean:\n\t@true\n' >"$tmp_root/src/team/repo/Makefile"
  printf 'clean:\n\t@true\n' >"$tmp_root/src/team/repo/vendor/deep/Makefile"
  SUPER_CLEAN_ROOTS=("$tmp_root/src" "$tmp_root/projects")
  SUPER_CLEAN_HAS_FD=0
  actual_makefiles="$(superclean_find_hook_candidates | sort)"
  assert_eq "$tmp_root/src/team/repo/Makefile" "$actual_makefiles" "only shallow project makefiles"
  rm -rf "$tmp_root"
}

test_interactive_main_flow() {
  local tmp_root=""
  local order_log=""
  local actual_order=""
  local expected_order=""
  local output=""
  local status=0

  superclean_reset_state
  tmp_root="$(mktemp -d)"
  order_log="$(mktemp)"

  superclean_detect_tools() { :; }
  superclean_interactive_select_cleanup_groups() { printf 'select_groups\n' >>"$order_log"; }
  superclean_protips() { printf 'protips\n' >>"$order_log"; }
  superclean_capture_start_disk() { printf 'capture_start_disk\n' >>"$order_log"; }
  superclean_confirm_aggressive_steps() { :; }
  superclean_warn_sudo_if_needed() { :; }
  superclean_plan_runtime_caches() { printf 'plan_runtime_caches\n' >>"$order_log"; }
  superclean_apply_runtime_caches() { printf 'apply_runtime_caches\n' >>"$order_log"; }
  superclean_plan_system_paths() { printf 'plan_system_paths\n' >>"$order_log"; }
  superclean_plan_library_inventory() { printf 'plan_library_inventory\n' >>"$order_log"; }
  superclean_apply_orphan_app_support_cleanup() { printf 'apply_orphan_app_support_cleanup\n' >>"$order_log"; }
  superclean_apply_installed_app_support_cache_cleanup() { printf 'apply_installed_app_support_cache_cleanup\n' >>"$order_log"; }
  superclean_apply_system_paths() { printf 'apply_system_paths\n' >>"$order_log"; }
  superclean_plan_hooks() { printf 'plan_hooks\n' >>"$order_log"; }
  superclean_apply_hooks() { printf 'apply_hooks\n' >>"$order_log"; }
  superclean_plan_deep_scan() { printf 'plan_deep_scan\n' >>"$order_log"; }
  superclean_apply_deep_scan() { printf 'apply_deep_scan\n' >>"$order_log"; }
  superclean_apply_container_prune() { :; }
  superclean_report_reclaimed() { :; }

  superclean_main --interactive
  trap - EXIT INT TERM

  expected_order="$(printf '%s\n' \
    select_groups \
    protips \
    capture_start_disk \
    plan_runtime_caches \
    apply_runtime_caches \
    plan_system_paths \
    plan_library_inventory \
    apply_orphan_app_support_cleanup \
    apply_installed_app_support_cache_cleanup \
    apply_system_paths \
    plan_hooks \
    apply_hooks \
    plan_deep_scan \
    apply_deep_scan)"
  actual_order="$(cat "$order_log")"
  assert_eq "$expected_order" "$actual_order" "interactive group selector runs first"

  unset -f superclean_detect_tools
  unset -f superclean_interactive_select_cleanup_groups
  unset -f superclean_protips
  unset -f superclean_capture_start_disk
  unset -f superclean_confirm_aggressive_steps
  unset -f superclean_warn_sudo_if_needed
  unset -f superclean_plan_runtime_caches
  unset -f superclean_apply_runtime_caches
  unset -f superclean_plan_system_paths
  unset -f superclean_plan_library_inventory
  unset -f superclean_apply_orphan_app_support_cleanup
  unset -f superclean_apply_installed_app_support_cache_cleanup
  unset -f superclean_apply_system_paths
  unset -f superclean_plan_hooks
  unset -f superclean_apply_hooks
  unset -f superclean_plan_deep_scan
  unset -f superclean_apply_deep_scan
  unset -f superclean_apply_container_prune
  unset -f superclean_report_reclaimed
  reload_superclean_functions

  rm -f "$order_log"
  rm -rf "$tmp_root"

  capture_command output status bash -lc "cd \"$DOTFILES\" && source bin/superclean source && \
    superclean_detect_tools() { :; } && \
    superclean_protips() { :; } && \
    superclean_capture_start_disk() { :; } && \
    superclean_confirm_aggressive_steps() { :; } && \
    superclean_warn_sudo_if_needed() { :; } && \
    superclean_plan_runtime_caches() { :; } && \
    superclean_apply_runtime_caches() { :; } && \
    superclean_plan_system_paths() { kill -INT \$\$; } && \
    superclean_plan_library_inventory() { printf FAIL >&2; } && \
    superclean_apply_orphan_app_support_cleanup() { printf FAIL >&2; } && \
    superclean_apply_installed_app_support_cache_cleanup() { printf FAIL >&2; } && \
    superclean_apply_system_paths() { printf FAIL >&2; } && \
    superclean_plan_hooks() { printf FAIL >&2; } && \
    superclean_apply_hooks() { printf FAIL >&2; } && \
    superclean_plan_deep_scan() { printf FAIL >&2; } && \
    superclean_apply_deep_scan() { printf FAIL >&2; } && \
    superclean_apply_container_prune() { printf FAIL >&2; } && \
    superclean_report_reclaimed() { printf FAIL >&2; } && \
    superclean_main --dry-run --apps >/dev/null 2>&1"
  assert_status "130" "$status" "ctrl-c exits immediately"
}

test_library_inventory_dry_run_apps() {
  local tmp_root=""
  local original_home=""
  local inventory_output=""

  superclean_reset_state
  SUPER_CLEAN_DRY_RUN=1
  SUPER_CLEAN_GROUP_APPS=1
  SUPER_CLEAN_APP_SUPPORT_BREAKDOWN_MIN_KB=100
  tmp_root="$(mktemp -d)"
  original_home="$HOME"
  mkdir -p \
    "$tmp_root/home/Library/Application Support/Warp" \
    "$tmp_root/home/Library/Caches/com.apple.bird" \
    "$tmp_root/home/Library/Logs" \
    "$tmp_root/home/Library/Containers/com.example.App" \
    "$tmp_root/home/Library/Developer/CoreSimulator/Devices/Device-1"
  HOME="$tmp_root/home"

  superclean_info() { printf '%s\n' "$*"; }
  superclean_log() { printf '%s\n' "$*"; }
  superclean_format_kb() { printf '%s KB' "$1"; }
  superclean_collect_installed_app_keys() { printf 'warp\n'; }
  superclean_path_mtime_epoch() {
    case "$1" in
      "$HOME/Library/Application Support/Cypress") printf '1700000000' ;;
      "/Library/Application Support/Warp System") printf '1710000000' ;;
      *) printf '0' ;;
    esac
  }
  superclean_format_mtime_epoch() {
    case "$1" in
      1700000000) printf '2023-11-14 22:13' ;;
      1710000000) printf '2024-03-09 16:00' ;;
      *) printf '-' ;;
    esac
  }
  superclean_emit_ranked_child_dirs() {
    case "$1" in
      "$HOME/Library")
        printf '000000000400\t%s\n' "$HOME/Library/Caches"
        printf '000000000120\t%s\n' "$HOME/Library/Logs"
        ;;
      "/Library")
        printf '000000000800\t%s\n' '/Library/Caches'
        ;;
      "$HOME/Library/Application Support")
        printf '000000000500\t%s\n' "$HOME/Library/Application Support/Warp"
        printf '000000000300\t%s\n' "$HOME/Library/Application Support/Cypress"
        ;;
      "/Library/Application Support")
        printf '000000000600\t%s\n' "/Library/Application Support/Warp System"
        ;;
      "$HOME/Library/Developer/CoreSimulator/Devices")
        printf '000000000900\t%s\n' "$HOME/Library/Developer/CoreSimulator/Devices/Device-1"
        ;;
    esac
  }
  superclean_app_support_roots() {
    printf '%s\n' "$HOME/Library/Application Support"
    printf '%s\n' "/Library/Application Support"
  }
  superclean_emit_ranked_child_entries() {
    case "$1" in
      "$HOME/Library/Application Support/Warp")
        printf '000000000300\t%s\n' "$HOME/Library/Application Support/Warp/Cache"
        printf '000000000120\t%s\n' "$HOME/Library/Application Support/Warp/Storage"
        ;;
      "$HOME/Library/Application Support/Cypress")
        printf '000000000200\t%s\n' "$HOME/Library/Application Support/Cypress/browsers"
        ;;
    esac
  }
  superclean_emit_app_support_cache_rows() {
    printf '000000000420\t000000000500\t%s\t%s\n' "$HOME/Library/Application Support/Warp" "$HOME/Library/Application Support/Warp/CachedData"
    printf '000000000240\t000000000600\t%s\t%s\n' "/Library/Application Support/Warp System" "/Library/Application Support/Warp System/GPUCache"
  }
  superclean_emit_container_rows() {
    printf '000000000700\tinstalled\t%s\n' "$HOME/Library/Containers/com.example.App"
  }
  superclean_emit_container_cache_rows() {
    printf '000000000500\t%s\n' "$HOME/Library/Containers/com.example.App/Data/Library/Caches"
  }
  superclean_path_size_kb() {
    case "$1" in
      "$HOME/Library/Caches/com.apple.bird") printf '2200' ;;
      "$HOME/Library/Developer/CoreSimulator/Devices") printf '1500' ;;
      *) printf '0' ;;
    esac
  }
  xcrun() { :; }

  inventory_output="$(superclean_plan_library_inventory)"
  assert_contains "$inventory_output" "Inventory: largest ~/Library directories (dry-run)" "library inventory prints top-level summary"
  assert_contains "$inventory_output" "Breakdown: Warp (installed, 000000000500 KB)" "library inventory prints app support breakdown"
  assert_contains "$inventory_output" "Review: likely orphaned Application Support entries under ~/Library and /Library (dry-run)" "library inventory prints orphan review"
  assert_contains "$inventory_output" "$HOME/Library/Application Support/Cypress" "library inventory includes orphaned app support path"
  assert_contains "$inventory_output" "2023-11-14 22:13" "library inventory includes orphan updated time"
  assert_contains "$inventory_output" "Review: cache-like subpaths inside installed app support dirs under ~/Library and /Library (dry-run)" "library inventory prints installed cache review"
  assert_contains "$inventory_output" "$HOME/Library/Application Support/Warp/CachedData" "library inventory includes user app-support cache path"
  assert_contains "$inventory_output" "/Library/Application Support/Warp System/GPUCache" "library inventory includes system app-support cache path"
  assert_contains "$inventory_output" "Inventory: largest ~/Library/Containers entries (dry-run)" "library inventory prints containers inventory"
  assert_contains "$inventory_output" "Inventory: iCloud sync cache (dry-run)" "library inventory prints bird cache inventory"
  assert_contains "$inventory_output" "rebuild local sync state after restart" "library inventory includes bird cache guidance"
  assert_contains "$inventory_output" "Container caches: com.example.App (installed, 000000000700 KB)" "library inventory prints container cache breakdown"
  assert_contains "$inventory_output" "Inventory: ~/Library/Developer/CoreSimulator/Devices (dry-run)" "library inventory prints CoreSimulator inventory"
  assert_contains "$inventory_output" "safer cleanup command: xcrun simctl delete unavailable" "library inventory includes CoreSimulator guidance"
  assert_contains "$inventory_output" "Inventory: largest /Library directories (dry-run)" "library inventory prints /Library inventory"

  unset -f superclean_info
  unset -f superclean_log
  unset -f superclean_format_kb
  unset -f superclean_collect_installed_app_keys
  unset -f superclean_path_mtime_epoch
  unset -f superclean_format_mtime_epoch
  unset -f superclean_app_support_roots
  unset -f superclean_emit_ranked_child_dirs
  unset -f superclean_emit_ranked_child_entries
  unset -f superclean_emit_app_support_cache_rows
  unset -f superclean_emit_container_rows
  unset -f superclean_emit_container_cache_rows
  unset -f superclean_path_size_kb
  unset -f xcrun

  HOME="$original_home"
  reload_superclean_functions
  rm -rf "$tmp_root"
}

test_selector_and_apply_flows() {
  local tmp_root=""
  local args_log=""
  local input_log=""
  local selected_log=""
  local expected_row=""
  local apply_output=""
  local row_prefix=""
  local status_output=""

  superclean_reset_state
  tmp_root="$(mktemp -d)"
  args_log="$tmp_root/fzf.args"
  input_log="$tmp_root/fzf.input"
  selected_log="$tmp_root/selected.log"

  superclean_register_cleanup_trap() { :; }
  superclean_detect_tools() { :; }
  superclean_protips() { :; }
  superclean_capture_start_disk() { :; }
  superclean_confirm_aggressive_steps() { :; }
  superclean_warn_sudo_if_needed() { :; }
  superclean_apply_container_prune() { :; }
  superclean_report_reclaimed() { :; }
  superclean_cached_hooks() {
    printf '%s\n%s\n' "$tmp_root/src/app/bin/cleanup" "$tmp_root/src/other/bin/cleanup"
  }
  superclean_hook_project_root() {
    case "$1" in
      "$tmp_root/src/app/bin/cleanup") printf '%s\n' "$tmp_root/src/app" ;;
      "$tmp_root/src/other/bin/cleanup") printf '%s\n' "$tmp_root/src/other" ;;
      *) return 1 ;;
    esac
  }
  SUPER_CLEAN_HAS_FZF=1
  fzf() {
    printf '%s\n' "$*" >"$args_log"
    cat >"$input_log"
    head -n 1 "$input_log"
  }

  selected_log="$(superclean_interactive_select_hooks)"
  assert_eq "$tmp_root/src/app/bin/cleanup" "$selected_log" "interactive hook selection returns chosen hook"
  assert_eq "1" "$(grep -cF -- '--with-nth=1,2' "$args_log")" "hook selector hides raw path from visible list"
  assert_eq "1" "$(grep -cF -- '--bind=ctrl-a:select-all,ctrl-d:deselect-all' "$args_log")" "hook selector includes bulk bindings"
  assert_eq "1" "$(grep -cF -- '--height=50%' "$args_log")" "hook selector sets consistent height"
  assert_eq "1" "$(grep -cF -- 'ctrl-a: all  ctrl-d: none' "$args_log")" "hook selector shows bulk-selection hint"
  assert_eq "1" "$(grep -cF -- "$tmp_root/src/app/bin/cleanup" "$input_log")" "hook selector input keeps full path payload"
  row_prefix="$(printf '%s\tcleanup\t' "$tmp_root/src/app")"
  assert_eq "1" "$(grep -cF -- "$row_prefix" "$input_log")" "hook selector keeps root and hook name visible"

  unset -f superclean_register_cleanup_trap
  unset -f superclean_detect_tools
  unset -f superclean_protips
  unset -f superclean_capture_start_disk
  unset -f superclean_confirm_aggressive_steps
  unset -f superclean_warn_sudo_if_needed
  unset -f superclean_apply_container_prune
  unset -f superclean_report_reclaimed
  unset -f superclean_cached_hooks
  unset -f superclean_hook_project_root
  unset -f fzf
  reload_superclean_functions
  rm -rf "$tmp_root"

  superclean_reset_state
  tmp_root="$(mktemp -d)"
  args_log="$tmp_root/deep.args"
  input_log="$tmp_root/deep.input"
  superclean_cached_target_dirs() {
    printf '%s\n%s\n' "$tmp_root/projects/app/node_modules" "$tmp_root/projects/other/node_modules"
  }
  superclean_path_size_kb() {
    case "$1" in
      "$tmp_root/projects/app/node_modules") printf '8' ;;
      "$tmp_root/projects/other/node_modules") printf '6240' ;;
      *) printf '0' ;;
    esac
  }
  SUPER_CLEAN_HAS_FZF=1
  fzf() {
    printf '%s\n' "$*" >"$args_log"
    cat >"$input_log"
    head -n 1 "$input_log"
  }

  selected_log="$(superclean_interactive_select_paths)"
  assert_eq "$tmp_root/projects/app/node_modules" "$selected_log" "interactive deep scan selection returns chosen path"
  assert_eq "1" "$(grep -cF -- '--with-nth=2' "$args_log")" "deep scan selector hides sort key"
  assert_eq "1" "$(grep -cF -- '--bind=ctrl-a:select-all,ctrl-d:deselect-all' "$args_log")" "deep scan selector includes bulk bindings"
  assert_eq "1" "$(grep -cF -- '--height=50%' "$args_log")" "deep scan selector sets consistent height"
  assert_eq "1" "$(grep -cF -- 'ctrl-a: all  ctrl-d: none' "$args_log")" "deep scan selector shows bulk-selection hint"
  expected_row="$(printf '%s\t%s\t%s' '000000000008' "$tmp_root/projects/app/node_modules 8.0 KB" "$tmp_root/projects/app/node_modules")"
  assert_eq "1" "$(grep -cF -- "$expected_row" "$input_log")" "deep scan selector row format"

  unset -f superclean_cached_target_dirs
  unset -f superclean_path_size_kb
  unset -f fzf
  reload_superclean_functions
  rm -rf "$tmp_root"

  superclean_reset_state
  tmp_root="$(mktemp -d)"
  args_log="$tmp_root/orphan.args"
  input_log="$tmp_root/orphan.input"
  superclean_orphan_app_support_rows() {
    printf '000000000120\torphan-review\t%s\n' "$tmp_root/home/Library/Application Support/Cypress"
    printf '000000000090\torphan-review\t%s\n' "$tmp_root/home/Library/Application Support/Cursor"
  }
  superclean_path_mtime_epoch() {
    case "$1" in
      "$tmp_root/home/Library/Application Support/Cypress") printf '1700000000' ;;
      "$tmp_root/home/Library/Application Support/Cursor") printf '1710000000' ;;
      *) printf '0' ;;
    esac
  }
  superclean_format_mtime_epoch() {
    case "$1" in
      1700000000) printf '2023-11-14 22:13' ;;
      1710000000) printf '2024-03-09 16:00' ;;
      *) printf '-' ;;
    esac
  }
  SUPER_CLEAN_HAS_FZF=1
  fzf() {
    printf '%s\n' "$*" >"$args_log"
    cat >"$input_log"
    head -n 1 "$input_log"
  }

  selected_log="$(superclean_interactive_select_orphan_app_support_paths)"
  assert_eq "$tmp_root/home/Library/Application Support/Cypress" "$selected_log" "interactive orphan app support selection returns chosen path"
  assert_eq "1" "$(grep -cF -- '--with-nth=3,4,5' "$args_log")" "orphan selector hides raw sort keys and payload"
  assert_eq "1" "$(grep -cF -- '--bind=ctrl-a:select-all,ctrl-d:deselect-all' "$args_log")" "orphan selector includes bulk bindings"
  assert_eq "1" "$(grep -cF -- 'ctrl-s: sort by size' "$args_log")" "orphan selector exposes size sort toggle"
  assert_eq "1" "$(grep -cF -- 'ctrl-t: sort by updated' "$args_log")" "orphan selector exposes updated sort toggle"
  assert_eq "1" "$(grep -cF -- 'change-prompt(Orphaned app support by size > )' "$args_log")" "orphan selector binds size prompt toggle"
  assert_eq "1" "$(grep -cF -- 'change-prompt(Orphaned app support by updated > )' "$args_log")" "orphan selector binds updated prompt toggle"
  expected_row="$(printf '%s\t%s\t%s\t%s\t%s\t%s' '000000000120' '001700000000' '120.0 KB' '2023-11-14 22:13' 'Cypress' "$tmp_root/home/Library/Application Support/Cypress")"
  assert_eq "1" "$(grep -cF -- "$expected_row" "$input_log")" "orphan selector row format"

  unset -f superclean_orphan_app_support_rows
  unset -f superclean_path_mtime_epoch
  unset -f superclean_format_mtime_epoch
  unset -f fzf
  reload_superclean_functions
  rm -rf "$tmp_root"

  tmp_root="$(mktemp -d)"
  apply_output="$(TMP_ROOT="$tmp_root" DOTFILES="$DOTFILES" bash -lc '
    set -euo pipefail
    cd "$DOTFILES"
    source bin/superclean source
    SUPER_CLEAN_GROUP_APPS=1
    SUPER_CLEAN_DRY_RUN=1
    SUPER_CLEAN_INTERACTIVE=1
    removed_log="$TMP_ROOT/orphan.removed"
    superclean_orphan_app_support_rows() {
      printf "000000000120\torphan-review\t%s\n" "$TMP_ROOT/home/Library/Application Support/Cypress"
    }
    superclean_interactive_select_orphan_app_support_paths() {
      printf "%s\n" "$TMP_ROOT/home/Library/Application Support/Cypress"
    }
    superclean_remove_path() {
      printf "%s\n" "$1" >> "$removed_log"
    }
    superclean_apply_orphan_app_support_cleanup >/dev/null
    cat "$removed_log"
  ')"
  assert_eq "$tmp_root/home/Library/Application Support/Cypress" "$apply_output" "interactive dry-run orphan cleanup applies selected path"
  rm -rf "$tmp_root"

  superclean_reset_state
  tmp_root="$(mktemp -d)"
  args_log="$tmp_root/appcache.args"
  input_log="$tmp_root/appcache.input"
  superclean_emit_app_support_cache_rows() {
    printf '000000000420\t000000001000\t%s\t%s\n' "$tmp_root/home/Library/Application Support/Code" "$tmp_root/home/Library/Application Support/Code/CachedData"
    printf '000000000210\t000000001000\t%s\t%s\n' "$tmp_root/home/Library/Application Support/Code" "$tmp_root/home/Library/Application Support/Code/GPUCache"
  }
  SUPER_CLEAN_HAS_FZF=1
  fzf() {
    printf '%s\n' "$*" >"$args_log"
    cat >"$input_log"
    head -n 1 "$input_log"
  }

  selected_log="$(superclean_interactive_select_app_support_cache_paths)"
  assert_eq "$tmp_root/home/Library/Application Support/Code/CachedData" "$selected_log" "interactive installed app-support cache selection returns chosen path"
  assert_eq "1" "$(grep -cF -- '--with-nth=2,3,4' "$args_log")" "app-support cache selector hides raw sort key and payload"
  expected_row="$(printf '%s\t%s\t%s\t%s\t%s' '000000000420' '420.0 KB' 'Code' 'CachedData' "$tmp_root/home/Library/Application Support/Code/CachedData")"
  assert_eq "1" "$(grep -cF -- "$expected_row" "$input_log")" "app-support cache selector row format"

  unset -f superclean_emit_app_support_cache_rows
  unset -f fzf
  reload_superclean_functions
  rm -rf "$tmp_root"

  tmp_root="$(mktemp -d)"
  apply_output="$(TMP_ROOT="$tmp_root" DOTFILES="$DOTFILES" bash -lc '
    set -euo pipefail
    cd "$DOTFILES"
    source bin/superclean source
    SUPER_CLEAN_GROUP_APPS=1
    SUPER_CLEAN_DRY_RUN=1
    SUPER_CLEAN_INTERACTIVE=1
    removed_log="$TMP_ROOT/cache.removed"
    superclean_emit_app_support_cache_rows() {
      printf "000000000420\t000000001000\t%s\t%s\n" "$TMP_ROOT/home/Library/Application Support/Code" "$TMP_ROOT/home/Library/Application Support/Code/CachedData"
    }
    superclean_interactive_select_app_support_cache_paths() {
      printf "%s\n" "$TMP_ROOT/home/Library/Application Support/Code/CachedData"
    }
    superclean_remove_path() {
      printf "%s\n" "$1" >> "$removed_log"
    }
    superclean_apply_installed_app_support_cache_cleanup >/dev/null
    cat "$removed_log"
  ')"
  assert_eq "$tmp_root/home/Library/Application Support/Code/CachedData" "$apply_output" "interactive dry-run installed app-support cache cleanup applies selected path"
  rm -rf "$tmp_root"

  superclean_reset_state
  superclean_cached_target_dirs() { return 0; }
  superclean_interactive_select_paths() { printf 'FAIL\n' >&2; return 1; }
  superclean_apply_deep_scan
  unset -f superclean_cached_target_dirs
  unset -f superclean_interactive_select_paths
  reload_superclean_functions

  superclean_reset_state
  SUPER_CLEAN_LIVE_SCAN_ACTIVE=1
  SUPER_CLEAN_COLOR_ENABLED=0
  tput() {
    if [[ "$1" == "cols" ]]; then
      printf '60'
    else
      return 1
    fi
  }
  status_output="$(superclean_live_scan_status 3 2 126464 "/Users/jesper/src/shai-hulud-detect/test-cases/edge-case-project/node_modules")"
  if [[ -z "$status_output" ]]; then
    test_fail "live scan status" "Expected output"
  fi
  if [[ "$status_output" != *$'\n'* ]]; then
    test_fail "live scan status" "Expected a two-line update" "Actual: [$status_output]"
  fi
  assert_contains "$status_output" $'\nCurrent: ' "live scan status prints current path on second line"
  unset -f tput
  reload_superclean_functions
}

run_tests "$@"
