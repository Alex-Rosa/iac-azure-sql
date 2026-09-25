#!/usr/bin/env bash
# DAG status (run on ANY node): compact KEY=VALUE lines - local AG roles, distributed AG members
# (LISTENER_URL, role, connection, health) and database sync state. Output stays small because
# az vm run-command returns at most ~4 KB.
#
# Usage: sudo ./dag-06-status.sh '<SA_PASSWORD>' '<DAG_NAME>'
set -euo pipefail

SA_PASSWORD="${1:?}"
DAG_NAME="${2:?}"

# DMV columns (Latin1_General_CI_AS_KS_WS) and catalog columns (server collation) can't be
# concatenated without an explicit COLLATE.
/opt/mssql-tools18/bin/sqlcmd -S localhost -U SA -P "$SA_PASSWORD" -No -C -b -W -h -1 -Q "
SET NOCOUNT ON;
SELECT 'HOST=' + @@SERVERNAME;
SELECT 'LOCAL_AG=' + ag.name + '|' + ISNULL(rs.role_desc COLLATE DATABASE_DEFAULT, 'UNKNOWN')
FROM sys.availability_groups ag
LEFT JOIN sys.dm_hadr_availability_replica_states rs ON rs.group_id = ag.group_id AND rs.is_local = 1
WHERE ag.is_distributed = 0;
SELECT 'DAG_EXISTS=' + CASE WHEN EXISTS (SELECT 1 FROM sys.availability_groups WHERE name = N'$DAG_NAME' AND is_distributed = 1) THEN '1' ELSE '0' END;
SELECT 'DAG_MEMBER=' + ar.replica_server_name + '|' + ar.endpoint_url + '|' + ar.availability_mode_desc COLLATE DATABASE_DEFAULT
     + '|' + ISNULL(rs.role_desc COLLATE DATABASE_DEFAULT, '-') + '|' + ISNULL(rs.connected_state_desc COLLATE DATABASE_DEFAULT, '-')
     + '|' + ISNULL(rs.synchronization_health_desc COLLATE DATABASE_DEFAULT, '-')
FROM sys.availability_replicas ar
JOIN sys.availability_groups ag ON ag.group_id = ar.group_id
LEFT JOIN sys.dm_hadr_availability_replica_states rs ON rs.replica_id = ar.replica_id
WHERE ag.name = N'$DAG_NAME';
-- sys.availability_databases_cluster has no rows for a distributed AG: name via DB_NAME().
SELECT 'DAG_DB=' + ar.replica_server_name + '|' + ISNULL(DB_NAME(drs.database_id), CAST(drs.group_database_id AS varchar(36))) COLLATE DATABASE_DEFAULT + '|' + drs.synchronization_state_desc COLLATE DATABASE_DEFAULT
FROM sys.dm_hadr_database_replica_states drs
JOIN sys.availability_replicas ar ON ar.replica_id = drs.replica_id
JOIN sys.availability_groups ag ON ag.group_id = drs.group_id
WHERE ag.name = N'$DAG_NAME';
SELECT 'LOCAL_DB=' + d.name + '|' + d.state_desc COLLATE DATABASE_DEFAULT + '|' + ISNULL(drs.synchronization_state_desc COLLATE DATABASE_DEFAULT, 'NOT_IN_AG')
FROM sys.databases d
LEFT JOIN sys.dm_hadr_database_replica_states drs ON drs.database_id = d.database_id AND drs.is_local = 1
    AND drs.group_id IN (SELECT group_id FROM sys.availability_groups WHERE is_distributed = 0)
WHERE d.database_id > 4;"
