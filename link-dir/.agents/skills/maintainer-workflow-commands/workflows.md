# Maintainer commands: reference catalogue

Companion to [SKILL.md](SKILL.md) (the recipe). This is the full surface as of
2026-11: read from the scripts and their `--help`. Re-check `--help` before
relying on a flag. Project tags: **PR** plus-reporter, **CV** cancerventetid,
**BB** bbapprove; untagged = same in all that have it. Paths are relative to
each repo.

Conventions: `-h/--help` exits 0 everywhere. Usage error is 64 in PR/CV
`workflows`/`troubleshoot`/`check_vhost`/`lint`, 2 in `changelog`/BB scripts.
Plain output when not a TTY or `NO_COLOR` is set (where noted).

## 1. Setup

| Command | What it does | Flags/args | Exit codes | Notes |
| --- | --- | --- | --- | --- |
| `bin/workflows setup` | Prints the setup commands | `[name]` | 0; 64 unknown name | PR, CV. Print-only. Docs: `doc(s)/workflows.md` |
| `bin/setup` PR | yarn install (corepack), bundler, deploymock TLS (`bin/deploymock-ensure-tls`, mkcert optional), `db:prepare`, `log:clear tmp:clear`, `rails restart` | none (no `--help`; any arg ignored) | 0; non-zero if a step fails | Idempotent. Ruby: `source ~/.rvm/scripts/rvm && rvm use` |
| `bin/setup` CV | bundler, `bin/setup_mkcert.sh`, `npm ci --ignore-scripts`, css+js builds, Playwright chromium, docker compose `db`, `db:prepare`, `bin/test_setup --full-db-setup`, then `exec bin/dev` | `--skip-server` (do not start dev) | 0; raises on failure | **No `--help`: `bin/setup --help` runs the full setup** (do not use to probe). Docs: `docs/01_SETUP.md` |
| `bin/setup` BB | Verify tools, `go mod download`, build | `--check` (verify only) | 0; 1 missing/failed; 2 usage | Safe to re-run |
| `bin/test_setup` CV | Prepare SQLite test DB, sync generated fixtures | `--full-db-setup` (db:setup instead of db:prepare) | 0; 1 bad arg | Called by `bin/setup` |
| `bin/setup_mkcert.sh` CV | Local TLS cert `config/ssl/local.{crt,key}` | — | — | Needed once before `bin/dev` |
| `bin/test` | First check after setup | see Develop | | |

## 2. Develop

