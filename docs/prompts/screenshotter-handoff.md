# Handoff: write a Playwright screenshotter script

> DRAFT for review. Paste everything below the line into any project.

---

## Goal

Write **one plain, sequential Playwright script** that drives this app through a wide series of
scenarios and saves a numbered PNG for each. The screenshots document the app and later serve as a
visual baseline, so breadth matters: cover most user-facing functionality, with emphasis on
**JavaScript-driven interaction**, not just static pages.

Scope is the script only. Do **not** build runners, servers, DB reset tooling, diffing or review
UIs. Assume the app is already running and seeded; the script takes its URL from env.

## Companion files

Hand these off together with this prompt and use them as the template for structure and
conventions (swap in this project's routes and selectors, keep the shape):
`screenshotter-example/screenshots.spec.js` and `screenshotter-example/playwright.config.js`.

## Deliverables

1. `playwright/screenshots.spec.js` (CommonJS, `@playwright/test`).
2. `playwright.config.js` if missing: `workers: 1`, `fullyParallel: false`, `retries: 0`,
   `timeout: 120000`, fixed viewport (1440x1200), `baseURL` from `SCREENSHOT_BASE_URL` /
   `PLAYWRIGHT_BASE_URL` (default `http://127.0.0.1:3000`), `screenshot/video: 'off'`.
3. Add `@playwright/test` as a devDependency only if absent, using the project's package manager.
4. A short "Capturing screenshots" note in the project's README or docs (3-5 lines).

## Script structure (follow the companion spec)

- One `test('captures the screenshot suite', ...)` with `test.describe.configure({ mode: 'serial' })`.
- A `scenarios` array of `{ file: '07-add-row.png', capture: captureAddRow }`, numbered in the
  order a user would explore the app. Use `NNb-` suffixes for variants of the same screen.
- One small `async function captureX(page)` per scenario. No page-object framework, no abstractions
  beyond tiny helpers (`login`, `shot`, `waitForIdle`).
- The loop runs scenarios in order, logs `Capturing <file>...`, **catches per-scenario errors**,
  keeps going, and at the end prints a success/failure summary and fails the test if any scenario
  failed. A broken scenario must never stop the rest.
- Output dir from `SCREENSHOT_OUTPUT_DIR` (default `docs/screenshots`), created with `mkdirSync`.
- Credentials from env (`SCREENSHOT_EMAIL`, `SCREENSHOT_PASSWORD`) with defaults read from the
  project's seed data. Never hardcode real secrets.

## What to cover

First explore the app (routes, views/templates, JS controllers/components, seed data) and write a
checklist of interactive features. Then capture, per area, **before and after** the interaction:

- **Dynamic lists/forms:** add row, remove row, add several, reorder, inline edit, dependent fields
  appearing/disappearing, repeated nested rows.
- **Menus and overlays:** navigation dropdowns, user menu, context/kebab menus, tooltips, popovers,
  modals/dialogs (open state), drawers, confirm dialogs (open, never confirm destructive ones).
- **Pickers:** datepicker open (and one with a date selected), select2/combobox/autocomplete with
  options expanded, typeahead suggestions, color/file pickers where feasible.
- **Hidden information:** accordions, tabs, collapsibles, "show more", expandable table rows,
  details/summary, toggles, history/audit panels.
- **Validation and states:** invalid form submit with errors, empty state, loading state, flash/toast
  messages, disabled vs enabled buttons after input.
- **Lists:** search with results, filters applied, sort changed, pagination page 2.
- **Responsive:** a narrow (mobile ~390px) variant of key screens, incl. the opened mobile menu.
- **Auth/roles:** login page, and key screens as other roles if the seed data has them.

Aim for **30-60 screenshots** depending on app size; prefer many small focused scenarios over a few
giant ones. If a feature cannot be reached from seed data, say so in the summary rather than faking it.

## Rules for reliable, deterministic shots

- Wait on **state, not time**: `locator.waitFor`, `expect(...).toBeVisible()`, `waitForLoadState`.
  Avoid bare `waitForTimeout` except for CSS animations (<=300ms, commented why).
- Disable animations/caret for stability (`animations: 'disabled'`, `caret: 'hide'` on screenshot).
- Use `fullPage: true` for pages; for overlays/menus capture the viewport (or the element) so the
  open state is visible. Scroll the interactive element into view first.
- Prefer role/label/test-id locators over CSS paths.
- Each scenario gets a fresh browser context and sets up its own starting state so scenarios don't depend on the
  previous one's leftovers. Don't mutate persistent data in ways that break later scenarios; if a
  scenario saves data, do it last or against throwaway records.
- Mask or avoid volatile content (clocks, random ids). Note any remaining nondeterminism.
- Local/test environments only. No real external services.

## Verification (required before you say done)

1. Run the script against the running app and paste the **actual console output** (the
   `Capturing ...` lines plus the summary).
2. List the generated files (`ls -1 $SCREENSHOT_OUTPUT_DIR | wc -l` and the names).
3. Open at least 5 representative PNGs (interactive ones: an opened menu, datepicker, added row)
   and confirm the interaction is actually visible in each, not just the page behind it.
4. Run it twice; report whether any output differs in an obvious, avoidable way.
5. Run the project's linter on the touched files and commit (small, conventional commit).

If something fails, report it plainly with the output; do not claim success.

## Final report

Short table: file, what it shows, interaction performed. Then: features **not** covered and why.
