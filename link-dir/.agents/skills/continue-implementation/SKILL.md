---
name: continue-implementation
group: skills-meta
summary: "Continues and orchestrates an existing implementation plan to completion."
description: Use when the user runs /continue-implementation, or asks to continue and orchestrate an existing implementation plan.
---

# Continue & Orchestrate an Implementation Plan

Fired by the `/continue-implementation` slash command, or when the user asks to continue and orchestrate an existing implementation plan. Goal: pick up an existing plan and drive it to completion without stalling.

## State at start
1. Read the plan/spec: `SPEC.md`, the active todo list, or the referenced phase/steps. Re-read; never trust memory.
2. `git status` for uncommitted changes.
3. Materialize the full work surface as ordered `todo` phases; flatten every phase, checklist, and file list into concrete items. Expand "most/important" — that phrasing is a failure, enumerate everything.

## Orchestration loop (advance within one turn)
1. **Plan** — enumerate the entire remaining surface; expand phases/checklists/file lists into flat items.
2. **Dispatch** — fan out to parallel `task` subagents in one message; each self-contained, ≤3–5 explicit target paths (no globs), clear acceptance criteria. Never one-off serial subagents.
3. **Verify** — run gates (`bun check` types, package `bun test`, `lsp diagnostics`) across the union of changed files. Red tree → dispatch fix-up subagents, re-verify, never advance.
4. **Commit** — focused phase-naming commit only if the repo workflow expects it; never commit a red tree.
5. **Advance** — mark phase done in `todo`; immediately start the next. No inter-phase summary.

## Defer, don't stop
When you need user input, do NOT wait or stall:
- Record it as a `[blocked]`/deferred todo item with the exact question.
- Continue all reachable work around it.
- Pick up the deferred input at the next checkpoint / when it arrives.
This is the core behavior the user's prompt asks for.

## Guardrails
- No scope creep (add nothing unrequested) and no scope shrink (never relabel unfinished work "MVP/follow-up" as done).
- Subagents never verify/lint/format; the orchestrator verifies once across all changed files.
- Closure is the only stop condition: every requested item verifiably done, or a concrete `[blocked]` that genuinely needs the user.
