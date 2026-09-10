# Podman Setup Specification

**Status:** Active operational spec for rootless Podman on macOS  
**Maintained by:** `bin/podman_troubleshoot` and related tools  
**Last updated:** 2026-09-10

---

## Overview

This specification defines the operational setup for a rootless Podman environment on macOS that:
- Supports CLI workflows (`podman`, `docker`, `docker compose`)
- Enables Docker-compatible clients inside containers (Traefik, etc.)
- Maintains safety invariants across repairs and reconfigurations
- Provides diagnostic and self-healing capabilities

**Core principle:** Repairs are opt-in via `--fix` flag; default behavior is read-only diagnostics.

---

## Requirements: The 4 Non-Negotiables

Any Podman operation in this setup **must maintain** these invariants.

### 1. Rootless Mode (Always)

**Requirement:** Podman machine runs with `rootful=false`

**Why:**
- Avoids `sudo` in daily workflows
- Smaller container escape attack surface
- Matches Docker Desktop UX expectations on macOS

**How it's maintained:**
- `bin/podman_troubleshoot --fix` detects and converts rootful machines back to rootless
- `bin/podman_troubleshoot --init` creates new machines with `--rootful=false`
- Repair tools refuse to leave system in rootful state

**Verification:**
```bash
podman machine inspect podman-machine-default --format '{{.Rootful}}'
# Expected: false
```

---

### 2. Lower Ports Allowed (Down to :443)

**Requirement:** Rootless containers bind host ports down to 443

**Why:**
- Traefik and production-like reverse proxies need port 443
- Without this: `rootlessport cannot expose privileged port 443` errors
- Fix is idempotent and non-destructive (VM sysctl only)

**How it's maintained:**
- `bin/podman_troubleshoot --fix` sets `net.ipv4.ip_unprivileged_port_start=443` inside VM
- `podman-allow-port-443` utility does this on-demand
- Setting lives in VM `/etc/sysctl.d/99-unprivileged-ports.conf`

**Verification:**
```bash
podman machine ssh 'sysctl net.ipv4.ip_unprivileged_port_start'
# Expected: net.ipv4.ip_unprivileged_port_start = 443
```

---

### 3. Multiarchitecture Image Support

**Requirement:** `podman buildx` works for cross-architecture builds (`linux/amd64`, `linux/arm64`)

**Why:**
- CI/CD and local dev need to build images for both Intel and Apple Silicon
- Without `qemu` in VM: multiarch builds fail silently or error

**How it's maintained:**
- Machine initialized with 9 CPUs, 8GB RAM (supports `qemu` emulation)
- `bin/podman_troubleshoot --fix` recreates machine if memory falls below 4GB threshold
- VM image includes `qemu-user-static` or equivalent

**Verification:**
```bash
podman run --rm --platform linux/amd64 alpine uname -m
# Expected: x86_64 (via qemu)

podman machine inspect podman-machine-default --format '{{.Resources.CPUs}} {{.Resources.Memory}}'
# Expected: 9 8192 (or higher)
```

---

### 4. Integration Preservation

**Requirement:** Repairs must not break established dotfiles integrations

#### Shell Environment (`source/60_podman.sh`)
- Sets `DOCKER_HOST` to stable socket path
- Configures `PODMAN_COMPOSE_PROVIDER` for Docker Compose V2
- Provides machine detection utilities

**Safety:** Never modified by repair tools. Socket symlink refreshed but always points to stable location.

#### Docker Socket (`/var/run/docker.sock`)
- Optional symlink to Podman VM socket (for `docker` CLI)
- Validated but not forcibly created or modified by repairs

**Safety:** Repairs validate state, don't overwrite custom setups.

#### Docker Compose Integration
- Both `docker compose` and `podman-compose` work from CLI
- `DOCKER_HOST` env var provides connection
- Compose files run unmodified in VM

**Safety:** Repairs maintain connection defaults, don't force provider changes.

#### Traefik-in-Container (`bin/docker_socket_rootless_test`)
- Containers mount VM-internal socket: `/run/user/<uid>/podman/podman.sock`
- Requires SELinux label disable: `security_opt: [label=disable]`
- Separate from host-side socket path

**Safety:** Repairs never modify container compose files or mount paths.

---

## Architecture: Verified Constraints

These constraints were validated in practice and are baked into the setup.

### Host vs. Container Socket Paths (Different)

**Host-side (macOS):**
- Transient path: `$TMPDIR/podman/podman-machine-default-api.sock`
- Stable symlink: `${HOME}/.local/share/containers/podman/machine/podman.sock`
- Used for: `DOCKER_HOST`, host CLI tools, Docker-compatible clients

**Container-side (VM):**
- VM-internal path: `/run/user/503/podman/podman.sock` (replace 503 with actual UID)
- Used for: containers mounting the Docker socket
- NOT the transient host path

**Why:** Transient host path is specific to macOS socket forwarding. Containers need the VM-internal socket for direct access.

