#!/usr/bin/env bash
# AG Phase 2 (run on BOTH nodes, after certs have been cross-copied): trust the peer node's
# certificate so this node's endpoint will authenticate it. Expects the peer's public cert to
# already be uploaded to /tmp/peer_dbm_certificate.cer.
#
# Usage: sudo ./ag-02-trust-peer.sh '<SA_PASSWORD>' '<PEER_REPLICA_NAME>' '<PEER_LOGIN_PASSWORD>'
set -euo pipefail

SA_PASSWORD="${1:?SA password required}"
PEER_NAME="${2:?Peer replica name required}"
PEER_LOGIN_PASSWORD="${3:?Peer login password required}"
SQLCMD=(/opt/mssql-tools18/bin/sqlcmd -S localhost -U SA -P "$SA_PASSWORD" -No -C -b)
PEER_CERT=/tmp/peer_dbm_certificate.cer

if [ ! -f "$PEER_CERT" ]; then
  echo "Missing $PEER_CERT - copy the peer node's dbm_certificate.cer here first." >&2
  exit 1
fi

# A peer that was removed and rebuilt (sqlvm-linux-ag.ps1 -Action remove -RemoveScope secondary, then
# deploy) comes back with a brand-new certificate under the same replica name. The IF NOT EXISTS
# below would keep trusting the old one and the endpoint handshake would fail, so drop the
# stored certificate when its SHA-1 thumbprint no longer matches the uploaded file.
PEER_THUMB=$(openssl x509 -inform DER -in "$PEER_CERT" -noout -fingerprint -sha1 2>/dev/null \
  | cut -d= -f2 | tr -d ':' | tr '[:lower:]' '[:upper:]' || true)
CUR_THUMB=$("${SQLCMD[@]}" -h -1 -Q "SET NOCOUNT ON; SELECT CONVERT(varchar(64), thumbprint, 2) FROM sys.certificates WHERE name = N'${PEER_NAME}_cert'" | tr -d '[:space:]')
if [ -n "$PEER_THUMB" ] && [ -n "$CUR_THUMB" ] && [ "$PEER_THUMB" != "$CUR_THUMB" ]; then
  echo "=== Peer '$PEER_NAME' presents a new certificate (node rebuilt) - replacing ${PEER_NAME}_cert ==="
  "${SQLCMD[@]}" -Q "DROP CERTIFICATE [${PEER_NAME}_cert];"
fi

"${SQLCMD[@]}" -Q "
IF NOT EXISTS (SELECT * FROM sys.server_principals WHERE name = N'$PEER_NAME')
  CREATE LOGIN [$PEER_NAME] WITH PASSWORD = N'$PEER_LOGIN_PASSWORD';
IF NOT EXISTS (SELECT * FROM sys.database_principals WHERE name = N'$PEER_NAME')
  CREATE USER [$PEER_NAME] FOR LOGIN [$PEER_NAME];
IF NOT EXISTS (SELECT * FROM sys.certificates WHERE name = N'${PEER_NAME}_cert')
  CREATE CERTIFICATE [${PEER_NAME}_cert]
    AUTHORIZATION [$PEER_NAME]
    FROM FILE = N'$PEER_CERT';
GRANT CONNECT ON ENDPOINT::[Hadr_endpoint] TO [$PEER_NAME];
"
echo "=== Phase 2 complete. Trust established for peer replica '$PEER_NAME'. ==="
