#!/usr/bin/env bash
set -euo pipefail

project_root="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
fixture_repo="$project_root/sandbox/codex-edit-loop"
model="${1:-qwen3.6:35b-a3b-coding-mxfp8}"
timeout_secs="${2:-240}"
slug="$(printf '%s' "$model" | tr ':/.' '-' | tr -cd '[:alnum:]-')"
workspace_root="${TMPDIR:-/tmp}/local-model-testrun-loop/runs"
workspace="$(mktemp -d "$workspace_root/${slug}-$(date +%Y%m%dT%H%M%S)-XXXXXX")"
raw_log_file="$(mktemp "$workspace_root/${slug}-raw-XXXXXX")"
log_file="$workspace_root/${slug}-run.jsonl"
last_file="$workspace_root/${slug}-last.txt"

prompt='You are in a tiny git repo for local-model-testrun-loop verification. Use shell commands to inspect the repo, then edit only README.md so line 3 becomes exactly: This line is the deterministic edit target BINGO. Do not use apply_patch. Verify the tracked-file diff with git diff -- README.md before finishing. Keep the final response to one short sentence.'

rm -f "$raw_log_file" "$log_file" "$last_file"
mkdir -p "$workspace_root"

while read -r loaded_model _; do
  [[ -n "${loaded_model:-}" && "$loaded_model" != "NAME" ]] || continue
  ollama stop "$loaded_model" >/dev/null 2>&1 || true
done < <(ollama ps)

git clone -q "$fixture_repo" "$workspace"

run_status=0
if ! printf '%s\n' "$prompt" |
  perl -e '
    my $timeout = shift @ARGV;
    my $pid = fork();
    die "fork failed\n" unless defined $pid;
    if ($pid == 0) {
      exec @ARGV or die "exec failed: $!\n";
    }
    local $SIG{ALRM} = sub {
      kill 9, $pid;
      waitpid($pid, 0);
      exit 124;
    };
    alarm $timeout;
    waitpid($pid, 0);
    alarm 0;
    exit($? >> 8);
  ' "$timeout_secs" \
  codex exec \
    --json \
    --output-last-message "$last_file" \
    --oss \
    --local-provider ollama \
    -m "$model" \
    --ignore-user-config \
    --ephemeral \
    --cd "$workspace" \
    -s workspace-write \
    - >"$raw_log_file" 2>&1; then
  run_status=$?
fi

if [[ ! -f "$last_file" ]]; then
  : >"$last_file"
fi

python3 - "$raw_log_file" "$log_file" <<'PY'
import json
import sys
from pathlib import Path

src = Path(sys.argv[1])
dst = Path(sys.argv[2])

with src.open() as infile, dst.open("w") as outfile:
    for line in infile:
        if line.startswith("{"):
            try:
                json.loads(line)
            except json.JSONDecodeError:
                continue
            outfile.write(line)
PY

rm -f "$raw_log_file"

printf 'model: %s\n' "$model"
printf 'run status: %s\n' "$run_status"
printf 'timeout seconds: %s\n' "$timeout_secs"
printf 'workspace: %s\n' "$workspace"
printf 'filtered log: %s\n' "$log_file"
printf 'last message:\n'
cat "$last_file"
printf '\n\nverified diff:\n'
git -C "$workspace" diff -- README.md
