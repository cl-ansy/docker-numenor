# Updating

See also [access.md](access.md), [storage.md](storage.md).

## Tagging policy

`:latest` can move across major versions without warning and records no version
to roll back to. Pinning everything has its own cost, since stale pins
accumulate known bugs. So tag per service, based on how far a bad update reaches.

### Pinned

| Image | Pin | Reason |
|---|---|---|
| `postgres` | `16-alpine` | 17 refuses to start against a 16 data directory |
| `redis` | `8-alpine` | RDB format isn't backward readable |
| `traefik` | `v3` | Every route depends on it |
| `prom/prometheus` | `v3` | TSDB format |
| `ghcr.io/goauthentik/server` | `2025.2.4` | Biggest blast radius, one-way migrations |

### `:latest`, low stakes

Dozzle, Homepage, whoami, the `exportarr` exporters, socket-proxy. Stateless, no
migrations. Restart or roll the digest back.

### `:latest`, accepted risk

Grafana, Jellyfin, Jellyseerr, Radarr, Sonarr, SABnzbd, Portainer.

These do one-way database migrations, so a downgrade needs a config restore from
backup. They're self-contained though, so a failure doesn't cascade. LinuxServer
publishes no major-only tags for the *arrs, so pinning would mean naming exact
versions and bumping them by hand.

This tier only works if you record digests before every update. Skip that and
there's no rollback path.

### Pinning correctly

Commit `3e16cc4` pinned four images at once. Two broke on the next pull, in
opposite ways.

**The tag has to exist.** `grafana/grafana:11` doesn't. The pull failed with
`manifest unknown`, which aborted the whole `up` and left other services
mid-recreate. A bare major tag is a convention, not a guarantee - publishers who
ship `11.6.3` often never publish a floating `11`.

**The tag has to match what's already running.** `redis:alpine` became
`redis:7-alpine`, but `redis:alpine` had been Redis 8, which writes RDB format
version 13. Redis 7 can't read it, so it failed with `Can't handle RDB format
version 13` and took Authentik down through `depends_on: service_healthy`.

Any pin that narrows a floating tag is a version change until proven otherwise.
Check what's running first:

```bash
sudo docker inspect <container> --format '{{.Config.Image}}'
sudo docker inspect <container> \
  --format '{{index .Config.Labels "org.opencontainers.image.version"}}'
sudo docker pull <image>:<tag>        # confirm the tag resolves
```

Downgrades are the more dangerous of the two. A missing tag fails loudly at pull
time with nothing recreated. A downgrade pulls cleanly, then fails on a data
format the older binary can't read, after the old container is gone.

Prefer a specific version over a floating major where the publisher doesn't
clearly maintain major tags. A specific version can't silently stop resolving or
silently move.

## Moving the Authentik pin

Pinned to `2025.2.4` on both `authentik` and `authentik-worker`. They must always
carry the same tag.

Authentik doesn't reliably support skipping releases, so a jump forward may need
stepping through intermediate versions. Read the release notes between the
current pin and the target first.

To move it: snapshot the VM (disk only), dump the database, edit both tags, then:

```bash
dcpull
dcup
dclogs authentik          # wait for migrations to finish
```

Log in at `https://auth.<domain>` before walking away.

Anything reading Authentik's API may be version-sensitive - the homepage widget
needs `version: 2` only at 2025.8.0 and above.

## Blast radius

Authentik runs migrations on start. If it fails, Traefik's forward-auth
middleware fails closed and everything behind `chain-authentik@file` becomes
unreachable.

| Behind Authentik | Independent |
|---|---|
| Traefik dashboard | Jellyfin |
| Homepage | Jellyseerr (`chain-no-auth`) |
| SABnzbd | Portainer (own auth) |
| Radarr, Sonarr | |
| Grafana | |
| Dozzle | |

Traefik's dashboard, Dozzle and Homepage are all inside that blast radius, so
diagnose over SSH with `dclogs`.

## Before updating

```bash
cd "$DOCKERDIR"

# Record running versions
sudo docker compose -f docker-compose-main.yml images > "logs/images-$(date +%F).txt"
sudo docker images --digests | grep -E 'authentik|jellyfin|radarr|sonarr|sabnzbd'

# Dump the Authentik database
sudo docker compose -f docker-compose-main.yml exec -T authentik-postgres \
  pg_dump -U "$(sudo cat secrets/authentik_postgres_user)" -d authentik \
  | sudo tee "/nfs/<share>/backup/authentik-$(date +%F).sql" > /dev/null

# Archive the config of whatever is being updated
sudo tar czf "/nfs/<share>/backup/appdata-<service>-$(date +%F).tgz" "appdata/<service>"
```

