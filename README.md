# Microsoft SQL Server + Traefik + Let's Encrypt — Docker Compose

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

- [`mcr.microsoft.com/mssql/server`](https://mcr.microsoft.com/en-us/artifact/mar/mssql/server/about) — SQL Server on Linux, Microsoft's official image
- [`traefik`](https://hub.docker.com/_/traefik) — reverse proxy, Docker Hub official image

Both are pinned to `tag@sha256:<digest>` as interpolation defaults in the compose file's `x-images` block. Compose pulls by digest, not by tag, so two users deploying on different days get byte-identical image manifests — and `git pull` alone delivers the version combination this repository has tested. Setting `MSSQL_IMAGE_TAG` or `TRAEFIK_IMAGE_TAG` in `.env` overrides the default when you deliberately want a different version.

The daily `check-pin-freshness` CI job re-resolves each pinned tag against its registry and compares the pinned cumulative update against the newest CU **in the same release line** (currently 2022). The yearly engine line is never bumped by a routine update: attaching existing data files to a newer engine (2022 → 2025) upgrades them one-way, so that jump only ever happens in a major release of this template with explicit upgrade notes. GitHub Actions are pinned by commit SHA with version comments; Dependabot keeps those fresh.

The image is published for `linux/amd64` only and the compose file declares that platform explicitly.

## Production checklist

- [ ] **Do not expose 1433 to the internet.** SQL Server's port is scanned constantly and `sa` is the most brute-forced account name in existence. Bind the port to a private interface, firewall it to known client IPs, or reach it over VPN/SSH tunnel.
- [ ] **Strong `sa` password, then stop using `sa`.** Create named logins with the minimum roles your applications need and disable `sa` (`ALTER LOGIN sa DISABLE`).
- [ ] **Check your licensing.** `MSSQL_PID=Developer` is free but licensed for development only. Production needs Express (limits apply), a paid edition, or a product key.
- [ ] **Back up your databases.** This template persists `/var/opt/mssql` in a named volume, which is not a backup. Schedule `BACKUP DATABASE` to a path you replicate off-host.
- [ ] **Plan engine upgrades deliberately.** Moving to SQL Server 2025 upgrades database files one-way on first attach. Take full backups first, test the restore on the new engine, then change the pin.
- [ ] **Lock down the Traefik dashboard.** Basic auth is basic. Consider Traefik's `IPAllowList` middleware or not exposing the dashboard publicly at all.

## Testing

The [Deployment Verification](https://github.com/heyvaldemar/mssql-server-traefik-letsencrypt-docker-compose/actions/workflows/deployment-verification.yml?query=branch%3Amain) workflow runs on every push, pull request, and every day at 06:00 UTC: shellcheck + actionlint, a Trivy scan of each pinned image, the daily `check-pin-freshness` job, and a deploy-and-test job that boots the full stack with an ephemeral `.env`, waits for the engine's healthcheck, and executes a query through Traefik's TCP entrypoint — proving the routed path, not just the container.

## Security Notes

- Credentials are read from `.env` at deploy time; `.env` is gitignored and required variables fail fast with `${VAR:?…}` guards.
- **Pre-rotation advisory.** Before v1.0.0 this repository tracked a `.env` containing a literal `MSSQL_SA_PASSWORD` value. That value remains in git history. Anyone who deployed with it (or an `.env` derived from it) should change the `sa` password: `ALTER LOGIN sa WITH PASSWORD = '<new strong password>'`, then update `.env` and `docker compose up -d --force-recreate`.

---

## About the maintainer

<div align="center">

**Maintained by [Vladimir Mikhalev](https://github.com/heyvaldemar)** — Docker Captain · IBM Champion · AWS Community Builder

[YouTube](https://www.youtube.com/channel/UCf85kQ0u1sYTTTyKVpxrlyQ?sub_confirmation=1) · [Blog](https://heyvaldemar.com) · [LinkedIn](https://www.linkedin.com/in/heyvaldemar/)

</div>
