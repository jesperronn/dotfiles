# Ecosystem commands

What each template runs. Detection files in parentheses. Re-check `--help` of
the tool before relying on a flag.

| | bash | Ruby / Rails | JS | Go | Java |
| --- | --- | --- | --- | --- | --- |
| detect | `*.sh` in `bin/` or `test/` | `Gemfile` (Rails: `config/application.rb` + `bin/rails`) | `package.json` | `go.mod` | `pom.xml`, `build.gradle[.kts]` |
| setup | tools only | `bundle install`; Rails `bin/rails db:prepare` | `npm ci` / `yarn install --immutable` / `pnpm install --frozen-lockfile` | `go mod download` | `mvn dependency:go-offline`, `gradle assemble` |
| dev | n/a | `bin/rails server` (`Procfile.dev`: overmind/foreman) | `<pm> run dev` | `go run .` or `./cmd/<name>` | `spring-boot:run`, `bootRun` |
| test | `bash x.test.sh` | `bin/rspec` / `bundle exec rspec` (spec/), `bin/rails test`, `rake test` | `<pm> run test` | `go test ./... -count=1 -race` | `mvn -B test`, `gradle test` (`-Dtest=`, `--tests`) |
| lint | shellcheck, shfmt | rubocop (`-a`) | biome, eslint, or `lint` script | gofmt -l, go vet, golangci-lint | spotless, checkstyle |
| list outdated | n/a | `bundle outdated --only-explicit` | `npx npm-check-updates` | `go list -u -m` (direct only) | `versions:display-dependency-updates`; gradle `dependencyUpdates` |
| update | n/a | `bundle update --patch\|--minor\|(all)` | `ncu --target patch\|minor\|latest -u`, then install | `go get -u=patch\|-u ./...`, `go mod tidy` | `versions:use-latest-releases` (+ `versions:commit`) |
| major | n/a | all of `bundle update` | `--target latest` | by hand: new `/vN` import path | all of use-latest-releases; gradle by hand |

## Notes per ecosystem

- **bash:** tests are `*.test.sh`; shfmt reads `.editorconfig`, else `-i 2 -ci`.
  Extensionless scripts are linted by shebang.
- **Ruby:** the Ruby version is a separate command (`bin/bump_ruby`-style:
  `.ruby-version`, `.tool-versions`), not `deps`. Prefer binstubs
  (`bin/rspec`, `bin/rubocop`). Add `bundle audit` to `deps` if bundler-audit is used.
- **Rails:** `setup` runs `db:prepare`; Rails upgrades use `bin/rails app:update`
  by hand, never from `deps`. Never touch credentials or `master.key`.
- **JS:** package manager from the lockfile. `npm-check-updates` rewrites ranges,
  including exact pins (classic `yarn upgrade` never moves an exact pin, so `deps`
  runs ncu `-u` first, then `yarn upgrade`): review the diff. `npx --yes` downloads code; skip it
  where that is not allowed.
- **Go:** `go test -race` needs cgo; `GO_TEST_RACE=0` drops it. Add
  `govulncheck ./...` for audit. Release tooling: goreleaser.
- **Java:** prefer `./mvnw`/`./gradlew`. JDK version lives in a toolchain file
  (`.sdkmanrc`, `.java-version`, Gradle toolchain), separate from `deps`. Audit:
  OWASP dependency-check. Gradle has no portable updater; the ben-manes plugin
  only lists.
- **Tooling/CLI projects:** use `dev` for a watcher or build-and-run, `release`
  for archives (`bin/package`-style), and no `deploy`.

## Adding an ecosystem

Add the name to `ALL_GROUPS` and `group_detected` in `lib/project.sh`, then one
`<verb>_<group>` function in each of `setup`, `test`, `lint`, `deps` and a row
above. Python fits the same pattern (`pyproject.toml`, pytest, ruff, `uv`).
