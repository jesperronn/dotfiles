# shellcheck shell=bash

# Refreshes the user-space symlink to the transient Podman VM socket
podman-fix() {
    local CURRENT_VM_SOCK=$(podman machine inspect --format '{{.ConnectionInfo.PodmanSocket.Path}}' 2>/dev/null)
    if [ -z "${CURRENT_VM_SOCK}" ]; then
        echo "❌ Podman machine is not running."
        return 1
    fi
    local STABLE_SOCK="${HOME}/.local/share/containers/podman/machine/podman.sock"
    mkdir -p "$(dirname "${STABLE_SOCK}")"
    ln -sf "${CURRENT_VM_SOCK}" "$STABLE_SOCK"
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
