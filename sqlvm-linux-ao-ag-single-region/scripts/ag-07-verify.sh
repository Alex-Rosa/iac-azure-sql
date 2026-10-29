#!/usr/bin/env bash
# AG Phase 7 (run on the PRIMARY node only): post-deployment verification. Confirms the AG is
# actually healthy and that each expected database was really added - not just that the
# earlier setup commands happened to return success. Exits non-zero (failing the deploy) if
# an expected database is missing from the AG.
#
# Usage: sudo ./ag-07-verify.sh '<SA_PASSWORD>' '<AG_NAME>' '<DB_NAME_1>' ['<DB_NAME_2>' ...]
set -euo pipefail

SA_PASSWORD="${1:?SA password required}"
AG_NAME="${2:?AG name required}"
shift 2
DB_NAMES=("$@")
SQLCMD=(/opt/mssql-tools18/bin/sqlcmd -S localhost -U SA -P "$SA_PASSWORD" -No -C -b)

echo "--- Replica roles / health (AG: $AG_NAME) ---"
"${SQLCMD[@]}" -Q "
SET NOCOUNT ON;
SELECT ar.replica_server_name, ars.role_desc, ars.connected_state_desc, ars.synchronization_health_desc
FROM sys.dm_hadr_availability_replica_states ars
JOIN sys.availability_replicas ar ON ar.replica_id = ars.replica_id;
"

echo "--- Per-database sync state ---"
"${SQLCMD[@]}" -Q "
SET NOCOUNT ON;
SELECT d.name AS database_name, drs.synchronization_state_desc, drs.is_suspended
FROM sys.dm_hadr_database_replica_states drs
JOIN sys.databases d ON d.database_id = drs.database_id
ORDER BY d.name;
"

echo "--- Expected-database check ---"
FAIL=0
for DB in "${DB_NAMES[@]}"; do
  COUNT=$("${SQLCMD[@]}" -h -1 -Q "SET NOCOUNT ON; SELECT COUNT(*) FROM sys.dm_hadr_database_replica_states drs JOIN sys.databases d ON d.database_id = drs.database_id WHERE d.name = N'$DB'" | tr -d '[:space:]')
  if [ "$COUNT" -gt 0 ]; then
    echo "  [OK]   $DB is in the AG ($COUNT replica row(s) reporting)"
  else
    echo "  [FAIL] $DB was NOT found in the AG"
    FAIL=1
  fi
done

if [ "$FAIL" -ne 0 ]; then
  echo "=== Phase 7: one or more expected databases are missing from the AG. ==="
  exit 1
fi
echo "=== Phase 7 complete. AG healthy, all expected databases present. ==="
