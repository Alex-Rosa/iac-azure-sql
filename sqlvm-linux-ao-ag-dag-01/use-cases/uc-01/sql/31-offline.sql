-- UC-01 | CURRENT primary (node-2), once the target reports SYNCHRONIZED | Take the AG offline here
-- to stop writes before the role change.
-- sqlcmd -v AgName="agsqlvm-node-1" -i 31-offline.sql
SET NOCOUNT ON;
ALTER AVAILABILITY GROUP [$(AgName)] OFFLINE;
SELECT 'AG_OFFLINE=1';
