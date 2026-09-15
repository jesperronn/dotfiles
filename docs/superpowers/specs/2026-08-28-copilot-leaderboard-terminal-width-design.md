# copilot-leaderboard terminal-width design

## Goal

Keep end-of-month Copilot leaderboard output readable in narrow terminal windows
by reducing the table's fixed-width overhead and avoiding wrapped lines.

## Behavior

- Render each leaderboard table with columns in this order: `Total`, daily
  columns, then `User`.
- Rename the `Month total` heading to `Total`.
- Preserve the Markdown report written to the archive, including its content
  and ANSI styling behavior.
- When stdout is an interactive terminal and the rendered output is wider than
  the terminal, display the output through `less -S` so long lines are chopped
  rather than wrapped.
- Write captured, redirected, or piped output directly, without invoking a
  pager.
- If `less` is unavailable, fall back to direct output rather than losing the
  report.

## Testing

- Assert that `Total` is present and `Month total` is absent.
- Assert that the first table column is `Total` and the final column is `User`.
- Use a fake pager and a narrow terminal width to verify `less -S` is used only
  when needed.
- Keep existing report-file and data-rendering assertions unchanged.
