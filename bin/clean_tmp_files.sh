#!/usr/bin/env bash

set -x

yarn cache clean
brew cleanup 
rvm cleanup all

rm -rf $TMPDIR
rm -rf ~/Library/Caches/Google/Chrome/Default/Cache
rm -rf ~/Library/Caches/Google/Chrome/Default/Media\ Cache/
rm -rf ~/Library/Application\ Support/Atom/Cache/

find ~/src -d 3 -type d -name "node_modules" -exec rm -rf '{}' +
find ~/src -d 4 -type d -name "target" -exec rm -rf '{}' +
find ~/src -d 3 -type d -name "log" -exec rm -rf '{}' +
