#!/usr/bin/env bash

# PURPOSE: Migrate macOS from Docker Desktop to a high-performance, free Podman setup.
# 1. Purges Docker Desktop (app, virtual disks, and build caches) to reclaim GBs of space.
# 2. Installs Podman + Docker-Compose V2 via Homebrew and initializes a 6-CPU VM.
# 3. Switches from "Shell Aliases" to "System Shims" in /usr/local/bin.
#    - Pitfall: Aliases fail in scripts like 'bin/setup.sh'. Shims solve this.
# 4. Implements a "Double-Link" socket architecture (Root -> User -> VM).
#    - Satisfies root-seeking tools (lazydocker) without requiring sudo after setup.
# 5. Configures Podman to use official Docker-Compose V2 as the backend provider.
#
# PITFALLS COVERED:
# - Alias Overlap: Script blocks execution if 'alias docker' is detected in dotfiles.
# - Transient Sockets: Includes 'podman-fix' to re-sync links when the VM restarts.
# - Path Conflicts: Surgically removes legacy binaries while sparing Homebrew paths.

# --- Configuration & Variables ---
STABLE_USER_SOCK=".local/share/containers/podman/machine/podman.sock"
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
DOTFILES_DIR="$(cd "$SCRIPT_DIR/.." && pwd)"

detect_shell() {
    if [[ "$SHELL" == *"zsh"* ]]; then
        CONF_FILE="$HOME/.zshrc"
    elif [[ "$SHELL" == *"bash"* ]]; then
        CONF_FILE="$HOME/.bash_profile"
        [[ ! -f "$CONF_FILE" ]] && CONF_FILE="$HOME/.bashrc"
    else
        echo "⚠️ Unknown shell. Manual setup required."
        exit 1
    fi
}

purge_docker() {
    echo "🧹 Purging Docker Desktop and reclaiming disk space..."

    # 1. Gracefully shut down Docker Desktop
    osascript -e 'quit app "Docker"' 2>/dev/null
    sleep 2

    # 2. Reclaim Disk Space
    rm -rf ~/Library/Containers/com.docker.docker \
           ~/Library/Group\ Containers/group.com.docker \
           ~/Library/Application\ Support/Docker\ Desktop 2>/dev/null

    # 3. Surgical Binary Removal
    # We remove binaries that are NOT Homebrew-managed and NOT Podman shims
    for cmd in docker docker-compose; do
        paths=$(which -a "$cmd" 2>/dev/null)
        for p in $paths; do
            # Skip Homebrew paths
            [[ "$p" == *"/opt/homebrew/"* ]] && continue
            [[ "$p" == *"/Cellar/"* ]] && continue

            # Skip if it's a symlink already pointing to podman or brew's compose
            if [ -L "$p" ]; then
                target=$(readlink "$p")
                [[ "$target" == *"podman"* ]] && continue
                [[ "$target" == *"docker-compose"* ]] && continue
            fi

            echo "🗑️ Removing legacy binary: $p"
            sudo rm -f "$p" 2>/dev/null
        done
    done
}

install_tooling() {
    if ! command -v brew >/dev/null 2>&1; then
        echo "❌ Homebrew (brew) not found. Aborting."
        exit 1
    fi

    ensure_brew_formula() {
        local formula="$1"
        if brew list --formula --versions "$formula" >/dev/null 2>&1; then
            echo "✅ $formula already installed."
        else
            echo "📦 Installing $formula..."
            brew install "$formula"
        fi
    }

    ensure_brew_cask() {
        local cask="$1"
        if brew list --cask --versions "$cask" >/dev/null 2>&1; then
            echo "✅ $cask already installed."
        else
            echo "📦 Installing $cask..."
            brew install --cask "$cask"
        fi
    }

    echo "📦 Checking dependencies..."
    ensure_brew_formula podman
    ensure_brew_formula docker-compose
    ensure_brew_cask podman-desktop
}

