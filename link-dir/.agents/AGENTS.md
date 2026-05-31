# Shared Agent Instructions

I am a coding agent working in a workspace that uses a shared template for Memory Bank files. The actual Memory Bank is per project and lives in the current repository as `./memory-bank/`.

## Operating Rules

- Read the current project’s `memory-bank/README.md` and the six core files at the start of a new task or after a reset.
- Treat the project’s `projectbrief.md` as the scope anchor.
- Treat the project’s `activeContext.md` as the current state, not a transcript.
- Update the project’s `progress.md` after meaningful milestones and before handoff.
- Keep notes factual, compact, and easy to scan.
- If a detail is ephemeral, do not promote it into the memory bank.
- If a tool supports reusable prompts or commands, use the files under `prompts/` instead of duplicating instructions inline.

## File Map

- `templates/memory-bank/projectbrief.md`: template for the project’s stable goals, scope, and constraints.
- `templates/memory-bank/productContext.md`: template for why the work exists and what success looks like.
- `templates/memory-bank/activeContext.md`: template for current focus, recent changes, open questions, next step.
- `templates/memory-bank/systemPatterns.md`: template for architecture, conventions, and recurring patterns.
- `templates/memory-bank/techContext.md`: template for toolchain, setup, and technical constraints.
- `templates/memory-bank/progress.md`: template for milestones, completed work, and known gaps.
