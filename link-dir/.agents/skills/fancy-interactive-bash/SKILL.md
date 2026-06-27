---
name: fancy-interactive-bash
group: shell-bash
summary: "Quality Bash pattern: parse_opts/parse_prereqs/run_main, sourceable functions, color UX, testable by function."
description: Use when creating or refactoring interactive Bash scripts that should be composable, sourceable, color-aware, testable by function, and structured around parse_opts, parse_prereqs, and a sequential run_main orchestration.
---

# Fancy Interactive Bash

Use this skill for Bash utilities where the implementation quality matters more than the domain logic.

The goal is not "write a script that works once". The goal is:
- sourceable for tests
- deterministic in small functions
- pleasant in terminal use
- easy to extend without turning `main` into a blob

## Template Files

Starter templates are in `assets/`: `script-template.sh`, `script-template.test.sh`, `bin-test-template`, `bin-lint-template`.

Copy them as starting points and adapt names immediately to avoid leaking placeholders.

## Default Shape

Prefer this structure:

```bash
#!/usr/bin/env bash
# shellcheck shell=bash

set -euo pipefail

# Global flags and cached state

# Colors

usage() { ... }
log() { ... }
color_print() { ... }
info() { ... }
success() { ... }
warn() { ... }
error() { ... }
verbose() { ... }

parse_opts() { ... }
parse_prereqs() { ... }

# Pure helpers and formatting helpers

# Inventory / planning helpers

# Apply / mutate helpers

run_main() {
  parse_opts "$@" || return $?
  parse_prereqs

  plan_phase_one
  apply_phase_one

  plan_phase_two
  apply_phase_two

  report_summary
}

if [[ "${BASH_SOURCE[0]}" == "$0" ]]; then
  run_main "$@"
fi
```

## Core Rules

- Keep `run_main` as a readable sequence of function calls.
- Do not hide orchestration inside one giant helper.
- Separate planning/reporting from mutation when practical.
- Make most helpers callable independently after `source script`.
- Prefer small functions with single responsibility over local cleverness.
- Keep state in explicit globals with a clear prefix, not anonymous shell variables.
- Run `shellcheck` during development and before considering the script finished.
- If `shellcheck` warnings are intentionally suppressed, keep the suppression narrow and explain why.

## Validation Workflow

Treat testing and linting as script contract, not follow-up chores.

**Script level:**
- Add `*.test.sh` sibling for each script (`bin/foo` → `bin/foo.test.sh`)
- Keep tests small, readable, assertion output clear (expected vs actual)
- Print colored `[PASS]` / `[FAIL]` markers at line start
- Cover option parsing, defaults, `--help`, symmetry, formatters, interactive fallbacks, progress/failure shapes

**Repository level:**
- `bin/test`: discover and run all `*.test.sh` files in stable order; per-file heading before each; fail fast; apply color to headings (cyan/aqua works well)
- `bin/lint`: standard shellcheck entrypoint; per-file headings with same color scheme; fail non-zero on lint errors
- Both should have reproducible per-file lines so failures can be retried directly

Developers run `bin/lint && bin/test` before commit.

## Naming

Normalize the reusable top-level contract to:
- `parse_opts`: parse flags and mode selection
- `parse_prereqs`: detect tools, terminal capabilities, required binaries, and environment constraints
- `run_main`: linear orchestration only

Other helpers should be named by role:
- `*_usage`
- `*_info`, `*_warn`, `*_error`, `*_success`
- `*_format_*`
- `*_plan_*`
- `*_apply_*`
- `*_interactive_select_*`
- `*_progress_*`

## Option Design

Support common flags users will try even before they read help:
- `-h`, `--help`
- `-n`, `--dry-run`
- `--verbose`
- `--trace`
- `--timings`
- `-i`, `--interactive`
- `--color`
- `--no-color`
- `--raw`, `--short` when you have machine-lean or condensed output modes
- `--plain`, `--progressive` when output mode can change materially
- `--all` when multiple groups/checks/actions can be enabled at once
- `--foo` and `--no-foo` pairs for toggles

