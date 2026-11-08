#!/bin/bash
# End-to-end tests for the SQL Server backup + restore flow.
#
# Requires: docker, docker compose. Assumes the stack is already up with
# short backup intervals in .env (CI uses INIT_SLEEP=15s, INTERVAL=60s).
#
# Run from the repository root:
#   ./tests/e2e-backup-restore.sh
#
# The tests work on a database they create themselves (e2e_test), so a
# real deployment's databases are never touched - but the failure scenario
# stops the SQL Server container briefly: run this on a staging copy.
#
# Tests and helpers are dispatched indirectly via run_test "$name"; shellcheck
# cannot trace that and flags every function as unused (SC2329).
# shellcheck disable=SC2329

set -euo pipefail

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$REPO_ROOT"

COMPOSE_PROJECT_NAME="${COMPOSE_PROJECT_NAME:-mssql}"
DOCKER_COMPOSE_FILE="${DOCKER_COMPOSE_FILE:-mssql-server-traefik-letsencrypt-docker-compose.yml}"

if [[ -f .env ]]; then
  set -o allexport
  # shellcheck disable=SC1091
  source .env
  set +o allexport
else
  echo "error: .env not found at $REPO_ROOT/.env" >&2
  exit 1
fi

: "${MSSQL_BACKUPS_PATH:=/var/opt/mssql/backup}"
: "${MSSQL_BACKUP_NAME:=mssql-backup}"
: "${MSSQL_BACKUP_INTERVAL:=24h}"

BACKUPS_PATH="${MSSQL_BACKUPS_PATH%/}"
BACKUP_PREFIX="${MSSQL_BACKUP_NAME}"
INTERVAL="${MSSQL_BACKUP_INTERVAL}"
TEST_DB="e2e_test"

# Note: never `grep -q` on a docker logs pipe here - with pipefail, grep
# exiting early sends docker logs a SIGPIPE and the whole pipeline fails.

BACKUPS_CONTAINER="$(docker compose -f "$DOCKER_COMPOSE_FILE" -p "$COMPOSE_PROJECT_NAME" ps -aq backups | head -n 1)"
DB_CONTAINER="$(docker compose -f "$DOCKER_COMPOSE_FILE" -p "$COMPOSE_PROJECT_NAME" ps -aq mssql | head -n 1)"
[[ -n "$BACKUPS_CONTAINER" ]] || { echo "error: backups container not found" >&2; exit 1; }
[[ -n "$DB_CONTAINER" ]] || { echo "error: mssql container not found" >&2; exit 1; }

interval_seconds() {
  local v="$INTERVAL"
  case "$v" in
    *h) echo $(( ${v%h} * 3600 )) ;;
    *m) echo $(( ${v%m} * 60 )) ;;
    *s) echo "${v%s}" ;;
    *) echo "$v" ;;
  esac
}
CYCLE_WAIT=$(( $(interval_seconds) + 60 ))

PASSED=0
FAILED=0
FAILURES=()

run_test() {
  local name="$1"
  echo
  echo "=== $name ==="
  if "$name"; then
    echo "  PASS: $name"
    PASSED=$((PASSED + 1))
  else
    echo "  FAIL: $name" >&2
    FAILED=$((FAILED + 1))
    FAILURES+=("$name")
  fi
}

fail() {
  echo "  ASSERT: $*" >&2
  return 1
}

backups_sh() {
  docker exec "$BACKUPS_CONTAINER" sh -c "$1"
}

# sqlcmd from the backups container against the server; the password comes
# from the container environment, never from this shell.
sql() {
  docker exec "$BACKUPS_CONTAINER" sh -c 'SQLCMDPASSWORD="$MSSQL_SA_PASSWORD" /opt/mssql-tools18/bin/sqlcmd -S mssql -U sa -C -b -h -1 -W -Q "$1" | tr -d "\r"' _ "$1"
}

