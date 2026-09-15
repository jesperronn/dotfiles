# bbpr Review Workflow Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Update `bbpr` so reviewer-focused workflows default to structured Markdown, 1Password token fetches show dim waiting text, `review --short` points to the next command to run, and `show -i/--interactive` provides an `fzf`-based PR picker with live previews.

**Architecture:** Keep `bbpr` as a single Bash entrypoint and extend the existing subcommand handlers with small, local helper functions rather than introducing new files. Preserve the current JSON contracts and API call flow, but change the default human output path for `review` and add an explicit interactive branch for `show`. Drive the work from shell tests in `bin/bbpr_test.sh`, using the existing `bin/lib/bash_test.sh` harness and mocked `op`, `curl`, and `fzf` binaries.

**Tech Stack:** Bash, `jq`, `curl`, `fzf`, 1Password CLI (`op`), custom shell test harness in `bin/lib/bash_test.sh`.

## Global Constraints

- Do not modify unrelated working-tree changes in `dotfiles`.
- Do not split `bin/bbpr` into multiple production files for this change; follow the repo's existing single-script pattern.
- `review` must default to structured reviewer Markdown when `--json` is not set.
- `op item get ...` token retrieval paths must emit dim-gray waiting text before the external call runs.
- `review --short` must still emit slash-form PR identifiers and must append a concrete next-step hint.
- `show -i` and `show --interactive` must require `fzf`; when `fzf` is missing, fail with a clear install hint.
- Interactive preview mode must show PR details by reusing local `bbpr` logic, not by duplicating a separate preview renderer.
- Existing `--json` behavior for `review`, `show`, and `comments` must remain unchanged.

## File Map

- Modify: `bin/bbpr:42-85` — usage text for new default review behavior and `show --interactive`.
- Modify: `bin/bbpr:87-100` — add a dim-status printer for waiting text without changing existing error/info semantics.
- Modify: `bin/bbpr:102-135` — option parsing for `show -i|--interactive` and any supporting state flags.
- Modify: `bin/bbpr:147-161` — token lookup flow so `op`-backed retrieval announces the wait state.
- Modify: `bin/bbpr:392-400` — retain long PR formatter for non-review flows while separating review-specific human output.
- Modify: `bin/bbpr:442-484` — replace current table output with structured reviewer Markdown and short-mode hinting.
- Modify: `bin/bbpr:525-631` — add interactive picker entrypoint and reusable show rendering for previews.
- Modify: `bin/bbpr:708-740` — dispatch `show` interactive mode correctly while keeping argument validation coherent.
- Modify: `bin/bbpr_test.sh:13-45` — extend the test fixture setup with optional `fzf` mock behavior and log capture.
- Modify: `bin/bbpr_test.sh:47-121` — add regression tests for Markdown review output, waiting text, short hinting, and interactive preview behavior.

## Implementation Tasks

### Task 1: Lock the new CLI contract in tests

**Files:**
- Modify: `bin/bbpr_test.sh:13-45`
- Modify: `bin/bbpr_test.sh:47-121`
- Test: `bin/bbpr_test.sh`

**Interfaces:**
- Consumes: `capture_command`, `assert_contains`, `assert_not_contains`, `assert_status`, `assert_eq` from `bin/lib/bash_test.sh`
- Produces: `test_review_default_emits_structured_markdown`, `test_review_short_adds_next_step_hint`, `test_fetch_token_prints_waiting_message_for_op`, `test_show_interactive_requires_fzf`, `test_show_interactive_uses_fzf_preview`

- [ ] **Step 1: Write the failing review-markdown and hint tests**

