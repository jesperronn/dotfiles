# shellcheck shell=bash

# Ollama defaults used by shells, launchd, and the Homebrew service.
# Keep these aligned with bin/verify_ollama so GUI apps and terminal sessions
# see the same server settings.

export OLLAMA_KEEP_ALIVE="${OLLAMA_KEEP_ALIVE:-30m}"
export OLLAMA_CONTEXT_LENGTH="${OLLAMA_CONTEXT_LENGTH:-524288}"
# Concurrent predictions per loaded model — lets several editor windows / agents
# (e.g. Cline in two VS Code windows, or an orchestrator + sub-agents) share one
# loaded model without queueing. Ollama exposes this globally; LM Studio does
# not (set --parallel at load time via lms-serve below).
export OLLAMA_NUM_PARALLEL="${OLLAMA_NUM_PARALLEL:-4}"

# LM Studio load defaults, consumed by lms-serve. LM Studio has no global env or
# CLI default for context/parallel, so we set them explicitly at load time.
export LMS_CTX="${LMS_CTX:-65536}"        # context window for agentic coding
export LMS_PARALLEL="${LMS_PARALLEL:-4}"  # concurrent slots (multi-editor/agent)
export LMS_TTL="${LMS_TTL:-3600}"         # auto-unload after idle seconds

# Launch aider against LM Studio. Picks model interactively via fzf,
# or use the first argument as the model key to skip the prompt.
# Usage: aider-lms [model-key] [aider-args...]
aider-lms() {
  local model="$1"
  if [[ -z "$model" ]]; then
    model=$(lms ls --json --llm 2>/dev/null \
      | python3 -c "import json,sys; [print(m['modelKey']) for m in json.load(sys.stdin)]" \
      | fzf --prompt="LM Studio model> ")
    [[ -z "$model" ]] && return 1
  else
    shift
  fi
  aider \
    --openai-api-base http://localhost:1234/v1 \
    --openai-api-key lm-studio \
    --model "openai/$model" \
    "$@"
}

# Load a model into LM Studio tuned for concurrent editor/agent sessions:
# large context (LMS_CTX) + parallel slots (LMS_PARALLEL) + idle TTL (LMS_TTL).
# Editor extensions (Cline, Continue) JIT-load via the API and would otherwise
# get LM Studio's small default context and no concurrency; pre-loading here
# means those extensions reuse this tuned instance instead of auto-loading a
# stingy one. Picks the model via fzf if no key is given.
# Usage: lms-serve [model-key]   (env overrides: LMS_CTX, LMS_PARALLEL, LMS_TTL)
lms-serve() {
  local model="$1"
  if [[ -z "$model" ]]; then
    model=$(lms ls --json --llm 2>/dev/null \
      | python3 -c "import json,sys; [print(m['modelKey']) for m in json.load(sys.stdin)]" \
      | fzf --prompt="LM Studio model> ")
    [[ -z "$model" ]] && return 1
  fi
  lms load "$model" \
    --context-length "$LMS_CTX" \
    --parallel "$LMS_PARALLEL" \
    --ttl "$LMS_TTL" \
    --yes
}
