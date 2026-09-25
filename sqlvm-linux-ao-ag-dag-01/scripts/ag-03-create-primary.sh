#!/usr/bin/env bash
# AG Phase 3 (run on the PRIMARY node only): create the Availability Group with both replicas
# defined. CLUSTER_TYPE = NONE means no Pacemaker/WSFC cluster manager - failover is manual,
# which is the right tradeoff for a cross-region pair (automatic failover across regions is
# generally not recommended anyway due to WAN latency and quorum complexity). The primary runs
# synchronous commit (same-region app writes get zero data loss); the secondary runs asynchronous
# commit across the WAN link.
#
# Usage: sudo ./ag-03-create-primary.sh '<SA_PASSWORD>' '<AG_NAME>' '<PRIMARY_NAME>' '<PRIMARY_PRIVATE_IP>' '<SECONDARY_NAME>' '<SECONDARY_PRIVATE_IP>'
set -euo pipefail

SA_PASSWORD="${1:?}"
AG_NAME="${2:?}"
PRI_NAME="${3:?}"
PRI_IP="${4:?}"
SEC_NAME="${5:?}"
SEC_IP="${6:?}"
SQLCMD=(/opt/mssql-tools18/bin/sqlcmd -S localhost -U SA -P "$SA_PASSWORD" -No -C -b)

"${SQLCMD[@]}" -Q "
IF NOT EXISTS (SELECT * FROM sys.availability_groups WHERE name = N'$AG_NAME')
CREATE AVAILABILITY GROUP [$AG_NAME]
WITH (CLUSTER_TYPE = NONE)
FOR REPLICA ON
  N'$PRI_NAME' WITH (
    ENDPOINT_URL = N'tcp://$PRI_IP:5022',
    AVAILABILITY_MODE = SYNCHRONOUS_COMMIT,
    FAILOVER_MODE = MANUAL,
    SEEDING_MODE = AUTOMATIC,
    SECONDARY_ROLE (ALLOW_CONNECTIONS = ALL)
  ),
  N'$SEC_NAME' WITH (
    ENDPOINT_URL = N'tcp://$SEC_IP:5022',
    AVAILABILITY_MODE = ASYNCHRONOUS_COMMIT,
    FAILOVER_MODE = MANUAL,
    SEEDING_MODE = AUTOMATIC,
    SECONDARY_ROLE (ALLOW_CONNECTIONS = ALL)
  );
ALTER AVAILABILITY GROUP [$AG_NAME] GRANT CREATE ANY DATABASE;
"

# AG already existed (resumed deploy, or a secondary that was removed and rebuilt): make sure the
# secondary replica is in it, and that its endpoint URL matches the node's current private IP
# (a rebuilt VM can get a different one). Only valid while this node holds the PRIMARY role.
"${SQLCMD[@]}" -Q "
IF EXISTS (
  SELECT 1 FROM sys.dm_hadr_availability_replica_states rs
  JOIN sys.availability_groups ag ON ag.group_id = rs.group_id
  WHERE ag.name = N'$AG_NAME' AND rs.is_local = 1 AND rs.role_desc = 'PRIMARY'
)
BEGIN
  IF NOT EXISTS (
    SELECT 1 FROM sys.availability_replicas ar
    JOIN sys.availability_groups ag ON ag.group_id = ar.group_id
    WHERE ag.name = N'$AG_NAME' AND ar.replica_server_name = N'$SEC_NAME'
  )
  BEGIN
    PRINT 'Re-adding secondary replica $SEC_NAME';
    ALTER AVAILABILITY GROUP [$AG_NAME] ADD REPLICA ON
      N'$SEC_NAME' WITH (
        ENDPOINT_URL = N'tcp://$SEC_IP:5022',
        AVAILABILITY_MODE = ASYNCHRONOUS_COMMIT,
        FAILOVER_MODE = MANUAL,
        SEEDING_MODE = AUTOMATIC,
        SECONDARY_ROLE (ALLOW_CONNECTIONS = ALL)
      );
  END
  ELSE
    ALTER AVAILABILITY GROUP [$AG_NAME] MODIFY REPLICA ON N'$SEC_NAME' WITH (ENDPOINT_URL = N'tcp://$SEC_IP:5022');
END
"
echo "=== Phase 3 complete. Availability Group '$AG_NAME' created, primary = $PRI_NAME. ==="
