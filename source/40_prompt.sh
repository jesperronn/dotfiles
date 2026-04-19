# shellcheck shell=bash

export STARSHIP_CONFIG=~/.config/starship.toml

if [[ $- == *i* ]] && [[ "${TERM:-}" != "dumb" ]]; then
  eval "$(starship init bash)"
fi
