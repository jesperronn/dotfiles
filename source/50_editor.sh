# shellcheck shell=bash

# Editing

export EDITOR=vim

if [[ ! "$SSH_TTY" ]] && is_osx; then
  export LESSEDIT="$EDITOR ?lm+%lm -- %f"
fi

export VISUAL="$EDITOR"
