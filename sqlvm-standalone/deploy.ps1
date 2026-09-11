<#
.SYNOPSIS
    Interactively deploys a standalone Azure SQL VM using main.bicep.

.DESCRIPTION
    Prompts for the required inputs (subscription, resource group, region,
    VM name/size, SQL edition/license, admin credentials, network access)
    then runs `az deployment group create` against main.bicep.

.NOTES
    Requires the Azure CLI (az) to be installed and available on PATH.
    Run with PowerShell 7+ (pwsh) on macOS/Linux/Windows.
#>

$ErrorActionPreference = 'Stop'

function Read-RequiredString {
    param(
        [string]$Prompt,
        [string]$Default
    )
    while ($true) {
        $suffix = if ($Default) { " [$Default]" } else { '' }
        $value = Read-Host "$Prompt$suffix"
        if ([string]::IsNullOrWhiteSpace($value) -and $Default) { return $Default }
        if (-not [string]::IsNullOrWhiteSpace($value)) { return $value }
        Write-Host 'A value is required.' -ForegroundColor Yellow
    }
}

function Read-YesNo {
    param(
        [string]$Prompt,
        [bool]$Default = $true
    )
    $hint = if ($Default) { 'Y/n' } else { 'y/N' }
    $value = Read-Host "$Prompt ($hint)"
    if ([string]::IsNullOrWhiteSpace($value)) { return $Default }
    return $value.Trim().ToLower() -in @('y', 'yes')
}

Write-Host '=== Azure SQL VM (standalone) deployment ===' -ForegroundColor Cyan

# --- Azure CLI login / subscription check ---
$account = az account show 2>$null | ConvertFrom-Json
if (-not $account) {
    Write-Host 'You are not logged in to Azure CLI. Launching az login...' -ForegroundColor Yellow
    az login | Out-Null
    $account = az account show | ConvertFrom-Json
}
Write-Host "Using subscription: $($account.name) ($($account.id))"
if (-not (Read-YesNo -Prompt 'Continue with this subscription?' -Default $true)) {
    $subId = Read-RequiredString -Prompt 'Enter the subscription ID to use'
    az account set --subscription $subId
    $account = az account show | ConvertFrom-Json
    Write-Host "Switched to subscription: $($account.name) ($($account.id))"
}

# --- Resource group ---
$resourceGroupName = Read-RequiredString -Prompt 'Resource group name'
$location = Read-RequiredString -Prompt 'Azure region' -Default 'eastus'

$rgExists = az group exists --name $resourceGroupName | ConvertFrom-Json
if (-not $rgExists) {
    Write-Host "Resource group '$resourceGroupName' does not exist. Creating it in $location..."
    az group create --name $resourceGroupName --location $location | Out-Null
} else {
    Write-Host "Resource group '$resourceGroupName' already exists; reusing it."
}

# --- VM basics ---
$vmName = Read-RequiredString -Prompt 'SQL VM name (max 15 characters)'
if ($vmName.Length -gt 15) {
    Write-Host 'VM name must be 15 characters or fewer.' -ForegroundColor Red
    exit 1
}
$vmSize = Read-RequiredString -Prompt 'VM size' -Default 'Standard_D4s_v5'

$adminUsername = Read-RequiredString -Prompt 'Admin username' -Default 'sqladmin'

$adminPassword = $null
while ($true) {
    $secure1 = Read-Host 'Admin password (min 12 chars, complex)' -AsSecureString
    $secure2 = Read-Host 'Confirm admin password' -AsSecureString
    $plain1 = [System.Runtime.InteropServices.Marshal]::PtrToStringAuto([System.Runtime.InteropServices.Marshal]::SecureStringToBSTR($secure1))
    $plain2 = [System.Runtime.InteropServices.Marshal]::PtrToStringAuto([System.Runtime.InteropServices.Marshal]::SecureStringToBSTR($secure2))
    if ($plain1 -ne $plain2) {
        Write-Host 'Passwords do not match. Try again.' -ForegroundColor Yellow
        continue
    }
    if ($plain1.Length -lt 12) {
        Write-Host 'Password must be at least 12 characters.' -ForegroundColor Yellow
        continue
    }
    $adminPassword = $plain1
    break
}

# --- SQL edition / licensing ---
Write-Host "`nSQL Server editions: standard, enterprise, developer, express"
$sqlSku = Read-RequiredString -Prompt 'SQL Server edition' -Default 'standard'

Write-Host "`nLicense type: PAYG (pay-as-you-go) or AHUB (Azure Hybrid Benefit - bring your own license)"
$sqlServerLicenseType = Read-RequiredString -Prompt 'SQL Server license type' -Default 'PAYG'

# --- Networking ---
$deployPublicIp = Read-YesNo -Prompt 'Deploy a public IP for this VM?' -Default $true
$enableSqlPublicAccess = Read-YesNo -Prompt 'Allow SQL Server (port 1433) traffic from the internet/allowed IP?' -Default $false

$detectedIp = $null
try {
    $detectedIp = (Invoke-RestMethod -Uri 'https://api.ipify.org' -TimeoutSec 5).Trim()
} catch {
    $detectedIp = $null
}
$defaultIp = if ($detectedIp) { "$detectedIp/32" } else { '*' }
$allowedSourceIpAddress = Read-RequiredString -Prompt 'Source IP/CIDR allowed for RDP (and SQL if enabled) - use your own public IP' -Default $defaultIp

# --- Summary ---
Write-Host "`n=== Deployment summary ===" -ForegroundColor Cyan
Write-Host "Subscription:        $($account.name)"
Write-Host "Resource group:      $resourceGroupName"
Write-Host "Location:            $location"
Write-Host "VM name:             $vmName"
Write-Host "VM size:             $vmSize"
Write-Host "Admin username:      $adminUsername"
Write-Host "SQL edition:         $sqlSku"
Write-Host "SQL license type:    $sqlServerLicenseType"
Write-Host "Public IP:           $deployPublicIp"
Write-Host "SQL public access:   $enableSqlPublicAccess"
Write-Host "Allowed source IP:   $allowedSourceIpAddress"

if (-not (Read-YesNo -Prompt "`nProceed with deployment?" -Default $true)) {
    Write-Host 'Deployment cancelled.' -ForegroundColor Yellow
    exit 0
}

# --- Deploy ---
$scriptDir = Split-Path -Parent $MyInvocation.MyCommand.Path
$bicepFile = Join-Path $scriptDir 'main.bicep'
$deploymentName = "$vmName-$(Get-Date -Format 'yyyyMMddHHmmss')"

Write-Host "`nStarting deployment '$deploymentName'... this can take 15-30 minutes." -ForegroundColor Cyan

az deployment group create `
    --name $deploymentName `
    --resource-group $resourceGroupName `
    --template-file $bicepFile `
    --parameters `
        vmName=$vmName `
        vmSize=$vmSize `
        adminUsername=$adminUsername `
        adminPassword=$adminPassword `
        sqlSku=$sqlSku `
        sqlServerLicenseType=$sqlServerLicenseType `
        deployPublicIp=$deployPublicIp `
        enableSqlPublicAccess=$enableSqlPublicAccess `
        allowedSourceIpAddress=$allowedSourceIpAddress

if ($LASTEXITCODE -eq 0) {
    Write-Host "`nDeployment complete." -ForegroundColor Green
    az deployment group show --name $deploymentName --resource-group $resourceGroupName --query properties.outputs
} else {
    Write-Host "`nDeployment failed. Review the errors above." -ForegroundColor Red
    exit $LASTEXITCODE
}