Rules:
- Positive group flags should allow "only mode" semantics when relevant.
- `--no-x` must work symmetrically with `--x`.
- Unknown options should print a warning, show usage, and exit non-zero.
- `--help` should print usage and exit without running work.
- `--verbose` should expose useful per-step detail without becoming shell trace noise.
- Support `--timings` when runtime cost matters and users need to see where time is going.
- Keep `--trace` separate from `--verbose` so debugging command execution stays opt-in.

## Output and Color

Treat terminal output as part of the interface. Principles apply to Bash, Go, Python, and any CLI tool.

**TTY detection:** Auto-disable color when output is piped/redirected. Detect via `[[ -t 1 ]]` (Bash), `os.Stat` (Go), `sys.stdout.isatty()` (Python). Optionally support `--color`/`--no-color` flags. **All output must remain readable without color.**

**Palette:** Use small, semantic set with consistent meaning across your tool:

| Element | Color | Used For |
|---------|-------|----------|
| Dim | gray | descriptions, prose, non-critical text, debug output |
| Bold | bright | structural markers, emphasis |
| Heading | warm yellow/orange | section labels (`Usage:`, `Flags:`, `Examples:`) |
| Command | green | executable tokens, subcommands |
| Flag | yellow or cyan | option names (pick one, use consistently) |
| Placeholder | magenta/pink | metavariables (`<issue-key>`, `[FILE]`) |
| File heading | cyan/aqua | per-file labels in test/lint output |
| Tool name | purple-ish | primary brand, usage first line (optional) |
| Success | green | completion, `[PASS]` |
| Error | red | failure, `[FAIL]`, error lines |

**Apply to:**
- Help section headings and tool name
- Subcommand tokens separately from placeholders (separate colors so command shape scans fast)
- Option names in help
- `info()`, `success()`, `warn()`, `error()` output
- Test/lint runner headings
- `[PASS]` / `[FAIL]` markers
- **Dim text:** Debug output, verbose trace lines, auxiliary information user can ignore (e.g., when `--verbose` shows step-by-step progress, use dim for "entering step X" context)

**Rules:**
- **One central abstraction.** `color_print` helper in Bash, `color` package in Go — not scattered codes.
- **Token-level, not full-line.** Color individual tokens (command, flag, placeholder) not entire usage line.
- **Consistent across the tool.** Same palette for help, test output, error messages, runner headings.
- **Consistent across languages.** Bash script and Go CLI in same project should feel identical to users.
- **Deviations are intentional.** If you use blue for commands instead of green, document why and keep semantic split (headings ≠ commands ≠ placeholders ≠ prose).

Reference: `bat --help` uses warm headings, purple tool name, green commands, magenta placeholders, default text.

## Performance And Timings

Make slow steps visible without noise.

**Split flags:**
- `--verbose`: what's happening
- `--timings`: where time is going
- `--trace`: exact commands

**Rules:**
- Default output concise
- Time meaningful phases (not every helper): `parse_prereqs`, discovery, planning, selectors, external commands, final report
- In `--verbose`: show timing next to step when it clarifies slowness
- In default mode: keep timings in `--timings` or summary only
- Include elapsed time on failure when diagnostic
- One timing helper, not scattered `date` calls; prefer monotonic timers, fall back cleanly
- Store per-step data for summary; don't couple timing to color/TTY logic

**Pattern:** `run_timed "Step name" step_function` → `Completed in 12.4s`

## Interactivity

Interactive mode should be optional, not structural.

Rules:
- The script must still work non-interactively.
- If `fzf` or a similar tool is available, use it for multi-select review.
- If it is not available, fall back to one-at-a-time confirmation or plain prompts.
- Print a protip when an optional tool would improve UX.

For `fzf`-style selectors:
- visible columns should show meaningful labels, not raw payload fields
- raw paths/ids may remain hidden as the returned value
- support bulk select/deselect bindings
- include short usage hints in the prompt/header
- keep row formatting deterministic so tests can assert it

