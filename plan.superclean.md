# Implementation Plan: `superclean` Bash Utility

## 1. Objective
A "one-button" maintenance script for macOS/Linux developers to reclaim disk space across major language runtimes (JS, Ruby, Go), clear IDE/system caches, and trigger decentralized project-specific cleanup hooks.

## 1.1 Current Implementation
The script already implements the following behavior:

* Runtime cleanup for npm, RVM, gems, Go, and Homebrew with dry-run estimates where practical.
* Group-scoped flags for `node`, `java`, `ruby`, `go`, `brew`, `apps`, `logs`, `hooks`, and `containers`, including `--no-*` variants.
* An upfront interactive group selector when `--interactive` is set, before any cleanup work starts.
* Deep-scan discovery across all configured roots with interactive selection, deduping, and pruning of nested targets.
* Project hook discovery and execution, including executable script hooks and project-level `Makefile` cleanup.
* Interactive multiselect support via `fzf` for groups, hooks, and deep-scan candidates, including bulk select/deselect bindings.
* Live progress rendering for deep-scan and hook execution with width-aware truncation.
* Terminal cleanup that restores cursor state without relying on saved `stty` state.

---

## 2. Script Architecture & Discovery
The script will follow a tiered execution model so it cleans the safest/highest-value areas first before moving to more expensive filesystem scans.

### Configurable Cleanup Roots
Project scanning must not assume a single folder layout. Instead, the script should support a configurable list of cleanup roots.

**Default roots:**
* `$HOME/src`
* `$HOME/projects`

**Rules:**
1. Only scan roots that actually exist.
2. Scan recursively below each root rather than assuming a fixed `*` depth.
3. Keep root configuration near the top of the script so additional paths can be added later without rewriting the scan logic.
4. Explicitly avoid descending into directories that are already marked for deletion.

### Tool Preference & Protips
* Prefer `fd` for filesystem discovery when available.
* Fallback to `find` when `fd` is not installed.
* If `fd` is not available, print:

```text
Protip: This script runs faster if you install "fd" (`brew install fd`)
```

* Prefer `fzf` for interactive multi-select review when available.
* If `fzf` is not available and `--interactive` is requested, fall back to one-at-a-time confirmation and print:

```text
Protip: Interactive cleanup is faster if you install "fzf" (`brew install fzf`)
```
* All `fzf --multi` pickers should offer bulk selection helpers (`ctrl-a` select all, `ctrl-d` deselect all) and keep the visible list focused on the meaningful columns.

### Tier 1: Global Runtime Caches (The "Easy Wins")
These commands use the tools' internal logic to safely purge their own caches.

| Language/Tool | Command | Effect |
| :--- | :--- | :--- |
| **Node/NPM** | `npm cache clean --force` | Clears the content-addressable cache. |
| **Node/NPM** | `rm -rf ~/.npm/*` | Purges leftover logs and "ghost" extractions. |
| **Ruby/RVM** | `rvm cleanup all` | Removes downloaded Ruby source, archives, and logs. |
| **Ruby/Gems** | `gem cleanup` | Uninstalls old versions of gems while keeping the latest. |
| **Go** | `go clean -cache -modcache` | Purges both build artifacts and the entire module library. |
| **Homebrew** | `brew cleanup -s` | Removes old versions of formulae and clears the download cache. |

**Notes:**
* These commands should only run if the corresponding tool exists.
* In `--dry-run` mode, report what would be executed and estimate sizes where practical, but do not mutate anything.

### Tier 2: System & IDE Artifacts
Targets heavy-duty temporary data stored by macOS and development environments.
* **JetBrains:** `rm -rf ~/Library/Caches/JetBrains/*`
* **TypeScript:** `rm -rf ~/Library/Caches/typescript/*`
* **Xcode:** `rm -rf ~/Library/Developer/Xcode/DerivedData/*`
* **Home caches:** safe home-scoped cache paths such as `~/.cache`, `~/.gradle/caches`, `~/.ivy2/cache`, `~/.pnpm-store`, and `~/.yarn/cache`
* **Browser cache (aggressive):** browser cache roots such as `~/Library/Caches/Google/Chrome` and `~/Library/Caches/BraveSoftware/Brave-Browser`
* **Dev tool cache (aggressive):** editor and test-tool caches such as VS Code, Cypress, Playwright, Yarn, Bun, and old editor caches such as Atom, if present
* **General cache wipe (aggressive):** `rm -rf ~/Library/Caches/*` (Optional/Prompted)

