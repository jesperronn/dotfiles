# shellcheck shell=bash

[ -f ~/.fzf.bash ] && source ~/.fzf.bash

# git integration: https://github.com/junegunn/fzf-git.sh/blob/main/README.md
# List of bindings
#
# CTRL-G CTRL-F for Files
# CTRL-G CTRL-B for Branches
# CTRL-G CTRL-T for Tags
# CTRL-G CTRL-R for Remotes
# CTRL-G CTRL-H for commit Hashes
# CTRL-G CTRL-S for Stashes
# CTRL-G CTRL-L for reflogs
# CTRL-G CTRL-W for Worktrees
# CTRL-G CTRL-E for Each ref (git for-each-ref)
# ⚠️ You may have issues with these bindings in the following cases:
#
# CTRL-G CTRL-B will not work if CTRL-B is used as the tmux prefix
# CTRL-G CTRL-S will not work if flow control is enabled, CTRL-S will freeze the terminal instead
# (stty -ixon will disable it)
# To workaround the problems, you can use CTRL-G {key} instead of CTRL-G CTRL-{KEY}.
#
# ⚠️ If zsh's KEYTIMEOUT is too small (e.g. 1), you may not be able to hit two keys in time.
#
# Inside fzf
#
# TAB or SHIFT-TAB to select multiple objects
# CTRL-/ to change preview window layout
# CTRL-O to open the object in the web browser (in GitHub URL scheme)
#
SRC=https://raw.githubusercontent.com/junegunn/fzf-git.sh/main/fzf-git.sh
DST=$HOME/bin/.fzf-git.sh
if [[ ! -f "${DST}" ]];
then
  mkdir -p $HOME/bin/
  curl -s "$SRC" -o "${DST}"
  chmod +x "${DST}"
fi

[[ -f "${DST}" ]] && source "${DST}"

unset SRC DST


