-- UC-02 | PRIMARY | One monitoring sample as ONE line (the on-VM sampler appends one every few seconds;
-- uc-02.ps1 collects them in batches):
--   S1=<utc>|<tx counter>|<log bytes counter>|<writer committed>|<writer failed>|<writer sessions running>
--      |<writer stop reason>|<writer slowest commit ms>|<log MB>|<log used %>|<log reuse wait>
--      |<log volume>|<volume MB>|<volume free MB>|<AG data MB>|<primary last commit>|<replicas>
--   <replicas> = '#'-separated: AG,replica,connected,sync state,suspended,send queue KB,send rate KB/s,
--                redo queue KB,redo rate KB/s,secondary_lag_seconds,replica last commit
-- Replication lag is computed from the two last-commit times (the primary's newest commit minus the
-- newest commit the replica has): millisecond precision, and still known while the replica is down.
-- sqlcmd -v DbName="AGDemoDB" RunId="20260926-100000" -i 40-primary-sample.sql
SET NOCOUNT ON;
DECLARE @db sysname = N'$(DbName)', @dbid int = DB_ID(N'$(DbName)');
DECLARE @tx bigint, @logb bigint;
SELECT @tx   = SUM(CASE WHEN RTRIM(counter_name) = 'Transactions/sec' THEN cntr_value END),
       @logb = SUM(CASE WHEN RTRIM(counter_name) = 'Log Bytes Flushed/sec' THEN cntr_value END)
FROM sys.dm_os_performance_counters
WHERE object_name LIKE '%:Databases%' AND RTRIM(instance_name) = @db;
DECLARE @w varchar(300) = '0|0|0||';
IF OBJECT_ID(N'[$(DbName)].dbo.UC02_Writer') IS NOT NULL
    SELECT @w = CAST(ISNULL(SUM(tx_ok), 0) AS varchar(20)) + '|' + CAST(ISNULL(SUM(tx_err), 0) AS varchar(20))
              + '|' + CAST(ISNULL(SUM(CASE WHEN stop_reason IS NULL THEN 1 ELSE 0 END), 0) AS varchar(10))
              + '|' + ISNULL(MAX(stop_reason), '') + '|' + ISNULL(CAST(MAX(slow_ms) AS varchar(20)), '')
    FROM [$(DbName)].dbo.UC02_Writer WHERE run_id = '$(RunId)';
CREATE TABLE #ls (db sysname, size_mb float, used_pct float, status int);
INSERT #ls EXEC ('DBCC SQLPERF(LOGSPACE) WITH NO_INFOMSGS');
DECLARE @log varchar(300) = (
    SELECT CAST(CAST(l.size_mb AS decimal(14, 1)) AS varchar(20)) + '|' + CAST(CAST(l.used_pct AS decimal(5, 1)) AS varchar(10))
         + '|' + d.log_reuse_wait_desc COLLATE DATABASE_DEFAULT
    FROM #ls l JOIN sys.databases d ON d.name = l.db COLLATE DATABASE_DEFAULT WHERE d.name = @db);
-- volume_mount_point is NULL on Linux: fall back to the log file's folder.
DECLARE @disk varchar(600) = (
    SELECT TOP (1) ISNULL(vs.volume_mount_point COLLATE DATABASE_DEFAULT,
                          LEFT(mf.physical_name, LEN(mf.physical_name) - CHARINDEX('/', REVERSE(mf.physical_name))) COLLATE DATABASE_DEFAULT)
         + '|' + CAST(vs.total_bytes / 1048576 AS varchar(20)) + '|' + CAST(vs.available_bytes / 1048576 AS varchar(20))
    FROM sys.master_files mf CROSS APPLY sys.dm_os_volume_stats(mf.database_id, mf.file_id) vs
    WHERE mf.database_id = @dbid AND mf.type = 1);
-- Data size of every database in an AG on this node: what a reseed would have to copy.
DECLARE @dataMB bigint = (SELECT SUM(CAST(size AS bigint)) / 128 FROM sys.master_files
                          WHERE type = 0 AND database_id IN (SELECT database_id FROM sys.dm_hadr_database_replica_states WHERE is_local = 1));
DECLARE @lc datetime = (SELECT MAX(last_commit_time) FROM sys.dm_hadr_database_replica_states WHERE is_local = 1 AND database_id = @dbid);
DECLARE @reps varchar(8000) = (
    SELECT STRING_AGG(CAST(ag.name COLLATE DATABASE_DEFAULT + ',' + ar.replica_server_name COLLATE DATABASE_DEFAULT
         + ',' + ISNULL(rs.connected_state_desc COLLATE DATABASE_DEFAULT, '?') + ',' + drs.synchronization_state_desc COLLATE DATABASE_DEFAULT
         + ',' + CAST(drs.is_suspended AS varchar(1))
         + ',' + ISNULL(CAST(drs.log_send_queue_size AS varchar(20)), '') + ',' + ISNULL(CAST(drs.log_send_rate AS varchar(20)), '')
         + ',' + ISNULL(CAST(drs.redo_queue_size AS varchar(20)), '') + ',' + ISNULL(CAST(drs.redo_rate AS varchar(20)), '')
         + ',' + ISNULL(CAST(drs.secondary_lag_seconds AS varchar(20)), '')
         + ',' + ISNULL(CONVERT(varchar(23), drs.last_commit_time, 126), '') AS varchar(8000)), '#')
    FROM sys.dm_hadr_database_replica_states drs
    JOIN sys.availability_replicas ar ON ar.replica_id = drs.replica_id
    JOIN sys.availability_groups ag ON ag.group_id = drs.group_id
    LEFT JOIN sys.dm_hadr_availability_replica_states rs ON rs.replica_id = drs.replica_id
    WHERE drs.is_local = 0 AND drs.database_id = @dbid);
SELECT CAST('S1=' + CONVERT(varchar(23), SYSUTCDATETIME(), 126) + '|' + ISNULL(CAST(@tx AS varchar(30)), '') + '|' + ISNULL(CAST(@logb AS varchar(30)), '')
     + '|' + @w + '|' + ISNULL(@log, '||') + '|' + ISNULL(@disk, '||') + '|' + ISNULL(CAST(@dataMB AS varchar(20)), '')
     + '|' + ISNULL(CONVERT(varchar(23), @lc, 126), '') + '|' + ISNULL(@reps, '') AS varchar(8000));
