-- shared | PRIMARY | Transaction ledger written by the application writer (uc-common.ps1 Start-UcWriter).
-- It lives in an AG database, so it replicates like any application table. One row per acknowledged
-- commit: (run_id, seq) is the writer's counter, host_ip the node that accepted the commit.
-- sqlcmd -v DbName="AGDemoDB" -i 01-prepare-ledger.sql
SET NOCOUNT ON;
USE [$(DbName)];
IF OBJECT_ID(N'dbo.UC_Tx') IS NULL
    CREATE TABLE dbo.UC_Tx (
        run_id      varchar(32)   NOT NULL,
        seq         bigint        NOT NULL,
        host_ip     varchar(45)   NOT NULL,
        written_utc datetime2(3)  NOT NULL CONSTRAINT DF_UC_Tx_written DEFAULT SYSUTCDATETIME(),
        host        nvarchar(128) NOT NULL CONSTRAINT DF_UC_Tx_host DEFAULT @@SERVERNAME,
        CONSTRAINT PK_UC_Tx PRIMARY KEY (run_id, seq)
    );
SELECT 'LEDGER_READY=1';