db_ready() {
  docker exec "$BACKUPS_CONTAINER" sh -c 'SQLCMDPASSWORD="$MSSQL_SA_PASSWORD" /opt/mssql-tools18/bin/sqlcmd -S mssql -U sa -C -b -Q "SELECT 1"' > /dev/null 2>&1
}

wait_for_db_ready() {
  local timeout="${1:-120}" elapsed=0
  while [[ $elapsed -lt $timeout ]]; do
    db_ready && return 0
    sleep 3; elapsed=$((elapsed + 3))
  done
  return 1
}

# backups of the test database only, oldest first
list_backups() {
  backups_sh "ls -1 ${BACKUPS_PATH}/${BACKUP_PREFIX}-${TEST_DB}-*.bak 2>/dev/null" | sort || true
}

post_marker_backup() {
  local f elapsed=0
  while :; do
    f=$(backups_sh "find ${BACKUPS_PATH} -name '${BACKUP_PREFIX}-${TEST_DB}-*.bak' -newer ${BACKUPS_PATH}/.e2e-marker-stamp 2>/dev/null | sort | head -1")
    [[ -n "$f" ]] && { echo "$f"; return 0; }
    [[ $elapsed -lt $CYCLE_WAIT ]] || return 1
    sleep 5; elapsed=$((elapsed + 5))
  done
}

marker_count() {
  sql "SET NOCOUNT ON; SELECT count(*) FROM [$TEST_DB].dbo.restore_test;" | tr -d '[:space:]'
}
# the server answers on master before user databases finish recovery, and
# a query against a recovering database returns "Msg 904" instead of a number
wait_for_test_db_online() {
  local timeout="${1:-120}" elapsed=0 state
  while [[ $elapsed -lt $timeout ]]; do
    # state_desc says ONLINE before the server finishes its own startup; a
    # database with AUTO_CLOSE (the Express default) then answers Msg 904,
    # so the proof is a query that touches the database and returns a number
    state=$(sql "SET NOCOUNT ON; SELECT count(*) FROM [$TEST_DB].sys.tables;" 2>/dev/null | tr -d '[:space:]')
    [[ "$state" =~ ^[0-9]+$ ]] && return 0
    sleep 3; elapsed=$((elapsed + 3))
  done
  return 1
}

# --- Test cases ---

test_env_required() {
  mv .env .env.bak
  local out
  out=$(env -i PATH="$PATH" HOME="$HOME" docker compose -f "$DOCKER_COMPOSE_FILE" config 2>&1 || true)
  mv .env.bak .env
  echo "$out" | grep -qiE "set in \.env|required|is not set" && return 0
  fail "expected a required-variable error from docker compose config"
}

test_backup_created() {
  echo "  waiting up to ${CYCLE_WAIT}s for a backup of $TEST_DB..."
  local first
  first=$(post_marker_backup) || { fail "no backup of $TEST_DB within ${CYCLE_WAIT}s"; return 1; }
  local size
  size=$(backups_sh "stat -c %s $first" | tr -d '[:space:]')
  [[ -n "$size" && "$size" -gt 0 ]] || { fail "backup $first has size '$size'"; return 1; }
  echo "  first backup: $first ($size bytes)"
}

test_backup_verifyonly() {
  local newest
  newest=$(list_backups | tail -1)
  sql "RESTORE VERIFYONLY FROM DISK = N'$newest' WITH CHECKSUM;" > /dev/null || { fail "RESTORE VERIFYONLY failed on $newest"; return 1; }
  echo "  RESTORE VERIFYONLY passed on $newest"
}

test_backup_failure_detected() {
  echo "  stopping SQL Server to force a failed cycle"
  docker stop "$DB_CONTAINER" > /dev/null
  echo "  waiting ${CYCLE_WAIT}s for the failed cycle..."
  sleep "$CYCLE_WAIT"
  echo "  restarting SQL Server"
  docker start "$DB_CONTAINER" > /dev/null
  wait_for_db_ready 180 || { fail "SQL Server did not become ready within 180s after restart"; return 1; }
  wait_for_test_db_online 180 || { fail "$TEST_DB did not come back ONLINE within 180s after restart"; return 1; }
  # sqlcmd cannot even list the databases while the server is down, so the
  # loop logs FAILED without a partial file; the log line is the evidence.
  docker logs "$BACKUPS_CONTAINER" 2>&1 | grep -i "backup FAILED" > /dev/null || { fail "expected a 'backup FAILED' log line"; return 1; }
}

