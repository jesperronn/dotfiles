# TASKS.md — Documentation Tasks

Each task is **isolated, self-contained, and pick-up-able** by a small agent working alone.
Tasks are grouped by priority. Dependencies are explicit — follow the order when tasks interact.

---

## Task 1 — Critical: Add usage/help to bin scripts with flags but no documentation

**Priority:** 🔴 Highest — these are user-facing tools with CLI options but no way to discover them.

**Scope:** 11 scripts in `bin/` that accept flags/options but have no `--help`, no usage text, and no purpose comments.

**Status:** 🟡 Ready to start — no dependencies on other tasks.

**Dependencies:** None. Can be done in parallel with Task 2.

**Output format (per script):**

```bash
#!/usr/bin/env bash
# <ONE-LINE PURPOSE>
#
# Usage:
#   <script> [options] [args...]
#
# Options:
#   --help, -h    Show this help and exit.
#   <flag>        <description>.  (default: <value>)
#
# Dependencies:
#   <external tools required>
#
# Notes:
#   <gotchas, context, links>
```

**Scripts to document (11 total):**

| # | File | What it does (from reading) | Key flags to document |
|---|---|---|---|
| 1.1 | `bin/dotfiles` | Main bootstrap: clones repo, copies/link-symlinks files, runs init scripts. Modes: `full`, `targeted`. | `source`, `restart`, `--copy`, `--link`, `--init` |
| 1.2 | `bin/superclean` | Aggressive disk cleanup: finds junk apps, caches, logs, old gems. | `--dry-run`, `--verbose`, `--interactive`, `--aggressive` |
| 1.3 | `bin/podman_troubleshoot` | Diagnoses and fixes Podman VM: starts/stops, checks health, fixes socket mounts, resolves clock drift. | `--fix`, `--force`, `--verbose`, `--image`, `--log-health`, `--log-emergency` |
| 1.4 | `bin/gwt` | Interactive git wrapper: colorized branch/worktree picker with fzf. | (interactive — document the workflow) |
| 1.5 | `bin/local_agent` | Runs AI agent with Ollama/LM Studio adapters. Validates ollama, checks models, runs test loop. | Env vars: `LOCAL_AGENT_VERIFY_OLLAMA_BIN`, `LOCAL_AGENT_DEFAULT_PRESET`, `LOCAL_AGENT_DEFAULT_CODEX_SANDBOX`, etc. |
| 1.6 | `bin/looper` | Repeatedly runs a command with colored output, stoppable with Ctrl+C. | `--count`, `--verbose` |
| 1.7 | `bin/returner` | Captures exit code and message from a command, re-plays them. | (stdin/stdout capture) |
| 1.8 | `bin/rehome_doctor` | Scans `~/` for files/folders not managed by the dotfiles repo. | `--all` (include junk), `--interactive` |
| 1.9 | `bin/coverup` | Finds JaCoCo XML files, reports instruction/branch coverage. | `--root`, `--sort`, `--verbose`, `--help` |
| 1.10 | `bin/jqlog` | Formats JSON log files via jq (level, sequence, message, timestamp). | (file or stdin) |
| 1.11 | `bin/git-gpg-wrapper` | Git GPG signing wrapper with cache keygrip lookup. Bypasses cache for non-signing commands. | (transparent wrapper — document when it activates) |

**Acceptance criteria (per script):**
- [ ] Header comment with one-line purpose
- [ ] Usage section with example invocation(s)
- [ ] All flags/options documented with defaults
- [ ] Dependencies listed (external tools, env vars)
- [ ] `--help` flag works and shows the documented usage
- [ ] No existing functionality changed

---

## Task 2 — Medium: Add purpose comments to bin scripts with zero comments

**Priority:** 🟡 Medium — these scripts are called by other tools or by the bootstrap process.

**Scope:** 5 scripts in `bin/` that have **zero comments** of any kind.

**Status:** 🟡 Ready to start — **depends on Task 1 being completed** because some of these scripts are called by scripts in Task 1.

**Dependencies:** Depends on **Task 1** completing first, specifically:
- `bin/local-model-testrun-loop.sh` calls `bin/verify_ollama` and `bin/verify_ollama_models` (both documented in Task 1)
- `bin/local-model-testrun-loop.sh` references `sandbox/codex-edit-loop` fixture repo

**Scripts to document (5 total):**

| # | File | What it does (from reading) | What to add |
|---|---|---|---|
| 2.1 | `bin/local-model-testrun-loop.sh` | Runs an AI agent in a sandbox git repo, captures JSONL logs, enforces deterministic edits. | Usage, model name param, timeout param, description of the prompt and expected changes |
| 2.2 | `bin/podman-troubleshoot` (if exists separately from 1.3) | (check if duplicate) | Same as 1.3 |
| 2.3 | `bin/podman-troubleshoot.test.sh` | (test file — skip) | N/A |
| 2.4 | `bin/podman-troubleshoot` (duplicate?) | (check file existence) | (same as 1.3) |
| 2.5 | `bin/podman-troubleshoot` (duplicate?) | (check file existence) | (same as 1.3) |

