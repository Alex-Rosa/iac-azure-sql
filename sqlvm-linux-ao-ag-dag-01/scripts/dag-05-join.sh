#!/usr/bin/env bash
# DAG Phase 5 (run on the FORWARDER: the primary replica of the secondary AG): join the
# distributed AG created on the global primary; automatic seeding uses the local AG's CREATE ANY
# DATABASE permission.
#
# Usage: sudo ./dag-05-join.sh '<SA_PASSWORD>' '<DAG_NAME>' '<PRIMARY_AG>' '<PRIMARY_AG_URL>' '<FORWARDER_AG>' '<FORWARDER_AG_URL>'
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
IF NOT EXISTS (SELECT 1 FROM sys.availability_groups WHERE name = N'$DAG_NAME')
BEGIN
    ALTER AVAILABILITY GROUP [$DAG_NAME]
       JOIN
       AVAILABILITY GROUP ON
          N'$AG1' WITH (LISTENER_URL = N'$AG1_URL', AVAILABILITY_MODE = ASYNCHRONOUS_COMMIT, FAILOVER_MODE = MANUAL, SEEDING_MODE = AUTOMATIC),
          N'$AG2' WITH (LISTENER_URL = N'$AG2_URL', AVAILABILITY_MODE = ASYNCHRONOUS_COMMIT, FAILOVER_MODE = MANUAL, SEEDING_MODE = AUTOMATIC);
    SELECT 'DAG_JOINED=1';
END
ELSE
    SELECT 'DAG_JOINED=0 (already joined)';
-- Automatic seeding into the forwarder uses the LOCAL AG's permission (a distributed AG doesn't
-- accept GRANT CREATE ANY DATABASE itself - Msg 15151).
ALTER AVAILABILITY GROUP [$AG2] GRANT CREATE ANY DATABASE;"
