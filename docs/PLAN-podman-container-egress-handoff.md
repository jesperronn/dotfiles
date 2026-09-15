# Podman Container Egress and AppleHV Lifecycle Handoff

## Purpose

Add two **diagnostic-only** checks to `bin/podman_troubleshoot` before it offers
any repair. They distinguish a broken rootless container network from a broken
Podman AppleHV runtime, and give an operator a short, reproducible report.

This is a handoff only. Do not implement it until the VM is healthy again.

## Safety boundary

The checks must not stop or restart a machine, kill processes, modify sysctls,
pull images, install packages, or change the default connection. They may run
a disposable **already-cached** container only after the existing engine health
checks pass; always remove it with `--rm` and apply short connect and total
timeouts.

Keep the established invariants from `docs/podman-rootless-plan.md`:

- `Rootful=false` and the rootless default connection.
- `net.ipv4.ip_unprivileged_port_start <= 443`.
- the stable host socket and Docker-compatible clients.
- Linux AMD64 image builds on Apple Silicon.

## Check 1: rootless container HTTPS egress

### Problem it catches

The macOS host and the Podman VM can resolve and fetch Rubygems, while a
rootless container resolves the same name but its TCP connection to port 443
times out before TLS. Bundler then appears to hang at `Fetching source index`.

### Simple reproduction

Run these three commands in order. Do not infer one layer from another.

```sh
curl --connect-timeout 8 --max-time 20 -fsS -o /dev/null -w 'host %{http_code}\n' https://rubygems.org/
podman machine ssh 'curl --connect-timeout 8 --max-time 20 -fsS -o /dev/null -w "vm %{http_code}\\n" https://rubygems.org/'
podman run --rm docker.io/library/ruby:4.0.6-slim sh -lc 'apt-get update -qq && apt-get install -y --no-install-recommends curl >/dev/null && curl --connect-timeout 8 --max-time 20 -fsS -o /dev/null -w "container %{http_code}\\n" https://rubygems.org/'
```

The third command is a one-off manual reproduction and may download packages;
it is intentionally **not** the command that the future diagnostic will run.

Expected healthy result: all three print `200`.

Failure signature: host and VM print `200`; the container prints a timeout
(`curl: (28)`), despite successful DNS resolution. Report this as **rootless
container egress failure**, not as a Rubygems outage, DNS failure, or Bundler
failure.

### Intended implementation shape

Add `check_container_https_egress` after `check_vm_dns_and_registry` and before
image-pull checks. Prefer an already-cached tiny image that has `curl`; do not
install packages in the check. Probe both:

```text
https://rubygems.org/
https://registry-1.docker.io/v2/
```

For each URL report DNS, TCP/TLS, and HTTP outcome separately. A successful VM
probe plus a failed container probe must produce one clear next step:

```text
Container egress is broken while VM egress works. Do not change Bundler,
registry mirrors, or DNS yet. Continue with the AppleHV lifecycle diagnostic.
```

## Check 2: AppleHV runtime stays alive after start

### Problem it catches

`podman machine start` can print success and the guest can reach its login
prompt, but the host-side `vfkit` process exits seconds later. The machine API
then refuses connections and all containers remain unavailable.

### Simple reproduction

Only run this on an idle machine or during an approved outage, because it
stops running containers:

```sh
podman machine stop podman-machine-default
podman machine start podman-machine-default
sleep 10
podman machine list
podman ps
```

Expected healthy result: the machine is `Currently running` and `podman ps`
returns normally after the ten-second stability window.

Failure signature: `podman machine start` says success, then `machine list`
shows stopped or `podman ps` reports `connection refused` to the SSH/API port.
This is **AppleHV/Podman runtime lifecycle failure**; it is not a container
network diagnosis.

### Intended implementation shape

Add a read-only `check_machine_stability` to normal diagnostics. It should:

1. Read the default machine name and verify it is already running.
2. Run `podman ps` twice, 10 seconds apart, with the existing bounded timeout.
3. Check `podman machine list --format json` after the second probe.
4. Read the last 100 lines of `$TMPDIR/podman/<machine>.log` and the matching
   `gvproxy.log` only if either probe fails.
5. Report `vfkit` and `gvproxy` process presence using `ps`, but never kill or
   restart either process in diagnostic mode.

The check must avoid a stop/start cycle in normal use. The explicit
stop/start reproduction belongs in the output as an operator-only command.

## Repair handoff: Podman 6.1.1 AppleHV runtime

Observed environment: Podman `6.1.1`, AppleHV machine, rootless mode,
Fedora CoreOS guest. The guest boot log reached `multi-user.target` and the
login prompt, but `vfkit` did not remain running and the forwarded API became
unreachable. The logs did not show an actionable guest OS error.

### Required order

1. Preserve state before any repair: `podman ps -a`, `podman images`, `podman
   volume ls`, `podman network ls`, machine inspect output, and the Podman VM
   and gvproxy logs.
2. Check Podman release notes/issues for the installed Podman, vfkit, gvproxy,
   AppleHV, macOS, and Fedora CoreOS versions.
3. Upgrade or reinstall the host Podman runtime **without removing the machine**.
4. Start the existing machine, wait at least ten seconds, and rerun both new
   diagnostic checks plus `bin/docker_socket_rootless_test`.
5. Only if the existing VM still cannot remain running: obtain explicit
   approval, back up VM-local images/volumes and required data, then recreate
   the machine with `--rootful=false`, restore port 443, and rebuild/restore
   workloads.

Never make `podman machine rm -f` an automatic `--fix` action. It discards
VM-local images, volumes, and container state.

## Acceptance tests for the future implementation

- Host, VM, and disposable-container probes produce distinct, labelled output.
- A mocked container timeout after successful host/VM probes exits non-zero and
  labels the fault as container egress.
- A mocked second `podman ps` failure after an initially healthy API labels the
  fault as unstable AppleHV lifecycle and prints the log locations.
- Diagnostic mode runs no `machine stop`, `machine start`, `machine rm`,
  `system migrate`, `kill`, `sudo`, or sysctl write.
- Existing rootless, port-443, socket, and multiarchitecture tests still pass.
