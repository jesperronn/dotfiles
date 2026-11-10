---
name: concise-docs
summary: "Tightens README/markdown docs and CLI --help text without losing detail: one source per fact, audit table, drift tests, task-first structure."
description: Use when the user asks to shorten or tighten a README, docs, or --help output without losing detail, or when a repo duplicates the same facts across README, docs/ and CLI help.
---

# Concise docs

Shorten docs by giving every fact exactly one home, not by deleting facts.
If the docs are already single-sourced and task-first, say so and stop.

## Procedure (in order)

1. **Survey first.** Record line counts of the docs in scope. Find what the
   project already has: reference sources (help output, config schema,
   generated API docs), where rationale lives, the test setup, and any doc
   conventions. Follow those instead of inventing new files or systems. If
   an existing convention contradicts a step below (e.g. a mandated README
   layout, or facts deliberately repeated), stop, tell the user what
   conflicts, and ask which wins before editing.
2. **Pick one home per kind of fact.** Prefer the source closest to the code,
   ideally generated or tested (for a CLI: `--help` for flags, env vars and
   exit codes). Prose docs link to it rather than repeat it. Rationale goes in
   the project's existing design/architecture doc, not the README.
3. **Audit table.** Map every fact you remove to its single new home. No row,
   no deletion. Keep the table in the PR description or scratch, not in the
   repo.
4. **Move, link, and lead with the task.** Default README order: what it is,
   install, set up, first run, use, update, troubleshoot, license. Skip
   sections that do not apply.
5. **Cut by rule.**
   - One example per feature.
   - Tables only for reference data that is looked up, not read.
   - Delete sentences that restate what the code, the help output or a
     diagnostics command already shows.
   - CHANGELOG records changes only, no narrative.
   - Maintainer docs / AGENTS.md keep only what cannot be found by running
     the project or reading its help.
6. **Drift test.** Where a machine-readable source and a test suite exist,
   add a test that fails when the docs and that source diverge (for a CLI:
   every flag/env var in help appears in the README or a page it links to,
   and every flag the README mentions exists in help). If that is not
   feasible, say so explicitly instead of skipping silently.
7. **Check links.** Moved or renamed sections break anchors; fix every
   inbound link within the repo.

## For CLI projects

- Top-level help fits one screen. Move long paragraphs to whatever longer
  form the project already has (help topics, man page, docs) instead of
  adding a new mechanism.
- Do not change help output the task did not ask to change. If the project
  has golden/snapshot tests for help, they pass or every diff is intentional.

## Checklist before done

- [ ] Audit table covers every removed fact, each with one home.
- [ ] Drift test exists and passes, or its absence is stated with the reason.
- [ ] No broken links or anchors in the repo.
- [ ] Line counts before/after reported for each doc touched.
