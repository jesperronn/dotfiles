# Agent Instructions (Always-On)

Detail lives in `~/.agents/notes/` — open a linked note only when it applies.

## Git & commits

- Conventional commits: `type(scope): subject`.
- Do not add `Co-authored-by:` trailers.
- Never record test/verification results in commit messages (no "Verified: …", "tests pass", example counts). The message says what changed and why.
- `git diff`/`log`/`show` → always `git --no-pager …` or `GIT_PAGER= git …` to avoid hanging output → `~/.agents/notes/git-pager.md`

## Verification

- Never say "fixed", "all passing", "verified" or "done" without having just run the relevant command and shown its actual output (or a specific excerpt). This applies to subtasks and subagents: require the command output, not a prose claim of success.
- If a fetch, build or test run fails, say so; never cite something you did not actually read or run successfully.
- After finishing a unit of work, check `git status` and commit; do not leave the tree dirty without saying so.

## Linting

- Every project should have `bin/lint` (or equivalent): accepts any number of file/dir paths, supports `--autofix`, lints the whole project with no args. Add a minimal one if missing.
- After editing files, run it on the touched paths before calling the change done.

## Tooling

- macOS: use `gsed` instead of BSD `sed` when `which gsed` succeeds (BSD sed breaks on `\n` in replacements with `-i`).

## Memory Bank

- Per-project memory lives in `./memory-bank/` (per-project, never global). Read `activeContext.md` + `progress.md` at task start and update them at milestones. Template: `~/.agents/templates/memory-bank/`; details: `~/.agents/notes/memory-bank.md`.

## Gotchas

- Background jobs started in one tool call die before the next → `~/.agents/notes/terminal-background-jobs.md`