---

### SELinux Labeling for Container Access

**Problem:** Inside the VM (SELinux enforcing), a rootless container gets permission denied on the mounted socket even with matching UID/GID and `--userns keep-id`.

**Solution:** Disable SELinux labeling in container compose:

```yaml
security_opt:
  - label=disable
```

This is required for Traefik and similar Docker-socket-reading containers.

---

### Rootless Container Port Binding Limits

**Constraint:** Rootless containers cannot bind privileged ports (< 1024) unless VM sysctl allows it.

**Default behavior:** Fails with `rootlessport cannot expose privileged port 443`

**Fix:** Set `net.ipv4.ip_unprivileged_port_start=443` inside VM (automated by `--fix`)

**Workaround for development:** Bind to unprivileged ports internally (e.g., `:8080` inside container, publish host `8080:8080`)

---

## Diagnostic & Self-Healing Architecture

### Primary Tool: `bin/podman_troubleshoot`

**Default behavior (no flags):** Read-only diagnostics
```bash
bin/podman_troubleshoot
# Shows status, identifies issues, suggests "Run: --fix"
# Zero changes made to system
```

**Repair mode (`--fix`):** Diagnostics + optional fixes
```bash
bin/podman_troubleshoot --fix
# Runs checks, prompts before each fix, applies fixes with verification
# All operations interactive unless --force is passed
```

**Auto-repair mode (`--fix --force`):** Diagnostics + automatic fixes
```bash
bin/podman_troubleshoot --fix --force
# Applies all fixes without prompting
# Use only when confident all fixes are safe
```

**Initialization mode (`--init`):** Machine creation + convergence
```bash
bin/podman_troubleshoot --init
# Creates/starts machine, ensures rootless, refreshes socket, sets defaults
```

---

### Diagnostic Checks (Read-Only)

These checks observe system state without modification:

#### Basic System Checks
- **Podman Socket Connection:** Can CLI reach the VM API socket?
- **Local Client Versions:** What versions of docker/podman are installed?
- **Podman System Container:** What version of system container is running? Is update available?
- **Host Loopback 443:** Is anything listening on host port 443?
- **Global Docker Socket:** Does `/var/run/docker.sock` point to Podman?

#### Machine State Checks
- **Podman Machine List:** Can we list machines?
- **Podman Machine Alignment:** Do default machine and connection match?
- **Podman Machine Running State:** Is the machine running?
- **Machine Stability After Start:** Does vfkit/gvproxy stay alive (10-second test)?
- **Machine Start Lock:** Are there stale lock files?
- **Machine Log Health:** Does vfkit log show startup errors?

#### VM Health Checks
- **VM Clock Sync:** Is VM clock in sync with host (after hibernation)?
- **Rootless Privileged Port Policy:** Does VM allow port 443 binding?
- **VM DNS and Registry:** Can VM reach Docker registries by name and IP?
- **VM Registry IP Probes:** Can VM reach registry-1.docker.io by each resolved IP?
- **VM Runtime State:** Are VM runtime directories accessible?

#### Diagnostics Checks
- **Machine Stability:** Runs `podman ps` at T+0s and T+10s to detect vfkit exit during/after boot
- **Container HTTPS Egress:** Probes HTTPS from host, VM, and container to isolate network failures
- **Registry Auth State:** Is docker auth config readable?

#### Image Pull Checks
- **Target Image Pull:** Can we pull a specific test image?
- **Control Pull From Quay:** Can VM pull from quay.io?

---

### Self-Healing Fixes (`--fix` Mode)

These operations modify system state (all interactive unless `--force`):

| Fix | Trigger | Action | Safety |
|-----|---------|--------|--------|
| **Start Machine** | Machine stopped | Runs `podman machine start` | Prompted; VM data preserved |
| **Rootful → Rootless** | Machine in rootful mode | Sets `--rootful=false`, restarts | Prompted; data preserved |
| **Refresh Socket Symlink** | Symlink stale | Updates `~/.local/share/.../podman.sock` | Non-destructive |
| **Set Default Connection** | Connection misaligned | Sets default to rootless connection | Non-destructive |
| **Enable Port 443** | Sysctl not set to 443 | Sets `net.ipv4.ip_unprivileged_port_start=443` in VM | Idempotent; no data loss |
| **Sync VM Clock** | Clock drift > 10s | Runs `sudo chronyc makestep` inside VM | Idempotent; NTP-based |
| **Recreate Machine** | Memory ≤ 4GB | Stops, deletes, reinits with 8GB RAM | **Prompted; VM-local data lost** |

---

## Output & User Guidance

### Diagnostic Output (Read-Only Mode)

User sees clearly labeled sections:
- ✅ Passing checks
- ⚠️ Action items (non-critical)
- ❌ Troubleshoot items (needs attention)

Followed by dynamic recovery hints based on actual failures (not generic 15-item list).

