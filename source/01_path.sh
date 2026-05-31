# shellcheck shell=bash

# shown in reverse order
paths=(
  /opt/homebrew/bin
  $HOME/.local/bin
  $HOME/.npm-global/bin
  $HOME/Library/pnpm/bin
  $DOTFILES/bin
  "/Applications/IntelliJ IDEA.app/Contents/MacOS"
  /usr/local/bin
  /opt/workbrew/bin
)

export PATH
for p in "${paths[@]}"; do
  [[ -d "$p" ]] && PATH="$p:$(path_remove "$p")"
done
unset p paths
