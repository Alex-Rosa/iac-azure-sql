-- UC-01 | PRIMARY (node-1) | Transaction ledger used to measure RPO. Lives in an AG database, so it
-- replicates to the DR replica like any application table.
-- sqlcmd -v DbName="AGDemoDB" -i 01-prepare-workload.sql
SET NOCOUNT ON;
USE [$(DbName)];
IF OBJECT_ID(N'dbo.UC01_Tx') IS NULL
    CREATE TABLE dbo.UC01_Tx (
        run_id      varchar(32)   NOT NULL,
        seq         bigint        NOT NULL,
        phase       varchar(16)   NOT NULL,   -- 'pre-failure' (writer on node-1) | 'post-failover' (write test on DR)
        written_utc datetime2(3)  NOT NULL CONSTRAINT DF_UC01_Tx_written DEFAULT SYSUTCDATETIME(),
        host        nvarchar(128) NOT NULL CONSTRAINT DF_UC01_Tx_host DEFAULT @@SERVERNAME,
        CONSTRAINT PK_UC01_Tx PRIMARY KEY (run_id, seq)
    );
SELECT 'LEDGER_READY=1';
