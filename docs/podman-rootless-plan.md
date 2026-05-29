# Rootless Podman Plan

This document defines the intended rootless Podman setup for this repo, the end goal we are optimizing for, and the constraints we have already verified in practice.

Use this before changing Podman, Traefik, `docker.sock` handling, or the verification helpers. The goal is to avoid blind trial-and-error changes.

## End Goal

We want a rootless Podman setup on macOS that supports both:

- normal local CLI usage through `podman`, `docker`, and `docker compose`
- Docker-compatible clients inside containers, especially Traefik, reading labels from a mounted Docker API socket

Concretely, the target state is:

- the Podman machine runs in `rootful=false` mode
- the default Podman connection points at the rootless machine connection
- shell sessions use a stable host-side socket path:
  - `${HOME}/.local/share/containers/podman/machine/podman.sock`
- host-side Docker-compatible clients can use:
  - `DOCKER_HOST=unix://${HOME}/.local/share/containers/podman/machine/podman.sock`
- containers running inside the Podman VM mount the VM-internal socket path, not the macOS host socket path:
  - `/run/user/<uid>/podman/podman.sock`

## Verified Constraints

These are not guesses. They were validated during live troubleshooting.

### 1. Host socket path and container socket path are different

The host sees a transient macOS socket path under `$TMPDIR/podman/...-api.sock`.
That path is fine for host-side clients, but it is the wrong thing to mount into containers.

For containers such as Traefik, the correct mount source is the Linux-side socket inside the Podman VM:

```sh
/run/user/503/podman/podman.sock
```

On a different machine/user, replace `503` with the Podman VM user id.

### 2. The stable symlink is for host tooling, not for in-VM containers

This symlink is still correct and useful:

```sh
${HOME}/.local/share/containers/podman/machine/podman.sock
```

It is the stable host-side entrypoint for:

- `DOCKER_HOST`
- host CLI tooling
- tools that expect a Docker-compatible socket from macOS

It should not be confused with the socket path that containers inside the VM must mount.

### 3. SELinux blocks direct access to the mounted rootless Podman socket

Inside the Podman VM, SELinux is enforcing.

A rootless container mounting `/run/user/503/podman/podman.sock` can still get:

```text
permission denied while trying to connect to the Docker daemon socket
```

even when:

- the container UID matches the socket owner UID
- the container GID matches the socket owner GID
- `--userns keep-id` is used

The proven fix is to disable SELinux labeling for the container that mounts the socket:

```yaml
security_opt:
  - label=disable
```

That is the important fix for Traefik-style socket readers in this setup.

### 4. Rootless containers should avoid privileged container ports by default

Even if the host exposes `8080`, a rootless container can still fail if the service inside the container tries to bind `:80`.

For the smoke test and similar setups:

- bind Traefik to `:8080` inside the container
- publish host `8080:8080`

If a real deployment needs host port `443` while staying rootless, use the VM sysctl helper after the machine starts:

```sh
podman-allow-port-443
```

### 5. Traefik probe requests must send a clean Host header

Traefik `Host(...)` rules match the hostname, not `hostname:port`.

For local verification, probe `127.0.0.1:<port>` and explicitly send:

```http
Host: whoami.docker.localhost
```

Do not rely on `curl http://whoami.docker.localhost:8080/` if the distinction matters.

## Intended Setup

### Machine

The machine should be created and converged through:

- [bin/podman_machine_init](../bin/podman_machine_init)
- [bin/podman_troubleshoot](../bin/podman_troubleshoot)

Target settings:

- machine name: `podman-machine-default`
- rootless: `false` for `Rootful`, meaning the machine runs rootless mode
- default connection: `podman-machine-default`

### Shell and host env

The intended shell exports live in:

- [source/60_podman.sh](../source/60_podman.sh)

Important values:

- `DOCKER_HOST=unix://${HOME}/.local/share/containers/podman/machine/podman.sock`
- `PODMAN_COMPOSE_PROVIDER=/opt/homebrew/bin/docker-compose`
- `TRAEFIK_DOCKER_SOCKET=/run/user/${PODMAN_UID}/podman/podman.sock`

### Traefik-style container setup

For containers that need Docker API label discovery in this rootless Podman setup:

- mount `/run/user/<uid>/podman/podman.sock:/var/run/docker.sock`
- set:
  - `security_opt: [label=disable]`
- use unprivileged internal ports unless there is a reason not to

The smoke test in:

- [bin/docker_socket_rootless_test](../bin/docker_socket_rootless_test)

is the executable reference implementation for this pattern.

## Verification Workflow

When changing this setup, verify in this order.

### 1. Machine and CLI health

```sh
podman ps
podman info
docker ps
podman system connection list
```

Expected:

- `podman ps` succeeds
- `docker ps` succeeds from the host
- the default connection points at the rootless machine

### 2. Socket convergence

```sh
podman_troubleshoot
podman_troubleshoot --fix
```

Expected:

- no socket-connection failure
- no machine-start hang
- no emergency-mode boot diagnostics

### 3. Docker-label routing smoke test

```sh
bin/docker_socket_rootless_test
```

Expected:

- whoami route works on host port `8080`
- Traefik dashboard rawdata contains `whoami@docker`
- the script prints:

```text
✅ Docker socket rootless routing is working on port 8080
```

## If It Breaks Again

Do not guess immediately. Check which layer failed.

### If host CLI tools fail

Likely problem area:

- machine state
- default connection
- host-side stable socket symlink

Use:

```sh
podman_troubleshoot
podman_troubleshoot --fix
```

### If host CLI works but Traefik-in-container fails

Likely problem area:

- wrong socket mount source
- SELinux labeling
- privileged container port binding
- Traefik Host-rule probe mismatch

Use:

```sh
bin/docker_socket_rootless_test
```

If it fails, inspect the emitted:

- `compose.yml`
- `compose ps`
- Traefik logs
- whoami logs

### If the VM itself does not boot

Likely problem area:

- broken machine image
- ignition / boot failure
- filesystem check failure

Use:

```sh
podman_troubleshoot
```

If it reports initramfs emergency mode, rebuild the machine rather than continuing to tweak socket settings.

## Things We Should Not Reintroduce

Avoid these regressions:

- mounting macOS `$TMPDIR/podman/...-api.sock` into containers
- assuming host-side socket fixes automatically solve in-container access
- assuming matching UID/GID alone solves rootless socket access
- using `--api.insecure=true` in the smoke test when the dashboard is already routed through `api@internal`
- relying on `Host: name:port` probes for Traefik `Host(...)` rules

## Source of Truth

Operational source files:

- [source/60_podman.sh](../source/60_podman.sh)
- [bin/podman_machine_init](../bin/podman_machine_init)
- [bin/podman_troubleshoot](../bin/podman_troubleshoot)
- [bin/docker_socket_rootless_test](../bin/docker_socket_rootless_test)

This document is the architectural source of truth for why those files are shaped the way they are.