test_restore_roundtrip() {
  # Take the earliest post-marker backup of the test database, add a marker
  # row, restore, assert the marker is gone.
  local baseline before
  baseline=$(post_marker_backup) || { fail "no baseline backup"; return 1; }
  echo "  baseline: $baseline"
  sql "IF OBJECT_ID('[$TEST_DB].dbo.restore_test') IS NULL CREATE TABLE [$TEST_DB].dbo.restore_test (id int); INSERT INTO [$TEST_DB].dbo.restore_test VALUES (1);" > /dev/null
  before=$(marker_count)
  [[ "$before" =~ ^[0-9]+$ && "$before" -ge 1 ]] || { fail "marker insert failed: count=$before"; return 1; }
  echo "  restoring the baseline (single-user, RESTORE WITH REPLACE)"
  # THE SHIPPED SCRIPT, NOT A COPY OF ITS COMMANDS.
  COMPOSE_PROJECT_NAME="$COMPOSE_PROJECT_NAME" ./mssql-restore-database.sh "$(basename "$baseline")" > /dev/null \
    || { fail "./mssql-restore-database.sh failed"; return 1; }
  local exists
  exists=$(sql "SET NOCOUNT ON; SELECT count(*) FROM [$TEST_DB].sys.tables WHERE name = 'restore_test';" | tr -d '[:space:]')
  [[ "$exists" == "0" ]] || { fail "restore_test still present after restore - restore was a no-op"; return 1; }
  echo "  marker absent after restore - the backup is restorable"
}

test_prune_removes_old() {
  local fake_old="${BACKUPS_PATH}/${BACKUP_PREFIX}-${TEST_DB}-0000-00-00_00-00.bak"
  echo "  placing a fake file dated 2020 at $fake_old"
  backups_sh "echo fake > $fake_old && touch -t 202001010000 $fake_old" || { fail "could not create the fake file"; return 1; }
  # A cycle is a database dump, a data backup that takes as long as the data
  # does, the prune, then the interval. Nextcloud 35.0.1's data backup took
  # 98 s on 2026-09-25 and a fixed wait of interval + 60 s asked before the
  # prune had run. Wait for the prune itself, with a ceiling of two cycles.
  local ceiling=$(( $(interval_seconds) * 2 + 300 )) waited=0
  echo "  waiting up to ${ceiling}s for a prune cycle to remove it..."
  while backups_sh "ls $fake_old 2>/dev/null" > /dev/null 2>&1; do
    if [ "$waited" -ge "$ceiling" ]; then fail "fake old file survived ${ceiling}s, longer than two backup cycles"; return 1; fi
    sleep 5; waited=$(( waited + 5 ))
  done
  echo "  pruned after ${waited}s"
  [[ -n "$(list_backups)" ]] || { fail "prune removed everything, including recent backups"; return 1; }
}

# --- No password on any command line ---
#
# A process's arguments are /proc/<pid>/cmdline, mode 0444: every user on the
# host reads them with ps, and the host sees every container's processes. Its
# environment is /proc/<pid>/environ, readable by its owner alone. So sqlcmd
# reads SQLCMDPASSWORD, never -P. Two proofs, both matched against a file
# holding the value, so the value is never printed and never becomes an
# argument of the comparison itself:
#   - a sampler reads every command line on this machine several times a
#     second for the whole suite;
#   - the backup of a database big enough to take seconds is read while it
#     runs, on the host and inside the backups container.
DB_PASS="${MSSQL_SA_PASSWORD:?set in .env}"
PW_FILE="$(mktemp)"; PS_COUNTS="$(mktemp)"; PS_SAMPLER=""
trap 'rm -f "$PW_FILE" "$PS_COUNTS"; [[ -z "$PS_SAMPLER" ]] || kill "$PS_SAMPLER" 2>/dev/null || true' EXIT
chmod 600 "$PW_FILE"; printf '%s\n' "$DB_PASS" > "$PW_FILE"
PW_SUM="sha256:$(printf '%s' "$DB_PASS" | sha256sum | cut -c1-12)"   # names the value in this log without showing it
PROBE_DB="zz_argv_probe"

