#!/usr/bin/env bash
# shellcheck disable=SC1090,SC1091,SC2016

set -euo pipefail

DOTFILES_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
SCRIPT_UNDER_TEST="$DOTFILES_ROOT/bin/podman_troubleshoot"

source "$DOTFILES_ROOT/bin/lib/bash_test.sh"

# Global cleanup: remove any temp directories left behind by interrupted tests
cleanup_test_temps() {
  find . -maxdepth 1 -type d -name "ptest_*" -exec rm -rf {} + 2>/dev/null || true
}
trap cleanup_test_temps EXIT

# Test-mode env vars: reduce all timeouts to sub-second execution
export PODMAN_TROUBLESHOOT_TEST_MODE=1
export PODMAN_TROUBLESHOOT_STABILITY_SLEEP_SECONDS=0

make_stub_dir() {
  local stub_dir="$1"
  mkdir -p "$stub_dir"
}

write_fast_rootless_test_stub() {
  local file_path="$1"
  write_stub "$file_path" '
printf "Docker socket rootless routing is working on port 8080\n"
exit 0
'
}

write_stub() {
  local file_path="$1"
  shift
  local body="$1"
  { echo '#!/usr/bin/env bash'; echo 'set -euo pipefail'; echo "$body"; } >"$file_path"
  chmod +x "$file_path"
}

# Shared fixture setup: creates the common stubs used by most tests
setup_common_stubs() {
  local stub_dir="$1"

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

  write_stub "$stub_dir/curl" 'exit 0'

  write_stub "$stub_dir/strings" 'cat "$1"'

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
}

# Shared fixture setup: basic podman stub (healthy state)
setup_basic_podman_stub() {
  local stub_dir="$1"

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
  run)
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
        case "$3" in
          *"registry-1.docker.io"*) printf "resolved\n"; exit 0 ;;
          *) exit 0 ;;
        esac
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
}

# Shared fixture setup: jq stub (healthy state)
setup_basic_jq_stub() {
  local stub_dir="$1"

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
  *".[] | select(.Name == \$name) | .Running"*)
    printf "true\n"
    ;;
  *".[] | select(.Name == \$name) | .Starting"*)
    printf "false\n"
    ;;
  *"length"*)
    printf "1\n"
    ;;
  *)
    cat
    ;;
esac
'
}

# Fixture group 1: Log analysis tests (shared invocation, different log content)
# Running this fixture sets: FIXTURE1_OUTPUT, FIXTURE1_STATUS
run_fixture1_log_health_healthy() {
  local work_dir=""
  local stub_dir=""

  work_dir="$(mktemp -d)"
  stub_dir="$work_dir/stub-bin"
  make_stub_dir "$stub_dir"
  mkdir -p "$work_dir/home" "$work_dir/podman"

  setup_basic_podman_stub "$stub_dir"
  setup_common_stubs "$stub_dir"
  setup_basic_jq_stub "$stub_dir"

  cat >"$work_dir/podman/podman-machine-default.log" <<'EOF'
systemd[1]: Starting coreos-ignition-unique-boot.service - CoreOS Ignition Ensure Unique Boot Filesystem...
systemd[1]: Finished coreos-ignition-unique-boot.service - CoreOS Ignition Ensure Unique Boot Filesystem.
[    4.102150] systemd[1]: coreos-ignition-unique-boot.service: Deactivated successfully.
systemd[1]: Stopped coreos-ignition-unique-boot.service - CoreOS Ignition Ensure Unique Boot Filesystem.
EOF

  write_fast_rootless_test_stub "$stub_dir/docker_socket_rootless_test"

  capture_command FIXTURE1_OUTPUT FIXTURE1_STATUS env \
    NO_COLOR=1 \
    HOME="$work_dir/home" \
    TMPDIR="$work_dir" \
    PATH="$stub_dir:$PATH" \
    PODMAN_TROUBLESHOOT_STABILITY_SLEEP_SECONDS=0 \
    PODMAN_TROUBLESHOOT_TEST_MODE=1 \
    PODMAN_TROUBLESHOOT_DOCKER_SOCKET_TEST_BIN="$stub_dir/docker_socket_rootless_test" \
    bash --noprofile --norc -c "cd '$work_dir' && '$SCRIPT_UNDER_TEST'"

  rm -rf "$work_dir"
}

