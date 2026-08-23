# Access

See also [updating.md](updating.md), [latency.md](latency.md), [storage.md](storage.md), [gpu.md](gpu.md).

## Addresses

This table stays a template - the repo is public. Real addresses, ports and
usernames go in `~/.ssh/config`, `.env`, and a password manager. The table is
here so nothing gets forgotten when the console is the only way in.

| Thing | Value |
|---|---|
| Domain (`$DOMAINNAME`) | `<domain>` |
| CIMC | `<cimc-host>` |
| Proxmox host | `<pve-host>` |
| Docker VM | `<vm-host>` |
| NAS | `<nas-host>` |
| Firewall | `<opnsense-host>` |
| SSH user | `<user>` |
| SSH port (not 22) | `<ssh-port>` |
| Docker VM ID | `100` |

## Access ladder

```
CIMC  ->  Proxmox host  ->  Docker VM  ->  services
```

Each layer reaches the next and stays up when the one below it fails. Work down
until something answers.

### Services

`https://<service>.<domain>`. Everything routes through Traefik, and most
services sit behind Authentik SSO. Start at `https://<domain>` for the dashboard.

### Docker VM

```bash
ssh <vm-host>
```

Addressed directly, not under `<domain>` - that resolves to Traefik only.

### Proxmox host

```bash
ssh pve
qm list
qm start 100
```

Web UI at `https://<pve-host>:8006`. Its noVNC console reaches the VM even when
the VM's network is down.

### CIMC

`https://<cimc-host>`. Out-of-band, works with the OS dead or the box powered
off. Launch KVM for a console, Power for a hard cycle.

The Cisco Integrated Management Controller is a separate processor on the
motherboard with its own network port and standby power - Dell calls theirs
iDRAC, HP calls it iLO. It's the only way to reach BIOS setup, watch a boot, or
fix a host that won't start, so every risky host change depends on it working.

If the web UI won't load in a current browser, the firmware only offers TLS
1.0/1.1 and needs updating.

#### Configuring it without a reboot

As of 2026-08-22 CIMC reports `0.0.0.0` - no address. It can be set from the
running host over the internal IPMI interface, no downtime:

```bash
apt install ipmitool
modprobe ipmi_si ipmi_devintf
ipmitool lan print 1              # current config, MAC, port mode
ipmitool user list 1              # confirm a usable account exists
```

```bash
ipmitool lan set 1 ipsrc static
ipmitool lan set 1 ipaddr <cimc-ip>
ipmitool lan set 1 netmask <mask>
ipmitool lan set 1 defgw ipaddr <gateway>
ipmitool lan print 1              # verify
```

Static rather than DHCP - this is the layer you reach when other things are
down, so its address shouldn't depend on a DHCP server that might also be down.

Two things `ipmitool` can't fix. The rear dedicated management port has to be
cabled to a switch. And NIC mode (Dedicated vs Shared LOM) may only be reachable
via F8 at boot, so if `lan print` shows a mode that doesn't match the cabling,
that part needs console access.

Once it works, set `CIMC_HOST` in `.env` so the homepage bookmark resolves.

## Proxmox UI layout

The tree is cluster > node > guests even with one server. `Datacenter` is the
cluster scope, `pve` is the node name, and `local (pve)` means storage `local` on
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

Storage catches people out: it's defined at Datacenter, then made available to
nodes. Adding the NFS share for backups is **Datacenter > Storage > Add > NFS**.
The physical disks behind `local-lvm` are under **pve > Disks**.

## DNS

`<domain>` resolves to Traefik. Every name under it lands on the Docker VM, where
Traefik either matches a router or returns 404 - so `cimc.<domain>` reaches
Traefik, not the BMC.

Traefik's file provider could proxy Proxmox and CIMC under `<domain>`. Don't do
that: emergency access would then depend on the Docker stack being up.

Infrastructure is addressed directly, from `CIMC_HOST`, `PVE_HOST`, `NAS_HOST`
and `OPNSENSE_HOST` in `.env`. A bare IP or a name from a separate zone both
work, and the homepage bookmarks read the same values.

For names, use a zone unrelated to `<domain>`. Add host overrides under Services
> Unbound DNS > Overrides, in `home.arpa` or `lan`:

| Host | Domain | IP |
|---|---|---|
| `cimc` | `home.arpa` | `<cimc-ip>` |
| `pve` | `home.arpa` | `<pve-ip>` |
| `<vm-host>` | `home.arpa` | `<vm-ip>` |
| `nas` | `home.arpa` | `<nas-ip>` |
| `fw` | `home.arpa` | `<opnsense-ip>` |

These resolve straight to the devices and aren't affected by `<domain>`. They get
no certificate, so browsers warn on the self-signed certs those devices serve.

## SSH

sshd on the Docker VM does not listen on 22. Recover the port from the VM - this
reads the effective config including any `sshd_config.d/` drop-ins:

```bash
sudo sshd -T | grep -w port
sudo ss -tlnp | grep ssh      # alternative
```

Then put it in `~/.ssh/config` on the workstation:

```
Host <vm-host>
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

Keep customisations in `/etc/ssh/sshd_config.d/` rather than `sshd_config`
itself. Drop-ins aren't package conffiles, so a distro upgrade won't offer to
replace them - which matters most for `PasswordAuthentication no`, since the
stock file leaves it commented and sshd defaults to `yes`.

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

1. **Container running?** `dps`. If it restarts in a loop, `dclogs <service>`.
2. **Traefik routing it?** Check `https://traefik.<domain>` for the router and service. A missing router usually means a label typo or no `traefik.enable=true`.
3. **DNS?** `dig +short <service>.<domain> @<opnsense-host>` should return the VM IP. The domain is internal-only, so a wrong Unbound answer means nothing resolves.
4. **Certificate?** Browser TLS warnings mean ACME renewal failed. `dclogs traefik`, and check `appdata/traefik/acme/acme.json` is mode 600.
5. **Auth?** A redirect loop to `auth.<domain>` means Authentik or its Postgres is unhealthy. `dclogs authentik`, `dclogs authentik-postgres`.
6. **Storage?** Empty libraries in Jellyfin, Radarr or Sonarr mean the NFS mount is missing and containers bind-mounted an empty directory. Run `mount | grep nfs`, then list the mountpoint by its real path. `$SHAREDDIR` is a compose variable and is not set in an interactive shell, so `ls "$SHAREDDIR/media"` silently lists `/media` instead.

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
| Media (local) | `$LOCALMEDIADIR`, see [storage.md](storage.md) |
| Downloads | `$DOWNLOADSDIR` |

Paths come from `.env`, which is not in git. Copy `.env.example` to start.

## Adding a service to the dashboard

Services are defined in `appdata/homepage/services.yaml`, not as `homepage.*`
labels on the compose file. The two are independent mechanisms, so using both
renders every service twice.

```yaml
- Media:
    - Example:
        icon: example.png
        href: https://example.{{HOMEPAGE_VAR_DOMAIN}}
        description: What it does
        server: my-docker      # matches appdata/homepage/docker.yaml
        container: example     # gives the status dot
```

API keys go in `compose/homepage.yml` as `HOMEPAGE_VAR_*` and are referenced as
`"{{HOMEPAGE_VAR_X}}"`. Quote them, or YAML reads the braces as a flow mapping.

Group order is in `appdata/homepage/settings.yaml`. Non-container entries go in
`appdata/homepage/bookmarks.yaml`.
