# shellcheck shell=bash

export PATH="$HOME/.rvm/bin:$PATH"
export rvm_shell_arity="${rvm_shell_arity:-1}"
export rvm_tar_command="${rvm_tar_command:-tar}"

resolve_rvm_environment_file() {
  local search_dir ruby_version gemset env_name

  search_dir="$PWD"
  while [[ "$search_dir" != "/" ]]; do
    if [[ -f "$search_dir/.ruby-version" ]]; then
      ruby_version="$(<"$search_dir/.ruby-version")"
      ruby_version="${ruby_version//$'\n'/}"

      if [[ -f "$search_dir/.ruby-gemset" ]]; then
        gemset="$(<"$search_dir/.ruby-gemset")"
        gemset="${gemset//$'\n'/}"
      else
        gemset=""
      fi

      env_name="$ruby_version"
      [[ -n "$gemset" ]] && env_name="${env_name}@${gemset}"

      if [[ -s "$HOME/.rvm/environments/$env_name" ]]; then
        printf '%s\n' "$HOME/.rvm/environments/$env_name"
        return 0
      fi
    fi

    search_dir="$(dirname "$search_dir")"
  done

  if [[ -s "$HOME/.rvm/environments/default" ]]; then
    printf '%s\n' "$HOME/.rvm/environments/default"
    return 0
  fi

  return 1
}

if [[ "$CODEX_SANDBOX" == "true" || "${TERM:-}" == "dumb" ]]; then
  if env_file="$(resolve_rvm_environment_file)"; then
    # Avoid sourcing the full RVM shell integration in headless shells because
    # it probes /bin/ps, which is blocked inside the sandbox.
    source "$env_file"
  elif [[ -s "$HOME/.rvm/gems/default/environment" ]]; then
    source "$HOME/.rvm/gems/default/environment"
  fi
  return
fi

[[ -s "$HOME/.rvm/scripts/rvm" ]] && source "$HOME/.rvm/scripts/rvm" # Load RVM into a shell session *as a function*
