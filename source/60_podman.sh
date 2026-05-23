# shellcheck shell=bash

podman-default-machine-name() {
    podman machine list --format json 2>/dev/null | jq -r '.[] | select(.Default == true) | .Name' 2>/dev/null | head -n1
}

# Refreshes the user-space symlink to the transient Podman VM socket
podman-fix() {
    local MACHINE_NAME
    MACHINE_NAME="$(podman-default-machine-name)"
    if [ -z "${MACHINE_NAME}" ]; then
        echo "❌ No default Podman machine is configured."
        return 1
    fi

    local CURRENT_VM_SOCK
    CURRENT_VM_SOCK="$(podman machine inspect "${MACHINE_NAME}" --format '{{.ConnectionInfo.PodmanSocket.Path}}' 2>/dev/null)"
    if [ -z "${CURRENT_VM_SOCK}" ]; then
        echo "❌ Podman machine '${MACHINE_NAME}' is not running."
        return 1
    fi

    local STABLE_SOCK="${HOME}/.local/share/containers/podman/machine/podman.sock"
    mkdir -p "$(dirname "${STABLE_SOCK}")"
    ln -sf "${CURRENT_VM_SOCK}" "$STABLE_SOCK"

    if podman system connection default "${MACHINE_NAME}" >/dev/null 2>&1; then
        echo "✅ Default Podman connection set to '${MACHINE_NAME}'"
    fi

    echo "🔗 Symlink refreshed: $STABLE_SOCK -> ${CURRENT_VM_SOCK}"
}
export DOCKER_HOST="unix://${HOME}/.local/share/containers/podman/machine/podman.sock"
export PODMAN_COMPOSE_PROVIDER="/opt/homebrew/bin/docker-compose"
export PODMAN_ADVISORY_MODE=false

# Allows rootless Podman containers to listen on privileged ports like 443.
# Warns that sudo will be invoked inside the Podman VM during the one-time change.
podman-allow-port-443() {
    echo "⚠️ Running sudo inside the Podman VM to open port 443 (one-time change)."
    podman machine ssh "echo 'net.ipv4.ip_unprivileged_port_start=443' | sudo tee /etc/sysctl.d/99-unprivileged-ports.conf >/dev/null && sudo sysctl --system"
}
export REGISTRY_AUTH_FILE="${HOME}/.docker/config.json"
export PODMAN_PULL_PARALLEL=5
export GODEBUG=netdns=go
