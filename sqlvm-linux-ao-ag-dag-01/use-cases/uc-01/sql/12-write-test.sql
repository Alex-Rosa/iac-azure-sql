-- UC-01 | NEW primary (node-2) | Proves the alternate region now accepts transactions: inserts
-- $(Rows) ledger rows and reports the ledger state for this drill.
-- sqlcmd -v DbName="AGDemoDB" RunId="20260924-150000" Rows="10" -i 12-write-test.sql
SET NOCOUNT ON;
USE [$(DbName)];
IF OBJECT_ID(N'dbo.UC01_Tx') IS NULL   -- same definition as 01-prepare-workload.sql
    CREATE TABLE dbo.UC01_Tx (
        run_id      varchar(32)   NOT NULL,
        seq         bigint        NOT NULL,
        phase       varchar(16)   NOT NULL,
        written_utc datetime2(3)  NOT NULL CONSTRAINT DF_UC01_Tx_written DEFAULT SYSUTCDATETIME(),
        host        nvarchar(128) NOT NULL CONSTRAINT DF_UC01_Tx_host DEFAULT @@SERVERNAME,
        CONSTRAINT PK_UC01_Tx PRIMARY KEY (run_id, seq)
    );
DECLARE @i int = 1, @base bigint = 1000000000;   -- post-failover rows use their own seq range
SELECT @base = ISNULL(MAX(seq), @base) FROM dbo.UC01_Tx WHERE run_id = '$(RunId)' AND phase = 'post-failover';
WHILE @i <= $(Rows)
BEGIN
    INSERT dbo.UC01_Tx (run_id, seq, phase) VALUES ('$(RunId)', @base + @i, 'post-failover');
    SET @i += 1;
END
SELECT 'WRITE_OK=' + CAST($(Rows) AS varchar(10)) + '|' + @@SERVERNAME + '|' + CONVERT(varchar(23), SYSUTCDATETIME(), 126);
SELECT 'LEDGER=' + phase + '|rows=' + CAST(COUNT(*) AS varchar(20)) + '|max_seq=' + CAST(MAX(seq) AS varchar(20))
     + '|last=' + CONVERT(varchar(23), MAX(written_utc), 126)
FROM dbo.UC01_Tx WHERE run_id = '$(RunId)' GROUP BY phase;
