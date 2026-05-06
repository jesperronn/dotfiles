#!/usr/bin/env bash
# shellcheck shell=bash

set -euo pipefail

TEMPLATE_VERBOSE=0
TEMPLATE_COLOR_ENABLED=1
TEMPLATE_INTERACTIVE=0
TEMPLATE_TIMINGS=0

C_DIM=$'\033[2m'
C_BOLD=$'\033[1m'
C_RED=$'\033[31m'
C_GREEN=$'\033[32m'
C_MAGENTA=$'\033[35m'
C_0=$'\033[0m'

template_usage() {
  local header_style="" command_style="" subcommand_style="" parameter_style="" flag_style="" reset_style=""

  if (( TEMPLATE_COLOR_ENABLED )); then
    header_style="${C_BOLD}${C_MAGENTA}"
    command_style="${C_BOLD}${C_GREEN}"
    subcommand_style="$C_GREEN"
    parameter_style="$C_MAGENTA"
    flag_style="$C_GREEN"
    reset_style="$C_0"
  fi

  cat <<EOF
${header_style}Usage:${reset_style} ${command_style}template-script${reset_style} ${parameter_style}[OPTIONS]${reset_style}

${header_style}Subcommands:${reset_style}
  ${subcommand_style}run${reset_style}             Execute the default workflow.
  ${subcommand_style}inspect${reset_style}         Show the planned actions without mutating anything.

${header_style}Options:${reset_style}
  ${flag_style}--help${reset_style}          Show this help.
  ${flag_style}--verbose${reset_style}       Print extra progress details.
  ${flag_style}--timings${reset_style}       Show phase timings.
  ${flag_style}--interactive${reset_style}   Use interactive selection where available.
  ${flag_style}--color, --no-color${reset_style}
                    Enable or disable colored output.
EOF
}

template_color_print() {
  local color=$1
  shift

  if (( TEMPLATE_COLOR_ENABLED )); then
    printf '%s%s%s\n' "$color" "$*" "$C_0"
  else
    printf '%s\n' "$*"
  fi
}

template_info() {
  template_color_print "${C_BOLD}${C_ORANGE}" "$*"
}

template_success() {
  template_color_print "$C_GREEN" "$*"
}

template_warn() {
  template_color_print "${C_BOLD}${C_MAGENTA}" "$*" >&2
}

template_error() {
  template_color_print "$C_RED" "$*" >&2
}

template_verbose() {
  if (( TEMPLATE_VERBOSE )); then
    template_color_print "$C_DIM" "$*"
  fi
}

template_parse_opts() {
  while (($#)); do
    case "$1" in
      -h|--help)
        template_usage
        return 1
        ;;
      --verbose)
        TEMPLATE_VERBOSE=1
        ;;
      --timings)
        TEMPLATE_TIMINGS=1
        ;;
      -i|--interactive)
        TEMPLATE_INTERACTIVE=1
        ;;
      --color)
        TEMPLATE_COLOR_ENABLED=1
        ;;
      --no-color)
        TEMPLATE_COLOR_ENABLED=0
        ;;
      *)
        template_warn "Unknown option: $1"
        template_usage >&2
        return 2
        ;;
    esac
    shift
  done
}

template_parse_prereqs() {
  :
}

template_run_main() {
  template_parse_opts "$@" || return $?
  template_parse_prereqs

  template_verbose "Starting run"
  template_info "TODO: plan work"
  template_info "TODO: apply work"
  template_success "Done"
}

if [[ "${BASH_SOURCE[0]}" == "$0" ]]; then
  template_run_main "$@"
fi
