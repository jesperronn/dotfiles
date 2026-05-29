#!/usr/bin/env bash
# shellcheck disable=SC1090,SC1091,SC2016

set -euo pipefail

DOTFILES_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
SCRIPT_UNDER_TEST="$DOTFILES_ROOT/bin/podman_troubleshoot"

source "$DOTFILES_ROOT/bin/lib/bash_test.sh"

make_stub_dir() {
  local stub_dir="$1"

  mkdir -p "$stub_dir"
}

write_stub() {
  local file_path="$1"
  shift
  local body="$1"

  cat >"$file_path" <<EOF
#!/usr/bin/env bash
set -euo pipefail
$body
EOF
  chmod +x "$file_path"
}

test_journald_io_errors_trigger_actionable_recovery_hint() {
  local work_dir=""
  local stub_dir=""
  local output=""
  local status=0

  work_dir="$(mktemp -d)"
  stub_dir="$work_dir/stub-bin"
  make_stub_dir "$stub_dir"
  mkdir -p "$work_dir/home" "$work_dir/podman"

  write_stub "$stub_dir/podman" '
case "$1" in
  ps)
    exit 0
    ;;
  version)
    printf "Client 5.6.1\n"
    exit 0
    ;;
  info)
    printf "host: ok\n"
    exit 0
    ;;
  machine)
    case "$2" in
      list)
        printf "[{\"Name\":\"podman-machine-default\",\"Default\":true,\"Running\":true,\"Starting\":false,\"State\":\"running\"}]\n"
        ;;
      inspect)
        printf "{\"Name\":\"podman-machine-default\"}\n"
        ;;
      ssh)
        exit 0
        ;;
      connection)
        exit 0
        ;;
      *)
        exit 0
        ;;
    esac
    exit 0
    ;;
  system)
    case "$2" in
      connection)
        printf "[{\"Name\":\"podman-machine-default\",\"Default\":true}]\n"
        ;;
      *)
        exit 0
        ;;
    esac
    exit 0
    ;;
  *)
    exit 0
    ;;
esac
'

  write_stub "$stub_dir/docker" '
case "$1" in
  version)
    printf "Client 27.0.0\n"
    ;;
  info)
    printf "Docker Engine: ok\n"
    ;;
  system)
    exit 0
    ;;
  context)
    exit 0
    ;;
esac
exit 0
'

  write_stub "$stub_dir/curl" '
exit 0
'

  write_stub "$stub_dir/jq" '
query="${*: -1}"
case "$query" in
  *"select(.Default == true) | .Name"*)
    printf "podman-machine-default\n"
    ;;
  *"[.[] | select(.Default == true)] | length"*)
    printf "1\n"
    ;;
  *".Running"*)
    printf "true\n"
    ;;
  *".Starting"*)
    printf "false\n"
    ;;
  *".State // \"unknown\""*)
    printf "running\n"
    ;;
  *"length"*)
    printf "1\n"
    ;;
  *)
    cat
    ;;
esac
'

  write_stub "$stub_dir/strings" '
cat "$1"
'

  write_stub "$stub_dir/rg" '
pattern=""
while [[ $# -gt 0 ]]; do
  case "$1" in
    -n|-i|-N)
      shift
      ;;
    *)
      pattern="$1"
      shift
      break
      ;;
  esac
done

grep -Ein "$pattern"
'

  cat >"$work_dir/podman/podman-machine-default.log" <<'EOF'
[435791.625125] systemd-journald[770]: Failed to open /var/log/journal/ad209d968eb84885b8fc2b9f8e277dd3: Input/output error
[435792.875597] systemd-journald[770]: Failed to rotate /var/log/journal/ad209d968eb84885b8fc2b9f8e277dd3/system.journal: Input/output error
EOF

  capture_command output status env \
    NO_COLOR=1 \
    HOME="$work_dir/home" \
    TMPDIR="$work_dir" \
    PATH="$stub_dir:$PATH" \
    bash --noprofile --norc -c "cd '$work_dir' && '$SCRIPT_UNDER_TEST'"

  assert_status "0" "$status" "podman_troubleshoot completes successfully"
  assert_contains "$output" "Machine Log Health" "script reaches the log health section"
  assert_contains "$output" "Docker Socket Rootless Test" "script reaches the Docker socket rootless section"
  assert_contains "$output" "bin/docker_socket_rootless_test --port 8080" "script points to the high-port smoke test"
  assert_contains "$output" "docker_socket_rootless_test is available" "script finds the adjacent smoke test when run from another directory"
  assert_contains "$output" "[ACTION] vfkit log shows repeated journald I/O errors" "journald I/O errors are promoted to an actionable message"
  assert_contains "$output" "VM-local customizations, images, volumes, and container state" "script warns that rebuilding discards VM-local state"
  assert_contains "$output" "podman_troubleshoot --fix" "script points to the runnable recovery command instead of a shell-only helper"
  assert_contains "$output" "check(s) need attention" "script no longer reports all checks as passing"
  assert_not_contains "$output" "all checks passed" "script does not mark the run as clean when journald I/O errors are present"

  rm -rf "$work_dir"
}

