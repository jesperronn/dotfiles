# Shared Agent Workspace

This directory holds shared templates, reusable prompts, and tool adapters.

Important: the actual Memory Bank is per project, not global. Each repo should keep its own `memory-bank/` folder in the project root. Use the template files here to initialize that per-project folder.

## What lives here

- `AGENTS.md`: the short, always-on instruction file for tools that can read `~/.agents`.
- `templates/memory-bank/`: the canonical Memory Bank template to copy into each project.
- `prompts/`: reusable prompts for tools that support prompt files.

## How to use it

- Read `AGENTS.md` first.
- Copy `templates/memory-bank/` into the current project as `./memory-bank/` when starting a new repo.
- Read the per-project memory-bank files when starting a new task or after a context reset.
- Update `activeContext.md` and `progress.md` inside the project, not in `~/.agents`.
- Keep files small; move long detail into separate docs and link to them.
- Prefer the prompt files in `prompts/` when a tool supports reusable prompts.