```bash
test_review_default_emits_structured_markdown() {
  local output="" status=0

  capture_command output status "$BBPR_BIN" review
  assert_status "0" "$status" "review exits successfully"
  assert_contains "$output" "## Review Queue" "review prints a Markdown heading"
  assert_contains "$output" "- [ ] PROJ/repo/42" "review prints checkbox-style PR entries"
  assert_contains "$output" "Author: Test Author" "review includes reviewer context"
  assert_not_contains "$output" "https://stash.example.test/projects/PROJ/repos/repo/pull-requests/42 TA Test PR" "review no longer defaults to long flat lines"
}

test_review_short_adds_next_step_hint() {
  local output="" status=0

  capture_command output status "$BBPR_BIN" review --short
  assert_status "0" "$status" "review --short exits successfully"
  assert_contains "$output" "PROJ/repo/42" "review --short still emits a show identifier"
  assert_contains "$output" "next: bbpr show PROJ/repo/42" "review --short adds the next-step hint"
}
```

- [ ] **Step 2: Run the new tests to verify they fail**

Run: `bin/bbpr_test.sh test_review_default_emits_structured_markdown test_review_short_adds_next_step_hint`
Expected: FAIL because `bbpr_cmd_review` still emits the old long-line/table output and no next-step hint.

- [ ] **Step 3: Write the failing token-wait and interactive tests**

```bash
test_fetch_token_prints_waiting_message_for_op() {
  local output="" status=0

  : >"$BBPR_OP_MARKER"
  capture_command output status "$BBPR_BIN" review --short
  assert_status "0" "$status" "review --short succeeds with mocked op"
  assert_contains "$output" "Waiting for 1Password" "op-backed token lookup reports waiting text"
  assert_eq "mock-op" "$(cat "$BBPR_OP_MARKER")" "review still invokes the op mock"
}

test_show_interactive_requires_fzf() {
  local output="" status=0

  rm -f "$TEST_TMP_DIR/bin/fzf"
  capture_command output status "$BBPR_BIN" show --interactive
  assert_status "1" "$status" "show --interactive fails without fzf"
  assert_contains "$output" "fzf is not installed or not on PATH" "interactive mode explains the missing dependency"
}

test_show_interactive_uses_fzf_preview() {
  local output="" status=0

  cat >"$TEST_TMP_DIR/bin/fzf" <<'EOF'
#!/usr/bin/env bash
printf '%s\n' "$*" >"${BBPR_FZF_ARGS_LOG:?}"
cat >"${BBPR_FZF_INPUT_LOG:?}"
printf 'PROJ/repo/42\n'
EOF
  chmod +x "$TEST_TMP_DIR/bin/fzf"

  export BBPR_FZF_ARGS_LOG="$TEST_TMP_DIR/fzf.args"
  export BBPR_FZF_INPUT_LOG="$TEST_TMP_DIR/fzf.input"

  capture_command output status "$BBPR_BIN" show --interactive
  assert_status "0" "$status" "show --interactive succeeds with mocked fzf"
  assert_contains "$(cat "$BBPR_FZF_ARGS_LOG")" "--preview" "interactive mode configures fzf preview"
  assert_contains "$(cat "$BBPR_FZF_ARGS_LOG")" "bbpr show" "interactive preview reuses the show subcommand"
  assert_contains "$(cat "$BBPR_FZF_INPUT_LOG")" "PROJ/repo/42" "interactive mode offers review PR identifiers to fzf"
  assert_contains "$output" "PR #42: Test PR" "interactive selection prints the chosen PR details"
}
```

- [ ] **Step 4: Run the new tests to verify they fail**

Run: `bin/bbpr_test.sh test_fetch_token_prints_waiting_message_for_op test_show_interactive_requires_fzf test_show_interactive_uses_fzf_preview`
Expected: FAIL because token lookup is silent and `show` does not accept `--interactive`.

- [ ] **Step 5: Commit the test-only contract**

```bash
git add bin/bbpr_test.sh
git commit -m "test: lock bbpr review workflow contract"
```

### Task 2: Add output helpers and the waiting-text token path

**Files:**
- Modify: `bin/bbpr:87-100`
- Modify: `bin/bbpr:147-161`
- Modify: `bin/bbpr:42-85`
- Test: `bin/bbpr_test.sh`

