# AGENTS.md — dotfiles

## Commits

- Conventional: `type(scope): subject` (`feat:`, `fix:`, `chore:`, `docs:`, `test:`, `refactor:`).
- One logical change per commit; only stage files changed.

## Before done

- Run `bin/lint` and `bin/test` (or single test: `bin/test bin/<name>.test.sh`).
- New/changed scripts need colocated `bin/<name>.test.sh` unless user says skip.
- Use `bin/lib/bash_test.sh` helper; source the script under test.

## Tests must be mocked

- No real host state or network. Stub external binaries (`podman`, `curl`, etc.) via `PATH`-shadowing stub dir.
- Inject hardcoded tool paths via env vars (e.g., `OLLAMA_PLIST_BUDDY`) instead of absolute paths.
- No real `sleep` or network waits: make durations configurable env vars, set to `0` in tests.
- Tests against real host state pass/fail based on machine state, not code — not a unit test.
- Use `--verbose` flag to print per-test timing when diagnosing slow suites.

## Layout

- `bin/` — tools and their `*.test.sh`; helpers in `bin/lib/`.
- `link-file/` — files symlinked to `$HOME`.
- `link-dir/` — directories symlinked to `$HOME`.
- `source/`, `init/` — shell snippets for startup and one-time setup.
