-- UC-01 | failback TARGET (node-1) | Promote. The target is SYNCHRONIZED and the old primary is
-- offline, so despite the command name no committed data is lost.
-- sqlcmd -v AgName="agsqlvm-node-1" -i 32-promote.sql
SET NOCOUNT ON;
ALTER AVAILABILITY GROUP [$(AgName)] FORCE_FAILOVER_ALLOW_DATA_LOSS;
SELECT 'PROMOTED=' + @@SERVERNAME;