### Self-Healing Output (`--fix` Mode)

User sees:
1. Diagnostic results
2. Each fix offered with prompt
3. User can approve (Enter), skip (n), or cancel
4. After all fixes, re-runs verification
5. Shows which fixes were applied and results

### Messages Updated for Clarity

**Before:**
```
[TROUBLESHOOT] Podman socket connection refused
    next: run podman_troubleshoot --fix to converge the machine and socket state
    next: if the machine still needs a manual reset, do this sequence:
      podman_troubleshoot --fix
      podman machine stop
      ...
    [6 more lines of generic steps]
```

**After:**
```
[TROUBLESHOOT] Podman socket connection refused
    next: run: bin/podman_troubleshoot --fix to start machine and align socket
    next: if you need rootless Traefik or other Docker-compatible clients, point them at:
      export DOCKER_HOST="unix://${HOME}/.local/share/containers/podman/machine/podman.sock"
```

---

## Usage Quick Start

### First-Time Setup
```bash
# Initialize new machine with all defaults
bin/podman_troubleshoot --init

# Verify everything
podman ps
podman info
docker ps
```

### After System Changes (hibernation, upgrades)
```bash
# Diagnose
bin/podman_troubleshoot --verbose

# Repair if needed
bin/podman_troubleshoot --fix
```

### Automated Repair (CI/deployment)
```bash
# Apply all fixes non-interactively
bin/podman_troubleshoot --fix --force --verbose
```

### Container Docker-Socket Access (Traefik)
```bash
# Verify integration works
bin/docker_socket_rootless_test --port 8080

# Expected output:
# ✅ Docker socket rootless routing is working on port 8080
```

### Port 443 for Rootless Containers
```bash
# One-time configuration after machine starts
podman-allow-port-443

# Verify
podman machine ssh 'sysctl net.ipv4.ip_unprivileged_port_start'
```

---

## Related Files

**Operational:**
- `bin/podman_troubleshoot` – Main diagnostic & self-healing tool
- `bin/podman-sync-clock` – One-shot clock sync utility
- `bin/podman-allow-port-443` – Port 443 configuration helper
- `bin/docker_socket_rootless_test` – Traefik integration smoke test
- `bin/migrate-docker-to-podman.sh` – Docker Desktop → Podman migration
- `source/60_podman.sh` – Shell environment setup

**Reference:**
- `docs/podman-rootless-plan.md` – Detailed architecture decisions (archived for reference)
- `docs/PLAN-podman-container-egress-handoff.md` – Diagnostic check design (archived for reference)

---

## Verification Checklist

After initialization or repair, verify in this order:

```bash
# 1. Machine and CLI health
podman ps
podman info
docker ps
podman system connection list

# 2. Stability
bin/podman_troubleshoot --init
podman ps

# 3. Port 443 (if needed)
podman-allow-port-443
podman ps

# 4. Docker-label routing (if using Traefik)
bin/docker_socket_rootless_test --port 8080

# 5. Expected output from step 4:
# ✅ Docker socket rootless routing is working on port 8080
```

---

## Troubleshooting Decision Tree

### Issue: `podman ps` fails (connection refused)
→ Run: `bin/podman_troubleshoot --fix`  
→ If persists: `bin/podman_troubleshoot --fix --force`

### Issue: Container can't access HTTPS (timeout)
→ Run: `bin/podman_troubleshoot`  
→ Check "Rootless Container HTTPS Egress" section  
→ If isolated to container egress: check firewall/proxy

### Issue: Traefik routes not working
→ Run: `bin/docker_socket_rootless_test --port 8080`  
→ Check socket mount path (must be `/run/user/<uid>/podman/podman.sock`)  
→ Check compose `security_opt: [label=disable]`

### Issue: Can't bind port 443
→ Run: `podman-allow-port-443`  
→ Verify: `podman machine ssh 'sysctl net.ipv4.ip_unprivileged_port_start'`

### Issue: Machine won't start
→ Run: `bin/podman_troubleshoot --verbose`  
→ Check vfkit log: `tail -100 $TMPDIR/podman/podman-machine-default.log`  
→ If emergency mode: machine rebuild required (see Spec)

---

## Design Principles

1. **Safety First:** Default is read-only; repairs are opt-in
2. **Operator Control:** Fixes prompt before execution (unless `--force`)
3. **Non-Destructive:** Repairs prefer idempotent operations over rebuilds
4. **Diagnostic Clarity:** Checks isolate problems (host vs. VM vs. container)
5. **Preserved Invariants:** All 4 requirements maintained by design
6. **Integration Aware:** Never breaks shell, socket, or compose setups
7. **Verbose Mode:** `--verbose` shows progress for debugging timeouts
8. **Commands Explicit:** All commands visible in backticks (`` `podman ps` ``); users learn tools through exposure
9. **Terse Output:** Descriptions concise; next steps exact and copy-pasteable

