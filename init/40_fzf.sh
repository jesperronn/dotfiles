#!/usr/bin/env bash
# see https://github.com/junegunn/fzf#using-homebrew-or-linuxbrew
$(brew --prefix)/opt/fzf/install

# see https://github.com/junegunn/fzf#respecting-gitignore
export FZF_DEFAULT_COMMAND='rg --files'
# To apply the command to CTRL-T as well
export FZF_CTRL_T_COMMAND="${FZF_DEFAULT_COMMAND}"

