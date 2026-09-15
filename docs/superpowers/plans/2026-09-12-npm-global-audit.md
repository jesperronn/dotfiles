# Global npm Audit Report Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Add `bin/npm-global-audit`, a safe command that reports severity totals for every global npm package in aligned colorized rows.

**Architecture:** npm rejects `npm audit -g` with `EAUDITGLOBAL`. Discover top-level installed packages with `npm --no-audit ls -g --depth=0 --json`. For each installed `name@version`, create a disposable project, resolve a lockfile with `npm --prefix DIR install --package-lock-only --ignore-scripts --no-audit name@version`, run `npm --prefix DIR audit --json`, parse `metadata.vulnerabilities`, and format one row. No global package is changed.

**Tech Stack:** Bash, npm 12+, Node.js, `bin/lib/bash_test.sh`, ShellCheck.

## Global Constraints

- Create only `bin/npm-global-audit` and `bin/npm-global-audit.test.sh`; preserve all existing worktree changes.
- Never use `npm update`, `npm audit fix`, or global npm as a temporary project prefix.
- The command pins the installed top-level version but freshly resolves transitive dependencies. Document that it does not recreate the installed globally hoisted tree.
- Always use `--no-audit` for discovery/temporary resolution and `--ignore-scripts` for temporary resolution.
- Continue after a per-package failure; render an aligned error row and exit 1 after every package has been attempted.
- Color is TTY-only by default; honor `NO_COLOR`, `--color`, and `--no-color`. Plain mode emits no ANSI escapes. Zero is green, low yellow, moderate orange, high/critical red.

---

## File Structure

- `bin/npm-global-audit`: public CLI, global discovery, temporary directories, npm invocation, JSON parsing, output, cleanup, colors, aggregated exit status.
- `bin/npm-global-audit.test.sh`: direct behavioral tests that stub `npm` through `PATH` and use the real `node` for JSON parsing.

### Task 1: Write the failing behavior suite

**Files:**

- Create: `bin/npm-global-audit.test.sh`

**Interfaces:**

- The test’s fake npm returns a fixed global-list response and uses `NPM_STUB_LOG` to record all arguments.
- The new command interface is `npm-global-audit [--color|--no-color] [--help]`.

- [ ] **Step 1: Create the executable test file**

Use this header and source the existing helper:

```bash
#!/usr/bin/env bash
# shellcheck disable=SC1090,SC1091
set -euo pipefail
DOTFILES_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
SCRIPT_UNDER_TEST="$DOTFILES_ROOT/bin/npm-global-audit"
source "$DOTFILES_ROOT/bin/lib/bash_test.sh"
```

Make the test executable. Add `make_stub_npm DIR` to create `DIR/npm`; it appends every invocation to `$NPM_STUB_LOG`. Its global-list response is `{"dependencies":{"jumbo-cli":{"version":"3.23.0"},"svgo":{"version":"4.1.0"},"cline":{"version":"3.0.61"}}}`. Its audit responses have npm’s shape `{"metadata":{"vulnerabilities":{...}}}` and dispatch based on the literal package spec supplied to the preceding install.

- [ ] **Step 2: Specify expected rows with literal fixtures**

The fake npm must return these exact metadata values: `jumbo-cli` total 0; `svgo` total 3, low 2, moderate 1, high 0, critical 0; `cline` total 33, low 8, moderate 16, high 9, critical 0. Write one test that runs `NO_COLOR=1` with the fake npm and asserts status 0 plus every exact visible segment below:

```text
jumbo-cli@3.23.0
0 vulnerabilities
svgo@4.1.0
3 vulnerabilities (2 low, 1 moderate, 0 high)
cline@3.0.61
33 vulnerabilities (8 low, 16 moderate, 9 high)
```

Also assert no `ESC[` ANSI sequence exists in output.

- [ ] **Step 3: Add safety and error tests**

Write separate tests that run the real script with the fake npm and assert:

- The invocation log contains `--no-audit ls -g --depth=0 --json`.
- Every temporary install includes `--package-lock-only`, `--ignore-scripts`, `--no-audit`, and a literal installed spec such as `cline@3.0.61`.
- The log never includes `update -g`, `audit fix`, or `--global audit`.
- A fixture with total 3, high 1, critical 2 emits `3 vulnerabilities (0 low, 0 moderate, 1 high, 2 critical)`.
- A single `svgo` audit failure writes `registry unavailable`; the output still has cline’s normal row, has `svgo@4.1.0` and `audit failed: registry unavailable`, and exits 1.
- An empty dependency object emits `No global npm packages found.` and exits 0.
- `--help` exits 0 and mentions `--color`, `--no-color`, and freshly resolved transitive dependencies.
- `--color` emits an ANSI SGR sequence when stdout is captured.

- [ ] **Step 4: Verify the red state**