# Fixture group 2: Log analysis - journald I/O errors
run_fixture2_log_health_journald() {
  local work_dir=""
  local stub_dir=""

  work_dir="$(mktemp -d)"
  stub_dir="$work_dir/stub-bin"
  make_stub_dir "$stub_dir"
  mkdir -p "$work_dir/home" "$work_dir/podman"

  setup_basic_podman_stub "$stub_dir"
  setup_common_stubs "$stub_dir"
  setup_basic_jq_stub "$stub_dir"

  cat >"$work_dir/podman/podman-machine-default.log" <<'EOF'
[435791.625125] systemd-journald[770]: Failed to open /var/log/journal/ad209d968eb84885b8fc2b9f8e277dd3: Input/output error
[435792.875597] systemd-journald[770]: Failed to rotate /var/log/journal/ad209d968eb84885b8fc2b9f8e277dd3/system.journal: Input/output error
EOF

  write_fast_rootless_test_stub "$stub_dir/docker_socket_rootless_test"

  capture_command FIXTURE2_OUTPUT FIXTURE2_STATUS env \
    NO_COLOR=1 \
    HOME="$work_dir/home" \
    TMPDIR="$work_dir" \
    PATH="$stub_dir:$PATH" \
    PODMAN_TROUBLESHOOT_STABILITY_SLEEP_SECONDS=0 \
    PODMAN_TROUBLESHOOT_TEST_MODE=1 \
    PODMAN_TROUBLESHOOT_DOCKER_SOCKET_TEST_BIN="$stub_dir/docker_socket_rootless_test" \
    bash --noprofile --norc -c "cd '$work_dir' && '$SCRIPT_UNDER_TEST'"

  rm -rf "$work_dir"
}

# Fixture group 3: Log analysis - emergency mode
run_fixture3_log_health_emergency() {
  local work_dir=""
  local stub_dir=""

  work_dir="$(mktemp -d)"
  stub_dir="$work_dir/stub-bin"
  make_stub_dir "$stub_dir"
  mkdir -p "$work_dir/home" "$work_dir/podman"

  setup_basic_podman_stub "$stub_dir"
  setup_common_stubs "$stub_dir"
  setup_basic_jq_stub "$stub_dir"

  cat >"$work_dir/podman/podman-machine-default.log" <<'EOF'
Ignition has failed. Please ensure your config is valid.
Failed to start systemd-fsck-root.service - File System Check on /dev/disk/by-uuid/example.
Entering emergency mode. Exit the shell to continue.
Press Enter for system maintenance
EOF

  write_fast_rootless_test_stub "$stub_dir/docker_socket_rootless_test"

  capture_command FIXTURE3_OUTPUT FIXTURE3_STATUS env \
    NO_COLOR=1 \
    HOME="$work_dir/home" \
    TMPDIR="$work_dir" \
    PATH="$stub_dir:$PATH" \
    PODMAN_TROUBLESHOOT_STABILITY_SLEEP_SECONDS=0 \
    PODMAN_TROUBLESHOOT_TEST_MODE=1 \
    PODMAN_TROUBLESHOOT_DOCKER_SOCKET_TEST_BIN="$stub_dir/docker_socket_rootless_test" \
    bash --noprofile --norc -c "cd '$work_dir' && '$SCRIPT_UNDER_TEST'"

  rm -rf "$work_dir"
}

# Fixture group 4: Port 389 policy test
run_fixture4_port389_blocked() {
  local work_dir=""
  local stub_dir=""

  work_dir="$(mktemp -d)"
  stub_dir="$work_dir/stub-bin"
  make_stub_dir "$stub_dir"
  mkdir -p "$work_dir/home"

  write_stub "$stub_dir/podman" '
case "$1" in
  ps)
    printf "CONTAINER ID  IMAGE\n"
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
        printf "[{\"Name\":\"podman-machine-default\",\"Default\":true,\"Running\":true,\"Starting\":false}]\n"
        ;;
      inspect)
        if [[ "$4" == "{{.Rootful}}" ]]; then
          printf "false\n"
        else
          printf "{\"Name\":\"podman-machine-default\",\"Rootful\":false}\n"
        fi
        ;;
      ssh)
        if [[ "$3" == "sysctl -n net.ipv4.ip_unprivileged_port_start" ]]; then
          printf "1024\n"
        else
          exit 0
        fi
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

  setup_common_stubs "$stub_dir"

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
    printf "false\n"
    ;;
  *"length"*)
    printf "1\n"
    ;;
  *)
    cat
    ;;
