-- UC-02 | a node of the partitioned region | Restarts the mirroring endpoint so that its existing AG
-- connections drop now: NSG rules only affect NEW connections, the network partition would otherwise
-- only show when a connection is re-established.
-- sqlcmd -i 63-restart-endpoint.sql
SET NOCOUNT ON;
ALTER ENDPOINT [Hadr_endpoint] STATE = STOPPED;
WAITFOR DELAY '00:00:02';
ALTER ENDPOINT [Hadr_endpoint] STATE = STARTED;
SELECT 'ENDPOINT_RESTARTED=' + @@SERVERNAME;
