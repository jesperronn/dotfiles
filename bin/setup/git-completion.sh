#!/usr/bin/env bash
# git-completion.sh — download git's bash completion to ~/bin/.git-completion.bash if missing.
#
# suggestions from
# http://apple.stackexchange.com/questions/55875/have-git-autocomplete-branches-at-the-command-line

SRC=https://raw.githubusercontent.com/git/git/master/contrib/completion/git-completion.bash
DST=$HOME/bin/.git-completion.bash
if [ ! -f "$DST" ]; then
  mkdir -p "$HOME/bin/"
  curl "$SRC" -o "$DST"
fi

unset $SRC
unset "$DST"
