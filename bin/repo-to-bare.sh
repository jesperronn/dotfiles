#!/usr/bin/env bash

usage() {
  echo "Usage: $0 [OPTIONS]"
  echo ""
  echo "Convert repositories to bare repositories by renaming .git directories"
  echo ""
  echo "Options:"
  echo "  --help    Show this help message and exit"
  echo ""
}

while [[ $# -gt 0 ]]; do
  case "$1" in
    --help|-h)
      usage
      exit 0
      ;;
    *)
      echo "Unknown option: $1"
      usage
      exit 1
      ;;
  esac
done

for dirname in $(find . -depth 2 -type d -name .git); do
  echo converting "$dirname":
  
  newname=$(dirname "$dirname").git
  
  cp -r "$dirname" "$newname"
  git -C "$newname" config core.bare true
done


for dirname in $(find . -depth 2 -type d -name .git); do
  rm -rf "$dirname"
done