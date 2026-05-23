# Local Model Testrun Results

## Summary

Best current default:
- `qwen3.6:35b-a3b-coding-mxfp8`

Why:
- Exact successful edit and diff verification
- Low-effort tool path
- Strong speed relative to the other accurate models

Fastest model with comparable accuracy:
- `qwen3.5:35b-a3b-coding-nvfp4`

Why:
- Also produced the exact requested tracked diff
- Finished faster than the two larger 35B alternatives in the same harness
- Needed one macOS `sed -i ''` recovery, but otherwise stayed direct

## Comparison

Single-run wall-clock timings below come from the same local harness in `local-model-testrun-loop.sh`.

| Model | Ollama size | Exact final edit | Effort / recovery | Single-run wall time | Verdict |
| --- | --- | --- | --- | --- | --- |
| `qwen3.5:35b-a3b-coding-nvfp4` | 21 GB | Yes | 2 failed `sed` attempts, then successful `ed` edit and `git diff` verification | 38.58s | Fastest confirmed isolated good result so far |
| `qwen3.6:35b-a3b-coding-mxfp8` | 37 GB | Yes | Multiple failed `sed` attempts, then direct Python rewrite and `git diff` verification | 105.14s | Best overall balance despite a messier isolated rerun |
| `qwen3.6:35b-a3b-coding-bf16` | 70 GB | Yes | Failed Linux-style `sed`, then succeeded with macOS `sed -i ''` and verified with `git diff` | 36.21s | Accurate isolated result and now the fastest successful rerun in this set |
| `qwen3.5:9b-mlx` | 8.9 GB | Yes | Failed `sed` and `perl`, then recovered with `awk` and verified with `git diff` | 92.89s | Working isolated MLX edit agent, but clearly weaker and slower than the best Qwen models |
| `qwen3.5:9b` | 6.6 GB | Yes | Failed `sed -i`, then rewrote `README.md` with a heredoc and verified with `git diff` | 128.80s | Works when isolated, but slow and still less direct than the stronger Qwen models |
| `gemma4:e4b-mxfp8` | 11 GB | Yes | Failed `sed -i`, then recovered with an `awk` rewrite and `git diff` verification | 116.87s | Works, but slower and more verbose than the stronger Qwen models |
| `gemma4:e4b-mlx-bf16` | 16 GB | Yes | Failed `sed -i`, then recovered by reconstructing the file with `head`/`tail` and `git diff` verification | 157.00s | Works, but slower and more cumbersome than the smaller Gemma MXFP8 run |
| `gemma4:31b-coding-mtp-bf16` | 63 GB | Yes | Failed `sed c` form, then recovered with a simpler `sed ... > README.tmp && mv` rewrite and `git diff` verification | 109.58s | Accurate, but still slower and more cumbersome than the stronger Qwen models |
| `hf.co/Jackrong/Qwopus3.5-9B-Coder-GGUF:Q4_K_M` | 6.6 GB | No run reached tool use | Isolated rerun also failed before tool use with a high-demand turn failure | 29.81s to failure | Not currently usable through this Codex+Ollama path |
| `qwen3.5:0.8b-mlx` | 1.2 GB | No | Long confused run, repeated bad tool choices, never reached a file edit | 347.73s | Too weak and too slow for this edit-agent loop |

Interpretation:
- If two models are comparably accurate, prefer `qwen3.5:35b-a3b-coding-nvfp4` or isolated `qwen3.6:35b-a3b-coding-bf16` before the slower Gemma variants.
- `qwen3.6:35b-a3b-coding-mxfp8` remains the safest default because it still produced the exact diff reliably, even though the isolated rerun was slower and messier than the earlier shared-workspace run.
- `qwen3.6:35b-a3b-coding-bf16` is now more competitive after the isolated rerun, but `qwen3.6:35b-a3b-coding-mxfp8` still looks like the safer default on balance.
- `qwen3.5:9b` is now a verified isolated success, but it remains a weak practical choice because it is much slower and less direct than the stronger models.
- `qwen3.5:9b-mlx` is a legitimate working local edit agent now, but the isolated rerun was much slower and needed more recovery than the stronger Qwen models.
- `gemma4:e4b-mxfp8` is usable, but its isolated rerun was much slower than its size suggests and the tool behavior was more verbose than the stronger Qwen models.
- `gemma4:e4b-mlx-bf16` also works, but it is slower than `gemma4:e4b-mxfp8` and did not show better edit behavior.
- `gemma4:31b-coding-mtp-bf16` works, but even the cleaner isolated rerun is still slower and less attractive than the stronger Qwen options.

