#!/usr/bin/env bash
# AG Phase 1 (run on BOTH nodes independently): enable Always On, create a master key +
# self-signed certificate, and stand up the database-mirroring endpoint used for AG traffic.
# Stages this node's public certificate at /tmp/dbm_certificate.cer so the orchestrator can
# copy it to the peer node (certificate-based endpoint auth - simplest option for two
# standalone RHEL boxes that aren't domain-joined / don't share Kerberos).
#
# Usage: sudo ./ag-01-endpoint.sh '<SA_PASSWORD>' '<CERT_PASSWORD>'
set -euo pipefail

SA_PASSWORD="${1:?SA password required}"
CERT_PASSWORD="${2:?Certificate password required}"
SQLCMD=(/opt/mssql-tools18/bin/sqlcmd -S localhost -U SA -P "$SA_PASSWORD" -No -C -b)

HADR_ENABLED=$("${SQLCMD[@]}" -h -1 -Q "SET NOCOUNT ON; SELECT ISNULL(SERVERPROPERTY('IsHadrEnabled'), 0)" | tr -d '[:space:]')

if [ "$HADR_ENABLED" = "1" ]; then
  echo "=== Always On (HADR) already enabled - skipping restart ==="
else
  echo "=== Enabling Always On (HADR) ==="
  /opt/mssql/bin/mssql-conf set hadr.hadrenabled 1
  systemctl restart mssql-server
  for i in $(seq 1 30); do
    "${SQLCMD[@]}" -Q "SELECT 1" &>/dev/null && break
    sleep 5
  done
fi

echo "=== Creating master key + mirroring certificate ==="
"${SQLCMD[@]}" -Q "
IF NOT EXISTS (SELECT * FROM sys.symmetric_keys WHERE name = '##MS_DatabaseMasterKey##')
  CREATE MASTER KEY ENCRYPTION BY PASSWORD = N'$CERT_PASSWORD';
IF NOT EXISTS (SELECT * FROM sys.certificates WHERE name = 'dbm_certificate')
  CREATE CERTIFICATE dbm_certificate WITH SUBJECT = 'dbm_certificate';
"

rm -f /var/opt/mssql/data/dbm_certificate.cer /var/opt/mssql/data/dbm_certificate.pvk
"${SQLCMD[@]}" -Q "
BACKUP CERTIFICATE dbm_certificate
  TO FILE = N'/var/opt/mssql/data/dbm_certificate.cer'
  WITH PRIVATE KEY (
    FILE = N'/var/opt/mssql/data/dbm_certificate.pvk',
    ENCRYPTION BY PASSWORD = N'$CERT_PASSWORD'
  );
"

echo "=== Creating HADR endpoint (TCP 5022) ==="
"${SQLCMD[@]}" -Q "
IF NOT EXISTS (SELECT * FROM sys.tcp_endpoints WHERE name = 'Hadr_endpoint')
  CREATE ENDPOINT [Hadr_endpoint]
    AS TCP (LISTENER_PORT = 5022)
    FOR DATABASE_MIRRORING (ROLE = ALL, AUTHENTICATION = CERTIFICATE dbm_certificate, ENCRYPTION = REQUIRED ALGORITHM AES);
ALTER ENDPOINT [Hadr_endpoint] STATE = STARTED;
"

cp /var/opt/mssql/data/dbm_certificate.cer /tmp/dbm_certificate.cer
chmod 644 /tmp/dbm_certificate.cer
echo "=== Phase 1 complete. Public cert staged at /tmp/dbm_certificate.cer for exchange. ==="