esac
'

  write_fast_rootless_test_stub "$stub_dir/docker_socket_rootless_test"

  capture_command FIXTURE4_OUTPUT FIXTURE4_STATUS env \
    NO_COLOR=1 \
    HOME="$work_dir/home" \
    TMPDIR="$work_dir" \
    PATH="$stub_dir:$PATH" \
    PODMAN_TROUBLESHOOT_STABILITY_SLEEP_SECONDS=0 \
    PODMAN_TROUBLESHOOT_TEST_MODE=1 \
    PODMAN_TROUBLESHOOT_DOCKER_SOCKET_TEST_BIN="$stub_dir/docker_socket_rootless_test" \
    bash --noprofile --norc -c "cd '$work_dir' && '$SCRIPT_UNDER_TEST'"

  rm -rf "$work_dir"
}

# Fixture group 5: Starting machine
run_fixture5_starting_machine() {
  local work_dir=""
  local stub_dir=""

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

  setup_common_stubs "$stub_dir"

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

  write_fast_rootless_test_stub "$stub_dir/docker_socket_rootless_test"

  capture_command FIXTURE5_OUTPUT FIXTURE5_STATUS env \
    NO_COLOR=1 \
    HOME="$work_dir/home" \
    TMPDIR="$work_dir" \
    PATH="$stub_dir:$PATH" \
    PODMAN_TROUBLESHOOT_STABILITY_SLEEP_SECONDS=0 \
    PODMAN_TROUBLESHOOT_TEST_MODE=1 \
    PODMAN_TROUBLESHOOT_DOCKER_SOCKET_TEST_BIN="$stub_dir/docker_socket_rootless_test" \
    bash --noprofile --norc -c "cd '$work_dir' && '$SCRIPT_UNDER_TEST'"

  rm -rf "$work_dir"
}

# Fixture group 6: Verbose flag
run_fixture6_verbose() {
  local work_dir=""
  local stub_dir=""

  work_dir="$(mktemp -d)"
  stub_dir="$work_dir/stub-bin"
  make_stub_dir "$stub_dir"
  mkdir -p "$work_dir/home"

  setup_basic_podman_stub "$stub_dir"
  setup_common_stubs "$stub_dir"
  setup_basic_jq_stub "$stub_dir"
  write_fast_rootless_test_stub "$stub_dir/docker_socket_rootless_test"

  capture_command FIXTURE6_OUTPUT FIXTURE6_STATUS env \
    NO_COLOR=1 \
    HOME="$work_dir/home" \
    TMPDIR="$work_dir" \
    PATH="$stub_dir:$PATH" \
    PODMAN_TROUBLESHOOT_STABILITY_SLEEP_SECONDS=0 \
    PODMAN_TROUBLESHOOT_TEST_MODE=1 \
    PODMAN_TROUBLESHOOT_DOCKER_SOCKET_TEST_BIN="$stub_dir/docker_socket_rootless_test" \
    bash --noprofile --norc -c "cd '$work_dir' && '$SCRIPT_UNDER_TEST' --verbose"

  rm -rf "$work_dir"
}

# Fixture group 7: --fix --force mode (starts machine)
run_fixture7_fix_force() {
  local work_dir=""
  local stub_dir=""

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
      ssh)
        if [[ "$3" == "sysctl -n net.ipv4.ip_unprivileged_port_start" ]]; then
          if [[ -f "$state_dir/port389" ]]; then
            printf "389\n"
          else
            printf "1024\n"
          fi
        else
          : >"$state_dir/port389"
          printf "net.ipv4.ip_unprivileged_port_start = 389\n"
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

  write_fast_rootless_test_stub "$stub_dir/docker_socket_rootless_test"

  capture_command FIXTURE7_OUTPUT FIXTURE7_STATUS env \
    NO_COLOR=1 \
    HOME="$work_dir/home" \
    TMPDIR="$work_dir" \
    PODMAN_TEST_STATE_DIR="$work_dir/state" \
    PATH="$stub_dir:$PATH" \
    PODMAN_TROUBLESHOOT_STABILITY_SLEEP_SECONDS=0 \
    PODMAN_TROUBLESHOOT_TEST_MODE=1 \
    PODMAN_TROUBLESHOOT_DOCKER_SOCKET_TEST_BIN="$stub_dir/docker_socket_rootless_test" \
    bash --noprofile --norc -c "cd '$work_dir' && '$SCRIPT_UNDER_TEST' --fix --force"

  rm -rf "$work_dir"
}