init_podman() {
    if ! podman machine inspect podman-machine-default >/dev/null 2>&1; then
        echo "🤖 Initializing fresh High-Performance Podman machine..."
        # Simplified for Podman 5.7.1 compatibility
        # Defaults to AppleHV + VirtioFS on M-series Macs
        podman machine init \
            --cpus 6 \
            --memory 9000 \
            --disk-size 100 \
            --rootful=false
    fi

    echo "🚀 Starting Podman machine..."
    podman machine start 2>/dev/null || echo "ℹ️ Machine already running."
}
configure_shell() {
    echo "📝 Injecting configuration into $CONF_FILE..."

    # 1. Inject podman-fix function
    if ! grep -q "podman-fix()" "$CONF_FILE"; then
        cat << 'EOF' >> "$CONF_FILE"

# Refreshes the user-space symlink to the transient Podman VM socket
podman-fix() {
    local CURRENT_VM_SOCK=$(podman machine inspect --format '{{.ConnectionInfo.PodmanSocket.Path}}' 2>/dev/null)
    if [ -z "${CURRENT_VM_SOCK}" ]; then
        echo "❌ Podman machine is not running."
        return 0
    fi
    local STABLE_SOCK="${HOME}/.local/share/containers/podman/machine/podman.sock"
    mkdir -p "$(dirname "${STABLE_SOCK}")"
    ln -sf "${CURRENT_VM_SOCK}" "${STABLE_SOCK}"
    echo "🔗 Symlink refreshed: ${STABLE_SOCK} -> ${CURRENT_VM_SOCK}"
}
EOF
    fi

    # 2. Inject DOCKER_HOST for socket-based tools (lazydocker/compose)
    grep -q "export DOCKER_HOST" "${CONF_FILE}" || \
        echo "export DOCKER_HOST=\"unix://\${HOME}/${STABLE_USER_SOCK}\"" >> "$CONF_FILE"

    # 2b. Force Podman CLI to reuse Docker's auth store
    if ! grep -q "REGISTRY_AUTH_FILE" "$CONF_FILE"; then
        echo "export REGISTRY_AUTH_FILE=\"\${HOME}/.docker/config.json\"" >> "$CONF_FILE"
    fi

    # 3. Force 'docker compose' to use the official brew binary
    if ! grep -q "export PODMAN_COMPOSE_PROVIDER" "${CONF_FILE}"; then
        echo "export PODMAN_COMPOSE_PROVIDER=\"$(brew --prefix)/bin/docker-compose\"" >> "$CONF_FILE"
    fi

    # 4. Silence Podman advisory messages
    if ! grep -q "export PODMAN_ADVISORY_MODE" "${CONF_FILE}"; then
        echo "export PODMAN_ADVISORY_MODE=false" >> "${CONF_FILE}"
    fi

    # 5. Provide a helper function for port 443
    if ! grep -q "podman-allow-port-443" "${CONF_FILE}"; then
        cat << 'EOF' >> "${CONF_FILE}"

# Allows rootless Podman containers to listen on privileged ports like 443.
podman-allow-port-443() {
    echo "⚠️ Running sudo inside the Podman VM to open port 443 (one-time change)."
    podman machine ssh "echo 'net.ipv4.ip_unprivileged_port_start=443' | sudo tee /etc/sysctl.d/99-unprivileged-ports.conf >/dev/null && sudo sysctl --system"
}
EOF
    fi

    # 6. Performance Optimization: Parallel Pulls and DNS speedup
    if ! grep -q "export PODMAN_PULL_PARALLEL" "$CONF_FILE"; then
        echo "export PODMAN_PULL_PARALLEL=5" >> "$CONF_FILE"
        echo "export GODEBUG=netdns=go" >> "$CONF_FILE"
    fi
}

configure_registry_auth() {
    echo "🔐 Unifying Podman/Docker registry credentials..."

    local CONTAINERS_DIR="${HOME}/.config/containers"
    local CONTAINERS_CONF="${CONTAINERS_DIR}/containers.conf"
    local CONTAINERS_TEMPLATE="${DOTFILES_DIR}/config/containers/containers.conf"
    local PODMAN_RUNTIME_AUTH="${CONTAINERS_DIR}/auth.json"
    local DOCKER_DIR="${HOME}/.docker"
    local DOCKER_CONF="${DOCKER_DIR}/config.json"
    local DOCKER_CONF_LITERAL="${HOME}/.docker/config.json"

    mkdir -p "$CONTAINERS_DIR" "$DOCKER_DIR"

    if [ ! -e "$CONTAINERS_CONF" ] && [ -f "$CONTAINERS_TEMPLATE" ]; then
        ln -sf "$CONTAINERS_TEMPLATE" "$CONTAINERS_CONF"
    fi

    if [ ! -e "$CONTAINERS_CONF" ]; then
        cat <<'EOF' > "$CONTAINERS_CONF"
# Base Podman configuration managed by migrate-docker-to-podman.sh.
[engine]
EOF
    fi

    if [ ! -f "$DOCKER_CONF" ]; then
        echo '{"auths":{}}' > "$DOCKER_CONF"
    fi

    if [ -f "$PODMAN_RUNTIME_AUTH" ]; then
        if command -v python3 >/dev/null 2>&1; then
            SOURCE="$PODMAN_RUNTIME_AUTH" TARGET="$DOCKER_CONF" python3 <<'PY'
import json, os, sys
from pathlib import Path

src = Path(os.environ['SOURCE'])
dst = Path(os.environ['TARGET'])

try:
    src_data = json.loads(src.read_text())
except Exception:
    sys.exit(0)

try:
    dst_data = json.loads(dst.read_text())
except Exception:
    dst_data = {}

dst_auths = dst_data.setdefault('auths', {})
for registry, creds in src_data.get('auths', {}).items():
    dst_auths[registry] = creds

dst.write_text(json.dumps(dst_data, indent=2) + "\n")
PY
        else
            cp "$PODMAN_RUNTIME_AUTH" "$DOCKER_CONF"
        fi

        rm -f "$PODMAN_RUNTIME_AUTH"
    fi

    local TMP_FILE
    TMP_FILE=$(mktemp)

    awk -v path="$DOCKER_CONF_LITERAL" '
        BEGIN {
            inserted=0
            seen_engine=0
        }
        /^authfile=/ {
            if (!inserted) {
                print "authfile=\"" path "\""
                inserted=1
            }
            next
        }
        {
            print
            if ($0 ~ /^\[engine\]/) {
                seen_engine=1
                if (!inserted) {
                    print "authfile=\"" path "\""
                    inserted=1
                }
            }
        }
        END {
            if (!seen_engine) {
                print "[engine]"
            }
            if (!inserted) {
                print "authfile=\"" path "\""
            }
        }
    ' "$CONTAINERS_CONF" > "$TMP_FILE"

    cat "$TMP_FILE" > "$CONTAINERS_CONF"
    rm -f "$TMP_FILE"

    local service_is_remote=""
    service_is_remote=$(podman info --format '{{.Host.ServiceIsRemote}}' 2>/dev/null || true)

    if [[ "$service_is_remote" != "true" ]]; then
        local reported_auth
        echo "podman info --format '{{.Registries.AuthFile}}'"
        if reported_auth=$(podman info --format '{{.Registries.AuthFile}}' 2>/dev/null); then
            if [ -n "$reported_auth" ] && [ "$reported_auth" != "$DOCKER_CONF_LITERAL" ]; then
                echo "❌ Podman still reports authfile at $reported_auth. Please inspect $CONTAINERS_CONF"
                exit 1
            fi
        else
            echo "⚠️ Unable to verify Podman authfile via 'podman info'. Continuing, but run 'podman info --format \"{{.Registries.AuthFile}}\"' later to confirm."
        fi
    else
        echo "ℹ️ Detected remote Podman machine; skipping 'podman info' authfile verification because the remote host reports its own config path."
    fi
}

