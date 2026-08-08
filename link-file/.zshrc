[ -f ~/.fzf.zsh ] && source ~/.fzf.zsh

# Add RVM to PATH for scripting. Make sure this is the last PATH variable change.
export PATH="$PATH:$HOME/.rvm/bin"

# Added by LM Studio CLI tool (lms)
export PATH="$PATH:/Users/jesper/.lmstudio/bin"

# Claude Code local-model routing — revisit and fine-tune 2026-08-09.
# Uncomment to route subagents / the main session through a local runner
# (opencode + omlx on :4000, LM Studio on :1234 — see project memory
# "local-agent-runners" for the traps in each).
# export CLAUDE_CODE_SUBAGENT_MODEL=Ornith-1.0-35B-4bit
# export ANTHROPIC_MODEL=Ornith-1.0-35B-4bit
# export ANTHROPIC_SMALL_FAST_MODEL=Ornith-1.0-9B-4bit
# export ANTHROPIC_BASE_URL=http://localhost:4000/v1
# export ANTHROPIC_AUTH_TOKEN=local-no-auth-required
