-- UC-01 | DR replica (node-2) | Forced failover with possible data loss, per Microsoft's procedure for
-- CLUSTER_TYPE = NONE: promote this replica, then REMOVE the unreachable old primary so that it can't
-- come back as a second primary (split-brain) when its region recovers.
-- sqlcmd -v AgName="agsqlvm-node-1" OldPrimary="sqlvm-257672-node-1" -i 11-force-failover.sql
SET NOCOUNT ON;
IF NOT EXISTS (
    SELECT 1 FROM sys.dm_hadr_availability_replica_states rs
    JOIN sys.availability_groups ag ON ag.group_id = rs.group_id
    WHERE ag.name = N'$(AgName)' AND rs.is_local = 1 AND rs.role_desc COLLATE DATABASE_DEFAULT = 'PRIMARY')
BEGIN
    ALTER AVAILABILITY GROUP [$(AgName)] FORCE_FAILOVER_ALLOW_DATA_LOSS;
    SELECT 'FORCED_FAILOVER=1';
END
ELSE
    SELECT 'FORCED_FAILOVER=0 (already PRIMARY)';

IF EXISTS (
    SELECT 1 FROM sys.availability_replicas ar
    JOIN sys.availability_groups ag ON ag.group_id = ar.group_id
    WHERE ag.name = N'$(AgName)' AND ar.replica_server_name = N'$(OldPrimary)')
BEGIN
    ALTER AVAILABILITY GROUP [$(AgName)] REMOVE REPLICA ON N'$(OldPrimary)';
    SELECT 'REMOVED_REPLICA=$(OldPrimary)';
END

-- Resume any database left suspended by the role change.
DECLARE @db sysname, @sql nvarchar(400);
DECLARE c CURSOR LOCAL FAST_FORWARD FOR
    SELECT d.name FROM sys.dm_hadr_database_replica_states drs
    JOIN sys.databases d ON d.database_id = drs.database_id
    WHERE drs.is_local = 1 AND drs.is_suspended = 1;
OPEN c; FETCH NEXT FROM c INTO @db;
WHILE @@FETCH_STATUS = 0
BEGIN
    SET @sql = N'ALTER DATABASE ' + QUOTENAME(@db) + N' SET HADR RESUME;';
    EXEC (@sql);
    SELECT 'RESUMED=' + @db;
    FETCH NEXT FROM c INTO @db;
END
CLOSE c; DEALLOCATE c;
SELECT 'LOCAL_ROLE=' + ISNULL((
    SELECT rs.role_desc COLLATE DATABASE_DEFAULT FROM sys.dm_hadr_availability_replica_states rs
    JOIN sys.availability_groups ag ON ag.group_id = rs.group_id
    WHERE ag.name = N'$(AgName)' AND rs.is_local = 1), 'NONE');
