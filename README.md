# numenor

A Docker Compose homelab stack: media server and supporting services behind a
Traefik reverse proxy with Authentik SSO, running on a Debian VM under Proxmox.

`docker-compose-main.yml` defines the shared networks and secrets and includes
one file per service from `compose/`. That file is the list of what runs.

## Setup

1. Copy `.env.example` to `.env` and fill it in.
2. Create Docker secrets under `$DOCKERDIR/secrets/`:
   - `postgres_default_password`
   - `authentik_postgres_user`, `authentik_postgres_password`, `authentik_secret_key` - generate with `scripts/authentik_secret_gen.sh`
   - `cf_dns_api_token` - Cloudflare API token with Zone:DNS:Edit
3. Create `$DOCKERDIR/appdata/traefik/acme/acme.json` with mode `600`.
4. Set folder permissions to match `PUID`/`PGID`.
5. Mount network storage with `scripts/mount_nfs.sh`, after setting the NAS address.
6. Start the stack, then bootstrap Authentik at `https://auth.$DOMAINNAME/if/flow/initial-setup/`.

```bash
sudo docker compose -f docker-compose-main.yml pull
sudo docker compose -f docker-compose-main.yml up -d --remove-orphans
```

`shared/.bash_aliases` provides shorter forms (`dcup`, `dcpull`, `dclogs`,
`dps`). Source it from `~/.bashrc` after exporting `$DOCKERDIR`.

## Documentation

`runbooks/` covers access and recovery, updating, storage, and troubleshooting.
Start with `runbooks/access.md`.

`notes/` holds retrospectives. `build/` holds build tooling for things not
available as packages.

## Placeholders

The runbooks describe a real setup, so they use `<placeholder>` values instead of
real addresses. Actual hostnames, ports and credentials live in `.env`,
`~/.ssh/config` and a password manager.
