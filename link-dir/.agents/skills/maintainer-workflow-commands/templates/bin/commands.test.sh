#!/usr/bin/env bash
# commands.test.sh — tests for the bin/ command templates; hermetic, uses --dry-run and a scratch project.
# shellcheck disable=SC1090,SC1091
set -euo pipefail

BIN_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd -P)"
source "${BASH_TEST_LIB:-$BIN_DIR/lib/bash_test.sh}"

TEST_TMP_DIR="$(mktemp -d)"
cleanup_test_tmp() { rm -rf "$TEST_TMP_DIR"; }
trap cleanup_test_tmp EXIT

# mk_project NAME FILES...: scratch git repo with a copy of bin/ and the given files.
mk_project() {
  local dir="$TEST_TMP_DIR/$1" f
  shift
  mkdir -p "$dir/bin"
  cp -R "$BIN_DIR/." "$dir/bin/"
  rm -f "$dir/bin/commands.test.sh" # the copy would run itself through bin/test --bash
  for f in "$@"; do
    mkdir -p "$dir/$(dirname "$f")"
    : >"$dir/$f"
  done
  git -C "$dir" init -q
  git -C "$dir" add -A
  printf '%s\n' "$dir"
}

run() { # run VAR_OUT VAR_STATUS DIR CMD...
  local out_var="$1" st_var="$2" dir="$3"
  shift 3
  capture_command "$out_var" "$st_var" env -C "$dir" "$@"
}

test_workflows_prints_every_section() {
  local out st dir
  dir="$(mk_project wf)"
  run out st "$dir" bin/workflows
  assert_status 0 "$st" "workflows exits 0"
  local s
  for s in setup dev test lint deps release deploy troubleshoot; do
    assert_contains "$out" "== $s ==" "workflows prints section $s"
  done
  run out st "$dir" bin/workflows nope
  assert_status 2 "$st" "unknown workflow exits 2"
}

test_test_runs_every_detected_group() {
  local out st dir
  dir="$(mk_project t1 Gemfile spec/a_spec.rb go.mod package.json pom.xml bin/x.sh)"
  run out st "$dir" bin/test --dry-run
  assert_status 0 "$st" "dry run exits 0"
  assert_contains "$out" "+ bundle exec rspec" "ruby runs rspec when spec/ exists"
  assert_contains "$out" "+ go test ./... -count=1 -race" "go runs all packages with race"
  assert_contains "$out" "+ npm run test" "js runs the test script"
  assert_contains "$out" "+ mvn -B test" "java runs maven"
  assert_contains "$out" "skipped: no *.test.sh" "bash group says when it has no tests"
}

test_test_group_flag_and_paths() {
  local out st dir
  dir="$(mk_project t2 Gemfile spec/models/a_spec.rb go.mod internal/x/y_test.go package.json)"
  run out st "$dir" bin/test --dry-run --go
  assert_not_contains "$out" "rspec" "--go skips ruby"
  assert_contains "$out" "go test" "--go runs go"
  run out st "$dir" bin/test --dry-run spec/models/a_spec.rb
  assert_contains "$out" "+ bundle exec rspec spec/models/a_spec.rb" "spec path goes to rspec"
  assert_not_contains "$out" "go test" "spec path does not run go"
  run out st "$dir" bin/test --dry-run internal/x/y_test.go
  assert_contains "$out" "+ go test ./internal/x -count=1 -race" "go file maps to its package"
  run out st "$dir" bin/test --dry-run --bogus
  assert_status 2 "$st" "unknown option exits 2"
  run out st "$dir" bin/test --dry-run nope.txt
  assert_status 2 "$st" "missing path exits 2"
}

