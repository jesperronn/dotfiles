# Local Model Testrun Loop Plan

## Goal

Build a repeatable local verification loop that proves whether a local model agent using Ollama can:

- inspect a tiny git repo with tools
- make one deterministic file edit
- verify the exact tracked diff
- finish without human intervention

This plan is for agentic repository editing, not general chat quality.

## What “Success” Means

A model passes the loop when all of the following are true:

- the runner targets the intended local Ollama model.
- The model uses tools to inspect the repo.
- The model edits only `README.md`.
- The resulting tracked diff is exactly the requested one-line change.
- The model verifies the change with `git diff -- README.md`.
- The run finishes within a bounded time budget.

In practice, local success did not depend on `apply_patch`. The reliable success shape was:

- inspect with shell
- edit with shell
- verify with `git diff -- README.md`

## Repository Layout

Use a tiny dedicated sandbox repo. In this workspace it lives at:

- [sandbox/codex-edit-loop](../../sandbox/codex-edit-loop)

Minimum contents:

- `README.md`
- `AGENTS.md`
- git initialized with an initial commit

Recommended `README.md`:

```md
# Local Model Testrun Sandbox

This line is the deterministic edit target.

The agent should make one tiny verified change.
```

Recommended `AGENTS.md`:

```md
# Agent Instructions

- This repo is only for local-model-testrun-loop verification.
- Keep changes tiny and deterministic.
- Prefer direct repository edits over long explanations.
- Verify the exact diff before finishing.
- Unless the prompt says otherwise, edit only `README.md`.
```

## Helper Files

The current working helpers are:

- runner: [local-model-testrun-loop.sh](../../bin/local-model-testrun-loop.sh)
- log inspector: [local-model-testrun-inspect.py](../../bin/local-model-testrun-inspect.py)
- experiment results: [results.md](../../docs/local-model-testrun-loop/results.md)

If starting from scratch elsewhere, recreate equivalents of those files.

## Runner Design

The runner should do all of this automatically:

1. Stop any currently loaded Ollama model before starting a new run.
2. Create a fresh isolated clone of the sandbox repo for the model run.
3. Run `codex exec` against that isolated clone.
4. Capture:
   - cleaned JSON-only `.jsonl`
   - last agent message
5. Enforce a timeout so weak models cannot stall the test matrix.
6. Print the final tracked diff from the isolated clone.

Isolation matters. Earlier shared-repo runs interfered with each other when stale sessions were still alive.

## Current Runner

The current runner already implements the above:

```sh
bash ../bin/local-model-testrun-loop.sh MODEL_NAME [TIMEOUT_SECONDS]
```

Examples:

```sh
bash ../bin/local-model-testrun-loop.sh qwen3.5:35b-a3b-coding-nvfp4
bash ../bin/local-model-testrun-loop.sh qwen3.6:35b-a3b-coding-mxfp8 240
```

The runner currently writes files like:

- `MODEL-SLUG-run.jsonl`
- `MODEL-SLUG-last.txt`

and creates temporary isolated worktrees under:

- `$TMPDIR/local-model-testrun-loop/runs/`

## Prompt Contract

Use a prompt that is explicit, deterministic, and verification-oriented.

Current prompt used by the runner:

```text
You are in a tiny git repo for local-model-testrun-loop verification. Use shell commands to inspect the repo, then make two exact changes: edit README.md so line 3 becomes exactly: This line is the deterministic edit target BINGO. Then create a new file named simple-text.txt containing exactly: Simple text in a new file. Do not use apply_patch. Verify the README change with git diff -- README.md and verify the new file with git diff --no-index -- /dev/null simple-text.txt before finishing. Keep the final response to one short sentence.
```

This prompt is better than a vague “add BINGO” prompt because it:

- specifies the exact final line
- adds a second deterministic file-creation task
- forbids `apply_patch`
- requires explicit diff verification for the tracked README change and the new file
- constrains the final response

## Recommended End-to-End Procedure

### 1. Confirm local model availability

```sh
ollama list
```

### 2. Run one model

```sh
bash ../bin/local-model-testrun-loop.sh qwen3.5:35b-a3b-coding-nvfp4 240
```

### 3. Inspect the cleaned result

```sh
python3 ../bin/local-model-testrun-inspect.py \
  ../tmp/local-model-testrun-loop/runs/qwen3-5-35b-a3b-coding-nvfp4-run.jsonl
```

### 4. Judge the run

Check:

- did it inspect the repo?
- did it make both exact changes?
- did it verify with `git diff -- README.md` and `git diff --no-index -- /dev/null simple-text.txt`?
- how many recovery steps did it need?
- how long did it take?

### 5. Record the result

