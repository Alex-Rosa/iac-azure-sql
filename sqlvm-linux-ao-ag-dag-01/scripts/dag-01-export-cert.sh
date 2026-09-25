#!/usr/bin/env bash
# DAG Phase 1 (run on EVERY node of both AGs): print this node's public mirroring certificate
# (created by ag-01-endpoint.sh) as one base64 line, so the orchestrator can install it on the
# nodes of the OTHER availability group. A distributed AG connects the two AGs' endpoints
# directly, so each node must trust the certificates of all nodes in the other AG - any of them
# can become the global primary or the forwarder after a local failover.
#
# Usage: sudo ./dag-01-export-cert.sh '<SA_PASSWORD>'
set -euo pipefail

SA_PASSWORD="${1:?SA password required}"
CERT=/var/opt/mssql/data/dbm_certificate.cer

if [ ! -s "$CERT" ]; then
  # Re-export the public part if the file was removed (the private key isn't needed by peers).
  /opt/mssql-tools18/bin/sqlcmd -S localhost -U SA -P "$SA_PASSWORD" -No -C -b \
    -Q "BACKUP CERTIFICATE dbm_certificate TO FILE = N'$CERT';"
fi
echo "HOST=$(hostname)"
echo "CERT_B64=$(base64 -w0 "$CERT")"
