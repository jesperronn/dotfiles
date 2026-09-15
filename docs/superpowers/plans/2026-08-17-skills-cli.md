# Skills CLI Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Add a single `bin/skills` command for listing, inspecting, enabling, and disabling agent skills stored in the dotfiles repository.

**Architecture:** `bin/skills` will be a sourceable Bash CLI following the repository's `parse_opts`, `parse_prereqs`, and `run_main` structure. It will treat `link-dir/.agents/skills` as enabled and `link-dir/.agents/skills-disabled` as disabled, reading skill metadata from each skill's `SKILL.md`. Listing is read-only; enable/disable moves complete skill directories between those locations. README generation is explicitly out of scope.

**Tech Stack:** Bash, ShellCheck, repository `bin/test` and `bin/lint` conventions, temporary directories for isolated tests.

## Global Constraints

- Use the `fancy-interactive-bash` output, option, sourceability, and testing conventions.
- The command must work without color when stdout is not a TTY.
- Skill IDs are directory names and must not allow path traversal or path separators.
- `--verbose` adds full descriptions from `SKILL.md`; default listing remains concise.
- `--help`, `--color`, and `--no-color` are supported.
- Do not modify `bin/gen_skills_readme` or `link-dir/.agents/skills/README.md`.
- Tests must never move or mutate real repository skills.
- Preserve unrelated working-tree changes and stage only files belonging to this feature.

---

### Task 1: Create isolated test infrastructure

**Files:**
- Create: `bin/skills.test.sh`
- Test only: `bin/skills` after Task 2

**Interfaces:**
- Produces temporary enabled and disabled skill roots that later tests can reuse.
- Produces assertion helpers consistent with existing repository shell tests.

- [ ] **Step 1: Inspect existing shell test helpers**

Read nearby `bin/*.test.sh` files and reuse their assertion and temporary-directory conventions rather than introducing a new test framework.

- [ ] **Step 2: Add temporary skill-tree helpers**

Create helpers that build a temporary root containing:

```text
skills/
  alpha/SKILL.md
  multiline/SKILL.md
skills-disabled/
  disabled/SKILL.md
```

Include short `summary` metadata, a multiline `description`, and one malformed/incomplete metadata case.

- [ ] **Step 3: Add a cleanup trap**

Ensure every temporary directory is removed when the test exits, including assertion failures.

- [ ] **Step 4: Run the new test file**

Run:

```bash
bin/test bin/skills.test.sh
```

Expected: the test file is discovered and currently reports failures for the not-yet-created command behavior.

### Task 2: Add the sourceable CLI skeleton and help

**Files:**
- Create: `bin/skills`
- Modify: `bin/skills.test.sh`

**Interfaces:**
- `parse_opts "$@"` parses global options and subcommands.
- `parse_prereqs` detects terminal/color capabilities.
- `run_main "$@"` orchestrates parsing, discovery, and the selected operation.
- `skills_usage` prints global help.

- [ ] **Step 1: Add the executable Bash skeleton**

Use `set -euo pipefail`, repository-root discovery, explicit prefixed global state, and the direct-execution guard:

```bash
if [[ "${BASH_SOURCE[0]}" == "$0" ]]; then
  run_main "$@"
fi
```

- [ ] **Step 2: Define the command contract**

Support:

```text
bin/skills list [--disabled] [--verbose]
bin/skills status [--verbose]
bin/skills enable <skill-id>
bin/skills disable <skill-id>
bin/skills --help
bin/skills <subcommand> --help
```

Also support `--color` and `--no-color` as global or subcommand options where practical.

- [ ] **Step 3: Implement help and unknown-option errors**

Help must exit zero without discovering or mutating skills. Unknown options and subcommands must print an error, show relevant usage, and exit non-zero.

- [ ] **Step 4: Add help tests**

Assert successful global/subcommand help and non-zero unknown-option/subcommand behavior.

- [ ] **Step 5: Run focused tests**

Run:

```bash
bin/test bin/skills.test.sh
```

Expected: help-related tests pass.

### Task 3: Implement centralized color and output helpers

**Files:**
- Modify: `bin/skills`
- Modify: `bin/skills.test.sh`

**Interfaces:**
- `skills_color_print`
- `skills_info`, `skills_success`, `skills_warn`, `skills_error`, `skills_verbose`
- `skills_color_enabled`
- Formatting helpers return readable text with token-level styling.

- [ ] **Step 1: Define the semantic palette**

Use bold/high-contrast styling for IDs, green for enabled/success, dim text for descriptions and verbose context, warm yellow for headings, and red for errors.

- [ ] **Step 2: Implement TTY-aware color selection**

Auto-disable color when stdout is redirected. Let `--color` force color and `--no-color` force plain output. Keep all plain output readable.

- [ ] **Step 3: Implement list-row formatting**

Format enabled rows with `✓`, disabled rows with `-`, and make the skill ID bold without coloring the entire line.

- [ ] **Step 4: Add formatter tests**

Force color on and off in tests. Assert IDs, markers, headings, and descriptions are present; assert plain mode contains no ANSI escape sequences.

