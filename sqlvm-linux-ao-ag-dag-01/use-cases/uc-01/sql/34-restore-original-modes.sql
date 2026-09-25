-- UC-01 | NEW primary after failback (node-1) | Back to the deployment's original design:
-- local primary SYNCHRONOUS, cross-region replica ASYNCHRONOUS, no commit gating.
-- sqlcmd -v AgName="agsqlvm-node-1" Primary="sqlvm-257672-node-1" Remote="sqlvm-257672-node-2" -i 34-restore-original-modes.sql
SET NOCOUNT ON;
ALTER AVAILABILITY GROUP [$(AgName)] SET (REQUIRED_SYNCHRONIZED_SECONDARIES_TO_COMMIT = 0);
ALTER AVAILABILITY GROUP [$(AgName)] MODIFY REPLICA ON N'$(Remote)'  WITH (AVAILABILITY_MODE = ASYNCHRONOUS_COMMIT);
ALTER AVAILABILITY GROUP [$(AgName)] MODIFY REPLICA ON N'$(Primary)' WITH (AVAILABILITY_MODE = SYNCHRONOUS_COMMIT);
SELECT 'MODES_RESTORED=1';