**Interfaces:**
- Consumes: `BBPR_C_DIM`, `BBPR_C_RESET`, `BBPR_COLOR_ENABLED`, existing `bbpr_color_print`
- Produces: `bbpr_dim()`, `bbpr_fetch_token()`, updated usage copy mentioning `show -i, --interactive`

- [ ] **Step 1: Implement the smallest helper set for dim waiting text**

```bash
bbpr_dim() {
  bbpr_color_print "$BBPR_C_DIM" "$*"
}

bbpr_fetch_token() {
  if [[ -n "$BBPR_TOKEN" ]]; then
    printf '%s' "$BBPR_TOKEN"
    return 0
  fi

  local token=""
  if command -v op >/dev/null 2>&1; then
    bbpr_dim "Waiting for 1Password: op item get BITBUCKET_TOKEN_JRJ"
    token="$(op item get "BITBUCKET_TOKEN_JRJ" --fields label=token --reveal 2>/dev/null)" || token=""
  fi

  if [[ -z "$token" ]]; then
    bbpr_error "No token available. Set --token or install 'op' (1Password CLI)."
    return 1
  fi

  printf '%s' "$token"
}
```

- [ ] **Step 2: Update help text for the new interaction contract**

```bash
printf '  %sshow%s %sPROJ/REPO/NNN%s  Show full PR details.\n' "$command_style" "$placeholder_style" "$reset_style" "$reset_style"
printf '  %sshow%s %s-i, --interactive%s  Pick a PR with fzf and preview details.\n' "$command_style" "$reset_style" "$flag_style" "$reset_style"
printf '  %sreview%s            Show reviewer Markdown by default.\n' "$command_style" "$reset_style"
```

- [ ] **Step 3: Run the focused tests and make them pass**

Run: `bin/bbpr_test.sh test_help_lists_output_modes test_fetch_token_prints_waiting_message_for_op`
Expected: PASS, confirming the wait message appears and help documents the new mode without breaking existing help assertions.

- [ ] **Step 4: Run syntax and full `bbpr` tests**

Run: `bash -n bin/bbpr && bin/bbpr_test.sh`
Expected: PASS.

- [ ] **Step 5: Commit the helper and token-flow changes**

```bash
git add bin/bbpr bin/bbpr_test.sh
git commit -m "feat: show bbpr token wait status"
```

### Task 3: Replace default `review` output with structured reviewer Markdown

**Files:**
- Modify: `bin/bbpr:442-484`
- Modify: `bin/bbpr:392-400`
- Modify: `bin/bbpr_test.sh`
- Test: `bin/bbpr_test.sh`

**Interfaces:**
- Consumes: `bbpr_cmd_list_prs "REVIEWER"`, `BBPR_SHORT`, `BBPR_LONG`, `BBPR_JSON`, `BBPR_BASE_URL`
- Produces: `bbpr_render_review_markdown()`, `bbpr_render_review_short_hint()`, unchanged `bbpr_print_long_prs()` for `mine`/`open`

- [ ] **Step 1: Add a dedicated review Markdown renderer**

```bash
bbpr_render_review_markdown() {
  local prs="$1"

  printf '%s' "$prs" | jq -r '
    if length == 0 then
      "## Review Queue\n\n_No pending review assignments._"
    else
      [
        "## Review Queue",
        "",
        (.[] | [
          "- [ ] \(.fromRef.repository.project.key)/\(.fromRef.repository.slug)/\(.id)",
          "  Title: \(.title // "Untitled PR")",
          "  Author: \(.author.user.displayName // .author.user.slug // "?")",
          "  URL: \(.links.self[0].href)",
          "  Status: " + (
            if (.participants | any(.role == "REVIEWER" and .status == "APPROVED")) then "APPROVED"
            elif (.participants | any(.role == "REVIEWER" and .status == "NEEDS_WORK")) then "NEEDS WORK"
            else "UNAPPROVED"
            end
          )
        ] | join("\n"))
      ] | join("\n")
    end
  '
}
```

- [ ] **Step 2: Keep short mode machine-friendly and append one actionable hint**

