#!/bin/bash

# # mssql-restore-database.sh Description
# This script facilitates the restoration of a database backup.
# 1. **List Backups**: Displays all available .bak files in the shared backup volume.
# 2. **Select Backup**: Prompts the user to copy and paste the desired backup name from the list.
# 3. **Restore Database**: Puts the database into single-user mode (dropping other connections), runs
#    RESTORE DATABASE ... WITH REPLACE, then returns it to multi-user mode. The database name is taken
#    from the file name (<prefix>-<database>-<timestamp>.bak).
# System databases (master, msdb) cannot be restored this way: master needs the server in single-user
# mode - see https://learn.microsoft.com/sql/relational-databases/backup-restore/restore-the-master-database-transact-sql
# To make the `mssql-restore-database.sh` script executable, run the following command:
# `chmod +x mssql-restore-database.sh`

MSSQL_BACKUPS_CONTAINER="$(docker ps -aqf "name=mssql-backups")"
BACKUP_PATH="/var/opt/mssql/backup/"
BACKUP_NAME="mssql-backup"

sql() {
  docker exec "$MSSQL_BACKUPS_CONTAINER" sh -c '/opt/mssql-tools18/bin/sqlcmd -S mssql -U sa -P "$MSSQL_SA_PASSWORD" -C -b -Q "$1"' _ "$1"
}

echo "--> All available database backups:"

for entry in $(docker container exec "$MSSQL_BACKUPS_CONTAINER" sh -c "ls $BACKUP_PATH")
do
  echo "$entry"
done

echo "--> Copy and paste the backup name from the list above to restore database and press [ENTER]
--> Example: ${BACKUP_NAME}-mydatabase-YYYY-MM-DD_hh-mm.bak"
echo -n "--> "

read -r SELECTED_DATABASE_BACKUP

echo "--> $SELECTED_DATABASE_BACKUP was selected"

DB_NAME="${SELECTED_DATABASE_BACKUP#"${BACKUP_NAME}"-}"
DB_NAME="${DB_NAME%-[0-9][0-9][0-9][0-9]-[0-9][0-9]-[0-9][0-9]_[0-9][0-9]-[0-9][0-9].bak}"
if [ -z "$DB_NAME" ] || [ "$DB_NAME" = "$SELECTED_DATABASE_BACKUP" ]; then
  echo "--> Could not derive the database name from the file name; expected ${BACKUP_NAME}-<database>-<timestamp>.bak" >&2
  exit 1
fi
case "$DB_NAME" in
  master|msdb|model|tempdb)
    echo "--> $DB_NAME is a system database; restore it by hand following Microsoft's procedure" >&2
    exit 1 ;;
esac

echo "--> Restoring database [$DB_NAME] (other connections are dropped)..."
if sql "IF DB_ID(N'$DB_NAME') IS NOT NULL ALTER DATABASE [$DB_NAME] SET SINGLE_USER WITH ROLLBACK IMMEDIATE;" \
   && sql "RESTORE DATABASE [$DB_NAME] FROM DISK = N'${BACKUP_PATH}${SELECTED_DATABASE_BACKUP}' WITH REPLACE, RECOVERY;" \
   && sql "ALTER DATABASE [$DB_NAME] SET MULTI_USER;"; then
  echo "--> Database recovery completed..."
else
  echo "--> Restore FAILED - the database may be left in single-user mode; run: ALTER DATABASE [$DB_NAME] SET MULTI_USER" >&2
  exit 1
fi