- [ ] **Step 5: Run focused tests and ShellCheck**

Run:

```bash
bin/lint bin/skills bin/skills.test.sh
bin/test bin/skills.test.sh
```

Expected: formatter tests pass and ShellCheck reports no errors.

### Task 4: Implement skill discovery and metadata parsing

**Files:**
- Modify: `bin/skills`
- Modify: `bin/skills.test.sh`

**Interfaces:**
- `skills_enabled_root`
- `skills_disabled_root`
- `skills_list_ids ROOT`
- `skills_read_metadata SKILL_DIR`
- `skills_discover LOCATION`

- [ ] **Step 1: Add configurable roots**

Default roots must resolve relative to the repository:

```text
<repo>/link-dir/.agents/skills
<repo>/link-dir/.agents/skills-disabled
```

Keep them overrideable by tests through explicit variables or functions.

- [ ] **Step 2: Discover only immediate skill directories**

Enumerate immediate directories, require `SKILL.md` for a complete record, and sort IDs deterministically. Treat a missing disabled root as empty.

- [ ] **Step 3: Parse display metadata**

Read `summary` for concise output and the complete `description` for verbose output, including multiline YAML block values. If metadata is missing or malformed, use the directory ID and a clear fallback instead of crashing.

- [ ] **Step 4: Add discovery tests**

Cover sorting, missing disabled root, multiline descriptions, missing metadata, and malformed metadata.

- [ ] **Step 5: Run focused tests**

Run:

```bash
bin/test bin/skills.test.sh
```

Expected: discovery and metadata tests pass.

### Task 5: Implement read-only list and status commands

**Files:**
- Modify: `bin/skills`
- Modify: `bin/skills.test.sh`

**Interfaces:**
- `skills_list_enabled`
- `skills_list_disabled`
- `skills_status`
- `skills_print_summary`

- [ ] **Step 1: Implement `list`**

Make `bin/skills list` show enabled skills by default. Add `--disabled` for disabled skills and `--verbose` for full descriptions.

- [ ] **Step 2: Implement `status`**

Show enabled and disabled sections, followed by total/enabled/disabled counts. Keep empty sections readable.

- [ ] **Step 3: Keep read-only commands side-effect free**

Listing and status must not create directories, modify files, or invoke the dotfiles linker.

- [ ] **Step 4: Add exact output tests**

Assert enabled-only output, disabled-only output, both status sections, verbose descriptions, stable ordering, empty lists, and correct counts.

- [ ] **Step 5: Run focused tests**

Run:

```bash
bin/test bin/skills.test.sh
```

Expected: all read-only command tests pass.

### Task 6: Implement safe enable and disable operations

**Files:**
- Modify: `bin/skills`
- Modify: `bin/skills.test.sh`

**Interfaces:**
- `skills_validate_id SKILL_ID`
- `skills_enable SKILL_ID`
- `skills_disable SKILL_ID`
- `skills_move_skill SOURCE DEST`

- [ ] **Step 1: Validate skill IDs**

Accept normal directory names such as `fancy-interactive-bash`. Reject empty values, `/`, `..`, `.`, path separators, and IDs that resolve outside the configured roots.

- [ ] **Step 2: Implement disable**

Require the skill to exist under enabled skills, create `skills-disabled/` if needed, reject an existing destination, and move the complete directory.

- [ ] **Step 3: Implement enable**

Require the skill to exist under disabled skills, reject an existing enabled destination, and move the complete directory back.

- [ ] **Step 4: Implement failure-safe reporting**

On failure, preserve both source and destination state and print a concrete recovery message. Successful operations must identify the skill and resulting state.

- [ ] **Step 5: Add mutation tests**

Cover successful disable/enable symmetry, unknown IDs, collisions, traversal attempts, nested-file preservation, and no-data-loss failure paths.

- [ ] **Step 6: Run focused tests**

Run:

```bash
bin/test bin/skills.test.sh
```

Expected: all mutation tests pass.

### Task 7: Complete repository validation

**Files:**
- Modify: `bin/skills`
- Modify: `bin/skills.test.sh`

- [ ] **Step 1: Run focused lint and tests**

```bash
bin/lint bin/skills bin/skills.test.sh
bin/test bin/skills.test.sh
```

- [ ] **Step 2: Run repository-wide validation**

```bash
bin/lint
bin/test
git diff --check
```

- [ ] **Step 3: Manually verify the public interface**

Run:

```bash
bin/skills --help
bin/skills list
bin/skills list --verbose
bin/skills list --disabled
bin/skills status
bin/skills enable --help
bin/skills disable --help
```

- [ ] **Step 4: Verify redirected output**

Run:

```bash
bin/skills status > /tmp/skills-status.txt
```

Confirm the file is readable and contains no ANSI escape sequences.

- [ ] **Step 5: Review the final diff**

Confirm only `bin/skills`, `bin/skills.test.sh`, and this plan or explicitly related files are included. Confirm that `bin/gen_skills_readme` and `link-dir/.agents/skills/README.md` are unchanged.

