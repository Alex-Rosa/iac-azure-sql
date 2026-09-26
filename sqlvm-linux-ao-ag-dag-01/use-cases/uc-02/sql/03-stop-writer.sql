-- UC-02 | PRIMARY | Sets the stop flag, waits up to 90 s for every writer session to finish, then reports
-- each session and the totals.
-- sqlcmd -v DbName="AGDemoDB" RunId="20260926-100000" -i 03-stop-writer.sql
SET NOCOUNT ON;
USE [$(DbName)];
IF OBJECT_ID(N'dbo.UC02_Control') IS NULL BEGIN SELECT 'TOTAL=0|0|0'; RETURN; END
UPDATE dbo.UC02_Control SET stop = 1 WHERE run_id = '$(RunId)';
DECLARE @t int = 0;
WHILE @t < 90 AND EXISTS (SELECT 1 FROM dbo.UC02_Writer WHERE run_id = '$(RunId)' AND stop_reason IS NULL)
BEGIN
    WAITFOR DELAY '00:00:01';
    SET @t += 1;
END
SELECT 'WRITER=' + CAST(session_id AS varchar(10)) + '|' + ISNULL(stop_reason, 'still running')
     + '|tx_ok=' + CAST(tx_ok AS varchar(20)) + '|tx_err=' + CAST(tx_err AS varchar(20))
FROM dbo.UC02_Writer WHERE run_id = '$(RunId)' ORDER BY session_id;
SELECT 'TOTAL=' + CAST(ISNULL(SUM(tx_ok), 0) AS varchar(20)) + '|' + CAST(ISNULL(SUM(tx_err), 0) AS varchar(20)) + '|' + CAST(ISNULL(SUM(rows_ok), 0) AS varchar(20))
FROM dbo.UC02_Writer WHERE run_id = '$(RunId)';
