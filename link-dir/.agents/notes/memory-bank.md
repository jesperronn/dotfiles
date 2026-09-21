# Memory Bank

Per-project memory to track context across sessions.

## Setup

- Memory lives in `./memory-bank/` in each project root (not global, per-project only).
- If missing and the task is non-trivial, copy `~/.agents/templates/memory-bank/` into the project as `./memory-bank/`.

## Usage

- Read `activeContext.md` + `progress.md` at task start or after a context reset.
- Update at milestones, not by restating the whole chat each time.
- Keep individual files small; link out to separate docs for long detail.

## Files

The template includes:

- `activeContext.md` — current working context (what are we doing right now?)
- `progress.md` — milestone checklist of what's been done
- `projectbrief.md` — project goals & constraints (rarely changes)
- `techContext.md` — architecture & tech decisions
- `productContext.md` — product/domain context
- `systemPatterns.md` — patterns & conventions in this codebase