Run `bin/test bin/npm-global-audit.test.sh`. It must fail because `bin/npm-global-audit` is absent, not because the fake npm or test helper is malformed.

### Task 2: Implement the report command

**Files:**

- Create: `bin/npm-global-audit`
- Test: `bin/npm-global-audit.test.sh`

**Interfaces:**

- Input: valid JSON from `npm --no-audit ls -g --depth=0 --json` and `npm audit --json`.
- Output: lexical package-name order with aligned `name@version` columns, one row per discovered package.
- Exit: 0 only when every package provides valid vulnerability metadata; 1 after one or more package failures; 2 for invalid command-line options.

- [ ] **Step 1: Add command shell and option handling**

Use `#!/usr/bin/env bash`, `set -euo pipefail`, and state variables `COLOR_MODE=auto`, `COLOR_ENABLED=0`, `WORK_DIR=""`, and `HAD_FAILURE=0`. Parse `--color`, `--no-color`, `-h`, `--help`; unknown options print an error and usage to stderr then exit 2. Enable color only when forced or when stdout is a TTY and `NO_COLOR` is empty. Help must explain the temporary resolution limitation.

Add an exit trap that removes only a `mktemp -d "${TMPDIR:-/tmp}/npm-global-audit.XXXXXX"` directory. Do not allocate it until after options and discovery succeed.

- [ ] **Step 2: Discover package specs and compute alignment width**

Capture `npm --no-audit ls -g --depth=0 --json`. If that command fails or Node cannot parse its JSON, write `npm-global-audit: unable to list global packages` to stderr and exit 1. Feed JSON to `node -e` on stdin; emit tab-separated `name<TAB>version` records from `dependencies`, require nonempty strings, and sort them with `LC_ALL=C sort`. Empty records produce the required no-packages message. Before audits, build literal `name@version` values and calculate the maximum character width.

- [ ] **Step 3: Implement a safe isolated audit loop**

For every record, create a child directory below `WORK_DIR`, invoke temporary resolution exactly as planned, and capture output/status without terminating the loop. An install failure becomes `install failed: <last non-empty output line>`, sets `HAD_FAILURE=1`, and continues. On successful resolution, invoke `npm --prefix "$package_dir" audit --json`. Exit status 1 is acceptable only if stdout parses as JSON with `metadata.vulnerabilities`; otherwise print `audit failed: <last non-empty stderr line>` or `audit failed: invalid npm audit response`, set `HAD_FAILURE=1`, and continue.

- [ ] **Step 4: Normalize JSON and format output**

Use Node to emit tab-separated `total`, `low`, `moderate`, `high`, `critical`, and `info` integers; missing keys become zero, and nonnumeric/negative values reject the response. Do not calculate total from severities or show `info`. Format these contracts exactly: `0 vulnerabilities`; `1 vulnerability (1 low, 0 moderate, 0 high)`; `3 vulnerabilities (2 low, 1 moderate, 0 high)`; and `3 vulnerabilities (0 low, 0 moderate, 1 high, 2 critical)`. Include a parenthesized breakdown for every nonzero total and include critical only if nonzero. Render ordinary and error rows using `printf '%-*s  %s\n' "$width" "$package_spec" "$text"`.

Use a narrow color helper so only the result text is colored. It uses green for zero, yellow for low-only, orange when moderate is highest, and red for any high/critical. Disabled color must retain identical visible text.

- [ ] **Step 5: Make the focused suite green**

Run `bin/test bin/npm-global-audit.test.sh` until it passes. Fix implementation, not literal output expectations.

- [ ] **Step 6: Lint and commit**

Run `bin/lint bin/npm-global-audit bin/npm-global-audit.test.sh`; it must exit 0. Then stage only the two new files and commit with `feat: report npm audits for global packages`.

### Task 3: Verify repository integration and live safety

**Files:**

- Verify: `bin/npm-global-audit`
- Verify: `bin/npm-global-audit.test.sh`

- [ ] **Step 1: Run required project gates**

Run `bin/lint` and `bin/test`. Both must exit 0. Preserve and report any pre-existing unrelated failure rather than modifying unrelated files.

- [ ] **Step 2: Run a non-mutating live smoke test**

Run `NO_COLOR=1 bin/npm-global-audit`. Expect one readable success/error row for each result of global discovery and no `EAUDITGLOBAL` warning. The command may contact the npm registry but must only create then remove its own temporary directory.

- [ ] **Step 3: Check final scope**

Run `git status --short` and `git show --stat --oneline HEAD`. Confirm the feature commit has only the two planned files and pre-existing worktree changes are untouched.

## Plan Self-Review

- Coverage includes discovery, version pinning, temporary audits, severity output, colors, error continuation, help, automated tests, lint, full repository gates, and live smoke testing.
- All commands, expected strings, temporary npm flags, and error behavior are explicit.
- Fake npm assertions match the production npm calls and the public command remains `npm-global-audit` throughout.
