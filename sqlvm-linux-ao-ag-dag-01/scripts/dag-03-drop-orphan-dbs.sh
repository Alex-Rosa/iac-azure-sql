#!/usr/bin/env bash
# DAG Phase 3 (run on the FORWARDER AG's nodes, after dag-02): databases removed from the AG on the
# primary are left behind on the secondary, and a same-named database would block automatic
# seeding from the global primary.
#
# The removal reaches a secondary asynchronously: for a few seconds the database still has its
# local AG state row and - on a readable secondary - still shows ONLINE, before it turns RESTORING.
# So each database is re-checked (~60 s) while that local AG state row exists:
#   - still listed in an AG                  -> wait (removal not propagated yet)
#   - AG state row, no longer in any AG      -> wait; on the last attempt SET HADR OFF + drop
#   - no AG state row and RESTORING          -> drop (leftover copy)
#   - no AG state row and ONLINE             -> KEPT_DB: a real database, never dropped here
#
# Usage: sudo ./dag-03-drop-orphan-dbs.sh '<SA_PASSWORD>' '<DB1,DB2,...>'
set -euo pipefail

SA_PASSWORD="${1:?}"
DB_LIST="${2:-}"
SQLCMD=(/opt/mssql-tools18/bin/sqlcmd -S localhost -U SA -P "$SA_PASSWORD" -No -C -b -W -h -1)
ATTEMPTS=12

IFS=',' read -r -a DBS <<< "$DB_LIST"
for DB in "${DBS[@]}"; do
  [ -z "$DB" ] && continue
  RESULT=""
  for attempt in $(seq 1 $ATTEMPTS); do
    FINAL=0; [ "$attempt" -eq "$ATTEMPTS" ] && FINAL=1
    RESULT=$("${SQLCMD[@]}" -Q "
SET NOCOUNT ON;
DECLARE @state varchar(30) = CAST(DATABASEPROPERTYEX(N'$DB', 'Status') AS varchar(30));
DECLARE @hasAgRow bit = CASE WHEN EXISTS (SELECT 1 FROM sys.dm_hadr_database_replica_states
                                          WHERE database_id = DB_ID(N'$DB') AND is_local = 1) THEN 1 ELSE 0 END;
DECLARE @inAg bit = CASE WHEN EXISTS (SELECT 1 FROM sys.availability_databases_cluster
                                      WHERE database_name = N'$DB') THEN 1 ELSE 0 END;
IF DB_ID(N'$DB') IS NULL
    SELECT 'ABSENT_DB=$DB';
ELSE IF @hasAgRow = 1 AND @inAg = 1
    SELECT 'WAIT_DB=$DB|' + @state + '|in-ag';
ELSE IF @hasAgRow = 1 AND $FINAL = 0
    SELECT 'WAIT_DB=$DB|' + @state + '|leaving-ag';
ELSE IF @hasAgRow = 1 OR @state = 'RESTORING'
BEGIN
    IF @hasAgRow = 1 ALTER DATABASE [$DB] SET HADR OFF;
    DROP DATABASE [$DB];
    SELECT 'DROPPED_DB=$DB';
END
ELSE
    SELECT 'KEPT_DB=$DB|' + @state;" | tr -d '\r')
    case "$RESULT" in
      WAIT_DB=*) sleep 5 ;;
      *) break ;;
    esac
  done
  echo "$RESULT"
done