```bash
if (( BBPR_SHORT )); then
  local short_ids first_id
  short_ids="$(printf '%s' "$prs" | jq -r '.[] | "\(.fromRef.repository.project.key)/\(.fromRef.repository.slug)/\(.id)"')"
  printf '%s\n' "$short_ids"
  first_id="$(printf '%s\n' "$short_ids" | sed -n '1p')"
  if [[ -n "$first_id" ]]; then
    printf '\nnext: bbpr show %s\n' "$first_id"
  fi
  return 0
fi
```

- [ ] **Step 3: Route default human review output through the Markdown renderer**

```bash
if (( BBPR_JSON )); then
  # keep existing JSON block
  :
else
  bbpr_render_review_markdown "$prs"
fi
```

- [ ] **Step 4: Run the focused review tests**

Run: `bin/bbpr_test.sh test_review_default_emits_structured_markdown test_review_short_adds_next_step_hint test_review_short_and_long_output`
Expected: PASS, with `review` using Markdown by default and `review --long` retaining the clickable flat format for explicit long mode.

- [ ] **Step 5: Run full regression and commit**

Run: `bash -n bin/bbpr && bin/bbpr_test.sh`
Expected: PASS.

```bash
git add bin/bbpr bin/bbpr_test.sh
git commit -m "feat: make bbpr review output reviewer-first"
```

### Task 4: Add `show -i|--interactive` with `fzf` previews

**Files:**
- Modify: `bin/bbpr:102-135`
- Modify: `bin/bbpr:525-631`
- Modify: `bin/bbpr:708-740`
- Modify: `bin/bbpr_test.sh`
- Test: `bin/bbpr_test.sh`

**Interfaces:**
- Consumes: `bbpr_cmd_list_prs "REVIEWER"`, `bbpr_parse_pr_id`, `bbpr_cmd_show`, `BBPR_ARGS`
- Produces: `BBPR_INTERACTIVE`, `bbpr_require_fzf()`, `bbpr_select_review_pr_interactively()`, interactive `show` dispatch

- [ ] **Step 1: Extend option parsing for interactive show mode**

```bash
BBPR_INTERACTIVE=0

parse_opts() {
  local temp_args=()
  while [[ $# -gt 0 ]]; do
    case "$1" in
      -i|--interactive) BBPR_INTERACTIVE=1; shift ;;
      # existing cases...
      *) temp_args+=("$1"); shift ;;
    esac
  done
  # existing subcommand assignment...
}
```

- [ ] **Step 2: Add the smallest possible `fzf` dependency check and selector**

```bash
bbpr_require_fzf() {
  if ! command -v fzf >/dev/null 2>&1; then
    bbpr_error "fzf is not installed or not on PATH."
    bbpr_error "Install it with: brew install fzf"
    return 1
  fi
}

bbpr_select_review_pr_interactively() {
  bbpr_require_fzf || return 1

  local prs selector_input selected
  prs="$(bbpr_cmd_list_prs "REVIEWER")" || return 1
  selector_input="$(printf '%s' "$prs" | jq -r '.[] | "\(.fromRef.repository.project.key)/\(.fromRef.repository.slug)/\(.id)\t\(.title // "Untitled PR")\t\(.author.user.displayName // .author.user.slug // "?")"')"
  selected="$(printf '%s\n' "$selector_input" | fzf --delimiter=$'\t' --with-nth=1,2,3 --prompt='bbpr show > ' --preview='bin/bbpr show {1}' | cut -f1)" || return 1
  printf '%s' "$selected"
}
```

- [ ] **Step 3: Dispatch interactive `show` before positional-argument validation**

```bash
show)
  if (( BBPR_INTERACTIVE )); then
    local selected_spec=""
    selected_spec="$(bbpr_select_review_pr_interactively)" || return 1
    [[ -n "$selected_spec" ]] || return 0
    bbpr_cmd_show "$selected_spec"
    main_status=$?
  else
    [[ ${#BBPR_ARGS[@]} -ge 1 ]] || { bbpr_error "Usage: bbpr show PROJ/REPO/NNN"; return 1; }
    bbpr_cmd_show "${BBPR_ARGS[0]}"
    main_status=$?
  fi
  ;;
```

