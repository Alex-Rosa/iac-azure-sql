-- UC-01 | DR replica (node-2), BEFORE forcing failover | What the DR replica knows right now:
-- is the primary still connected, and how far has replication gotten (last hardened/committed data).
-- sqlcmd -v AgName="agsqlvm-node-1" DbName="AGDemoDB" RunId="20260924-150000" -i 10-dr-snapshot.sql
SET NOCOUNT ON;
SELECT 'LOCAL_ROLE=' + ISNULL((
    SELECT rs.role_desc COLLATE DATABASE_DEFAULT FROM sys.dm_hadr_availability_replica_states rs
    JOIN sys.availability_groups ag ON ag.group_id = rs.group_id
    WHERE ag.name = N'$(AgName)' AND rs.is_local = 1), 'NONE');
-- Is this secondary still connected to the primary? A secondary has NO state row for the other
-- replicas (they'd show as NULL/UNKNOWN even when healthy); its OWN row's connected_state_desc is
-- what reports the connection to the primary. DISCONNECTED = primary lost.
SELECT 'PRIMARY_STATE=' + ISNULL((
    SELECT TOP (1) ar.replica_server_name FROM sys.availability_replicas ar
    JOIN sys.availability_groups ag ON ag.group_id = ar.group_id
    WHERE ag.name = N'$(AgName)' AND ar.replica_server_name <> @@SERVERNAME), 'NONE')
     + '|' + ISNULL((
    SELECT rs.connected_state_desc COLLATE DATABASE_DEFAULT FROM sys.dm_hadr_availability_replica_states rs
    JOIN sys.availability_groups ag ON ag.group_id = rs.group_id
    WHERE ag.name = N'$(AgName)' AND rs.is_local = 1), 'UNKNOWN');
SELECT 'DB_LAST_COMMIT=' + d.name + '|' + ISNULL(CONVERT(varchar(23), drs.last_commit_time, 126), '-')
     + '|' + drs.synchronization_state_desc COLLATE DATABASE_DEFAULT
FROM sys.dm_hadr_database_replica_states drs
JOIN sys.databases d ON d.database_id = drs.database_id
JOIN sys.availability_groups ag ON ag.group_id = drs.group_id
WHERE ag.name = N'$(AgName)' AND drs.is_local = 1;
-- Last ledger row that reached this replica (readable secondary: ALLOW_CONNECTIONS = ALL).
IF DATABASEPROPERTYEX(N'$(DbName)', 'Status') = 'ONLINE' AND OBJECT_ID(N'[$(DbName)].dbo.UC01_Tx') IS NOT NULL
    EXEC (N'SELECT ''DR_LAST_SEQ='' + ISNULL(CAST(MAX(seq) AS varchar(20)), ''0'') + ''|'' + ISNULL(CONVERT(varchar(23), MAX(written_utc), 126), ''-'')
            FROM [$(DbName)].dbo.UC01_Tx WHERE run_id = ''$(RunId)'' AND phase = ''pre-failure''');
