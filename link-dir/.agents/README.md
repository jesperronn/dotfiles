# Shared Agent Workspace

This directory holds shared templates, reusable prompts, and tool adapters.

Instructions for agents live in `AGENTS.md`, not here - this file is just a
human-facing map of what's in the directory.

## What lives here

- `AGENTS.md`: the short, always-on instruction file for tools that can read
  `~/.agents`. Start there.
- `notes/`: detail docs (gotchas, longer explanations) linked from `AGENTS.md`.
  Not loaded unless the linked situation applies.
- `templates/memory-bank/`: the canonical Memory Bank template to copy into
  each project (see `AGENTS.md` for how/when).
- `prompts/`: reusable prompts for tools that support prompt files.

## Maintenance

- Keep every file here short. Put long/rarely-needed detail in `notes/` and
  link to it - never duplicate the same information in two files.

