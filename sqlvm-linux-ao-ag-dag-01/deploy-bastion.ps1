#Requires -Version 7.0
<#
.SYNOPSIS
    Optional: adds (or removes) Azure Bastion to a stack created by deploy.ps1, and opens
    SQL/SSH sessions through it.

.DESCRIPTION
    Asks for anything not passed on the command line: action, unique identifier, primary/secondary node suffix
    (the same ones used with deploy.ps1) and, for tunnel-sql/ssh, which node. Regions and VNet
    address spaces are read from the live VNets, so Bastion always lands next to the nodes.

.EXAMPLE
    ./deploy-bastion.ps1 -Action deploy -PrimaryNodeSuffix node-1 -SecondaryNodeSuffix node-2

.EXAMPLE
    ./deploy-bastion.ps1 -Action tunnel-sql -PrimaryNodeSuffix node-1 -SecondaryNodeSuffix node-2 -Node primary -LocalPort 11433
#>
param(
    [ValidateSet('', 'deploy', 'remove', 'tunnel-sql', 'ssh', 'status')]
    [string]$Action = '',

    [string]$PrimaryNodeSuffix   = '',
    [string]$SecondaryNodeSuffix = '',
    [ValidateSet('', 'primary', 'secondary')]
    [string]$Node = '',

    [string]$Prefix      = 'sqlvm',
    # Must match the identifier the deploy.ps1 run used. Asked for when not passed.
    [Alias('Environment')]
    [string]$Identifier = '',
    [int]$LocalPort    = 0,
    [string]$SshKeyPath = (Join-Path $HOME '.ssh' 'id_rsa'),
    [switch]$AutoApprove
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Continue'

if ($IsWindows) {
    $env:PATH = [System.Environment]::GetEnvironmentVariable('PATH', 'Machine') + ';' +
                [System.Environment]::GetEnvironmentVariable('PATH', 'User')
}

$BastionBicep  = Join-Path $PSScriptRoot 'bicep' 'bastion.bicep'
$AdminUser     = 'azureuser'
$SuffixPattern = '^[a-z0-9]([a-z0-9-]{0,18}[a-z0-9])?$'

function Write-Step {
    param([string]$Message)
    Write-Host "[$(Get-Date -Format 'HH:mm:ss')] $Message" -ForegroundColor Cyan
}

function Read-Choice {
    param([string]$Prompt, [string[]]$Options, [string]$Default)
    Write-Host ''
    Write-Host $Prompt -ForegroundColor Cyan
    for ($i = 0; $i -lt $Options.Count; $i++) {
        $marker = if ($Options[$i] -eq $Default) { ' (default)' } else { '' }
        Write-Host "  $($i + 1)) $($Options[$i])$marker"
    }
    while ($true) {
        $answer = (Read-Host 'Select a number or type the value').Trim().ToLower()
        if (-not $answer -and $Default) { return $Default }
        if ($answer -match '^\d+$' -and [int]$answer -ge 1 -and [int]$answer -le $Options.Count) {
            return $Options[[int]$answer - 1]
        }
        if ($Options -contains $answer) { return $answer }
        Write-Host "  '$answer' is not one of: $($Options -join ', ')" -ForegroundColor Yellow
    }
}

function Read-Suffix {
    param([string]$Prompt, [string]$Default)
    while ($true) {
        $answer = (Read-Host "$Prompt [$Default]").Trim().ToLower()
        if (-not $answer) { $answer = $Default }
        if ($answer -cmatch $SuffixPattern) { return $answer }
        Write-Host "  Invalid value '$answer'. Use 1-20 lowercase letters, digits or hyphens, e.g. node-1." -ForegroundColor Yellow
    }
}

if (-not (Get-Command az -ErrorAction SilentlyContinue)) {
    Write-Error 'Required tool not found: az. Please install it and re-run.'
    exit 1
}

$account = az account show 2>$null | ConvertFrom-Json
if (-not $account) {
    Write-Host 'Not logged in to Azure. Running az login...'
    az login | Out-Null
    $account = az account show 2>$null | ConvertFrom-Json
    if (-not $account) { Write-Error 'Azure login failed.'; exit 1 }
}
Write-Host "Using Azure subscription: $($account.name) ($($account.id))"

if (-not $Action) {
    $Action = Read-Choice -Prompt 'What do you want to do?' -Default 'deploy' `
        -Options @('deploy', 'remove', 'tunnel-sql', 'ssh', 'status')
}
$idPattern = '^[a-z0-9]([a-z0-9-]{0,13}[a-z0-9])?$'
while (-not $Identifier -or $Identifier.ToLower() -cnotmatch $idPattern) {
    if ($Identifier) { Write-Host "  Invalid identifier '$Identifier'. Use 1-15 lowercase letters, digits or hyphens, e.g. 257672." -ForegroundColor Yellow }
    $Identifier = (Read-Host 'Unique identifier used for the object names (e.g. 257672)').Trim()
}
$Identifier = $Identifier.ToLower()
if (-not $PrimaryNodeSuffix)   { $PrimaryNodeSuffix   = Read-Suffix 'Primary node objects suffix (e.g. node-1)' 'node-1' }
if (-not $SecondaryNodeSuffix) { $SecondaryNodeSuffix = Read-Suffix 'Secondary node objects suffix (e.g. node-2)' 'node-2' }
$PrimaryNodeSuffix   = $PrimaryNodeSuffix.ToLower()
$SecondaryNodeSuffix = $SecondaryNodeSuffix.ToLower()
foreach ($s in @($PrimaryNodeSuffix, $SecondaryNodeSuffix)) {
    if ($s -cnotmatch $SuffixPattern) { Write-Error "Invalid node suffix '$s'."; exit 1 }
}

$NamePrefix    = "$Prefix-$Identifier"
$ResourceGroup = "$NamePrefix-$PrimaryNodeSuffix-$SecondaryNodeSuffix-rg"
$Suffixes      = [ordered]@{ primary = $PrimaryNodeSuffix; secondary = $SecondaryNodeSuffix }

Write-Step "Checking resource group: $ResourceGroup"
if ((az group exists --name $ResourceGroup) -ne 'true') {
    Write-Error "Resource group '$ResourceGroup' doesn't exist. Run deploy.ps1 -Action deploy with the same suffixes (and -Identifier) first."
    exit 1
}

function Get-BastionName { param([string]$Role) "$NamePrefix-$($Suffixes[$Role])-bastion" }
function Get-VmName      { param([string]$Role) "$NamePrefix-$($Suffixes[$Role])-vm" }

function Resolve-TargetNode {
    if ($Node) { return $Node }
    return (Read-Choice -Prompt 'Which node?' -Options @('primary', 'secondary') -Default 'primary')
}

# ── DEPLOY ─────────────────────────────────────────────────────────────────────
if ($Action -eq 'deploy') {
    $vnets = @{}
    foreach ($role in $Suffixes.Keys) {
        $vnetName = "$NamePrefix-$($Suffixes[$role])-vnet"
        Write-Step "Reading existing VNet: $vnetName"
        $json = az network vnet show --resource-group $ResourceGroup --name $vnetName `
            --query '{location:location, addressSpace:addressSpace.addressPrefixes[0]}' -o json 2>$null
        if (-not $json) {
            Write-Error "VNet '$vnetName' not found in $ResourceGroup. Check the suffixes / -Identifier match the main deployment."
            exit 1
        }
        $vnets[$role] = $json | ConvertFrom-Json
        Write-Host "  $role : $($vnets[$role].location), $($vnets[$role].addressSpace)"
    }

    Write-Host ''
    Write-Host "=== Deploying Bastion (Standard SKU, one per node VNet) into $ResourceGroup ===" -ForegroundColor Cyan
    Write-Host 'Purely additive - the existing VNets, VMs and AG are not modified.' -ForegroundColor Yellow
    Write-Host 'Provisioning commonly takes 5-10 minutes; az may look idle meanwhile.' -ForegroundColor Yellow

    az deployment group create `
        --name "$NamePrefix-$PrimaryNodeSuffix-$SecondaryNodeSuffix-bastion" `
        --resource-group $ResourceGroup `
        --template-file $BastionBicep `
        --parameters "prefix=$Prefix" "environment=$Identifier" `
                     "primaryNodeSuffix=$PrimaryNodeSuffix" "secondaryNodeSuffix=$SecondaryNodeSuffix" `
                     "primaryLocation=$($vnets.primary.location)" "secondaryLocation=$($vnets.secondary.location)" `
                     "primaryAddressSpace=$($vnets.primary.addressSpace)" "secondaryAddressSpace=$($vnets.secondary.addressSpace)" `
        --output none
    if ($LASTEXITCODE -ne 0) { Write-Error 'Bastion deployment failed - see the az error output above.'; exit 1 }

    az network bastion list --resource-group $ResourceGroup `
        --query '[].{name:name, location:location, tunneling:enableTunneling, state:provisioningState}' -o table

    $common = "-PrimaryNodeSuffix $PrimaryNodeSuffix -SecondaryNodeSuffix $SecondaryNodeSuffix -Identifier $Identifier"
    Write-Host ''
    Write-Host '=== Bastion deployed ===' -ForegroundColor Green
    Write-Host "  SQL tunnel primary   : ./deploy-bastion.ps1 -Action tunnel-sql $common -Node primary -LocalPort 11433"
    Write-Host "  SQL tunnel secondary : ./deploy-bastion.ps1 -Action tunnel-sql $common -Node secondary -LocalPort 12433"
    Write-Host "  SSH primary          : ./deploy-bastion.ps1 -Action ssh $common -Node primary"
    Write-Host "  SSH secondary        : ./deploy-bastion.ps1 -Action ssh $common -Node secondary"
    Write-Host ''
    Write-Host '  Billing: 2 Standard Bastion hosts bill continuously while deployed. Use -Action remove when done.' -ForegroundColor Yellow
}

# ── TUNNEL-SQL (for SSMS) / SSH ────────────────────────────────────────────────
elseif ($Action -in @('tunnel-sql', 'ssh')) {
    az extension add --name bastion --yes 2>$null | Out-Null
    $role        = Resolve-TargetNode
    $bastionName = Get-BastionName $role
    $vmName      = Get-VmName $role
    Write-Step "Resolving target VM: $vmName"
    $vmId = az vm show --resource-group $ResourceGroup --name $vmName --query id -o tsv 2>$null
    if (-not $vmId) { Write-Error "VM '$vmName' not found in $ResourceGroup."; exit 1 }

    if ($Action -eq 'tunnel-sql') {
        if ($LocalPort -le 0) { $LocalPort = if ($role -eq 'primary') { 11433 } else { 12433 } }
        Write-Step "Opening SQL tunnel through $bastionName"
        Write-Host "Tunnel: 127.0.0.1:$LocalPort -> $vmName`:1433 via Azure Bastion"
        Write-Host "In SSMS, connect to:  127.0.0.1,$LocalPort   (Trust server certificate: ON)" -ForegroundColor Green
        Write-Host 'Press Ctrl+C to close the tunnel when done.'
        az network bastion tunnel --name $bastionName --resource-group $ResourceGroup `
            --target-resource-id $vmId --resource-port 1433 --port $LocalPort
    } else {
        Write-Step "Opening SSH session through $bastionName"
        az network bastion ssh --name $bastionName --resource-group $ResourceGroup `
            --target-resource-id $vmId --auth-type ssh-key --username $AdminUser --ssh-key $SshKeyPath
    }
}

