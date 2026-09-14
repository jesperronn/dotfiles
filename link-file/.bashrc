# shellcheck shell=bash

# Where the magic happens.
export DOTFILES=~/src/dotfiles

if [[ -n "$HOME" && ( "$CODEX_SANDBOX" == "true" || "$TERM" == "dumb" ) ]]; then
  export XDG_CACHE_HOME="${XDG_CACHE_HOME:-/tmp/$(whoami)_cache}"
  export BUNDLE_USER_HOME="${BUNDLE_USER_HOME:-/tmp/$(whoami)_bundle}"
  export PATH="$HOME/.rvm/bin:$PATH"
  export rvm_shell_arity="${rvm_shell_arity:-1}"
  export rvm_tar_command="${rvm_tar_command:-tar}"

  # Keep agent/sandbox/non-interactive shells out of the real ~/.bash_history:
  # without this they share HISTFILE with interactive terminals, and since
  # histappend is never enabled here, exiting one of these shells overwrites
  # (rather than appends to) the shared file. Cheap exports only — do not add
  # starship/rvm-scripts here, that previously blocked agent tool calls.
  export HISTFILE="${XDG_CACHE_HOME}/bash_history_agent"
  shopt -s histappend

  source "$DOTFILES/source/00_dotfiles.sh"
  source "$DOTFILES/source/90_env_variables.sh"
  source "$DOTFILES/source/01_path.sh"
  source "$DOTFILES/source/60_ruby.sh"
  return
fi

eval "$(/opt/workbrew/bin/brew shellenv)"

# Source all files in "source"
function src() {
  local file
  if [[ "$1" ]]; then
    source "$DOTFILES/source/$1.sh"
  else
    for file in $DOTFILES/source/*.sh; do
      # timings for load of start script performance/benchmark -- use __bashrc_bench=1:
      # $ __bashrc_bench=1 bash -i
      if [[ $__bashrc_bench ]]; then
        TIMEFORMAT="$file: %R"
        time . "$file"
        unset TIMEFORMAT
      else
        . "$file"
      fi
    done
  fi
}

# Run dotfiles script, then source.
function dotfiles() {
  $DOTFILES/bin/dotfiles "$@" && src
}

src

# pnpm
export PNPM_HOME="$HOME/Library/pnpm"
case ":$PATH:" in
  *":$PNPM_HOME/bin:"*) ;;
  *) export PATH="$PNPM_HOME/bin:$PATH" ;;
esac
# pnpm end

# Added by LM Studio CLI tool (lms)
export PATH="$PATH:/Users/jesper/.lmstudio/bin"

# Claude Code local-model routing — revisit and fine-tune 2026-08-09.
# Uncomment to route subagents / the main session through a local runner
# (opencode + omlx on :4000, LM Studio on :1234 — see project memory
# "local-agent-runners" for the traps in each).
# export CLAUDE_CODE_SUBAGENT_MODEL=Ornith-1.0-35B-4bit
# export ANTHROPIC_MODEL=Ornith-1.0-35B-4bit
# export ANTHROPIC_SMALL_FAST_MODEL=Ornith-1.0-9B-4bit
# export ANTHROPIC_BASE_URL=http://localhost:4000/v1
# export ANTHROPIC_AUTH_TOKEN=local-no-auth-required
