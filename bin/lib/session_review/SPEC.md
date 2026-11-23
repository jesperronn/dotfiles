# session_review: specification

Status: describes the tool as built (2026-11). "Must" marks behaviour the tests or the design rely on; "should" marks intent that is not enforced.

`session_review` finds good, bad and unusual coding-agent sessions and lets a person pick favourites, locally and without sending tokens anywhere. It has two halves:

- **Part A, the engine** (`bin/session_review`, `bin/lib/session_review/`): reads raw session logs, scores them, prints shortlists, renders transcripts and writes the data an overview page needs.
- **Part B, the overview page** (`overview.html` plus the generated `sessions.json`, `sessions.js` and `s/<id8>.html`): a static, offline page to browse, filter, mark and export.

It is separate from `bin/agent_insights`, which writes LLM-based usage reports. The two share no code.

## Goals and non-goals

Goals
1. Zero model tokens: everything is computed from the logs with regexes and counters.
2. Harness-agnostic: one scoring and rendering pipeline; one adapter file per harness (copilot and claude exist; codex would be one more).
3. Fast enough to re-run on every change: shortlist over about 100 sessions in about 1 s; a 90 MB session loads in about 0.1 s in light mode.
4. The overview and the details pages show the same numbers and labels, so a person keeps focus when moving between them.
5. Safe to show on a projector: home paths and secret-looking strings are redacted by default.

Non-goals: judging whether an answer was correct; calling any LLM; editing or deleting the source logs; syncing marks between browsers or people.

---

# Part A: the engine

## A1. Command line

Entry: `bin/session_review <shortlist|show|overview> [options]`. `--harness copilot|claude` is optional: if absent it is inferred from `--root` (or the given path) by asking each adapter's `detect`, and falls back to copilot. An unknown harness is an error with a non-zero exit. `bin/copilot_shortlist`, `copilot_show` and `copilot_overview` are three-line shims that add `--harness copilot`.

### shortlist
Ranks sessions and prints them.

