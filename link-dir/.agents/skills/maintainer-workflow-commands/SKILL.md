---
name: maintainer-workflow-commands
summary: "Generate lean project workflows for selected languages."
description: Use when adding or auditing project commands for setup, development, tests, lint, dependencies, troubleshooting, or releases, and when making those commands discoverable through bin/workflows.
---

# Maintainer workflow commands

Keep project commands small. Generate only the workflows and languages needed.
Preserve existing names, runners, CI, and project conventions.

## Bootstrap

1. Inspect the project, including nested manifests, lockfiles, existing scripts,
   and CI. Identify languages that need workflows; ignore dependencies, build
   output, and the generated wrappers themselves. See [ecosystems](references/ecosystems.md).
2. Select missing commands and languages. Run this internal tool from the skill
   directory; it writes files but runs no project commands or installs:

   ```bash
   scripts/bootstrap --files=deps,lint,test,setup --lang=js,java,bash --output=/path/to/project
   ```

   Files: `setup,dev,test,lint,deps,workflows,troubleshoot,changelog,release`.
   Languages: `bash,ruby,js,go,java`; `sh` aliases `bash`.
3. Bootstrap refuses overwrites. For an existing workflow, generate into a
   scratch directory and adapt the result. Keep names such as `bin/runtests`;
   update companion scripts to call the project's actual entrypoints.
4. Generated scripts contain only selected language sections, including help,
   flags, routing, and helpers. Commands share argument parsing and step results
   in `bin/lib/project.sh`. Bash is their interpreter regardless of which
   test languages were selected. They have no runtime dependency on this skill.
5. Adapt tool choices and paths. Remove unused steps; replace project-specific
   assumptions. `bin/workflows` indexes executable commands from their
   `# <name> — <description>` headers without executing them.
6. Test the result, run lint then tests, and connect the actual commands to CI
   and AGENTS.md. Do not copy this skill's test harness into the project blindly.

## Contracts

- Language flags select suites: `--java` detects Maven/Gradle and prefers the
  wrapper. Never replace it with `--maven` or `--gradle`. No flag runs detected
  selected languages; paths narrow the run, and flags filter paths.
- `test` Java directories select `*Test.java`, `*Tests.java`, and `*IT.java`
  recursively; empty selections fail. Selectors use simple class names. Adapt
  duplicate names and integration-test tasks to the project.
- `lint` checks by default; `--autofix` applies supported fixes. Java lint and
  fallback JS lint scripts run project-wide. Adapt fallback JS autofix explicitly.
- `setup --check` checks tools. `deps` lists by default; `--patch`, `--minor`,
  or `--major` requests updates. It never commits.
- `setup`, `dev`, `test`, `lint`, `deps`, and `release` support `--dry-run`.
  Batch commands continue after failed steps. Exit: 0 success, 1 failure,
  2 usage, 9 missing tool. Preserve existing project exit conventions.
- `troubleshoot <target> [ARGS...]` is intentionally empty: it prints
  "empty for now". Add checks only when the project needs them; remote targets
  should print commands for the user to run.
- `release` uses hand-written Unreleased notes and `changelog next` for version
  suggestions. Generate both companions when missing, plus lint/test entrypoints.
  Read the [release contract](references/release.md) before adapting or running it.

## Verify the skill

Run `bin/maintainer-workflow-commands.test.sh` from the dotfiles repository.
It tests generation, language exclusion, workflow behavior, and release safety
in scratch projects, using stubs for external commands. Run `bin/gen_skills_readme`
after editing this skill.