test_emergency_mode_log_triggers_rebuild_hint() {
  local work_dir=""
  local stub_dir=""
  local output=""
  local status=0

  work_dir="$(mktemp -d)"
  stub_dir="$work_dir/stub-bin"
  make_stub_dir "$stub_dir"
  mkdir -p "$work_dir/home" "$work_dir/podman"

  write_stub "$stub_dir/podman" '
case "$1" in
  ps)
    exit 0
    ;;
  version)
    printf "Client 5.6.1\n"
    exit 0
    ;;
  info)
    printf "host: ok\n"
    exit 0
    ;;
  machine)
    case "$2" in
      list)
        printf "[{\"Name\":\"podman-machine-default\",\"Default\":true,\"Running\":true,\"Starting\":false,\"State\":\"running\"}]\n"
        ;;
      inspect)
        printf "{\"Name\":\"podman-machine-default\"}\n"
        ;;
      ssh)
        exit 0
        ;;
      connection)
        exit 0
        ;;
      *)
        exit 0
        ;;
    esac
    exit 0
    ;;
  system)
    case "$2" in
      connection)
        printf "[{\"Name\":\"podman-machine-default\",\"Default\":true}]\n"
        ;;
      *)
        exit 0
        ;;
    esac
    exit 0
    ;;
  *)
    exit 0
    ;;
esac
'

  write_stub "$stub_dir/docker" '
case "$1" in
  version)
    printf "Client 27.0.0\n"
    ;;
  info)
    printf "Docker Engine: ok\n"
    ;;
  system)
    exit 0
    ;;
  context)
    exit 0
    ;;
esac
exit 0
'

  write_stub "$stub_dir/curl" '
exit 0
'

  write_stub "$stub_dir/jq" '
query="${*: -1}"
case "$query" in
  *"select(.Default == true) | .Name"*)
    printf "podman-machine-default\n"
    ;;
  *"[.[] | select(.Default == true)] | length"*)
    printf "1\n"
    ;;
  *".Running"*)
    printf "true\n"
    ;;
  *".Starting"*)
    printf "false\n"
    ;;
  *".State // \"unknown\""*)
    printf "running\n"
    ;;
  *"length"*)
    printf "1\n"
    ;;
  *)
    cat
    ;;
esac
'

  write_stub "$stub_dir/strings" '
cat "$1"
'

  write_stub "$stub_dir/rg" '
pattern=""
while [[ $# -gt 0 ]]; do
  case "$1" in
    -n|-i|-N)
      shift
      ;;
    *)
      pattern="$1"
      shift
      break
      ;;
  esac
done

grep -Ein "$pattern"
'

  cat >"$work_dir/podman/podman-machine-default.log" <<'EOF'
Ignition has failed. Please ensure your config is valid.
Failed to start systemd-fsck-root.service - File System Check on /dev/disk/by-uuid/example.
Entering emergency mode. Exit the shell to continue.
Press Enter for system maintenance
EOF

  capture_command output status env \
    NO_COLOR=1 \
    HOME="$work_dir/home" \
    TMPDIR="$work_dir" \
    PATH="$stub_dir:$PATH" \
    bash --noprofile --norc -c "cd '$work_dir' && '$SCRIPT_UNDER_TEST'"

  assert_status "0" "$status" "podman_troubleshoot completes successfully with emergency-mode log hints"
  assert_contains "$output" "[ACTION] vfkit log shows the VM booted into emergency mode" "emergency-mode boot is promoted to an action item"
  assert_contains "$output" "podman machine rm -f podman-machine-default" "script recommends a rebuild for emergency-mode boots"
  assert_contains "$output" "podman_troubleshoot --fix" "script keeps the new runnable recovery entrypoint in the follow-up steps"
  assert_not_contains "$output" "/podman//podman-machine-default.log" "log path does not contain a doubled slash"
  assert_not_contains "$output" "/T//podman/podman-machine-default.log" "TMPDIR with a trailing slash is normalized in log paths"

  rm -rf "$work_dir"
}

