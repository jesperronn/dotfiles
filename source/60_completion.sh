# shellcheck shell=bash

# SSH auto-completion based on entries in known_hosts.
# will not work on hashed host names
# if [[ -e ~/.ssh/known_hosts ]]; then
#   complete -o default -W "$(cat ~/.ssh/known_hosts | sed 's/[, ].*//' | sort | uniq | grep -v '[0-9]')" ssh scp sftp
# fi


# ssh completion (slow)
# see http://hints.macworld.com/article.php?story=20100113142633883
# complete -o default -o nospace -W "$(/usr/bin/env ruby -ne 'puts $_.split(/[,\s]+/)[1..-1].reject{|host| host.match(/\*|\?/)} if $_.match(/^\s*Host\s+/);' < $HOME/.ssh/config)" scp sftp ssh



# existing generated completion file -- to reuse
DST=~/bin/.git-completion.bash
# generate if not existing
if [ ! -f $DST ]; then
  "$DOTFILES/bin/setup/git-completion.sh"
fi
source "$DST"


# kubectl autocompletion
# existing generated completion file -- to reuse
DST=~/bin/.kubectl-completion.bash
# generate if not existing
if [ ! -f $DST ]; then
  kubectl completion bash > $DST
fi
source "$DST"



