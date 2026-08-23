---
name: scrub
description: Check markdown or any tracked file for environment details that should not be committed to this public repo - hostnames, IPs, domains, usernames, ports, keys, serials. Use before committing docs, when writing anything shareable, or when asked to scrub, sanitise, or check a file for leaks.
---

# Scrub

This repository is **public**. Its docs describe a real deployment, so they must
carry the procedure without carrying the environment.

The rule: **the repo holds the shape, the environment holds the values.**

## What must not be committed

| Category | Replace with |
|---|---|
| The domain | `<domain>` |
| Hostnames of any real machine | `<vm-host>`, `<pve-host>`, `<nas-host>` |
| IP addresses | `<vm-ip>` |
| Usernames | `<user>` |
| Non-default service ports | `<ssh-port>` |
| API keys, tokens, passwords | never, at all |
| Network share paths | `<share-path>` |
| Chassis, disk or BMC serial numbers | omit entirely |

**Fine to keep:** Docker-internal service names and ports (`radarr:7878`,
`socket-proxy:2375`) - they are not reachable outside the stack and the compose
files declare them anyway. Also fine: hardware models, PCI IDs and bus addresses,
kernel and package versions, upstream URLs.

## Checking

Run these against the files being committed. Fill in the bracketed values from
the environment rather than writing them into this file.

```bash
# IPs, excluding the pinned Docker subnets and public resolvers
grep -rnoE '\b([0-9]{1,3}\.){3}[0-9]{1,3}\b' <paths> \
  | grep -vE '192\.168\.9[0-4]\.|127\.0\.0\.1|1\.1\.1\.1|1\.0\.0\.1|0\.0\.0\.0'

# Environment-specific strings
grep -rniE "$(grep -E '^(DOMAINNAME|HOSTNAME)=' .env | cut -d= -f2 | tr -d '"' | paste -sd'|')" <paths>

# Internal DNS suffixes
grep -rniE '\.(lan|local|internal|home\.arpa)\b' <paths>

# Anything key-shaped
grep -rniE '(api[_-]?key|token|password|secret)\s*[:=]\s*[A-Za-z0-9/+_-]{12,}' <paths>

# Serial numbers
grep -rniE '\b[A-Z]{3}[0-9]{4}[A-Z0-9]{4}\b' <paths>
```

Confirm nothing sensitive was ever committed:

```bash
git log --all --diff-filter=A --name-only -- '.env' 'secrets/*' 'appdata/traefik/acme/*'
```

## Rules of thumb

**Placeholders, not fake-but-plausible values.** `<pve-host>` reads as
intentional; `192.168.1.50` reads as real and invites someone to copy it.

**A table of what you need beats a table of what it is.** Listing the fields
without the values means nothing is forgotten and nothing is disclosed.

**Compose files reference variables**, never inline values - including in
comments. Homepage config uses `{{HOMEPAGE_VAR_X}}`, substituted at runtime, so
those files stay committable.

**Pasted terminal output is the usual leak.** Console captures carry hostnames,
IPs and mount paths that prose would have abstracted. Scrub captured output or
describe it instead. Same for screenshots.

**Do not describe the contents of ignored paths.** Naming a directory in
`.gitignore` is unavoidable; characterising what is in it tells a reader where
the unredacted material would be. Keep ignore rules bare.

## Moving files between directories

Ignored paths can be frank; tracked paths cannot. Moving a file from an ignored
directory into a tracked one publishes it. **Scrub at that moment**, not later.

Check before committing anything newly added:

```bash
git status --short
git check-ignore -v <path> || echo "tracked - scrub required"
```

## If something has already been committed

Rotate first, redact second. A credential in git history is compromised
regardless of later edits - history is public and already cloned. Regenerate it,
then decide whether rewriting history is worth the disruption.