test_test_bash_group_runs_colocated_tests() {
  local out st dir
  dir="$(mk_project t3 bin/tool.sh)"
  printf '#!/usr/bin/env bash\necho ran-tool-test\n' >"$dir/bin/tool.test.sh"
  run out st "$dir" bin/test --bash
  assert_status 0 "$st" "passing bash test exits 0"
  assert_contains "$out" "ran-tool-test" "colocated test ran"
  printf '#!/usr/bin/env bash\nexit 3\n' >"$dir/bin/tool.test.sh"
  run out st "$dir" bin/test --bash bin/tool.test.sh
  assert_status 1 "$st" "failing bash test exits 1"
  assert_contains "$out" "FAIL" "summary names the failure"
}

test_test_missing_tool_exits_9() {
  local out st dir
  dir="$(mk_project t4 go.mod)"
  run out st "$dir" env PATH="/nonexistent" "$(command -v bash)" bin/test --go
  assert_status 9 "$st" "missing go exits 9"
  assert_contains "$out" "MISSING" "summary says MISSING"
}

test_lint_routes_files_and_autofix() {
  local out st dir
  dir="$(mk_project l1 Gemfile a.rb go.mod pkg/b.go package.json biome.json)"
  run out st "$dir" bin/lint --dry-run
  assert_contains "$out" "+ bundle exec rubocop" "ruby uses rubocop"
  assert_contains "$out" "+ go_fmt_check ." "go checks gofmt"
  assert_contains "$out" "+ go vet ./..." "go runs vet"
  assert_contains "$out" "+ npx --no-install biome check ." "js uses biome"
  run out st "$dir" bin/lint --dry-run --autofix a.rb pkg/b.go
  assert_contains "$out" "+ bundle exec rubocop -a a.rb" "autofix passes -a and the file"
  assert_contains "$out" "+ gofmt -w pkg/b.go" "autofix formats the go file"
  assert_contains "$out" "+ go vet ./pkg" "vet gets the package dir"
  assert_not_contains "$out" "biome" "js is not linted for ruby/go paths"
  run out st "$dir" bin/lint --dry-run pkg
  assert_contains "$out" "gofmt -l" "a directory expands to its files"
}

test_lint_bash_scripts_by_shebang() {
  local out st dir
  dir="$(mk_project l2 bin/x.sh)"
  printf '#!/usr/bin/env bash\n' >"$dir/bin/tool"
  git -C "$dir" add -A
  run out st "$dir" bin/lint --dry-run
  assert_contains "$out" "bin/x.sh" "tracked .sh is linted"
  assert_contains "$out" "bin/tool" "extensionless bash script is linted by shebang"
  assert_contains "$out" "shfmt -i 2 -ci -d" "shfmt falls back to -i 2 -ci without .editorconfig"
}

test_setup_installs_by_lockfile() {
  local out st dir
  dir="$(mk_project s1 Gemfile package.json package-lock.json go.mod bin/setup.d/10-x)"
  chmod +x "$dir/bin/setup.d/10-x"
  run out st "$dir" bin/setup --dry-run
  assert_contains "$out" "+ ruby_install" "ruby installs bundle"
  assert_contains "$out" "+ npm ci" "npm ci with a package-lock"
  assert_contains "$out" "+ go mod download" "go downloads modules"
  assert_contains "$out" "+ bin/setup.d/10-x" "setup.d steps run"
  run out st "$dir" env PATH="/nonexistent" "$(command -v bash)" bin/setup --check
  assert_status 9 "$st" "--check with no tools exits 9"
}

test_dev_picks_command() {
  local out st dir
  dir="$(mk_project d1 Gemfile config/application.rb bin/rails)"
  run out st "$dir" bin/dev --dry-run -p 4000
  assert_contains "$out" "+ bin/rails server -p 4000" "rails server with passthrough args"
  run out st "$dir" env DEV_CMD="echo hi" bin/dev --dry-run
  assert_contains "$out" "bash -c" "DEV_CMD wins"
  dir="$(mk_project d2 README.md)"
  run out st "$dir" bin/dev --dry-run
  assert_status 1 "$st" "nothing to start exits 1"
}

