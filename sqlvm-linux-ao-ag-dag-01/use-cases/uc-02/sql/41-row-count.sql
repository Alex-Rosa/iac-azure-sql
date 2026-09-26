-- UC-02 | any replica (the DR replica and forwarders are readable) | Rows the workload of this run
-- committed, as this replica sees them: ROWS=<count>|<max id>.
-- sqlcmd -v DbName="AGDemoDB" RunId="20260926-100000" -i 41-row-count.sql
SET NOCOUNT ON;
SELECT 'HOST=' + @@SERVERNAME;
IF OBJECT_ID(N'[$(DbName)].dbo.UC02_Load') IS NULL SELECT 'ROWS=0|0';
ELSE SELECT 'ROWS=' + CAST(COUNT_BIG(*) AS varchar(20)) + '|' + ISNULL(CAST(MAX(id) AS varchar(20)), '0')
     FROM [$(DbName)].dbo.UC02_Load WHERE run_id = '$(RunId)';
