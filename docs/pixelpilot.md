# pixelpilot

A Node.js screenshot reviewer, synced from `plus-reporter`'s `tools/screenshot` (`bin/screenshot_review`). It compares the PNGs in a current screenshot folder (or at a Git ref) against a baseline at a Git ref, and writes a self-contained HTML review page with a scenario sidebar and a viewer: side-by-side or overlay, pixel diff, heatmap and region boxes, zoom/pan, blink, fade and keyboard-driven review.

## Start

```bash
pixelpilot --help
pixelpilot --baseline v1.2.0
pixelpilot --from v20.0.0 --to v21.1.0
```

Run it from the root of the project being reviewed. See `pixelpilot --help` for the full option list and defaults.

| Option | Default | Meaning |
| --- | --- | --- |
| `--baseline`, `--from` | `HEAD` | Git ref the baseline PNGs are extracted from. |
| `--current-dir` | `tmp/screenshot-output` | Folder with the current PNGs. |
| `--current-ref`, `--to` | none | Git ref to use as the current side instead (exclusive with `--current-dir`). |
| `--baseline-dir` | `tmp/screenshot-review/baseline/<ref>` | Scratch folder the baseline is extracted into. |
| `--screenshots-dir` | `doc/screenshots` | Git-tracked folder the baseline PNGs are read from. |
| `--output-html` | `tmp/screenshot-review/index.html` | Where the page is written; diff images go beside it. |
| `--title` | `Screenshot Review` | Page title and heading. |

Settings can also come from `screenshot-review.config.json` or a `screenshotReview` key in `package.json`; CLI flags win.

When stderr is a terminal, a braille spinner with an `n/total` count shows while overlays are built (the frame advances every second; `PIXELPILOT_SPINNER_INTERVAL_MS` overrides it), and the line is removed when done. `--help`, `-h` prints the usage.

## Gotchas

- **`--baseline-dir` is an output folder.** Baseline PNGs are written into it, overwriting same-named files. Point it at a scratch folder.
- **The `--manifest` option no longer exists** in the upstream version.
- The page loads images by relative path, so keep it next to its `diffs/` and `baseline/` folders.
- Errors go to stderr and exit with status 1.

## Files

- [bin/pixelpilot](../bin/pixelpilot) — launcher; calls `bin/lib/pixelpilot/cli.js`.
- `bin/lib/pixelpilot/cli.js` — argument parsing, config, git baseline extraction, output.
- `review-html.js` / `review-page.js` — the HTML page and its embedded browser-side script.
- `pixel-diff.js`, `pixelmatch.js`, `heatmap.js`, `regions.js`, `png.js`, `changed-percent-color.js` — dependency-free diffing and PNG handling.

To resync, copy these files from `plus-reporter/tools/screenshot/` and re-apply the `Usage: pixelpilot` rename in `cli.js`.