- [ ] **Step 4: Run the interactive tests**

Run: `bin/bbpr_test.sh test_show_interactive_requires_fzf test_show_interactive_uses_fzf_preview test_show_accepts_bitbucket_urls`
Expected: PASS, confirming missing-`fzf` messaging, preview wiring, and no regression for direct `show`.

- [ ] **Step 5: Run full verification and commit**

Run: `bash -n bin/bbpr && bin/bbpr_test.sh && git diff --check`
Expected: PASS.

```bash
git add bin/bbpr bin/bbpr_test.sh
git commit -m "feat: add interactive bbpr show picker"
```

### Task 5: Final polish and whole-command verification

**Files:**
- Modify: `bin/bbpr`
- Modify: `bin/bbpr_test.sh`
- Test: `bin/bbpr_test.sh`

**Interfaces:**
- Consumes: all prior task outputs
- Produces: final verified reviewer workflow with stable CLI help and no JSON regressions

- [ ] **Step 1: Add one regression test for explicit `review --long`**

```bash
test_review_long_preserves_clickable_lines() {
  local output="" status=0

  capture_command output status "$BBPR_BIN" review --long
  assert_status "0" "$status" "review --long exits successfully"
  assert_contains "$output" "https://stash.example.test/projects/PROJ/repos/repo/pull-requests/42" "review --long keeps clickable URLs"
  assert_contains "$output" "TA Test PR" "review --long keeps author initials and title"
  assert_not_contains "$output" "## Review Queue" "review --long bypasses Markdown mode"
}
```

- [ ] **Step 2: Run the targeted long-mode and JSON regression checks**

Run: `bin/bbpr_test.sh test_review_long_preserves_clickable_lines test_list_commands_use_dashboard_api test_comments_accepts_normalized_url`
Expected: PASS.

- [ ] **Step 3: Run full verification**

Run: `bash -n bin/bbpr`
Expected: PASS.

Run: `bin/bbpr_test.sh`
Expected: PASS.

Run: `git diff --check`
Expected: PASS.

- [ ] **Step 4: Do one manual smoke check with color-capable output**

Run: `BBPR_TOKEN=test-token PATH="$TEST_TMP_DIR/bin:$PATH" script -q /dev/null bin/bbpr review`
Expected: the waiting line and Markdown output render cleanly in a TTY, with the waiting line dimmed when colors are enabled.

- [ ] **Step 5: Commit the final polish**

```bash
git add bin/bbpr bin/bbpr_test.sh
git commit -m "test: cover bbpr review long-mode regression"
```

## Self-Review

**Spec coverage:**
- Structured reviewer Markdown by default: Task 1 and Task 3.
- Dim-gray waiting text for `op item` commands: Task 1 and Task 2.
- `review --short` next-step hint: Task 1 and Task 3.
- `show -i|--interactive` requiring `fzf` and previewing PR details: Task 1 and Task 4.
- Preserve current JSON and non-review behavior: Task 3, Task 4, and Task 5.

No gaps found against the approved design summary.

**Placeholder scan:** Completed. No `TODO`, `TBD`, or undefined follow-up references remain in tasks.

**Type consistency:** The plan consistently uses `BBPR_INTERACTIVE`, `bbpr_dim()`, `bbpr_render_review_markdown()`, `bbpr_require_fzf()`, and `bbpr_select_review_pr_interactively()` as the planned interfaces.

## Execution Handoff

Plan complete and saved to `docs/superpowers/plans/2026-08-17-bbpr-review-workflow.md`. Two execution options:

**1. Subagent-Driven (recommended)** - Dispatch a fresh subagent per task, review between tasks, fast iteration.

**2. Inline Execution** - Execute tasks in one session using `executing-plans`, batch execution with checkpoints.

Which approach?
