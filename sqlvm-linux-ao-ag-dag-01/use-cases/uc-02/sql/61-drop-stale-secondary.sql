-- UC-02 | the DR replica, back after the primary was protected | It was removed from $(AgName) while it was
-- down, so its copy is stale: drop its local definition of the AG, then the AG's databases (they are
-- left RESTORING). Only databases listed in $(Dbs) (comma-separated) are dropped. 22 + 23 re-seed it.
-- sqlcmd -v AgName="agsqlvm-node-1" Dbs="AGDemoDB,WideWorldImporters" -i 61-drop-stale-secondary.sql
SET NOCOUNT ON;
IF EXISTS (SELECT 1 FROM sys.availability_groups WHERE name = N'$(AgName)')
BEGIN
    DROP AVAILABILITY GROUP [$(AgName)];
    SELECT 'AG_DROPPED=' + @@SERVERNAME;
END
DECLARE @db sysname, @sql nvarchar(400), @i int;
DECLARE c CURSOR LOCAL FAST_FORWARD FOR
    SELECT d.name FROM sys.databases d
    WHERE d.name IN (SELECT LTRIM(RTRIM(value)) FROM STRING_SPLIT(N'$(Dbs)', ','))
      AND d.state_desc COLLATE DATABASE_DEFAULT <> 'ONLINE';
OPEN c; FETCH NEXT FROM c INTO @db;
WHILE @@FETCH_STATUS = 0
BEGIN
    SET @i = 0;
    WHILE @i < 12   -- the database can stay briefly in use while the AG is dropped
    BEGIN
        BEGIN TRY
            SET @sql = N'DROP DATABASE ' + QUOTENAME(@db) + N';';
            EXEC (@sql);
            SELECT 'DB_DROPPED=' + @db;
            BREAK;
        END TRY
        BEGIN CATCH
            SET @i += 1;
            IF @i = 12 SELECT 'DB_DROP_FAILED=' + @db + '|' + ERROR_MESSAGE();
            WAITFOR DELAY '00:00:05';
        END CATCH
    END
    FETCH NEXT FROM c INTO @db;
END
CLOSE c; DEALLOCATE c;
