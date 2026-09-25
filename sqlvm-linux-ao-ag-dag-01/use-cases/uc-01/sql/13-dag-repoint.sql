-- UC-01 | global primary AND forwarder | Point the distributed AG at a member AG's CURRENT primary
-- replica. With CLUSTER_TYPE = NONE there's no listener: LISTENER_URL is the primary replica's
-- endpoint, so after any local failover inside a member AG it must be updated - on the global
-- primary and on the forwarder (Microsoft: "Manually fail over FCI in distributed availability group").
-- sqlcmd -v DagName="dagsqlvm-node-1-node-3" MemberAg="agsqlvm-node-1" ListenerUrl="tcp://10.20.1.4:5022" -i 13-dag-repoint.sql
SET NOCOUNT ON;
IF NOT EXISTS (SELECT 1 FROM sys.availability_groups WHERE name = N'$(DagName)' AND is_distributed = 1)
    SELECT 'DAG_REPOINTED=$(DagName)|none (not on ' + @@SERVERNAME + ')';
ELSE IF EXISTS (
    SELECT 1 FROM sys.availability_replicas ar
    JOIN sys.availability_groups ag ON ag.group_id = ar.group_id
    WHERE ag.name = N'$(DagName)' AND ar.replica_server_name = N'$(MemberAg)' AND ar.endpoint_url = N'$(ListenerUrl)')
    SELECT 'DAG_REPOINTED=$(DagName)|already $(ListenerUrl)|' + @@SERVERNAME;
ELSE
BEGIN
    ALTER AVAILABILITY GROUP [$(DagName)]
        MODIFY AVAILABILITY GROUP ON N'$(MemberAg)' WITH (LISTENER_URL = N'$(ListenerUrl)');
    SELECT 'DAG_REPOINTED=$(DagName)|$(MemberAg)|$(ListenerUrl)|' + @@SERVERNAME;
END
