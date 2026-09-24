#!/usr/bin/env bash
# AG Phase 6 (run on the PRIMARY node only): download + restore the WideWorldImporters sample
# database, put it in FULL recovery model, take the required full backup, then add it to the
# AG. Automatic seeding replicates the full database across regions to the secondary - no manual
# backup/copy/restore needed on the secondary. This can take a few minutes over the
# cross-region link depending on WAN bandwidth; monitor with the query in the README.
#
# Usage: sudo ./ag-06-restore-wideworldimporters.sh '<SA_PASSWORD>' '<AG_NAME>'
set -euo pipefail

SA_PASSWORD="${1:?SA password required}"
AG_NAME="${2:?AG name required}"
SQLCMD=(/opt/mssql-tools18/bin/sqlcmd -S localhost -U SA -P "$SA_PASSWORD" -No -C -b)
DB_NAME="WideWorldImporters"

EXISTS=$("${SQLCMD[@]}" -h -1 -Q "SET NOCOUNT ON; SELECT COUNT(*) FROM sys.databases WHERE name = N'$DB_NAME'" | tr -d '[:space:]')

if [ "$EXISTS" = "1" ]; then
  echo "$DB_NAME already exists, skipping download/restore."
else
  echo "--- Downloading WideWorldImporters-Full.bak ---"
  mkdir -p /var/opt/mssql/backup
  chown mssql:mssql /var/opt/mssql/backup
  wget -q \
    "https://github.com/Microsoft/sql-server-samples/releases/download/wide-world-importers-v1.0/WideWorldImporters-Full.bak" \
    -O /var/opt/mssql/backup/WideWorldImporters-Full.bak

  mkdir -p /var/opt/mssql/data/WideWorldImporters_InMemory
  chown mssql:mssql /var/opt/mssql/data/WideWorldImporters_InMemory

  echo "--- Restoring $DB_NAME ---"
  "${SQLCMD[@]}" -Q "
  RESTORE DATABASE [$DB_NAME]
  FROM DISK = N'/var/opt/mssql/backup/WideWorldImporters-Full.bak'
  WITH
    MOVE N'WWI_Primary'         TO N'/var/opt/mssql/data/WideWorldImporters.mdf',
    MOVE N'WWI_UserData'        TO N'/var/opt/mssql/data/WideWorldImporters_UserData.ndf',
    MOVE N'WWI_Log'             TO N'/var/opt/mssql/data/WideWorldImporters_log.ldf',
    MOVE N'WWI_InMemory_Data_1' TO N'/var/opt/mssql/data/WideWorldImporters_InMemory',
    REPLACE, STATS = 10;
  "
fi

echo "--- Preparing $DB_NAME for Always On (full recovery model + full backup) ---"
"${SQLCMD[@]}" -Q "ALTER DATABASE [$DB_NAME] SET RECOVERY FULL;"

echo "--- Taking required full backup for $DB_NAME ---"
for attempt in $(seq 1 12); do
  if "${SQLCMD[@]}" -Q "CHECKPOINT; BACKUP DATABASE [$DB_NAME] TO DISK = N'/var/opt/mssql/data/${DB_NAME}.bak' WITH INIT;" ; then
    break
  fi

  if [ "$attempt" -eq 12 ]; then
    echo "Backup of $DB_NAME failed after $attempt attempts." >&2
    exit 1
  fi

  echo "Backup attempt $attempt failed; waiting for memory-optimized filegroup recovery/upgrade to settle..."
  sleep 10
done

echo "--- Adding $DB_NAME to availability group $AG_NAME (automatic seeding to secondary) ---"
"${SQLCMD[@]}" -Q "
IF NOT EXISTS (
  SELECT 1 FROM sys.dm_hadr_database_replica_states rs
  JOIN sys.databases d ON d.database_id = rs.database_id
  WHERE d.name = N'$DB_NAME'
)
  ALTER AVAILABILITY GROUP [$AG_NAME] ADD DATABASE [$DB_NAME];
"

echo "=== Phase 6 complete. $DB_NAME added to AG '$AG_NAME'; seeding to secondary continues in the background. ==="
