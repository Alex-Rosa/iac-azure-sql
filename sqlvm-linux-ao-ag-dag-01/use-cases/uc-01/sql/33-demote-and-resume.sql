-- UC-01 | run on the OLD primary (node-2) after 32-promote.sql, then on the NEW primary (node-1) |
-- Set the old primary's role to SECONDARY (only when it isn't already) and resume data movement for
-- every suspended local AG database.
-- sqlcmd -v AgName="agsqlvm-node-1" Demote="1" -i 33-demote-and-resume.sql
SET NOCOUNT ON;
IF $(Demote) = 1
BEGIN
    ALTER AVAILABILITY GROUP [$(AgName)] SET (ROLE = SECONDARY);
    SELECT 'DEMOTED=' + @@SERVERNAME;
END
DECLARE @db sysname, @sql nvarchar(400);
DECLARE c CURSOR LOCAL FAST_FORWARD FOR
    SELECT d.name FROM sys.dm_hadr_database_replica_states drs
    JOIN sys.databases d ON d.database_id = drs.database_id
    WHERE drs.is_local = 1 AND drs.is_suspended = 1;
OPEN c; FETCH NEXT FROM c INTO @db;
WHILE @@FETCH_STATUS = 0
BEGIN
    SET @sql = N'ALTER DATABASE ' + QUOTENAME(@db) + N' SET HADR RESUME;';
    BEGIN TRY EXEC (@sql); SELECT 'RESUMED=' + @db; END TRY
    BEGIN CATCH SELECT 'RESUME_SKIPPED=' + @db + '|' + ERROR_MESSAGE(); END CATCH
    FETCH NEXT FROM c INTO @db;
END
CLOSE c; DEALLOCATE c;
