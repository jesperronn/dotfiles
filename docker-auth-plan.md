# Docker Auth Challenge

## Context
- Objective: ensure Podman (aliased as `docker`) and docker-compose share registry credentials for `unilogin-docker.opbevaring.stil.dk` so `docker compose pull` succeeds.

## Attempts That Failed
- `docker login` (alias to Podman) kept writing tokens to `~/.config/containers/auth.json`; docker-compose only read `~/.docker/config.json`, so pulls failed with "unable to retrieve auth token".
- Prefixing `REGISTRY_AUTH_FILE=~/.config/containers/auth.json docker compose pull` did nothing because the legacy docker-compose binary ignores that environment variable.
- Setting `authfile="$HOME/.docker/config.json"` inside `registries.conf` had no effect; Podman pulls the authfile path from `containers.conf` instead.
- `podman info --format '{{.Host.AuthFile}}'` errors because that field does not exist; `podman info --format '{{.Registries.AuthFile}}'` returned `<no value>` before the configuration was fixed.

## Working Solution
1. Choose option A: configure Podman to reuse Docker's credential store so all tooling keeps reading `~/.docker/config.json`.
2. Edit `~/.config/containers/containers.conf` (not `registries.conf`) to include:
   ```
   [engine]
   authfile="/Users/jesper/.docker/config.json"
   ```
   (Use the literal path; Podman does not expand `$HOME` in this file.)
3. Remove `~/.config/containers/auth.json`, create `~/.docker/config.json` if it does not exist, then run `docker login unilogin-docker.opbevaring.stil.dk` once to populate it.
4. Verify by observing that `~/.config/containers/auth.json` is no longer recreated and `~/.docker/config.json` updates after logins. `docker compose pull` now authenticates without extra environment variables.
