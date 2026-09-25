#!/usr/bin/env bash
# Installs SQL Server from a local RPM (already uploaded to /tmp) plus mssql-tools18, then
# configures the engine with Developer edition - required
# for Always On Availability Groups (Standard edition only supports Basic AGs, one DB, no
# readable secondary).
#
# Usage: sudo ./install-sqlserver.sh '<SA_PASSWORD>' '<ENGINE_RPM_FILENAME>'
set -euo pipefail

SA_PASSWORD="${1:?SA password required}"
ENGINE_RPM="${2:?engine RPM filename required, e.g. mssql-server-18.0.110.3-1.x86_64.rpm}"
HA_RPM="${3:-}"

echo "=== $(date) Installing SQL Server from local RPM ($ENGINE_RPM) ==="
dnf install -y wget curl openssl python3 glibc unixODBC 2>/dev/null || true

systemctl stop mssql-server 2>/dev/null || true
dnf remove mssql-server -y 2>/dev/null || true
rm -rf /var/opt/mssql/data/*

dnf localinstall -y "/tmp/$ENGINE_RPM"

if [ -n "$HA_RPM" ] && [ -f "/tmp/$HA_RPM" ]; then
  echo "--- Installing HA companion package ($HA_RPM), best-effort ---"
  # Not required by this deployment (CLUSTER_TYPE = NONE, no Pacemaker). Its 'resource-agents'
  # dependency lives in RHEL's HighAvailability repo channel, which isn't enabled on an
  # unregistered PAYG image - so a failure here is expected and must not abort the install.
  if ! dnf localinstall -y "/tmp/$HA_RPM"; then
    echo "WARNING: HA companion package install failed (likely missing 'resource-agents' from an" \
         "unregistered RHEL entitlement). Not required for CLUSTER_TYPE=NONE - continuing without it."
  fi
fi

echo "--- Installing sqlcmd tools ---"
curl -sSL "https://packages.microsoft.com/config/rhel/9/prod.repo" -o /etc/yum.repos.d/msprod.repo
ACCEPT_EULA=Y dnf install -y mssql-tools18 unixODBC-devel
echo 'export PATH="$PATH:/opt/mssql-tools18/bin"' > /etc/profile.d/mssql-tools.sh
export PATH="$PATH:/opt/mssql-tools18/bin"

echo "--- Configuring SQL Server (Developer edition - full feature set, non-production license) ---"
MSSQL_SA_PASSWORD="$SA_PASSWORD" MSSQL_PID='Developer' \
  /opt/mssql/bin/mssql-conf -n setup accept-eula

systemctl enable mssql-server
systemctl start mssql-server

echo "--- Waiting for SQL Server to be ready ---"
for i in $(seq 1 30); do
  if sqlcmd -S localhost -U SA -P "$SA_PASSWORD" -No -C -Q "SELECT 1" &>/dev/null; then
    echo "SQL Server is ready."
    break
  fi
  echo "  attempt $i/30 - waiting 5s..."
  sleep 5
done

firewall-cmd --permanent --add-port=1433/tcp 2>/dev/null || true
firewall-cmd --permanent --add-port=5022/tcp 2>/dev/null || true
firewall-cmd --reload 2>/dev/null || true

echo "--- SQL Server info ---"
sqlcmd -S localhost -U SA -P "$SA_PASSWORD" -No -C \
  -Q "SELECT SERVERPROPERTY('MachineName') AS Host, SERVERPROPERTY('ProductVersion') AS Version, SERVERPROPERTY('Edition') AS Edition"

echo "=== $(date) Install complete ==="
