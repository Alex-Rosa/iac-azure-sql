#!/usr/bin/env bash
# AG Phase 5 (run on the PRIMARY node only): create a small demo database, put it in FULL
# recovery model, take the one full backup Always On requires before a database can be added
# to an AG, then add it - automatic seeding replicates it to the secondary with no manual
# backup/restore needed on that side.
#
# Usage: sudo ./ag-05-create-demo-db.sh '<SA_PASSWORD>' '<AG_NAME>' '<DB_NAME>'
set -euo pipefail

SA_PASSWORD="${1:?}"
AG_NAME="${2:?}"
DB_NAME="${3:?}"
SQLCMD=(/opt/mssql-tools18/bin/sqlcmd -S localhost -U SA -P "$SA_PASSWORD" -No -C -b)

"${SQLCMD[@]}" -Q "
IF NOT EXISTS (SELECT * FROM sys.databases WHERE name = N'$DB_NAME')
BEGIN
  CREATE DATABASE [$DB_NAME];
  ALTER DATABASE [$DB_NAME] SET RECOVERY FULL;
END
"

"${SQLCMD[@]}" -d "$DB_NAME" -Q "
IF OBJECT_ID('dbo.AGHeartbeat') IS NULL
BEGIN
  CREATE TABLE dbo.AGHeartbeat (
    id INT IDENTITY PRIMARY KEY,
    inserted_at_utc DATETIME2 DEFAULT SYSUTCDATETIME(),
    inserted_by_host NVARCHAR(64) DEFAULT HOST_NAME()
  );
END
INSERT INTO dbo.AGHeartbeat DEFAULT VALUES;
"

"${SQLCMD[@]}" -Q "BACKUP DATABASE [$DB_NAME] TO DISK = N'/var/opt/mssql/data/${DB_NAME}.bak';"

"${SQLCMD[@]}" -Q "
IF NOT EXISTS (
  SELECT 1 FROM sys.dm_hadr_database_replica_states rs
  JOIN sys.databases d ON d.database_id = rs.database_id
  WHERE d.name = N'$DB_NAME'
)
  ALTER AVAILABILITY GROUP [$AG_NAME] ADD DATABASE [$DB_NAME];
"
echo "=== Phase 5 complete. Database '$DB_NAME' added to AG '$AG_NAME'. ==="
