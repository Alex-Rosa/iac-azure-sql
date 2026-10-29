#!/usr/bin/env bash
# One step of a failover with CLUSTER_TYPE = NONE (no cluster manager: sqlvm-linux-ag.ps1 drives
# the steps across the two nodes through 'az vm run-command'). Prints STEP_DONE=<step> on success.
#
# Planned failover without data loss (Microsoft's procedure for CLUSTER_TYPE = NONE):
#   current primary : prepare        both replicas SYNCHRONOUS_COMMIT, REQUIRED_SYNCHRONIZED_SECONDARIES_TO_COMMIT = 1
#   (orchestrator)  : wait until the target reports every database SYNCHRONIZED
#   current primary : offline        stop writes before the role change
#   target          : promote        FORCE_FAILOVER_ALLOW_DATA_LOSS (no loss: the target is synchronized)
#   old primary     : demote         SET (ROLE = SECONDARY)
#   both            : resume         SET HADR RESUME on every suspended local database
#   new primary     : commit-gate 0  writes no longer wait for a synchronized secondary
#
# Forced failover (primary lost): promote on the target, later demote + resume on the old primary.
#
# Other steps:
#   remove-replica <name>   (primary) take a replica out of the AG, e.g. before deleting its node
#
# Usage: sudo ./ag-09-failover-step.sh '<SA_PASSWORD>' '<AG_NAME>' '<STEP>' ['<ARG>']
set -euo pipefail

SA_PASSWORD="${1:?SA password required}"
AG_NAME="${2:?AG name required}"
STEP="${3:?step required}"
ARG="${4:-}"
SQLCMD=(/opt/mssql-tools18/bin/sqlcmd -S localhost -U SA -P "$SA_PASSWORD" -No -C -b -W -h -1)

local_role() {
  "${SQLCMD[@]}" -Q "SET NOCOUNT ON; SELECT ISNULL((SELECT rs.role_desc FROM sys.dm_hadr_availability_replica_states rs
    JOIN sys.availability_groups ag ON ag.group_id = rs.group_id WHERE ag.name = N'$AG_NAME' AND rs.is_local = 1), 'NONE')" | tr -d '[:space:]'
}

case "$STEP" in
  prepare)
    "${SQLCMD[@]}" -Q "
SET NOCOUNT ON;
DECLARE @r sysname, @sql nvarchar(400);
DECLARE c CURSOR LOCAL FAST_FORWARD FOR
  SELECT ar.replica_server_name FROM sys.availability_replicas ar
  JOIN sys.availability_groups ag ON ag.group_id = ar.group_id
  WHERE ag.name = N'$AG_NAME' AND ar.availability_mode_desc <> 'SYNCHRONOUS_COMMIT';
OPEN c; FETCH NEXT FROM c INTO @r;
WHILE @@FETCH_STATUS = 0
BEGIN
  SET @sql = N'ALTER AVAILABILITY GROUP [$AG_NAME] MODIFY REPLICA ON N''' + @r + N''' WITH (AVAILABILITY_MODE = SYNCHRONOUS_COMMIT);';
  EXEC (@sql);
  SELECT 'MADE_SYNC=' + @r;
  FETCH NEXT FROM c INTO @r;
END
CLOSE c; DEALLOCATE c;
ALTER AVAILABILITY GROUP [$AG_NAME] SET (REQUIRED_SYNCHRONIZED_SECONDARIES_TO_COMMIT = 1);
"
    ;;
  offline)
    "${SQLCMD[@]}" -Q "ALTER AVAILABILITY GROUP [$AG_NAME] OFFLINE;"
    ;;
  promote)
    "${SQLCMD[@]}" -Q "ALTER AVAILABILITY GROUP [$AG_NAME] FORCE_FAILOVER_ALLOW_DATA_LOSS;"
    echo "PROMOTED=$(hostname)"
    ;;
  demote)
    ROLE=$(local_role)
    if [ "$ROLE" = "SECONDARY" ]; then
      echo "DEMOTE_SKIPPED=already SECONDARY"
    else
      "${SQLCMD[@]}" -Q "ALTER AVAILABILITY GROUP [$AG_NAME] SET (ROLE = SECONDARY);"
      echo "DEMOTED=$(hostname)|was $ROLE"
    fi
    ;;
  resume)
    "${SQLCMD[@]}" -Q "
SET NOCOUNT ON;
DECLARE @db sysname, @sql nvarchar(400);
DECLARE c CURSOR LOCAL FAST_FORWARD FOR
  SELECT d.name FROM sys.dm_hadr_database_replica_states drs
  JOIN sys.databases d ON d.database_id = drs.database_id
  WHERE drs.is_local = 1 AND drs.is_suspended = 1;
OPEN c; FETCH NEXT FROM c INTO @db;
WHILE @@FETCH_STATUS = 0
BEGIN
  SET @sql = N'ALTER DATABASE ' + QUOTENAME(@db) + N' SET HADR RESUME;';
  BEGIN TRY EXEC (@sql); SELECT 'RESUMED=' + @db; END TRY
  BEGIN CATCH SELECT 'RESUME_FAILED=' + @db + '|' + LEFT(ERROR_MESSAGE(), 200); END CATCH
  FETCH NEXT FROM c INTO @db;
END
CLOSE c; DEALLOCATE c;
"
    ;;
  commit-gate)
    N="${ARG:-0}"
    "${SQLCMD[@]}" -Q "ALTER AVAILABILITY GROUP [$AG_NAME] SET (REQUIRED_SYNCHRONIZED_SECONDARIES_TO_COMMIT = $N);"
    echo "REQUIRED_SYNC=$N"
    ;;
  remove-replica)
    [ -n "$ARG" ] || { echo "ERROR=replica name required"; exit 1; }
    "${SQLCMD[@]}" -Q "
SET NOCOUNT ON;
IF EXISTS (SELECT 1 FROM sys.availability_replicas ar JOIN sys.availability_groups ag ON ag.group_id = ar.group_id
           WHERE ag.name = N'$AG_NAME' AND ar.replica_server_name = N'$ARG')
BEGIN
  ALTER AVAILABILITY GROUP [$AG_NAME] REMOVE REPLICA ON N'$ARG';
  SELECT 'REMOVED_REPLICA=$ARG';
END
ELSE SELECT 'REMOVED_REPLICA=not in AG';
"
    ;;
  *)
    echo "ERROR=unknown step '$STEP'"
    exit 1
    ;;
esac
echo "STEP_DONE=$STEP"