| Command | What it does | Flags/args | Exit codes | Notes |
| --- | --- | --- | --- | --- |
| `bin/dev` PR | `rails server`; port 3000, falls back to 3003 if taken | rails server args; `-p/--port`/`PORT` disables auto-pick | rails' | `bin/lib/port_picker.rb` shared with `bin/screenshot-runner`. Env: `PORT` |
| `bin/dev` CV | `foreman start -f Procfile.dev` on HTTPS :3000 | foreman args | 1 no local cert (run `bin/setup_mkcert.sh`) or server already running | Env: `PORT` (3000), `DATABASE_URL` (compose pg on 55432), `PIDFILE` (`tmp/pids/dev-server.pid`) |
| `bin/test` PR | RSpec + JS (`bin/test-js`) + shell (`bin/test-sh`); all run even if one fails | `--ruby --js --sh` (combinable); `--fresh-db`; `--ci` (db:drop/create/schema:load, JUnit to `test_results/rspec/results.xml`); `--clean-assets`; `--isolation` (per-file PASS/FAIL); other args to `bin/rspec` | 0; 1 failed; 9 required tool/bundle missing | rspec args/`--fresh-db`/`--isolation`/`--clean-assets` imply Ruby only. Env: `RVM_SCRIPT_PATH` |
| `bin/test` CV | RSpec + JS unit (`node --test`) + shell (`bin/*.test.sh`) | `--ruby --js --sh --pages` (Playwright, ~2 min, never default, rebuilds test DB); `--verbose`; `--fresh-db`; `--isolation` (implies fresh-db); rspec args | 0; 1 failed; 9 tool missing | |
| `bin/test` BB | `go test ./... -count=1 -race`, then `test/*.test.sh` | `--verbose` `--timings` `--no-go` `--no-shell` `[TARGET...]` (a `*.test.sh` file or a Go package pattern) | 0; 1 suite failed; 2 usage | Env: `TEST_SLOW_SUITE_SECONDS` (3), `TEST_SLOW_TEST_SECONDS` (1), informational only |
| `bin/test-sh` PR | Runs `bin/*_test.sh` and `bin/*.test.sh` (bash, `bin/lib/bash_test.sh` PASS/FAIL harness) | `[test-file ...]` | 0 all pass; 1 any failed | CI `lint_and_js` job. `security.test.sh` is non-hermetic (depends on the repo's latest real tag): known pre-existing failure |
| `bin/test-js` PR | JS unit tests | | | via `bin/test --js` |
| `bin/test_javascript` CV | Playwright page tests | | | via `bin/test --pages` |
| `bin/rspec` PR, CV | Targeted specs | rspec args | rspec's | Run before the full suite |
| `bin/lint` PR | RuboCop (.rb), Biome (.js), shellcheck+shfmt (.sh); classifies by extension then shebang; whole project via `git ls-files` with no paths | `-a/--autofix` (default), `--no-autofix`, `--unsafe`, `--ruby` `--js` `--sh`, `--only ruby,js,sh`, `--verbose`; other `-x` args go to rubocop | 0 clean; bit flags 1 RuboCop, 2 Biome, 4 shellcheck, 8 shfmt (OR-ed); 9 tool missing; 64 usage; 66 path missing | Env: `LINT_VERBOSE=1`, `RVM_SCRIPT_PATH`. `/tmp is a symlink` warning is harmless |
| `bin/lint` CV | RuboCop + Biome (JS/JSON) | `-a/--autofix` (default), `--no-autofix` | 0; 9 tool missing; 66 path missing | Other `-x` args to RuboCop. No shell lint |
| `bin/lint` BB | shellcheck + shfmt, `gofmt -l`, `go vet` | `[PATH...]`, `--autofix` (gofmt -w, shfmt -w) | 0; 1 a tool reported problems (all still run); 2 usage | shfmt missing: skipped with a note. Style from `.editorconfig` |
| `bin/lint-commits` BB | Commit/PR text policy (conventional subject <=70 chars, no trailing period, body rules) | `[RANGE]` (default `origin/main..HEAD`), `--title TEXT`, `--body-file FILE` (`-` stdin) | 0 clean; 1 violations; 2 usage | Policy in `AGENTS.md` |
| `bin/build` BB | Go binary with git version embedded | `--test`, `--install [--prefix DIR] [--force]`, `--version`, `-o FILE` | | `bin/install` is the documented install |
| `bin/screenshot` PR | UI baseline via `bin/with-ruby bin/screenshot-runner` | passes args through | runner's | Only noted here. Docs: `doc/screenshots.md`. Never target :3000 for a deploymock check |
| `bin/with-ruby` PR | Loads RVM Ruby then runs the command | command | command's | Used by `bin/test`, `bin/deploy`, `bin/screenshot` |

## 3. Deps

| Command | What it does | Flags/args | Exit codes | Notes |
| --- | --- | --- | --- | --- |
| `bin/workflows deps` | Prints the deps commands | | 0; 64 | PR, CV |
| `bin/deps` PR | List (default) or update gems (`bundle outdated --only-explicit`, bundler) and JS (yarn); checks vendored Bootstrap drift (`vendor/assets/bootstrap.VERSION` vs `package.json`); after a JS update that changes bootstrap re-runs `bin/vendor-bootstrap` | mode: none or `--outdated` (list), `--patch`/`--minor`/`--major` (exclusive); scope `--ruby`/`--js` (default both); `[packages...]` (need exactly one scope); `--dry-run`; `--verbose`; `-h` | 0; 1 error (unknown flag, mutually exclusive levels, packages without single scope); 9 required tool missing | Never commits. Lister exit 1 (outdated) is not a failure. Prints changed files + "Next step:" (`bin/test`, `bin/lint`, suggested `chore(deps): bump x a -> b`). Env: `NODE_OPTIONS` gets `--no-deprecation`. Docs: `doc/dependencies.md`; test `bin/deps_test.sh` |
| `bin/deps` CV | Same interface with bundler + npm | same flags as PR (no Bootstrap check) | 0; 1 error | JS update runs `npx npm-check-updates --target <level> -u` then `npm install` (rewrites package.json ranges incl. exact pins). Default output = last 20 lines. Docs: `docs/dependencies.md`; test `bin/deps.test.sh` |
| `bin/bump_ruby` CV | Bump the Ruby version files | `--major` `--minor` `--patch` `--target VERSION` `--suggest` (look up released versions) `--dry-run` | 0 | Ruby version is separate from `deps`. Docs: `docs/04_MAINTAINERS.md` |
| `bin/vendor-bootstrap` PR | Regenerates vendored Bootstrap + stamp | | | Called by `bin/deps` |
| `bin/test && bin/lint` | Verify an update, then commit by hand | | | |

BB has no deps script (Go modules; `go mod` by hand) (gap).

## 4. Release

| Command | What it does | Flags/args | Exit codes | Notes |
| --- | --- | --- | --- | --- |
| `bin/changelog next` PR | Next `vX.Y.Z` from conventional commits since latest `vX.Y.Z` tag (`v0.0.0` if none) | `--repo DIR` | 0 releasable; 3 nothing releasable; 1 error; 2 usage | Read-only: never tags, fetches or writes. Env: `BASE_TAG`, `NO_COLOR`. Sources `bin/bump_version` for tag lookup/version math |
| `bin/changelog render` PR | Changelog section for that version | `--repo DIR` | 0; 3; 1; 2 | Entries `- **scope:** description (hash)` |
| `bin/changelog due` PR | Time left of the quiet period since HEAD | `--repo DIR`, `--grace D` (`90m` `2h` `1h30m` `1d`, default 2h), `--now EPOCH` (seconds, tests) | 0 due; 4 not yet; 1; 2 | |
| `bin/changelog next/render/update/due` BB | Go tool; also `update` inserts the section into `CHANGELOG.md` | all: `-repo DIR`. `next`: -. `render`/`update`: `-version X`, `-date YYYY-MM-DD`. `update`: `-file`, `-replace-unreleased`. `due`: `-grace` (2h), `-last-activity RFC3339` (HEAD time), `-now RFC3339` | 0; 3; 4; 1; 2 | Flag style `-x` (Go flag). `update` refuses if the version heading exists. Pre-release base `v1.0.0-rc.2` gives `1.0.0`. Types table in `internal/release/render.go` |
| `bin/bump_version` PR | Pre-flight checklist (clean tree, HEAD is main = origin/main, CI status for HEAD via `gh api` GET; CI lookup is a warning only), suggests bump, creates ANNOTATED local tag with changelog `<latest tag>..HEAD`, prints push/deploy next steps; **never pushes** | `[vX.Y.Z]`; `-i/--interactive`; `-n/--dry-run`; `-f/--force`; `-d/--debug/--verbose`; `--ignore-dirty`; `--major/--minor/--patch`; `--deploy [vX.Y.Z]` (adds production lookup, migrations + puma env-var checks since production, full deploy steps; an already-existing tag only prints); `--production-rev SHA`; `--deploy-tag vX.Y.Z` (creates `deploy-YYYY-MM-DD[.N]`, prints push) | 0; 1 dirty tree / bad version; 2 no `--force`/`--interactive`/version/bump type given; 3 pre-flight failed; 4 tag missing locally (`--deploy`/`--deploy-tag`); 8 unknown parameter | PR only. Env: `PRODUCTION_VERSION_URL` (default `https://indberetning-joep.pplus.dk/version`), `PRODUCTION_REVISION_URL` (fallback sign_in footer), `PRODUCTION_REV_OVERRIDE`. Default bump when nothing releasable: patch. Docs: `doc/release.md`; test `bin/bump_version_test.sh` |
| `GET /version` PR | Deployed revision/tag/describe as JSON (`/version.txt` or `Accept: text/plain` gives describe) | | | Public, no auth, never a time. `doc/release.md#the-version-endpoint` |
| `bin/release` BB | Full release: preconditions (main, clean, not behind origin, tag unused locally+origin, `gh auth`, non-empty `[Unreleased]`), `bin/lint`, `bin/test`, move `[Unreleased]` under `## [X.Y.Z] - DATE`, commit `docs: changelog for X.Y.Z`, tag, **asks** then `git push --atomic origin main vX.Y.Z`, `gh run watch`, prints URL | `[VERSION]` (no leading `v`; `-` = pre-release; omitted = `changelog next`); `--dry-run`; `--yes` (skip push prompt) | 0 released/dry run; 1 failed or declined; 2 usage; 127 tool missing | BB only: pushes (after prompt). Env: `RELEASE_DATE`, `BBAPPROVE_RELEASE_RUN_WAIT_SECONDS` (60), `BBAPPROVE_RELEASE_RUN_POLL_SECONDS` (3). Docs: `docs/releasing.md` |
| `bin/release-notes` BB | Body of the `## [VERSION]` section for a tag | `[--changelog FILE] TAG` | 0; 1 section missing/empty; 2 usage | Used for the GitHub release notes |
| `bin/package` BB | Release archives + `SHA256SUMS` for a tag | `TAG --out DIR`, `--only OS/ARCH` (repeatable) | | Used by the Release workflow; publishes nothing |
| `bin/workflows deploy` | Index of preview/bump/deploy commands | | 0; 64 | PR, CV |

CV has no release script and no tags flow (gap). Env: `BBAPPROVE_VERSION` overrides the embedded version.

## 5. Deploy: local rehearsal

| Command | What it does | Flags/args | Exit codes | Notes |
| --- | --- | --- | --- | --- |
| `bin/deploymock <cmd>` PR | Ubuntu 26.04 systemd container (podman or docker) rehearsing the real Capistrano path | `build` `start` `stop` `rm` `status` `ssh` `provision` (cap setup + pg) `deploy` `doctor` `check-host` `smoke` (build, start, provision, deploy, doctor, check-host) `nocerts` (expect setup to skip nginx and FAIL) `screenshot` (seed + capture on :8443); `-h` | 0; 1 error / unknown command | Env: `DEPLOYMOCK_NAME` (`plusreporter-deploymock`), `DEPLOYMOCK_IMAGE`, `DEPLOYMOCK_SSH_PORT` (2222), `DEPLOYMOCK_HTTP_PORT` (8080), `DEPLOYMOCK_HTTPS_PORT` (8443), `DEPLOYMOCK_ENGINE`, `GITHUB_DEPLOY_KEY_FILE`, `DEPLOYMOCK_SKIP_SEED`. Needs a running container runtime. Related: `bin/deploymock-ensure-tls`, `bin/deploymock-check`, `doc/deploymock.md`. Test `bin/deploymock.test.sh` |
| `bin/deploy --target deploymock` CV | Bootstrap deploymock, then `ansible-playbook site.yml --limit deploymock` | see section 6 CV row | | |
| `bin/deploy --target compose` CV | Local Docker Compose production-image runtime | | | Fix via `bin/deploy_doctor fix --target compose` |
| `bin/build` CV | Build images and tarballs into `deploy/assets` | `--all` (pull+build+save), `--ansible` `--app` `--db` `--deploymock`, `--offline`, `--pull`, `--save`, `--help` | 0; 1 bad arg; 9 container tool missing | Env: `CONTAINER_BIN`, `CV_DEPLOYMOCK_PLATFORM`, `OFFLINE` |
| `bin/run_deploymock`, `bin/setup_deploymock` CV | Deploymock helper scripts (not read in detail) | | | not referenced from `bin/deploy`; check before use |
| `bin/deploy deploymock <task>` PR | Cap task on the local stage | see section 6 | | |

BB: no deploy concept (CLI tool; releases are GitHub Releases) (gap).

## 6. Deploy: real

| Command | What it does | Flags/args | Exit codes | Notes |
| --- | --- | --- | --- | --- |
| `bin/deploy <stage> [cap-task]` PR | `exec bin/with-ruby bin/cap <stage> <task>` (default `deploy`) | stages: `production_dip` `production_joep` `staging_dip` `staging_joep` `deploymock` `ci`; env `REVISION=<tag>` selects the deployed ref | 0 (no stage = usage); 9 bundle gems missing (run `bin/setup`); else cap's | Wraps Capistrano (`Capfile`, `config/deploy/*.rb`). **Remote: user runs it, agents never** (no cap on `production_*`). Docs: `doc/release.md` |
| `bin/deploy` CV | Ansible `site.yml` against compose/deploymock/remote | `--target <compose\|deploymock\|remote>` (remote default), `--host <inventory-target>`, `--rebuild-artifacts` (fresh `bin/build --app --db --save`), `--color/--no-color`, `-h` | 0; 1 error | Env: `NO_COLOR`, `CV_DEPLOYMOCK_PLATFORM`. Remote/deploymock reuse existing tarballs by default. No staging stage. Docs: `deploy/README.md` |
| `bin/deploy_doctor <stage> [cap-task]` PR | `bin/cap <stage> doctor` (shared contract checks, `bin/deploy_contract_check`) | `[cap-task]` default `doctor` | 0 (no stage = usage); 9 bundle missing; else cap's | Remote stage: user runs it |
| `bin/deploy_doctor <inspect\|fix> --target <compose\|deploymock\|remote\|production>` CV | `inspect` read-only health check; `fix` remediates then rechecks | `--host <inventory-target>`, `--verbose` | non-zero on failed checks | Logic in `bin/lib/deploy_doctor.sh` |
| `bin/bump_version --deploy ...` PR | Prints the deploy steps (never runs) | see section 4 | | |
| Post-deploy tag PR | `bin/bump_version --deploy-tag vX.Y.Z` | | | see section 4 |

## 7. Troubleshoot: local and remote

| Command | What it does | Flags/args | Exit codes | Notes |
| --- | --- | --- | --- | --- |
| `bin/troubleshoot deploymock` PR | Runs `bin/deploymock status`, `bin/deploy_doctor deploymock`, `bin/deploymock check-host`; continues past failures | | 0 all ok; 1 any step failed; 64 no arg | Prints `N step(s) failed.` |
| `bin/troubleshoot <other stage>` PR | **Runs nothing.** Prints: `bin/deploy_doctor`, `bin/cap <stage> logs:ls`, `logs:tail_rails`, `bin/check_vhost`, `bin/tunnel --print`, `bin/deploy <stage> deploy:check` | `staging_*`, `production_*`, `ci` | 0 | Hard safety rule. Pointers `doc/troubleshooting.md`, `doc/deploymock.md` |
| `bin/troubleshoot compose\|deploymock` CV | `exec bin/deploy_doctor inspect --target <t>` (read-only, local containers) | | doctor's; 64 no arg | |
| `bin/troubleshoot <remote host>` CV | **Runs nothing.** Prints `deploy_doctor inspect --target remote --host H` and, only if inspect says so, `fix` | | 0 | Pointers `deploy/README.md`, `docs/07_DEBUGGING.md` |
| `bin/check_vhost <stage>` PR | Check nginx vhost + TLS before DNS using `curl --resolve`; reads `config/deploy/<stage>.rb` only, no cap, no login | `--ip IP` (default: `ssh -G` HostName, no connect), `--host NAME`, `--tunnel PORT` (use 127.0.0.1:PORT), `--deployed` (502/503/504 is FAIL, default PASS) | 0 PASS; 1 FAIL; 64 usage | Docs: `doc/vhost_check.md`; test `bin/check_vhost.test.sh` |
| `bin/tunnel [--print] [stage ...]` PR | ssh tunnel to nginx :443 on the stage's server for browsing; `--print` shows the command and URLs only | `--print`, stages | 0; 1 error | Env: `TUNNEL_PORT` (8443). Needs `/etc/hosts` test hostnames. Admin login refused unless puma has `SUPERUSER_TESTMODE=1`. **Opens ssh: user runs it** (use `--print`) |
| `bin/deploymock status`/`doctor`/`check-host` PR | Local checks | see section 5 | | |
| `bin/cap <stage> logs:ls\|logs:tail_rails` PR | Remote logs | | | Printed by troubleshoot, never run by agents |
| `bin/db_dump_ssh` PR, `bin/db_dump_ssh.sh` CV | DB dump over ssh | | | Remote; user only |

## Standard contract

Generic command every project should expose, with each project's equivalent.

| Generic | plus-reporter | cancerventetid | bbapprove |
| --- | --- | --- | --- |
| `workflows` | `bin/workflows` | `bin/workflows` | — (gap) |
| `troubleshoot` | `bin/troubleshoot` | `bin/troubleshoot` | — (gap; CLI, no deploy) |
| `deps` | `bin/deps` (bundler+yarn) | `bin/deps` (bundler+npm) + `bin/bump_ruby` | — (gap; Go modules by hand) |
| `changelog` | `bin/changelog next\|render\|due` | — (gap) | `bin/changelog next\|render\|update\|due` |
| `setup` | `bin/setup` | `bin/setup [--skip-server]` + `bin/test_setup` | `bin/setup [--check]` |
| `dev` | `bin/dev` | `bin/dev` | — (gap; `bin/build`/`bin/bbapprove`) |
| `test` | `bin/test` (+`test-sh`, `test-js`) | `bin/test` | `bin/test` |
| `lint` | `bin/lint` | `bin/lint` | `bin/lint` (+ `bin/lint-commits`) |
| `deploy` | `bin/deploy <stage> [task]`, `bin/deploymock` | `bin/deploy --target ...` | — (gap) |
| `deploy_doctor` | `bin/deploy_doctor <stage>` | `bin/deploy_doctor inspect\|fix --target` | — (gap) |
| `release` / bump | `bin/bump_version` (tag only, no push) | — (gap) | `bin/release` (pushes after prompt), `bin/release-notes` |

## Gaps and differences

- `changelog update` only in bbapprove (keeps `CHANGELOG.md`); plus-reporter
  puts the changelog in the annotated tag message (its `CHANGELOG.md` is stale);
  cancerventetid has no changelog or release tooling.
- JS tooling: plus-reporter yarn (corepack), cancerventetid npm (`npm-check-updates`
  rewrites pins), bbapprove none.
- `bump_version` defaults to a patch bump when nothing is releasable;
  `changelog next` exits 3 (both PR and BB). `bump_version` exit 8 unknown param,
  `changelog` 2.
- Usage exit 64 (PR/CV workflow-style scripts, lint) versus 2 (changelog, BB
  scripts); one project per convention, not unified across projects.
- Flag style: bash `--flag` (PR, CV) versus Go `-flag` for `bbapprove changelog`.
- Release pushing: only `bbapprove bin/release` pushes (after a prompt, `--yes`
  skips); `bump_version` never pushes.
- `--help` hazard: cancerventetid `bin/setup` has no `--help` and runs the whole
  setup; plus-reporter `bin/setup` likewise ignores args. Never probe them.
- Remote stages (plus-reporter `staging_*`/`production_*`, cancerventetid
  `remote` hosts): `troubleshoot` prints, never runs; agents never run
  `cap`/`ssh`/`ansible` against them.
- Test harness: PR `bin/test-sh` runs `*_test.sh` and `*.test.sh`; CV via
  `bin/test --sh`; BB `test/*.test.sh` through `bin/test`.
- No staging in cancerventetid; no deploy in bbapprove; no `dev` in bbapprove;
  `workflows`/`troubleshoot` missing in bbapprove.
