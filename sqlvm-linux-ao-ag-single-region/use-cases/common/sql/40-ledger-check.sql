-- shared | any node whose database is readable (primary, readable secondary, fenced old primary) |
-- The ledger of one drill run:
--   LEDGER=<rows>|<max seq>|<newest row UTC>
--   LEDGER_UPTO=<rows with seq <= UpTo>     UpTo = the writer's last ACKNOWLEDGED seq:
--                                           UpTo - LEDGER_UPTO = acknowledged commits that are missing (RPO)
--   LEDGER_HOST=<rows>|<max seq> committed through HostIp (e.g. the old primary, to find rows only it has)
-- sqlcmd -v DbName="AGDemoDB" RunId="20261012-150000" UpTo="1234" HostIp="10.10.1.4" -i 40-ledger-check.sql
SET NOCOUNT ON;
USE [$(DbName)];
IF OBJECT_ID(N'dbo.UC_Tx') IS NULL
BEGIN
    SELECT 'LEDGER=0|0|-';
    RETURN;
END
SELECT 'LEDGER=' + CAST(COUNT(*) AS varchar(20)) + '|' + ISNULL(CAST(MAX(seq) AS varchar(20)), '0')
     + '|' + ISNULL(CONVERT(varchar(23), MAX(written_utc), 126), '-')
FROM dbo.UC_Tx WHERE run_id = '$(RunId)';
SELECT 'LEDGER_UPTO=' + CAST(COUNT(*) AS varchar(20)) FROM dbo.UC_Tx WHERE run_id = '$(RunId)' AND seq <= $(UpTo);
SELECT 'LEDGER_HOST=' + CAST(COUNT(*) AS varchar(20)) + '|' + ISNULL(CAST(MAX(seq) AS varchar(20)), '0')
FROM dbo.UC_Tx WHERE run_id = '$(RunId)' AND host_ip = '$(HostIp)';