## Progress UI

For longer work, render progress on the same line when stdout is a TTY.

Rules:
- gate live rendering behind `[[ -t 1 ]]`
- provide explicit start/status/finish helpers
- clear previously rendered status lines before printing final output
- truncate long paths to terminal width
- prefer stable two-line status when current target/path matters

Do not make progress rendering a dependency of correctness. It is presentation only.

## Failure Handling

Always tell the user what to do next when a chained command fails.

Rules:
- print the failing step clearly
- print exit status when available
- if a line number or source line can be inferred, show it
- end with a concrete next step

Typical next-step guidance:
- rerun with `--verbose`
- rerun with `--timings`
- rerun with `--trace`
- rerun a single group with `--foo`
- install optional dependency such as `fzf`
- fix prerequisite access such as `sudo` or missing binary
- run the suggested safer command instead of deleting raw files

Failure output should explain the recovery path, not just the error.

## Composability

Write the script so functions can be tested in isolation.

Preferred patterns:
- direct sourcing via `source script`, guarded with `[[ "${BASH_SOURCE[0]}" == "$0" ]]`
- explicit reset helper in tests for all globals
- helper functions return data via stdout when practical
- orchestration functions call helpers that can be overridden in tests
- avoid hidden subshell-only state unless required

This matters more than "pure shell minimalism". A sourceable script with overridable helpers is easier to verify.

## Testing Method

Test structure and behavior via source and function override.

**Coverage:** Option parsing, defaults/reset, `--help`, flag symmetry, formatters, interactive fallbacks, progress/failure shapes, orchestration, environment branches.

**Method:**
- Source the script; override helpers to isolate units
- Use temp directories, not fixtures
- Assert exact strings (formatted rows, prompts); separate exit code assertions
- Run `shellcheck` as required validation
- Print colored `[PASS]` / `[FAIL]` at line start
- Show expected vs actual clearly on failure
- Use parameterized loops when they add signal, not noise

**Helpers:** `assert_eq`, `assert_status`, `reset_state`

**Test runner UX:** Section headers, colored `[PASS]` / `[FAIL]`, fail fast on structural regressions.

## What To Reuse From The Source Pattern

Extract and reuse these methods:
- centralized color handling, including help/usage output
- a consistent family of `info/success/warn/error/verbose` helpers
- symmetrical option parsing with intuitive defaults
- explicit parsing and prerequisite phases
- sequential `run_main`
- plan/apply separation
- interactive selectors as separate functions
- progress helpers separate from business logic
- failure handlers that include next steps
- a direct-source entry guard for tests using `BASH_SOURCE`
- tests that override helpers to isolate units

## What To Ignore

Ignore the actual business purpose of the script.

Do not copy:
- cleanup-specific paths
- runtime-specific commands
- app-specific heuristics
- domain-specific group names

Copy the engineering pattern, not the business logic.

## Skeleton

```bash
parse_opts() {
  while (($#)); do
    case "$1" in
      -h|--help) usage; return 1 ;;
      -n|--dry-run) FLAG_DRY_RUN=1 ;;
      --verbose) FLAG_VERBOSE=1 ;;
      -i|--interactive) FLAG_INTERACTIVE=1 ;;
      --color) FLAG_COLOR=1 ;;
      --no-color) FLAG_COLOR=0 ;;
      --all) FLAG_ALL=1 ;;
      --thing) enable_only_mode; FLAG_THING=1 ;;
      --no-thing) FLAG_THING=0 ;;
      *) warn "Unknown option: $1"; usage >&2; return 2 ;;
    esac
    shift
  done
}

parse_prereqs() {
  command -v fzf >/dev/null 2>&1 && HAS_FZF=1 || HAS_FZF=0
}

run_main() {
  parse_opts "$@" || return $?
  parse_prereqs
  plan_work
  apply_work
  report_summary
}
```

Use this as the starting contract unless the script is trivial enough that the extra structure would be fake ceremony.
