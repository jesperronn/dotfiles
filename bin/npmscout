#!/bin/bash

# Scan for JavaScript packages in package-lock.json files

# Usage: npmscout.sh [--packages name1,name2,...] [folder]
#
# Searches all package-lock.json files in the given folder (defaults to current directory)
# and prints a table of matches for the specified packages.
#
# Options:
#   -h, --help                 Show this help message
#   -p, --packages  LIST       Comma-separated list of package names to search for
#                              (e.g. "keyv,cachable,@types/node")

usage() {
    cat <<EOF
Usage: $(basename "$0") [options] [folder]

Scan package-lock.json files for specific JavaScript packages.

Options:
  -h, --help                 Show this help message
  -p, --packages  LIST       Comma-separated list of package names to search for
                             (e.g. "keyv,cachable,@types/node")

Arguments:
  folder                     Root folder to scan. Defaults to current directory.

Examples:
  $(basename "$0")                                    # scan current dir, default packages
  $(basename "$0") --packages keyv,cachable           # scan current dir, specific packages
  $(basename "$0") /path/to/repo --packages lodash    # scan specific repo, specific package
  $(basename "$0") --packages @types/node,.eslintrc    # scoped packages supported
EOF
    exit 0
}

PACKAGES=""
FOLDER="."

while [[ $# -gt 0 ]]; do
    case "$1" in
        -h|--help)
            usage
            shift
            ;;
        -p|--packages)
            if [[ $# -lt 2 ]]; then
                echo "Error: --packages requires a comma-separated list of package names" >&2
                exit 1
            fi
            PACKAGES="$2"
            shift 2
            ;;
        *)
            if [[ "$FOLDER" == "." ]]; then
                FOLDER="$1"
            else
                echo "Error: Unexpected argument: $1" >&2
                usage
            fi
            shift
            ;;
    esac
done

if [[ -z "$PACKAGES" ]]; then
    PACKAGES="keyv cachable"
fi

# Convert comma-separated to space-separated
SPACE_PACKAGES=$(echo "$PACKAGES" | tr ',' ' ')

RESULT=()

while IFS= read -r lock; do
  echo "DEBUG: Found lock file: $lock" >&2
  lockDir=$(dirname "$lock")
  project=${lockDir#$FOLDER/}

  for pkg in $SPACE_PACKAGES; do
    echo "DEBUG: Looking for package: $pkg" >&2
    ver=$(node -e "
      const f = require('${lock}');
      const pkgName = '${pkg}';
      const nodeModulesKey = 'node_modules/' + pkgName;
      const entry = (f.packages && f.packages[nodeModulesKey]) || null;
      if (entry && entry.version) console.log(entry.version);
    " 2>&1)
    echo "DEBUG: Version from node: '$ver'" >&2

    if [[ -n "$ver" ]]; then
      RESULT+=("$project | $pkg | $ver | $lock")
    fi
  done
done < <(find "$FOLDER" -name "package-lock.json" 2>/dev/null)

if [[ ${#RESULT[@]} -eq 0 ]]; then
  echo "No matching packages found in package-lock.json files."
  exit 0
fi

echo "Project | Package | Version | Path"
echo "--------|---------|---------|------"
for r in "${RESULT[@]}"; do
  IFS="|" read -r project pkg ver path <<<"$r"
  echo "$project | $pkg | $ver | $path"
done
