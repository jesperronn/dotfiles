---
name: bash-shell-testing
description: Use when creating or refactoring Bash test files, repository shell test runners, or shell lint runners. Covers colocated `*.test.sh` structure, direct-execution test files, colored `[PASS]` and `[FAIL]` output, and reusable `bin/test` and `bin/lint` templates.
---

# Bash Shell Testing

Use this skill for the test and validation side of Bash projects.

This skill owns:
- `*.test.sh` layout and conventions
- repository `bin/test` runner patterns
- repository `bin/lint` runner patterns
- test helper shape and assertion output

## Template Files

This skill includes starter templates under `assets/`:
- `assets/script-template.test.sh`
- `assets/bin-test-template`
- `assets/bin-lint-template`

Use them when you want a concrete starting point instead of retyping the structure.

If the task is mainly about interactive CLI structure, sourceable orchestration, or overall Bash UX, also use `fancy-interactive-bash`. Keep the test-specific rules here.

## Scope

Prefer this split:
- `fancy-interactive-bash`: script structure, option parsing, composability, color UX, orchestration
- `bash-shell-testing`: tests, assertions, test runners, lint runners, validation workflow

## Core Rules

- Keep tests next to the script they cover: `foo.sh` beside `foo.test.sh`.
- Make every `*.test.sh` executable.
- Test files must be runnable directly, not only through `bash path/to/test`.
- Keep tests non-interactive by default so `bin/test` never blocks.
- Prefer unit tests that source helpers and stub side effects.
- Keep tests small, readable, and deterministic.
- Cover at least one success path and one failure or edge case for each public command or helper.
- For bug fixes, add a regression test first or alongside the fix.

## Assertion Output

- Print colored `[PASS]` markers at the front of successful assertion lines.
- Print colored `[FAIL]` markers at the front of failed assertion lines.
- Failure output must make `expected` and `actual` easy to compare.
- Keep output readable without color when `NO_COLOR` is set.

## `*.test.sh` Shape

Prefer a small in-repo helper such as `bin/lib/bash_test.sh`.

Rules:
- use `#!/usr/bin/env bash`
- use `set -euo pipefail`
- source shared test helpers
- source the script under test when practical; prefer scripts that gate execution with `[[ "${BASH_SOURCE[0]}" == "$0" ]]`
- end with `run_tests "$@"`
- start from `assets/script-template.test.sh` when creating a new sibling test file

## `bin/test`

`bin/test` should be the standard repository entrypoint for shell tests.

Rules:
- discover all `*.test.sh` files in a stable order
- print one bold colored file header before each file
- keep the heading reproducible so the file can be rerun directly
- execute test files directly rather than with `bash <file>`
- fail clearly when a discovered test file is not executable
- preserve each test file's native output
- exit non-zero if any test file fails
- print an actionable failure summary that lists each failed test file as a direct `bin/test ...` rerun command, similar to RSpec's failed-example rerun hints
- support targeting one or more explicit test files
- support a verbose mode that exposes per-test `RUN` lines when the test helper supports it

- start from `assets/bin-test-template` when creating or replacing a repo `bin/test`

## `bin/lint`

`bin/lint` should be the standard repository entrypoint for shell linting.

Rules:
- support linting the full repository or an explicit file subset
- prefer `bin/lint <file> [<file> ...]` when only a few files changed
- run syntax checks consistently
- run `shellcheck` when available
- fail non-zero on lint errors
- keep output reproducible and easy to rerun
- use the same color system as the rest of the Bash UX
- start from `assets/bin-lint-template` when creating or replacing a repo `bin/lint`

## Validation Workflow

Treat linting and tests as part of the Bash contract.

Default workflow:
- run `bin/lint` for changed shell files
- run `bin/test` before finishing
- if a test seems to hang, check for interactive prompts and login-shell startup side effects first

## Template Ownership

Templates for these belong with this skill:
- sibling `*.test.sh` file templates
- repository `bin/test` templates
- repository `bin/lint` templates
