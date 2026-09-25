-- UC-01 | CURRENT primary | Per-database state of one secondary replica, seen from the primary
-- (seeding progress after a rejoin, or SYNCHRONIZED check before a planned failback).
-- sqlcmd -v AgName="agsqlvm-node-1" ReplicaName="sqlvm-257672-node-1" -i 24-replica-sync-state.sql
SET NOCOUNT ON;
SELECT 'EXPECTED_DBS=' + CAST(COUNT(*) AS varchar(10))
FROM sys.availability_databases_cluster adc
JOIN sys.availability_groups ag ON ag.group_id = adc.group_id
WHERE ag.name = N'$(AgName)';
SELECT 'SYNC=' + ISNULL(d.name, adc.database_name COLLATE DATABASE_DEFAULT) + '|' + drs.synchronization_state_desc COLLATE DATABASE_DEFAULT
     + '|suspended=' + CAST(drs.is_suspended AS varchar(1))
FROM sys.dm_hadr_database_replica_states drs
JOIN sys.availability_replicas ar ON ar.replica_id = drs.replica_id
JOIN sys.availability_groups ag ON ag.group_id = ar.group_id
JOIN sys.availability_databases_cluster adc ON adc.group_database_id = drs.group_database_id
LEFT JOIN sys.databases d ON d.database_id = drs.database_id AND drs.is_local = 1
WHERE ag.name = N'$(AgName)' AND ar.replica_server_name = N'$(ReplicaName)';
SELECT 'SEEDING=' + CAST(local_database_name AS varchar(128)) + '|' + CAST(internal_state_desc COLLATE DATABASE_DEFAULT AS varchar(60))
     + '|' + CAST(ISNULL(transferred_size_bytes * 100 / NULLIF(database_size_bytes, 0), 0) AS varchar(10)) + '%'
FROM sys.dm_hadr_physical_seeding_stats
WHERE remote_machine_name LIKE '%' + (SELECT TOP (1) REPLACE(REPLACE(endpoint_url, 'tcp://', ''), ':5022', '')
                                       FROM sys.availability_replicas WHERE replica_server_name = N'$(ReplicaName)') + '%';
