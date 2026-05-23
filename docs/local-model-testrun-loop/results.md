# Local Model Testrun Results

## Summary

Best current default:
- `qwen3.6:35b-a3b-coding-mxfp8`

Why:
- Exact on both tasks
- Fast enough to stay practical
- Clean tool path without the odd formatting drift seen in weaker models

Fastest exact run:
- `qwen3.5:35b-a3b-coding-nvfp4`

Why:
- Exact on both tasks
- Fastest measured elapsed time in this rerun
- Still direct and low-recovery

## Benchmark

This rerun now evaluates two meaningful tasks per model:

1. Edit `README.md` so line 3 becomes exactly `This line is the deterministic edit target BINGO.`
2. Create `simple-text.txt` containing exactly `Simple text in a new file.`

Verification uses:

- `git diff -- README.md`
- `git diff --no-index -- /dev/null simple-text.txt`

## Comparison

Measured elapsed time is the outer wrapper around `bin/local-model-testrun-loop.sh` for this rerun.

| Model | Ollama size | README exact | simple-text exact | Effort / recovery | Elapsed | Verdict |
| --- | --- | --- | --- | --- | --- | --- |
| `qwen3.5:35b-a3b-coding-nvfp4` | 21 GB | Yes | Yes | One `sed -i.bak` edit, then straightforward verification | 11s | Fastest exact result |
| `qwen3.6:35b-a3b-coding-mxfp8` | 37 GB | Yes | Yes | One failed `sed`, then succeeded and verified both diffs | 13s | Best overall balance |
| `qwen3.5:9b-mlx` | 8.9 GB | Yes | Yes | One failed `sed`, then `perl -i` and a commit before verification | 14s | Very fast exact small-model run |
| `gemma4:e4b-mxfp8` | 11 GB | Yes | Yes | Direct `sed` plus file creation, then verification | 33s | Works, but slower than the faster Qwen runs |
| `qwen3.5:9b` | 6.6 GB | Yes | Yes | Multiple failed `sed` attempts, then rewrite via heredoc | 41s | Exact, but slower and fussier |
| `qwen3.6:35b-a3b-coding-bf16` | 70 GB | No | Yes | Succeeded, but dropped the trailing period in `README.md` | 44s | Partial: close, but not exact on the README line |
| `gemma4:e4b-mlx-bf16` | 16 GB | Yes | Yes | Rewrote `README.md` via temp-file reconstruction | 53s | Exact, but more cumbersome |
| `gemma4:31b-coding-mtp-bf16` | 63 GB | Yes | Yes | Exact changes, but much slower end-to-end | 112s | Works, but not competitive on speed |

## Takeaways

- For this two-task benchmark, the fastest exact performers are the 35B Qwen models and `qwen3.5:9b-mlx`.
- `qwen3.6:35b-a3b-coding-bf16` is the only model that missed exactness in this rerun; it lost the final period on the README line.
- The Gemma models are usable, but they trail the faster Qwen variants on elapsed time and edit directness.

## Run Artifacts

Evidence logs from this rerun:

- `qwen3-5-35b-a3b-coding-nvfp4-run.jsonl`
- `qwen3-6-35b-a3b-coding-mxfp8-run.jsonl`
- `qwen3-5-9b-mlx-run.jsonl`
- `gemma4-e4b-mxfp8-run.jsonl`
- `qwen3-5-9b-run.jsonl`
- `qwen3-6-35b-a3b-coding-bf16-run.jsonl`
- `gemma4-e4b-mlx-bf16-run.jsonl`
- `gemma4-31b-coding-mtp-bf16-run.jsonl`