**Note:** `bin/podman-troubleshoot` appears in the audit — verify whether it's the same file as `bin/podman_troubleshoot` (underscore vs hyphen). If it's a duplicate, document it identically to Task 1.3 and note the naming inconsistency.

**Acceptance criteria (per script):**
- [ ] Header comment with one-line purpose
- [ ] Usage section with example invocation(s)
- [ ] Parameters/variables documented
- [ ] No existing functionality changed

---

## Task 3 — Low: Add purpose comments to source/ files

**Priority:** 🟢 Low — these are configuration fragments sourced at shell startup.

**Scope:** 7 source files with **no or minimal comments**.

**Status:** 🟢 Ready to start — **no dependencies on Task 1 or 2** (these are independent config files).

**Dependencies:** None. Can be done in parallel with Task 1 and Task 2.

**Scripts to document (7 total):**

| # | File | What it does | What to add |
|---|---|---|---|
| 3.1 | `source/00_dotfiles.sh` | Sources the main `bin/dotfiles` script in "source" mode (defines functions, doesn't run). | One-line purpose: "Bootstraps dotfiles functions for shell use." |
| 3.2 | `source/01_path.sh` | Constructs PATH from Homebrew, local bin, npm-global, pnpm, dotfiles bin, IntelliJ, standard paths. | Describe the PATH ordering strategy (why Homebrew first, why these specific paths). |
| 3.3 | `source/01_prompt.sh` | Saves/restores default PS1-PS4, defines `prompt_default()` and `prompt_git()`. | Describe the prompt system: default vs git-aware prompts, how to restore. |
| 3.4 | `source/60_podman.sh` | Finds the default/current Podman machine name from `podman machine list`. | Describe the function's purpose: machine name resolution for scripts. |
| 3.5 | `source/60_ruby.sh` | RVM environment resolution: walks directory tree for `.ruby-version` and `.ruby-gemset`. | Describe the rvm_env_path function and .ruby-version/.ruby-gemset detection. |
| 3.6 | `source/70_karnov.sh` | Loads Jin tool, commented-out kubectl/CDK aliases for karnov stack. | Describe the Jin integration and comment out the dead aliases. |
| 3.7 | `source/90_stil_alias.sh` | Sets STIL_HOME, Keycloak path, Stil support tools path. | Describe the Stil/Keycloak environment setup. |

**Acceptance criteria (per file):**
- [ ] Header comment with one-line purpose
- [ ] Any non-obvious behavior explained
- [ ] Dead/commented code flagged as such (e.g., karnov aliases in 3.6)
- [ ] No existing functionality changed

---

## Task 4 — Optional: Standardize documentation format across all bin scripts

**Priority:** 🟢 Optional — cleanup/enhancement pass.

**Scope:** All 38 non-test scripts in `bin/` that now have documentation (after Tasks 1-3).

**Status:** 🟢 Can start after Tasks 1, 2, 3 are complete.

**Dependencies:** Depends on **Tasks 1, 2, 3** being complete.

**Goal:** Ensure consistent documentation structure across all scripts:
- All scripts follow the same header format (purpose, usage, options, dependencies, notes)
- No script has a bare `--help` that shows different info than the header comment
- All env var overrides are documented in the header
- Cross-references between scripts (e.g., `local_agent` → `verify_ollama`) are noted

**This is a review pass, not a write pass.** Only modify scripts that were already updated in Tasks 1-3.

---

## Summary Table

| Task | Scripts Affected | Priority | Dependencies | Est. Effort |
|---|---|---|---|---|
| **Task 1** | 11 bin scripts | 🔴 Critical | None | 2-3 hours |
| **Task 2** | 5 bin scripts | 🟡 Medium | Task 1 | 1-2 hours |
| **Task 3** | 7 source files | 🟢 Low | None | 1 hour |
| **Task 4** | All 38 bin scripts | 🟢 Optional | Tasks 1, 2, 3 | 1-2 hours |

**Total: 23 scripts + 7 source files need documentation.**

---

## How to Use This File

1. **Pick a task** that matches your available time and interest area.
2. **Read the scripts** listed in the task's table before starting.
3. **Follow the acceptance criteria** — each script must pass its checklist.
4. **Check dependencies** — don't start Task 2 before Task 1, don't start Task 4 before 1+2+3.
5. **Update this file** when a task is complete (change "Ready" to "Done" and note any issues).
