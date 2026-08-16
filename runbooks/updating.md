# Updating

Companions: [access.md](access.md), [storage.md](storage.md).

## Tagging policy

`:latest` moves across major versions without warning and records no version to
roll back to. Pinning everything has its own cost: stale pins accumulate known
bugs. Tag per service, by how far a bad update reaches.

### Pinned

| Image | Pin | Reason |
|---|---|---|
| `postgres` | `16-alpine` | 17 refuses to start against a 16 data directory |
| `redis` | `7-alpine` | Persistence format |
| `traefik` | `v3` | Every route depends on it |
| `prom/prometheus` | `v3` | TSDB format |
| `ghcr.io/goauthentik/server` | unpinned, should be pinned | See below |

### `:latest`, low stakes

Dozzle, Homepage, whoami, the `exportarr` exporters, docker-gc, socket-proxy.
Stateless, no migrations. Restart or roll the digest back.

### A pin is only real if the tag exists

`grafana/grafana:11` was pinned here and **the tag does not exist**. A pull failed
with `manifest unknown`, which aborted the whole `up` and left other services
mid-recreate.

A bare major tag is a convention, not a guarantee. Publishers who ship `11.6.3`
often never publish a floating `11`, and floating tags that do exist can be
withdrawn later. Verify before relying on one:

```bash
curl -s 'https://hub.docker.com/v2/repositories/<org>/<image>/tags?page_size=100&ordering=last_updated' \
  | jq -r '.results[].name' | head -30
```

Prefer a specific version (`11.6.3`) over a floating major for anything whose
publisher does not clearly maintain major tags. A specific version cannot silently
stop resolving.

Grafana now runs `:latest` as a stopgap. That accepted a major version jump and a
one-way `grafana.db` migration, so an older binary will no longer start against
that data directory.

### `:latest`, accepted risk

Grafana, Jellyfin, Jellyseerr, Radarr, Sonarr, SABnzbd, Portainer.

One-way database migrations, so a downgrade needs a config restore from backup.
Self-contained, so a failure does not cascade. LinuxServer publishes no major-only
tags for the *arrs, so pinning means naming exact versions and bumping by hand.

This tier depends on recording digests before every update. Without that step
there is no rollback path.

## Pinning Authentik

Highest blast radius in the stack, one-way migrations, and it does not reliably
support skipping releases.

Pin to a minor stream so patches flow and majors stay deliberate. Use the version
already running; pinning to anything else makes the next `dcup` perform the
uncontrolled jump the pin exists to prevent.

```bash
sudo docker inspect authentik --format '{{.Config.Image}}'
sudo docker inspect authentik \
  --format '{{index .Config.Labels "org.opencontainers.image.version"}}'
```

In `compose/authentik.yml`, on both `authentik` and `authentik-worker`:

```yaml
    image: ghcr.io/goauthentik/server:2025.8    # replace with the running version
```

Confirm it changes nothing:

```bash
dcpull
dps        # no container recreated
```

Server and worker always carry the same tag.

## Blast radius

Authentik runs migrations on start. If it fails, Traefik's forward-auth middleware
fails closed and everything behind `chain-authentik@file` becomes unreachable.

| Behind Authentik | Independent |
|---|---|
| Traefik dashboard | Jellyfin |
| Homepage | Jellyseerr (`chain-no-auth`) |
| SABnzbd | Portainer (own auth) |
| Radarr, Sonarr | |
| Grafana | |
| Dozzle | |

Traefik's dashboard, Dozzle and Homepage are all inside the blast radius. Diagnose
over SSH with `dclogs`.

## Before updating

```bash
cd "$DOCKERDIR"

# Record running versions
sudo docker compose -f docker-compose-main.yml images > "logs/images-$(date +%F).txt"
sudo docker images --digests | grep -E 'authentik|jellyfin|radarr|sonarr|sabnzbd'

# Dump the Authentik database
sudo docker compose -f docker-compose-main.yml exec -T authentik-postgres \
  pg_dump -U "$(sudo cat secrets/authentik_postgres_user)" -d authentik \
  | sudo tee "/nfs/readynas/backup/authentik-$(date +%F).sql" > /dev/null

# Archive the config of the service being updated
sudo tar czf "/nfs/readynas/backup/appdata-<service>-$(date +%F).tgz" "appdata/<service>"
```

