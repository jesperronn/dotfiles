---
name: concise-docs
summary: "Tightens README/markdown docs and CLI --help text without losing detail: one source per fact, drift tests, task-first structure."
description: Use when the user asks to shorten or tighten a README, docs, or --help output without losing detail, or when a repo duplicates the same facts across README, docs/ and CLI help.
---

# Concise docs

Shorten docs by giving every fact exactly one home, not by deleting facts.

## When to use

- User asks to shorten/tighten README, docs, or `--help` without losing detail.
- The same flags, env vars, or steps appear in README, `docs/`, and help.

## Procedure (in order)

1. **One source per fact.** `--help` is the reference for flags, env vars and
   exit codes; the README links to it. Build an audit table mapping every
   removed fact to its single new home. No row, no deletion.
2. **Drift test.** Add a hermetic test that fails when README and help diverge:
   every flag/env var in help appears in the README or a topic it links to,
   and every flag mentioned in the README exists in help.
3. **Lead with the task.** README order: what it is, install, set up, first
   run, use, update, troubleshoot, license. Rationale belongs only in
   `docs/architecture.md`.
4. **One-screen help.** Top-level help is at most ~35 lines. Move long
   paragraphs to `help <topic>` pages that use the same markup and golden-test
   system as the rest of the help.
5. **Cut by rule.**
   - Tables only for env vars and exit codes.
   - One example per feature.
   - Delete sentences that restate what the code or a diagnostics command
     already shows.
   - CHANGELOG records changes only, no narrative.
6. **Thin maintainer docs / AGENTS.md.** Keep only what cannot be found by
   running the project's help script.

## Process rules

- Delegate edits to cheaper subagents, but verify yourself with pasted command
  output: line counts before/after, tests, lint.
- Conventional commits, split into `feat(help)`, `test`, and `docs` commits.
  Any refactor goes in its own branch/PR first.
- Never lose a fact without recording where it moved.
- Plain (non-markup) output stays byte-identical unless the change is
  intentional; golden tests prove it.

## Checklist before done

- [ ] Audit table covers every removed fact, each with one home.
- [ ] Drift test exists and passes; golden tests pass or diffs are intentional.
- [ ] Line counts before/after recorded (README, help, maintainer docs).
- [ ] Top-level help fits one screen (~35 lines).
- [ ] README follows the task-first order; rationale only in architecture doc.
- [ ] Lint and tests run, output pasted.
- [ ] Commits split and conventional; `git status` checked.
