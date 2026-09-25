-- UC-01 | CURRENT primary (node-2) | Planned failback, no data loss (Microsoft procedure for
-- CLUSTER_TYPE = NONE): make both replicas SYNCHRONOUS and require 1 synchronized secondary to commit.
-- sqlcmd -v AgName="agsqlvm-node-1" CurrentPrimary="sqlvm-257672-node-2" Target="sqlvm-257672-node-1" -i 30-failback-prepare.sql
SET NOCOUNT ON;
ALTER AVAILABILITY GROUP [$(AgName)] MODIFY REPLICA ON N'$(CurrentPrimary)' WITH (AVAILABILITY_MODE = SYNCHRONOUS_COMMIT);
ALTER AVAILABILITY GROUP [$(AgName)] MODIFY REPLICA ON N'$(Target)'         WITH (AVAILABILITY_MODE = SYNCHRONOUS_COMMIT);
ALTER AVAILABILITY GROUP [$(AgName)] SET (REQUIRED_SYNCHRONIZED_SECONDARIES_TO_COMMIT = 1);
SELECT 'FAILBACK_PREPARED=1';