test_deps_levels_and_scopes() {
  local out st dir
  dir="$(mk_project p1 Gemfile go.mod pom.xml)"
  run out st "$dir" bin/deps --dry-run --ruby
  assert_contains "$out" "+ ruby_list" "no level lists outdated"
  run out st "$dir" bin/deps --dry-run --patch --ruby
  assert_contains "$out" "+ bundle update --patch" "ruby patch update"
  run out st "$dir" bin/deps --dry-run --patch --go
  assert_contains "$out" "+ go_update -u=patch ./..." "go patch update"
  run out st "$dir" bin/deps --dry-run --major --go
  assert_contains "$out" "skipped: a major version changes the import path" "go major is manual"
  run out st "$dir" bin/deps --dry-run --minor --java
  assert_contains "$out" "+ java_update mvn -DallowMajorUpdates=false" "maven minor excludes major"
  run out st "$dir" bin/deps --dry-run --patch --minor
  assert_status 2 "$st" "two levels exit 2"
  run out st "$dir" bin/deps --dry-run --patch rails
  assert_status 2 "$st" "packages without one scope exit 2"
  run out st "$dir" bin/deps --dry-run --patch --ruby rails
  assert_contains "$out" "bundle update --patch rails" "named package is passed on"
}

test_troubleshoot_never_runs_remote() {
  local out st dir
  dir="$(mk_project r1 README.md)"
  run out st "$dir" env PATH="/nonexistent" "$(command -v bash)" bin/troubleshoot production
  assert_status 0 "$st" "remote target exits 0"
  assert_contains "$out" "nothing was executed" "remote prints hints"
  assert_contains "$out" "ssh production" "hint names the target"
  run out st "$dir" bin/troubleshoot
  assert_status 2 "$st" "missing target exits 2"
}

# commit_at DIR OFFSET SUBJECT [BODY]: commit at 1700000000+OFFSET seconds.
commit_at() {
  local dir="$1" when="$2" subject="$3" body="${4-}"
  GIT_AUTHOR_DATE="$((1700000000 + when)) +0000" GIT_COMMITTER_DATE="$((1700000000 + when)) +0000" \
    git -C "$dir" -c user.name=t -c user.email=t@t commit -q --allow-empty -m "$subject${body:+

$body}"
}

test_changelog_bumps_from_conventional_commits() {
  local out st dir
  dir="$(mk_project c1 README.md)"
  commit_at "$dir" 1000 "chore: init"
  run out st "$dir" bin/changelog next
  assert_status 3 "$st" "nothing releasable exits 3"
  assert_contains "$out" "nothing releasable" "says why"
  commit_at "$dir" 1100 "feat(api): add export"
  run out st "$dir" bin/changelog next
  assert_eq "v0.1.0" "$out" "first feat without tags gives v0.1.0"
  git -C "$dir" tag v1.2.3
  commit_at "$dir" 1200 "docs: typo"
  run out st "$dir" bin/changelog next
  assert_status 3 "$st" "docs alone is not releasable"
  commit_at "$dir" 1300 "fix: crash"
  run out st "$dir" bin/changelog next
  assert_eq "v1.2.4" "$out" "fix gives a patch bump"
  commit_at "$dir" 1400 "feat: more"
  run out st "$dir" bin/changelog next
  assert_eq "v1.3.0" "$out" "feat gives a minor bump"
  commit_at "$dir" 1500 "refactor: x" "BREAKING CHANGE: api removed"
  run out st "$dir" bin/changelog next
  assert_eq "v2.0.0" "$out" "BREAKING CHANGE footer gives major"
}

test_changelog_render_groups_entries() {
  local out st dir
  dir="$(mk_project c2 README.md)"
  git -C "$dir" -c user.name=t -c user.email=t@t commit -q --allow-empty -m "chore: init"
  git -C "$dir" tag v1.0.0
  commit_at "$dir" 1000 "feat(api): add export"
  commit_at "$dir" 1100 "fix: crash"
  commit_at "$dir" 1200 "perf!: drop cache"
  run out st "$dir" bin/changelog render
  assert_status 0 "$st" "render exits 0"
  assert_contains "$out" "## v2.0.0" "heading has the next version"
  assert_contains "$out" "### Changed (BREAKING)" "breaking section"
  assert_contains "$out" "### Added" "added section"
  assert_contains "$out" "- **api:** add export (" "scope and description format"
  assert_contains "$out" "### Fixed" "fixed section"
  run out st "$dir" bin/changelog render --repo "$TEST_TMP_DIR/nope"
  assert_status 1 "$st" "bad repo exits 1"
  run out st "$dir" bin/changelog bogus
  assert_status 2 "$st" "unknown subcommand exits 2"
}

