# shellcheck shell=bash

alias k='kubectl'
alias vi='nvim'
alias vim='nvim'
alias lzd='lazydocker'
alias lzg='lazygit'


# Cisco vpn credentials can be fired from command line. copy this file
# and use it like this:
# /opt/cisco/secureclient/bin/vpn connect lev-vpn-fw.regionh.dk -s < ~.ssh/.credentials.regionh
#
# tip from https://apple.stackexchange.com/a/260928/3403
# and https://superuser.com/questions/649614/connect-using-anyconnect-from-command-line
alias vpn='/opt/cisco/secureclient/bin/vpn'
alias vpndisconnect='vpn disconnect'
alias vpnconnect_regionh='vpn connect lev-vpn-fw.regionh.dk -s < ~/.ssh/.credentials.regionh'

# lang settings, view with `locale` or `locale -a`
# export LANG=da_DK.UTF-8
export LANG=en_US.UTF-8
export LC_ALL=en_US.UTF-8

# for homebrew upgrade, always remove old versions:
# If --cleanup is specified or HOMEBREW_INSTALL_CLEANUP is set then remove
#     previously installed version(s) of upgraded formulae.
export HOMEBREW_INSTALL_CLEANUP=true
# The GitHub credentials in the macOS keychain may be invalid.
# Clear them with:
#   printf "protocol=https\nhost=github.com\n" | git credential-osxkeychain erase
# Or create a personal access token:
#   https://github.com/settings/tokens/new?scopes=gist,public_repo&description=Homebrew
# and then set the token as: export HOMEBREW_GITHUB_API_TOKEN="your_new_token"
# Github api for homebrew

# homebrew API token (for `brew search` and similar commands)
