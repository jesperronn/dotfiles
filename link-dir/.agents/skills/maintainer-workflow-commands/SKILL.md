---
name: maintainer-workflow-commands
group: shell-bash
summary: "Copy-in bin/ command templates (setup, dev, test, lint, deps, workflows, troubleshoot) for bash, Ruby/Rails, JS, Go and Java projects, with safety rules, exit codes and hermetic tests."
description: Use when adding or auditing maintainer commands in any project (bin/setup, bin/dev, bin/test, bin/lint, bin/deps, bin/workflows, bin/troubleshoot, release/changelog), or when asked to make setup, test, lint, deps, release, deploy and troubleshoot discoverable and safe for humans and agents.
---

# Maintainer workflow commands

One verb per task, same name in every project. Humans and agents run
`bin/workflows`, then the verb. Templates are in [templates/bin](templates/bin);
per-ecosystem commands in [ecosystems.md](ecosystems.md); how three real repos
did it in [examples.md](examples.md).

## Verbs

| Verb | Does | Template |
| --- | --- | --- |
| `workflows [name]` | print-only index: every `bin/` script (scraped from its `# name — text` line) plus per-workflow cheat sheets | yes |
| `setup [--check]` | install what the project needs; idempotent | yes |
| `dev` | start the dev server | yes |
| `test [--group] [PATH]` | tests per ecosystem, narrowed by path | yes |
| `lint [--autofix] [PATH]` | lint/format per ecosystem | yes |
| `deps [--patch\|--minor\|--major]` | list or update dependencies | yes |
| `troubleshoot <target>` | local: run checks; remote: print only | yes |
| `changelog next\|render\|update\|due` | release preview from conventional commits; `update` writes `CHANGELOG.md` | yes |
| release, deploy | project specific | see below |

## Adopt in a project

1. Survey `bin/`, `Makefile`, CI, docs. Reuse what exists; index it in
   `bin/workflows`. Where a concept does not exist (staging, release), write
   "none". Never invent stages.
2. Copy `templates/bin/*` and `lib/project.sh`, `chmod +x`. Keep only the
   ecosystems the project uses; detection is by `Gemfile`, `package.json`,
   `go.mod`, `pom.xml`/`build.gradle*`, `*.sh`.
3. Project-specific steps go in `bin/setup.d/NN-name` (executable), checks in
   `bin/doctor`; edit the `PROJECT` lines in `workflows` and `troubleshoot`.
4. Wire `bin/test` and `bin/lint` into CI. Add `bin/commands.test.sh` (needs a
   `bin/lib/bash_test.sh` harness; `BASH_TEST_LIB` overrides the path).
5. Give every `bin/` script a `# <name> — <one line>` comment near the top;
   `bin/workflows commands` scrapes it, so the index cannot go stale.
6. Shape AGENTS.md (see below) and point it at `bin/workflows`.

A Makefile, `just` or Gradle task project keeps its runner: make the verbs
thin wrappers or index them in `bin/workflows`.

## AGENTS.md shape

Same sections in every project, each short (apply `concise-docs`: one home
per fact, only what cannot be found by running the project):

1. One line: what the project is.
2. **Definition of done**: `bin/workflows` lists the commands; run `bin/lint`
   then `bin/test`, and show the output before saying "done".
3. **Conventions**: commits, staging, tests colocated as `bin/*.test.sh`
   (or the project's one test dir), `gsed` on macOS.
4. **Hard rules**: what must never be committed, pushed or run.
5. **Docs**: links to the one home of each kind of fact.

Release, deploy and agent-specific workflows go in `docs/`, linked from here.

## Template behaviour

- `--dry-run` (or `DRY_RUN=1`) prints `+ command` lines and runs nothing; use it
  to preview and to test.
- Groups: `--bash --ruby --js --go --java`. None selected = all detected.
- PATH args (test, lint) route to the right group by name; a file never goes
  to a linter of another language.
- Every group runs even if one fails; summary lines `ok|FAIL|MISSING|skip`.
- Exit: 0 ok, 1 failed, 9 tool missing, 2 usage (`EX_USAGE` in `lib/project.sh`;
  use 64 if the project already does). `--help` exits 0 everywhere.
- Plain output when not a TTY or `NO_COLOR` is set.

## Safety rules

- Remote targets (staging, production, any host): run NOTHING, print the
  commands for the user. Test with `PATH=/nonexistent bash bin/troubleshoot prod`.
- `deps` never commits and prints a commit message that lists the commands it ran
  (counts, not per-package versions); `changelog` never tags; release never pushes without a
  prompt. Agents never run deploys, `ssh`, `cap` or `ansible` against remote.
- Never probe a script with `--help` unless you know it parses it: some `bin/setup`
  scripts ignore args and run everything.

## Release and deploy (no template)

- `bin/changelog next|render|due` preview only; `update` is the one writer (inserts
  `## [X.Y.Z] - DATE` into `CHANGELOG.md`, `--replace-unreleased`, refuses a
  duplicate). `update` is not part of a release script: bbapprove's `release`
  moves the hand-written `[Unreleased]` notes and only calls `next`. Keep
  one changelog source per project (hand-written or generated). Exit 0 ok, 3 nothing releasable, 4 not yet
  due. Bump: `!:`/`BREAKING CHANGE` major; `feat` minor; `fix`, `perf` patch;
  the rest none. It reads tags, so tag with `vX.Y.Z`.
- If the project already has release tooling (goreleaser, git-cliff,
  release-please, semantic-release, JReleaser), wrap it instead of using
  `bin/changelog`. Drop `update` when the changelog lives in tag messages.
- A release script tags locally and pushes only after a prompt. Share tag
  lookup with any `bump_version`: guard its main with
  `[[ "${BASH_SOURCE[0]}" == "$0" ]]` and `source` it.
- Deploy: keep a local rehearsal target separate from real stages; real ones are
  run by the user. Describe them in `bin/workflows`.

## Tests

Colocated `bin/*.test.sh` with a shared harness (`test_pass`, `assert_*`).
Hermetic: scratch git repos with explicit `user.name/email`, stubs first on
`PATH`, waits as env vars set to `0`, `--dry-run` instead of real installs. Every
assertion prints `[PASS]`.

## Audit checklist

For each project check: `bin/workflows` exists and `AGENTS.md` links it; CI
runs `bin/lint` and `bin/test`; `lint --autofix` exists; `setup --check`
exists when tools beyond the language toolchain are needed; changelog and
release are scripted or explicitly "none"; no handoff or report files in the
repo root; `docs/README.md` indexes more than a few docs. `dev` and
`troubleshoot` apply to servers and remote hosts only, so skip them for CLIs.

## Pitfalls

- macOS BSD `sed`: use `gsed`. Bash 3.2 has no associative arrays and breaks
  `"${arr[@]}"` on empty arrays under `set -u`: use `${arr[@]+"${arr[@]}"}`.
- In a sourced script `$0` is the caller; use `${BASH_SOURCE[0]}`.
- A test copying `bin/` into a scratch project must drop its own `*.test.sh`,
  or `bin/test --bash` runs it recursively.
- Test the "runs nothing" path with builtins only (`printf`, not `cat`).
- `assert_contains` takes the haystack first, then the needle.