With `:latest` and no recorded digest there is no rollback.

## Checking for updates

`scripts/dockcheck.sh` is [mag37/dockcheck](https://github.com/mag37/dockcheck)
v0.5.7.0, vendored into this repo in commit `60f6cf3` (2025-03-21). It compares
running containers against registry digests.

```bash
sudo ./scripts/dockcheck.sh -n              # check only
sudo ./scripts/dockcheck.sh -n -d 7         # skip images newer than 7 days
sudo ./scripts/dockcheck.sh -e authentik    # exclude
```

`-d 7` skips images published in the last week, when most regressions are still
being found.

### Decline its self-update

The script curls `raw.githubusercontent.com` on every run to compare versions, and
offers to update itself. Answering yes runs
`curl -L <raw url> > "$ScriptPath"` against the **`main` branch**: no tag, no
checksum, no signature. Under `sudo` that executes whatever is at HEAD of a
third-party repo and overwrites the copy tracked in git.

Answer `n`. Bump it deliberately with a reviewed diff instead.

### Verify the update path before using it

dockcheck does not read the compose files. It reads
`com.docker.compose.project.working_dir` and
`com.docker.compose.project.config_files` off each running container, cds there,
and runs `docker compose -f <those files> up -d <service>`.

This stack uses `include:`, so confirm what those labels contain:

```bash
docker inspect radarr \
  --format '{{index .Config.Labels "com.docker.compose.project.config_files"}}'
```

`docker-compose-main.yml` means the reconstructed command is correct.
`compose/radarr.yml` means it would run against a file that has no networks or
secrets defined, so update with `dcpull` + `dcup` instead.

`-n` is unaffected either way.

## Updating

Routine services (the *arrs, SABnzbd, Jellyfin, exporters):

```bash
dcpull        # always first
dcup
dps
```

**`dcpull` before `dcup`, always.** Pull contacts the registry without touching
running containers, so an unresolvable image or a registry problem fails while
everything is still up. `dcup` on its own uses whatever image is already on disk
and recreates containers as it goes, so the same failure lands mid-flight and
leaves services stopped.

`dcconfig` does not substitute for this. It renders and validates the merged YAML
and catches unset variables, but it never contacts a registry and will happily
pass a config referencing an image that does not exist.

Authentik, alone, never bundled:

```bash
# Snapshot the VM first, disk only - do not include RAM
dcpull
sudo docker compose -f docker-compose-main.yml up -d \
  authentik-postgres authentik-redis authentik authentik-worker
dclogs authentik          # wait for migrations to finish
```

Log in at `https://auth.<domain>` before moving on.

Pinned major bumps (Traefik v3 to v4, Grafana 11 to 12, Prometheus v3 to v4): edit
the tag, read the upstream breaking changes, one at a time.

Postgres major versions are not a pull. The data directory format changes and the
container refuses to start against the old one. It needs a `pg_dump`, a wipe of
`appdata/authentik-postgres`, and a restore.

## Stack-specific traps

### docker-gc removes the Prometheus history

`compose/docker-gc.yml` sets `CLEAN_UP_VOLUMES: 1` and
`appdata/docker-gc/docker-gc-exclude` is empty. Prometheus stores its TSDB at
`/prometheus`, an anonymous volume, because the compose file only binds
`/etc/prometheus`. Recreating the container during an update orphans the old
volume and makes it eligible for removal.

Fix in `compose/prometheus.yml`:

```yaml
      - $DOCKERDIR/appdata/prometheus-data:/prometheus
```

Until then, metrics history is disposable.

### --remove-orphans deletes disabled services

`dcup` includes it. Commenting an `include` line out of `docker-compose-main.yml`
and running `dcup` deletes that container. Its `appdata` survives; anonymous
volumes do not.

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

Requires digests recorded beforehand.

```bash
sudo docker pull <image>@sha256:<digest>
sudo docker tag <image>@sha256:<digest> <image>:latest
dcup
```

Authentik also needs its database rolled back. Migrations are not reversible and
an older binary will not start against a newer schema.

```bash
dcmain stop authentik authentik-worker
sudo docker compose -f docker-compose-main.yml exec -T authentik-postgres \
  psql -U "$(sudo cat secrets/authentik_postgres_user)" -d authentik \
  < /nfs/readynas/backup/authentik-<date>.sql
```

A Proxmox snapshot rollback is faster and more reliable than either.

## Snapshot vs backup

| | Snapshot (disk only) | Snapshot (with RAM) | Backup (`vzdump`) |
|---|---|---|---|
| Stored | Same storage as the VM | Same storage as the VM | Separate storage (NAS, PBS) |
| Speed | Seconds | Minutes, see below | Minutes to hours |
| Initial space | Near zero | Size of VM RAM in use | Size of the disks |
| Rollback | VM boots fresh | VM resumes mid-execution | Restore as a VM |
| Survives disk or host loss | No | No | Yes |
| Covers | Your own changes | Your own changes | Hardware failure |

An Authentik update takes a disk-only snapshot. The migration in
`.plans/proxmox-migration.md` takes a `vzdump` to the NAS, because a snapshot dies
with the disk being wiped.

### Uncheck "Include RAM"

Measured on VM 100: a RAM-inclusive snapshot wrote **61.03 GiB in 14m23s** before
it even reached the disk, and added roughly 0.5 TiB of thin provisioning.

Disk-only completes in seconds and allocates almost nothing up front. Rollback
boots the VM instead of resuming it, which does not matter for a Docker host.
Include RAM only when the in-memory state itself is what needs preserving.

### Thin pool limits

`local-lvm` is LVM-thin, so snapshots work at all; thick LVM does not support
them. Two numbers govern how much room there is:

```bash
vgs pve                                                    # VFree
lvs -a -o lv_name,lv_size,data_percent,metadata_percent pve
```

- `data_percent` on `pve/data` is the real risk figure. Provisioned size exceeding the volume group is normal for thin provisioning; **used** space approaching 100% takes thin volumes read-only.
- `metadata_percent` is a separate failure mode with the same result. Snapshots consume metadata faster than data.
- Delete snapshots after use. Every write the VM makes while one exists allocates copy-on-write blocks in the pool.

LVM warns that `thin_pool_autoextend_threshold` is 100 (never autoextend).
Lowering it in `/etc/lvm/lvm.conf` only helps if `VFree` shows unallocated space
in the volume group to extend into. The Proxmox installer usually assigns nearly
all of it to `pve/data`, in which case the only protection is watching
`data_percent`.

PCIe passthrough breaks RAM-state snapshots; the device state cannot be
serialized. Disk-only snapshots still work.

Back up a running VM with `--mode snapshot`. The migration plan uses `--mode stop`
because it is the final backup before a wipe.

## Host and hypervisor

Debian packages on the Docker host:

```bash
sudo apt update && sudo apt upgrade
sudo reboot        # if the kernel moved
```

After any reboot, confirm NFS mounted before Docker started. If it did not, Radarr
and Sonarr show empty libraries.

```bash
mount | grep nfs
ls "$SHAREDDIR/media"
```

Proxmox: snapshot both VMs, update from the host shell, reboot into the new kernel
while CIMC is reachable.

## Cadence

| What | Interval |
|---|---|
| `dockcheck.sh -n` | Weekly |
| The *arrs, SABnzbd, Jellyfin | Monthly |
| Authentik | Deliberately, with a snapshot |
| Debian packages | Monthly, security sooner |
| Proxmox | Quarterly |
| Certificate expiry check | Monthly |
