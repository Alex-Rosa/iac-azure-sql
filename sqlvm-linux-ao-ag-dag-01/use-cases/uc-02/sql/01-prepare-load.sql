-- UC-02 | PRIMARY | Workload tables. They live in an AG database, so they replicate to the DR replica
-- and to every forwarder like any application table:
--   UC02_Load     the rows the writer sessions insert (payload sized by the workload profile)
--   UC02_Writer   one row per writer session: committed / failed transactions, why it stopped
--   UC02_Control  stop flag the writer sessions poll (stop-workload, verify, cleanup)
-- sqlcmd -v DbName="AGDemoDB" RunId="20260926-100000" -i 01-prepare-load.sql
SET NOCOUNT ON;
USE [$(DbName)];
IF OBJECT_ID(N'dbo.UC02_Load') IS NULL
    CREATE TABLE dbo.UC02_Load (
        id          bigint IDENTITY(1, 1) NOT NULL CONSTRAINT PK_UC02_Load PRIMARY KEY,
        run_id      varchar(32)   NOT NULL,
        session_id  int           NOT NULL,
        written_utc datetime2(3)  NOT NULL CONSTRAINT DF_UC02_Load_written DEFAULT SYSUTCDATETIME(),
        payload     varchar(8000) NOT NULL
    );
IF OBJECT_ID(N'dbo.UC02_Writer') IS NULL
    CREATE TABLE dbo.UC02_Writer (
        run_id      varchar(32)    NOT NULL,
        session_id  int            NOT NULL,
        tx_ok       bigint         NOT NULL,
        tx_err      bigint         NOT NULL,
        rows_ok     bigint         NOT NULL,
        last_error  nvarchar(400)  NULL,
        stop_reason varchar(60)    NULL,        -- NULL while the session runs
        started_utc datetime2(3)   NOT NULL,
        updated_utc datetime2(3)   NOT NULL,
        slow_ms     int            NULL,        -- slowest commit since the previous progress update
        CONSTRAINT PK_UC02_Writer PRIMARY KEY (run_id, session_id)
    );
IF COL_LENGTH(N'dbo.UC02_Writer', N'slow_ms') IS NULL ALTER TABLE dbo.UC02_Writer ADD slow_ms int NULL;   -- tables from older runs
IF OBJECT_ID(N'dbo.UC02_Control') IS NULL
    CREATE TABLE dbo.UC02_Control (run_id varchar(32) NOT NULL CONSTRAINT PK_UC02_Control PRIMARY KEY, stop bit NOT NULL);
DELETE dbo.UC02_Writer WHERE run_id = '$(RunId)';
IF EXISTS (SELECT 1 FROM dbo.UC02_Control WHERE run_id = '$(RunId)') UPDATE dbo.UC02_Control SET stop = 0 WHERE run_id = '$(RunId)';
ELSE INSERT dbo.UC02_Control (run_id, stop) VALUES ('$(RunId)', 0);
SELECT 'LOAD_READY=1';
SELECT 'DB_FILE=' + CASE type WHEN 1 THEN 'log' ELSE 'data' END + '|' + physical_name + '|' + CAST(size / 128 AS varchar(20)) + ' MB'
FROM sys.database_files;
