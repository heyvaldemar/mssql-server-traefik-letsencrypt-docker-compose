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
  docker exec "$BACKUPS_CONTAINER" sh -c '/opt/mssql-tools18/bin/sqlcmd -S mssql -U sa -P "$MSSQL_SA_PASSWORD" -C -b -h -1 -W -Q "$1" | tr -d "\r"' _ "$1"
}

db_ready() {
  docker exec "$BACKUPS_CONTAINER" sh -c '/opt/mssql-tools18/bin/sqlcmd -S mssql -U sa -P "$MSSQL_SA_PASSWORD" -C -b -Q "SELECT 1"' > /dev/null 2>&1
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
  sql "ALTER DATABASE [$TEST_DB] SET SINGLE_USER WITH ROLLBACK IMMEDIATE; RESTORE DATABASE [$TEST_DB] FROM DISK = N'$baseline' WITH REPLACE, RECOVERY; ALTER DATABASE [$TEST_DB] SET MULTI_USER;" > /dev/null || { fail "restore commands failed"; return 1; }
  local exists
  exists=$(sql "SET NOCOUNT ON; SELECT count(*) FROM [$TEST_DB].sys.tables WHERE name = 'restore_test';" | tr -d '[:space:]')
  [[ "$exists" == "0" ]] || { fail "restore_test still present after restore - restore was a no-op"; return 1; }
  echo "  marker absent after restore - the backup is restorable"
}

test_prune_removes_old() {
  local fake_old="${BACKUPS_PATH}/${BACKUP_PREFIX}-${TEST_DB}-0000-00-00_00-00.bak"
  echo "  placing a fake file dated 2020 at $fake_old"
  backups_sh "echo fake > $fake_old && touch -t 202001010000 $fake_old" || { fail "could not create the fake file"; return 1; }
  echo "  waiting ${CYCLE_WAIT}s for the next prune cycle..."
  sleep "$CYCLE_WAIT"
  if backups_sh "ls $fake_old 2>/dev/null" > /dev/null 2>&1; then fail "fake old file survived the prune cycle"; return 1; fi
  [[ -n "$(list_backups)" ]] || { fail "prune removed everything, including recent backups"; return 1; }
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

run_test test_env_required
run_test test_backup_created
run_test test_backup_verifyonly
run_test test_backup_failure_detected
run_test test_restore_roundtrip
run_test test_prune_removes_old

echo
echo "==============================="
echo "Passed: $PASSED  Failed: $FAILED"
if [[ ${#FAILURES[@]} -gt 0 ]]; then
  echo "Failures:"
  for f in "${FAILURES[@]}"; do echo "  - $f"; done
fi
[[ $FAILED -eq 0 ]]
