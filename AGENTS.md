# AGENTS.md — dotfiles

## Verify before done

- Run `bin/lint` then `bin/test`; both default to all of `bin/`, pass paths to narrow. Nothing runs them automatically — `.githooks/pre-commit` only regenerates the skills README.
- Single test file: `bin/test bin/<name>.test.sh`; `--verbose` prints per-test `[RUN]`/`[TIME]` lines.

## Commits

- Conventional commits: `feat|fix|chore|docs|test|refactor(scope): subject`.
- One logical change per commit; stage only the files you changed (never `git add -A`).

## Bash test rules

- New/changed script in `bin/` gets a colocated `bin/<name>.test.sh`, `chmod +x`.
- Hermetic: no network, no real host state. Stub `podman`/`curl` in a dir prepended to `PATH` (pattern: `bin/npmscout.test.sh`).
- Make sleep/wait durations configurable env vars, set to `0` in tests (e.g. `PODMAN_TROUBLESHOOT_STABILITY_SLEEP_SECONDS=0`).
- Define a local `cleanup_test_tmp()` + `trap 'cleanup_test_tmp' EXIT`.
- Target under ~1s per test file;
- assert with `test_pass`/`assert_*` so every assertion prints `[PASS]` — a silent conditional is not a test.
