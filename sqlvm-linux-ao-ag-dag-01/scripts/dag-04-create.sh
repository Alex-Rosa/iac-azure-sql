#!/usr/bin/env bash
# DAG Phase 4 (run on the GLOBAL PRIMARY: the primary replica of the primary AG): create the
# distributed AG. With CLUSTER_TYPE = NONE there's no listener, so each member AG's LISTENER_URL
# is its current PRIMARY replica's endpoint (Microsoft's guidance for AGs without a cluster
# manager). After a local failover inside a member AG, the URL must be updated on both sides.
#
# Usage: sudo ./dag-04-create.sh '<SA_PASSWORD>' '<DAG_NAME>' '<PRIMARY_AG>' '<PRIMARY_AG_URL>' '<FORWARDER_AG>' '<FORWARDER_AG_URL>'
set -euo pipefail

SA_PASSWORD="${1:?}"
DAG_NAME="${2:?}"
AG1="${3:?}"
AG1_URL="${4:?}"
AG2="${5:?}"
AG2_URL="${6:?}"
SQLCMD=(/opt/mssql-tools18/bin/sqlcmd -S localhost -U SA -P "$SA_PASSWORD" -No -C -b -W -h -1)

"${SQLCMD[@]}" -Q "
SET NOCOUNT ON;
IF NOT EXISTS (SELECT 1 FROM sys.dm_hadr_availability_replica_states rs JOIN sys.availability_groups ag ON ag.group_id = rs.group_id
               WHERE ag.name = N'$AG1' AND rs.is_local = 1 AND rs.role_desc = 'PRIMARY')
    THROW 50001, 'This node is not the PRIMARY replica of $AG1 - run on the global primary.', 1;
IF NOT EXISTS (SELECT 1 FROM sys.availability_groups WHERE name = N'$DAG_NAME')
BEGIN
    CREATE AVAILABILITY GROUP [$DAG_NAME]
       WITH (DISTRIBUTED)
       AVAILABILITY GROUP ON
          N'$AG1' WITH (LISTENER_URL = N'$AG1_URL', AVAILABILITY_MODE = ASYNCHRONOUS_COMMIT, FAILOVER_MODE = MANUAL, SEEDING_MODE = AUTOMATIC),
          N'$AG2' WITH (LISTENER_URL = N'$AG2_URL', AVAILABILITY_MODE = ASYNCHRONOUS_COMMIT, FAILOVER_MODE = MANUAL, SEEDING_MODE = AUTOMATIC);
    SELECT 'DAG_CREATED=1';
END
ELSE
    SELECT 'DAG_CREATED=0 (already exists)';"
