# shellcheck shell=bash

export PATH="$HOME/.rvm/bin:$PATH"
export rvm_shell_arity="${rvm_shell_arity:-1}"
export rvm_tar_command="${rvm_tar_command:-tar}"

if [[ "$CODEX_SANDBOX" == "true" || "${TERM:-}" == "dumb" ]]; then
  [[ -s "$HOME/.rvm/gems/default/environment" ]] && source "$HOME/.rvm/gems/default/environment"
  return
fi

[[ -s "$HOME/.rvm/scripts/rvm" ]] && source "$HOME/.rvm/scripts/rvm" # Load RVM into a shell session *as a function*
