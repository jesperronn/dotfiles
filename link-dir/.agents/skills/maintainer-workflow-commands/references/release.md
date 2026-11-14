# Release contract

Prefer existing release tooling. The template follows bbapprove's hand-written
release-note flow and assumes GitHub CLI plus a workflow named `Release`.
Adapt the branch, test entrypoint, and workflow name to the project.

```text
bin/release [--dry-run] [--yes] [VERSION]
bin/changelog next|render|update|due [flags]
```

VERSION is semver without `v`; `1.0.0-rc.3` is a pre-release. Omitted: use
`changelog next`. When that exits 3, pass a version explicitly. A version that
differs from the suggestion prints a note and continues.

Release requires clean main equal to origin/main, an unused tag, authenticated
`gh`, filled `[Unreleased]` notes, and executable lint/test/changelog companions.
It runs lint then tests, moves the notes under a dated version heading, commits
only CHANGELOG.md, and creates an annotated tag. Confirmation precedes the atomic
push of main and the tag; `--yes` skips it. Declining leaves the commit/tag local.
After pushing, it waits for the workflow, watches it, and prints the release URL.
Failures after pushing need inspection; rerunning is not automatic recovery.

`--dry-run` performs read-only precondition checks and prints planned mutations.
It queries origin without fetching. It does not run lint/tests or change files,
commits, tags, or local refs. External read-only Git/gh requests still occur.
Agents need user authorization to publish; a template does not grant it.

`changelog next`, `render`, and `due` are read-only; only `update` writes.
Release does not call `update`: notes remain hand-written. Changelog exits 3
when nothing is releasable, 4 before the quiet period ends, 2 for usage, 1 for
errors. Use each command's `--help` for its flags.
