-- shared | any node | Compact AG status of THIS instance (one line per fact, run-command output is capped at 4 KB).
-- sqlcmd -v AgName="agsqlvm-node-1" -i 00-status.sql
SET NOCOUNT ON;
SELECT 'HOST=' + @@SERVERNAME;
SELECT 'AG_EXISTS=' + CASE WHEN EXISTS (SELECT 1 FROM sys.availability_groups WHERE name = N'$(AgName)') THEN '1' ELSE '0' END;
SELECT 'LOCAL_ROLE=' + ISNULL((
    SELECT rs.role_desc COLLATE DATABASE_DEFAULT
    FROM sys.dm_hadr_availability_replica_states rs
    JOIN sys.availability_groups ag ON ag.group_id = rs.group_id
    WHERE ag.name = N'$(AgName)' AND rs.is_local = 1), 'NONE');
SELECT 'REPLICA=' + ar.replica_server_name
     + '|' + ar.availability_mode_desc COLLATE DATABASE_DEFAULT
     + '|' + ISNULL(rs.role_desc COLLATE DATABASE_DEFAULT, '?')
     + '|' + ISNULL(rs.connected_state_desc COLLATE DATABASE_DEFAULT, '?')
     + '|' + ISNULL(rs.synchronization_health_desc COLLATE DATABASE_DEFAULT, '?')
FROM sys.availability_replicas ar
JOIN sys.availability_groups ag ON ag.group_id = ar.group_id
LEFT JOIN sys.dm_hadr_availability_replica_states rs ON rs.replica_id = ar.replica_id
WHERE ag.name = N'$(AgName)'
ORDER BY ar.replica_server_name;
-- Every distributed AG defined on this node (uc-01 checks that all of them were declared).
SELECT 'DISTRIBUTED_AG=' + name FROM sys.availability_groups WHERE is_distributed = 1;
SELECT 'DB=' + d.name
     + '|' + d.state_desc COLLATE DATABASE_DEFAULT
     + '|' + ISNULL(drs.synchronization_state_desc COLLATE DATABASE_DEFAULT, 'NOT_IN_AG')
     + '|suspended=' + ISNULL(CAST(drs.is_suspended AS varchar(1)), '-')
FROM sys.databases d
LEFT JOIN sys.dm_hadr_database_replica_states drs ON drs.database_id = d.database_id AND drs.is_local = 1
WHERE d.database_id > 4
ORDER BY d.name;
