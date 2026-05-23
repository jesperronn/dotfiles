# shellcheck shell=bash

export SDKMAN_OFFLINE_MODE=true
export SDKMAN_DIR="$HOME/.sdkman"
# SDK Man installation done with http://sdkman.io/
# THIS MUST BE AT THE END OF THE FILE FOR SDKMAN TO WORK!!!
[[ -s "$HOME/.sdkman/bin/sdkman-init.sh" ]] && source "$HOME/.sdkman/bin/sdkman-init.sh"