setup_binaries() {
    echo "🔗 Creating global binary shims for script compatibility..."
    local PODMAN_BIN=$(which podman)
    local COMPOSE_BIN="$(brew --prefix)/bin/docker-compose"
    local TARGET_DIR="/usr/local/bin"


    # Link 'docker' -> 'podman'
    if [[ "$(readlink "$TARGET_DIR/docker")" != "$PODMAN_BIN" ]]; then
        echo "🍺 Linking $TARGET_DIR/docker -> $PODMAN_BIN"
        ln -vsf "$PODMAN_BIN" "$TARGET_DIR/docker"
    fi

    # Link 'docker-compose' -> brew version (for legacy script support)
    if [[ "$(readlink "$TARGET_DIR/docker-compose")" != "$COMPOSE_BIN" ]]; then
        echo "🍺 Linking $TARGET_DIR/docker-compose -> $COMPOSE_BIN"
        ln -vsf "$COMPOSE_BIN" "$TARGET_DIR/docker-compose"
    fi
}

setup_links() {
    echo "🔐 Bridging /var/run/docker.sock to user-space (sudo required)..."
    if [ ! -L "/var/run/docker.sock" ]; then
        sudo ln -sf "${HOME}/${STABLE_USER_SOCK}" /var/run/docker.sock
    fi

    echo "🔗 Linking stable user socket..."
    mkdir -p "$(dirname "${HOME}/${STABLE_USER_SOCK}")"
    local CURRENT_VM_SOCK=$(podman machine inspect --format '{{.ConnectionInfo.PodmanSocket.Path}}' 2>/dev/null)
    if [ -n "$CURRENT_VM_SOCK" ]; then
        ln -sf "$CURRENT_VM_SOCK" "${HOME}/${STABLE_USER_SOCK}"
    fi
}

cleanup_aliases() {
    echo "🔍 Checking for conflicting shell aliases..."

    # Check if 'docker' is currently an alias in the active environment
    if alias docker >/dev/null 2>&1; then
        echo -e "\033[0;31m"
        echo "********************************************************"
        echo "❌ ERROR: CONFLICTING ALIAS DETECTED"
        echo "********************************************************"
        echo "The 'docker' alias is still active in your shell."
        echo "This will override the new system shim at /usr/local/bin/docker."
        echo ""
        echo "Please remove the following line from $CONF_FILE:"
        grep -n "alias docker=" "$CONF_FILE" | sed 's/^/Line /'
        echo ""
        echo "After removing it, restart your terminal and run this script again."
        echo "********************************************************"
        echo -e "\033[0m"
        exit 1
    fi

    echo "✅ No conflicting aliases found in the current environment."
}

run_main() {
    detect_shell
    purge_docker
    install_tooling
    init_podman
    configure_registry_auth
    configure_shell
    setup_binaries
    cleanup_aliases
    setup_links

    echo "✨ Migration complete! Run: source $CONF_FILE"
    echo "💡 Use 'docker login <registry>' going forward so Podman and docker-compose remain in sync."
}

if [[ "${BASH_SOURCE[0]}" == "$0" ]]; then
    run_main
fi
