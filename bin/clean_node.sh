#!/usr/bin/env bash

#
# clean_node:
# remove all the node_modules folders from given root folder where
# script is executed
#
# By Alejandro Soto, 2016
# Modified 1.1 by Jesper 2018-05

echo
echo "node_modules remover v1.1"
echo

pushd $1

for i in $(find . -name node_modules -d 3 -type d); do
  if [ $(grep -o "node_modules" <<<"$i" | wc -l) == 1 ]
  then
    echo "$(du -sh $i)"
    read -p "Delete Y/N ? " -n 1 -r
    echo
    if [[ $REPLY =~ ^[Yy]$ ]]
    then
      rm -r $i
      echo "deleted"
    fi
  fi
done


##
## TODO
## summarize the size of the files/folders removed at the end of the execution
##
