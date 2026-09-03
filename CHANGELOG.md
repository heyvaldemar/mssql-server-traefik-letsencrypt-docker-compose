# Changelog

All notable changes to this project are documented in this file.

The format is based on [Keep a Changelog](https://keepachangelog.com/en/1.1.0/),
and this project adheres to [Semantic Versioning](https://semver.org/spec/v2.0.0.html).

## [Unreleased]

_(no unreleased changes yet)_

## [1.5.0] - 2026-09-03

### Added

- **Per-image version overrides.** Every pin in the `x-images` block is
  now `${<PREFIX>_IMAGE_TAG:-repo:${<PREFIX>_IMAGE_VERSION:-tag@sha256:digest}}`.
  Set `<PREFIX>_IMAGE_VERSION` in `.env` to run a different version of one
  image while every other pin stays as tested (Compose pulls that tag
  without a digest), or `<PREFIX>_IMAGE_TAG` to replace the whole
  reference as before. A deployment that sets neither is unchanged. The
  freshness job, the Trivy matrix and the fleet digest automation resolve
  the nested default before reading a pin. Needs Docker Compose v2.5 or
  newer (2022): v2.0 to v2.4 leave the inner `${...}` unexpanded and
  `docker compose up` fails with an invalid reference instead of
  deploying something unexpected.

## [1.4.0] - 2026-09-02

### Security

- **Container hardening.** Every service runs with
  `security_opt: no-new-privileges:true` (no privilege escalation via
  setuid binaries even if a process escapes its initial capability
  set). Infrastructure containers (the reverse proxy, databases,
  caches, backups) drop every Linux capability and add back only what
  their entrypoints need (bind :80/:443, chown a data directory, drop to
  the service user). Application containers keep the default capability
  set: upstream images assume it, and a wrong guess there is a boot loop
  in production, not a hardening win. CI boots the stack under these
  settings on every push.

### Added

- **`tests/e2e-backup-restore.sh`**: six scenarios against the live
  stack, run by CI on every push, on a database the tests create
  themselves: the required-variable guard fires, a backup of that
  database is produced, `RESTORE VERIFYONLY` passes on it, a SQL Server
  outage is reported as `FAILED`, **restore genuinely replaces database
  state** (`RESTORE ... WITH REPLACE` of the baseline removes a table
  created after it), and pruning removes only old files.

## [1.3.0] - 2026-09-02

### Added

- **A `backups` service**: this template persisted `/var/opt/mssql` and
  called that a day; now a sidecar from the same image runs `BACKUP
  DATABASE ... WITH CHECKSUM` for `master`, `msdb`, and every online
  user database on a loop, verifies each file with `RESTORE VERIFYONLY`,
  logs `Database backup OK: <file> (<bytes> bytes)` or `FAILED` per
  database (a failed file is kept as `<file>.failed`), and prunes only
  its own files. Backups land in the `mssql-server-backups` volume,
  shared with the server. Schedule knobs (`MSSQL_BACKUP_INIT_SLEEP`,
  `MSSQL_BACKUP_INTERVAL`, `MSSQL_BACKUP_PRUNE_DAYS`, path and name)
  have defaults listed in `.env.example`. No `COMPRESSION`, which
  Express does not support.
- **`mssql-restore-database.sh`**: interactive restore of a user
  database from a selected `.bak` (single-user mode, `RESTORE ... WITH
  REPLACE`, back to multi-user). System databases are refused with a
  pointer to Microsoft's procedure.
- CI waits for the first backup cycle and runs `RESTORE VERIFYONLY`
  itself on the newest file.

## [1.2.0] - 2026-09-02

### Added

- **Resource limits on every service, as `.env`-overridable defaults.**
  Each service now carries memory and CPU limits plus reservations
  (`<SERVICE>_MEMORY_LIMIT`, `_CPU_LIMIT`, `_MEMORY_RESERVATION`,
  `_CPU_RESERVATION`, defaults listed in `.env.example`). Set any of
  them in `.env` and the override survives every `git pull`. The
  defaults are what CI boots the stack under, so they are known to be
  enough for a fresh install; raise a limit if a service is OOM-killed
  under your real load (`docker inspect` shows `OOMKilled=true`).

## [1.1.0] - 2026-09-02

### Added

- **`update.sh`**: unattended updates to the newest tagged release,
  and nothing else: a tag is cut only after CI has booted the pinned
  images and passed the smoke tests, so "update to the latest tag" means
  "update to a combination a machine has already run". It refuses to
  cross a major version on its own (`--allow-major` after reading the
  notes), refuses a checkout with local modifications, and supports
  `--dry-run`. Put it on a cron timer for hands-off minor/patch updates.

## [1.0.0] - 2026-09-02

First semver release. Brings this template to the fleet standard established
in [keycloak-traefik-letsencrypt-docker-compose](https://github.com/heyvaldemar/keycloak-traefik-letsencrypt-docker-compose).

### Fixed (the shipped configuration could not work as promised)

- **The Traefik TCP router pointed at port 11434**: SQL Server listens
  on 1433, so every connection through the published entrypoint went
  nowhere. The router now targets 1433, and CI proves the routed path by
  running a query through Traefik.
- **The healthcheck could never succeed**: it referenced
  `SQLSERVER_SA_PASSWORD`, a variable that exists nowhere (the real one
  is `MSSQL_SA_PASSWORD`), and called `/opt/mssql-tools/bin/sqlcmd`, a
  path current images do not ship (`mssql-tools18` is the location, and
  its sqlcmd needs `-C` to trust the instance's self-signed
  certificate). The password is now read from the container environment
  at runtime instead of being interpolated into the config.

### Security

- **`.env` is no longer tracked in git.** The previous tracked file
  carried a literal `MSSQL_SA_PASSWORD` value, which remains in git
  history. If you deployed with it, rotate: `ALTER LOGIN sa WITH
  PASSWORD = '<new strong password>'`, update `.env`, recreate.

### Changed

- **SQL Server updated to 2022-CU26** (was 2022-CU10) and **Traefik to
  v3.7** (was 3.2), both pinned by `tag@sha256:digest` in the compose
  `x-images` block. The freshness gate tracks CUs within the 2022 line
  only: moving to SQL Server 2025 upgrades data files one-way, so that
  jump is reserved for a major release with explicit upgrade notes.
- Required variables now fail fast with `${VAR:?…}` guards;
  `TRAEFIK_LOG_LEVEL` and `MSSQL_PID` have defaults.
- `platform: linux/amd64` declared explicitly: the upstream image
  publishes no other architecture.

### Added

- **Deployment Verification workflow**: shellcheck + actionlint; a Trivy
  scan of each pinned image; daily `check-pin-freshness` (digest drift +
  same-line CU lag + Traefik release lag); and a deploy-and-test job
  that boots the full stack with an ephemeral `.env`, waits for the
  engine healthcheck, and queries through the Traefik TCP entrypoint.
- `.env.example` with generation commands; `.gitignore` for `.env`.

[Unreleased]: https://github.com/heyvaldemar/mssql-server-traefik-letsencrypt-docker-compose/compare/v1.5.0...HEAD
[1.5.0]: https://github.com/heyvaldemar/mssql-server-traefik-letsencrypt-docker-compose/compare/v1.4.0...v1.5.0
[1.4.0]: https://github.com/heyvaldemar/mssql-server-traefik-letsencrypt-docker-compose/compare/v1.3.0...v1.4.0
[1.3.0]: https://github.com/heyvaldemar/mssql-server-traefik-letsencrypt-docker-compose/compare/v1.2.0...v1.3.0
[1.2.0]: https://github.com/heyvaldemar/mssql-server-traefik-letsencrypt-docker-compose/compare/v1.1.0...v1.2.0
[1.1.0]: https://github.com/heyvaldemar/mssql-server-traefik-letsencrypt-docker-compose/compare/v1.0.0...v1.1.0
[1.0.0]: https://github.com/heyvaldemar/mssql-server-traefik-letsencrypt-docker-compose/releases/tag/v1.0.0
