# Examples from real projects

Patterns, not a catalogue. Re-read the scripts and their `--help` for details.

| Project | Shape | Worth copying |
| --- | --- | --- |
| Rails + Capistrano app | `workflows`, `troubleshoot`, `deps`, `changelog`, `bump_version`, `deploymock` (container rehearsal of the real deploy), `check_vhost`, `tunnel --print` | Local rehearsal target vs real stages; `troubleshoot` prints for remote stages; `bump_version` tags locally and never pushes; lint exit codes as bit flags (1 rubocop, 2 biome, 4 shellcheck, 8 shfmt) |
| Rails + Ansible app | same verbs; `bin/deploy --target compose\|deploymock\|remote`; `deploy_doctor inspect\|fix`; `bump_ruby` | Ruby version bump separate from `deps`; `inspect` read-only vs `fix` remediating; no staging, said so in the sheet |
| Go CLI | `setup --check`, `test` (go + shell suites, `--timings`), `lint`, `lint-commits`, `build`, `release`, `changelog next\|render\|update\|due` (Go tool) | `release` pushes only after a prompt (`--yes` skips); changelog logic in Go, bash is a thin wrapper; slow-test budgets as env vars |

## Differences between them

- Changelog lives in the annotated tag message (Rails + Capistrano) or in
  `CHANGELOG.md` with an `update` subcommand (Go CLI); omit `update` when the
  file is stale.
- `bump_version` suggests a patch when nothing is releasable; `changelog next`
  exits 3. Document the difference where both exist.
- Usage exit is 64 in older scripts and 2 in newer ones; one per project.
- `setup` without `--help` that runs everything: never probe it.