Update:

- [results.md](../docs/local-model-testrun-loop/results.md)

Recommended fields to track per model:

- model name
- Ollama size
- exact final edit: yes/no
- effort / recovery behavior
- single-run wall time
- verdict

## Log Handling

### Important reality

`codex exec --json` does not produce pure JSONL in practice. The runner filters the mixed output and only keeps the JSON lines.

Typical noise:

```text
WARN codex_otel::events::session_telemetry: ... tag value contains invalid characters: qwen3.5:9b-mlx
```

These warnings are emitted by Codex telemetry, not by Ollama. They are noisy but did not block successful edit-loop runs.

### Recommended approach

Keep the filtered JSON-only log for structured analysis. The current runner discards the raw log after filtering.

### Inspect a filtered log

Use:

```sh
python3 ../bin/local-model-testrun-inspect.py \
  ../tmp/local-model-testrun-loop/runs/MODEL-SLUG-run.jsonl
```

That helper:

- ignores non-JSON warning lines
- counts telemetry warning noise
- estimates wall time from timestamps
- prints reasoning items
- prints command executions
- prints final message
- prints token usage

### If you want to strip telemetry warnings from saved `.jsonl` files

Preview:

```sh
rg -n 'WARN codex_otel::events::session_telemetry:' ../tmp/local-model-testrun-loop/runs/*.jsonl
```

Rewrite with backups:

```sh
perl -i.bak -ne 'print unless /WARN codex_otel::events::session_telemetry:/' ../tmp/local-model-testrun-loop/runs/*.jsonl
```

### If you just want to ignore the warnings during analysis

Do not mutate the files. Use the helper script and treat only JSON lines as authoritative.

## Practical Constraints Learned From Real Runs

- macOS shell behavior matters. Many models first tried Linux-style `sed -i` and failed.
- Smaller models can be dramatically worse at tool use even when they can talk at length.
- A model may claim success in its last message while leaving the file unchanged. Always trust the diff, not the prose.
- Shared mutable workspaces are a trap. Use isolated clones per run.
- Timeout protection is mandatory if you want to benchmark several local models in a row.
- For this task, shell competence is more important than elegant patch formatting.

## Recommended Evaluation Heuristics

Rank models primarily by:

1. exactness of final diff
2. number of recovery steps
3. wall-clock speed
4. behavioral directness

When two models are comparably accurate, prefer the faster/smaller one.

## Known Good and Bad Outcomes So Far

The latest running summary is in:

- [results.md](../docs/local-model-testrun-loop/results.md)

At the time of this plan update, the strongest practical defaults from prior experiments are:

- `qwen3.6:35b-a3b-coding-mxfp8`
- `qwen3.5:35b-a3b-coding-nvfp4`

Also proven workable:

- `qwen3.6:35b-a3b-coding-bf16`
- `qwen3.5:9b-mlx`
- `gemma4:e4b-mxfp8`
- `gemma4:31b-coding-mtp-bf16`

Known weak or failing cases so far include:

- `qwen3.5:0.8b-mlx`
- `qwen3.5:9b`
- `hf.co/Jackrong/Qwopus3.5-9B-Coder-GGUF:Q4_K_M`

Treat [results.md](../docs/local-model-testrun-loop/results.md) as the source of truth for the latest rankings and timings.

## How A Fresh Agent Should Proceed

If starting from scratch, the agent should:

1. Create the tiny sandbox repo with `README.md`, `AGENTS.md`, and an initial git commit.
2. Create a runner equivalent to [local-model-testrun-loop.sh](../bin/local-model-testrun-loop.sh).
3. Create a log parser equivalent to [local-model-testrun-inspect.py](../bin/local-model-testrun-inspect.py).
4. Run one known-good model first to verify the loop itself.
5. Once the loop is trustworthy, test additional models one at a time.
6. Record results after each run in a structured summary like [results.md](../docs/local-model-testrun-loop/results.md).

Suggested first validation model:

- `qwen3.5:35b-a3b-coding-nvfp4`

Suggested second validation model:

- `qwen3.6:35b-a3b-coding-mxfp8`

Those two are good initial checks because they have already demonstrated real local edit-loop success.

## Minimal Fresh-Start Checklist

```sh
ollama list
cd ../sandbox/codex-edit-loop
bash ../bin/local-model-testrun-loop.sh qwen3.5:35b-a3b-coding-nvfp4 240
python3 ../bin/local-model-testrun-inspect.py ../tmp/local-model-testrun-loop/runs/qwen3-5-35b-a3b-coding-nvfp4-run.jsonl
```

If that succeeds and the diff is exact, the local verification loop is working and can be used to test any additional Ollama model.
