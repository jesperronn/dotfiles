# PixelPilot Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Create a standalone `pixelpilot` CLI in the dotfiles repository that reviews screenshots from any project, compares two screenshot trees or a Git revision, and opens a portable HTML report.

**Architecture:** PixelPilot is a self-contained Node CLI installed through the dotfiles `bin/` directory. It discovers images recursively, uses relative paths as stable scenario IDs, materializes Git baselines in a temporary workspace, builds a manifest containing matched, missing, and extra scenarios, and renders a self-contained HTML viewer with local image assets. The image-diff implementation is behind a small adapter so a more tolerant library can be evaluated later without changing the viewer contract.

**Tech Stack:** Node.js standard library, bundled HTML/JavaScript, PNG decoding/diffing, Git CLI, shell fixture tests.

## Global Constraints

- The command must work from any caller directory and must not require the caller to be inside a Git repository.
- Screenshot identity is the normalized relative path below each screenshot root; never flatten nested paths.
- The initial supported image format is PNG; unsupported files must be reported clearly.
- Git operations must accept an explicit repository path and revision.
- The generated report must retain all source assets in a report-owned directory so it can be opened later.
- Existing unrelated working-tree changes in `dotfiles` must be preserved.
- The first diff engine remains exact pixel comparison; tolerant diff-library replacement is a low-priority follow-up.

## Proposed screenshot contract

Each project exposes two trees with matching relative paths:

```text
screenshots/
  login.png
  admin/dashboard.png
  reports/empty.png
```

The relative path is the scenario ID. A project may choose any root directory and naming scheme, but baseline and current roots must use the same IDs. The recommended convention is committed baseline screenshots under `doc/screenshots/` and generated screenshots under `tmp/screenshot-output/`, while PixelPilot itself accepts arbitrary paths.

## Reuse from any folder

After dotfiles installation makes `bin/` available on `PATH`, invoke:

```bash
pixelpilot --repo /path/to/project --baseline v1 \
  --current-dir /path/to/project/tmp/screenshots \
  --baseline-root doc/screenshots
```

For two ordinary folders, no repository is needed:

```bash
pixelpilot --baseline-dir /path/to/baseline \
  --current-dir /path/to/current
```

The command must resolve all paths before changing directory, use absolute paths internally, and print the report path for CI and non-interactive use.

## Minimal fixture repository

Create a small external fixture repository used only by PixelPilot tests. It contains `screenshot-a.png`, `screenshot-b.png`, and `screenshot-c.png` at tag `v1`; tag `v2` changes `b`, leaves `a` unchanged, and changes `c` dimensions. Additional test commits can add a missing baseline and an extra current screenshot. The fixture should be generated deterministically from a checked-in script or tiny base64 PNG fixtures, so tests do not depend on a real application or Playwright.

## File map

- Create: `bin/pixelpilot` — PATH-facing launcher.
- Create: `bin/lib/pixelpilot/review-cli.js`, `bin/lib/pixelpilot/review-html.js`, `bin/lib/pixelpilot/review-page.js`, `bin/lib/pixelpilot/image-diff.js`, `bin/lib/pixelpilot/diff-artifacts.js` — bundled viewer implementation.
- Create: `bin/pixelpilot.test.sh` — shell-level smoke tests using temporary folders and a temporary Git repository.
- Create: this plan — public usage contract and implementation sequence.

## Implementation tasks

### Task 1: Bundle and launch the existing viewer

- [x] Copy the viewer CLI, renderer, browser client, PNG decoder, and diff artifact modules into `bin/lib/pixelpilot/`; keep the top-level `bin/` limited to runnable entrypoints.
- [x] Keep the launcher independent of the caller’s current directory by resolving bundled modules from `__dirname`.
- [ ] Add explicit `--help` output and a version string.

### Task 2: Add arbitrary-folder comparison

- [ ] Add recursive PNG discovery returning POSIX-style relative paths.
- [ ] Build the union of current and baseline IDs so unchanged, changed, missing-baseline, and missing-current cases all appear.
- [ ] Copy both inputs and generated diffs under the report output directory, avoiding `../` asset paths.
- [ ] Add manifest validation and actionable errors for missing roots, invalid PNGs, duplicate normalized paths, and unsupported files.

### Task 3: Add explicit Git repository support

- [ ] Add `--repo` and `--baseline` options that run `git -C <repo>`.
- [ ] Extract a configurable screenshot root from the requested revision without mutating the project’s baseline directory.
- [ ] Preserve nested paths and reject path traversal from Git tree entries.
- [ ] Record repository path, revision, and Git descriptions in the manifest.

### Task 4: Add deterministic fixture-repository tests

- [ ] Create `v1` and `v2` fixture commits with three PNG scenarios.
- [ ] Assert that one scenario is equal, one has a diff artifact, and one reports a dimension mismatch.
- [ ] Assert recursive paths, missing/extra scenarios, explicit repository paths, and execution from outside the repository.
- [ ] Assert the report path is printed in non-TTY mode and the generated HTML references only report-owned assets.

### Task 5: Evaluate a better diff library

- [ ] Benchmark the current exact comparison against candidate libraries using the fixture set plus anti-aliasing/font-rendering samples.
- [ ] Compare tolerance controls, diff-mask quality, dimension handling, native dependencies, Node compatibility, license, and maintenance activity.
- [ ] Keep the current adapter as the fallback until a candidate demonstrates fewer false positives without hiding meaningful changes.
- [ ] Make library replacement a separate low-priority commit and regression-test both exact and tolerant cases.

## Verification

```bash
bin/pixelpilot.test.sh
node --check bin/pixelpilot
git diff --check
```

Then test reuse from an unrelated directory:

```bash
cd /tmp
pixelpilot --repo /path/to/fixture-repo --baseline v1 \
  --current-dir /path/to/fixture-repo/current
```

The first implementation should be committed separately from any later diff-library experiment.
