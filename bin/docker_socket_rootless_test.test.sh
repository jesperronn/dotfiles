#!/usr/bin/env bash
# shellcheck disable=SC1090,SC1091,SC2016

set -euo pipefail

DOTFILES_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
SCRIPT_UNDER_TEST="$DOTFILES_ROOT/bin/docker_socket_rootless_test"

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

test_tester_generates_compose_file_and_probes_routes() {
  local work_dir=""
  local stub_dir=""
  local call_log=""
  local socket_path=""
  local output=""
  local status=0

  work_dir="$(mktemp -d)"
  stub_dir="$work_dir/stub-bin"
  call_log="$work_dir/calls.log"
  socket_target="$work_dir/podman-api.sock"
  socket_path="$work_dir/podman.sock"
  mkdir -p "$stub_dir"
  : >"$socket_target"
  ln -s "$socket_target" "$socket_path"

  write_stub "$stub_dir/podman" '
printf "%s\n" "$*" >> "${CALL_LOG}"
case "$1" in
  compose)
    case "$2" in
      version)
        exit 0
        ;;
      up|down)
        exit 0
        ;;
    esac
    exit 0
    ;;
esac
exit 0
'

  write_stub "$stub_dir/curl" '
case "$*" in
  *"/api/rawdata"*)
    printf "{\"http\":{\"routers\":{\"whoami@docker\":{}}}}\n"
    ;;
  *"whoami.docker.localhost"*)
    printf "Hostname: whoami-test\nHost: whoami.docker.localhost:8080\n"
    ;;
  *)
    exit 1
    ;;
esac
'

  capture_command output status env \
    CALL_LOG="$call_log" \
    PATH="$stub_dir:$PATH" \
    "$SCRIPT_UNDER_TEST" \
    --work-dir "$work_dir" \
    --keep-work-dir \
    --socket "$socket_path" \
    --port 8080

  assert_status "0" "$status" "docker_socket_rootless_test exits successfully"
  assert_contains "$output" "Docker socket rootless routing is working on port 8080" "helper reports success on a high port"
  assert_contains "$(cat "$call_log")" "compose -f $work_dir/compose.yml -p traefik-label-test up -d --remove-orphans --quiet-pull" "helper starts the compose stack"
  assert_contains "$(cat "$call_log")" "compose -f $work_dir/compose.yml -p traefik-label-test down -v --remove-orphans" "helper tears the stack down on exit"
  assert_contains "$(cat "$work_dir/compose.yml")" "8080:8080" "compose file maps a host port above 443"
  assert_contains "$(cat "$work_dir/compose.yml")" "$socket_target:/var/run/docker.sock" "compose file mounts the resolved socket target"
  assert_contains "$(cat "$work_dir/compose.yml")" 'user: "0:0"' "compose file runs Traefik as root"
  assert_contains "$(cat "$work_dir/compose.yml")" 'label=disable' "compose file disables SELinux labeling for the mounted socket"
  assert_contains "$(cat "$work_dir/compose.yml")" "traefik.http.routers.whoami.rule=Host(\`whoami.docker.localhost\`)" "compose file includes the whoami router label"
  assert_contains "$(cat "$work_dir/compose.yml")" "traefik.http.routers.dashboard.rule=Host(\`traefik.docker.localhost\`)" "compose file includes the Traefik dashboard router label"

  rm -rf "$work_dir"
}

test_tester_prefers_vm_internal_socket_path_without_realpath() {
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
  compose)
    case "$2" in
      version)
        exit 0
        ;;
      up|down)
        exit 0
        ;;
    esac
    exit 0
    ;;
  machine)
    case "$2" in
      list)
        printf "[{\"Name\":\"podman-machine-default\",\"Default\":true}]\n"
        ;;
      inspect)
        printf "false\n"
        ;;
    esac
    exit 0
    ;;
esac
exit 0
'

  write_stub "$stub_dir/jq" '
query="${*: -1}"
case "$query" in
  *"select(.Default == true) | .Name"*)
    printf "podman-machine-default\n"
    ;;
  *)
    cat
    ;;
esac
'

  write_stub "$stub_dir/curl" '
case "$*" in
  *"/api/rawdata"*)
    printf "{\"http\":{\"routers\":{\"whoami@docker\":{}}}}\n"
    ;;
  *"whoami.docker.localhost"*)
    printf "Hostname: whoami-test\nHost: whoami.docker.localhost:8080\n"
    ;;
  *)
    exit 1
    ;;
esac
'

  capture_command output status env \
    CALL_LOG="$call_log" \
    PATH="$stub_dir:$PATH" \
    TRAEFIK_DOCKER_SOCKET="/run/user/503/podman/podman.sock" \
    "$SCRIPT_UNDER_TEST" \
    --work-dir "$work_dir" \
    --keep-work-dir \
    --port 8080

  assert_status "0" "$status" "docker_socket_rootless_test accepts a VM-internal socket path"
  assert_contains "$(cat "$work_dir/compose.yml")" "/run/user/503/podman/podman.sock:/var/run/docker.sock" "compose file mounts the VM-internal socket path directly"

  rm -rf "$work_dir"
}

test_tester_prints_compose_and_container_logs_on_probe_failure() {
  local work_dir=""
  local stub_dir=""
  local call_log=""
  local socket_path=""
  local output=""
  local status=0

  work_dir="$(mktemp -d)"
  stub_dir="$work_dir/stub-bin"
  call_log="$work_dir/calls.log"
  socket_path="$work_dir/podman.sock"
  mkdir -p "$stub_dir"
  : >"$socket_path"

  write_stub "$stub_dir/podman" '
printf "%s\n" "$*" >> "${CALL_LOG}"
case "$1" in
  compose)
    case "$2" in
      version)
        exit 0
        ;;
      up|down)
        exit 0
        ;;
      ps)
        printf "NAME STATUS PORTS\ntraefik up 8080\n"
        exit 0
        ;;
      logs)
        if [[ "$5" == "traefik" ]]; then
          printf "traefik log line\n"
        else
          printf "whoami log line\n"
        fi
        exit 0
        ;;
    esac
    exit 0
    ;;
esac
exit 0
'

  write_stub "$stub_dir/curl" '
exit 1
'

  capture_command output status env \
    CALL_LOG="$call_log" \
    PATH="$stub_dir:$PATH" \
    "$SCRIPT_UNDER_TEST" \
    --work-dir "$work_dir" \
    --socket "$socket_path" \
    --port 8080

  assert_status "1" "$status" "docker_socket_rootless_test exits non-zero on probe failure"
  assert_contains "$output" "❌ docker_socket_rootless_test failed" "helper prints a clear failure header"
  assert_contains "$output" "== compose ps ==" "helper prints compose status on failure"
  assert_contains "$output" "== traefik logs ==" "helper prints Traefik logs on failure"
  assert_contains "$output" "== whoami logs ==" "helper prints whoami logs on failure"
  assert_contains "$output" "work dir kept for inspection" "helper preserves the work dir on failure"
  assert_contains "$output" "rerun with: docker_socket_rootless_test --keep-work-dir --socket $socket_path" "helper prints an actionable rerun command"

  rm -rf "$work_dir"
}

run_tests "$@"
