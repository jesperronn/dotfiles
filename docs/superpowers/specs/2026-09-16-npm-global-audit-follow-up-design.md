# npm-global-audit Follow-up Design

## Goal

Make `npm-global-audit` audit the globally installed `npm` package under npm
12's stricter remote-fetch policy, expose useful install failures, show progress
while preparing advisory details, and visually de-emphasize the `Next:` label.

## npm-specific fallback

Every package first uses the existing isolated command:

```text
npm --prefix JOB_DIR/package install --package-lock-only --ignore-scripts --no-audit SPEC
```

If and only if all of these conditions hold, retry once with
`--allow-remote=all`:

- the exact package name is `npm`;
- the first command failed; and
- its output reports `EALLOWREMOTE`.

The retry keeps the exact installed version, `--package-lock-only`,
`--ignore-scripts`, `--no-audit`, and disposable job directory. No other
package receives the relaxed setting. If the retry fails, the package remains
an install failure and the overall command exits unsuccessfully as before.

## Actionable errors

Install failures retain one useful line from npm output. Prefer the first
`npm error` line that is neither the generic `npm error` prefix nor the final
"A complete log ..." notice. Fall back to the last non-empty line only when no
actionable npm error exists. Error rows remain one terminal row and retain the
existing non-TTY format.

## Advisory-detail progress

The audit JSON already contains advisory details; this phase parses it locally
and does not perform another registry request.

After package audit progress finishes, count packages that are vulnerable and
already at their latest version. In a TTY, show one transient line:

```text
Loading vulnerability details: N/T complete
```

Update it after each package's advisory list is parsed, including packages
whose list is empty or malformed. Do not show the phase when `T` is zero. Clear
the line before printing recommendations. Redirected output receives no
progress text or ANSI controls and otherwise remains unchanged.

## `Next:` styling

When color is enabled, apply the existing dim style only to the literal
`Next:` token and immediately reset styling. Recommendation headings, package
names, advisory entries, and commands remain normally styled. Plain and
redirected output continue to contain the literal `Next:` without ANSI codes.

## Tests

All tests remain mocked and deterministic:

- an `npm@VERSION` `EALLOWREMOTE` failure retries once with
  `--allow-remote=all` and completes its audit;
- other packages and other error codes never receive the fallback;
- a failed retry displays an actionable error instead of the log-file notice;
- TTY advisory parsing advances from `0/T` through `T/T` and clears before
  `Next:`;
- redirected output contains neither the advisory progress nor ANSI controls;
- forced color dims only `Next:` and resets before the remaining text.

Run the focused test and lint commands, followed by `bin/test`. Full-repository
lint failures outside the two changed files are reported without expanding
scope.
