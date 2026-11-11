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
| `workflows [name]` | print-only cheat sheet | yes |
| `setup [--check]` | install what the project needs; idempotent | yes |
| `dev` | start the dev server | yes |
| `test [--group] [PATH]` | tests per ecosystem, narrowed by path | yes |
| `lint [--autofix] [PATH]` | lint/format per ecosystem | yes |
| `deps [--patch\|--minor\|--major]` | list or update dependencies | yes |
| `troubleshoot <target>` | local: run checks; remote: print only | yes |
| `changelog next\|render\|due`, release, deploy | project specific | see below |

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
5. Point AGENTS.md at `bin/workflows`.

A Makefile, `just` or Gradle task project keeps its runner: make the verbs
thin wrappers or index them in `bin/workflows`.

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
- `deps` never commits; `changelog` never tags; release never pushes without a
  prompt. Agents never run deploys, `ssh`, `cap` or `ansible` against remote.
- Never probe a script with `--help` unless you know it parses it: some `bin/setup`
  scripts ignore args and run everything.

## Release and changelog (no template; write when releases use tags)

- Prefer the project's existing tool (goreleaser, git-cliff, release-please,
  semantic-release, JReleaser). Hand-roll only if none exists.
- `changelog next`: next `vX.Y.Z` from conventional commits since the latest tag
  (`v0.0.0` if none); `render`: the section; `due --grace 2h`: quiet period
  left. Exit 0 ok, 3 nothing releasable, 4 not yet due. Read-only.
- Bump: `!:`/`BREAKING CHANGE` major; `feat` minor; `fix`, `perf` patch; the
  rest none. Entry format `- **scope:** description (hash)`.
- Share tag lookup with any `bump_version`: guard its main with
  `[[ "${BASH_SOURCE[0]}" == "$0" ]]` and `source` it.

## Tests

Colocated `bin/*.test.sh` with a shared harness (`test_pass`, `assert_*`).
Hermetic: scratch git repos with explicit `user.name/email`, stubs first on
`PATH`, waits as env vars set to `0`, `--dry-run` instead of real installs. Every
assertion prints `[PASS]`.

## Pitfalls

- macOS BSD `sed`: use `gsed`. Bash 3.2 has no associative arrays and breaks
  `"${arr[@]}"` on empty arrays under `set -u`: use `${arr[@]+"${arr[@]}"}`.
- In a sourced script `$0` is the caller; use `${BASH_SOURCE[0]}`.
- A test copying `bin/` into a scratch project must drop its own `*.test.sh`,
  or `bin/test --bash` runs it recursively.
- Test the "runs nothing" path with builtins only (`printf`, not `cat`).
- `assert_contains` takes the haystack first, then the needle.
