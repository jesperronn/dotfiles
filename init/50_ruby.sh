#!/usr/bin/env bash
# Initialize my ruby via rvm

# install rvm and compile latest ruby
\curl -sSL https://get.rvm.io | bash -s stable
if [[ -s "$HOME/.rvm/scripts/rvm" ]]; then source "$HOME/.rvm/scripts/rvm" ; fi
rvm get head
rvm reload

rvm autolibs homebrew
rvm requirements
