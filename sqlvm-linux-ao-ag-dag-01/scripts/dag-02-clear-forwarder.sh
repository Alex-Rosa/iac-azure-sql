#!/usr/bin/env bash
# DAG Phase 2 (run on the FORWARDER AG's PRIMARY replica, once, before the distributed AG is
# created): the forwarder AG must not contain databases - they're seeded from the global primary.
# Takes a COPY_ONLY backup of each database (unless SKIP_BACKUP=1), removes it from the local AG
# and drops it. Does nothing if this node already belongs to the distributed AG.
#
# Usage: sudo ./dag-02-clear-forwarder.sh '<SA_PASSWORD>' '<FORWARDER_AG>' '<DAG_NAME>' '<SKIP_BACKUP 0|1>'
set -euo pipefail

SA_PASSWORD="${1:?}"
AG_NAME="${2:?}"
DAG_NAME="${3:?}"
SKIP_BACKUP="${4:-0}"
SQLCMD=(/opt/mssql-tools18/bin/sqlcmd -S localhost -U SA -P "$SA_PASSWORD" -No -C -b -W -h -1)
BACKUP_DIR=/var/opt/mssql/backup

IN_DAG=$("${SQLCMD[@]}" -Q "SET NOCOUNT ON; SELECT COUNT(*) FROM sys.availability_groups WHERE name = N'$DAG_NAME' AND is_distributed = 1" | tr -d '[:space:]')
if [ "$IN_DAG" != "0" ]; then
  echo "FORWARDER_CLEARED=0 (already a member of $DAG_NAME)"
  exit 0
fi

ROLE=$("${SQLCMD[@]}" -Q "SET NOCOUNT ON; SELECT rs.role_desc FROM sys.dm_hadr_availability_replica_states rs JOIN sys.availability_groups ag ON ag.group_id = rs.group_id WHERE ag.name = N'$AG_NAME' AND rs.is_local = 1" | tr -d '[:space:]')
if [ "$ROLE" != "PRIMARY" ]; then
  echo "This node is '$ROLE' in $AG_NAME - run on the forwarder AG's PRIMARY replica." >&2
  exit 1
fi

mkdir -p "$BACKUP_DIR" && chown mssql:mssql "$BACKUP_DIR"
DBS=$("${SQLCMD[@]}" -Q "SET NOCOUNT ON; SELECT adc.database_name FROM sys.availability_databases_cluster adc JOIN sys.availability_groups ag ON ag.group_id = adc.group_id WHERE ag.name = N'$AG_NAME'")
for DB in $DBS; do
  if [ "$SKIP_BACKUP" != "1" ]; then
    "${SQLCMD[@]}" -Q "BACKUP DATABASE [$DB] TO DISK = N'$BACKUP_DIR/pre-dag-$DB.bak' WITH COPY_ONLY, COMPRESSION, INIT;" >/dev/null
    echo "BACKED_UP=$DB|$BACKUP_DIR/pre-dag-$DB.bak"
  fi
  "${SQLCMD[@]}" -Q "ALTER AVAILABILITY GROUP [$AG_NAME] REMOVE DATABASE [$DB];"
  "${SQLCMD[@]}" -Q "ALTER DATABASE [$DB] SET SINGLE_USER WITH ROLLBACK IMMEDIATE; DROP DATABASE [$DB];"
  echo "REMOVED_DB=$DB"
done
echo "FORWARDER_CLEARED=1"
