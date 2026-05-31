# shellcheck shell=bash

podman_default_machine_name() {
    local MACHINE_LIST
    MACHINE_LIST="$(podman machine list 2>/dev/null || true)"
    [ -n "${MACHINE_LIST}" ] || return 1
    printf '%s\n' "${MACHINE_LIST}" | awk '
        NR > 1 {
            name = $1
            sub(/\*$/, "", name)
            if ($1 ~ /\*$/) {
                print name
                exit
            }
            if (NR == 2 && name != "") {
                single = name
            }
        }
        END {
            if (single != "") {
                print single
            }
        }
    '
}

podman_current_machine_name() {
    local MACHINE_NAME
    MACHINE_NAME="$(podman_default_machine_name || true)"
    if [ -n "${MACHINE_NAME}" ]; then
        printf '%s\n' "$MACHINE_NAME"
        return 0
    fi

    MACHINE_NAME="$(podman system connection list --format json 2>/dev/null || true)"
    MACHINE_NAME="$(printf '%s\n' "${MACHINE_NAME}" | jq -r '.[] | select(.Default == true) | .Name' 2>/dev/null | head -n1)"
    if [ -n "${MACHINE_NAME}" ]; then
        MACHINE_NAME="${MACHINE_NAME%-root}"
        printf '%s\n' "$MACHINE_NAME"
        return 0
    fi

    MACHINE_NAME="$(podman machine info 2>/dev/null || true)"
    MACHINE_NAME="$(printf '%s\n' "${MACHINE_NAME}" | awk -F': ' '/^    currentmachine:/ {print $2; exit}')"
    if [ -n "${MACHINE_NAME}" ]; then
        printf '%s\n' "$MACHINE_NAME"
        return 0
    fi

    MACHINE_NAME="$(podman machine list --format json 2>/dev/null || true)"
    MACHINE_NAME="$(printf '%s\n' "${MACHINE_NAME}" | jq -r 'if length == 1 then .[0].Name else empty end' 2>/dev/null | head -n1)"
    if [ -n "${MACHINE_NAME}" ]; then
        printf '%s\n' "$MACHINE_NAME"
        return 0
    fi

    return 1
}

podman_machine_rootful_connection_name() {
    local MACHINE_NAME
    MACHINE_NAME="$1"

    local ROOTFUL
    ROOTFUL="$(podman machine inspect "${MACHINE_NAME}" --format '{{.Rootful}}' 2>/dev/null || true)"
    if [ "$ROOTFUL" = "true" ]; then
        printf '%s-root\n' "$MACHINE_NAME"
    else
        printf '%s\n' "$MACHINE_NAME"
    fi
}

# Refreshes the user-space symlink to the transient Podman VM socket
podman_fix() {
    if command -v podman_troubleshoot >/dev/null 2>&1; then
        podman_troubleshoot --fix --force "$@"
        return $?
    fi

    local MACHINE_NAME
    MACHINE_NAME="$(podman_current_machine_name)"
    if [ -z "${MACHINE_NAME}" ]; then
        echo "❌ No current Podman machine could be resolved."
        return 1
    fi

    local CURRENT_VM_SOCK
    CURRENT_VM_SOCK="$(podman machine inspect "${MACHINE_NAME}" --format '{{.ConnectionInfo.PodmanSocket.Path}}' 2>/dev/null || true)"
    if [ -z "${CURRENT_VM_SOCK}" ]; then
        echo "❌ Podman machine '${MACHINE_NAME}' is not running."
        return 1
    fi

    local STABLE_SOCK="${HOME}/.local/share/containers/podman/machine/podman.sock"
    mkdir -p "$(dirname "${STABLE_SOCK}")"
    ln -sf "${CURRENT_VM_SOCK}" "$STABLE_SOCK"
    export DOCKER_HOST="unix://${CURRENT_VM_SOCK}"

    local CONNECTION_NAME
    CONNECTION_NAME="$(podman_machine_rootful_connection_name "${MACHINE_NAME}")"
    if podman system connection default "${CONNECTION_NAME}" >/dev/null 2>&1; then
        echo "✅ Active Podman system connection set to '${CONNECTION_NAME}'"
    fi

    echo "🔗 Symlink refreshed: $STABLE_SOCK -> ${CURRENT_VM_SOCK}"
}
export DOCKER_HOST="unix://${HOME}/.local/share/containers/podman/machine/podman.sock"
export PODMAN_COMPOSE_PROVIDER="/opt/homebrew/bin/docker-compose"
export PODMAN_ADVISORY_MODE=false

# Allows rootless Podman containers to listen on privileged ports like 443.
# Warns that sudo will be invoked inside the Podman VM during the one-time change.
podman_allow_port_443() {
    echo "⚠️ Running sudo inside the Podman VM to open port 443 (one-time change)."
    podman machine ssh "echo 'net.ipv4.ip_unprivileged_port_start=443' | sudo tee /etc/sysctl.d/99-unprivileged-ports.conf >/dev/null && sudo sysctl --system"
}
export REGISTRY_AUTH_FILE="${HOME}/.docker/config.json"
export PODMAN_PULL_PARALLEL=5
export GODEBUG=netdns=go

podman-default-machine-name() {
    podman_default_machine_name "$@"
}

podman-current-machine-name() {
    podman_current_machine_name "$@"
}

podman-machine-rootful-connection-name() {
    podman_machine_rootful_connection_name "$@"
}

podman-fix() {
    podman_fix "$@"
}

podman-allow-port-443() {
    podman_allow_port_443 "$@"
}
