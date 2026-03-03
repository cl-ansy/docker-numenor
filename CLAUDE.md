# CLAUDE.md

This file provides guidance to Claude Code (claude.ai/code) when working with code in this repository.

## Overview

This is a Docker Compose homelab stack named "numenor". It runs a self-hosted media server and supporting services behind a Traefik reverse proxy with Authentik SSO, all deployed on a single host.

## Common Commands

The stack is managed via a single top-level compose file. Commands should be run from the repo root. The `shared/.bash_aliases` file documents the intended aliases (adjust the path to match your `$DOCKERDIR`):

```bash
# Start all services (build + remove orphans)
sudo docker compose -f docker-compose-main.yml up -d --build --remove-orphans

# Stop all services
sudo docker compose -f docker-compose-main.yml down --remove-orphans

# Tail logs for a service
sudo docker compose -f docker-compose-main.yml logs -tf --tail="50" <service>

# Pull updated images
sudo docker compose -f docker-compose-main.yml pull

# Restart a single service
sudo docker compose -f docker-compose-main.yml restart <service>
```

## Initial Setup

1. Copy `.env.example` to `.env` and fill in all variables (`PUID`, `PGID`, `TZ`, `USERDIR`, `DOCKERDIR`, `DOWNLOADDIR`, `SHAREDDIR`, `HOSTNAME`, `DOMAINNAME`, API keys).
2. Create Docker secrets files under `$DOCKERDIR/secrets/`:
   - `postgres_default_password`
   - `authentik_postgres_user`, `authentik_postgres_password`, `authentik_secret_key` — use `scripts/authentik_secret_gen.sh` to generate these
   - `cf_dns_api_token` — Cloudflare API token for DNS challenge (needs Zone:DNS:Edit permissions)
3. Create `$DOCKERDIR/appdata/traefik/acme/acme.json` with permissions `600`.
4. Mount NFS storage if needed: `scripts/mount_nfs.sh` (edit `$IP` to match your NAS).
5. Bootstrap Authentik by visiting `https://auth.$DOMAINNAME/if/flow/initial-setup/`.

## Architecture

### Entry Point

`docker-compose-main.yml` defines shared networks, Docker secrets, and `include`s all service compose files from `compose/`. To enable/disable a service, comment/uncomment its `include` line here.

### Networks

| Network | Subnet | Purpose |
|---|---|---|
| `t3_proxy` | 192.168.90.0/24 | Public-facing; Traefik routes here |
| `socket_proxy` | 192.168.91.0/24 | Internal-only; Docker socket access |
| `db` | 192.168.92.0/24 | Internal-only; database tier |
| `downloaders` | 192.168.93.0/24 | Internal-only; download clients |
| `ops` | 192.168.94.0/24 | Internal-only; ops/monitoring |

Services only get access to the networks they need. Most app containers join only `t3_proxy`.

### Secrets

All sensitive credentials are passed via Docker secrets (files under `$DOCKERDIR/secrets/`), not environment variables. Services reference them with `_FILE` suffix env vars (e.g., `AUTHENTIK_SECRET_KEY=file:///run/secrets/authentik_secret_key`).

### Reverse Proxy & TLS (Traefik)

- Traefik communicates with Docker via `socket-proxy` (not direct socket mount) for security.
- TLS is handled via ACME DNS challenge through Cloudflare — wildcard cert covers `*.$DOMAINNAME`.
- All HTTP traffic is permanently redirected to HTTPS.
- Traefik reads dynamic config from `appdata/traefik/rules/` (file provider, hot-reload enabled).
- Services opt into Traefik via `traefik.enable=true` labels in their compose files.

### Authentication (Authentik)

- Authentik (`auth.$DOMAINNAME`) provides SSO for protected services.
- Traefik middleware chains are defined in `appdata/traefik/rules/`:
  - `chain-authentik.yml` — rate limit + secure headers + forward auth to Authentik
  - `chain-no-auth.yml` — rate limit + secure headers only (no auth)
- Apply auth to a service by adding `traefik.http.routers.<name>.middlewares=chain-authentik@file` to its labels.
- Authentik runs server + worker + postgres + redis — all in `compose/authentik.yml`.
- Brand assets (logo, background, CSS) are bind-mounted from `appdata/authentik/brand/`.

### Adding a New Service

1. Create `compose/<service>.yml` following the pattern of existing files.
2. Assign appropriate networks; at minimum `t3_proxy` if it needs a public route.
3. Add Traefik labels to expose it, referencing `chain-authentik@file` or `chain-no-auth@file`.
4. Include it in `docker-compose-main.yml` under the appropriate category comment.
5. Add homepage discovery labels (`homepage.group`, `homepage.name`, `homepage.icon`, `homepage.href`) if desired.

### Gitignore Strategy

- `.env` is excluded. Only `.env.example` is tracked.
- `appdata/` contents are excluded by default; specific subdirectories are whitelisted (brand assets, traefik rules, homepage config, prometheus config, docker-gc config).
- `secrets/` directory structure is tracked but contents are excluded.
- `logs/` contents are excluded.