# Fixture group 8: --fix --force with low memory machine
run_fixture8_fix_force_lowmem() {
  local work_dir=""
  local stub_dir=""

  work_dir="$(mktemp -d)"
  stub_dir="$work_dir/stub-bin"
  make_stub_dir "$stub_dir"
  mkdir -p "$work_dir/home/.local/share/containers/podman/machine" "$work_dir/state"
  printf '2048\n' >"$work_dir/state/memory"

  write_stub "$stub_dir/podman" '
state_dir="${PODMAN_TEST_STATE_DIR:?}"
running_file="$state_dir/running"
default_file="$state_dir/default_connection"
memory_file="$state_dir/memory"
calls_file="$state_dir/calls.log"

case "$1" in
  ps)
    printf "CONTAINER ID  IMAGE\n"
    exit 0
    ;;
  info|version)
    printf "host: ok\n"
    exit 0
    ;;
  machine)
    printf "%s\n" "$*" >>"$calls_file"
    case "$2" in
      list)
        printf "[{\"Name\":\"podman-machine-default\",\"Default\":true,\"Running\":true,\"Starting\":false}]\n"
        ;;
      inspect)
        if [[ "$5" == "{{.Rootful}}" ]]; then
          printf "false\n"
        elif [[ "$5" == "{{.ConnectionInfo.PodmanSocket.Path}}" ]]; then
          printf "%s/podman/podman-machine-default-api.sock\n" "${TMPDIR:-/tmp}"
        elif [[ "$5" == "{{.Resources.Memory}}" ]]; then
          cat "$memory_file"
        else
          printf "{\"Name\":\"podman-machine-default\",\"Rootful\":false}\n"
        fi
        ;;
      rm)
        exit 0
        ;;
      init)
        printf "8192\n" >"$memory_file"
        exit 0
        ;;
      ssh)
        if [[ "$3" == "sysctl -n net.ipv4.ip_unprivileged_port_start" ]]; then
          if [[ -f "$state_dir/port389" ]]; then
            printf "389\n"
          else
            printf "1024\n"
          fi
        else
          : >"$state_dir/port389"
          printf "net.ipv4.ip_unprivileged_port_start = 389\n"
        fi
        ;;
      start)
        : >"$running_file"
        printf "Machine started\n"
        ;;
      stop)
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

  write_fast_rootless_test_stub "$stub_dir/docker_socket_rootless_test"

  capture_command FIXTURE8_OUTPUT FIXTURE8_STATUS env \
    NO_COLOR=1 \
    HOME="$work_dir/home" \
    TMPDIR="$work_dir" \
    PODMAN_TEST_STATE_DIR="$work_dir/state" \
    PATH="$stub_dir:$PATH" \
    PODMAN_TROUBLESHOOT_STABILITY_SLEEP_SECONDS=0 \
    PODMAN_TROUBLESHOOT_TEST_MODE=1 \
    PODMAN_TROUBLESHOOT_DOCKER_SOCKET_TEST_BIN="$stub_dir/docker_socket_rootless_test" \
    bash --noprofile --norc -c "cd '$work_dir' && '$SCRIPT_UNDER_TEST' --fix --force"

  rm -rf "$work_dir"
}

# Assertion functions - each verifies one aspect of a cached fixture
test_journald_io_errors_trigger_actionable_recovery_hint() {
  run_fixture2_log_health_journald
  assert_status "0" "$FIXTURE2_STATUS" "podman_troubleshoot completes successfully"
  assert_contains "$FIXTURE2_OUTPUT" "Machine Log Health" "script reaches the log health section"
  assert_contains "$FIXTURE2_OUTPUT" "Docker Socket Rootless Test" "script reaches the Docker socket rootless section"
  assert_contains "$FIXTURE2_OUTPUT" "bin/docker_socket_rootless_test --port 8080" "script points to the high-port smoke test"
  assert_contains "$FIXTURE2_OUTPUT" "docker_socket_rootless_test is available" "script finds the adjacent smoke test when run from another directory"
  assert_contains "$FIXTURE2_OUTPUT" "[ACTION] vfkit log shows repeated journald I/O errors" "journald I/O errors are promoted to an actionable message"
  assert_contains "$FIXTURE2_OUTPUT" "VM-local customizations, images, volumes, and container state" "script warns that rebuilding discards VM-local state"
  assert_contains "$FIXTURE2_OUTPUT" "podman_troubleshoot --fix" "script points to the runnable recovery command instead of a shell-only helper"
  assert_contains "$FIXTURE2_OUTPUT" "check(s) need attention" "script no longer reports all checks as passing"
  assert_not_contains "$FIXTURE2_OUTPUT" "all checks passed" "script does not mark the run as clean when journald I/O errors are present"
}

