#!/usr/bin/env bash
# AG Phase 3 (run on the PRIMARY node only): create the Availability Group with both replicas
# defined. CLUSTER_TYPE = NONE means no Pacemaker/WSFC cluster manager - failover is manual
# (sqlvm-linux-ag.ps1 -Action failover / force-failover). Both nodes are in the same region, so
# BOTH replicas run SYNCHRONOUS_COMMIT: a commit is hardened on the secondary before it is
# acknowledged, and a planned failover loses no data. The primary still accepts writes while the
# secondary is down (REQUIRED_SYNCHRONIZED_SECONDARIES_TO_COMMIT stays 0 outside a failover).
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
    AVAILABILITY_MODE = SYNCHRONOUS_COMMIT,
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
        AVAILABILITY_MODE = SYNCHRONOUS_COMMIT,
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
