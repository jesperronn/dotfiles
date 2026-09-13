# shellcheck shell=bash

# shown in reverse order
paths=(
  $HOME/.local/bin
  $HOME/.npm-global/bin
  $HOME/Library/pnpm/bin
  $DOTFILES/bin
  "/Applications/IntelliJ IDEA.app/Contents/MacOS"
  /usr/local/bin
  /opt/homebrew/bin
)

export PATH
for p in "${paths[@]}"; do
  [[ -d "$p" ]] && PATH="$p:$(path_remove "$p")"
done
unset p paths
