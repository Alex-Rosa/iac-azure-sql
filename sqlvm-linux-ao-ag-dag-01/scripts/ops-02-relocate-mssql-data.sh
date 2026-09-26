#!/usr/bin/env bash
# Moves SQL Server's data folder (/var/opt/mssql/data: every database's data AND log files) to the data
# disk: copies it to /sqldata/mssql-data and bind-mounts that back on /var/opt/mssql/data. SQL Server's
# own file paths don't change, so nothing in SQL Server (or in the AGs) has to be altered. SQL Server is
# stopped for the copy - a primary replica's databases are unavailable meanwhile. Idempotent.
# Usage: sudo ./ops-02-relocate-mssql-data.sh '<SA_PASSWORD>'
set -euo pipefail
SA_PASSWORD="${1:?SA password required}"
SRC=/var/opt/mssql/data
DST=/sqldata/mssql-data
SQLCMD=(/opt/mssql-tools18/bin/sqlcmd -S localhost -U SA -P "$SA_PASSWORD" -No -C -b -W -h -1)

mountpoint -q /sqldata || { echo "ERROR=/sqldata is not mounted (run ops-01-mount-data-disk.sh first)"; exit 1; }
if mountpoint -q "$SRC"; then
  echo "RELOCATED=already ($(findmnt -no SOURCE "$SRC"))"
  exit 0
fi
need=$(du -sm "$SRC" | cut -f1)
free=$(df -m --output=avail /sqldata | tail -1 | tr -d ' ')
echo "DATA_MB=$need"
if [ "$free" -le $((need * 2)) ]; then echo "ERROR=not enough room on /sqldata ($free MB free for $need MB)"; exit 1; fi

wait_sql() {
  for i in $(seq 1 60); do
    if "${SQLCMD[@]}" -Q "SET NOCOUNT ON; SELECT 1" >/dev/null 2>&1; then return 0; fi
    sleep 3
  done
  return 1
}

systemctl stop mssql-server
mkdir -p "$DST"
rsync -aHAX --delete "$SRC/" "$DST/"
chown mssql:mssql "$DST"
chmod --reference="$SRC" "$DST"
mv "$SRC" "$SRC.pre-sqldata"
mkdir "$SRC"
chown mssql:mssql "$SRC"
chmod --reference="$SRC.pre-sqldata" "$SRC"
mount --bind "$DST" "$SRC"
sed -i "\# $SRC #d" /etc/fstab
echo "$DST $SRC none bind,nofail,x-systemd.requires-mounts-for=/sqldata 0 0" >> /etc/fstab
systemctl daemon-reload || true
if command -v restorecon >/dev/null 2>&1; then restorecon -R "$SRC" || true; fi
systemctl start mssql-server

if ! wait_sql; then
  echo "ROLLBACK=SQL Server didn't come back on the data disk - restoring the original folder"
  systemctl stop mssql-server || true
  umount "$SRC" || true
  sed -i "\# $SRC #d" /etc/fstab
  rmdir "$SRC"
  mv "$SRC.pre-sqldata" "$SRC"
  systemctl start mssql-server
  wait_sql || true
  echo "ERROR=relocation rolled back"
  exit 1
fi

"${SQLCMD[@]}" -Q "SET NOCOUNT ON; SELECT 'DB=' + name + '|' + state_desc COLLATE DATABASE_DEFAULT FROM sys.databases WHERE database_id > 4;
SELECT 'AG_ROLE=' + ag.name + '|' + rs.role_desc COLLATE DATABASE_DEFAULT FROM sys.dm_hadr_availability_replica_states rs JOIN sys.availability_groups ag ON ag.group_id = rs.group_id WHERE rs.is_local = 1;"
rm -rf "$SRC.pre-sqldata"
df -m --output=size,avail / /var "$SRC" 2>/dev/null | tail -n +2 | awk '{print "SPACE_MB=" $1 "|" $2}'
echo "RELOCATED=1"
