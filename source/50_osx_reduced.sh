# shellcheck shell=bash

# OSX-only stuff. Abort if not OSX.
is_osx || return 1

# APPLE, Y U PUT /usr/bin B4 /usr/local/bin?!
# PATH="/usr/local/bin:$(path_remove /usr/local/bin)"
# export PATH


# Make 'less' more.
[[ "$(type -P lesspipe.sh)" ]] && eval "$(lesspipe.sh)"
