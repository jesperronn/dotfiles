#!/usr/bin/env bash
#
# this file is a template for bash scripts
# it provides common functions and a standard structure for bash scripts
#
# curl -L --silent --remote-name https://gist.githubusercontent.com/jesperronn/c06371a3a2685af1a5eab71f543e09a5/raw/bash-template.sh && chmod +x bash-template.sh
#
# Agents can use this template to create new bash scripts quickly and easily.
#
# Format, there are 3 main sections:
# section #1. Header: shebang, set -euo pipefail, pushd to script dir, fixed variables
# section #2. Functions: usage, parse_args, check_program, check_prereqs
# section #3. Specific functions
# section #4. Main: run_main function

# start section #1 - euo pipefail, pushd, fixed variables
set -euo pipefail

pushd "$(dirname "$0")/.." > /dev/null || exit 1

# fixed variables go here
# color variables
C_0="\e[0m"
C_BOLD="\e[1m"
C_RED="\e[31m"
C_GREEN="\e[32m"
C_ORANGE="\e[38;5;202m"
C_CYAN="\e[36m"
C_DIM="\e[37m"
# other variables
VERBOSE=0

# start section #2. Functions: usage, parse_args, check_program, check_prereqs
function usage() {
  cat <<EOF
Usage: $0 [options] [environment]
Options:
  -h, --help       Show this help message and exit
  -v, --verbose    Enable extra verbose output
EOF
}

function parse_args() {
  while [[ $# -gt 0 ]]
  do
    case "$1" in
      -h|--help)
        usage
        exit 0
        ;;
      -v|--verbose)
        VERBOSE=1
        debug "Verbose mode enabled"
        ;;
      *)
        echo "Unknown option: $1"
        usage
        exit 1
        ;;
    esac
    shift
  done
}

# debug helper: prints only when VERBOSE is enabled
debug() {
  # Print the provided message(s) with escape sequences interpreted, but only when verbose
  if [[ "${VERBOSE:-0}" -eq 1 ]]; then
    # Automatically wrap debug output in cyan coloring so callers don't need to embed color codes.
    printf '%b\n' "${C_CYAN}${*}${C_0}"
  fi
}

check_program() {
  set +e
  command_to_test=$(command -v "${1}")
  command_exit_code=$?
  set -e
  if [[ "${command_exit_code}" -ne 0 ]]; then
    echo -e "${C_BOLD}${C_RED}FATAL: Required ${1} command not found. You MUST install ${1} manually${C_0}" >&2
    return 9
  else
    debug "✅${C_GREEN} Found ${1} [${command_to_test}]"
  fi

}

check_prereqs() {
  if [[ "${RUN_ALL:-}" != "true" ]]; then
    return
  fi
  debug "Check prereqs... Testing for required commands availability"
  check_program bash
  debug "✅Check prereqs... All relevant commands available"
}
# start section #3. Specific functions

# (deliberately empty in the template)


# start section #4. Main: run_main function. This is a separate function to make file testable
run_main() {
  parse_args "$@"
  check_prereqs

  # here you add the main logic of your script
  echo "TODO: call the main program here"
}

if [[ "${BASH_SOURCE[0]}" == "${0}" ]]
then
  run_main "$@"
fi