test_emergency_mode_log_triggers_rebuild_hint() {
  run_fixture3_log_health_emergency
  assert_status "0" "$FIXTURE3_STATUS" "podman_troubleshoot completes successfully with emergency-mode log hints"
  assert_contains "$FIXTURE3_OUTPUT" "[ACTION] vfkit log shows the VM booted into emergency mode" "emergency-mode boot is promoted to an action item"
  assert_contains "$FIXTURE3_OUTPUT" "podman machine rm -f podman-machine-default" "script recommends a rebuild for emergency-mode boots"
  assert_contains "$FIXTURE3_OUTPUT" "podman_troubleshoot --fix" "script keeps the new runnable recovery entrypoint in the follow-up steps"
  assert_not_contains "$FIXTURE3_OUTPUT" "/podman//podman-machine-default.log" "log path does not contain a doubled slash"
  assert_not_contains "$FIXTURE3_OUTPUT" "/T//podman/podman-machine-default.log" "TMPDIR with a trailing slash is normalized in log paths"
}

test_benign_ignition_boot_lines_do_not_mark_log_unhealthy() {
  run_fixture1_log_health_healthy
  assert_status "0" "$FIXTURE1_STATUS" "podman_troubleshoot completes successfully with benign ignition log lines"
  assert_contains "$FIXTURE1_OUTPUT" "[OK] vfkit log does not show obvious startup errors" "benign ignition boot lines keep the log health section green"
  assert_not_contains "$FIXTURE1_OUTPUT" "suspicious log entries:" "benign ignition boot lines are not printed as suspicious"
}

test_rootless_privileged_port_policy_surfaces_missing_389_setting() {
  run_fixture4_port389_blocked
  assert_status "0" "$FIXTURE4_STATUS" "podman_troubleshoot completes successfully when port 389 policy is blocked"
  assert_contains "$FIXTURE4_OUTPUT" "Rootless Privileged Port Policy" "script reaches the privileged port policy section"
  assert_contains "$FIXTURE4_OUTPUT" "[TROUBLESHOOT] rootless host port 389 is still blocked inside the Podman VM" "blocked rootless port 389 is surfaced as a troubleshooting issue"
  assert_contains "$FIXTURE4_OUTPUT" "podman-allow-port-389" "script points to the runnable helper for port 389"
  assert_contains "$FIXTURE4_OUTPUT" "net.ipv4.ip_unprivileged_port_start=1024" "script shows the current VM sysctl value"
}

test_starting_machine_is_not_reported_as_healthy() {
  run_fixture5_starting_machine
  assert_status "0" "$FIXTURE5_STATUS" "podman_troubleshoot completes successfully with a starting machine"
  assert_contains "$FIXTURE5_OUTPUT" "[TROUBLESHOOT] default Podman machine is still starting" "starting machines are surfaced as an issue"
  assert_not_contains "$FIXTURE5_OUTPUT" "[OK] default Podman machine is running" "starting machines are not reported as healthy"
}

test_verbose_flag_prints_progress_lines() {
  run_fixture6_verbose
  assert_status "0" "$FIXTURE6_STATUS" "podman_troubleshoot completes successfully with --verbose"
  assert_contains "$FIXTURE6_OUTPUT" "[VERBOSE] running: podman version --format" "verbose mode shows executed commands"
  assert_contains "$FIXTURE6_OUTPUT" "[VERBOSE] probing registry-1.docker.io by resolved IP inside the VM" "verbose mode shows long-running probe context"
}

test_fix_force_starts_machine_refreshes_socket_and_verifies() {
  run_fixture7_fix_force
  assert_status "0" "$FIXTURE7_STATUS" "podman_troubleshoot --fix --force completes successfully"
  assert_contains "$FIXTURE7_OUTPUT" "== Podman Fix ==" "fix mode prints its own section"
  assert_contains "$FIXTURE7_OUTPUT" "[OK] Podman machine started" "fix mode starts the stopped machine"
  assert_contains "$FIXTURE7_OUTPUT" "[OK] stable Podman socket refreshed" "fix mode refreshes the stable socket"
  assert_contains "$FIXTURE7_OUTPUT" "[OK] default Podman connection aligned" "fix mode sets the default connection"
  assert_contains "$FIXTURE7_OUTPUT" "[OK] rootless privileged port floor updated for port 389" "fix mode applies the rootless port 389 sysctl"
  assert_contains "$FIXTURE7_OUTPUT" "[OK] podman ps succeeded after fix" "fix mode verifies podman ps"
  assert_contains "$FIXTURE7_OUTPUT" "[OK] podman info succeeded after fix" "fix mode verifies podman info"
}

test_fix_force_recreates_low_memory_machine() {
  run_fixture8_fix_force_lowmem
  assert_status "0" "$FIXTURE8_STATUS" "podman_troubleshoot --fix --force completes successfully with a low-memory machine"
}

run_tests "$@"
