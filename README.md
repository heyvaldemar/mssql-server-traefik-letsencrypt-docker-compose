# Microsoft SQL Server + Traefik + Let's Encrypt on Docker Compose

[![Deployment Verification](https://github.com/heyvaldemar/mssql-server-traefik-letsencrypt-docker-compose/actions/workflows/deployment-verification.yml/badge.svg?branch=main)](https://github.com/heyvaldemar/mssql-server-traefik-letsencrypt-docker-compose/actions/workflows/deployment-verification.yml)

This repository deploys **Microsoft SQL Server 2022** behind **Traefik**, with SQL traffic routed through a dedicated TCP entrypoint on port 1433 and the Traefik dashboard served over automatic **Let's Encrypt TLS**.

📙 Full narrative installation guide on the blog: [heyvaldemar.com/install-mssql-server-using-docker-compose/](https://www.heyvaldemar.com/install-mssql-server-using-docker-compose/).

## Getting started

```bash
# 1. Clone
git clone https://github.com/heyvaldemar/mssql-server-traefik-letsencrypt-docker-compose
cd mssql-server-traefik-letsencrypt-docker-compose

# 2. Create the two Docker networks the stack expects
docker network create traefik-network
docker network create mssql-server-network

# 3. Copy the environment template and fill in required values
cp .env.example .env
$EDITOR .env
# ^ Required: MSSQL_SA_PASSWORD, TRAEFIK_ACME_EMAIL, TRAEFIK_HOSTNAME,
#   TRAEFIK_BASIC_AUTH. See .env.example for generation commands.

# 4. Deploy
docker compose -f mssql-server-traefik-letsencrypt-docker-compose.yml -p mssql up -d
```

SQL Server accepts connections on `your-server:1433` (through Traefik's TCP entrypoint) within a minute or two, and `https://${TRAEFIK_HOSTNAME}` serves the basic-auth protected Traefik dashboard with a fresh Let's Encrypt certificate.

### What success looks like

```bash
docker compose -f mssql-server-traefik-letsencrypt-docker-compose.yml -p mssql ps
# Expected: mssql and traefik both show "(healthy)"

# Query through the published port (uses sqlcmd from inside the container):
docker compose -f mssql-server-traefik-letsencrypt-docker-compose.yml -p mssql exec mssql \
  /bin/sh -c '/opt/mssql-tools18/bin/sqlcmd -S traefik,1433 -U sa -P "$MSSQL_SA_PASSWORD" -C -Q "SELECT @@VERSION"'
# Expected: the SQL Server 2022 version banner
```

### Common first-deploy issues

- **`docker compose up` fails with `set in .env`.** A required variable is empty in `.env`; the error names it. Most likely: `MSSQL_SA_PASSWORD`.
- **mssql restarts and the log says the password does not meet complexity requirements.** SQL Server refuses to initialize with a weak `sa` password. Use the generation command in `.env.example`.
- **Network not found.** Step 2 (the `docker network create` commands) was skipped.
- **Clients cannot connect from outside.** Port 1433 must be open in your firewall; and consider whether it should be (see the checklist below).

### Apply `.env` or compose-file changes

```bash
docker compose -f mssql-server-traefik-letsencrypt-docker-compose.yml -p mssql up -d --force-recreate
```

## Supply chain trust

This repository is a deployment template, not a custom image. It orchestrates two upstream images:

- [`mcr.microsoft.com/mssql/server`](https://mcr.microsoft.com/en-us/artifact/mar/mssql/server/about): SQL Server on Linux, Microsoft's official image
- [`traefik`](https://hub.docker.com/_/traefik): reverse proxy, Docker Hub official image

Both are pinned to `tag@sha256:<digest>` as interpolation defaults in the compose file's `x-images` block. Compose pulls by digest, not by tag, so two users deploying on different days get byte-identical image manifests, and `git pull` alone delivers the version combination this repository has tested. Setting `MSSQL_IMAGE_TAG` or `TRAEFIK_IMAGE_TAG` in `.env` overrides the default when you deliberately want a different version.

Two override levels exist per image. `<PREFIX>_IMAGE_VERSION` in `.env` swaps only the version of that image (Compose then pulls the tag, without a digest) and leaves every other pin as tested; `<PREFIX>_IMAGE_TAG` replaces the whole reference, digest included. The variable names are listed in `.env.example`. Nested defaults need Docker Compose v2.5 or newer (2022); v2.0 to v2.4 leave the inner `${...}` unexpanded and `docker compose up` fails with an invalid reference instead of deploying something unexpected.

The daily `check-pin-freshness` CI job re-resolves each pinned tag against its registry and compares the pinned cumulative update against the newest CU **in the same release line** (currently 2022). The yearly engine line is never bumped by a routine update: attaching existing data files to a newer engine (2022 → 2025) upgrades them one-way, so that jump only ever happens in a major release of this template with explicit upgrade notes. GitHub Actions are pinned by commit SHA with version comments; Dependabot keeps those fresh.

The image is published for `linux/amd64` only and the compose file declares that platform explicitly.

## Production checklist

- [ ] **Do not expose 1433 to the internet.** SQL Server's port is scanned constantly and `sa` is the most brute-forced account name in existence. Bind the port to a private interface, firewall it to known client IPs, or reach it over VPN/SSH tunnel.
- [ ] **Strong `sa` password, then stop using `sa`.** Create named logins with the minimum roles your applications need and disable `sa` (`ALTER LOGIN sa DISABLE`).
- [ ] **Check your licensing.** `MSSQL_PID=Developer` is free but licensed for development only. Production needs Express (limits apply), a paid edition, or a product key.
- [ ] **Replicate backups off-host.** The `backups` service writes verified `.bak` files into the `mssql-server-backups` volume on the same host. Bind-mount it to a path your off-host backup solution covers.
- [ ] **Plan engine upgrades deliberately.** Moving to SQL Server 2025 upgrades database files one-way on first attach. Take full backups first, test the restore on the new engine, then change the pin.
- [ ] **Lock down the Traefik dashboard.** Basic auth is basic. Consider Traefik's `IPAllowList` middleware or not exposing the dashboard publicly at all.

## Unattended updates

Releases are the update channel: a tag is cut only after CI has built the pinned images, booted the full stack, and passed the smoke tests. `update.sh` moves a deployment to the newest tag and nothing else:

```bash
./update.sh --dry-run   # show what would be applied
./update.sh             # update within the current major and redeploy
```

Put it on a timer for hands-off minor/patch updates:

```bash
# crontab -e
17 5 * * *  /opt/mssql-server-traefik-letsencrypt-docker-compose/update.sh >> /var/log/mssql-server-update.log 2>&1
```

The script refuses to cross a MAJOR template version on its own: majors are breaking by definition and their release notes exist to be read. After reading them, `./update.sh --allow-major` performs the jump. It also refuses to touch a checkout with local modifications: your customization belongs in `.env`, which updates never overwrite.

This is deliberately a host-side script and not a container in the stack: an in-stack updater needs the Docker socket (root on the host) and turns "someone pushed to a repo" into "someone deployed to your machine" with no operator in the loop. A cron job under your own user updates only to tagged, CI-verified states and leaves the trust boundary where it was.

## Resource limits

Every service carries memory and CPU limits plus reservations as compose-level defaults, the same values CI boots the stack under. Override any of them in `.env` (the knobs and their defaults are listed in `.env.example`, e.g. `TRAEFIK_MEMORY_LIMIT=512m`) and the override survives every `git pull`. If a service is OOM-killed under real load, `docker inspect <container> --format '{{.State.OOMKilled}}'` says so; raise its `_MEMORY_LIMIT` and recreate.

## Backups

The `backups` sidecar (same image as the server) runs on a loop: an initial delay (`MSSQL_BACKUP_INIT_SLEEP`, default 30m), then every `MSSQL_BACKUP_INTERVAL` (default 24h) a `BACKUP DATABASE ... WITH CHECKSUM` of `master`, `msdb`, and every online user database into the `mssql-server-backups` volume shared with the server, each file verified with `RESTORE VERIFYONLY`; files older than `MSSQL_BACKUP_PRUNE_DAYS` (default 7) are pruned. Each database logs `Database backup OK: <file> (<bytes> bytes)` or `Database backup FAILED` (the file is kept as `<file>.failed`). Grep the log for `FAILED` from your monitoring.

**Verify backups are running:**

```bash
docker compose -p mssql logs backups | tail -5
docker compose -p mssql exec backups ls -la /var/opt/mssql/backup/
```

**Restore** a user database with the interactive script (`chmod +x mssql-restore-database.sh` once): it lists the `.bak` files, derives the database name from the file name, drops other connections, runs `RESTORE DATABASE ... WITH REPLACE`, and returns the database to multi-user mode.

```bash
./mssql-restore-database.sh
```

**Off-host replication.** The backup volume lives on the same host as the data. Bind-mount `MSSQL_BACKUPS_PATH` to a directory covered by your off-host backup solution (restic, rclone, Borg, S3 sync). Backups are not compressed (Express cannot create compressed backups); compress in transit if size matters.

## Container hardening

Every service runs with `security_opt: no-new-privileges:true`, so a process cannot gain privileges through setuid binaries even if it escapes its initial capability set. Infrastructure containers (the reverse proxy, databases, caches, backups) run with `cap_drop: [ALL]` and add back only what their entrypoints need: `NET_BIND_SERVICE` for Traefik to bind :80/:443, `CHOWN`/`SETUID`/`SETGID` (and friends) for database images to own their data directory and drop to their service user. Application containers keep the default capability set on purpose: upstream images assume it, and a wrong guess there is a boot loop in production rather than a hardening win. CI boots the stack under exactly these settings on every push, so what ships is what was tested.

## Testing

The [Deployment Verification](https://github.com/heyvaldemar/mssql-server-traefik-letsencrypt-docker-compose/actions/workflows/deployment-verification.yml?query=branch%3Amain) workflow runs on every push, pull request, and every day at 06:00 UTC: shellcheck + actionlint, a Trivy scan of each pinned image, the daily `check-pin-freshness` job, and a deploy-and-test job that boots the full stack with an ephemeral `.env`, waits for the engine's healthcheck, and executes a query through Traefik's TCP entrypoint, proving the routed path, not just the container.

### Backup and restore, proven

`tests/e2e-backup-restore.sh` runs against the live stack and is what CI executes after the smoke test. It works on a database it creates itself (`e2e_test`), so nothing of yours is touched, but the failure scenario stops the SQL Server container briefly, so run it on a staging copy. The scenario that matters most is the restore roundtrip: create a table after the baseline backup, `RESTORE ... WITH REPLACE` the baseline, assert the table is gone.

```bash
chmod +x tests/e2e-backup-restore.sh
./tests/e2e-backup-restore.sh
```

## Security Notes

- Credentials are read from `.env` at deploy time; `.env` is gitignored and required variables fail fast with `${VAR:?…}` guards.
- **Pre-rotation advisory.** Before v1.0.0 this repository tracked a `.env` containing a literal `MSSQL_SA_PASSWORD` value. That value remains in git history. Anyone who deployed with it (or an `.env` derived from it) should change the `sa` password: `ALTER LOGIN sa WITH PASSWORD = '<new strong password>'`, then update `.env` and `docker compose up -d --force-recreate`.

---

## About the maintainer

<div align="center">

**Maintained by [Vladimir Mikhalev](https://github.com/heyvaldemar)** · Docker Captain · IBM Champion · AWS Community Builder

[YouTube](https://www.youtube.com/channel/UCf85kQ0u1sYTTTyKVpxrlyQ?sub_confirmation=1) · [Blog](https://heyvaldemar.com) · [LinkedIn](https://www.linkedin.com/in/heyvaldemar/)

</div>
