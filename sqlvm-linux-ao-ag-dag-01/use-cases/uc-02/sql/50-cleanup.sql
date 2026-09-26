-- UC-02 | PRIMARY | Reclaims the space the workload used: stops every writer, empties the load table
-- (TRUNCATE is minimally logged), backs up the log so it can be truncated, and shrinks the log file
-- to $(TargetLogMB) MB. The DR replica and the forwarders replay all of it.
-- sqlcmd -v DbName="AGDemoDB" BackupFile="/var/opt/mssql/backup/uc02/AGDemoDB-cleanup.trn" TargetLogMB="1024" -i 50-cleanup.sql
SET NOCOUNT ON;
USE [$(DbName)];
SELECT 'LOG_BEFORE_MB=' + CAST(size / 128 AS varchar(20)) FROM sys.database_files WHERE type = 1;
IF OBJECT_ID(N'dbo.UC02_Control') IS NOT NULL UPDATE dbo.UC02_Control SET stop = 1;
IF OBJECT_ID(N'dbo.UC02_Load') IS NOT NULL TRUNCATE TABLE dbo.UC02_Load;
BACKUP LOG [$(DbName)] TO DISK = N'$(BackupFile)' WITH COMPRESSION, INIT;
CHECKPOINT;
DECLARE @shrink nvarchar(200) = N'DBCC SHRINKFILE (' + CAST((SELECT TOP (1) file_id FROM sys.database_files WHERE type = 1) AS nvarchar(10))
                              + N', $(TargetLogMB)) WITH NO_INFOMSGS;';
EXEC (@shrink);
SELECT 'LOG_AFTER_MB=' + CAST(size / 128 AS varchar(20)) FROM sys.database_files WHERE type = 1;
SELECT 'LOG_REUSE_WAIT=' + log_reuse_wait_desc COLLATE DATABASE_DEFAULT FROM sys.databases WHERE name = N'$(DbName)';