# ── STATUS ─────────────────────────────────────────────────────────────────────
elseif ($Action -eq 'status') {
    az network bastion list --resource-group $ResourceGroup `
        --query '[].{name:name, location:location, tunneling:enableTunneling, state:provisioningState}' -o table
}

# ── REMOVE (Bastion only - VMs/AG/everything else untouched) ───────────────────
elseif ($Action -eq 'remove') {
    Write-Host ''
    Write-Host "Deletes both Bastion hosts, their public IPs and the AzureBastionSubnets in $ResourceGroup."
    Write-Host 'The VMs, AG and databases are NOT affected.'
    if (-not $AutoApprove) {
        $confirm = Read-Host "Type 'yes' to confirm"
        if ($confirm -ne 'yes') { Write-Host 'Cancelled.'; exit 0 }
    }
    foreach ($role in $Suffixes.Keys) {
        $bastionName = Get-BastionName $role
        Write-Step "Deleting Bastion host $bastionName"
        az network bastion delete --name $bastionName --resource-group $ResourceGroup 2>$null
        Write-Step "Deleting public IP $bastionName-pip"
        az network public-ip delete --name "$bastionName-pip" --resource-group $ResourceGroup 2>$null
        Write-Step "Deleting AzureBastionSubnet from $NamePrefix-$($Suffixes[$role])-vnet"
        az network vnet subnet delete --resource-group $ResourceGroup `
            --vnet-name "$NamePrefix-$($Suffixes[$role])-vnet" --name AzureBastionSubnet 2>$null
    }
    Write-Host 'Bastion removed. Everything else in the resource group is untouched.' -ForegroundColor Green
}
