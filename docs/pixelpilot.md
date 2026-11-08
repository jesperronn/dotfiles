# pixelpilot

A Node.js screenshot reviewer, synced from `plus-reporter`'s `tools/screenshot` (`bin/screenshot_review`). It compares the PNGs in a current screenshot folder (or at a Git ref) against a baseline at a Git ref, and writes a self-contained HTML review page with a scenario sidebar and a viewer: side-by-side or overlay, pixel diff, heatmap and region boxes, zoom/pan, blink, fade and keyboard-driven review.

## Start

```bash
pixelpilot --help
pixelpilot --from v1.2.0
pixelpilot --from v20.0.0 --to v21.1.0
```

Run it from the root of the project being reviewed. See `pixelpilot --help` for the full option list and defaults.

| Option | Default | Meaning |
| --- | --- | --- |
| `--from` | `HEAD` | Git ref the baseline PNGs are read from. |
| `--from-dir` | none | Plain folder of baseline PNGs instead of a git ref (exclusive with `--from`). No git extraction, `git describe`, dirty badge or tag needed; headings default to the folder paths. |
| `--to` | none | Git ref for the current side (exclusive with `--to-dir`). |
| `--to-dir` | `tmp/screenshot-output` if it has PNGs, else `--path` | On-disk folder with the current PNGs (exclusive with `--to`). |
| `--path` | `doc/screenshots` | Repo-relative folder holding the PNGs inside a ref; also the default `--to-dir`. |
| `--from-path`, `--to-path` | `--path` | `--path` for one side only, for when the screenshots moved between refs. |
| `--from-label`, `--to-label` | git describe | Heading text for each side. |
| `--output-html` | `tmp/screenshot-review/index.html` | Where the page is written; diff images go beside it. |
| `--title` | `Screenshot Review` | Page title and heading. |
| `--extract-dir` | `tmp/screenshot-review/baseline/<ref>` | Advanced: scratch folder the `--from` ref is extracted into. |
| `--report` | off | Print a text table instead of writing the HTML page (see below). |
| `--band-height` | `100` | Band height in px for the report's per-band summary. |
| `--only` | all | Report only: comma-separated file-name prefixes (`01` also matches `1-…`). |
| `--fail-above` | none | Report only: exit 1 if any pair differs by more than this percent. |
| `--report-dir` | `tmp/pixelpilot-report` | Report only: where diff PNGs are written. |

The old names still work as deprecated aliases: `--baseline`, `--current-ref`, `--baseline-folder`, `--current-dir`, `--screenshots-dir`, `--baseline-dir`, `--baseline-label`, `--current-label`.

Settings can also come from `screenshot-review.config.json` or a `screenshotReview` key in `package.json`; CLI flags win.

When stderr is a terminal, a braille spinner with an `n/total` count shows while overlays are built (the frame advances every 80 ms, the same pace as the `ora`/cli-spinners "dots" spinner; `PIXELPILOT_SPINNER_INTERVAL_MS` overrides it), and the line is removed when done. `--help`, `-h` prints the usage.

## Compare two folders

```bash
pixelpilot --from-dir screenshots/orig --to-dir screenshots/dev \
  --from-label 'WordPress (original)' --to-label 'Hugo (new)' \
  --output-html /tmp/pp/index.html --title 'Site comparison'
```

`--from-dir` is read in place and never written to. Config keys: `baselineFolder`, `baselineLabel`, `currentLabel`.

## Text report

```bash
pixelpilot --report --from-dir screenshots/orig --to-dir screenshots/dev --fail-above 5
```

Prints one row per same-named PNG pair: baseline size, current size, height delta (current minus baseline), % differing pixels over the larger canvas (the missing rows of a shorter image count as differing), and the first differing row. A `bands(%)` line under each row gives the differing % per `--band-height` rows, so a layout shift shows as everything differing below one row. Diff PNGs go to `--report-dir`. Differences use the review page's pixelmatch comparison (anti-aliasing ignored), not a per-channel tolerance.

## Gotchas

- **`--extract-dir` is an output folder.** Baseline PNGs are written into it, overwriting same-named files. Point it at a scratch folder.
- **The `--manifest` option no longer exists** in the upstream version.
- The page loads images by relative path, so keep it next to its `diffs/` and `baseline/` folders.
- Errors go to stderr and exit with status 1.

## Files

- [bin/pixelpilot](../bin/pixelpilot) — launcher; calls `bin/lib/pixelpilot/cli.js`.
- `bin/lib/pixelpilot/cli.js` — argument parsing, config, git baseline extraction, output.
- `review-html.js` / `review-page.js` — the HTML page and its embedded browser-side script.
- `pixel-diff.js`, `pixelmatch.js`, `heatmap.js`, `regions.js`, `png.js`, `changed-percent-color.js` — dependency-free diffing and PNG handling.

To resync, copy these files from `plus-reporter/tools/screenshot/` and re-apply the local changes in `cli.js`: the `Usage: pixelpilot` rename, the spinner, and the folder mode, label and `--report` options. Upstream has none of these.
