# shellcheck shell=bash

alias pgrep='ps -ef | grep $1'
alias pse='ps -e -o pid,command'

alias dcompose='docker compose'
alias dcheck='/Applications/Docker.app/Contents/MacOS/com.docker.diagnose check'

#shows top 10 used terms from history
#from http://stackoverflow.com/questions/68372/what-is-your-single-most-favorite-command-line-trick-using-bash#68390
alias tophist="history | awk '{print \$4}' | awk 'BEGIN{FS=\"|\"}{print \$1}' | sort | uniq -c | sort -n | tail | sort -nr"

# GPG requirement from https://help.github.com/articles/telling-git-about-your-gpg-key/
# test if needed with `echo "test" | gpg --clearsign`
export GPG_TTY=$(tty)

# avoid Chromium asking for Firewall permissions on every launch of Puppeteer in Catalina
# tip from https://github.com/puppeteer/puppeteer/issues/4752#issuecomment-586599843
alias sign_puppeteer="sudo codesign --force --deep --sign - ./node_modules/puppeteer/.local-chromium/mac-*/chrome-mac/Chromium.app"

# Flush Directory Service cache
alias flush="dscacheutil -flushcache"

function _timestamp() {
  date '+%Y%m%dT%H%M%S'
}

# convert unix timestamp (in seconds or milliseconds) to ISO 8601 format
# usage examples:
#   ts2iso 1672531199000
#    echo 1672531199000 | ts2iso
_ts2human(){
  local ts input
  if [ -n "$1" ]; then
    input="$1"
  elif [ ! -t 0 ]; then
    input="$(cat)"
  else
    input="$(date +%s%3N)"
  fi
  ts="$(echo "$input" | tr -d '\n')"
  local len=${#ts}
  if [ $len -ge 13 ]; then
    s=$((ts/1000))
    ms=$(printf "%03d" $((ts%1000)))
  else
    s=$ts
    ms="000"
  fi
  date -r $s +"%Y-%m-%dT%H:%M:%S" | awk -v ms="$ms" '{print $0 "." ms "+" strftime("%z", s)}'
}
alias ts2human='_ts2human'


function _calc_backup_filename(){
  set -u
  file=$1
  set +u
  ext="${file##*.}"
  filename="${file%.*}"

  echo "${filename}-$(_timestamp).${ext}"
}

function mv_date() {
  set -u
  file=$1
  set +u
  mv -v "$file" "$(_calc_backup_filename "$file" )"
}

function cp_date() {
  set -u
  file=$1
  set +u
  cp -v "$file" "$(_calc_backup_filename "$file" )"
}

# Git aliases with '!' execute in a subshell, so cd commands only affect that subshell
# and don't persist to the parent shell. These must be shell functions instead.
function cdroot() {
  cd "$(git rev-parse --show-toplevel)" || return 1
}

# Trace a symlink path through all its hops to the final destination
trace_link() {
    local target="$1"
    while [ -L "$target" ]; do
        ls -ld "$target"
        target=$(readlink "$target")
    done
    ls -ld "$target"
}
