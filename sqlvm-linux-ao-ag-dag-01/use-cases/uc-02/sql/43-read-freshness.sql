-- UC-02 | DR replica (readable secondary) | What a reporting query sees: the newest workload row
-- readable on this replica. Freshness = now - that row's commit time on the primary.
--   R1=<utc now>|<newest row written_utc>
-- sqlcmd -v DbName="AGDemoDB" -i 43-read-freshness.sql
SET NOCOUNT ON;
SELECT 'R1=' + CONVERT(varchar(23), SYSUTCDATETIME(), 126) + '|'
     + ISNULL((SELECT TOP (1) CONVERT(varchar(23), written_utc, 126) FROM [$(DbName)].dbo.UC02_Load ORDER BY id DESC), '');
