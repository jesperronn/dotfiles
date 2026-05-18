# shellcheck shell=bash
# Sets the Ghostty tab title and CWD on every prompt, using the same
# logic as 50_wezterm_prompt.sh:
#
#   • OSC 7  — reports the current working directory so Ghostty can open
#              new tabs/splits in the same directory.
#   • OSC 0  — sets the tab/window title based on git context:
#                - inside a git repo at root  → "repo-name"
#                - inside a git repo subdir   → "repo-name/current-dir"
#                - outside any git repo       → "current-dir"
#
# The functions are no-ops when not running inside Ghostty
# ($TERM_PROGRAM is set to "ghostty" by the terminal itself).

__ghostty_set_cwd() {
  if [[ "$TERM_PROGRAM" != "ghostty" ]]; then
    return
  fi
  local pwd="$PWD"
  pwd="${pwd// /%20}"
  printf '\e]7;file://%s%s\a' "${HOSTNAME:-localhost}" "$pwd"
}

__ghostty_set_title() {
  if [[ "$TERM_PROGRAM" != "ghostty" ]]; then
    return
  fi

  local cwd="$PWD"
  local title=""

  if git_root=$(git -C "$cwd" rev-parse --show-toplevel 2>/dev/null); then
    local root_base="${git_root##*/}"
    if [[ "$cwd" == "$git_root" ]]; then
      title="$root_base"
    else
      title="$root_base/${cwd##*/}"
    fi
  else
    title="${cwd##*/}"
  fi

  printf '\e]0;%s\a' "$title"
}

if [[ -n "$PROMPT_COMMAND" ]]; then
  PROMPT_COMMAND="$PROMPT_COMMAND; __ghostty_set_cwd; __ghostty_set_title"
else
  PROMPT_COMMAND="__ghostty_set_cwd; __ghostty_set_title"
fi
