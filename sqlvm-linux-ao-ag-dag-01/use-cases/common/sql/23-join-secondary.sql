-- shared | the re-added node, after 22-add-replica.sql ran on the primary | Join the AG as a
-- secondary and allow automatic seeding to create the databases.
-- sqlcmd -v AgName="agsqlvm-node-1" -i 23-join-secondary.sql
SET NOCOUNT ON;
IF NOT EXISTS (SELECT 1 FROM sys.availability_groups WHERE name = N'$(AgName)')
BEGIN
    ALTER AVAILABILITY GROUP [$(AgName)] JOIN WITH (CLUSTER_TYPE = NONE);
    SELECT 'JOINED=1';
END
ELSE
    SELECT 'JOINED=0 (already joined)';
ALTER AVAILABILITY GROUP [$(AgName)] GRANT CREATE ANY DATABASE;