## Successful runs

- Model: `qwen3.6:35b-a3b-coding-mxfp8`
- Outcome: successful tracked-file edit of `README.md`
- Evidence log: `qwen3-6-35b-a3b-coding-mxfp8-run.jsonl`
- Final message: `qwen3-6-35b-a3b-coding-mxfp8-last.txt`

Observed tool behavior:
- Read `README.md` with `cat -n README.md`
- Failed repeatedly with `sed`
- Inspected file metadata with `file`, `wc`, and `xxd`
- Recovered with a direct Python line rewrite
- Verified with `git diff -- README.md`

- Model: `gemma4:31b-coding-mtp-bf16`
- Outcome: successful tracked-file edit of `README.md`
- Evidence log: `gemma4-31b-coding-mtp-bf16-run.jsonl`
- Final message: `gemma4-31b-coding-mtp-bf16-last.txt`

Observed tool behavior:
- Inspected repo with `cat README.md`
- Failed once with a `sed '3c\...'` form
- Recovered with `sed '3s/.../' README.md > README.tmp && mv README.tmp README.md`
- Verified with `git diff -- README.md`

- Model: `qwen3.6:35b-a3b-coding-bf16`
- Outcome: successful tracked-file edit of `README.md`
- Evidence log: `qwen3-6-35b-a3b-coding-bf16-run.jsonl`
- Final message: `qwen3-6-35b-a3b-coding-bf16-last.txt`

Observed tool behavior:
- Read `README.md` with `cat -n README.md`
- First tried Linux-style `sed -i` and failed
- Recovered cleanly with macOS `sed -i ''`
- Verified with `git diff -- README.md`

- Model: `qwen3.5:35b-a3b-coding-nvfp4`
- Outcome: successful tracked-file edit of `README.md`
- Evidence log: `qwen3-5-35b-a3b-coding-nvfp4-run.jsonl`
- Final message: `qwen3-5-35b-a3b-coding-nvfp4-last.txt`

Observed tool behavior:
- Inspected repo state and `README.md` with shell
- Failed twice with `sed`
- Recovered with an `ed`-based line replacement
- Verified inline with `git diff -- README.md`

Verified diff:

```diff
-This line is the deterministic edit target.
+This line is the deterministic edit target BINGO.
```

- Model: `qwen3.5:9b-mlx`
- Outcome: successful tracked-file edit of `README.md`
- Evidence log: `qwen3-5-9b-mlx-run.jsonl`
- Final message: `qwen3-5-9b-mlx-last.txt`

Observed tool behavior:
- Read `README.md`, then confirmed line 3 separately
- Failed with both `sed` and `perl`
- Recovered with an `awk` rewrite of line 3
- Verified the tracked change with `git diff -- README.md`

Verified diff:

```diff
-This line is the deterministic edit target.
+This line is the deterministic edit target BINGO.
```

- Model: `qwen3.5:9b`
- Outcome: successful tracked-file edit of `README.md` in the isolated timed rerun
- Evidence log: `qwen3-5-9b-run.jsonl`
- Final message: `qwen3-5-9b-last.txt`

Observed tool behavior:
- Read `README.md` first
- Failed once with `sed -i`
- Rewrote `README.md` with a heredoc
- Verified the tracked change with `git diff -- README.md`

Verified diff:

```diff
-This line is the deterministic edit target.
+This line is the deterministic edit target BINGO.
```

- Model: `gemma4:e4b-mxfp8`
- Outcome: successful tracked-file edit of `README.md`
- Evidence log: `gemma4-e4b-mxfp8-run.jsonl`
- Final message: `gemma4-e4b-mxfp8-last.txt`

Observed tool behavior:
- Read `README.md` first
- Failed with `sed -i`
- Recovered with an `awk` rewrite of line 3
- Verified the tracked change with `git diff -- README.md`

Verified diff:

