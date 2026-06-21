# Skills Index

21 skills — grouped by domain.

> **To update:** edit `group` and `summary` in the skill's `SKILL.md` frontmatter.
> The pre-commit hook regenerates this file automatically on commit.
> To regenerate manually: `bin/gen_skills_readme`

---

## Spec / Build Loop

| Skill | Does |
|-------|------|
| **backprop** | Bug/test failure → §B entry + optional §V invariant to prevent recurrence. Auto-called by build. |
| **build** | Executes §T tasks top-to-bottom, flips status (·→~→x), commits per task. Auto-backprop on failure. |
| **caveman** | Compression codec for spec writes: drops filler, uses symbols (→ ∴ ∀). ~75% token cut. Used by spec/build/check. |
| **check** | Read-only drift detector. Diffs SPEC.md vs code, reports HOLD/VIOLATE/DRIFT/MISSING with file:line. |
| **spec** | Sole mutator of SPEC.md. Modes: NEW/DISTILL/BACKPROP/AMEND. Sections: §G §C §I §V §T §B. |

---

## Shell / Bash

| Skill | Does |
|-------|------|
| **bash-shell-testing** | Colocated *.test.sh structure, bin/test + bin/lint templates, colored [PASS]/[FAIL] output. |
| **fancy-interactive-bash** | Quality Bash pattern: parse_opts/parse_prereqs/run_main, sourceable functions, color UX, testable by function. |

---

## Wiki / Obsidian

| Skill | Does |
|-------|------|
| **cross-linker** | Discovers and inserts missing [[wikilinks]], scores candidates, adds frontmatter relationships. |
| **daily-update** | Wiki maintenance: checks source freshness, updates index.md, regenerates hot.md, writes notification state. |
| **graph-colorize** | Rewrites .obsidian/graph.json colorGroups by tag/category/visibility. Backs up before writing. |
| **memory-bridge** | Browse/compare wiki knowledge by AI source (claude/codex/hermes). Diff mode finds blind spots. |

---

## Memory / Session

| Skill | Does |
|-------|------|
| **memfile** | Creates/updates structured session file: task spec, state, files, workflow, errors, learnings, worklog. |
| **memory-during-chat** | Keeps running in-session memory of constraints and goals. Consulted before each answer. |
| **summarizer** | 9-section conversation summary: request/concepts/files/errors/problem-solving/messages/pending/current/next. |
| **wrap-up** | Session close-out: deferred items, open questions, decisions, next action, next-session opener prompt. |

---

## Writing / Format

| Skill | Does |
|-------|------|
| **gmail-format** | Parses Gmail threads into clean chronological Markdown with frontmatter and deduplicated content. |
| **save-plan-docs** | Turn a suggestion into a plan doc with metadata and a tool-tagged filename. |
| **share-research-as-chat-message** | Rewrites research into forwardable chat message (default Danish): sharp opener, compressed answer, sources. |

---

## Skills Meta

| Skill | Does |
|-------|------|
| **impl-validator** | Second-opinion checker: artifact existence, completeness, correctness. Returns PASS/WARN/FAIL. |
| **skill-creator** | Interview → draft → test with subagents → evaluate → iterate → optimize trigger → package .skill. |

---

## Domain-Specific

| Skill | Does |
|-------|------|
| **pagy-v9-to-v43-migration-expert** | Rails Pagy v9→v43: initializer, framework integration, helper calls, option renames, extras. |

---

*Last updated: 2026-06-21 · 21 skills*