**Safety note:**
* The general `~/Library/Caches/*` wipe must stay optional and separately confirmed because it is much broader than the targeted cache paths above.
* Browser/editor cache cleanup is better grouped into `--aggressive` mode because applications may need to rebuild state and the reclaim can be slower.

---

## 3. Tier 3: The "Deep Scan" (Recursive Cleanup)
This phase uses a recursive "search and destroy" approach for local project folders. It must use **pruning** to avoid scanning inside folders it is about to delete.

**Primary targets:**
* `node_modules`
* `target`
* Optional: project-local `log` directories

**Explicit non-targets:**
* Do **not** generically delete `bin` directories
* Do **not** touch `.git`, `.direnv`, or other repo/control directories unless a specific cleanup command owns them

**Logic for recursive artifact discovery:**
* **Tool Preference:** Use `fd` if available; fallback to `find`.
* **The "Prune" Rule:** If a target directory is found, delete it and **do not** look inside it for more nested matches.
* The scan should run across every configured cleanup root, not just `$HOME/src`.

```bash
# Example logic for node_modules
if command -v fd >/dev/null; then
  fd -H -t d -I "^node_modules$" "$HOME/src" --prune -x rm -rf
else
  find "$HOME/src" -name "node_modules" -type d -prune -exec rm -rf {} +
fi
```

---

## 4. Tier 4: Decentralized Project Hooks
The script will look for specific files within projects to allow projects to "clean themselves."

**Registry of Cleanup Hooks:**
* `**/bin/clean`
* `**/bin/clean.sh`
* `**/bin/cleanup`
* `**/bin/cleanup.sh`
* `**/scripts/clean`
* `**/scripts/clean.sh`
* `**/scripts/cleanup`
* `**/scripts/cleanup.sh`
* Project-level `Makefile` under configured roots (trigger `make clean` only if the target exists)

**Execution scope:**
* Search recursively under each configured cleanup root.
* Derive the project root from the hook location before execution.
* Avoid duplicate execution if multiple matching hook files are found in the same project.
* Keep `Makefile` discovery narrower than generic script-hook discovery:
  * only consider project-level `Makefile`s under configured roots such as `$HOME/src` and `$HOME/projects`
  * do not treat deeply nested or vendored `Makefile`s as cleanup hooks

**Execution Logic:**
1. Discover hook candidates recursively under the configured roots.
2. For script files, check whether the file is executable (`[ -x "$file" ]`) before running it.
3. For `Makefile`, only run `make clean` if the `clean` target exists.
4. `cd` into the project root and execute the hook there.
5. In `--dry-run`, print each hook that would run instead of executing it.

---

## 5. Optional Tier 5: Aggressive Cleanup
This tier is opt-in via `--aggressive` and is reserved for cleanup that is broader, slower, more disruptive, or more likely to trigger cache rebuilds afterward.

### Candidate Actions
* Broad cache wipe: `rm -rf ~/Library/Caches/*`
* Browser/editor/dev-tool cache cleanup
* Stale app support cleanup under `~/Library/Application Support/*` for apps that are no longer installed, such as Claude
* Optional project-local `log` directory cleanup
* Maven local repository cleanup: `~/.m2/repository`
* Container cleanup via tool commands, not raw path deletion

**Container candidates:**
* `docker system prune`
* `podman system prune`

**Rules:**
1. Only run this tier when `--aggressive` is specified.
2. Always require separate confirmation prompts for broad cache wipes and container pruning.
3. Only offer tool-specific actions if the relevant tool exists.
4. Do not attempt to reclaim container storage by manually deleting Docker/Podman state directories.
5. Treat this tier as allowed to be slower than the default path.
6. Prefer to group actions here if they may require apps to rebuild caches, may disrupt active sessions, or may take a long time to scan/prune.

---

## 6. Flags, Safety Features & User Experience

### Flags
* **`-n`, `--dry-run`:** Show what would be cleaned, include sizes where possible, but do not remove anything or run any cleanup hooks.
* **`--verbose`:** Print extra progress details, such as skipped tools, missing paths, exact commands, and per-tier decisions.
* **`--interactive`:** First review which cleanup groups are enabled, then use interactive selectors for deep-scan folder candidates and project hooks where applicable.
* **`--aggressive`:** Enable slower or riskier cleanup steps, such as broad cache wipes, browser/editor cache cleanup, optional project `log` cleanup, and container pruning.

