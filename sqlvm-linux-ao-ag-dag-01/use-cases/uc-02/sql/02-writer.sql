-- UC-02 | PRIMARY | One writer session (uc-02.ps1 start-workload runs N of them in the background).
-- Loops until $(Seconds) elapse, the stop flag is set, or the log volume drops below $(MinFreePct)% free:
-- each transaction inserts $(Rows) rows of $(RowBytes) bytes, then waits $(ThinkMs) ms.
-- Progress (committed / failed transactions, slowest commit) goes to dbo.UC02_Writer every 20 transactions.
-- sqlcmd -v DbName="AGDemoDB" RunId="20260926-100000" Session="1" Rows="20" RowBytes="2000" ThinkMs="20" Seconds="3600" MinFreePct="15" -i 02-writer.sql
SET NOCOUNT ON;
SET XACT_ABORT ON;
SET DEADLOCK_PRIORITY LOW;
USE [$(DbName)];
DECLARE @run varchar(32) = '$(RunId)', @session int = $(Session), @rows int = $(Rows);
DECLARE @end datetime2(3) = DATEADD(second, $(Seconds), SYSUTCDATETIME());
DECLARE @think datetime = DATEADD(millisecond, $(ThinkMs), CAST(0 AS datetime));
DECLARE @payload varchar(8000) = REPLICATE('x', $(RowBytes));
DECLARE @ok bigint = 0, @err bigint = 0, @i bigint = 0, @lastErr nvarchar(400) = NULL, @stop varchar(60) = 'duration reached', @free float;
DECLARE @t0 datetime2(7), @ms int, @slow int = 0;   -- commit duration: shows a stall (e.g. a synchronous replica lost)

INSERT dbo.UC02_Writer (run_id, session_id, tx_ok, tx_err, rows_ok, started_utc, updated_utc)
VALUES (@run, @session, 0, 0, 0, SYSUTCDATETIME(), SYSUTCDATETIME());

WHILE SYSUTCDATETIME() < @end
BEGIN
    SET @t0 = SYSUTCDATETIME();
    BEGIN TRY
        BEGIN TRAN;
        INSERT dbo.UC02_Load (run_id, session_id, payload)
        SELECT TOP (@rows) @run, @session, @payload FROM sys.all_columns;
        COMMIT;
        SET @ok += 1;
        SET @ms = DATEDIFF(millisecond, @t0, SYSUTCDATETIME());
        IF @ms > @slow SET @slow = @ms;
    END TRY
    BEGIN CATCH
        IF @@TRANCOUNT > 0 ROLLBACK;
        SET @err += 1;
        SET @lastErr = LEFT(ERROR_MESSAGE(), 400);
        WAITFOR DELAY '00:00:01';
    END CATCH
    SET @i += 1;
    IF @i % 20 = 0
    BEGIN
        BEGIN TRY
            UPDATE dbo.UC02_Writer SET tx_ok = @ok, tx_err = @err, rows_ok = @ok * @rows, last_error = @lastErr, slow_ms = @slow, updated_utc = SYSUTCDATETIME()
            WHERE run_id = @run AND session_id = @session;
            SET @slow = 0;
        END TRY
        BEGIN CATCH END CATCH
        IF EXISTS (SELECT 1 FROM dbo.UC02_Control WHERE run_id = @run AND stop = 1) BEGIN SET @stop = 'stop requested'; BREAK; END
        -- Disk guard: the primary's log can't be truncated while a replica is down - stop before the volume fills.
        SELECT @free = MIN(vs.available_bytes * 100.0 / NULLIF(vs.total_bytes, 0))
        FROM sys.database_files f CROSS APPLY sys.dm_os_volume_stats(DB_ID(), f.file_id) vs;
        IF @free < $(MinFreePct) BEGIN SET @stop = 'disk guard (' + CAST(CAST(@free AS decimal(5, 1)) AS varchar(10)) + '% free)'; BREAK; END
    END
    IF $(ThinkMs) > 0 WAITFOR DELAY @think;
END

UPDATE dbo.UC02_Writer SET tx_ok = @ok, tx_err = @err, rows_ok = @ok * @rows, last_error = @lastErr, stop_reason = @stop, updated_utc = SYSUTCDATETIME()
WHERE run_id = @run AND session_id = @session;
SELECT 'WRITER_DONE=' + CAST(@session AS varchar(10)) + '|' + @stop;
