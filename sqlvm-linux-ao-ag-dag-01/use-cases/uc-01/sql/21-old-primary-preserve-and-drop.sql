-- UC-01 | OLD primary (node-1), still FENCED | Microsoft's cleanup after a forced failover:
--   1. preserve the unsynchronized data (COPY_ONLY backups - skipped when SkipBackup=1)
--   2. drop every stale distributed AG, 3. take the AG offline, 4. drop the AG, 5. drop its databases,
-- so that node-1 can rejoin as a clean secondary and be re-seeded from the new primary.
-- sqlcmd -v AgName="agsqlvm-node-1" DropDistributed="1" BackupDir="/var/opt/mssql/backup" RunId="20260924-150000" SkipBackup="0" -i 21-old-primary-preserve-and-drop.sql
SET NOCOUNT ON;
DECLARE @dbs TABLE (name sysname);
INSERT @dbs SELECT d.name
FROM sys.dm_hadr_database_replica_states drs
JOIN sys.databases d ON d.database_id = drs.database_id
JOIN sys.availability_groups ag ON ag.group_id = drs.group_id
WHERE ag.name = N'$(AgName)' AND drs.is_local = 1;

DECLARE @db sysname, @sql nvarchar(max);

IF $(SkipBackup) = 0
BEGIN
    DECLARE b CURSOR LOCAL FAST_FORWARD FOR
        SELECT name FROM @dbs WHERE DATABASEPROPERTYEX(name, 'Status') = 'ONLINE';
    OPEN b; FETCH NEXT FROM b INTO @db;
    WHILE @@FETCH_STATUS = 0
    BEGIN
        SET @sql = N'BACKUP DATABASE ' + QUOTENAME(@db) + N' TO DISK = N''$(BackupDir)/uc01-$(RunId)-' + @db
                 + N'.bak'' WITH COPY_ONLY, COMPRESSION, INIT;';
        EXEC (@sql);
        SELECT 'PRESERVED=' + @db + '|$(BackupDir)/uc01-$(RunId)-' + @db + '.bak';
        FETCH NEXT FROM b INTO @db;
    END
    CLOSE b; DEALLOCATE b;
END

-- The stale distributed AG definitions go first: they reference the local AG, and a stale global
-- primary must never push its divergent log to a forwarder. This node only takes part in its own AG's
-- distributed AGs, so every one defined here is stale. DropDistributed="0" skips this.
IF $(DropDistributed) = 1
BEGIN
    DECLARE @dag sysname;
    DECLARE g CURSOR LOCAL FAST_FORWARD FOR SELECT name FROM sys.availability_groups WHERE is_distributed = 1;
    OPEN g; FETCH NEXT FROM g INTO @dag;
    WHILE @@FETCH_STATUS = 0
    BEGIN
        SET @sql = N'DROP AVAILABILITY GROUP ' + QUOTENAME(@dag) + N';';
        EXEC (@sql);
        SELECT 'DAG_DROPPED=' + @dag;
        FETCH NEXT FROM g INTO @dag;
    END
    CLOSE g; DEALLOCATE g;
END

IF EXISTS (SELECT 1 FROM sys.availability_groups WHERE name = N'$(AgName)')
BEGIN
    BEGIN TRY ALTER AVAILABILITY GROUP [$(AgName)] OFFLINE; SELECT 'AG_OFFLINE=1'; END TRY
    BEGIN CATCH SELECT 'AG_OFFLINE=skipped|' + ERROR_MESSAGE(); END CATCH
    DROP AVAILABILITY GROUP [$(AgName)];
    SELECT 'AG_DROPPED=1';
END

DECLARE x CURSOR LOCAL FAST_FORWARD FOR SELECT name FROM @dbs;
OPEN x; FETCH NEXT FROM x INTO @db;
WHILE @@FETCH_STATUS = 0
BEGIN
    IF DB_ID(@db) IS NOT NULL
    BEGIN
        IF DATABASEPROPERTYEX(@db, 'Status') = 'ONLINE'
        BEGIN
            SET @sql = N'ALTER DATABASE ' + QUOTENAME(@db) + N' SET SINGLE_USER WITH ROLLBACK IMMEDIATE;';
            EXEC (@sql);
        END
        SET @sql = N'DROP DATABASE ' + QUOTENAME(@db) + N';';
        EXEC (@sql);
        SELECT 'DB_DROPPED=' + @db;
    END
    FETCH NEXT FROM x INTO @db;
END
CLOSE x; DEALLOCATE x;
