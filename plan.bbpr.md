# Plan: `bbpr` — Bitbucket Pull Request CLI

Tool: `bin/bbpr` (bash)
Server: Atlassian Bitbucket Server v9.4.16 @ `https://stash.stil.dk/rest/api/1.0/`
Auth: `op item get "BITBUCKET_TOKEN_JRJ" --fields label=token --reveal` → `Authorization: Bearer <token>`

---

## 1. Subcommands

| Command | Endpoint(s) | Description |
|---|---|---|
| `ping` | `GET /rest/api/1.0/myself` (fallback `/rest/api/1.0/users/current`) | Auth check. Prints HTTP status + authenticated user slug, display name, active flag. |
| `mine` | `GET /pull-requests?state=OPEN` → filter `participants[].role==AUTHOR && user.slug==current` | Open PRs I authored |
| `review` | `GET /pull-requests?state=OPEN` → filter `participants[].role==REVIEWER` | Open PRs I'm a reviewer on |
| `open` | `GET /pull-requests?state=OPEN` (no filter) | All open PRs |
| `show PROJ/REPO#NNN` | `GET /pull-requests/{id}` + `GET /pull-requests/{id}/comments` | Full detail: title, author, src/dst ref, participants w/ approval state, all comments |
| `comments PROJ/REPO#NNN` | `GET /pull-requests/{id}/comments?state=RESOLVED` + `GET /pull-requests/{id}/blocker-comments` | Unresolved comments only — resolved (awaiting re-check) + blocker (v9.4 "unresolved/important") |

### `ping` (adjustment B)

Output:
```
[200] https://stash.stil.dk/rest/api/1.0/myself
  slug=jesper.rasmussen  name=Jesper Rasmussen  active=true
```

Quick auth verification. Returns non-zero on HTTP error.

### `comments` unresolved filter (adjustment A)

Two API calls, combined output:

1. `GET /pull-requests/{id}/comments?state=RESOLVED` — resolved comments awaiting re-check after fix.
2. `GET /pull-requests/{id}/blocker-comments` — v9.4 blocker (unresolved) comments.

Both paginated (`start`/`limit`), both include nested `comments[]` for thread replies.

Human output example:
```
PR #42: "Fix auth timeout" (stil/DIGITAL-1234)
  State: OPEN  |  Author: lars.jensen  |  Created: 2026-08-10

  BLOCKER comments (unresolved):
    [meta.andersen] src/auth.py:15-18  (ADDED)
      "Can we also handle timeout=0?"
      → reply [lars.jensen]: "Handled in commit abc123"

  RESOLVED comments (awaiting re-check):
    [meta.andersen] src/auth.py:42
      "LGTM, one nit on the test setup."
      resolved by [meta.andersen] 2026-08-12
```

---

## 2. JSON output

`--json` on any command emits:

```json
{
  "id": 42,
  "title": "Fix auth timeout",
  "state": "OPEN",
  "author": {"slug": "lars.jensen", "displayName": "Lars Jensen"},
  "created": "2026-08-10T...",
  "reviewers": [
    {"slug": "meta.andersen", "status": "APPROVED", "approved": true}
  ],
  "comments": [
    {
      "id": 101,
      "type": "blocker",
      "state": "OPEN",
      "author": {"slug": "..."},
      "text": "...",
      "anchor": {"file": "src/auth.py", "line": 15, "lineType": "ADDED"},
      "resolvedDate": null,
      "replies": [...]
    }
  ]
}
```

---

## 3. API specifics (v9.4 swagger confirmed)

| Concern | Detail |
|---|---|
| Base path | `/rest/api/1.0/` (server's "latest" alias) |
| Auth | `Authorization: Bearer <token>` |
| PR listing filter | `state=OPEN` (server-side); reviewer/auth filter clientside on `participants[]` |
| Comment listing filter | `state=OPEN\|PENDING\|RESOLVED`, `anchorState=...` |
| Blocker comments | Dedicated endpoint `/pull-requests/{id}/blocker-comments` (v9.4) |
| Pagination | `start`/`limit` + `isLastPage`/`nextPageStart` on all list endpoints |

---

## 4. Technical notes

- No server-side `author=` or `reviewer=` filter on the PR listing endpoint — filter clientside on `participants[].role` and `participants[].user.slug`.
- All list endpoints paginate; the tool loops until `isLastPage == true`.
- Global options: `--base-url <url>` (override), `--token <token>` (override), `--json` (machine output), `-h/--help`.
- Token resolved from `op` unless `--token` given.

---

## 5. Files

```
bin/bbpr                         # The tool (~300-400 lines)
bin/tests/test_bbpr.sh           # Smoke tests (ping, error paths, parse helpers)
```

---

## 6. Acceptance criteria

- `bbpr ping` returns `0` on valid token, non-zero on 401/403, prints user slug + HTTP status.
- `bbpr mine` / `review` / `open` produce a human-readable table (no `--json`) or JSON (`--json`).
- `bbpr show PROJ/REPO#NNN` prints full PR detail including participants' approval state.
- `bbpr comments PROJ/REPO#NNN` outputs only unresolved (blocker + resolved) comments, both human and `--json`.
- All API calls handle pagination correctly (multiple pages).
- `bash -n` clean, no syntax errors.

---

Pending review: any missing subcommand, wrong endpoint mapping, or format preference before I build?