```diff
-This line is the deterministic edit target.
+This line is the deterministic edit target BINGO.
```

- Model: `gemma4:e4b-mlx-bf16`
- Outcome: successful tracked-file edit of `README.md`
- Evidence log: `gemma4-e4b-mlx-bf16-run.jsonl`
- Final message: `gemma4-e4b-mlx-bf16-last.txt`

Observed tool behavior:
- Inspected the repo with `ls -F`
- Failed once with `sed -i`
- Recovered by rebuilding `README.md` line 3 with `head`/`tail` into a temp file
- Verified the tracked change with `git diff -- README.md`

Verified diff:

```diff
-This line is the deterministic edit target.
+This line is the deterministic edit target BINGO.
```

## Earlier failed-but-useful run

- Model: `qwen3.5:9b`
- Outcome: earlier shared-workspace run entered the tool loop, but was unreliable

Observed issues:
- First attempted unsupported `apply_patch`
- Needed multiple retries to adapt to macOS shell differences
- Got confused when the repo had no initial commit because `git diff README.md` is empty for untracked files

Interpretation:
- The isolated runner improved this model’s classification from “not recommended” to “works, but weak”

## Imported GGUF that did not work in this path

- Model: `hf.co/Jackrong/Qwopus3.5-9B-Coder-GGUF:Q4_K_M`
- Outcome: imported into Ollama successfully, but did not complete a single Codex turn

Observed issues:
- Both test runs failed before any tool call or file edit
- Failure mode was repeated sampling disconnects and `We're currently experiencing high demand` errors
- `README.md` remained unchanged after both attempts
- Isolated rerun evidence: `hf-co-Jackrong-Qwopus3-5-9B-Coder-GGUF-Q4KM-run.jsonl`

Interpretation:
- This looks like a current Codex+Ollama compatibility/runtime problem for this imported Hugging Face model tag, not a proven file-edit failure inside the agent loop
- It should not be treated as a working local edit-agent candidate until it can finish at least one full turn

## MLX models tested

- Model: `qwen3.5:0.8b-mlx`
- Outcome: completed a turn, but failed the edit task

Observed issues:
- Spent most of the turn attempting invalid tool flows and broken `write_stdin` retries
- Only reached plain file inspection very late in the run
- Did not perform any edit command
- `README.md` remained unchanged
- Rerun wall time from log timestamps: `347.73s`

Interpretation:
- This model is too weak for the current Codex edit-agent loop, even though it can produce a long turn

- Model: `qwen3.5:9b-mlx`
- Outcome: successful tracked-file edit of `README.md`

Observed behavior:
- Reached the file-edit task directly after a short inspection step
- Needed multiple recovery steps after `sed` and `perl` failed
- Completed the exact requested diff and verified it with `git diff -- README.md`

Interpretation:
- This is now a working MLX-based local edit agent
- It is usable, but still clearly behind `qwen3.5:35b-a3b-coding-nvfp4`, `qwen3.6:35b-a3b-coding-mxfp8`, and even isolated `qwen3.5:9b` on effort and speed

## Current local edit-agent set

- `qwen3.6:35b-a3b-coding-mxfp8`
- `gemma4:31b-coding-mtp-bf16`
- `qwen3.6:35b-a3b-coding-bf16`
- `qwen3.5:35b-a3b-coding-nvfp4`
- `qwen3.5:9b`
- `qwen3.5:9b-mlx`
- `gemma4:e4b-mxfp8`
- `gemma4:e4b-mlx-bf16`

## Recommended order

1. `qwen3.6:35b-a3b-coding-mxfp8`
2. `qwen3.5:35b-a3b-coding-nvfp4`
3. `qwen3.6:35b-a3b-coding-bf16`
4. `qwen3.5:9b`
5. `qwen3.5:9b-mlx`
6. `gemma4:e4b-mxfp8`
7. `gemma4:e4b-mlx-bf16`
8. `gemma4:31b-coding-mtp-bf16`

## Re-run

```sh
chmod +x ./local-model-testrun-loop.sh
./local-model-testrun-loop.sh
```

Troubleshooting helper:

```sh
python3 ./local-model-testrun-inspect.py ./qwen35-9b-mlx-run.jsonl
```
