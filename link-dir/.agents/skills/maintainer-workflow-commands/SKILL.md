---
name: maintainer-workflow-commands
group: shell-bash
summary: "Recipe for maintainer bin/ commands (workflows cheat sheet, troubleshoot, deps, changelog) with safety rules, exit codes and hermetic tests."
description: Use when adding or auditing maintainer workflow commands in a project (bin/workflows, bin/troubleshoot, bin/deps, bin/changelog), or when asked to make setup, deps, release, deploy and troubleshoot discoverable and safe for humans and agents.
---

# Maintainer workflow commands

Generalized from plus-reporter, cancerventetid and bbapprove. Examples use
their script names; adapt to the project.
Full command/flag/exit-code catalogue: [workflows.md](workflows.md).

## 1. Survey, index, fill gaps

Workflow set: setup, develop, deps, release (preview + bump), deploy (local
rehearsal vs real), troubleshoot (local vs remote).

1. List what `bin/`, `Makefile`, CI and docs already provide. Reuse it.
2. Index existing commands in `bin/workflows`; write new scripts only for gaps.
3. If a concept does not exist (no staging, no rehearsal target, no
   changelog file), say so in the sheet. Never invent stages or targets.

## 2. `bin/workflows [name]`

- Print-only cheat sheet: no side effects, one `== name ==` section per
  workflow, no argument prints all, unknown name exits 64 (usage), `--help` 0.
- Docs: a pointer in AGENTS.md plus one short `doc(s)/workflows.md`; the
  sheet is the command index, the doc holds only the why and links.
- Test: each section header present, unknown name exits 64.

## 3. `bin/troubleshoot <target>`

- Local/rehearsal targets (`deploymock`, `compose`): run the checks (status,
  doctor, host check), continue past failures, exit non-zero if any failed.
- Any other target (staging, production, remote host): run NOTHING; print the
  commands for the user to run and paste back. Hard safety rule.
- Missing target: usage, exit 64.
- Test the rule by running with `PATH=/nonexistent:/usr/bin:/bin`: output must
  still be the hints, proving nothing was executed.

## 4. `bin/deps`

- No flag: read-only list of outdated packages. `--patch|--minor|--major`
  (mutually exclusive) update up to that level. `--ruby|--js` scope (default
  both). Named packages need exactly one scope flag. `--dry-run`, `--verbose`.
- Never commits. Prints next steps (`bin/test && bin/lint`) and a suggested
  commit message.
- Outdated listers exit 1 when something is outdated: not a failure.
- Ecosystems differ: bundler uses `bundle outdated --only-explicit`;
  yarn has its own upgrade flow; npm needs `npx npm-check-updates --target
  <level> -u` then `npm install` (rewrites ranges, so it changes pins).
- Ruby/runtime versions are a separate command (`bin/bump_ruby`), not `deps`.
- Include project-specific drift checks (vendored Bootstrap) in the listing.

## 5. `bin/changelog next|render|due`

Read-only preview of "what would this release be" (inspired by bbapprove's
Go tool).

- `next`: next vX.Y.Z from conventional commits since the latest tag
  (`v0.0.0` if none). `render`: the changelog section. `due`: time left of
  the quiet period since HEAD (`--grace 2h`, `--now EPOCH` for tests).
- Exit: 0 ok/releasable/due, 1 error, 2 usage, 3 nothing releasable, 4 not
  yet due. Never tags, fetches or writes.

| Commit | Bump | Section |
| --- | --- | --- |
| `!:` / `BREAKING CHANGE` | major | Changed (BREAKING), first |
| `feat` | minor | Added |
| `fix` | patch | Fixed |
| `perf` | patch | Changed |
| `revert` | none alone | Changed |
| docs/test/chore/refactor/ci/build/style | none | omitted |

- Omit an `update` subcommand when the changelog lives in tag messages (or the
  file is stale); say why in the docs. bbapprove has `update` because it keeps
  CHANGELOG.md.
- Share tag lookup and version math with `bin/bump_version`: guard its main
  with `if [[ "${BASH_SOURCE[0]}" == "$0" ]]`, then `source` it. Do not
  duplicate. After sourcing, undo its `pushd`/`cd` and its color setup.
- Deliberate difference: `bump_version` suggests a patch when nothing is
  releasable; `changelog next` exits 3. Document it in the release doc.

## 6. Shared conventions

- Exit codes: 0 ok, 1 error, 2 usage (or 64 if the project already uses
  it; pick one per project and keep it). `--help` on every command.
- Plain output when not a TTY or `NO_COLOR` is set; one shared color lib
  (`bin/lib/common_output.sh`).
- Tests: colocated `bin/<name>.test.sh` with the shared harness
  (`bin/lib/bash_test.sh`, PASS/FAIL), wired into the project runner
  (`bin/test-sh`, `bin/test --sh`, CI). Hermetic: scratch git repos with
  explicit `user.name/email`; PATH stubs for ssh/scp/curl/bundle/npm; never
  real servers or the repo's own tags. Fixed commit dates and `--now` for
  time logic.
- Lint: shellcheck + shfmt through `bin/lint`.
- Docs: short, one home per fact (see concise-docs). Help text is the
  reference for flags; docs link to it.

## 7. Applying to a new project

1. Survey (section 1); note missing concepts.
2. Write `bin/workflows` + test; add the AGENTS.md pointer and a short doc.
3. Add `bin/troubleshoot` + test if there is any deploy target.
4. Add `bin/deps` + test with PATH stubs; add the `--dry-run` path first.
5. Add `bin/changelog` once releases use conventional commits and tags.
6. Wire tests into the runner and CI; run lint and the full suite.
7. Update `bin/workflows` so every new command is indexed.

## Pitfalls

- macOS: BSD `sed` breaks GNU syntax; use `gsed` when available.
- In a sourced script `$0` is the caller; use `${BASH_SOURCE[0]}` for paths and
  the main guard.
- `assert_contains` takes the haystack first, then the needle.
- Tests that `source` another script need `# shellcheck disable=SC1091` (or
  `source=` directive).
- `bump_version`-style tools default to a patch bump when nothing is
  releasable; guard with `changelog next` (exit 3).
- Sourcing a script that `set -e`s or `pushd`s changes the caller's shell;
  restore it.
