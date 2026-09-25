-- UC-01 | any node | Distributed AG health as seen from THIS instance: member AGs (LISTENER_URL,
-- role, connection, health) and per-database synchronization.
-- sqlcmd -v DagName="dagsqlvm-node-1-node-3" -i 14-dag-status.sql
SET NOCOUNT ON;
SELECT 'DAG_EXISTS=' + CASE WHEN EXISTS (SELECT 1 FROM sys.availability_groups WHERE name = N'$(DagName)' AND is_distributed = 1) THEN '1' ELSE '0' END;
SELECT 'DAG_MEMBER=' + ar.replica_server_name + '|' + ar.endpoint_url
     + '|' + ISNULL(rs.role_desc COLLATE DATABASE_DEFAULT, '-')
     + '|' + ISNULL(rs.connected_state_desc COLLATE DATABASE_DEFAULT, '-')
     + '|' + ISNULL(rs.synchronization_health_desc COLLATE DATABASE_DEFAULT, '-')
FROM sys.availability_replicas ar
JOIN sys.availability_groups ag ON ag.group_id = ar.group_id
LEFT JOIN sys.dm_hadr_availability_replica_states rs ON rs.replica_id = ar.replica_id
WHERE ag.name = N'$(DagName)';
-- sys.availability_databases_cluster has no rows for a distributed AG: name via DB_NAME().
SELECT 'DAG_DB=' + ar.replica_server_name + '|' + ISNULL(DB_NAME(drs.database_id), CAST(drs.group_database_id AS varchar(36))) COLLATE DATABASE_DEFAULT
     + '|' + drs.synchronization_state_desc COLLATE DATABASE_DEFAULT
     + '|suspended=' + CAST(drs.is_suspended AS varchar(1))
FROM sys.dm_hadr_database_replica_states drs
JOIN sys.availability_replicas ar ON ar.replica_id = drs.replica_id
JOIN sys.availability_groups ag ON ag.group_id = drs.group_id
WHERE ag.name = N'$(DagName)';
