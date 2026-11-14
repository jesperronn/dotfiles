#!/usr/bin/env bash
# bootstrap.test.sh — verify generated workflows in isolated projects.
set -euo pipefail
cd "${BASH_SOURCE[0]%/*}"
exec python3 bootstrap_test.py