argv_hits() { grep -cF -f "$PW_FILE" || true; }                 # lines on stdin that contain the value
cmdlines_in() {                                                   # every command line inside one container
  docker exec "$1" sh -c 'for f in /proc/[0-9]*/cmdline; do tr "\000" " " < "$f" 2>/dev/null; echo; done'
}
seconds_of() {
  case "$1" in
    *h) echo $(( ${1%h} * 3600 )) ;;
    *m) echo $(( ${1%m} * 60 )) ;;
    *s) echo "${1%s}" ;;
    *) echo "$1" ;;
  esac
}
ps_sampler_start() {
  ( while :; do ps -eo args= 2>/dev/null | argv_hits >> "$PS_COUNTS"; sleep 0.2; done ) &
  PS_SAMPLER=$!
}
ps_sampler_stop() {
  [[ -n "$PS_SAMPLER" ]] || return 0
  kill "$PS_SAMPLER" 2>/dev/null || true; wait "$PS_SAMPLER" 2>/dev/null || true; PS_SAMPLER=""
}

test_backup_runs_without_password_in_argv() {
  # 20,000 rows of 8 KB: BACKUP ... WITH CHECKSUM and RESTORE VERIFYONLY of it
  # take seconds, long enough to read the sqlcmd process that asked for them.
  local init since cmd="" i ok="" hits_host hits_bkp
  init=$(seconds_of "${MSSQL_BACKUP_INIT_SLEEP:-30m}")
  [[ "$init" -le 120 ]] || { fail "MSSQL_BACKUP_INIT_SLEEP is ${MSSQL_BACKUP_INIT_SLEEP:-30m}; this test needs a short one (CI uses 15s)"; return 1; }
  if ! { sql "IF DB_ID('$PROBE_DB') IS NULL CREATE DATABASE [$PROBE_DB];" > /dev/null \
         && sql "ALTER DATABASE [$PROBE_DB] SET AUTO_CLOSE OFF;" > /dev/null \
         && sql "SET NOCOUNT ON; IF OBJECT_ID('[$PROBE_DB].dbo.filler') IS NULL BEGIN CREATE TABLE [$PROBE_DB].dbo.filler (c char(8000)); INSERT INTO [$PROBE_DB].dbo.filler SELECT TOP 20000 'x' FROM sys.all_objects a CROSS JOIN sys.all_objects b; END" > /dev/null; }; then
    fail "could not create the probe database"; return 1
  fi
  since="$(date -u +%Y-%m-%dT%H:%M:%SZ)"
  echo "  restarting the backups service; its cycle ends with the probe database"
  docker restart "$BACKUPS_CONTAINER" > /dev/null
  for (( i = 0; i < (init + 180) * 10; i++ )); do
    cmd="$(ps -eo comm=,args= | awk -v db="$PROBE_DB" '$1 == "sqlcmd" && index($0, db) { $1 = ""; sub(/^ /, ""); print; exit }')"
    [[ -n "$cmd" ]] && break
    sleep 0.1
  done
  hits_host=$(ps -eo args= | argv_hits)
  hits_bkp=$(cmdlines_in "$BACKUPS_CONTAINER" | argv_hits)
  for (( i = 0; i < 180; i += 3 )); do
    ok="$(docker logs --since "$since" "$BACKUPS_CONTAINER" 2>&1 | grep -E "Database backup (OK|FAILED).*$PROBE_DB" | head -n 1 || true)"
    [[ -n "$ok" ]] && break
    sleep 3
  done
  sql "IF DB_ID('$PROBE_DB') IS NOT NULL DROP DATABASE [$PROBE_DB];" > /dev/null 2>&1 || true
  backups_sh "rm -f ${BACKUPS_PATH}/${BACKUP_PREFIX}-${PROBE_DB}-*" || true
  [[ -n "$cmd" ]] || { fail "no sqlcmd for $PROBE_DB appeared within $(( init + 180 ))s of the restart"; return 1; }
  echo "  sqlcmd, read while it ran: $(sed -E 's/(^| )-P [^ ]*/\1-P <hidden>/g' <<< "$cmd" | cut -c1-200)"
  [[ "$hits_host" == 0 ]] || { fail "$hits_host command line(s) on the host carried the password ($PW_SUM) during the backup"; return 1; }
  [[ "$hits_bkp" == 0 ]] || { fail "$hits_bkp command line(s) in the backups container carried the password ($PW_SUM) during the backup"; return 1; }
  if grep -qE '(^| )-P( |$)' <<< "$cmd"; then
    fail "sqlcmd was given its password as -P"; return 1
  fi
  [[ "$ok" == *"backup OK"* ]] || { fail "the backup of $PROBE_DB did not finish OK: ${ok:-no result within 180s}"; return 1; }
  echo "  0 command lines on the host and 0 in the backups container carried the password ($PW_SUM); the backup finished OK"
}

