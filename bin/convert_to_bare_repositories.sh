#!/usr/bin/env bash

for dirname in `find . -depth 2 -type d -name .git`; do
  echo converting $dirname:
  
  newname=$(dirname "$dirname").git
  
  cp -r $dirname $newname
  git -C $newname config core.bare true
done


for dirname in `find . -depth 2 -type d -name .git`; do
  rm -rf $dirname
done