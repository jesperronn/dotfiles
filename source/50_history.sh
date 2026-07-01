# History settings

#
shopt -s histappend
# Allow use to re-edit a faild history substitution.
shopt -s histreedit
# History expansions will be verified before execution.
shopt -s histverify

# Commands below are documented in
# https://www.gnu.org/software/bash/manual/html_node/Bash-Variables.html

# entries will be erased (leaving the most recent entry).
export HISTCONTROL="erasedups"
# Give history timestamps.
export HISTTIMEFORMAT="[%F %T] "

#The maximum number of commands to remember on the history list.
export HISTSIZE=200000

# The maximum number of lines contained in the history file.
export HISTFILESIZE=200000

# Write each command to the history file immediately instead of only on a
# clean shell exit, so a crash / force-quit / kill doesn't lose the session.
if [[ -n "$PROMPT_COMMAND" ]]; then
  PROMPT_COMMAND="history -a; $PROMPT_COMMAND"
else
  PROMPT_COMMAND="history -a"
fi
