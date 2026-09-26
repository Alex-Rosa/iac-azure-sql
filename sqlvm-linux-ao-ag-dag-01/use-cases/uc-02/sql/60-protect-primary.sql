-- UC-02 | PRIMARY | Protect the primary when its log volume runs out of room while a region is down:
-- remove the missing DR replica from $(AgName) and drop the distributed AGs of the missing forwarders
-- ($(Dags), comma-separated, may be empty), then back up the log so it can be truncated and reused.
-- The price: those replicas must be re-seeded when their region is back (uc-02.ps1 recover does it).
-- sqlcmd -v AgName="agsqlvm-node-1" Replica="sqlvm-ag01-node-2" Dags="dagsqlvm-node-1-node-5" DbName="AGDemoDB" BackupFile="/var/opt/mssql/backup/uc02/AGDemoDB-protect.trn" -i 60-protect-primary.sql
SET NOCOUNT ON;
IF EXISTS (SELECT 1 FROM sys.availability_replicas ar JOIN sys.availability_groups ag ON ag.group_id = ar.group_id
           WHERE ag.name = N'$(AgName)' AND ar.replica_server_name = N'$(Replica)')
BEGIN
    ALTER AVAILABILITY GROUP [$(AgName)] REMOVE REPLICA ON N'$(Replica)';
    SELECT 'REPLICA_REMOVED=$(Replica)';
END
DECLARE @dag sysname, @sql nvarchar(400);
DECLARE c CURSOR LOCAL FAST_FORWARD FOR SELECT LTRIM(RTRIM(value)) FROM STRING_SPLIT(N'$(Dags)', ',') WHERE LTRIM(RTRIM(value)) <> '';
OPEN c; FETCH NEXT FROM c INTO @dag;
WHILE @@FETCH_STATUS = 0
BEGIN
    IF EXISTS (SELECT 1 FROM sys.availability_groups WHERE name = @dag AND is_distributed = 1)
    BEGIN
        SET @sql = N'DROP AVAILABILITY GROUP ' + QUOTENAME(@dag) + N';';
        EXEC (@sql);
        SELECT 'DAG_DROPPED=' + @dag;
    END
    FETCH NEXT FROM c INTO @dag;
END
CLOSE c; DEALLOCATE c;
BACKUP LOG [$(DbName)] TO DISK = N'$(BackupFile)' WITH COMPRESSION, INIT;
SELECT 'LOG_REUSE_WAIT=' + log_reuse_wait_desc COLLATE DATABASE_DEFAULT FROM sys.databases WHERE name = N'$(DbName)';
