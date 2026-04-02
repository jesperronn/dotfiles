# shellcheck shell=bash

# This file is used to set up environment variables that are loaded at login.
# Place here:
# * Environment variables that should be available in all shells, including non-interactive ones.

# Point npm at the user-managed global prefix.
export NPM_CONFIG_PREFIX="$HOME/.npm-global"