test_changelog_due_uses_quiet_period() {
  local out st dir
  dir="$(mk_project c3 README.md)"
  commit_at "$dir" 10000 "feat: x"
  run out st "$dir" bin/changelog due --now 1700010600
  assert_status 4 "$st" "inside the grace period exits 4"
  assert_eq "1h50m" "$out" "prints the time left"
  run out st "$dir" bin/changelog due --now 1700017200
  assert_status 0 "$st" "after the grace period exits 0"
  assert_eq "due" "$out" "prints due"
  run out st "$dir" bin/changelog due --grace 90m --now 1700010000
  assert_eq "1h30m" "$out" "custom grace"
  run out st "$dir" bin/changelog due --grace nope
  assert_status 2 "$st" "bad grace exits 2"
}

test_changelog_update_inserts_section() {
  local out st dir
  dir="$(mk_project c4 README.md)"
  git -C "$dir" -c user.name=t -c user.email=t@t commit -q --allow-empty -m "chore: init"
  git -C "$dir" tag v1.0.0
  commit_at "$dir" 1000 "feat(api): add export"
  printf '# Changelog\n\n## [Unreleased]\n\n- hand written\n\n## [1.0.0] - 2026-01-01\n\n- old\n' >"$dir/CHANGELOG.md"
  run out st "$dir" bin/changelog update --date 2026-02-03
  assert_status 0 "$st" "update exits 0"
  local file
  file="$(cat "$dir/CHANGELOG.md")"
  assert_contains "$file" "## [1.1.0] - 2026-02-03" "new heading uses Keep a Changelog form"
  assert_contains "$file" "- **api:** add export (" "entry is inserted"
  assert_contains "$file" "- hand written" "Unreleased body stays by default"
  assert_contains "$file" "- old" "older release stays"
  if [[ "$file" == *"[Unreleased]"*"[1.1.0]"*"[1.0.0]"* ]]; then
    test_pass "new section sits between Unreleased and the newest release"
  else
    test_fail "section order" "$file"
  fi
  run out st "$dir" bin/changelog update --date 2026-02-03
  assert_status 1 "$st" "second update refuses a duplicate version"
  assert_contains "$out" "already has a section" "says why"
}

test_changelog_update_replace_unreleased_and_create() {
  local out st dir file
  dir="$(mk_project c5 README.md)"
  git -C "$dir" -c user.name=t -c user.email=t@t commit -q --allow-empty -m "chore: init"
  git -C "$dir" tag v1.0.0
  commit_at "$dir" 1000 "fix: crash"
  printf '# Changelog\n\n## [Unreleased]\n\n- hand written\n\n## [1.0.0] - 2026-01-01\n' >"$dir/CHANGELOG.md"
  run out st "$dir" bin/changelog update --replace-unreleased --date 2026-02-03
  file="$(cat "$dir/CHANGELOG.md")"
  assert_not_contains "$file" "hand written" "--replace-unreleased drops the body"
  assert_contains "$file" "## [Unreleased]" "...but keeps the heading"
  assert_contains "$file" "## [1.0.1] - 2026-02-03" "patch section added"
  rm "$dir/CHANGELOG.md"
  run out st "$dir" bin/changelog update --date 2026-02-03
  assert_status 0 "$st" "a missing file is created"
  assert_contains "$(cat "$dir/CHANGELOG.md")" "## [1.0.1] - 2026-02-03" "created file has the section"
  run out st "$dir" bin/changelog next --file x.md
  assert_status 2 "$st" "--file only applies to update"
}

run_tests "$@"
