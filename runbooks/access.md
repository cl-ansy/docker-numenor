# Access

Companions: [updating.md](updating.md), [latency.md](latency.md), [storage.md](storage.md).

## Addresses

| Thing | Value |
|---|---|
| Domain (`$DOMAINNAME`) | `<domain>` |
| CIMC | `<cimc-host>` |
| Proxmox host | `<pve-host>` |
| Docker VM | `<vm-host>` |
| ReadyNAS | `<nas-host>` |
| OPNsense | `<opnsense-host>` |
| SSH user | `<user>` |
| SSH port (not 22) | `<ssh-port>` |
| Docker VM ID | `100` |

## Access ladder

```
CIMC  ->  Proxmox host  ->  Docker VM  ->  services
```

Each layer reaches the next and stays up when the one below it fails. Work down
the list until something answers.

### Services

`https://<service>.<domain>`. Everything routes through Traefik. Most services sit
behind Authentik SSO. Start at `https://<domain>` for the dashboard.

### Docker VM

```bash
ssh numenor
```

Addressed directly, not under `<domain>`. `<domain>` resolves to Traefik only.

### Proxmox host

```bash
ssh pve
qm list
qm start 100
```

Web UI: `https://<pve-host>:8006`. Its noVNC console reaches the VM without the VM's
network working.

### CIMC

`https://<cimc-host>`. Out-of-band, works with the OS dead or the box powered off.
Launch KVM for a console, Power for a hard cycle.

If the CIMC web UI will not load in a current browser, its firmware only offers
TLS 1.0/1.1 and needs updating.

## Proxmox UI layout

The tree is always cluster > node > guests, even with one server. `Datacenter` is
the cluster scope. `pve` is the node name. `local (pve)` means storage `local` on
node `pve`.

Datacenter holds config that could apply to many machines. The node holds config
about this box.

| Datacenter | Node (`pve`) |
|---|---|
| Storage definitions | Disks, LVM, ZFS |
| Users, groups, API tokens, permissions | Shell / console |
| Backup jobs and schedules | Updates, repositories |
| Replication, HA | Network interfaces, DNS, hosts |
| Notification targets | Syslog, task history |
| Datacenter firewall | Node certificates, time |

Storage catches people out: a storage is defined at Datacenter, then made
available to nodes. Adding the NFS share for backups is **Datacenter > Storage >
Add > NFS**. The physical disks behind `local-lvm` are under **pve > Disks**.

## DNS

`<domain>` resolves to Traefik. Every name under it lands on the Docker VM, where
Traefik matches a router or returns 404. `cimc.<domain>` reaches Traefik, not the
BMC.

Traefik's file provider can proxy external backends, so Proxmox and CIMC could be
given names under `<domain>`. Do not do this. Emergency access would then depend
on the Docker stack being up.

Infrastructure is addressed directly, from `CIMC_HOST`, `PVE_HOST`, `NAS_HOST` and
`OPNSENSE_HOST` in `.env`. Either a bare IP or a name from the separate zone below
works. The homepage bookmarks read the same values.

For names, use a separate zone. Add host overrides in OPNsense under Services >
Unbound DNS > Overrides, in `home.arpa` or `lan`:

| Host | Domain | IP |
|---|---|---|
| `cimc` | `home.arpa` | `<cimc-ip>` |
| `pve` | `home.arpa` | `<pve-ip>` |
| `numenor` | `home.arpa` | `<vm-ip>` |
| `nas` | `home.arpa` | `<nas-ip>` |
| `opnsense` | `home.arpa` | `<opnsense-ip>` |

These resolve to the devices directly and are unaffected by `<domain>`. They get
no certificate, so browsers warn on the self-signed certs these devices serve.

## SSH

**sshd on the Docker VM does not listen on 22.** Recover the port from the VM
itself; this reads the effective config including any `sshd_config.d/` drop-ins:

```bash
sudo sshd -T | grep -w port
sudo ss -tlnp | grep ssh      # alternative
```

Then put it in `~/.ssh/config` on the workstation so it never has to be
remembered again:

```
Host numenor
    HostName <vm-host>
    User <user>
    Port <ssh-port>
    IdentityFile ~/.ssh/id_ed25519

Host pve
    HostName <pve-host>
    User root
    IdentityFile ~/.ssh/id_ed25519

Host nas
    HostName <nas-host>
    User <nas-user>
    IdentityFile ~/.ssh/id_ed25519
```

Record the port in the Addresses table at the top as well. A non-default port is
exactly the detail that is missing when the console is the only way in.

## Commands

Source `shared/.bash_aliases` from `~/.bashrc`.

| Command | Action |
|---|---|
| `dcup` | Start everything |
| `dcdown` | Stop everything |
| `dcpull` | Pull updated images |
| `dcrestart <svc>` | Restart one service |
| `dclogs <svc>` | Tail one service |
| `dps` | List containers |
| `dcconfig` | Render the merged compose config |
| `traefiklogs` | Tail the Traefik log |
| `runbook` | Open this file |

Without aliases:

```bash
cd "$DOCKERDIR"
sudo docker compose -f docker-compose-main.yml up -d --build --remove-orphans
sudo docker compose -f docker-compose-main.yml logs -tf --tail=50 <service>
```

## Diagnosing

In order. Stop at the first failure.

1. Container running? `dps`. If it restarts in a loop, `dclogs <service>`.
2. Traefik routing it? Check `https://traefik.<domain>` for the router and service. A missing router means a label typo or no `traefik.enable=true`.
3. DNS? `dig +short <service>.<domain> @<opnsense-host>` returns the VM IP. `<domain>` is internal-only, so a wrong Unbound answer means nothing resolves.
4. Certificate? Browser TLS warnings mean ACME renewal failed. `dclogs traefik`, and confirm `appdata/traefik/acme/acme.json` is mode 600.
5. Auth? A redirect loop to `auth.<domain>` means Authentik or its Postgres is unhealthy. `dclogs authentik`, `dclogs authentik-postgres`.
6. Storage? Empty libraries in Jellyfin, Radarr or Sonarr mean the NFS mount is missing and the containers bind-mounted an empty directory. `mount | grep nfs`, `ls "$SHAREDDIR/media"`.

## Paths

| What | Path |
|---|---|
| Compose stack | `$DOCKERDIR` |
| Service state | `$DOCKERDIR/appdata/<service>` |
| Docker secrets | `$DOCKERDIR/secrets/` (mode 600, not in git) |
| TLS certs | `$DOCKERDIR/appdata/traefik/acme/acme.json` (mode 600) |
| Traefik middleware | `$DOCKERDIR/appdata/traefik/rules/` |
| Logs | `$DOCKERDIR/logs/` |
| Media (NFS) | `$SHAREDDIR/media` |
| Media (local, RAID0) | `$LOCALMEDIADIR`, see [storage.md](storage.md) |
| Downloads | `$DOWNLOADSDIR` |

Paths come from `.env`, which is not in git. Copy `.env.example` to start.

## Adding a service to the dashboard

Homepage discovers containers through the socket proxy. Add labels to the
service's compose file:

```yaml
      - homepage.group=Media
      - homepage.name=Example
      - homepage.icon=example.png
      - homepage.href=https://example.$DOMAINNAME
      - homepage.description=What it does
```

Group order: `appdata/homepage/settings.yaml`. Non-container entries:
`appdata/homepage/bookmarks.yaml`.
