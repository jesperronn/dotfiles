# shellcheck shell=bash

# Where the magic happens.
export DOTFILES=~/.dotfiles

if [[ -n "$HOME" && ( "$CODEX_SANDBOX" == "true" || "$TERM" == "dumb" ) ]]; then
  export XDG_CACHE_HOME="${XDG_CACHE_HOME:-/tmp/$(whoami)_cache}"
  export BUNDLE_USER_HOME="${BUNDLE_USER_HOME:-/tmp/$(whoami)_bundle}"
  export PATH="$HOME/.rvm/bin:$PATH"
  export rvm_shell_arity="${rvm_shell_arity:-1}"
  export rvm_tar_command="${rvm_tar_command:-tar}"

  source "$DOTFILES/source/00_dotfiles.sh"
  source "$DOTFILES/source/90_env_variables.sh"
  source "$DOTFILES/source/01_path.sh"
  source "$DOTFILES/source/60_ruby.sh"
  return
fi

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


eval "$(/opt/workbrew/bin/brew shellenv)"


src

# pnpm
export PNPM_HOME="$HOME/Library/pnpm"
case ":$PATH:" in
  *":$PNPM_HOME:"*) ;;
  *) export PATH="$PNPM_HOME:$PATH" ;;
esac
# pnpm end