| Option | Meaning |
|---|---|
| `--root DIR` | session folder (default: the harness's standard location) |
| `--since YYYY-MM-DD` | only sessions started on or after |
| `--project TEXT` | only sessions whose working directory contains TEXT (`~` expanded) |
| `--exclude TEXT` | repeatable; also skip matching working directories |
| `--include-bench` | include benchmark and sandbox sessions, which are skipped by default (`BENCH_MARKERS` in `cli.py`) |
| `--bucket bad\|good\|outlier\|all` | which ranking to show (default `all`) |
| `--top N` | rows per bucket (default 12) |
| `--min-turns N` | skip sessions with fewer assistant turns (default 3) |
| `--format table\|tsv\|json` | output format (default `table`); `NO_COLOR` disables colour |
| `--copy DIR` | copy every listed session into DIR (created with `mkdir -p`) so `overview` can read it |
| `--recurring N` | also list sentences typed in follow-ups across at least N sessions (default 3; 0 disables) |

Must: a session listed in several buckets is copied once. Must: `--copy` only copies the files the adapter names (copilot: `workspace.yaml`, `events.jsonl`), never the rest of the harness's state.

### show
Renders one session to a self-contained HTML transcript. `session` is an id prefix, a session directory/file or an `events.jsonl` path. Options: `--root`, `--out FILE` (default `~/.cache/session_review/<id8>.html`), `--open`, `--max-result N` (characters of each tool argument or result, default 1500), `--no-redact`. Standalone `show` has key numbers, labels and timings but no star, role or notes (it belongs to no investigation). Outlier labels are not computed for a single session (`score(..., outliers=False)`), since there is nothing to compare with.

### overview
`overview SESSIONS_DIR` builds the page for a folder of copied sessions. Options: `--out DIR` (default `<sessions>/../overview`), `--name` (investigation name, default the parent folder's name), `--title`, `--max-result`, `--open`. Outputs:

- `index.html`: a copy of `overview.html`, unchanged.
- `sessions.json` and `sessions.js` (`window.OVERVIEW = <same JSON>`): `file://` pages cannot fetch JSON, so the page reads the `.js` copy.
- `s/<id8>.html`: one details page per session.

Must: two passes. Pass one loads every session, computes metrics and scores (outlier cut-offs are relative to this folder); pass two renders the details pages, which need those scores. Must: the same metrics feed `sessions.json` and the details pages.

## A2. Normalised model and adapters
The contract is `model.py` and must not be duplicated here. In short: a session is a dict with identity, project, client, start and end, usage, code changes, counters and an ordered event list. Events are `user`, `assistant`, `tool` or `marker` (`abort|error|compaction|end`). An adapter provides `NAME`, `DEFAULT_ROOT`, `detect`, `discover`, `peek`, `load(path, sid, full)`, `copy`, and optionally `EXTRA_LABELS` and `extra_signals`.

Rules for adapters
- Light load (`full=False`) skips assistant text and tool results. Everything a label or score needs must still be present in light mode, and labels must come out identical in both modes. This is why structural labels ignore assistant prose.
- `peek` must be cheap (no event parsing) because filters run on every session.
- A harness without a concept (for example Claude has no clean-shutdown record) returns `None` for it. `None` must not be treated as a crash.
- Tool calls count once: paired by call id where the harness has one; an id-less start is never deduplicated.
- Sub-agent sidechains are skipped (claude) or counted in `counts["subagents"]` (copilot).

Copilot reads `~/.copilot/session-state/<uuid>/{workspace.yaml,events.jsonl}` and uses `session.shutdown` for token details, code changes and premium requests. Claude reads `~/.claude/projects/<dir>/<uuid>.jsonl`, deduplicates by message id and estimates code changes from tool inputs. The older `~/.copilot/history-session-state/` format is not supported.

## A3. Metrics
`metrics.compute` turns a session into a flat metrics dict: user and assistant turn counts, tool calls and errors, aborts, compactions, session errors, subagents, code lines added and removed, total tokens (input plus output, cached re-reads excluded), timings, loop count, corrections, re-prompts, and the structural flags below.

- **Active time**: the sum of gaps between consecutive events that are at most 600 s (`IDLE_GAP_SECONDS`). Longer gaps count as away time. A wall-clock span of days must never be reported as work time.
- **Timings** (`metrics.timings`): wall clock, active time split into agent, you and away, per-prompt agent runs, longest and median run.
- **Loop**: the same tool call with identical arguments 4 or more times, ignoring the adapter's `ignore_tools`.
- **Correction**: a follow-up under 600 characters matching `CORRECTION_PATTERN` (English and Danish).
- **Re-prompt**: a follow-up whose word set has Jaccard similarity of at least 0.6 with an earlier message (messages with fewer than 5 words are ignored).
- **Project name**: the last path part of the working directory with a trailing `-wt` removed, so a worktree folds into its repository. Known limitation: two different repositories with a same-named folder merge.

## A4. Scoring and labels
Three scores per session, all additive and deterministic.

- **bad** (higher is worse): tool errors (0.5 each, capped at 30), error rate times 20 when there are 10 or more calls, 4 per loop, 3 per correction (capped at 8), 4 per re-prompt (capped at 6), 3 per abort, 3 per session error, +6 if the harness recorded a crash, +5 if abandoned, 2 per compaction, plus adapter signals, plus 8 for burning top-5% tokens with no lines added.
- **good** (higher is better): +6 not crashed and not abandoned, +6 any lines added, +4 for 3 or fewer prompts, +3 for 5 or more tool calls, small tie-break for lines and calls, −6 for trivial sessions (under 10 lines or under 10 tool calls), minus 0.7 times bad.
- **out** (outlier): +3 each for top-5% tokens, active minutes, turns or tool calls (the 95th percentile of the analysed folder), +2 for 3 or more subagents, +2 for 2000 or more added lines, plus adapter signals.

Labels are objects `{name, text, sentiment, help}`: `name` is the stable key, `text` the display form with counts (for example `tool-loop x2 (max 6)`), `sentiment` is `neg`, `pos` or empty, `help` is one sentence. Metadata lives in `metrics.LABELS` and each adapter's `EXTRA_LABELS`; the page contains no label knowledge of its own.

- At most 8 scored labels per session (`MAX_LABELS`), negative first, then adapter, positive, outlier.
- Structural labels `starts-handoff`, `ends-handoff`, `ends-plan` are neutral, add no score points, and are appended after the cap so they cannot be pushed out. They look at the first message (600 characters) and at the user messages and tool calls in the last 12 events; `plan` matches as a whole word.
- `clean-run` requires good above 8, at least 10 lines added and bad below 4.
- Outlier labels depend on the folder analysed, so the same session can be an outlier in one folder and not in another. This is intended.

## A5. Transcript rendering (the details page)
One self-contained HTML file per session; no network access; works from `file://`.

Layout: a header (title from the first prompt, subtitle with project, client, date, prompt count, tool calls and failures), the key numbers (msgs, tokens, err as failed/total, bad, good, out) and label chips exactly as in the list, the timings summary, then a sticky left menu and the transcript.

- Left menu: `toggle tool calls` checkbox first (sticky, checked means tool calls are shown), then one link per user prompt. A prompt that looks like a correction is highlighted.
- Each user message shows its time, "agent worked Xm Ys" for the run that followed it, and a "possible correction" badge.
- Tool calls are collapsed `<details>` elements, red when failed, with arguments and result truncated to `--max-result`. Consecutive tool calls form one run. When tool calls are hidden, each run is replaced by a dim centred line `— tool calls × N —`.
- Markers (abort, error, compaction, end) appear inline as dim lines.
- Marks (only when built by `overview`): favourite star, role (bad, good, outlier, none), tags and a note. They read and write the same browser storage entry as the overview and stay in sync across open tabs (see B5).
- Redaction (default): the home directory becomes `~`, and strings that look like keys, tokens, bearer headers or passwords are replaced. `--no-redact` turns this off. Redaction is best effort and not a security boundary; review a page before sharing it.
- Narrow screens (under 800 px): the left menu is hidden.

## A6. Quality requirements
- Hermetic tests: `bin/session_review.test.sh`, `bin/session_review_claude.test.sh` and the `copilot_*.test.sh` files build fixtures in a temp folder, use no network and no real host state, and run in about 1 s each. Every assertion prints `[PASS]`.
- `bin/lint` covers the shell scripts; the Python files are not linted by it.
- Adding an adapter requires a colocated test with a fixture of that harness's format.

---

# Part B: the overview page

A single static `overview.html`, no build step, no external requests, no framework. It works from a web server (`http://127.0.0.1:8765` via `bin/serve`) and, apart from the embedded-browser caveat below, from `file://`.

## B1. Data contract
`window.OVERVIEW = {meta, sessions}`.

- `meta`: `name` (investigation name), `title`, `from` and `to` (earliest and latest session date), `harnesses`, `metricTips` (one sentence per column), `generated` (UTC timestamp).
- `sessions[]`: `id`, `id8`, `harness`, `date`, `project`, `client`, `userTurns`, `turns`, `minutes`, `tokens`, `toolCalls`, `toolErrors`, `added`, `removed`, `bad`, `good`, `outlier`, `labels[]` (as in A4), `prompt` (first prompt, redacted), `link` (relative path to the details page).

Must: the page derives column help, label sentiment and label explanations only from this data. Must: an empty `sessions` array renders an empty list, not an error.

## B2. List
Header: the title, with the date range small and dim next to it, and a count line "N shown · M ★ of T".

One row per session, in a multi-column grid (not a table), two lines per row:
- Line one: star, number, project, first prompt (a link to the details page), then the figures date, msgs, tokens, err, bad, good, out, each with a small dim label. The project column is as wide as the longest project name, up to a limit; longer names are cut with an ellipsis.
- Line two: role pill, label chips, tag chips (`#tag`) and the note preview.

Clicking a row, but not a link, star or chip, opens an inline edit panel with client, id, turns, active minutes and line changes, the role buttons, a tags field and a note field. Rows with a star have a tinted background.

Label chips carry a small sentiment dot (negative, neutral, positive). Counts inside a label's text (for example the 2 in `x2`) are dimmed. Hover and selected states use tint and border weight, never inverted colours, and transition over 0.35 s with a 0.1 s delay on entry (CSS variables `--hover-ms`, `--hover-delay`, `--hover-ease`). Hovering a label or tag highlights every chip with the same value.

## B3. Sorting, filtering, search
- Sort pills in one row: date, msgs, tokens, err, bad, good, out. Clicking sorts descending; clicking the active pill again, or double-clicking, reverses. Ties break on id so order is stable.
- Selecting a label filter appends a sort pill for that label, which sorts by the number in the label (a session without the label counts as 0). It is added but not applied until clicked. Deselecting the label removes the pill and falls back to `bad`.
- Filters: all or favourites only; project (multiple allowed); label (multiple allowed, a session matches if it has any of the selected labels). Clicking a label chip anywhere in the list toggles that label filter. A clear button resets project and label filters and shows how many filters are active.
- A free-text box searches prompt, project, label text, notes and tags.
- Tooltips: every column heading, pill and label explains itself in one sentence from the data.
- Why pills and not dropdowns: native `<select>` popups do not work in Claude's sidebar browser.

## B4. Keyboard
`j` and `k` move the highlight down and up through the visible rows (a left-edge bar marks the current row, the page scrolls to keep it in view); the first `j` selects the top row, the first `k` the bottom one. `s` toggles the star on the current row. Keys are ignored while typing in an input, textarea, select or dialog and with Ctrl, Cmd or Alt held. When the current row disappears (unstarred in the favourites view, or filtered out) the highlight stays at the same position in the list.

## B5. Persistence
All in the browser's `localStorage`, per origin, wrapped in try/catch so the page works with storage blocked.

| Key | Content | Exported |
|---|---|---|
| `session_review_v1:<name>` | `{ "<session id>": {fav, role, tags, note} }`; empty entries are removed | yes |
| `session_review_v1:<name>:view` | `{onlyFav, labels[]}`: the all or favourites choice and the selected label filters; labels that no longer exist are dropped on load | no |

- The overview and its details pages share the first key because they share an origin. A `storage` event keeps open tabs in sync.
- Different investigations never share marks because `<name>` is part of the key.
- Not remembered: project filter, sort order, search text.
- Storage is lost when the browser data is cleared, so the page must offer export.

## B6. Export and import
- Export, JSON: the whole marks object. Import merges: imported entries replace local entries with the same session id, nothing else is touched.
- Export, Markdown: a readable list of favourites only, with role, id, project, date, first prompt, labels, tags and note.
- Invalid JSON on import shows an alert and changes nothing.

## B7. Accessibility and appearance
Light and dark mode through `prefers-color-scheme`. Colour is never the only carrier of meaning: sentiment dots have a tooltip word, roles are written out. Desktop layout first; narrow widths should still work but are not tuned. Target: usable with 150 sessions, with every interaction re-rendering the list in well under 100 ms.

## B8. Known gaps
- Tags are not clickable filters.
- Project and sort are not remembered.
- Enter does not open the details page from the keyboard.
- The project name ignores parent folders, so nested same-name folders in different repositories merge.
- Only copilot and claude sessions are supported.
- Marks cannot be shared between people or machines except by export and import.
