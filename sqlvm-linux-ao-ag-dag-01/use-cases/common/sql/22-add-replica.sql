-- UC-01 | CURRENT primary (node-2) | Re-add the recovered node as an ASYNCHRONOUS secondary (it is now
-- the cross-region replica). Automatic seeding re-creates its databases from this primary.
-- sqlcmd -v AgName="agsqlvm-node-1" ReplicaName="sqlvm-257672-node-1" EndpointUrl="tcp://10.10.1.4:5022" -i 22-add-replica.sql
SET NOCOUNT ON;
IF NOT EXISTS (
    SELECT 1 FROM sys.availability_replicas ar
    JOIN sys.availability_groups ag ON ag.group_id = ar.group_id
    WHERE ag.name = N'$(AgName)' AND ar.replica_server_name = N'$(ReplicaName)')
BEGIN
    ALTER AVAILABILITY GROUP [$(AgName)] ADD REPLICA ON
        N'$(ReplicaName)' WITH (
            ENDPOINT_URL = N'$(EndpointUrl)',
            AVAILABILITY_MODE = ASYNCHRONOUS_COMMIT,
            FAILOVER_MODE = MANUAL,
            SEEDING_MODE = AUTOMATIC,
            SECONDARY_ROLE (ALLOW_CONNECTIONS = ALL));
    SELECT 'REPLICA_ADDED=$(ReplicaName)';
END
ELSE
    SELECT 'REPLICA_ADDED=0 (already present)';
