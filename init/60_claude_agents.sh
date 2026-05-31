#!/usr/bin/env bash
# Link ~/.claude/skills → ~/.agents/skills so Claude Code picks up shared skills

_target="$HOME/.claude/skills"
_source="$HOME/.agents/skills"

if [[ -L "$_target" && "$(readlink "$_target")" == "$_source" ]]; then
  e_success "~/.claude/skills already linked."
elif [[ -e "$_target" && ! -L "$_target" ]]; then
  e_error "~/.claude/skills exists as a real directory — move or remove it first."
else
  ln -sf "$_source" "$_target"
  e_success "Linked ~/.claude/skills → ~/.agents/skills"
fi

unset _target _source