test_no_password_on_any_command_line() {
  ps_sampler_stop
  local samples hits
  samples=$(wc -l < "$PS_COUNTS" | tr -d '[:space:]')
  hits=$(awk '$1 > 0 { n++ } END { print n + 0 }' "$PS_COUNTS")
  [[ "$samples" -ge 100 ]] || { fail "only $samples samples of the host's command lines were taken"; return 1; }
  [[ "$hits" == 0 ]] || { fail "$hits of $samples samples of the host's command lines carried the password ($PW_SUM)"; return 1; }
  echo "  $samples samples of every command line on the host during this suite, none with the password ($PW_SUM)"
}

# --- Main ---

echo "=== SQL Server: backup/restore E2E tests ==="
echo "  project=${COMPOSE_PROJECT_NAME} backups=${BACKUPS_CONTAINER} db=${DB_CONTAINER}"
echo "  path=${BACKUPS_PATH} prefix=${BACKUP_PREFIX} interval=${INTERVAL}"

wait_for_db_ready 180 || { echo "error: SQL Server not ready" >&2; exit 1; }
# A database of our own with known content; the loop backs up every user
# database, so this one is in from the next cycle on.
sql "IF DB_ID('$TEST_DB') IS NULL CREATE DATABASE [$TEST_DB];" > /dev/null
# Express creates user databases with AUTO_CLOSE ON; a closed database cannot
# autostart while the server is still starting (Msg 904), which turns the
# restart in the failure-detection scenario into a race. Keep it open.
sql "ALTER DATABASE [$TEST_DB] SET AUTO_CLOSE OFF;" > /dev/null
sql "IF OBJECT_ID('[$TEST_DB].dbo.e2e_marker') IS NULL CREATE TABLE [$TEST_DB].dbo.e2e_marker (id int PRIMARY KEY);" > /dev/null
backups_sh "touch ${BACKUPS_PATH}/.e2e-marker-stamp"

ps_sampler_start
run_test test_env_required
run_test test_backup_created
run_test test_backup_verifyonly
run_test test_backup_failure_detected
run_test test_restore_roundtrip
run_test test_prune_removes_old
run_test test_backup_runs_without_password_in_argv
run_test test_no_password_on_any_command_line

echo
echo "==============================="
echo "Passed: $PASSED  Failed: $FAILED"
if [[ ${#FAILURES[@]} -gt 0 ]]; then
  echo "Failures:"
  for f in "${FAILURES[@]}"; do echo "  - $f"; done
fi
[[ $FAILED -eq 0 ]]