With `:latest` and no recorded digest there is no rollback.

## Checking for updates

`scripts/dockcheck.sh` is [mag37/dockcheck](https://github.com/mag37/dockcheck)
v0.5.7.0, vendored in commit `60f6cf3`. It compares running containers against
registry digests.

```bash
sudo ./scripts/dockcheck.sh -n              # check only
sudo ./scripts/dockcheck.sh -n -d 7         # skip images newer than 7 days
sudo ./scripts/dockcheck.sh -e authentik    # exclude
```

`-d 7` skips images published in the last week, when most regressions are still
being found.

### Decline its self-update

The script curls `raw.githubusercontent.com` on every run and offers to update
itself. Saying yes runs `curl -L <raw url> > "$ScriptPath"` against the `main`
branch - no tag, no checksum, no signature. Under `sudo` that executes whatever
is at HEAD of a third-party repo and overwrites the copy tracked in git.

Answer `n` and bump it deliberately with a reviewed diff.

### Verify the update path before using it

dockcheck doesn't read the compose files. It reads
`com.docker.compose.project.working_dir` and
`com.docker.compose.project.config_files` off each running container, cds there,
and runs `docker compose -f <those files> up -d <service>`.

This stack uses `include:`, so check what those labels contain:

```bash
docker inspect radarr \
  --format '{{index .Config.Labels "com.docker.compose.project.config_files"}}'
```

`docker-compose-main.yml` means the reconstructed command is correct.
`compose/radarr.yml` means it would run against a file with no networks or
secrets defined, so use `dcpull` + `dcup` instead. `-n` is unaffected either way.

## Updating

Routine services - the *arrs, SABnzbd, Jellyfin, exporters:

```bash
dcpull        # always first
dcup
dps
```

**Pull before up, always.** Pull contacts the registry without touching running
containers, so an unresolvable image fails while everything is still up. `dcup`
on its own uses whatever image is already on disk and recreates containers as it
goes, so the same failure lands mid-flight and leaves services stopped.

`dcconfig` is not a substitute. It renders and validates the merged YAML and
catches unset variables, but never contacts a registry - it will happily pass a
config referencing an image that doesn't exist.

Authentik goes alone, never bundled:

```bash
# Snapshot the VM first, disk only - no RAM
dcpull
sudo docker compose -f docker-compose-main.yml up -d \
  authentik-postgres authentik-redis authentik authentik-worker
dclogs authentik          # wait for migrations to finish
```

Pinned major bumps (Traefik v3 to v4, Grafana 11 to 12): edit the tag, read the
upstream breaking changes, one at a time.

Postgres major versions aren't a pull. The data directory format changes and the
container refuses to start against the old one, so it needs a `pg_dump`, a wipe
of `appdata/authentik-postgres`, and a restore.

## Traps in this stack

### Anonymous volumes are lost on recreate

An image that declares `VOLUME` for a path the compose file doesn't bind-mount
stores that data in an anonymous volume. Recreating the container - which any
image or config change does - orphans it and starts fresh.

`prom/prometheus` declares `/prometheus` for its TSDB. The compose file bound
only `/etc/prometheus`, the config, so metrics history was discarded on every
recreate. Fixed by binding `$DOCKERDIR/appdata/prometheus-data:/prometheus`.

`jellyfin/jellyfin` declares `/cache`, still unbound. That regenerates, so it
costs a rebuild rather than data.

Check for others after adding a service:

```bash
docker volume ls
docker ps -q | xargs docker inspect \
  -f '{{.Name}}{{range .Mounts}}{{if eq .Type "volume"}} VOL:{{.Name}}->{{.Destination}}{{end}}{{end}}'
```

docker-gc used to get the blame for this. It was removed on 2026-08-22 after its
logs showed it had never run - the image didn't accept the six-field
`0 0 0 * * ?` cron expression it was configured with. It had been armed to delete
volumes the whole time and never fired. Use `dprune` manually instead.

### A healthcheck that only pings hides write failures

`authentik-redis` was checked with `redis-cli ping | grep PONG`. Redis answers
PING while refusing every write, so when a background save failed and Redis set
`MISCONF`, Compose reported it healthy, started dependents, and the failure
surfaced as an unexplained `authentik-worker` problem several layers away.

The healthcheck now performs a write, so the same condition shows up as
`authentik-redis` unhealthy instead.

The save failure itself resolved when the container was recreated for an image
change - the Redis entrypoint chowns `/data` on start as root, which a
long-running container never re-runs. Stale ownership fits, though it was never
confirmed.

A healthcheck should exercise what dependents actually need. A liveness ping is
not a readiness check.

### --remove-orphans deletes disabled services

`dcup` includes it. Comment an `include` line out of `docker-compose-main.yml`,
run `dcup`, and that container is deleted. Its `appdata` survives; anonymous
volumes don't.

## Verifying

```bash
dps                                  # nothing restarting
dclogs traefik | tail -50            # routers reloaded, no cert errors
```

- [ ] `https://<domain>` loads with all groups
- [ ] Log out and back in through Authentik
- [ ] One `chain-authentik` service, e.g. `https://sabnzbd.<domain>`
- [ ] Jellyfin plays a file
- [ ] Radarr and Sonarr see their libraries (empty means NFS, not the update)
- [ ] Certificate is the existing wildcard, not a new one

## Rolling back

Only possible if digests were recorded first.

```bash
sudo docker pull <image>@sha256:<digest>
sudo docker tag <image>@sha256:<digest> <image>:latest
dcup
```

Authentik also needs its database rolled back, since migrations aren't reversible
and an older binary won't start against a newer schema:

```bash
dcmain stop authentik authentik-worker
sudo docker compose -f docker-compose-main.yml exec -T authentik-postgres \
  psql -U "$(sudo cat secrets/authentik_postgres_user)" -d authentik \
  < /nfs/<share>/backup/authentik-<date>.sql
```

A Proxmox snapshot rollback is faster and more reliable than either.

## Snapshot vs backup

| | Snapshot (disk only) | Snapshot (with RAM) | Backup (`vzdump`) |
|---|---|---|---|
| Stored | Same storage as the VM | Same storage as the VM | Separate storage |
| Speed | Seconds | Minutes | Minutes to hours |
| Initial space | Near zero | Size of VM RAM in use | Size of the disks |
| Rollback | VM boots fresh | VM resumes mid-execution | Restore as a VM |
| Survives disk or host loss | No | No | Yes |
| Covers | Your own changes | Your own changes | Hardware failure |

An Authentik update takes a disk-only snapshot. A host wipe needs `vzdump` to the
NAS, since a snapshot dies with the disk being wiped.

### Uncheck "Include RAM"

Measured on VM 100: a RAM-inclusive snapshot wrote 61.03 GiB in 14m23s before it
even reached the disk, and added roughly 0.5 TiB of thin provisioning.

Disk-only completes in seconds and allocates almost nothing up front. Rollback
boots the VM rather than resuming it, which doesn't matter for a Docker host.
Include RAM only when the in-memory state is what you need to preserve.

VM 100 has PCI passthrough devices configured and a RAM-state snapshot still
succeeded, so passthrough doesn't block it. Live migration is what passthrough
actually prevents.

### Thin pool limits

`local-lvm` is LVM-thin, so snapshots work at all - thick LVM doesn't support
them usefully. Two numbers govern the room available:

```bash
vgs pve                                                    # VFree
lvs -a -o lv_name,lv_size,data_percent,metadata_percent pve
```

`data_percent` on `pve/data` is the risk figure. Provisioned size exceeding the
volume group is normal for thin provisioning; *used* space approaching 100% takes
thin volumes read-only. `metadata_percent` does the same and fills faster when
snapshots exist.

Delete snapshots after use. Every write the VM makes while one exists allocates
copy-on-write blocks in the pool.

LVM warns that `thin_pool_autoextend_threshold` is 100, meaning never autoextend.
Lowering it in `/etc/lvm/lvm.conf` only helps if `VFree` shows unallocated space
to extend into, and the Proxmox installer usually assigns nearly all of it to
`pve/data`. Watching `data_percent` is the real protection.

Back up a running VM with `--mode snapshot`. Use `--mode stop` only when downtime
doesn't matter, such as a final backup before a wipe.

## Host and hypervisor

Debian packages on the Docker host:

```bash
sudo apt update && sudo apt upgrade
sudo reboot        # if the kernel moved
```

After any reboot, confirm NFS mounted before Docker started. If it didn't, Radarr
and Sonarr show empty libraries:

```bash
mount | grep nfs
ls /nfs/<share>/shared/media   # real path; $SHAREDDIR is compose-only
```

Proxmox: snapshot both VMs, update from the host shell, and reboot into the new
kernel while CIMC is reachable.

## Cadence

| What | Interval |
|---|---|
| `dockcheck.sh -n` | Weekly |
| The *arrs, SABnzbd, Jellyfin | Monthly |
| Authentik | Deliberately, with a snapshot |
| Debian packages | Monthly, security sooner |
| Proxmox | Quarterly |
| Certificate expiry check | Monthly |
