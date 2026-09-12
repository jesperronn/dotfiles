# AGENTS.md — dotfiles

## Commits

- Conventional commits: `type(scope): subject` — prefer `feat:`, `fix:`, `chore:`, `docs:`, `test:`, `refactor:` prefixes.
- One logical change per commit; only stage files you actually changed.

## Verify before done

- Run `bin/lint` (ShellCheck over `bin/`) and `bin/test` (runs all `bin/**/*.test.sh`)
  before declaring work complete. Single file: `bin/test bin/<name>.test.sh`.
- If a script has a colocated `bin/<name>.test.sh`, always run it after touching
  the script or its test.
- New or changed scripts require a colocated `bin/<name>.test.sh` unless the user
  explicitly says not to write tests. Test helper: `bin/lib/bash_test.sh`
  (see an existing `*.test.sh` for the pattern; source the script under test).

## Layout

- `bin/` — executable tools and their `*.test.sh`; shared helpers in `bin/lib/`.
- `link-file/` — files symlinked into `$HOME` (dotfiles).
- `link-dir/` — directories symlinked into `$HOME` (e.g. `.agents/`).
- `source/`, `init/` — shell snippets sourced at startup / one-time setup scripts.
