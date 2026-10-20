#!/usr/bin/env bash
# repo-to-bare.sh — make ./<repo>.git bare copies of ./<repo>/.git, then drop the originals.

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

while IFS= read -r -d '' dirname; do
  echo converting "$dirname":
  
  newname=$(dirname "$dirname").git
  
  cp -r "$dirname" "$newname"
  git -C "$newname" config core.bare true
done < <(find . -depth 2 -type d -name .git -print0)


while IFS= read -r -d '' dirname; do
  rm -rf "$dirname"
done < <(find . -depth 2 -type d -name .git -print0)