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

# chrome shortcut
# from https://developers.google.com/web/updates/2017/04/headless-chrome
alias chrome="/Applications/Google\ Chrome.app/Contents/MacOS/Google\ Chrome"

# avoid Chromium asking for Firewall permissions on every launch of Puppeteer in Catalina
# tip from https://github.com/puppeteer/puppeteer/issues/4752#issuecomment-586599843
alias sign_puppeteer="sudo codesign --force --deep --sign - ./node_modules/puppeteer/.local-chromium/mac-*/chrome-mac/Chromium.app"

function _timestamp() {
  date '+%Y%m%dT%H%M%S'
}

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
