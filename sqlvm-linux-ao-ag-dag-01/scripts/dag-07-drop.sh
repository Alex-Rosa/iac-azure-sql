#!/usr/bin/env bash
# DAG removal (run on the global primary AND on the forwarder): drop the distributed AG. The member
# AGs keep running; the forwarder's databases stay behind in RESTORING state.
#
# Usage: sudo ./dag-07-drop.sh '<SA_PASSWORD>' '<DAG_NAME>'
set -euo pipefail

SA_PASSWORD="${1:?}"
DAG_NAME="${2:?}"
/opt/mssql-tools18/bin/sqlcmd -S localhost -U SA -P "$SA_PASSWORD" -No -C -b -W -h -1 -Q "
SET NOCOUNT ON;
IF EXISTS (SELECT 1 FROM sys.availability_groups WHERE name = N'$DAG_NAME' AND is_distributed = 1)
BEGIN
    DROP AVAILABILITY GROUP [$DAG_NAME];
    SELECT 'DAG_DROPPED=' + @@SERVERNAME;
END
ELSE
    SELECT 'DAG_DROPPED=0 (not present on ' + @@SERVERNAME + ')';"
