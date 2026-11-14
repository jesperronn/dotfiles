#!/usr/bin/env bash
# maintainer-workflow-commands.test.sh — test the skill's generator and generated workflows.
set -euo pipefail
ROOT="$(cd "${BASH_SOURCE[0]%/*}/.." && pwd -P)"
export BASH_TEST_LIB="$ROOT/bin/lib/bash_test.sh"
SCRIPTS="$ROOT/link-dir/.agents/skills/maintainer-workflow-commands/scripts"
"$SCRIPTS/bootstrap.test.sh"
"$SCRIPTS/commands.test.sh" "$@"
