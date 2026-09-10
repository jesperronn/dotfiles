# Podman Troubleshoot: Safety Requirements & Repair Scope

This document defines the non-negotiable safety constraints for Podman troubleshooting and repairs in this dotfiles setup. These ensure that recovery operations never break the rest of the system.

**Primary tool:** `bin/podman_troubleshoot`  
**Architecture baseline:** `docs/podman-rootless-plan.md`

---

## Safety Requirements: The 4 Non-Negotiables

Any Podman repair (via `--fix`, `--init`, or manual steps) **must maintain** these properties:

### 1. Rootless Mode (Always)

**Requirement:** Podman machine must run as `rootful=false`

**Why:** 
- Rootless mode avoids the need for `sudo` in daily workflows
- Keeps container escape attack surface smaller
- Aligns with Docker Desktop's expected UX on macOS

**What the repair does:**
- `bin/podman_troubleshoot --fix` detects rootful machines and converts them back to rootless
- `bin/podman_troubleshoot --init` creates new machines with `--rootful=false` by default
- If a machine is rootful, both tools stop and reconfigure it before proceeding

**Safety:** The tooling will refuse to leave the system in rootful mode. If you deliberately need rootful for a specific operation, that's a separate, temporary state, not the repaired end-state.

---

### 2. Lower Ports Allowed (Down to :443)

**Requirement:** Rootless containers must be able to bind host port 443 (and lower)

**Why:**
- Traefik and other reverse proxies need port 443 for production-like local development
- Without this, `rootlessport cannot expose privileged port 443` errors break deployments
- The fix is idempotent and non-destructive (just sets a sysctl inside the VM)

**What the repair does:**
- `bin/podman_troubleshoot --fix` checks `net.ipv4.ip_unprivileged_port_start` inside the VM
- If it's higher than 443, reconfigures it to 443 via `/etc/sysctl.d/99-unprivileged-ports.conf`
- Alternatively, `podman-allow-port-443` does this on demand

**Safety:** This only affects the VM's kernel parameter. It doesn't open ports on the macOS host. Host firewalls remain intact. Containers still respect their own binding rules.

---

### 3. Multiarchitecture Image Support

**Requirement:** Podman must build and pull images for multiple architectures (`linux/amd64`, `linux/arm64`, etc.)

**Why:**
- CI/CD and local development often need to build images for both Intel and Apple Silicon Macs
- Without `qemu` in the VM, `podman buildx` will fail for cross-architecture builds

**What the repair does:**
- Machine initialization includes sufficient CPU/memory for `qemu` emulation (9 CPUs, 8GB RAM by default)
- `bin/podman_troubleshoot --fix` can recreate the machine with higher resources if memory is too low
- The VM image itself includes `qemu-user-static` or equivalent

**Safety:** Rebuilding the VM during a `--fix` step is prompted before execution (unless `--force` is passed). The VM is torn down and re-initialized only when memory is below the threshold (default: 4GB). Data inside the VM will be lost, but the stable socket path and configuration survive.

---

### 4. Integration with Other Dotfiles Setups

**Requirement:** Repairs must not break the following established integrations:

#### Shell Environment (`source/60_podman.sh`)
- Sets `DOCKER_HOST` to the stable socket path
- Configures `PODMAN_COMPOSE_PROVIDER` to use Docker Compose V2
- Provides utility functions for machine detection

**Safety:** Repair operations never modify shell startup files. The socket symlink is refreshed but always points to the same stable location.

#### Docker Socket Compatibility (`/var/run/docker.sock`)
- May be a symlink to the stable Podman socket (for `docker` CLI commands)
- Is validated but not forcibly created by repairs; it's optional
- If present, must point to the Podman VM socket, not Docker Desktop

**Safety:** Repairs validate socket state but don't overwrite existing setups. Use `podman_troubleshoot` to verify alignment, not as a force-sync for paths you've customized elsewhere.

#### Docker Compose Integration
- Both `docker compose` and `podman-compose` should work from the CLI
- `DOCKER_HOST` environment variable provides the connection
- Compose files run in the Podman VM without modification

**Safety:** Repair operations maintain the existing connection defaults. They don't force a provider switch; they ensure the connection is resolvable and healthy.

#### Traefik-in-Container (`bin/docker_socket_rootless_test`)
- Containers mount the VM-internal socket path: `/run/user/<uid>/podman/podman.sock`
- This is different from the host-side stable socket path
- SELinux label must be disabled for the container (`label=disable` in compose)

**Safety:** Repair operations never modify container compose files or mount paths. The smoke test (`docker_socket_rootless_test`) can validate integration separately.

---

## Tools & Coverage

### `bin/podman_troubleshoot` (Primary)

**Scope:** Diagnostic checks and convergence

#### Checks (read-only):
- Socket connection health
- Machine list and current state  
- Default connection alignment
- Machine stability after start (API responsiveness over 10 seconds)
- VM clock drift  
- Rootless privileged port policy
- Container HTTPS egress (distinguishes broken container network from broken runtime)
- Registry connectivity (Docker Hub, Quay)
- Image pull capability

