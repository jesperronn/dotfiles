# Mattermost Archive Script: Strategic Plan & Documentation

### 1. Primary Request and Intent
The user intends to create a robust, portable Bash script to locally archive Mattermost conversations (Public, Private, and DMs) as Markdown files. The primary goal is to bypass a server-side restriction on Personal Access Tokens (PATs) by "hijacking" the session token from the `mmctl` configuration. The long-term vision is to build a searchable, local "knowledge brain" (compatible with tools like Obsidian) that preserves chronological message flow regardless of whether users utilize proper threading.

### 2. Key Technical Concepts
* **Session Token Extraction:** Extracting the `authToken` from `~/.config/mmctl/config` to use in `curl` headers.
* **API Chronology:** Using the `/posts?since=` endpoint and `jq` sorting to reconstruct a "true" timeline of messages.
* **Slugification:** Converting human-readable channel names into safe, lowercase, ASCII filenames (e.g., `ø` -> `o`).
* **Portability:** Handling the behavioral differences between BSD `date` (macOS) and GNU `date` (Linux).
* **Subshell-safe Counting:** Using file descriptors or heredocs (`<<<`) to ensure variables like `saved_count` persist across loops.

### 3. Files and Code Sections
* **`mm_backfill.sh`**: The main executable script.
* **`~/.config/mmctl/config`**: The source of the authentication token.
* **`users.tmp`**: A temporary lookup table mapping User IDs to usernames.

**Key Logic Snippet (Slugify):**
```bash
slugify() {
    echo "$1" | iconv -c -t ascii//TRANSLIT 2>/dev/null | \
    sed -E 's/[^a-zA-Z0-9]+/_/g' | sed -E 's/(^_|_$)//g' | tr '[:upper:]' '[:lower:]'
}
```

**Key Logic Snippet (API Call):**
```bash
curl -sf -H "Authorization: Bearer $token" \
     "https://$DOMAIN/api/v4/channels/$id/posts?since=$start_ts&per_page=200"
```

### 4. Errors and Fixes
* **Error:** `date: illegal option -- d`.
    * **Fix:** Added `OSTYPE` detection to switch between macOS `date -j` and Linux `date -d`.
* **Error:** `mmctl user list --all --json` returned exit code 1 with empty stderr when run with `--strict`.
    * **Fix:** Removed `--strict` from the archive flow because the client/server version mismatch is expected on this machine and makes a valid command fail unnecessarily.
* **Error:** `mmctl` warnings were being hidden by blanket stderr redirection, which made failures hard to diagnose.
    * **Fix:** Capture `stdout` and `stderr` separately for `mmctl`, then print the real warning/error stream in verbose mode.
* **Error:** `jq: parse error: Unfinished JSON term` from the channel/post pipelines.
    * **Fix:** Split the pipeline into staged temp files so `mmctl` output is validated before `jq` parses it, and so the failing channel can be identified explicitly.
* **Error:** macOS `date -r` rejected fractional timestamps derived from Mattermost post times.
    * **Fix:** Convert post timestamps to whole seconds before formatting them.
* **Error:** `saved_count` always returns 0.
    * **Fix:** Changed pipe-based loops to `while read ... <<< "$channels"` to prevent subshell variable loss.
* **Error:** Syntax error near `)`.
    * **Fix:** Removed a stray parenthesis in the date increment function.

### 5. Problem Solving
To solve the "lack of thread discipline" among users, the script intentionally ignores the `root_id` hierarchy. Instead, it collects all posts for a 24-hour window, groups them by channel, and uses `jq -s 'sort_by(.t)'` to sort them by absolute timestamp. This "heals" the conversation by presenting it in the exact order the words were spoken, regardless of where users clicked.

### 6. All User Messages
1. "mattermost personal key how to read my conversations"
2. "Profile > security > has only "password" and not "Personal Access Tokens"?"
3. "with no access token, can I download selected conversations in another way? for instance, via the web interface?"
4. "option 1: /export > The channel export plugin requires a valid Enterprise license. option 2: i see urls like this: curl 'https://chat.stil.dk/api/v4/users/... [CURL SNIPPET] ...' You can probably shorten the url parameters for reuse later in a script"
5. "has somebody built a mattermost-cli I could use?"
6. "OK i installed mmctl and did `mmctl auth login` top 5 commands to explore my channels, new conversations, etc"
7. "favourite channels?"
8. "personal chats?"
9. "what happened the last 24 hours in mattermost?"
10. "stop. mmctl post search itd "*" --since $YESTERDAY Error: unknown flag: --since"
11. "mmctl post search itd "after:2026-04-05" [USAGE OUTPUT SHOWING NO SEARCH COMMAND]"
12. "mmctl team list [TEAM LIST OUTPUT]"
13. "I really want something that can save all conversations for a specific day... save all mattermost conversations locally as markdown... backfill local files with old conversation."
14. "i like mmctl that I log in via username/password, since server will not allow personal access tokens"
15. "mmctl auth list --json [TEXT TABLE WRAPPED IN JSON]"
16. "cat ~/.config/mmctl/config [CONFIG JSON SNIPPET]"
17. "which file structure will we save into? lets figure that out. What is your suggestion? How many files/conversations? We also want to make it possible to fetch a range of dates from/to as parameters"
18. "~/.dotfiles/bin/mm_backfill [DATE ERROR OUTPUT]"
19. "extract MM_ARCHIVE_FOLDER="$HOME/src/mattermost_archive""
20. "shebang use `#!/usr/bin/env bash` much more portable"
21. "lets add `set -euo pipefail` to this, but make START_DATE, END_DATE default to today. If START_DATE is set but END_DATE missing then default END_DATE to START_DATE"
22. "and also extract script into functions"
23. "bash template: [BASH SOURCE TEMPLATE]"
24. "--verbose doesnt work. Implement. Also no feedback on saved / updated files. I also want a --progress flag..."
25. "(perhaps slugify method to create filenames?)"
26. "~/.dotfiles/bin/mm_backfill: line 137: syntax error near unexpected token `)`"
27. "no, script still fails: ~/.dotfiles/bin/mm_backfill --verbose DEBUG: Refreshing User Map... ✖ 1"
28. "still: ~/.dotfiles/bin/mm_backfill --verbose --progress DEBUG: Refreshing User Map... ✖ 1. now, introduce method `parse_args`... introduces `pars_prereqs`... test if target directory exists."

### 7. Pending Tasks
* [ ] Implement a retry mechanism for `curl` if the API times out during large backfills.
* [ ] Handle pagination logic if a single channel exceeds 200 posts per day.
* [ ] Replace remaining brittle command pipelines with staged fetch/parse steps wherever a warning or partial response can corrupt JSON parsing.
* [ ] Add a check for "Direct Message" display names to resolve them to usernames (currently uses the `display_name` field which can be messy).
* [ ] Improve per-channel error handling so a single malformed response does not abort the whole day without context.

### 8. Current Work
Hardening the archive flow against brittle shell commands and mixed stdout/stderr behavior. The immediate focus is making `mmctl` and `jq` failures visible and attributable to the exact step that failed, while keeping the archive portable across macOS and Linux.

### 9. Optional Next Step
Transition the User Map from a flat text file to an associative array in Bash 4+ to increase lookup speed during massive archives, or add a post-processing step to create an `index.md` for each day that links to the individual channel files. Another useful follow-up would be a small retry/backoff wrapper for `curl` and a guard that treats version warnings as warnings, not fatal errors.
```
