-- UC-01 | OLD primary (node-1) after its region recovers - the VM must be FENCED first (deny 1433).
-- After a forced failover the old primary comes back still believing it is PRIMARY. Read the
-- transactions it committed that never reached the DR replica: this is the exact data loss (RPO).
-- sqlcmd -v AgName="agsqlvm-node-1" DbName="AGDemoDB" RunId="20260924-150000" -i 20-old-primary-inspect.sql
SET NOCOUNT ON;
SELECT 'LOCAL_ROLE=' + ISNULL((
    SELECT rs.role_desc COLLATE DATABASE_DEFAULT FROM sys.dm_hadr_availability_replica_states rs
    JOIN sys.availability_groups ag ON ag.group_id = rs.group_id
    WHERE ag.name = N'$(AgName)' AND rs.is_local = 1), 'NONE');
SELECT 'AG_DB=' + d.name + '|' + d.state_desc COLLATE DATABASE_DEFAULT
FROM sys.dm_hadr_database_replica_states drs
JOIN sys.databases d ON d.database_id = drs.database_id
JOIN sys.availability_groups ag ON ag.group_id = drs.group_id
WHERE ag.name = N'$(AgName)' AND drs.is_local = 1;
IF DATABASEPROPERTYEX(N'$(DbName)', 'Status') = 'ONLINE' AND OBJECT_ID(N'[$(DbName)].dbo.UC01_Tx') IS NOT NULL
    EXEC (N'SELECT ''OLD_LAST_SEQ='' + ISNULL(CAST(MAX(seq) AS varchar(20)), ''0'') + ''|'' + ISNULL(CONVERT(varchar(23), MAX(written_utc), 126), ''-'')
            FROM [$(DbName)].dbo.UC01_Tx WHERE run_id = ''$(RunId)'' AND phase = ''pre-failure''');
