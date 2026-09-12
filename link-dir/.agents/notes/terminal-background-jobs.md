# Terminal tool: background jobs are unreliable across calls

Symptom: a build/push/long-running command is started with a background flag
(even wrapped in `nohup ... & disown`), but it silently dies partway through -
no error in its own output - shortly after a *different*, unrelated terminal
command runs (including one the user cancels, or a plain `sleep`/`ps` used
just to poll progress).

Observed while running a real multi-arch `podman`/`buildah` build+push
(`docker manifest push` over a slow link): the background job kept dying after
1-2 unrelated foreground calls, even though `nohup`/`disown` should protect
against the shell's own `SIGHUP`.

Root cause (best guess): the terminal tool's underlying session/pty appears to
get torn down or signaled between some tool calls in a way that also reaps
still-running background children, regardless of `nohup`/`disown`. This is a
tooling limitation, not a shell scripting mistake.

## Workaround

- Run long operations as a **single blocking foreground command** rather than
  backgrounding + polling with separate tool calls. Foreground calls that ran
  start-to-finish in one shot completed reliably every time.
- If a foreground call risks the tool's own hard timeout (observed at ~5
  minutes / 300s), **break the work into smaller idempotent chunks**, each
  comfortably under the limit, run as separate foreground calls (e.g. one call
  per registry tag pushed, instead of one call looping over all tags).
- Avoid long `sleep N` polling loops split across multiple tool calls - each
  poll is itself a new command that can kill the thing you're waiting on. If
  you must poll, prefer fewer/shorter waits, and treat any backgrounded job as
  disposable across calls.
- Design scripts so expensive steps (e.g. uploading blobs to a registry) are
  naturally idempotent/resumable across chunked invocations - don't assume a
  scratch/local object (like a podman manifest list) survives a previous step;
  recreate it cheaply from stable inputs (local image IDs, digests) at the
  start of each chunk instead.

