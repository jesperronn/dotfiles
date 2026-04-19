---
name: fancy-interactive-bash
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

This skill includes starter templates under `assets/`:
- `assets/script-template.sh`
- `assets/script-template.test.sh`
- `assets/bin-test-template`
- `assets/bin-lint-template`

Use them when you want a concrete starting point instead of retyping the structure.

Guidance:
- copy `assets/script-template.sh` when creating a new interactive Bash entrypoint
- copy `assets/script-template.test.sh` and rename it to the sibling `*.test.sh`
- copy `assets/bin-test-template` to repository `bin/test`
- copy `assets/bin-lint-template` to repository `bin/lint`
- adapt names and prefixes immediately so the template does not leak placeholder identifiers

## Default Shape

Prefer this structure:

```bash
#!/usr/bin/env bash
# shellcheck shell=bash

set -euo pipefail

if [[ "${1-}" == "source" ]]; then
  MY_SCRIPT_SOURCE_ONLY=1
  shift || true
else
  MY_SCRIPT_SOURCE_ONLY=0
fi

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

if (( ! MY_SCRIPT_SOURCE_ONLY )); then
  run_main "$@"
fi
```

## Core Rules

- Keep `run_main` as a readable sequence of function calls.
- Do not hide orchestration inside one giant helper.
- Separate planning/reporting from mutation when practical.
- Make most helpers callable independently after `source script source`.
- Prefer small functions with single responsibility over local cleverness.
- Keep state in explicit globals with a clear prefix, not anonymous shell variables.
- Run `shellcheck` during development and before considering the script finished.
- If `shellcheck` warnings are intentionally suppressed, keep the suppression narrow and explain why.

## Validation Workflow

Treat testing and linting as part of the script contract, not follow-up chores.

Rules:
- For Bash work, the standard validation entrypoints are `bin/lint` and `bin/test`.
- When adding a Bash script such as `bin/foo`, also add a small sibling test file such as `bin/foo.test.sh`.
- Keep the test file small, direct, and readable.
- Prefer parameterized tests when the same assertion pattern is repeated across multiple inputs or environments.
- Failure output must make `expected` and `actual` easy to compare.
- Print colored `[PASS]` markers at the front of each successful test line.
- Print colored `[FAIL]` markers at the front of each failed test line.
- Tests should cover the supported environments or environment branches the script claims to handle.
- Add a repository-level `bin/test` wrapper that finds `*.test.sh` files and executes them.
- Add a repository-level `bin/lint` wrapper that runs the lint pass consistently across the repository.

For `bin/test`:
- discover all `*.test.sh` files in the repository
- execute them in a stable order
- print each test file on its own line before execution, for example `running ==> bin/script-a.test.sh`
- stop on failure or report a final non-zero exit status
- keep output readable enough that one failing test is obvious immediately
- make the per-file runner line reproducible so failures can be retried directly against the named file
- apply the same color principles to the per-file heading as the rest of the Bash UX
- aqua/cyan file headings are a strong default when they improve readability

For `bin/lint`:
- make it the standard entrypoint for linting Bash files
- run `shellcheck` across the relevant shell scripts in the repository
- keep invocation consistent so developers do not hand-roll lint commands each time
- fail non-zero on any lint error
- print a reproducible per-file heading before linting each file
- apply the same color principles as `bin/test`; aqua/cyan file headings work well here too

The method is:
- local script test file for focused verification
- `bin/test` for repository-wide test execution
- `bin/lint` for repository-wide shell linting
- developers should normally run both `bin/lint` and `bin/test` before considering the work done

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

Treat terminal output as part of the interface.

Use a small palette with named variables:
- dim
- bold
- red
- green
- warm yellow/orange for help section headings
- magenta/pink for metavariables and placeholders
- aqua/cyan for per-file runner headings
- one purple-ish accent color for the tool name and branded info lines
- reset

Apply color to:
- usage headings
- the top-level tool name in usage/help, using a purple-ish accent when it is the primary brand color
- subcommand names separately from parameter placeholders so the command shape is easier to scan
- parameter placeholders in a distinct accent from subcommands, for example magenta placeholders next to cyan subcommands
- option names in help
- info/warn/error/success lines
- `bin/test` and `bin/lint` per-file runner headings
- test results such as `[PASS]` and `[FAIL]`

Rules:
- All output must still work with `--no-color`.
- Keep a single `color_print` helper and build all styled output on top of it.
- Help output should be readable both with and without color.
- Prefer token-level help styling over coloring an entire usage line one color.
- A strong default for `--help`, borrowing from the `bat --help` theme, is: warm yellow/orange section headings, a purple-ish tool name, green command tokens and flags, magenta/pink placeholders, and default terminal color for prose.
- Per-file runner headings should use the same palette rather than inventing a separate style system.
- If the usage block has subcommands, color the command token separately from the placeholder token.
- Prefer a heredoc usage block when it makes token-level help styling easier to read.

Reference pattern:
- `pgit` should follow the same semantic split as `bat --help`: warm section labels, purple tool name, green command tokens, and magenta placeholders.
- Follow that split rather than coloring the entire usage line uniformly.

## Performance And Timings

Interactive shell tools should make slow steps visible without making normal usage noisy.

Preferred split:
- `--verbose`: what the script is doing
- `--timings`: where the time is going
- `--trace`: what exact shell commands executed

Rules:
- Default output should stay concise.
- Timings should be cheap to capture and easy to disable.
- Time meaningful phases such as `parse_prereqs`, discovery, planning, selectors, external commands, and final reporting.
- Prefer timing phase boundaries and external commands over every trivial helper.
- In verbose mode, include timing next to the step that just completed when that clarifies slowness.
- In non-verbose mode, keep timing output behind `--timings` or the final summary.
- If a step fails, include elapsed time when it helps diagnose the failure.

Implementation guidance:
- Use one timing helper instead of ad hoc `date` calls throughout the file.
- Prefer monotonic or high-resolution timers when available, but fall back cleanly.
- Store per-step timing data so the script can emit a useful summary at the end.
- Do not couple timing collection to colored output or TTY-only rendering.

Useful patterns:
- `run_timed "Discovering candidates" discover_candidates`
- `run_command_timed "Running cleanup hook" my_hook`
- `Completed in 12.4s`

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
- source-only mode via `script source`
- explicit reset helper in tests for all globals
- helper functions return data via stdout when practical
- orchestration functions call helpers that can be overridden in tests
- avoid hidden subshell-only state unless required

This matters more than "pure shell minimalism". A sourceable script with overridable helpers is easier to verify.

## Testing Method

Test the structure, not just the behavior.

Cover at least:
- option parsing
- default flags and reset state
- `--help`, unknown options, and on/off flag symmetry
- formatting helpers
- selector row formatting
- interactive fallback behavior
- progress rendering shape
- failure rendering shape
- orchestration ordering when feasible
- environment-specific branches the script claims to support

Preferred test style:
- source the script
- redefine specific helper functions inside the test to isolate units
- use temporary directories instead of fixture-heavy permanent state
- assert exact strings for formatted rows and prompts
- assert exit codes separately from stdout/stderr text
- run `shellcheck` as a required validation step in addition to tests
- print `[PASS]` in color at the start of each passing test line
- print `[FAIL]` in color at the start of each failing test line
- make failure output show expected and actual values clearly
- use parameterized test loops when they reduce repetition without hiding intent

Use explicit helpers such as:
- `assert_eq`
- `assert_status`
- `reset_state`

For the test runner UX:
- print section headers
- show colored `[PASS]` / `[FAIL]` markers
- fail fast on structural regressions

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
- a source-only entry mode for tests
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
