#!/usr/bin/env bash
# shellcheck disable=SC1090,SC1091,SC2016

set -euo pipefail

DOTFILES_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
SCRIPT_UNDER_TEST="$DOTFILES_ROOT/bin/podman_machine_init"

source "$DOTFILES_ROOT/bin/lib/bash_test.sh"

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

test_init_creates_and_starts_machine() {
  local work_dir=""
  local stub_dir=""
  local call_log=""
  local output=""
  local status=0

  work_dir="$(mktemp -d)"
  stub_dir="$work_dir/stub-bin"
  call_log="$work_dir/calls.log"
  mkdir -p "$stub_dir"

  write_stub "$stub_dir/podman" '
printf "%s\n" "$*" >> "${CALL_LOG}"
case "$1" in
  machine)
    case "$2" in
      inspect)
        exit 1
        ;;
      init)
        exit 0
        ;;
      start)
        exit 0
        ;;
      list)
        printf "[]\n"
        exit 0
        ;;
    esac
    ;;
esac
exit 0
'

  capture_command output status env \
    CALL_LOG="$call_log" \
    PATH="$stub_dir:$PATH" \
    "$SCRIPT_UNDER_TEST" podman-machine-default

  assert_status "0" "$status" "podman_machine_init exits successfully"
  assert_contains "$output" "Initializing fresh High-Performance Podman machine" "helper announces initialization when the machine is missing"
  assert_contains "$output" "Starting Podman machine" "helper starts the machine after initialization"
  assert_contains "$(cat "$call_log")" "machine init --cpus 9 --memory 8192 --disk-size 100 --rootful=false podman-machine-default" "helper passes the default cpus/memory to podman machine init without a stale ignition file"
  assert_contains "$(cat "$call_log")" "podman-machine-default" "helper uses the positional machine name syntax"
  assert_contains "$(cat "$call_log")" "machine start podman-machine-default" "helper starts the named machine"

  rm -rf "$work_dir"
}

test_init_converges_existing_rootful_machine_to_rootless() {
  local work_dir=""
  local stub_dir=""
  local call_log=""
  local state_file=""
  local output=""
  local status=0

  work_dir="$(mktemp -d)"
  stub_dir="$work_dir/stub-bin"
  call_log="$work_dir/calls.log"
  state_file="$work_dir/state"
  mkdir -p "$work_dir/home"
  mkdir -p "$stub_dir"
  printf 'rootful=true\nrunning=true\nsocket=/tmp/podman-machine-default.sock\n' >"$state_file"

  write_stub "$stub_dir/podman" '
set -euo pipefail
printf "%s\n" "$*" >> "${CALL_LOG}"

rootful_state() {
  sed -n "s/^rootful=//p" "${STATE_FILE}"
}

running_state() {
  sed -n "s/^running=//p" "${STATE_FILE}"
}

socket_path() {
  sed -n "s/^socket=//p" "${STATE_FILE}"
}

set_state() {
  local key="$1"
  local value="$2"
  tmp_file="${STATE_FILE}.tmp"
  awk -v key="$key" -v value="$value" -F= "BEGIN { OFS=\"=\" } \$1 == key { \$2 = value } { print }" "${STATE_FILE}" > "${tmp_file}"
  mv "${tmp_file}" "${STATE_FILE}"
}

case "$1" in
  machine)
    case "$2" in
      inspect)
        case "$*" in
          *Rootful*)
            printf "%s\n" "$(rootful_state)"
            exit 0
            ;;
          *ConnectionInfo.PodmanSocket.Path*)
            if [[ "$(running_state)" == "true" ]]; then
              printf "%s\n" "$(socket_path)"
              exit 0
            fi
            exit 1
            ;;
        esac
        exit 0
        ;;
      stop)
        set_state running false
        exit 0
        ;;
      set)
        set_state rootful false
        exit 0
        ;;
      start)
        set_state running true
        exit 0
        ;;
      list)
        printf "[{\\"Name\\":\\"podman-machine-default\\",\\"Default\\":true}]\n"
        exit 0
        ;;
    esac
    ;;
  system)
    case "$2" in
      connection)
        case "$3" in
          default)
            exit 0
            ;;
        esac
        ;;
    esac
    ;;
esac
exit 0
'

  capture_command output status env \
    CALL_LOG="$call_log" \
    HOME="$work_dir/home" \
    STATE_FILE="$state_file" \
    PATH="$stub_dir:$PATH" \
    "$SCRIPT_UNDER_TEST" podman-machine-default

  assert_status "0" "$status" "podman_machine_init converges existing machines"
  assert_contains "$output" "Reconfiguring podman-machine-default to rootless mode" "helper reconfigures rootful machines"
  assert_contains "$output" "Active Podman connection: podman-machine-default" "helper reports the rootless connection name"
  assert_contains "$(cat "$call_log")" "machine stop podman-machine-default" "helper stops the machine before changing rootful mode"
  assert_contains "$(cat "$call_log")" "machine set --rootful=false podman-machine-default" "helper switches the machine to rootless mode"
  assert_contains "$(cat "$call_log")" "machine start podman-machine-default" "helper starts the machine after reconfiguration"
  assert_contains "$(cat "$call_log")" "system connection default podman-machine-default" "helper points the default connection at the rootless machine"

  rm -rf "$work_dir"
}

run_tests "$@"
