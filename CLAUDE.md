# CLAUDE.md

Guidance for Claude Code when working in this repository.

## Overview

A Docker Compose homelab stack called "numenor". It runs a self-hosted media
server and supporting services behind a Traefik reverse proxy with Authentik SSO,
on a Debian VM under Proxmox.

This repository is public. Docs should explain how to do things without
including real hostnames, IPs, domains, usernames, ports or keys. Use the `scrub`
skill before committing documentation.

## Layout

| Path | Contents |
|---|---|
| `docker-compose-main.yml` | Networks, secrets, and `include`s of every service |
| `compose/` | One file per service |
| `appdata/` | Service state. Mostly gitignored; config files whitelisted |
| `runbooks/` | Operational procedures. Tracked and public |
| `notes/` | Retrospectives and case studies. Tracked and public |
| `build/` | Build tooling for things not available as packages |
| `scripts/` | Helper scripts |

## Common commands

`shared/.bash_aliases` defines these. Source it from `~/.bashrc` after setting
`$DOCKERDIR`.

```bash
dcup                    # up -d --build --remove-orphans
dcdown                  # down --remove-orphans
dcpull                  # pull updated images
dcrestart <service>
dclogs <service>        # logs -tf --tail=50
dps                     # docker ps -a
dcconfig                # render the merged compose config
```

Always run `dcpull` before `dcup`. Pull talks to the registry without touching
running containers, so a missing image fails while everything is still up. `dcup`
on its own recreates containers as it goes, so the same failure stops services
partway through.

## Initial setup

1. Copy `.env.example` to `.env` and fill it in.
2. Create Docker secrets under `$DOCKERDIR/secrets/`:
   - `postgres_default_password`
   - `authentik_postgres_user`, `authentik_postgres_password`, `authentik_secret_key` - use `scripts/authentik_secret_gen.sh`
   - `cf_dns_api_token` - Cloudflare API token with Zone:DNS:Edit
3. Create `$DOCKERDIR/appdata/traefik/acme/acme.json` with mode `600`.
4. Mount NFS storage: `scripts/mount_nfs.sh`, after setting the NAS address.
5. Bootstrap Authentik at `https://auth.$DOMAINNAME/if/flow/initial-setup/`.

## Architecture

### Entry point

`docker-compose-main.yml` defines the shared networks and secrets, then
`include`s each file from `compose/`. Comment out an `include` line to disable a
service.

`dcup` passes `--remove-orphans`, so commenting out an include deletes that
container on the next run. Its `appdata` survives; anonymous volumes don't.

### Networks

| Network | Subnet | Purpose |
|---|---|---|
| `t3_proxy` | 192.168.90.0/24 | Traefik routes here |
| `socket_proxy` | 192.168.91.0/24 | Internal; Docker socket access |
| `db` | 192.168.92.0/24 | Internal; database tier |
| `downloaders` | 192.168.93.0/24 | Internal; download clients |
| `ops` | 192.168.94.0/24 | Internal; monitoring |

Services join only the networks they need. Most app containers use `t3_proxy`
alone.

### Secrets

Credentials are passed as Docker secrets (files under `$DOCKERDIR/secrets/`)
rather than environment variables. Services read them through `_FILE` env vars,
for example `AUTHENTIK_SECRET_KEY=file:///run/secrets/authentik_secret_key`.

### Traefik and TLS

- Traefik talks to Docker through `socket-proxy` instead of mounting the socket.
- TLS uses an ACME DNS challenge through Cloudflare. The wildcard covers `*.$DOMAINNAME`.
- HTTP redirects permanently to HTTPS.
- Dynamic config comes from `appdata/traefik/rules/`, with hot reload.
- A service is exposed by adding `traefik.enable=true` to its labels.

`$DOMAINNAME` is internal-only with no inbound port forwards. The public
certificate exists so browsers trust it, not because anything is published.

### Authentik

- `auth.$DOMAINNAME` provides SSO.
- Middleware chains live in `appdata/traefik/rules/`: `chain-authentik.yml` (rate limit, secure headers, forward auth) and `chain-no-auth.yml` (rate limit, secure headers).
- Add auth to a service with `traefik.http.routers.<name>.middlewares=chain-authentik@file`.
- Server, worker, postgres and redis are all in `compose/authentik.yml`.
- Brand assets bind-mount from `appdata/authentik/brand/`.

If Authentik fails, forward auth fails closed and everything behind
`chain-authentik@file` becomes unreachable, including the Traefik dashboard,
Dozzle and Homepage. Update it on its own, after a snapshot. See
`runbooks/updating.md`.

### Homepage dashboard

Services are defined in `appdata/homepage/services.yaml`, not as `homepage.*`
labels on compose files. Homepage supports both, and using both shows every
service twice.

API keys go into the homepage container as `HOMEPAGE_VAR_*` in
`compose/homepage.yml`, and the YAML refers to them as `"{{HOMEPAGE_VAR_X}}"`.
Quote them, or the braces parse as a flow mapping. Keeping keys there instead of
on each service container also keeps them away from anything that can run
`docker inspect`.

### GPU

An Intel Arc A310 is passed through for Jellyfin transcoding. It doesn't work
yet, because the VA-API driver needs a version that isn't packaged. See
`runbooks/gpu.md`.

## Adding a new service

1. Create `compose/<service>.yml` following an existing file.
2. Assign networks. At minimum `t3_proxy` for a public route.
3. Add Traefik labels using `chain-authentik@file` or `chain-no-auth@file`.
4. Add the `include` line to `docker-compose-main.yml`.
5. Add an entry to `appdata/homepage/services.yaml`, with `server:` and `container:` so it gets a status dot.

## Image tagging

Pinned: `postgres:16-alpine`, `redis:8-alpine`, `traefik:v3`,
`prom/prometheus:v3`, `ghcr.io/goauthentik/server:2025.2.4`.

Everything else runs `:latest` by choice. Before changing a pin, check what is
actually running. Narrowing a floating tag is a version change, and a downgrade
can leave a container unable to read its own data. See `runbooks/updating.md`.

## Gitignore

- `.env` excluded; only `.env.example` tracked.
- `appdata/` excluded by default, with specific config directories whitelisted.
- `secrets/` structure tracked, contents excluded.
- `logs/` contents excluded.

Keep ignore rules bare. Describing what an ignored path holds tells a reader of a
public repo where to look for the unredacted version, so do not annotate them
here or in `.gitignore`.

## Documentation

Runbooks use `<placeholder>` values, never real ones. When a measured number
justifies a decision, record it with the date it was taken.
