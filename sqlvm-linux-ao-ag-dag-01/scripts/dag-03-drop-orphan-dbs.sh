#!/usr/bin/env bash
# DAG Phase 3 (run on the FORWARDER AG's nodes, after dag-02): databases removed from the AG on the
# primary are left behind on the secondary in RESTORING state, and a same-named database would block
# automatic seeding from the global primary. Drops each named database ONLY when it is RESTORING and
# no longer part of any AG. An ONLINE database is never dropped - it's reported as KEPT_DB.
# The AG removal reaches the secondary asynchronously, so each database is retried for ~60 s.
#
# Usage: sudo ./dag-03-drop-orphan-dbs.sh '<SA_PASSWORD>' '<DB1,DB2,...>'
set -euo pipefail

SA_PASSWORD="${1:?}"
DB_LIST="${2:-}"
SQLCMD=(/opt/mssql-tools18/bin/sqlcmd -S localhost -U SA -P "$SA_PASSWORD" -No -C -b -W -h -1)

IFS=',' read -r -a DBS <<< "$DB_LIST"
for DB in "${DBS[@]}"; do
  [ -z "$DB" ] && continue
  RESULT=""
  for attempt in $(seq 1 12); do
    RESULT=$("${SQLCMD[@]}" -Q "
SET NOCOUNT ON;
IF DB_ID(N'$DB') IS NULL
    SELECT 'ABSENT_DB=$DB';
ELSE IF CAST(DATABASEPROPERTYEX(N'$DB', 'Status') AS varchar(30)) = 'RESTORING'
     AND NOT EXISTS (SELECT 1 FROM sys.availability_databases_cluster WHERE database_name = N'$DB')
BEGIN
    IF EXISTS (SELECT 1 FROM sys.dm_hadr_database_replica_states WHERE database_id = DB_ID(N'$DB') AND is_local = 1)
        ALTER DATABASE [$DB] SET HADR OFF;
    DROP DATABASE [$DB];
    SELECT 'DROPPED_DB=$DB';
END
ELSE
    SELECT 'KEPT_DB=$DB|' + CAST(DATABASEPROPERTYEX(N'$DB', 'Status') AS varchar(30))
         + CASE WHEN EXISTS (SELECT 1 FROM sys.availability_databases_cluster WHERE database_name = N'$DB') THEN '|in-ag' ELSE '' END;" | tr -d '\r')
    # Retry only while the database is still RESTORING and listed in an AG (removal not propagated yet).
    case "$RESULT" in
      KEPT_DB=*"|RESTORING|in-ag"*) sleep 5 ;;
      *) break ;;
    esac
  done
  echo "$RESULT"
done
