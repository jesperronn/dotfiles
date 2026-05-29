# AI Tooling

This repo keeps the local Ollama runtime, model aliases, and agent launch path aligned across Codex and VS Code.

Current pieces:

- `Brewfile` installs `ollama`, `github.copilot-chat`, and `codex`.
- `source/91_ai_tools.sh` exports `OLLAMA_KEEP_ALIVE=30m` and `OLLAMA_CONTEXT_LENGTH=524288` for shell sessions.
- `link-file/Library/LaunchAgents/com.jesperronn.ollama-keep-alive.plist` runs `bin/verify_ollama` at login so GUI apps inherit the same Ollama env.
- `link-file/.ollama/modelfiles/*.Modelfile` defines repo-managed Ollama aliases with pinned context windows.
- `bin/local_agent` is the launcher for Codex, VS Code local-agent setup, and optional terminal-first local agents.

The recommendation in this doc is based on the local benchmark notes in:

- `docs/local-model-testrun-loop/local-model-testrun-plan.md`
- `docs/local-model-testrun-loop/results.md`

From those runs, the current best local agentic model order is:

1. `qwen3.6:35b-a3b-coding-mxfp8`
2. `qwen3.5:35b-a3b-coding-nvfp4`
3. `qwen3.5:9b-mlx`

The repo now exposes those as stable aliases:

- `qwen3.6-coding-best-64k`
- `qwen3.5-coding-fast-64k`
- `qwen3.5-coding-small-32k`

## Why keep Ollama warm?

Ollama unloads idle models by design. On a laptop, that is usually helpful, but it becomes annoying when you are bouncing between short bursts of work in:

- VS Code
- local AI extensions that talk to Ollama
- terminal commands that call `ollama`

Keeping a model warm for 30 minutes reduces repeated cold starts and makes local AI workflows feel much smoother. It is especially noticeable when switching between the editor and the terminal.

## How it works here

The login-time LaunchAgent is the part that makes this persistent for macOS GUI apps. Shell startup alone is not enough, because apps launched from the Dock do not inherit your terminal environment. `bin/verify_ollama` performs the launchd and Homebrew plist repair when you run it.

Run:

```sh
bin/verify_ollama
```

If the Homebrew Ollama plist or running service is wrong, repair it with:

```sh
bin/verify_ollama --fix
```

That command checks the current `launchctl` values and sets them to the repo defaults when needed.

If the service is already running, restart it with:

```sh
brew services restart ollama
```

If the service is stopped, start it with:

```sh
brew services start ollama
```

If you change either value later, update it in `source/91_ai_tools.sh` and rerun your dotfiles link/init step so the LaunchAgent symlink stays current.

## Shared model aliases

The reusable piece is model shape, not just process lifetime.

Different editors expose different Ollama controls. Repo-managed Modelfiles solve that by moving shared defaults into Ollama itself, then giving each client the same alias name to target.

Recommended aliases in this repo:

- `qwen3.6-coding-best-64k` from `qwen3.6:35b-a3b-coding-mxfp8` with `PARAMETER num_ctx 65536`
- `qwen3.5-coding-fast-64k` from `qwen3.5:35b-a3b-coding-nvfp4` with `PARAMETER num_ctx 65536`
- `qwen3.5-coding-small-32k` from `qwen3.5:9b-mlx` with `PARAMETER num_ctx 32768`

Older aliases such as `qwen3.6-coding-64k`, `qwen3.5-9b-32k`, and `gemma4-26b-64k` remain available for compatibility.

The linked Modelfiles live in `~/.ollama/modelfiles` after `dotfiles --link`.

Verify that the aliases already exist:

```sh
bin/verify_ollama_models
```

Create or refresh them from the linked Modelfiles:

```sh
bin/verify_ollama_models --fix
```

Point Ollama-backed tools at these alias names instead of the raw upstream tags. That keeps context size and shared defaults stable across Codex, VS Code local agents, Aider, or other OpenAI-compatible local clients.

When you want another shared alias:

1. Add a new `link-file/.ollama/modelfiles/<alias>.Modelfile`.
2. Start it with `FROM <base-model>`.
3. Add shared `PARAMETER` lines such as `num_ctx`.
4. Run `bin/verify_ollama_models --fix`.

## Agent Launch

Use the repo launcher instead of remembering raw tags:

```sh
bin/local_agent doctor --fix
bin/local_agent models
bin/local_agent codex best /path/to/project
bin/local_agent exec fast /path/to/project "review the latest diff for regressions"
bin/local_agent vscode best /path/to/project
```

What the presets mean:

- `best` is the default for agentic edits and research.
- `fast` is the better speed tradeoff when you still want a strong 35B model.
- `small` is the fallback when the bigger models are too slow or memory-heavy.

## Recommendation

For the criteria in the local edit-loop notes:

- best overall local agentic workflow: `bin/local_agent codex best`
- best low-friction terminal fallback: `bin/local_agent aider best` if you later install `aider`
- best VS Code path that does not depend on Continue: built-in VS Code local agents plus a Custom Endpoint model pointed at Ollama

The practical tradeoff is:

- Codex already proved it can do the full inspect-edit-verify loop locally against your Ollama models.
- VS Code local agents can use locally hosted BYOK models, but the built-in agent UX still asks before terminal commands, so it is not the lowest-friction path for long unattended loops.
- Continue is intentionally not the recommended path here.

## VS Code local-agent setup

1. Run `bin/local_agent doctor --fix`.
2. Run `bin/local_agent vscode-json`.
3. In VS Code, open `Chat: Manage Language Models`.
4. Add a `Custom Endpoint` provider.
5. Paste the JSON from `bin/local_agent vscode-json`.
6. Start an `Agent` session and choose `Ollama Qwen 3.6 Best (64k)`.

After changing the Ollama env, restart Ollama and any already-open VS Code windows so they pick up the new setting.
