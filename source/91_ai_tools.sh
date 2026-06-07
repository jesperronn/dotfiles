# shellcheck shell=bash

# Ollama defaults used by shells, launchd, and the Homebrew service.
# Keep these aligned with bin/verify_ollama so GUI apps and terminal sessions
# see the same server settings.

export OLLAMA_KEEP_ALIVE="${OLLAMA_KEEP_ALIVE:-30m}"
export OLLAMA_CONTEXT_LENGTH="${OLLAMA_CONTEXT_LENGTH:-524288}"

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