test_fix_force_starts_machine_refreshes_socket_and_verifies() {
  local work_dir=""
  local stub_dir=""
  local output=""
  local status=0

  work_dir="$(mktemp -d)"
  stub_dir="$work_dir/stub-bin"
  make_stub_dir "$stub_dir"
  mkdir -p "$work_dir/home/.local/share/containers/podman/machine" "$work_dir/state"

  write_stub "$stub_dir/podman" '
state_dir="${PODMAN_TEST_STATE_DIR:?}"
running_file="$state_dir/running"
default_file="$state_dir/default_connection"

case "$1" in
  ps)
    if [[ -f "$running_file" ]]; then
      printf "CONTAINER ID  IMAGE\n"
      exit 0
    fi
    printf "Cannot connect to Podman. Please verify your connection to the Linux system using `podman system connection list`, or try `podman machine init` and `podman machine start` to manage a new Linux VM\n" >&2
    printf "Error: unable to connect to Podman socket: failed to connect: dial tcp 127.0.0.1:58715: connect: connection refused\n" >&2
    exit 125
    ;;
  info|version)
    if [[ -f "$running_file" ]]; then
      printf "host: ok\n"
      exit 0
    fi
    printf "Error: machine is stopped\n" >&2
    exit 125
    ;;
  machine)
    case "$2" in
      list)
        if [[ -f "$running_file" ]]; then
          printf "[{\"Name\":\"podman-machine-default\",\"Default\":true,\"Running\":true,\"Starting\":false}]\n"
        else
          printf "[{\"Name\":\"podman-machine-default\",\"Default\":true,\"Running\":false,\"Starting\":false}]\n"
        fi
        ;;
      inspect)
        if [[ "$4" == "{{.Rootful}}" ]]; then
          printf "false\n"
        elif [[ "$4" == "{{.ConnectionInfo.PodmanSocket.Path}}" ]]; then
          printf "%s/podman/podman-machine-default-api.sock\n" "${TMPDIR:-/tmp}"
        else
          printf "{\"Name\":\"podman-machine-default\",\"Rootful\":false}\n"
        fi
        ;;
      start)
        : >"$running_file"
        printf "Machine started\n"
        ;;
      stop)
        rm -f "$running_file"
        printf "Machine stopped\n"
        ;;
      set)
        printf "rootful updated\n"
        ;;
      *)
        exit 0
        ;;
    esac
    exit 0
    ;;
  system)
    case "$2" in
      connection)
        if [[ "$3" == "list" ]]; then
          current_default="podman-machine-default"
          if [[ -f "$default_file" ]]; then
            current_default="$(cat "$default_file")"
          fi
          printf "[{\"Name\":\"%s\",\"Default\":true}]\n" "$current_default"
        elif [[ "$3" == "default" ]]; then
          printf "%s\n" "$4" >"$default_file"
          printf "Default connection set to %s\n" "$4"
        fi
        ;;
      *)
        exit 0
        ;;
    esac
    exit 0
    ;;
  *)
    exit 0
    ;;
esac
'

  write_stub "$stub_dir/jq" '
query="${*: -1}"
input="$(cat)"
case "$query" in
  *"select(.Default == true) | .Name"*)
    if [[ "$input" == *"podman-machine-default-root"* ]]; then
      printf "podman-machine-default-root\n"
    else
      printf "podman-machine-default\n"
    fi
    ;;
  *"select(.Name == \$name and .Running == true) | .Name"*)
    if [[ "$input" == *"\"Running\":true"* ]]; then
      printf "podman-machine-default\n"
      exit 0
    fi
    exit 1
    ;;
  *".[] | select(.Name == \$name) | .Running"*)
    if [[ "$input" == *"\"Running\":true"* ]]; then
      printf "true\n"
    else
      printf "false\n"
    fi
    ;;
  *".[] | select(.Name == \$name) | .Starting"*)
    printf "false\n"
    ;;
  *"length"*)
    printf "1\n"
    ;;
  *)
    cat <<<"$input"
    ;;
