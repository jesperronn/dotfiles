# shellcheck shell=bash

paths=(
  $HOME/.local/bin
  $DOTFILES/bin
  "/Applications/IntelliJ IDEA.app/Contents/MacOS"
  /usr/local/bin
)

export PATH
for p in "${paths[@]}"; do
  [[ -d "$p" ]] && PATH="$p:$(path_remove "$p")"
done
unset p paths
