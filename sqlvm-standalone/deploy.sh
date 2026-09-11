#!/usr/bin/env bash
# Interactively deploys a standalone Azure SQL VM using main.bicep.
# Requires: Azure CLI (az).

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
BICEP_FILE="$SCRIPT_DIR/main.bicep"

prompt_required() {
    local prompt="$1" default="${2:-}" value
    while true; do
        if [[ -n "$default" ]]; then
            read -r -p "$prompt [$default]: " value
            value="${value:-$default}"
        else
            read -r -p "$prompt: " value
        fi
        if [[ -n "$value" ]]; then
            echo "$value"
            return
        fi
        echo "A value is required." >&2
    done
}

prompt_yesno() {
    local prompt="$1" default="${2:-y}" hint value
    [[ "$default" == "y" ]] && hint="Y/n" || hint="y/N"
    read -r -p "$prompt ($hint): " value
    value="${value:-$default}"
    [[ "${value,,}" == "y" || "${value,,}" == "yes" ]] && echo "true" || echo "false"
}

echo "=== Azure SQL VM (standalone) deployment ==="

if ! command -v az >/dev/null 2>&1; then
    echo "Azure CLI (az) is not installed or not on PATH." >&2
    exit 1
fi

# --- Login / subscription check ---
if ! ACCOUNT_JSON=$(az account show 2>/dev/null); then
    echo "You are not logged in to Azure CLI. Launching az login..."
    az login >/dev/null
    ACCOUNT_JSON=$(az account show)
fi
ACCOUNT_NAME=$(echo "$ACCOUNT_JSON" | grep -o '"name": *"[^"]*"' | head -1 | cut -d'"' -f4)
ACCOUNT_ID=$(echo "$ACCOUNT_JSON" | grep -o '"id": *"[^"]*"' | head -1 | cut -d'"' -f4)
echo "Using subscription: $ACCOUNT_NAME ($ACCOUNT_ID)"
if [[ "$(prompt_yesno 'Continue with this subscription?' y)" == "false" ]]; then
    SUB_ID=$(prompt_required "Enter the subscription ID to use")
    az account set --subscription "$SUB_ID"
    ACCOUNT_JSON=$(az account show)
    ACCOUNT_NAME=$(echo "$ACCOUNT_JSON" | grep -o '"name": *"[^"]*"' | head -1 | cut -d'"' -f4)
fi

# --- Resource group ---
RESOURCE_GROUP=$(prompt_required "Resource group name")
LOCATION=$(prompt_required "Azure region" "eastus")

if [[ "$(az group exists --name "$RESOURCE_GROUP")" == "false" ]]; then
    echo "Resource group '$RESOURCE_GROUP' does not exist. Creating it in $LOCATION..."
    az group create --name "$RESOURCE_GROUP" --location "$LOCATION" >/dev/null
else
    echo "Resource group '$RESOURCE_GROUP' already exists; reusing it."
fi

# --- VM basics ---
VM_NAME=$(prompt_required "SQL VM name (max 15 characters)")
if [[ ${#VM_NAME} -gt 15 ]]; then
    echo "VM name must be 15 characters or fewer." >&2
    exit 1
fi
VM_SIZE=$(prompt_required "VM size" "Standard_D4s_v5")
ADMIN_USERNAME=$(prompt_required "Admin username" "sqladmin")

while true; do
    read -r -s -p "Admin password (min 12 chars, complex): " PASS1; echo
    read -r -s -p "Confirm admin password: " PASS2; echo
    if [[ "$PASS1" != "$PASS2" ]]; then
        echo "Passwords do not match. Try again." >&2
        continue
    fi
    if [[ ${#PASS1} -lt 12 ]]; then
        echo "Password must be at least 12 characters." >&2
        continue
    fi
    ADMIN_PASSWORD="$PASS1"
    break
done

# --- SQL edition / licensing ---
echo
echo "SQL Server editions: standard, enterprise, developer, express"
SQL_SKU=$(prompt_required "SQL Server edition" "standard")

echo
echo "License type: PAYG (pay-as-you-go) or AHUB (Azure Hybrid Benefit)"
SQL_LICENSE_TYPE=$(prompt_required "SQL Server license type" "PAYG")

# --- Networking ---
DEPLOY_PUBLIC_IP=$(prompt_yesno "Deploy a public IP for this VM?" y)
ENABLE_SQL_PUBLIC_ACCESS=$(prompt_yesno "Allow SQL Server (port 1433) traffic from the internet/allowed IP?" n)

DETECTED_IP=$(curl -s --max-time 5 https://api.ipify.org || true)
DEFAULT_IP="*"
[[ -n "$DETECTED_IP" ]] && DEFAULT_IP="${DETECTED_IP}/32"
ALLOWED_SOURCE_IP=$(prompt_required "Source IP/CIDR allowed for RDP (and SQL if enabled) - use your own public IP" "$DEFAULT_IP")

# --- Summary ---
echo
echo "=== Deployment summary ==="
echo "Subscription:        $ACCOUNT_NAME"
echo "Resource group:      $RESOURCE_GROUP"
echo "Location:            $LOCATION"
echo "VM name:              $VM_NAME"
echo "VM size:              $VM_SIZE"
echo "Admin username:       $ADMIN_USERNAME"
echo "SQL edition:          $SQL_SKU"
echo "SQL license type:     $SQL_LICENSE_TYPE"
echo "Public IP:            $DEPLOY_PUBLIC_IP"
echo "SQL public access:    $ENABLE_SQL_PUBLIC_ACCESS"
echo "Allowed source IP:    $ALLOWED_SOURCE_IP"
echo

if [[ "$(prompt_yesno 'Proceed with deployment?' y)" == "false" ]]; then
    echo "Deployment cancelled."
    exit 0
fi

DEPLOYMENT_NAME="${VM_NAME}-$(date +%Y%m%d%H%M%S)"

echo
echo "Starting deployment '$DEPLOYMENT_NAME'... this can take 15-30 minutes."

az deployment group create \
    --name "$DEPLOYMENT_NAME" \
    --resource-group "$RESOURCE_GROUP" \
    --template-file "$BICEP_FILE" \
    --parameters \
        vmName="$VM_NAME" \
        vmSize="$VM_SIZE" \
        adminUsername="$ADMIN_USERNAME" \
        adminPassword="$ADMIN_PASSWORD" \
        sqlSku="$SQL_SKU" \
        sqlServerLicenseType="$SQL_LICENSE_TYPE" \
        deployPublicIp="$DEPLOY_PUBLIC_IP" \
        enableSqlPublicAccess="$ENABLE_SQL_PUBLIC_ACCESS" \
        allowedSourceIpAddress="$ALLOWED_SOURCE_IP"

echo
echo "Deployment complete."
az deployment group show --name "$DEPLOYMENT_NAME" --resource-group "$RESOURCE_GROUP" --query properties.outputs