#### Fixes (interactive, with prompts):
- Reconfigure rootful machines to rootless
- Restart stopped machines
- Refresh stable socket symlink
- Set default connection
- Configure port 443 for rootless (sysctl)
- Sync VM clock via chronyc
- Recreate machine if memory is too low

#### Modes:
- `bin/podman_troubleshoot` – Run all checks
- `bin/podman_troubleshoot --init` – Initialize/start a new or existing machine, converge rootless/socket state
- `bin/podman_troubleshoot --fix` – Run checks, prompt for each fix, apply fixes
- `bin/podman_troubleshoot --fix --force` – Run checks and apply all fixes without prompting
- `bin/podman_troubleshoot --verbose` – Show progress for long-running checks
- `bin/podman_troubleshoot <image>` – Include a pull test of a specific image

**Why it's safe:**
- All fixes are interactive (with `--force` override)
- Fixes are tested before and after via `verify_fix_result()`
- High-risk operations (machine recreate) are only triggered if thresholds are met
- No changes to shell config, compose files, or other dotfiles projects

**Diagnostic-only checks (never modify state):**
- Machine stability after start: Runs `podman ps` twice (10 seconds apart) to detect vfkit/gvproxy runtime lifecycle failures. Never restarts or stops the machine.
- Container HTTPS egress: Probes registry endpoints from host, VM, and a disposable rootless container to distinguish broken container networking from broken Podman runtime. Uses only cached images with `--rm` and short timeouts; never installs packages.

Both diagnostic checks maintain all safety invariants (rootless, port 443, multiarch, integration) and fail gracefully with actionable guidance if issues are detected.

### `bin/podman-sync-clock` (Utility)

**Scope:** One-shot clock synchronization

**Usage:** After host hibernation, if VM clock has drifted

**Why it's safe:**
- Runs `sudo chronyc makestep` inside the VM only
- Does not modify host or host firewall
- Idempotent; safe to run multiple times

---

## Redundant or Superseded Files

### `bin/podman_machine_init`

**Status:** ⚠️ **Superseded by `bin/podman_troubleshoot --init`**

**Details:**
- Line 582 of `podman_troubleshoot` notes: `init_machine()` was "inlined from the former bin/podman_machine_init"
- `podman_machine_init` is simpler and covers only initialization
- `podman_troubleshoot --init` includes all the same logic plus additional convergence checks

**Recommendation:**
- Keep for now if you rely on it in other tools or automation
- Prefer `bin/podman_troubleshoot --init` for new scripts
- Archive/deprecate once all callers switch to the troubleshoot tool
- Consider adding a `podman_machine_init` shim that calls `podman troubleshoot --init` if you want to maintain backwards compatibility

**Action:**
- [ ] Audit callers of `bin/podman_machine_init` (grep dotfiles and external tools)
- [ ] If no external callers, mark `podman_machine_init` as deprecated (comment header)
- [ ] If callers exist, create a shim or update them to use `--init`

### `bin/podman_machine_init.test.sh`

**Status:** ⚠️ **Superseded by `bin/podman_troubleshoot.test.sh`**

**Recommendation:** Archive after `podman_machine_init` is deprecated

### Other Podman Files (Keep)

- `bin/migrate-docker-to-podman.sh` – Migration script, not covered by troubleshoot, keep as-is
- `bin/podman-install-wake-handler` – System integration, independent of troubleshoot, keep as-is
- `source/60_podman.sh` – Shell environment, sourced in login shells, keep as-is
- `docs/podman-rootless-plan.md` – Architecture doc, referenced by troubleshoot, keep as-is
- `bin/docker_socket_rootless_test` – Smoke test for Traefik-in-container, independent, keep as-is

---

## Repair Workflow: Keeping It Safe

### For Interactive Repairs
```bash
# 1. Run diagnostics first (no changes)
bin/podman_troubleshoot

# 2. Review output; if issues are found:
bin/podman_troubleshoot --fix

# 3. For each fix, you'll be prompted. Review and confirm.
# 4. At the end, the tool re-runs checks to verify the fixes.
```

### For Automated Repairs (e.g., in CI or setup scripts)
```bash
# Only when absolutely certain all fixes should apply:
bin/podman_troubleshoot --fix --force
```

### After Major Events
- **Host hibernation:** Run `bin/podman-sync-clock` or `bin/podman_troubleshoot --fix`
- **Podman upgrade:** Run `bin/podman_troubleshoot`
- **Machine state confusion:** Run `bin/podman_troubleshoot --fix --force`

---

## Verification Checklist

After running `--fix` or `--init`, verify these in order:

```bash
# 1. Machine and CLI health
podman ps
podman info
docker ps

# 2. Socket convergence
podman system connection list

# 3. Docker-label routing (if using Traefik)
bin/docker_socket_rootless_test

# 4. Lower port binding (if needed)
podman run --rm -p 443:443 nginx:latest
# (Ctrl+C to stop)
```

If any of these fail, re-run:
```bash
bin/podman_troubleshoot --fix --force --verbose
```

---

## See Also

- `docs/podman-rootless-plan.md` – Intended setup and verified constraints
- `bin/podman_troubleshoot --help` – Full usage and environment variable docs
- `source/60_podman.sh` – Shell environment and utility functions
