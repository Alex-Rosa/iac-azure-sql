#!/usr/bin/env bash
# AG Phase 4 (run on the SECONDARY node only): join the Availability Group that the primary
# just created, and grant it permission to auto-create seeded databases.
#
# Usage: sudo ./ag-04-join-secondary.sh '<SA_PASSWORD>' '<AG_NAME>'
set -euo pipefail

SA_PASSWORD="${1:?}"
AG_NAME="${2:?}"
SQLCMD=(/opt/mssql-tools18/bin/sqlcmd -S localhost -U SA -P "$SA_PASSWORD" -No -C -b)

"${SQLCMD[@]}" -Q "
IF NOT EXISTS (SELECT * FROM sys.availability_groups WHERE name = N'$AG_NAME')
  ALTER AVAILABILITY GROUP [$AG_NAME] JOIN WITH (CLUSTER_TYPE = NONE);
ALTER AVAILABILITY GROUP [$AG_NAME] GRANT CREATE ANY DATABASE;
"
echo "=== Phase 4 complete. This node joined Availability Group '$AG_NAME'. ==="
