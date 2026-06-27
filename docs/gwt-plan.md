# gwt — Git Worktree Wrapper

## Purpose

Interactive wrapper around `git worktree` with fzf-based selection.

## Prerequisites

- `git` must be installed
- `fzf` must be installed
- Must be inside (or traversable up to) a git repository

## Core Behavior

When run with no arguments, `gwt` starts in interactive mode:

1. **Prerequisites check** — verify `git` and `fzf` are available; exit with error if not
2. **Find repo root** — use `git rev-parse --show-toplevel` (searches up parent dirs); exit if no repo found
3. **List worktrees** — run `git worktree list` (raw output), parse into a fzf selector
4. **User selects** from the fzf list:
   - **Enter** on an existing worktree → delete it (and prune orphaned metadata)
   - **Ctrl-A** (or similar shortcut) → create a new worktree
5. **Add worktree**:
   - Name: `<repo_name>-wt` (e.g., `myproject-wt`)
   - Path: sibling to repo root (e.g., `../myproject-wt`)
   - If that path exists, try `-wt1`, `-wt2`, etc. until one is free
   - Run the `git worktree add` command (printed in dim for transparency)
   - After creation: 3-second countdown "Navigate to new worktree? [y/N] (3s)"
   - Countdown updates on screen each second (2s, 1s, then exits)
   - Only if user presses `y` within the window: `cd` into the new worktree
6. **Delete worktree**:
   - Run `git worktree remove` on the selected worktree (printed in dim)
   - Run `git worktree prune` to clean orphaned metadata (printed in dim)

## File Structure

```
bin/gwt              # Main script (single file)
bin/gwt.test.sh      # Test file (sibling, follows naming convention)
docs/gwt-plan.md     # This document
```

## Outstanding / Deferred Features

### Phase 2 candidates

- **`gwt list` subcommand** — non-interactive flat list of worktrees (same format as `git worktree list`)
- **`gwt add <path>`** — explicit path instead of auto-generated
- **`gwt remove <worktree>`** — explicit worktree name (non-interactive)
- **`gwt prune`** — standalone prune command
- **`--dry-run` flag** — two states: actually execute vs. only print commands (deferred, need design)
- **`--branch <name>`** — specify branch name explicitly (deferred)
- **`--detach`** — create detached HEAD worktree (deferred)
- **`--cd` flag** — always auto-navigate (deferred, current behavior is countdown-based)
- **Sub/partial worktree behavior** — work on a subset of files (deferred)

### Design decisions deferred

- Keyboard shortcut for "add" — currently Ctrl-A as fzf binding
- Whether `--dry-run` is a flag or a separate mode
- Auto-navigate default (current: countdown prompt)

## Implementation Notes

- Use `fzf` for the interactive worktree selector
- FZF height: computed as `min(30% of terminal height, 20 lines)` — caps the selector so it never takes over the whole screen
- Parse `git worktree list` raw output to extract paths, branches, HEAD refs
- Print all commands in dim color so user sees what's happening and can learn
- The 3-second countdown uses terminal escape codes to update in-place
- Single file: `bin/gwt`
- Test file: `bin/gwt.test.sh` following project conventions