### Implemented Group Flags
The following group-scoped flags are already implemented and compose with `--interactive`, `--dry-run`, and `--verbose`:

* `--node`, `--no-node`
* `--java`, `--no-java`
* `--ruby`, `--no-ruby`
* `--go`, `--no-go`
* `--brew`, `--no-brew`
* `--apps`, `--no-apps`
* `--logs`, `--no-logs`
* `--hooks`, `--no-hooks`
* `--containers`, `--no-containers`

### Interactive Behavior
If `--interactive` is enabled:

1. Present a top-level cleanup-group selector before any cleanup work begins.
2. If `fzf` is installed, use a multiselect picker for the enabled groups with `ctrl-a`/`ctrl-d` bulk helpers.
3. For deep-scan candidates and project hooks, show the meaningful columns in the picker and keep the raw path hidden as the selected payload.
4. If `fzf` is not installed, fall back to one-at-a-time confirmation.
5. In fallback mode, print:

```text
Protip: Interactive cleanup is faster if you install "fzf" (`brew install fzf`)
```
6. Live progress for deep-scan and hook execution should stay within the terminal width, with the current path on its own line during deep-scan.

### Safety
* **Disk Space Delta:**
  * Capture `df -k` at the start.
  * Capture `df -k` at the end.
  * Output: `Total Space Reclaimed: X.XX GB`.
* **Confirmation Gates:**
  * Before the Deep Scan (Tier 3), require an explicit `y/N` confirmation unless the user is already in `--interactive` selection flow.
  * Before the broad `~/Library/Caches/*` wipe, require a separate `y/N` confirmation.
  * Before container pruning, require a separate `y/N` confirmation.
  * Aggressive actions should be clearly labeled as `AGGRESSIVE` in prompts and output.
* **Missing tool handling:**
  * Skip unavailable tools cleanly and report that in verbose mode.
* **Terminal cleanup:**
  * Clear live progress lines and restore the cursor without relying on saved `stty` state.

---

## 7. Execution Summary (Mockup)
This is illustrative only; the current implementation now prompts for cleanup groups first when `--interactive` is used, and deep-scan live progress is rendered on two lines.
```text
$ superclean
[+] Cleaning NPM cache... Done.
[+] Cleaning RVM archives... Done.
[+] Cleaning Go Modcache... Done (Reclaimed 4.2GB).
[+] Checking for Project Hooks...
    -> Found ~/src/cancerventetid/bin/cleanup... Executed.
[?] Proceed with Deep Scan of configured roots for removable project artifacts? [y/N]: y
[+] Removing 42 node_modules folders... Done.
---------------------------------------
CLEANUP COMPLETE: 12.4 GB Reclaimed.
```

---

## 8. Implementation Notes
* Implement as a standalone Bash script under `bin/superclean`.
* Implement one feature at a time rather than building the whole script in one pass.
* After each feature increment:
  * run `shellcheck`
  * add or update unit tests
  * verify the feature before moving to the next one
* Keep deletion logic centralized so `--dry-run`, `--verbose`, and `--interactive` all share the same candidate list and size calculations.
* Prefer command-driven cleanup for language/tool caches and path-driven cleanup for project artifacts.
* Structure the script so new artifact names, hook patterns, and cleanup roots can be added from a small config section near the top.

---

## 9. Roadmap Ideas
These are explicitly out of scope for the first implementation, but worth designing toward:

* Add a `--system` mode for command-driven macOS cleanup tasks only.
* `--system` should stay separate from `--apps` and should avoid raw path deletion for Apple privacy-sensitive or entitlement-sensitive app data like Safari, Photos, Music, TV, iCloud/CloudKit, Find My, Siri, and similar system-managed areas.
* `--system` should also avoid raw cleanup under `~/Library/Containers/*`; those are app sandboxes and can reset app state, sessions, permissions, or extension data.
* If container cleanup is ever added later, it should be a separate stale-orphaned-app workflow with explicit interactive confirmation, not part of normal `--system` or `--apps` cleanup.
* Likely future `--system` candidates:
  * `qlmanage -r cache` for Quick Look cache
  * `xcrun simctl delete unavailable` for stale iOS Simulator state
* `--system` should likely require `--aggressive`.
* If these flags are added later, they should compose cleanly with `--dry-run`, `--verbose`, `--interactive`, and `--aggressive`.
