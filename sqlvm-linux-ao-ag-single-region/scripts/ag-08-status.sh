#!/usr/bin/env bash
# AG status of THIS node, as compact KEY=VALUE lines (run through 'az vm run-command', whose output
# is capped at about 4 KB). Never fails on SQL errors: a node whose SQL Server is down reports SQL_UP=0.
#
#   HOST=<@@SERVERNAME>                  SQL_UP=1|0
#   AG_EXISTS=1|0                        LOCAL_ROLE=PRIMARY|SECONDARY|RESOLVING|NONE
#   REQUIRED_SYNC=<n>                    (REQUIRED_SYNCHRONIZED_SECONDARIES_TO_COMMIT)
#   REPLICA=<name>|<mode>|<role>|<connected>|<health>      (full detail on the primary only)
#   DB=<name>|<state>|<sync state or NOT_IN_AG>|suspended=<0|1|->   (local copies)
#   DB_REPLICA=<db>|<replica>|<sync state>|suspended=<0|1>          (primary only: every replica)
#
# Usage: sudo ./ag-08-status.sh '<SA_PASSWORD>' '<AG_NAME>'
set -uo pipefail

SA_PASSWORD="${1:?SA password required}"
AG_NAME="${2:?AG name required}"
SQLCMD=(/opt/mssql-tools18/bin/sqlcmd -S localhost -U SA -P "$SA_PASSWORD" -No -C -b -W -h -1 -l 10)

if ! "${SQLCMD[@]}" -Q "SET NOCOUNT ON; SELECT 1" >/dev/null 2>&1; then
  echo "HOST=$(hostname)"
  echo "SQL_UP=0"
  exit 0
fi
echo "SQL_UP=1"

"${SQLCMD[@]}" -Q "
SET NOCOUNT ON;
SELECT 'HOST=' + @@SERVERNAME;
SELECT 'AG_EXISTS=' + CASE WHEN EXISTS (SELECT 1 FROM sys.availability_groups WHERE name = N'$AG_NAME') THEN '1' ELSE '0' END;
SELECT 'LOCAL_ROLE=' + ISNULL((
    SELECT rs.role_desc COLLATE DATABASE_DEFAULT
    FROM sys.dm_hadr_availability_replica_states rs
    JOIN sys.availability_groups ag ON ag.group_id = rs.group_id
    WHERE ag.name = N'$AG_NAME' AND rs.is_local = 1), 'NONE');
SELECT 'REQUIRED_SYNC=' + CAST(required_synchronized_secondaries_to_commit AS varchar(4))
FROM sys.availability_groups WHERE name = N'$AG_NAME';
SELECT 'REPLICA=' + ar.replica_server_name
     + '|' + ar.availability_mode_desc COLLATE DATABASE_DEFAULT
     + '|' + ISNULL(rs.role_desc COLLATE DATABASE_DEFAULT, '?')
     + '|' + ISNULL(rs.connected_state_desc COLLATE DATABASE_DEFAULT, '?')
     + '|' + ISNULL(rs.synchronization_health_desc COLLATE DATABASE_DEFAULT, '?')
FROM sys.availability_replicas ar
JOIN sys.availability_groups ag ON ag.group_id = ar.group_id
LEFT JOIN sys.dm_hadr_availability_replica_states rs ON rs.replica_id = ar.replica_id
WHERE ag.name = N'$AG_NAME'
ORDER BY ar.replica_server_name;
SELECT 'DB=' + d.name
     + '|' + d.state_desc COLLATE DATABASE_DEFAULT
     + '|' + ISNULL(drs.synchronization_state_desc COLLATE DATABASE_DEFAULT, 'NOT_IN_AG')
     + '|suspended=' + ISNULL(CAST(drs.is_suspended AS varchar(1)), '-')
FROM sys.databases d
LEFT JOIN sys.dm_hadr_database_replica_states drs ON drs.database_id = d.database_id AND drs.is_local = 1
WHERE d.database_id > 4
ORDER BY d.name;
SELECT 'DB_REPLICA=' + DB_NAME(drs.database_id)
     + '|' + ar.replica_server_name
     + '|' + drs.synchronization_state_desc COLLATE DATABASE_DEFAULT
     + '|suspended=' + CAST(drs.is_suspended AS varchar(1))
FROM sys.dm_hadr_database_replica_states drs
JOIN sys.availability_replicas ar ON ar.replica_id = drs.replica_id
JOIN sys.availability_groups ag ON ag.group_id = drs.group_id
WHERE ag.name = N'$AG_NAME' AND drs.is_primary_replica = 0
  AND EXISTS (SELECT 1 FROM sys.dm_hadr_availability_replica_states rs
              WHERE rs.group_id = ag.group_id AND rs.is_local = 1 AND rs.role_desc = 'PRIMARY')
ORDER BY 1;
" 2>&1 | grep -E '^[A-Z_]+=' || true
