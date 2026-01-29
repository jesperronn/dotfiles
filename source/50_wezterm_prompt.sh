# shellcheck shell=bash

__wezterm_set_cwd() {
  if [[ -z "$WEZTERM_EXECUTABLE" ]]; then
    return
  fi
  local pwd="$PWD"
  pwd="${pwd// /%20}"
  printf '\e]7;file://%s%s\a' "${HOSTNAME:-localhost}" "$pwd"
}

__wezterm_set_title() {
  if [[ -z "$WEZTERM_EXECUTABLE" ]]; then
    return
  fi

  local cwd="$PWD"
  local title=""

  if git_root=$(git -C "$cwd" rev-parse --show-toplevel 2>/dev/null); then
    local root_base
    root_base="${git_root##*/}"
    if [[ "$cwd" == "$git_root" ]]; then
      title="$root_base"
    else
      local sub_base
      sub_base="${cwd##*/}"
      title="$root_base/$sub_base"
    fi
  else
    title="${cwd##*/}"
  fi

  printf '\e]0;%s\a' "$title"
}

if [[ -n "$PROMPT_COMMAND" ]]; then
  PROMPT_COMMAND="$PROMPT_COMMAND; __wezterm_set_cwd; __wezterm_set_title"
else
  PROMPT_COMMAND="__wezterm_set_cwd; __wezterm_set_title"
fi