esac
'

  capture_command output status env \
    NO_COLOR=1 \
    HOME="$work_dir/home" \
    TMPDIR="$work_dir" \
    PODMAN_TEST_STATE_DIR="$work_dir/state" \
    PATH="$stub_dir:$PATH" \
    bash --noprofile --norc -c "cd '$work_dir' && '$SCRIPT_UNDER_TEST' --fix --force"

  assert_status "0" "$status" "podman_troubleshoot --fix --force completes successfully"
  assert_contains "$output" "== Podman Fix ==" "fix mode prints its own section"
  assert_contains "$output" "[OK] Podman machine started" "fix mode starts the stopped machine"
  assert_contains "$output" "[OK] stable Podman socket refreshed" "fix mode refreshes the stable socket"
  assert_contains "$output" "[OK] default Podman connection aligned" "fix mode sets the default connection"
  assert_contains "$output" "[OK] podman ps succeeded after fix" "fix mode verifies podman ps"
  assert_contains "$output" "[OK] podman info succeeded after fix" "fix mode verifies podman info"

  rm -rf "$work_dir"
}

test_starting_machine_is_not_reported_as_healthy() {
  local work_dir=""
  local stub_dir=""
  local output=""
  local status=0

  work_dir="$(mktemp -d)"
  stub_dir="$work_dir/stub-bin"
  make_stub_dir "$stub_dir"
  mkdir -p "$work_dir/home"

  write_stub "$stub_dir/podman" '
case "$1" in
  ps)
    printf "Cannot connect to Podman. Please verify your connection to the Linux system using `podman system connection list`, or try `podman machine init` and `podman machine start` to manage a new Linux VM\n" >&2
    printf "Error: unable to connect to Podman socket: failed to connect: dial tcp 127.0.0.1:58715: connect: connection refused\n" >&2
    exit 125
    ;;
  version)
    printf "Client 5.6.1\n"
    exit 0
    ;;
  info)
    printf "host: ok\n"
    exit 0
    ;;
  machine)
    case "$2" in
      list)
        printf "[{\"Name\":\"podman-machine-default\",\"Default\":true,\"Running\":true,\"Starting\":true}]\n"
        ;;
      inspect)
        printf "{\"Name\":\"podman-machine-default\"}\n"
        ;;
      ssh)
        exit 0
        ;;
      *)
        exit 0
        ;;
    esac
    exit 0
    ;;
  system)
    case "$2" in
      connection)
        printf "[{\"Name\":\"podman-machine-default\",\"Default\":true}]\n"
        ;;
      *)
        exit 0
        ;;
    esac
    exit 0
    ;;
  *)
    exit 0
    ;;
esac
'

  write_stub "$stub_dir/docker" '
case "$1" in
  version)
    printf "Client 27.0.0\n"
    ;;
  info)
    printf "Docker Engine: ok\n"
    ;;
  system)
    exit 0
    ;;
  context)
    exit 0
    ;;
esac
exit 0
'

  write_stub "$stub_dir/curl" '
exit 0
'

  write_stub "$stub_dir/jq" '
query="${*: -1}"
case "$query" in
  *"select(.Default == true) | .Name"*)
    printf "podman-machine-default\n"
    ;;
  *"[.[] | select(.Default == true)] | length"*)
    printf "1\n"
    ;;
  *".[] | select(.Name == \$name) | .Running"*)
    printf "true\n"
    ;;
  *".[] | select(.Name == \$name) | .Starting"*)
    printf "true\n"
    ;;
  *"length"*)
    printf "1\n"
    ;;
  *)
    cat
    ;;
esac
'

  capture_command output status env \
    NO_COLOR=1 \
    HOME="$work_dir/home" \
    TMPDIR="$work_dir" \
    PATH="$stub_dir:$PATH" \
    bash --noprofile --norc -c "cd '$work_dir' && '$SCRIPT_UNDER_TEST'"

  assert_status "0" "$status" "podman_troubleshoot completes successfully with a starting machine"
  assert_contains "$output" "[TROUBLESHOOT] default Podman machine is still starting" "starting machines are surfaced as an issue"
  assert_not_contains "$output" "[OK] default Podman machine is running" "starting machines are not reported as healthy"

  rm -rf "$work_dir"
}

run_tests "$@"
