#Requires -Version 7.0
<#
.SYNOPSIS
    SQL Server on Linux Always On lab, single region: deploy, remove, check and operate 2-node AG
    stacks (RHEL 9, CLUSTER_TYPE = NONE, both replicas SYNCHRONOUS_COMMIT) with both VMs in the same
    Azure region, spread across availability zones (or an availability set).

.DESCRIPTION
    Run it without -Action / -UseCase for the menu:
      1) Deploy     - stack (2-node AG in one region)
      2) Remove     - stack or one node
      3) Check      - VM status, AG status, connection info
      4) Operate    - refresh SSH/SQL access, planned failover, forced failover, reinstate
      5) Use cases  - failure drills and runbooks, discovered from use-cases/uc-NN/uc-NN.ps1
      6) Dashboard  - live progress or replay of a use-case run (web page and/or terminal)

    Then anything not passed on the command line is asked for:
      Unique identifier      - part of every object name, e.g. 257672
      Primary node suffix    - e.g. node-1
      Secondary node suffix  - e.g. node-2
      Region / VM size       - deploy of a new stack only
      SSH/SQL access         - deploy only: your current public IP, parameters.json, or a CIDR list
      Remove scope           - remove only: whole stack, primary node only, secondary node only

    Object naming (prefix defaults to 'sqlvm'; <id> is the unique identifier you're asked for):
      Resource group : <prefix>-<id>-<primarySuffix>-<secondarySuffix>-rg
      Stack objects  : <prefix>-<id>-<primarySuffix>-<secondarySuffix>-{vnet,subnet-nsg,avset}
      Per node       : <prefix>-<id>-<suffix>-{vm,nic,nsg,pip,sqldata,osdisk}
      AG replica     : <prefix>-<id>-<suffix>   (the VM hostname)

    Placement: when the VM size is offered in at least two availability zones of the region, the
    primary goes to one zone and the secondary to another (a zone failure takes out one replica
    only). Otherwise both VMs go in one availability set (separate fault and update domains).

    Everything after the SQL Server install (AG status, failovers, single-node removal) runs through
    'az vm run-command', so it works even where a policy blocks SSH / 1433 from the internet.

.EXAMPLE
    ./sqlvm-linux-ag.ps1
    # menu

.EXAMPLE
    ./sqlvm-linux-ag.ps1 -Action deploy -Identifier 257672 -PrimaryNodeSuffix node-1 -SecondaryNodeSuffix node-2 -Location eastus -AllowedSourceIps auto

.EXAMPLE
    ./sqlvm-linux-ag.ps1 -Action failover -Identifier 257672 -PrimaryNodeSuffix node-1 -SecondaryNodeSuffix node-2
    # planned failover without data loss to whichever node is the secondary right now (also fails back)

.EXAMPLE
    ./sqlvm-linux-ag.ps1 -UseCase uc-02 -UseCaseAction drill -Identifier 257672
    # runs use-cases/uc-02/uc-02.ps1 -Action drill (it asks for its own remaining inputs)

.EXAMPLE
    ./sqlvm-linux-ag.ps1 -Action dashboard
    # runs dashboard/dashboard.ps1, which asks for the use case, live or replay, web or terminal

.EXAMPLE
    ./sqlvm-linux-ag.ps1 -Action remove -Identifier 257672 -PrimaryNodeSuffix node-1 -SecondaryNodeSuffix node-2 -RemoveScope secondary
    # removes only node-2's objects; a later -Action deploy recreates it and re-adds it to the AG
#>
param(
    [ValidateSet('', 'deploy', 'remove', 'status', 'status-ag', 'output', 'refresh-access', 'failover', 'force-failover', 'reinstate', 'dashboard')]
    [string]$Action = '',

    # Use cases: use-cases/<id>/<id>.ps1, e.g. -UseCase uc-01 (or 1). -UseCaseAction is passed to it
    # as its -Action; anything it still needs, it asks for itself.
    [string]$UseCase       = '',
    [string]$UseCaseAction = '',

    [string]$PrimaryNodeSuffix   = '',
    [string]$SecondaryNodeSuffix = '',
    # Region of BOTH nodes (deploy of a new stack only; an existing stack keeps its region).
    [string]$Location            = '',

    # remove only: 'stack' = whole resource group, 'primary' / 'secondary' = that node's objects only.
    [ValidateSet('', 'stack', 'primary', 'secondary')]
    [string]$RemoveScope = '',

    [string]$Prefix      = 'sqlvm',
    # Unique identifier that is part of every object name (e.g. 257672). Asked for when not passed.
    # -Environment still works as an alias.
    [Alias('Environment')]
    [string]$Identifier = '',
    # Empty = on a new stack, list the sizes that pass the checks in the region and let you pick one.
    # An existing node always keeps its current size.
    [string]$VmSize      = '',
    # Empty = 'zones' when the size is offered in 2+ zones of the region, else 'availability-set'.
    # An existing node always keeps its placement.
    [ValidateSet('', 'zones', 'availability-set', 'none')]
    [string]$Placement   = '',
    # Empty = pick the first free 10.<n>.0.0/16 (n = 10, 20, ... 250) that overlaps no VNet in the
    # subscription. An existing VNet always keeps its current address space.
    [string]$VnetCidr    = '',
    # Sources allowed on SSH 22 + SQL 1433. 'auto' = this machine's current public IP (/32).
    # Empty = ask during deploy (or use bicep/parameters.json with -AutoApprove).
    [string[]]$AllowedSourceIps = @(),

    [string]$RhelZipPath = '',
    [string]$SshKeyPath  = (Join-Path $HOME '.ssh' 'id_rsa'),
    [string]$SaPassword      = '',
    [string]$CertPassword    = '',
    [string]$AgLoginPassword = '',
    # Defaults to 'agsqlvm-<primary suffix>'.
    [string]$AgName     = '',
    [string]$DemoDbName = 'AGDemoDB',
    # reinstate only: the suffix of the node that must stay PRIMARY when both nodes claim the role.
    [string]$KeepPrimary = '',
    [switch]$AutoApprove
)

Set-StrictMode -Version Latest
$ScriptBoundParameters = $PSBoundParameters
# NOT 'Stop': every az/ssh/scp call below is checked manually via $LASTEXITCODE. Under 'Stop',
# any benign stderr line a native exe writes (e.g. an az CLI warning) becomes a terminating
# exception before the script's own error handling can run.
$ErrorActionPreference = 'Continue'

if ($IsWindows) {
    # Refresh PATH so az/ssh/scp are found even in a shell opened before they were installed.
    $env:PATH = [System.Environment]::GetEnvironmentVariable('PATH', 'Machine') + ';' +
                [System.Environment]::GetEnvironmentVariable('PATH', 'User')
}

$ScriptDir  = $PSScriptRoot
$BicepDir   = Join-Path $ScriptDir 'bicep'
$ScriptsDir = Join-Path $ScriptDir 'scripts'
$MainBicep  = Join-Path $BicepDir 'main.bicep'
$ParamsFile = Join-Path $BicepDir 'parameters.json'
$StateDir   = Join-Path $ScriptDir 'state'
$LogDir     = Join-Path $ScriptDir 'logs'
$AdminUser  = 'azureuser'
$DefaultVmSize = 'Standard_D4as_v7'

$SuffixPattern = '^[a-z0-9]([a-z0-9-]{0,18}[a-z0-9])?$'
$Ipv4Pattern   = '^((25[0-5]|2[0-4]\d|1?\d?\d)\.){3}(25[0-5]|2[0-4]\d|1?\d?\d)$'

# ── Interactive input helpers ──────────────────────────────────────────────────
# Read-Host returns $null once input is closed (e.g. piped/CI input ran out); stop instead of
# re-asking forever.
function Read-Line {
    param([string]$Prompt)
    $value = Read-Host $Prompt
    if ($null -eq $value) { Write-Error "No input available for: $Prompt"; exit 1 }
    return $value.Trim()
}

function Read-Choice {
    param([string]$Prompt, [string[]]$Options, [string]$Default, [string[]]$Descriptions = @())
    Write-Host ''
    Write-Host $Prompt -ForegroundColor Cyan
    for ($i = 0; $i -lt $Options.Count; $i++) {
        $marker = if ($Options[$i] -eq $Default) { ' (default)' } else { '' }
        $desc   = if ($i -lt $Descriptions.Count -and $Descriptions[$i]) { " - $($Descriptions[$i])" } else { '' }
        Write-Host "  $($i + 1)) $($Options[$i])$marker$desc"
    }
    while ($true) {
        $answer = (Read-Line 'Select a number or type the value').ToLower()
        if (-not $answer -and $Default) { return $Default }
        if ($answer -match '^\d+$' -and [int]$answer -ge 1 -and [int]$answer -le $Options.Count) {
            return $Options[[int]$answer - 1]
        }
        if ($Options -contains $answer) { return $answer }
        Write-Host "  '$answer' is not one of: $($Options -join ', ')" -ForegroundColor Yellow
    }
}

function Read-Value {
    param([string]$Prompt, [string]$Default, [scriptblock]$Validate, [string]$Hint)
    while ($true) {
        $label = if ($Default) { "$Prompt [$Default]" } else { $Prompt }
        $answer = (Read-Line $label).ToLower()
        if (-not $answer) { $answer = $Default }
        if ($answer -and (& $Validate $answer)) { return $answer }
        Write-Host "  Invalid value '$answer'. $Hint" -ForegroundColor Yellow
    }
}

function Confirm-Yes {
    param([string]$Prompt = "Type 'yes' to continue")
    if ($AutoApprove) { return }
    $confirm = Read-Host $Prompt
    if ($confirm -ne 'yes') { Write-Host 'Cancelled.'; exit 0 }
}

function Test-Identifier {
    param([string]$Value)
    return ($Value -cmatch '^[a-z0-9]([a-z0-9-]{0,13}[a-z0-9])?$')
}

function Test-Suffix {
    param([string]$Value)
    return ($Value -cmatch $SuffixPattern)
}

$script:ValidRegions = $null
function Test-RegionName {
    param([string]$Value)
    if (-not $script:ValidRegions) {
        $script:ValidRegions = @(az account list-locations --query "[?metadata.regionType=='Physical'].name" -o tsv 2>$null)
    }
    # If the list couldn't be fetched, don't block - Azure validates the region at deploy time.
    return ($script:ValidRegions.Count -eq 0 -or $script:ValidRegions -contains $Value)
}

# ── Network helpers (access allow-list + VNet address space) ───────────────────
function Get-MyPublicIp {
    foreach ($url in @('https://api.ipify.org', 'https://ifconfig.me/ip', 'https://icanhazip.com')) {
        try {
            $ip = "$(Invoke-RestMethod -Uri $url -TimeoutSec 10)".Trim()
            if ($ip -match $Ipv4Pattern) { return $ip }
        } catch { }
    }
    return $null
}

function Test-Cidr {
    param([string]$Value, [int]$MaxPrefix = 32)
    $parts = $Value.Split('/')
    if ($parts.Count -ne 2 -or $parts[1] -notmatch '^\d{1,2}$') { return $false }
    return ($parts[0] -match $Ipv4Pattern -and [int]$parts[1] -le $MaxPrefix)
}

# Normalizes a user-supplied list: 'auto' -> current public IP/32, bare IP -> IP/32.
function ConvertTo-SourceCidrs {
    param([string[]]$Values)
    $out = @()
    foreach ($v in ($Values | ForEach-Object { $_ -split '[,\s]+' } | Where-Object { $_ })) {
        if ($v -eq 'auto') {
            $ip = Get-MyPublicIp
            if (-not $ip) { Write-Error 'Could not detect this machine''s public IP - pass the CIDR explicitly.'; exit 1 }
            Write-Host "Detected public IP: $ip"
            $out += "$ip/32"
        } elseif ($v -match $Ipv4Pattern) {
            $out += "$v/32"
        } elseif (Test-Cidr $v) {
            $out += $v
        } else {
            Write-Error "'$v' is not an IPv4 address or CIDR."
            exit 1
        }
    }
    return $out
}

# Returns the SSH/SQL allow-list for this deploy, or an empty list for "keep parameters.json".
function Resolve-AllowedSourceIps {
    if ($AllowedSourceIps.Count -gt 0) { return (ConvertTo-SourceCidrs $AllowedSourceIps) }
    if ($AutoApprove) { return @() }

    $fromFile = @((Get-Content $ParamsFile -Raw | ConvertFrom-Json).parameters.allowedSourceIps.value)
    $myIp = Get-MyPublicIp
    $options = @(); $descriptions = @()
    if ($myIp) { $options += 'my-ip'; $descriptions += "only this machine's current public IP ($myIp/32) - recommended" }
    $options += 'parameters-file'; $descriptions += "bicep/parameters.json ($($fromFile -join ', '))"
    $options += 'custom';          $descriptions += 'enter IPs/CIDRs'
    $choice = Read-Choice -Prompt 'Who may reach SSH (22) and SQL Server (1433) on the node public IPs?' `
        -Options $options -Descriptions $descriptions -Default $options[0]
    switch ($choice) {
        'my-ip'           { return @("$myIp/32") }
        'parameters-file' { return @() }
        'custom' {
            while ($true) {
                $raw = Read-Line 'IPs/CIDRs, comma-separated (e.g. 203.0.113.7, 198.51.100.0/24)'
                $list = @($raw -split '[,\s]+' | Where-Object { $_ })
                $bad  = @($list | Where-Object { -not ($_ -match $Ipv4Pattern -or (Test-Cidr $_)) })
                if ($list.Count -gt 0 -and $bad.Count -eq 0) { return (ConvertTo-SourceCidrs $list) }
                Write-Host "  Invalid entries: $($bad -join ', ')" -ForegroundColor Yellow
            }
        }
    }
}

# Updates the SSH/SQL rules on whichever of this stack's NSGs exist (both NIC NSGs and the subnet
# NSG - traffic must pass both) - no VM/Bicep redeploy.
function Update-NsgAccess {
    param([string[]]$Cidrs)
    $nsgs = @($Nodes.Values | ForEach-Object { "$NamePrefix-$_-nsg" }) + @("$StackName-subnet-nsg")
    foreach ($nsg in $nsgs) {
        if (-not (az network nsg show -g $ResourceGroup -n $nsg --query name -o tsv 2>$null)) { continue }
        foreach ($rule in @('allow-ssh', 'allow-sqlserver')) {
            az network nsg rule update -g $ResourceGroup --nsg-name $nsg -n $rule --source-address-prefixes @Cidrs --output none
            if ($LASTEXITCODE -ne 0) { Write-Error "Failed to update rule '$rule' on '$nsg'."; exit 1 }
        }
        Write-Host "  $nsg : SSH/SQL allowed from $($Cidrs -join ', ')" -ForegroundColor Green
    }
}

function Get-CidrRange {
    param([string]$Cidr)
    $ip, $bits = $Cidr.Split('/')
    $prefix = if ($bits) { [int]$bits } else { 32 }
    $bytes = [System.Net.IPAddress]::Parse($ip).GetAddressBytes()
    [Array]::Reverse($bytes)
    $n     = [uint64][BitConverter]::ToUInt32($bytes, 0)
    $size  = [uint64][math]::Pow(2, 32 - $prefix)
    $start = $n - ($n % $size)
    return @($start, ($start + $size - 1))
}

function Test-CidrOverlap {
    param([string]$A, [string]$B)
    $ra = Get-CidrRange $A; $rb = Get-CidrRange $B
    return ($ra[0] -le $rb[1] -and $rb[0] -le $ra[1])
}

# Decides the address space of the stack VNet:
#  - an existing VNet keeps its address space (it can't change under attached NICs);
#  - an explicit -VnetCidr is used as given (warns on overlap);
#  - otherwise the first 10.<n>.0.0/16 (n = 10, 20, ... 250) overlapping no VNet in the
#    subscription - so the stack can be peered with any other one later.
function Resolve-VnetCidr {
    $vnetName = "$StackName-vnet"
    $current = az network vnet show -g $ResourceGroup -n $vnetName --query 'addressSpace.addressPrefixes[0]' -o tsv 2>$null
    if ($current) {
        if ($VnetCidr -and $VnetCidr -ne $current) {
            Write-Host "  $vnetName already exists with $current - ignoring -VnetCidr $VnetCidr." -ForegroundColor Yellow
        }
        return $current
    }
    $taken = @(az network vnet list --query '[].addressSpace.addressPrefixes[]' -o tsv 2>$null |
               Where-Object { $_ -and $_ -notmatch ':' })
    if ($VnetCidr) {
        if (-not (Test-Cidr $VnetCidr -MaxPrefix 22)) {
            Write-Error "Invalid VNet CIDR '$VnetCidr' - use an IPv4 range of /22 or larger, e.g. 10.30.0.0/16."
            exit 1
        }
        $overlaps = @($taken | Where-Object { Test-CidrOverlap $VnetCidr $_ })
        if ($overlaps.Count -gt 0) {
            Write-Host "  WARNING: $VnetCidr overlaps existing VNet range(s) $($overlaps -join ', ') - those VNets can never be peered with this one." -ForegroundColor Yellow
        }
        return $VnetCidr
    }
    for ($o = 10; $o -le 250; $o += 10) {
        $candidate = "10.$o.0.0/16"
        if (-not @($taken | Where-Object { Test-CidrOverlap $candidate $_ }).Count) { return $candidate }
    }
    Write-Error 'No free 10.<n>.0.0/16 range left in this subscription - pass -VnetCidr.'
    exit 1
}

# ── Remote helpers (SSH - used by deploy) ──────────────────────────────────────
function Assert-Tool {
    param([string]$Name)
    if (-not (Get-Command $Name -ErrorAction SilentlyContinue)) {
        Write-Error "Required tool not found: $Name. Please install it and re-run."
        exit 1
    }
}

function New-StrongPassword {
    param([int]$Length = 20)
    $upper   = 'ABCDEFGHJKLMNPQRSTUVWXYZ'
    $lower   = 'abcdefghijkmnopqrstuvwxyz'
    $digits  = '23456789'
    # No quotes, $, `, \ or ! - these passwords get passed through PowerShell -> ssh -> bash -> sqlcmd.
    $special = '@#%^*-_=+'
    $all     = $upper + $lower + $digits + $special

    $pick = { param([string]$chars) $chars[[System.Security.Cryptography.RandomNumberGenerator]::GetInt32($chars.Length)] }
    $chars = @(
        (& $pick $upper), (& $pick $upper), (& $pick $lower), (& $pick $lower),
        (& $pick $digits), (& $pick $digits), (& $pick $special), (& $pick $special)
    )
    for ($i = $chars.Count; $i -lt $Length; $i++) { $chars += & $pick $all }
    -join ($chars | Sort-Object { [System.Security.Cryptography.RandomNumberGenerator]::GetInt32([int]::MaxValue) })
}

# Per-stack known_hosts file: node public IPs get recycled across redeploys, and a stale entry
# in ~/.ssh/known_hosts would otherwise produce a host-key-changed failure.
function Get-SshOptions {
    @('-o', 'StrictHostKeyChecking=no', '-o', "UserKnownHostsFile=$KnownHostsFile", '-o', 'ConnectTimeout=15', '-i', $SshKeyPath)
}

function Wait-ForSSH {
    param([string]$IP, [int]$Timeout = 300)
    Write-Host "Waiting for SSH on $IP ..."
    $elapsed = 0
    $opts = Get-SshOptions
    while ($elapsed -lt $Timeout) {
        $out = ssh @opts -o BatchMode=yes "$AdminUser@$IP" 'echo ok' 2>$null
        if ($out -match 'ok') { Write-Host "  SSH ready on $IP."; return $true }
        Start-Sleep 10
        $elapsed += 10
        Write-Host "  $elapsed s elapsed..."
    }
    Write-Error @"
SSH did not become available on $IP within $Timeout seconds.
Most common cause: the NSG allow-list doesn't include the public IP this machine egresses from.
Fix it without redeploying, then re-run deploy:
  ./sqlvm-linux-ag.ps1 -Action refresh-access -Identifier $Identifier -PrimaryNodeSuffix $PrimaryNodeSuffix -SecondaryNodeSuffix $SecondaryNodeSuffix
"@
    return $false
}

function Test-SqlServerReady {
    param([string]$IP)
    $opts = Get-SshOptions
    $out = ssh @opts -o BatchMode=yes "$AdminUser@$IP" `
        "/opt/mssql-tools18/bin/sqlcmd -S localhost -U SA -P '$SaPassword' -No -C -h -1 -Q 'SET NOCOUNT ON; SELECT 1'" 2>$null
    return ($out -match '(?m)^\s*1\s*$')
}

# Runs one T-SQL batch on a node and returns its output (no retries, no exit on failure).
# The query must not contain double quotes or '$'.
function Invoke-RemoteSql {
    param([string]$IP, [string]$Query)
    $opts = Get-SshOptions
    ssh @opts -o BatchMode=yes "$AdminUser@$IP" `
        "/opt/mssql-tools18/bin/sqlcmd -S localhost -U SA -P '$SaPassword' -No -C -b -h -1 -Q `"SET NOCOUNT ON; $Query`"" 2>$null
}

# This node's role in the AG: PRIMARY, SECONDARY, RESOLVING, or NONE (AG not on this node).
function Get-AgRoleSsh {
    param([string]$IP)
    $out = "$(Invoke-RemoteSql $IP "SELECT ISNULL((SELECT rs.role_desc FROM sys.dm_hadr_availability_replica_states rs JOIN sys.availability_groups ag ON ag.group_id = rs.group_id WHERE ag.name = N'$AgName' AND rs.is_local = 1), 'NONE')")".Trim()
    if (-not $out) { return 'NONE' }
    return $out
}

# A full deploy fires dozens of ssh/scp calls; retrying a few times absorbs transient network
# blips without masking a persistent failure (auth/NSG/host-down fails all attempts).
function Invoke-WithRetry {
    param([scriptblock]$Operation, [string]$Description, [int]$MaxAttempts = 3, [int]$DelaySeconds = 10)
    for ($attempt = 1; $attempt -le $MaxAttempts; $attempt++) {
        & $Operation
        if ($LASTEXITCODE -eq 0) { return $true }
        if ($attempt -lt $MaxAttempts) {
            Write-Host "  $Description failed (attempt $attempt/$MaxAttempts, exit $LASTEXITCODE) - retrying in $DelaySeconds s..." -ForegroundColor Yellow
            Start-Sleep -Seconds $DelaySeconds
        }
    }
    return $false
}

function Invoke-Remote {
    param([string]$IP, [string]$Command)
    $opts = Get-SshOptions
    $ok = Invoke-WithRetry -Description "Remote command on $IP" -Operation { ssh @opts "$AdminUser@$IP" $Command }
    if (-not $ok) { Write-Error "Remote command failed on $IP after retries."; exit 1 }
}

function Copy-ToRemote {
    param([string]$IP, [string]$LocalPath, [string]$RemotePath)
    $opts = Get-SshOptions
    $ok = Invoke-WithRetry -Description "Upload to $IP" -Operation { scp @opts $LocalPath "$AdminUser@${IP}:$RemotePath" }
    if (-not $ok) { Write-Error "Upload to $IP failed after retries: $LocalPath -> $RemotePath"; exit 1 }
}

function Copy-FromRemote {
    param([string]$IP, [string]$RemotePath, [string]$LocalPath)
    $opts = Get-SshOptions
    $ok = Invoke-WithRetry -Description "Download from $IP" -Operation { scp @opts "$AdminUser@${IP}:$RemotePath" $LocalPath }
    if (-not $ok) { Write-Error "Download from $IP failed after retries: $RemotePath -> $LocalPath"; exit 1 }
}

# Uploads scripts/<Script> to the node and runs it with sudo and the given (single-quoted) args.
function Invoke-NodeScript {
    param([string]$IP, [string]$Script, [string[]]$Arguments)
    Copy-ToRemote $IP (Join-Path $ScriptsDir $Script) "/tmp/$Script"
    $argString = ($Arguments | ForEach-Object { "'$_'" }) -join ' '
    Invoke-Remote $IP "chmod +x /tmp/$Script && sudo /tmp/$Script $argString"
}

# Reads a node straight from the live VM resource (not the ARM deployment record, whose
# provisioningState sticks at 'Failed' after any failed redeploy even when the VMs are healthy).
function Get-NodeInfo {
    param([string]$Suffix)
    $vmName = "$NamePrefix-$Suffix-vm"
    $json = az vm show -d --resource-group $ResourceGroup --name $vmName `
        --query "{name:name, location:location, vmSize:hardwareProfile.vmSize, provisioningState:provisioningState, powerState:powerState, publicIP:publicIps, privateIP:privateIps, zone:zones[0], availabilitySet:availabilitySet.id}" -o json 2>$null
    if (-not $json) { return $null }
    $info = $json | ConvertFrom-Json
    $info | Add-Member -NotePropertyName nodeName -NotePropertyValue "$NamePrefix-$Suffix"
    $info | Add-Member -NotePropertyName healthy -NotePropertyValue (
        $info.provisioningState -eq 'Succeeded' -and [bool]$info.publicIP -and [bool]$info.privateIP)
    return $info
}

function Format-Placement {
    param($Info)
    if ($Info.zone) { return "zone $($Info.zone)" }
    if ($Info.availabilitySet) { return 'availability set' }
    return 'no zone'
}

function Import-SavedCredentials {
    if ((-not $script:SaPassword -or -not $script:CertPassword -or -not $script:AgLoginPassword) -and (Test-Path $CredsFile)) {
        $saved = Get-Content $CredsFile -Raw | ConvertFrom-Json
        if (-not $script:SaPassword)      { $script:SaPassword      = $saved.SaPassword }
        if (-not $script:CertPassword)    { $script:CertPassword    = $saved.CertPassword }
        if (-not $script:AgLoginPassword) { $script:AgLoginPassword = $saved.AgLoginPassword }
        Write-Host "Using credentials saved from a previous run ($CredsFile)."
    }
}

# ── VM size / zone discovery ───────────────────────────────────────────────────
# az vm list-skus for a whole region is slow (tens of seconds), so results are cached per region.
$script:SkuCache   = @{}
$script:QuotaCache = @{}

# Zones in which this SKU can be deployed for this subscription (offered minus zone-restricted).
function Get-SkuZones {
    param($Sku)
    $offered = @(@($Sku.locationInfo | Select-Object -First 1 | ForEach-Object { $_.zones }) | Where-Object { $_ })
    $restricted = @(@($Sku.restrictions | Where-Object { $_ -and $_.type -eq 'Zone' } |
                      ForEach-Object { $_.restrictionInfo.zones }) | Where-Object { $_ })
    return @($offered | Where-Object { $restricted -notcontains $_ } | Sort-Object)
}

# Every VM size offered to this subscription in $Location (location restrictions removed;
# zone-only restrictions reduce the size's usable zones), with the capabilities this deployment
# cares about.
function Get-RegionVmSizes {
    param([string]$Location)
    if ($script:SkuCache.ContainsKey($Location)) { return $script:SkuCache[$Location] }
    Write-Host "  Reading VM sizes offered in $Location (can take up to a minute) ..."
    $json = az vm list-skus --location $Location --resource-type virtualMachines --output json 2>$null
    $sizes = @{}
    if ($json) {
        foreach ($sku in ($json | ConvertFrom-Json)) {
            if (@($sku.restrictions | Where-Object { $_ -and $_.type -ne 'Zone' }).Count -gt 0) { continue }
            $caps = @{}
            foreach ($c in @($sku.capabilities)) { if ($c) { $caps[$c.name] = "$($c.value)" } }
            $sizes[$sku.name] = [pscustomobject]@{
                Name      = $sku.name
                Family    = $sku.family
                VCpus     = if ($caps['vCPUs']) { [int]$caps['vCPUs'] } else { 0 }
                MemoryGB  = if ($caps['MemoryGB']) { [double]$caps['MemoryGB'] } else { 0 }
                PremiumIO = $caps['PremiumIO'] -eq 'True'
                Gen2      = "$($caps['HyperVGenerations'])" -match 'V2'
                X64       = $caps['CpuArchitectureType'] -ne 'Arm64'
                Zones     = @(Get-SkuZones $sku)
            }
        }
    }
    $script:SkuCache[$Location] = $sizes
    return $sizes
}

# Free vCPUs per quota name (each VM family + 'cores' = total regional vCPUs) in $Location.
function Get-RegionQuota {
    param([string]$Location)
    if ($script:QuotaCache.ContainsKey($Location)) { return $script:QuotaCache[$Location] }
    $free = @{}
    $json = az vm list-usage --location $Location --output json 2>$null
    if ($json) {
        foreach ($u in ($json | ConvertFrom-Json)) { $free[$u.name.value] = [int]$u.limit - [int]$u.currentValue }
    }
    $script:QuotaCache[$Location] = $free
    return $free
}

# One size in one region (fast, no full-region scan). Returns $null when not offered / restricted.
function Get-SizeSku {
    param([string]$Location, [string]$Size)
    $json = az vm list-skus --location $Location --size $Size --resource-type virtualMachines --output json 2>$null
    return @(if ($json) { $json | ConvertFrom-Json | Where-Object { $_.name -eq $Size } }) | Select-Object -First 1
}

# Checks both things that can block a deploy, since Azure reports them differently:
#  1. Offer/location restrictions on the SKU (zone restrictions only shrink the usable zones).
#  2. Core quota headroom for the SKU's family - a SKU can be unrestricted and still fail with
#     QuotaExceeded when the family's approved quota in that region is too low.
function Test-RegionCapacity {
    param([string]$Location, [string]$Size, [int]$VmCount)
    $sku = Get-SizeSku -Location $Location -Size $Size
    if (-not $sku) { Write-Host ' not offered here' -NoNewline; return $false }

    $blocking = @($sku.restrictions | Where-Object { $_ -and $_.type -ne 'Zone' })
    if ($blocking.Count -gt 0) {
        Write-Host " restricted ($($blocking[0].reasonCode))" -NoNewline
        return $false
    }

    $vcpuCap = $sku.capabilities | Where-Object { $_.name -eq 'vCPUs' } | Select-Object -First 1
    $coresNeeded = $VmCount * $(if ($vcpuCap) { [int]$vcpuCap.value } else { 4 })

    $free = Get-RegionQuota $Location
    foreach ($quotaName in @($sku.family, 'cores')) {
        if ($free.ContainsKey($quotaName) -and $free[$quotaName] -lt $coresNeeded) {
            Write-Host " quota too low ($quotaName`: $($free[$quotaName]) vCPUs free, need $coresNeeded)" -NoNewline
            return $false
        }
    }
    return $true
}

# Lists the sizes usable in the region and lets the user pick one. A size qualifies when it is
# offered without restriction, fits this deployment (x64 for the x86_64 SQL Server RPM, Gen2 for
# the RHEL 9 gen2 image, Premium SSD support, >= 2 vCPUs and >= 8 GB RAM) and the family + total
# regional vCPU quota can hold both VMs. Returns the chosen size, or $null when nothing qualifies.
function Select-VmSize {
    param([string]$Region)
    Write-Host ''
    Write-Host "=== Checking VM sizes available in $Region ===" -ForegroundColor Cyan
    $sizes = Get-RegionVmSizes $Region
    $free  = Get-RegionQuota $Region
    $all = @(foreach ($sz in $sizes.Values) {
        if ($sz.VCpus -lt 2 -or $sz.MemoryGB -lt 8 -or -not $sz.PremiumIO -or -not $sz.Gen2 -or -not $sz.X64) { continue }
        $needed = $sz.VCpus * 2
        $familyFree = if ($free.ContainsKey($sz.Family)) { $free[$sz.Family] } else { [int]::MaxValue }
        $totalFree  = if ($free.ContainsKey('cores'))    { $free['cores'] }    else { [int]::MaxValue }
        if ($familyFree -lt $needed -or $totalFree -lt $needed) { continue }
        [pscustomobject]@{ Name = $sz.Name; VCpus = $sz.VCpus; MemoryGB = $sz.MemoryGB; Zones = $sz.Zones; QuotaFree = [math]::Min($familyFree, $totalFree) }
    }) | Sort-Object VCpus, MemoryGB, Name
    $all = @($all)
    Write-Host "  $Region : $($all.Count) usable size(s)"
    if ($all.Count -eq 0) { return $null }

    while ($true) {
        Write-Host ''
        $filter = Read-Line "$($all.Count) VM sizes are available in $Region. Filter by text (e.g. D4, E8s, v5) or press Enter to list all"
        $shown = @($all | Where-Object { -not $filter -or $_.Name -like "*$filter*" })
        if ($shown.Count -eq 0) { Write-Host "  No size matches '$filter'." -ForegroundColor Yellow; continue }

        Write-Host ''
        Write-Host ('  {0,4}  {1,-30} {2,6} {3,11} {4,8} {5,14}' -f '#', 'Size', 'vCPUs', 'Memory GB', 'Zones', 'vCPUs free*')
        for ($i = 0; $i -lt $shown.Count; $i++) {
            $q = if ($shown[$i].QuotaFree -eq [int]::MaxValue) { 'n/a' } else { $shown[$i].QuotaFree }
            $z = if ($shown[$i].Zones.Count) { $shown[$i].Zones -join ',' } else { '-' }
            Write-Host ('  {0,4}  {1,-30} {2,6} {3,11} {4,8} {5,14}' -f ($i + 1), $shown[$i].Name, $shown[$i].VCpus, $shown[$i].MemoryGB, $z, $q)
        }
        Write-Host '  * lowest free vCPU quota (family or regional total); this deploy needs vCPUs x 2.'
        Write-Host '    Zones: sizes with 2+ zones get one node per zone; the others use an availability set.'
        $default = if ($shown.Name -contains $DefaultVmSize) { $DefaultVmSize } else { '' }

        while ($true) {
            $label = if ($default) { "Select a number or type a size name, 'f' to filter again [$default]" } else { "Select a number or type a size name, 'f' to filter again" }
            $answer = Read-Line $label
            if (-not $answer -and $default) { return $default }
            if ($answer -eq 'f') { break }
            if ($answer -match '^\d+$' -and [int]$answer -ge 1 -and [int]$answer -le $shown.Count) { return $shown[[int]$answer - 1].Name }
            $match = $all | Where-Object { $_.Name -eq $answer -or $_.Name -eq "Standard_$answer" } | Select-Object -First 1
            if ($match) { return $match.Name }
            Write-Host "  '$answer' is not in the list." -ForegroundColor Yellow
        }
    }
}

# Validates that $VmSize can be deployed in the region; if not, asks for another region (or lets
# the user deploy anyway) instead of silently switching to a region they didn't pick.
function Confirm-RegionCapacity {
    param([string]$Location, [int]$VmCount)
    while ($true) {
        Write-Host "  Checking $VmSize in $Location ..." -NoNewline
        if (Test-RegionCapacity -Location $Location -Size $VmSize -VmCount $VmCount) {
            Write-Host ' available' -ForegroundColor Green
            return $Location
        }
        Write-Host ''
        if ($AutoApprove) {
            Write-Error "'$VmSize' is not deployable in '$Location' for this subscription. Pick another region or -VmSize."
            exit 1
        }
        $answer = (Read-Line "  Enter a different region, 'force' to deploy to '$Location' anyway, or 'quit'").ToLower()
        if ($answer -eq 'quit') { Write-Host 'Cancelled.'; exit 0 }
        if ($answer -eq 'force') { return $Location }
        if ($answer -and (Test-RegionName $answer)) { $Location = $answer }
        else { Write-Host "  '$answer' is not a valid Azure region name." -ForegroundColor Yellow }
    }
}

function Read-Region {
    param([string]$Default)
    $hint = 'Use an Azure region name such as eastus, westus2, koreacentral (az account list-locations -o table).'
    return (Read-Value -Prompt 'Region for both nodes' -Default $Default -Hint $hint -Validate { param($v) Test-RegionName $v })
}

# Where the VMs go: @{ Mode = zones|availability-set|none; PrimaryZone; SecondaryZone }.
#  - New stack: zones when the size has 2+ usable zones (first two), else an availability set.
#  - Existing nodes keep what they have (a VM's zone / availability set can't change).
#  - A rebuilt node joins the kept node's scheme: another zone, or the same availability set.
function Resolve-StackPlacement {
    param($Pri, $Sec)
    $kept = if ($Pri) { $Pri } else { $Sec }
    if ($Pri -and $Sec) {
        $mode = if ($Pri.zone -or $Sec.zone) { 'zones' } elseif ($Pri.availabilitySet) { 'availability-set' } else { 'none' }
        if ($Placement -and $Placement -ne $mode) { Write-Host "Ignoring -Placement $Placement - existing VMs keep their placement ($mode)." -ForegroundColor Yellow }
        return @{ Mode = $mode; PrimaryZone = "$($Pri.zone)"; SecondaryZone = "$($Sec.zone)" }
    }

    $sku = Get-SizeSku -Location $Location -Size $VmSize
    $zones = if ($sku) { @(Get-SkuZones $sku) } else { @() }

    if ($kept) {
        if ($Placement) { Write-Host "Ignoring -Placement $Placement - the rebuilt node follows the existing node's placement." -ForegroundColor Yellow }
        if ($kept.zone) {
            $other = @($zones | Where-Object { $_ -ne "$($kept.zone)" }) | Select-Object -First 1
            if (-not $other) {
                Write-Host "WARNING: $VmSize has no usable zone other than $($kept.zone) in $Location - the rebuilt node gets no zone." -ForegroundColor Yellow
                $other = ''
            }
            if ($Pri) { return @{ Mode = 'zones'; PrimaryZone = "$($Pri.zone)"; SecondaryZone = "$other" } }
            return @{ Mode = 'zones'; PrimaryZone = "$other"; SecondaryZone = "$($Sec.zone)" }
        }
        $mode = if ($kept.availabilitySet) { 'availability-set' } else { 'none' }
        return @{ Mode = $mode; PrimaryZone = ''; SecondaryZone = '' }
    }

    $mode = if ($Placement) { $Placement } elseif ($zones.Count -ge 2) { 'zones' } else { 'availability-set' }
    if ($mode -eq 'zones') {
        if ($zones.Count -lt 2) {
            Write-Error "-Placement zones: $VmSize is usable in $(if ($zones.Count) { "zone $($zones -join ',') only" } else { 'no zone' }) of $Location. Use another size/region, or -Placement availability-set."
            exit 1
        }
        return @{ Mode = 'zones'; PrimaryZone = "$($zones[0])"; SecondaryZone = "$($zones[1])" }
    }
    return @{ Mode = $mode; PrimaryZone = ''; SecondaryZone = '' }
}

# ── Run Command transport (status, failover, single-node removal) ──────────────
# Direct SSH/1433 can be blocked by subscription policy, so every step after the install runs
# through 'az vm run-command' (Azure control plane) instead of ssh/scp.

# Runs bash bodies on several VMs in parallel through the Run Command extension. Each request is
# @{ Rg; Vm; Body; Label }. Returns one result per request (same order) with the KEY=VALUE lines
# of its stdout parsed into .Values. Azure returns at most ~4 KB of output per call, so the node
# scripts print compact KEY=VALUE lines only.
function Invoke-RunCommandBatch {
    param([object[]]$Requests)
    $template = @'
#!/bin/bash
(
set -euo pipefail
__BODY__
)
echo "RC_EXIT=$?"
'@
    $jobs = @(foreach ($r in $Requests) {
        [pscustomobject]@{ Rg = $r.Rg; Vm = $r.Vm; Label = $r.Label; Script = $template.Replace('__BODY__', $r.Body).Replace("`r`n", "`n") }
    })
    foreach ($j in $jobs) { Write-Host "  [$($j.Vm)] $($j.Label) ..." -ForegroundColor DarkGray }

    $raw = @($jobs | ForEach-Object -ThrottleLimit 4 -Parallel {
        $j = $_
        $tmp = Join-Path ([System.IO.Path]::GetTempPath()) ('rc-' + [guid]::NewGuid().ToString('N') + '.sh')
        [System.IO.File]::WriteAllText($tmp, $j.Script)
        $json = $null
        try {
            for ($attempt = 1; $attempt -le 2; $attempt++) {
                $json = az vm run-command invoke -g $j.Rg -n $j.Vm --command-id RunShellScript --scripts "@$tmp" -o json 2>$null
                if ($LASTEXITCODE -eq 0 -and $json) { break }
                Start-Sleep 20
            }
        } finally {
            Remove-Item $tmp -Force -ErrorAction SilentlyContinue
        }
        $message = if ($json) { "$((($json | ConvertFrom-Json).value | Select-Object -First 1).message)" } else { $null }
        [pscustomobject]@{ Vm = $j.Vm; Label = $j.Label; Message = $message }
    })

    foreach ($j in $jobs) {
        $m = $raw | Where-Object { $_.Vm -eq $j.Vm -and $_.Label -eq $j.Label } | Select-Object -First 1
        $message = if ($m) { $m.Message } else { $null }
        if (-not $message) {
            [pscustomobject]@{ Vm = $j.Vm; Label = $j.Label; Exit = -1; Stdout = ''; Stderr = 'az vm run-command failed (VM not running?)'; Values = @{} }
            continue
        }
        $parts  = $message -split '\[stderr\]', 2
        $stdout = ($parts[0] -replace '(?s)^.*?\[stdout\]\s*', '').Trim()
        $stderr = if ($parts.Count -gt 1) { $parts[1].Trim() } else { '' }
        $values = @{}
        foreach ($line in ($stdout -split "`n")) {
            if ($line -match '^\s*([A-Z][A-Z0-9_]*)=(.*)$') {
                if (-not $values.ContainsKey($Matches[1])) { $values[$Matches[1]] = [System.Collections.Generic.List[string]]::new() }
                $values[$Matches[1]].Add($Matches[2].Trim())
            }
        }
        $exit = if ($values.ContainsKey('RC_EXIT')) { [int]$values['RC_EXIT'][-1] } else { -1 }
        [pscustomobject]@{ Vm = $j.Vm; Label = $j.Label; Exit = $exit; Stdout = $stdout; Stderr = $stderr; Values = $values }
    }
}

function Get-RcVal  { param($Result, [string]$Key) if ($Result -and $Result.Values.ContainsKey($Key)) { $Result.Values[$Key][0] } else { $null } }
function Get-RcVals { param($Result, [string]$Key) if ($Result -and $Result.Values.ContainsKey($Key)) { @($Result.Values[$Key]) } else { @() } }

function Assert-RcOk {
    param([object[]]$Results)
    foreach ($r in $Results) {
        if ($r.Exit -ne 0) {
            if ($r.Stdout) { Write-Host $r.Stdout }
            if ($r.Stderr) { Write-Host $r.Stderr -ForegroundColor Red }
            Write-Error "$($r.Label) failed on $($r.Vm) (exit $($r.Exit))."
            exit 1
        }
    }
}

# Bash lines that write scripts/<Script> to the VM and run it with single-quoted arguments.
function Get-NodeScriptBody {
    param([string]$Script, [string[]]$Arguments)
    $content = (Get-Content (Join-Path $ScriptsDir $Script) -Raw).Replace("`r`n", "`n")
    $argString = ($Arguments | ForEach-Object { "'$_'" }) -join ' '
    return "cat > /tmp/$Script <<'SQLVMNODESCRIPT'`n$content`nSQLVMNODESCRIPT`nchmod +x /tmp/$Script`n/tmp/$Script $argString"
}

function New-NodeScriptRequest {
    param($Node, [string]$Script, [string[]]$Arguments, [string]$Label = $Script)
    return @{ Rg = $Node.Rg; Vm = $Node.Vm; Label = $Label; Body = (Get-NodeScriptBody -Script $Script -Arguments $Arguments) }
}

# Runs one ag-09-failover-step.sh step on one node; exits the script on failure unless -NoThrow.
function Invoke-AgStep {
    param($Node, [string]$Step, [string]$Arg = '', [switch]$NoThrow)
    $arguments = @($SaPassword, $AgName, $Step)
    if ($Arg) { $arguments += $Arg }
    $r = @(Invoke-RunCommandBatch @(New-NodeScriptRequest -Node $Node -Script 'ag-09-failover-step.sh' -Arguments $arguments -Label $Step))[0]
    if (-not $NoThrow) { Assert-RcOk $r }
    foreach ($k in @('MADE_SYNC', 'PROMOTED', 'DEMOTED', 'DEMOTE_SKIPPED', 'RESUMED', 'RESUME_FAILED', 'REQUIRED_SYNC', 'REMOVED_REPLICA')) {
        foreach ($v in (Get-RcVals $r $k)) { Write-Host "    $k = $v" }
    }
    return $r
}

# ── AG status / failover (run-command) ─────────────────────────────────────────
# Both nodes of this stack, with their VM state. .Status is filled by Update-AgStatus.
function Get-AgNodes {
    foreach ($role in $Nodes.Keys) {
        $suffix = $Nodes[$role]
        $info = Get-NodeInfo $suffix
        [pscustomobject]@{
            Role = $role; Suffix = $suffix; Name = "$NamePrefix-$suffix"; Vm = "$NamePrefix-$suffix-vm"; Rg = $ResourceGroup
            Exists = [bool]$info
            Running = [bool]($info -and $info.powerState -eq 'VM running')
            Power = if ($info) { "$($info.powerState)" -replace '^VM ', '' } else { 'not found' }
            Placement = if ($info) { Format-Placement $info } else { '-' }
            Status = $null
        }
    }
}

# ag-08-status.sh on every running node (in parallel).
function Update-AgStatus {
    param([object[]]$AgNodes)
    $running = @($AgNodes | Where-Object { $_.Running })
    foreach ($n in $AgNodes) { $n.Status = $null }
    if ($running.Count -eq 0) { return }
    $batch = @(Invoke-RunCommandBatch @($running | ForEach-Object { New-NodeScriptRequest -Node $_ -Script 'ag-08-status.sh' -Arguments @($SaPassword, $AgName) -Label 'AG status' }))
    foreach ($r in $batch) { ($AgNodes | Where-Object { $_.Vm -eq $r.Vm }).Status = $r }
}

# PRIMARY / SECONDARY / RESOLVING / NONE, or VM-DOWN / SQL-DOWN / UNREACHABLE.
function Get-NodeAgRole {
    param($Node)
    if (-not $Node.Exists)  { return 'MISSING' }
    if (-not $Node.Running) { return 'VM-DOWN' }
    if (-not $Node.Status -or $Node.Status.Exit -ne 0) { return 'UNREACHABLE' }
    if ((Get-RcVal $Node.Status 'SQL_UP') -ne '1') { return 'SQL-DOWN' }
    $role = Get-RcVal $Node.Status 'LOCAL_ROLE'
    if ($role) { return $role }
    return 'NONE'
}

# AG databases on a node: the DB lines whose sync state isn't NOT_IN_AG.
function Get-AgDatabases {
    param($Node)
    return @(Get-RcVals $Node.Status 'DB' | Where-Object { $_ -notmatch '\|NOT_IN_AG\|' } | ForEach-Object { $_.Split('|')[0] })
}

function Show-AgStatus {
    param([object[]]$AgNodes)
    foreach ($n in $AgNodes) {
        Write-Host ''
        Write-Host ("  {0} ({1} suffix, {2}, VM {3}) - AG role: {4}" -f $n.Name, $n.Role, $n.Placement, $n.Power, (Get-NodeAgRole $n)) -ForegroundColor White
        foreach ($k in @('REQUIRED_SYNC', 'REPLICA', 'DB', 'DB_REPLICA')) {
            foreach ($v in (Get-RcVals $n.Status $k)) { Write-Host ("    {0,-13} {1}" -f $k, $v) }
        }
    }
}

# Polls the primary until every AG database reports SYNCHRONIZED on the target replica.
function Wait-Synchronized {
    param($Primary, $Target, [int]$Minutes = 10)
    $deadline = (Get-Date).AddMinutes($Minutes)
    while ($true) {
        Update-AgStatus @($Primary)
        $dbs  = @(Get-AgDatabases $Primary)
        $rows = @(Get-RcVals $Primary.Status 'DB_REPLICA' | Where-Object { $_.Split('|')[1] -eq $Target.Name })
        $sync = @($rows | Where-Object { $_.Split('|')[2] -eq 'SYNCHRONIZED' })
        Write-Host ("  {0}: {1}/{2} database(s) SYNCHRONIZED" -f $Target.Name, $sync.Count, $dbs.Count)
        foreach ($r in $rows) { Write-Host "    $r" -ForegroundColor DarkGray }
        if ($dbs.Count -gt 0 -and $sync.Count -eq $dbs.Count) { return $true }
        if ((Get-Date) -gt $deadline) { return $false }
        # A role change suspends the new secondary's databases ("from partner") asynchronously - possibly
        # after the resume ran. Resume whatever is still suspended there.
        if (@($rows | Where-Object { $_ -match 'suspended=1' }).Count) {
            Write-Host "  $($Target.Name) has suspended database(s) - resuming them." -ForegroundColor Yellow
            Invoke-AgStep $Target 'resume' -NoThrow | Out-Null
        }
        Start-Sleep 10
    }
}

function Assert-SavedSaPassword {
    Import-SavedCredentials
    if (-not $SaPassword) { Write-Error "No saved credentials for this stack ($CredsFile) - pass -SaPassword."; exit 1 }
}

# Planned failover without data loss (Microsoft's procedure for CLUSTER_TYPE = NONE): to whichever
# node is the secondary right now - so the same action also fails back.
function Invoke-PlannedFailover {
    Assert-SavedSaPassword
    $agNodes = @(Get-AgNodes)
    Write-Host ''
    Write-Host '=== Current state ===' -ForegroundColor Cyan
    Update-AgStatus $agNodes
    $roles = @($agNodes | ForEach-Object { Get-NodeAgRole $_ })
    $primary = $agNodes | Where-Object { (Get-NodeAgRole $_) -eq 'PRIMARY' }
    if (@($primary).Count -ne 1) {
        Show-AgStatus $agNodes
        if (@($primary).Count -eq 2) { Write-Error 'Both nodes claim the PRIMARY role - run -Action reinstate first.' }
        else { Write-Error "No reachable PRIMARY replica (roles: $($roles -join ', ')). If the primary is lost, use -Action force-failover." }
        exit 1
    }
    $target = $agNodes | Where-Object { $_.Vm -ne $primary.Vm } | Select-Object -First 1
    if ((Get-NodeAgRole $target) -ne 'SECONDARY') {
        Show-AgStatus $agNodes
        Write-Error "$($target.Name) is '$(Get-NodeAgRole $target)', not a healthy SECONDARY - a planned failover needs both nodes up."
        exit 1
    }
    Show-AgStatus $agNodes

    Write-Host ''
    Write-Host "Planned failover: $($primary.Name) (PRIMARY) -> $($target.Name)." -ForegroundColor Cyan
    Write-Host 'No committed transaction is lost. Writes stop for the few seconds of the role change, and' -ForegroundColor Yellow
    Write-Host "applications must reconnect to $($target.Name) (no listener with CLUSTER_TYPE = NONE)." -ForegroundColor Yellow
    Confirm-Yes "Type 'yes' to fail over"

    Write-Host ''
    Write-Host '=== 1/6 Prepare: both replicas SYNCHRONOUS_COMMIT, 1 synchronized secondary required to commit ===' -ForegroundColor Cyan
    Invoke-AgStep $primary 'prepare' | Out-Null

    Write-Host ''
    Write-Host "=== 2/6 Waiting for $($target.Name) to be SYNCHRONIZED ===" -ForegroundColor Cyan
    if (-not (Wait-Synchronized -Primary $primary -Target $target -Minutes 10)) {
        Invoke-AgStep $primary 'commit-gate' '0' -NoThrow | Out-Null
        Write-Error "$($target.Name) did not reach SYNCHRONIZED within 10 minutes - failover cancelled, $($primary.Name) stays PRIMARY."
        exit 1
    }

    Write-Host ''
    Write-Host "=== 3/6 Taking the AG offline on $($primary.Name) (stops writes) ===" -ForegroundColor Cyan
    Invoke-AgStep $primary 'offline' | Out-Null

    Write-Host ''
    Write-Host "=== 4/6 Promoting $($target.Name) ===" -ForegroundColor Cyan
    $promote = Invoke-AgStep $target 'promote' -NoThrow
    if ($promote.Exit -ne 0) {
        if ($promote.Stderr) { Write-Host $promote.Stderr -ForegroundColor Red }
        Write-Host "Promotion failed - bringing $($primary.Name) back as PRIMARY." -ForegroundColor Yellow
        Invoke-AgStep $primary 'promote' -NoThrow | Out-Null
        Invoke-AgStep $primary 'commit-gate' '0' -NoThrow | Out-Null
        Write-Error "Failover to $($target.Name) failed; check -Action status-ag."
        exit 1
    }

    Write-Host ''
    Write-Host "=== 5/6 Demoting $($primary.Name) to SECONDARY, resuming data movement ===" -ForegroundColor Cyan
    Invoke-AgStep $primary 'demote' | Out-Null
    $resume = @(Invoke-RunCommandBatch @($primary, $target | ForEach-Object { New-NodeScriptRequest -Node $_ -Script 'ag-09-failover-step.sh' -Arguments @($SaPassword, $AgName, 'resume') -Label 'resume' }))
    Assert-RcOk $resume
    foreach ($r in $resume) { foreach ($k in @('RESUMED', 'RESUME_FAILED')) { foreach ($v in (Get-RcVals $r $k)) { Write-Host "    [$($r.Vm)] $k = $v" } } }

    Write-Host ''
    Write-Host '=== 6/6 Commit gate back to 0 (the primary keeps accepting writes if the secondary goes down) ===' -ForegroundColor Cyan
    Invoke-AgStep $target 'commit-gate' '0' | Out-Null
    if (-not (Wait-Synchronized -Primary $target -Target $primary -Minutes 5)) {
        Write-Host "WARNING: $($primary.Name) is not SYNCHRONIZED yet - check -Action status-ag in a minute." -ForegroundColor Yellow
    }

    Update-AgStatus $agNodes
    Show-AgStatus $agNodes
    Write-Host ''
    Write-Host "Planned failover complete: $($target.Name) is PRIMARY, $($primary.Name) is SECONDARY." -ForegroundColor Green
    Write-Host 'Run the same action again to fail back.'
}

# Forced failover (possible data loss): promotes the secondary when the primary is lost. If the
# old primary is still reachable it is taken offline first and demoted afterwards; otherwise
# -Action reinstate demotes it once it is back.
function Invoke-ForcedFailover {
    Assert-SavedSaPassword
    $agNodes = @(Get-AgNodes)
    Write-Host ''
    Write-Host '=== Current state ===' -ForegroundColor Cyan
    Update-AgStatus $agNodes
    Show-AgStatus $agNodes

    $up = @($agNodes | Where-Object { (Get-NodeAgRole $_) -in @('PRIMARY', 'SECONDARY', 'RESOLVING') })
    $candidates = @($up | Where-Object { (Get-NodeAgRole $_) -ne 'PRIMARY' })
    if ($candidates.Count -eq 0) {
        Write-Error 'No reachable SECONDARY / RESOLVING replica to promote (the target needs its VM and SQL Server up).'
        exit 1
    }
    $target = $candidates[0]
    $old    = $agNodes | Where-Object { $_.Vm -ne $target.Vm } | Select-Object -First 1
    $oldUp  = (Get-NodeAgRole $old) -in @('PRIMARY', 'SECONDARY', 'RESOLVING')

    Write-Host ''
    Write-Host "Forced failover: $($target.Name) becomes PRIMARY (FORCE_FAILOVER_ALLOW_DATA_LOSS)." -ForegroundColor Cyan
    if ((Get-NodeAgRole $old) -eq 'PRIMARY') {
        Write-Host "$($old.Name) is a healthy PRIMARY - a planned failover (-Action failover) would lose nothing." -ForegroundColor Yellow
    }
    $syncRows = @(Get-RcVals $target.Status 'DB' | Where-Object { $_ -notmatch '\|NOT_IN_AG\|' -and $_ -notmatch '\|SYNCHRONIZED\|' })
    if ($syncRows.Count -gt 0) {
        Write-Host "Not every database on $($target.Name) is SYNCHRONIZED - transactions not yet hardened there are LOST:" -ForegroundColor Red
        $syncRows | ForEach-Object { Write-Host "    $_" -ForegroundColor Red }
    } else {
        Write-Host 'Both replicas are synchronous; databases that were SYNCHRONIZED lose nothing.' -ForegroundColor Yellow
    }
    Confirm-Yes "Type 'yes' to force the failover"

    if ($oldUp -and (Get-NodeAgRole $old) -eq 'PRIMARY') {
        Write-Host ''
        Write-Host "=== Taking the AG offline on $($old.Name) ===" -ForegroundColor Cyan
        Invoke-AgStep $old 'offline' -NoThrow | Out-Null
    }

    Write-Host ''
    Write-Host "=== Promoting $($target.Name) ===" -ForegroundColor Cyan
    Invoke-AgStep $target 'promote' | Out-Null
    Invoke-AgStep $target 'commit-gate' '0' -NoThrow | Out-Null

    if ($oldUp) {
        Write-Host ''
        Write-Host "=== Demoting $($old.Name) to SECONDARY, resuming data movement ===" -ForegroundColor Cyan
        Invoke-AgStep $old 'demote' -NoThrow | Out-Null
        foreach ($n in @($old, $target)) { Invoke-AgStep $n 'resume' -NoThrow | Out-Null }
        Wait-Synchronized -Primary $target -Target $old -Minutes 5 | Out-Null
    } else {
        Write-Host ''
        Write-Host "$($old.Name) is $(Get-NodeAgRole $old). When it is back, its SQL Server may still consider itself" -ForegroundColor Yellow
        Write-Host 'PRIMARY (two primaries). Demote it and resume replication with:' -ForegroundColor Yellow
        Write-Host "  ./sqlvm-linux-ag.ps1 -Action reinstate -Identifier $Identifier -PrimaryNodeSuffix $PrimaryNodeSuffix -SecondaryNodeSuffix $SecondaryNodeSuffix -KeepPrimary $($target.Suffix)" -ForegroundColor Yellow
    }

    Update-AgStatus $agNodes
    Show-AgStatus $agNodes
    Write-Host ''
    Write-Host "Forced failover complete: $($target.Name) is PRIMARY." -ForegroundColor Green
}

# After a forced failover: the returning node is demoted to SECONDARY and both resume replication.
function Invoke-Reinstate {
    Assert-SavedSaPassword
    $agNodes = @(Get-AgNodes)
    Write-Host ''
    Write-Host '=== Current state ===' -ForegroundColor Cyan
    Update-AgStatus $agNodes
    Show-AgStatus $agNodes

    $down = @($agNodes | Where-Object { (Get-NodeAgRole $_) -notin @('PRIMARY', 'SECONDARY', 'RESOLVING') })
    if ($down.Count -gt 0) {
        Write-Error "Both nodes need their VM and SQL Server up ($(($down | ForEach-Object { "$($_.Name): $(Get-NodeAgRole $_)" }) -join ', '))."
        exit 1
    }
    $primaries = @($agNodes | Where-Object { (Get-NodeAgRole $_) -eq 'PRIMARY' })
    if ($primaries.Count -eq 0) { Write-Error 'No node is PRIMARY - promote one with -Action force-failover.'; exit 1 }

    if ($KeepPrimary) {
        $keep = $agNodes | Where-Object { $_.Suffix -eq $KeepPrimary.ToLower() } | Select-Object -First 1
        if (-not $keep) { Write-Error "-KeepPrimary '$KeepPrimary' is neither '$PrimaryNodeSuffix' nor '$SecondaryNodeSuffix'."; exit 1 }
        if ((Get-NodeAgRole $keep) -ne 'PRIMARY') { Write-Error "$($keep.Name) is not PRIMARY - nothing to keep. Run -Action force-failover first."; exit 1 }
    } elseif ($primaries.Count -eq 1) {
        $keep = $primaries[0]
    } else {
        if ($AutoApprove) { Write-Error 'Both nodes claim the PRIMARY role - pass -KeepPrimary <suffix> to say which one stays.'; exit 1 }
        Write-Host ''
        Write-Host 'Both nodes claim the PRIMARY role. Keep the one your applications have been writing to' -ForegroundColor Red
        Write-Host '(usually the one promoted by force-failover); the other one''s unreplicated changes are discarded.' -ForegroundColor Red
        $choice = Read-Choice -Prompt 'Which node stays PRIMARY?' -Options @($agNodes | ForEach-Object { $_.Suffix }) -Default ''
        $keep = $agNodes | Where-Object { $_.Suffix -eq $choice } | Select-Object -First 1
    }
    $other = $agNodes | Where-Object { $_.Vm -ne $keep.Vm } | Select-Object -First 1

    Write-Host ''
    Write-Host "$($keep.Name) stays PRIMARY; $($other.Name) is demoted to SECONDARY and resumes replication." -ForegroundColor Cyan
    if ((Get-NodeAgRole $other) -eq 'PRIMARY') {
        Write-Host "Changes made on $($other.Name) that never reached $($keep.Name) are discarded." -ForegroundColor Yellow
    }
    Confirm-Yes "Type 'yes' to continue"

    if ((Get-NodeAgRole $other) -eq 'PRIMARY') { Invoke-AgStep $other 'offline' -NoThrow | Out-Null }
    Invoke-AgStep $other 'demote' | Out-Null
    $failed = @()
    foreach ($n in @($other, $keep)) {
        $r = Invoke-AgStep $n 'resume' -NoThrow
        $failed += @(Get-RcVals $r 'RESUME_FAILED')
    }
    Invoke-AgStep $keep 'commit-gate' '0' -NoThrow | Out-Null
    $ok = Wait-Synchronized -Primary $keep -Target $other -Minutes 5

    Update-AgStatus $agNodes
    Show-AgStatus $agNodes
    Write-Host ''
    if ($ok -and $failed.Count -eq 0) {
        Write-Host "Reinstated: $($keep.Name) PRIMARY, $($other.Name) SECONDARY and SYNCHRONIZED." -ForegroundColor Green
    } else {
        Write-Host "$($other.Name) is not fully synchronized. If its databases stay NOT SYNCHRONIZING (the copies" -ForegroundColor Yellow
        Write-Host 'diverged), rebuild that node: remove it and deploy again - it is re-seeded from the primary:' -ForegroundColor Yellow
        Write-Host "  ./sqlvm-linux-ag.ps1 -Action remove -RemoveScope $($other.Role) -Identifier $Identifier -PrimaryNodeSuffix $PrimaryNodeSuffix -SecondaryNodeSuffix $SecondaryNodeSuffix" -ForegroundColor Yellow
        Write-Host "  ./sqlvm-linux-ag.ps1 -Action deploy -Identifier $Identifier -PrimaryNodeSuffix $PrimaryNodeSuffix -SecondaryNodeSuffix $SecondaryNodeSuffix" -ForegroundColor Yellow
    }
}

# ── Single-node removal ────────────────────────────────────────────────────────
# Deletes one node's objects (VM, NIC, PIP, NSG, disks) and, when the kept node is the AG primary,
# first removes the node's replica from the AG so the kept node keeps running cleanly. The VNet,
# subnet NSG and availability set belong to the stack and stay. deploy recreates the node later.
function Remove-SingleNode {
    param([string]$Role)
    $keptRole   = if ($Role -eq 'primary') { 'secondary' } else { 'primary' }
    $suffix     = $Nodes[$Role]
    $keptSuffix = $Nodes[$keptRole]
    $base       = "$NamePrefix-$suffix"

    $present = @(az resource list -g $ResourceGroup --query '[].name' -o tsv 2>$null)
    $targets = @(@(
        @{ Name = "$base-vm";      Kind = 'vm' },
        @{ Name = "$base-nic";     Kind = 'nic' },
        @{ Name = "$base-pip";     Kind = 'public-ip' },
        @{ Name = "$base-nsg";     Kind = 'nsg' },
        @{ Name = "$base-osdisk";  Kind = 'disk' },
        @{ Name = "$base-sqldata"; Kind = 'disk' }
    ) | Where-Object { $present -contains $_.Name })

    if ($targets.Count -eq 0) {
        Write-Host "No objects for the $Role node '$base' exist in $ResourceGroup - nothing to remove." -ForegroundColor Yellow
        return
    }

    Write-Host ''
    Write-Host "Objects of the $Role node '$base' that will be PERMANENTLY deleted:" -ForegroundColor Yellow
    $targets | ForEach-Object { Write-Host "  $($_.Name)  ($($_.Kind))" }
    Write-Host "The $keptRole node '$NamePrefix-$keptSuffix', its data and the stack VNet are kept." -ForegroundColor Yellow

    # AG housekeeping on the node that stays (through run-command).
    Import-SavedCredentials
    $agNodes = @(Get-AgNodes)
    $kept = $agNodes | Where-Object { $_.Suffix -eq $keptSuffix }
    $removeReplica = $false
    if ($SaPassword -and $kept.Running) {
        Update-AgStatus @($kept)
        $keptAgRole = Get-NodeAgRole $kept
        if ($keptAgRole -eq 'PRIMARY') {
            $removeReplica = $true
            Write-Host "Replica '$base' will first be removed from AG '$AgName' on '$($kept.Name)' (current primary)."
        } elseif ($keptAgRole -in @('SECONDARY', 'RESOLVING')) {
            Write-Host ''
            Write-Host "WARNING: '$base' is the CURRENT AG PRIMARY. Removing it leaves '$($kept.Name)' as a" -ForegroundColor Red
            Write-Host 'secondary whose databases are not writable. Fail over first:' -ForegroundColor Red
            Write-Host "  ./sqlvm-linux-ag.ps1 -Action failover -Identifier $Identifier -PrimaryNodeSuffix $PrimaryNodeSuffix -SecondaryNodeSuffix $SecondaryNodeSuffix" -ForegroundColor Red
        } else {
            Write-Host "AG '$AgName' not reachable on '$($kept.Name)' ($keptAgRole) - no AG cleanup." -ForegroundColor Yellow
        }
    } elseif ($kept.Exists) {
        Write-Host "Can't reach SQL Server on '$($kept.Name)' (no saved SA password or VM not running) - skipping AG cleanup." -ForegroundColor Yellow
    }

    Confirm-Yes "Type 'yes' to delete the $Role node '$base'"

    if ($removeReplica) {
        $r = Invoke-AgStep $kept 'remove-replica' $base -NoThrow
        if ($r.Exit -ne 0) { Write-Host "Could not remove replica '$base' from the AG - continuing; remove it manually later." -ForegroundColor Yellow }
    }

    foreach ($t in $targets) {
        Write-Host "Deleting $($t.Kind) $($t.Name) ..."
        switch ($t.Kind) {
            'vm'        { az vm delete -g $ResourceGroup -n $t.Name --yes --output none }
            'nic'       { az network nic delete -g $ResourceGroup -n $t.Name --output none }
            'public-ip' { az network public-ip delete -g $ResourceGroup -n $t.Name --output none }
            'nsg'       { az network nsg delete -g $ResourceGroup -n $t.Name --output none }
            'disk'      { az disk delete -g $ResourceGroup -n $t.Name --yes --output none }
        }
        if ($LASTEXITCODE -ne 0) { Write-Error "Failed to delete $($t.Name) - see the az error above. Re-run remove to retry."; exit 1 }
    }
    Remove-Item $KnownHostsFile -Force -ErrorAction SilentlyContinue
    Write-Host ''
    Write-Host "Removed the $Role node '$base'. '$NamePrefix-$keptSuffix' is untouched." -ForegroundColor Green
    Write-Host 'Rebuild it and re-add it to the AG (the kept node must be the AG primary) with:'
    Write-Host "  ./sqlvm-linux-ag.ps1 -Action deploy -Identifier $Identifier -PrimaryNodeSuffix $PrimaryNodeSuffix -SecondaryNodeSuffix $SecondaryNodeSuffix"
}

# ── Menu ───────────────────────────────────────────────────────────────────────
# A section with a single option needs the leading comma: @(@('a', 'b')) flattens to @('a', 'b').
$MenuSections = [ordered]@{
    'Deploy'  = @(
        ,@('deploy',        'Stack - 2-node AG in the region you choose (create, resume or rebuild a node)'))
    'Remove'  = @(
        ,@('remove',        'Stack - the whole stack, or only one of its nodes'))
    'Check'   = @(
        @('status',         'VM power state, region and zone'),
        @('status-ag',      'AG roles, replica health and database sync state'),
        @('output',         'Connection info (SSH / SSMS)'))
    'Operate' = @(
        @('refresh-access', 'Allow your current public IP on SSH (22) / SQL (1433)'),
        @('failover',       'Planned failover, no data loss (to the current secondary; also fails back)'),
        @('force-failover', 'Forced failover when the primary is lost (possible data loss)'),
        @('reinstate',      'After a forced failover: demote the returning node and resume replication'))
}

# Every use-cases/uc-NN/ folder that has a uc-NN.ps1; the title is the first line of its README.
function Get-UseCases {
    $root = Join-Path $ScriptDir 'use-cases'
    if (-not (Test-Path $root)) { return @() }
    return @(Get-ChildItem $root -Directory | Where-Object { $_.Name -match '^uc-\d+$' } | Sort-Object Name | ForEach-Object {
        $script = Join-Path $_.FullName "$($_.Name).ps1"
        if (-not (Test-Path $script)) { return }
        $readme = Join-Path $_.FullName 'README.md'
        $title  = if (Test-Path $readme) { ((Get-Content $readme -TotalCount 1) -replace '^#\s*', '').Trim() } else { $_.Name.ToUpper() }
        [pscustomobject]@{ Id = $_.Name; Script = $script; Title = $title }
    })
}

# Accepts 'uc-01', 'UC-01', '01' or '1'.
function Resolve-UseCase {
    param([string]$Name)
    $useCases = Get-UseCases
    $n = $Name.Trim().ToLower()
    if ($n -match '^\d+$') { $n = 'uc-{0:D2}' -f [int]$n }
    $uc = $useCases | Where-Object { $_.Id -eq $n } | Select-Object -First 1
    if (-not $uc) {
        Write-Error "Use case '$Name' not found. Available: $(($useCases | ForEach-Object { $_.Id }) -join ', ')"
        exit 1
    }
    return $uc
}

# Two-level menu: section, then action (or use case). Returns @{ Action = ...; UseCase = ... }.
function Read-MenuAction {
    $useCases = Get-UseCases
    $sections = @($MenuSections.Keys) + @('Use cases', 'Dashboard')
    $summaries = @(
        'stack (2-node AG in one region)',
        'stack or one node',
        'VM status, AG status, connection info',
        'refresh SSH/SQL access, planned / forced failover, reinstate',
        "failure drills and runbooks ($($useCases.Count) available)",
        'live progress or replay of a use-case run (web / terminal)')
    while ($true) {
        Write-Host ''
        Write-Host 'What do you want to do?' -ForegroundColor Cyan
        for ($i = 0; $i -lt $sections.Count; $i++) { Write-Host ("  {0}) {1,-10} - {2}" -f ($i + 1), $sections[$i], $summaries[$i]) }
        $answer = (Read-Line 'Select a section').ToLower()
        $section = $null
        if ($answer -match '^\d+$' -and [int]$answer -ge 1 -and [int]$answer -le $sections.Count) { $section = $sections[[int]$answer - 1] }
        else { $section = $sections | Where-Object { $_.ToLower() -eq $answer } | Select-Object -First 1 }
        if (-not $section) { Write-Host "  '$answer' is not a section." -ForegroundColor Yellow; continue }

        if ($section -eq 'Dashboard') { return @{ Action = 'dashboard'; UseCase = $null } }
        if ($section -eq 'Use cases') {
            if ($useCases.Count -eq 0) { Write-Host '  No use cases found under use-cases/.' -ForegroundColor Yellow; continue }
            $labels = @($useCases | ForEach-Object { $_.Title })
        } else {
            $labels = @($MenuSections[$section] | ForEach-Object { "{0,-16} {1}" -f $_[0], $_[1] })
        }
        Write-Host ''
        Write-Host $section -ForegroundColor Cyan
        for ($i = 0; $i -lt $labels.Count; $i++) { Write-Host ("  {0}) {1}" -f ($i + 1), $labels[$i]) }
        Write-Host '  0) back'
        $answer = (Read-Line 'Select an option').ToLower()
        if ($answer -eq '0' -or $answer -eq 'back') { continue }
        if ($answer -notmatch '^\d+$' -or [int]$answer -lt 1 -or [int]$answer -gt $labels.Count) {
            Write-Host "  '$answer' is not an option." -ForegroundColor Yellow; continue
        }
        $index = [int]$answer - 1
        if ($section -eq 'Use cases') { return @{ Action = ''; UseCase = $useCases[$index] } }
        return @{ Action = $MenuSections[$section][$index][0]; UseCase = $null }
    }
}

# Runs a use case in its own pwsh process, passing only what it declares and what was already
# answered here (identifier) or passed explicitly on this command line. It asks for the rest with
# its own, scenario-specific prompts.
function Invoke-UseCase {
    param($Uc)
    $declared = (Get-Command $Uc.Script).Parameters.Keys
    $ucArgs = @()
    if ($declared -contains 'Identifier') { $ucArgs += @('-Identifier', $Identifier) }
    if ($UseCaseAction -and $declared -contains 'Action') { $ucArgs += @('-Action', $UseCaseAction) }
    foreach ($name in @('Prefix', 'PrimaryNodeSuffix', 'SecondaryNodeSuffix', 'AgName', 'DemoDbName')) {
        if ($ScriptBoundParameters.ContainsKey($name) -and $declared -contains $name) { $ucArgs += @("-$name", $ScriptBoundParameters[$name]) }
    }
    if ($AutoApprove -and $declared -contains 'AutoApprove') { $ucArgs += '-AutoApprove' }
    Write-Host ''
    Write-Host "=== $($Uc.Title) ===" -ForegroundColor Cyan
    Write-Host "  $($Uc.Script)" -ForegroundColor DarkGray
    # Start-Process -NoNewWindow: the use case talks to this console directly (its prompts must not
    # go through a PowerShell pipeline, which would hold back prompt text until a newline).
    $argList = @('-NoProfile', '-File', "`"$($Uc.Script)`"") + $ucArgs
    $proc = Start-Process -FilePath (Get-Process -Id $PID).Path -ArgumentList $argList -NoNewWindow -Wait -PassThru
    return $proc.ExitCode
}

# ── Preconditions + inputs ──────────────────────────────────────────────────────
Assert-Tool 'az'

$account = az account show 2>$null | ConvertFrom-Json
if (-not $account) {
    Write-Host 'Not logged in to Azure. Running az login...'
    az login | Out-Null
    $account = az account show 2>$null | ConvertFrom-Json
    if (-not $account) { Write-Error 'Azure login failed.'; exit 1 }
}
Write-Host "Using Azure subscription: $($account.name) ($($account.id))"

if ($UseCase -and $Action) { Write-Error 'Pass either -Action or -UseCase, not both.'; exit 1 }
if ($UseCaseAction -and -not $UseCase) { Write-Error '-UseCaseAction needs -UseCase.'; exit 1 }
$SelectedUseCase = $null
if ($UseCase) {
    $SelectedUseCase = Resolve-UseCase $UseCase
} elseif (-not $Action) {
    $pick = Read-MenuAction
    $Action = $pick.Action
    $SelectedUseCase = $pick.UseCase
}

# The dashboard only reads use-case runs: it needs no identifier (it asks for what it needs).
if ($Action -eq 'dashboard') {
    $proc = Start-Process -FilePath (Get-Process -Id $PID).Path -NoNewWindow -Wait -PassThru `
        -ArgumentList @('-NoProfile', '-File', "`"$(Join-Path $ScriptDir 'dashboard' 'dashboard.ps1')`"")
    exit $proc.ExitCode
}

$idHint = 'Use 1-15 lowercase letters, digits or hyphens (no leading/trailing hyphen), e.g. 257672.'
if (-not $Identifier) {
    $Identifier = Read-Value -Prompt 'Unique identifier for the object names (e.g. 257672)' -Default '' -Hint $idHint -Validate { param($v) Test-Identifier $v }
}
$Identifier = $Identifier.ToLower()
if (-not (Test-Identifier $Identifier)) { Write-Error "Invalid identifier '$Identifier'. $idHint"; exit 1 }

if ($SelectedUseCase) {
    exit (Invoke-UseCase $SelectedUseCase)
}

$suffixHint = 'Use 1-20 lowercase letters, digits or hyphens, e.g. node-1.'
if (-not $PrimaryNodeSuffix) {
    $PrimaryNodeSuffix = Read-Value -Prompt 'Primary node objects suffix (e.g. node-1)' -Default 'node-1' -Hint $suffixHint -Validate { param($v) Test-Suffix $v }
}
if (-not $SecondaryNodeSuffix) {
    $SecondaryNodeSuffix = Read-Value -Prompt 'Secondary node objects suffix (e.g. node-2)' -Default 'node-2' -Hint $suffixHint -Validate { param($v) Test-Suffix $v }
}
$PrimaryNodeSuffix   = $PrimaryNodeSuffix.ToLower()
$SecondaryNodeSuffix = $SecondaryNodeSuffix.ToLower()
foreach ($s in @($PrimaryNodeSuffix, $SecondaryNodeSuffix)) {
    if (-not (Test-Suffix $s)) { Write-Error "Invalid node suffix '$s'. $suffixHint"; exit 1 }
}
if ($PrimaryNodeSuffix -eq $SecondaryNodeSuffix) {
    Write-Error "Primary and secondary node suffixes must be different (both are '$PrimaryNodeSuffix')."
    exit 1
}

$Nodes          = [ordered]@{ primary = $PrimaryNodeSuffix; secondary = $SecondaryNodeSuffix }
$NamePrefix     = "$Prefix-$Identifier"
$StackName      = "$NamePrefix-$PrimaryNodeSuffix-$SecondaryNodeSuffix"
$ResourceGroup  = "$StackName-rg"
# Subscription-scope deployment records are keyed by name alone and pinned to the location they were
# first created in. '<stack>-sr-<location>' keeps this project's records apart from the cross-region
# project's ('<stack>', same naming otherwise) and from a stale record of this stack in another region.
$DeploymentPrefix = "$StackName-sr-"
function Get-DeploymentName {
    param([string]$Region)
    $name = "$DeploymentPrefix$Region"
    if ($name.Length -gt 64) { return $name.Substring(0, 64) }
    return $name
}
# The 'project' tag every resource group of this project carries (bicep/parameters.json).
$ProjectTag = (Get-Content $ParamsFile -Raw | ConvertFrom-Json).parameters.tags.value.project
$PrimaryVmName   = "$NamePrefix-$PrimaryNodeSuffix-vm"
$SecondaryVmName = "$NamePrefix-$SecondaryNodeSuffix-vm"
if (-not $AgName) { $AgName = "agsqlvm-$PrimaryNodeSuffix" }

# Saved per-stack credentials: a rerun after a mid-deploy failure must reuse the SAME passwords
# that are already configured on the VMs, or the "already installed" checks can't recognize them.
New-Item -ItemType Directory -Force -Path $StateDir | Out-Null
$CredsFile      = Join-Path $StateDir "$ResourceGroup.credentials.json"
$KnownHostsFile = Join-Path $StateDir "$ResourceGroup.known_hosts"

# Every run gets its own timestamped transcript (contains passwords - logs/ is git-ignored).
New-Item -ItemType Directory -Force -Path $LogDir | Out-Null
$LogFile = Join-Path $LogDir "$Action-$StackName-$(Get-Date -Format 'yyyyMMdd-HHmmss').log"
Start-Transcript -Path $LogFile -Append | Out-Null
Write-Host "Logging this run to: $LogFile"

try {

Write-Host ''
Write-Host "Action          : $Action"
Write-Host "Resource group  : $ResourceGroup"
Write-Host "Primary node    : $NamePrefix-$PrimaryNodeSuffix"
Write-Host "Secondary node  : $NamePrefix-$SecondaryNodeSuffix"
Write-Host "AG name         : $AgName"

$RgExists = (az group exists --name $ResourceGroup) -eq 'true'

# Same naming as the cross-region project (sqlvm-linux-ao-ag-dag-01): the same identifier + suffixes
# there give the same resource group name. Never adopt, change or delete a group this project
# didn't create.
if ($RgExists) {
    $rgProject = az group show --name $ResourceGroup --query 'tags.project' -o tsv 2>$null
    if ($rgProject -ne $ProjectTag) {
        Write-Error @"
Resource group '$ResourceGroup' exists but wasn't created by this project (its 'project' tag is '$(if ($rgProject) { $rgProject } else { 'missing' })', expected '$ProjectTag').
It's probably a stack of the cross-region project (sqlvm-linux-ao-ag-dag-01) - manage it from there.
For a single-region stack, use another -Identifier or other node suffixes.
"@
        exit 1
    }
}

# ── DEPLOY ─────────────────────────────────────────────────────────────────────
if ($Action -eq 'deploy') {
    Assert-Tool 'ssh'
    Assert-Tool 'scp'

    # 1. SSH key
    if (-not (Test-Path $SshKeyPath)) {
        Write-Error "SSH private key not found: $SshKeyPath"
        Write-Host "Generate one with:  ssh-keygen -t rsa -b 4096 -f `"$SshKeyPath`" -N `"`""
        exit 1
    }
    $PubKeyPath = "$SshKeyPath.pub"
    if (-not (Test-Path $PubKeyPath)) { Write-Error "SSH public key not found: $PubKeyPath"; exit 1 }
    $SshPublicKey = (Get-Content $PubKeyPath -Raw).Trim()

    # 2. What already exists? An existing node's region, size and placement are fixed.
    $pri = $null; $sec = $null
    if ($RgExists) {
        $pri = Get-NodeInfo $PrimaryNodeSuffix
        $sec = Get-NodeInfo $SecondaryNodeSuffix
        Write-Host ''
        Write-Host "WARNING: Resource group '$ResourceGroup' already exists." -ForegroundColor Yellow
        Write-Host 'Continuing reuses its VMs. A node whose SQL Server already answers to the SA password' -ForegroundColor Yellow
        Write-Host 'is left alone; any other node gets SQL Server (re)installed, which WIPES its databases.' -ForegroundColor Yellow
        if (-not (Test-Path $CredsFile) -and -not $SaPassword) {
            Write-Host "No saved credentials found ($CredsFile) and no -SaPassword given:" -ForegroundColor Red
            Write-Host 'if SQL Server is already installed on these VMs it will be reinstalled from scratch.' -ForegroundColor Red
        }
        Confirm-Yes
    }

    $kept = if ($pri) { $pri } elseif ($sec) { $sec } else { $null }
    if ($kept) {
        # Existing stack, or one node to rebuild: everything follows the node(s) already there.
        $existingLocation = $kept.location
        if ($Location -and $Location.ToLower() -ne $existingLocation) {
            Write-Host "Ignoring -Location $Location - the stack is in $existingLocation." -ForegroundColor Yellow
        }
        $Location = $existingLocation
        if ($VmSize -and $VmSize -ne $kept.vmSize) {
            Write-Host "Ignoring -VmSize $VmSize - the stack uses $($kept.vmSize) (one template, one size for both nodes)." -ForegroundColor Yellow
        }
        $VmSize = $kept.vmSize
        if ($pri -and $sec) {
            Write-Host "Existing stack - region $Location, VM size $VmSize" -ForegroundColor Yellow
        } else {
            $missing = if ($pri) { $SecondaryVmName } else { $PrimaryVmName }
            Write-Host ''
            Write-Host "Only $($kept.name) exists - '$missing' will be rebuilt and re-added to AG '$AgName'." -ForegroundColor Yellow
            Write-Host "(The existing node must be the AG primary; the new node is seeded from it.)" -ForegroundColor Yellow
            Write-Host ''
            Write-Host "=== Validating '$VmSize' availability ===" -ForegroundColor Cyan
            Confirm-RegionCapacity -Location $Location -VmCount 1 | Out-Null
        }
    } else {
        if (-not $Location) { $Location = Read-Region -Default 'westus2' }
        $Location = $Location.ToLower()
        if (-not (Test-RegionName $Location)) { Write-Error "Unknown Azure region '$Location'."; exit 1 }

        if (-not $VmSize -and $AutoApprove) {
            $VmSize = $DefaultVmSize
            Write-Host "No -VmSize given with -AutoApprove - using $VmSize." -ForegroundColor Yellow
        }
        if ($VmSize) {
            # Size given up front: pre-validate SKU restrictions + quota before committing to a
            # 15-20 minute deployment.
            Write-Host ''
            Write-Host "=== Validating '$VmSize' availability ===" -ForegroundColor Cyan
            $Location = Confirm-RegionCapacity -Location $Location -VmCount 2
        } else {
            # List what's actually usable in the region and let the user pick.
            while (-not $VmSize) {
                $VmSize = Select-VmSize -Region $Location
                if ($VmSize) { break }
                Write-Host ''
                Write-Host "No VM size passes the checks in $Location (usually vCPU quota)." -ForegroundColor Yellow
                $answer = (Read-Line "Enter another region (e.g. westus2), or 'quit'").ToLower()
                if ($answer -eq 'quit') { Write-Host 'Cancelled.'; exit 0 }
                if (Test-RegionName $answer) { $Location = $answer }
                else { Write-Host "  '$answer' is not a valid Azure region name." -ForegroundColor Yellow }
            }
        }
    }

    $Place = Resolve-StackPlacement -Pri $pri -Sec $sec
    Write-Host "Region           : $Location" -ForegroundColor Green
    Write-Host "VM size          : $VmSize" -ForegroundColor Green
    switch ($Place.Mode) {
        'zones'            { Write-Host "Placement        : availability zones - primary zone $(if ($Place.PrimaryZone) { $Place.PrimaryZone } else { '-' }), secondary zone $(if ($Place.SecondaryZone) { $Place.SecondaryZone } else { '-' })" -ForegroundColor Green }
        'availability-set' { Write-Host "Placement        : availability set $StackName-avset (separate fault/update domains)" -ForegroundColor Green }
        default            { Write-Host 'Placement        : none (both VMs may share hardware - no protection against a host or zone failure)' -ForegroundColor Yellow }
    }

    # 3. SSH/SQL access allow-list (empty = keep bicep/parameters.json).
    $SourceCidrs = @(Resolve-AllowedSourceIps)
    if ($SourceCidrs.Count -gt 0) { Write-Host "SSH/SQL allowed from: $($SourceCidrs -join ', ')" -ForegroundColor Green }
    else { Write-Host 'SSH/SQL allow-list: from bicep/parameters.json' }

    # 4. Credentials: explicit parameters > saved from a previous run of this stack > new.
    Import-SavedCredentials
    if (-not $SaPassword)      { $SaPassword      = New-StrongPassword; Write-Host 'Generated a random SA password.' }
    if (-not $CertPassword)    { $CertPassword    = New-StrongPassword; Write-Host 'Generated a random certificate password.' }
    if (-not $AgLoginPassword) { $AgLoginPassword = New-StrongPassword; Write-Host 'Generated a random AG peer-login password.' }
    [ordered]@{
        SaPassword      = $SaPassword
        CertPassword    = $CertPassword
        AgLoginPassword = $AgLoginPassword
    } | ConvertTo-Json | Set-Content -Path $CredsFile

    Write-Host ''
    Write-Host '=== Credentials for this stack (also saved to the state/ folder, git-ignored) ===' -ForegroundColor Yellow
    Write-Host "  SA password            : $SaPassword"
    Write-Host "  Certificate password   : $CertPassword"
    Write-Host "  AG peer-login password : $AgLoginPassword"
    Write-Host "  Saved to               : $CredsFile"

    # 5. Infrastructure - only when a VM is missing/unhealthy (redeploying Bicep over live VMs
    #    can hard-fail on immutable disk properties even when nothing needs to change).
    if ($pri -and $sec -and $pri.healthy -and $sec.healthy) {
        Write-Host ''
        Write-Host '=== Both VMs already exist and are healthy - skipping Bicep ===' -ForegroundColor Green
        if ($SourceCidrs.Count -gt 0) {
            Write-Host 'Applying the SSH/SQL allow-list to the existing NSGs...'
            Update-NsgAccess $SourceCidrs
        }
    } else {
        Write-Host ''
        Write-Host '=== Choosing the VNet address space ===' -ForegroundColor Cyan
        $Cidr = Resolve-VnetCidr
        Write-Host "  VNet $StackName-vnet : $Cidr (VM subnet: its second /24)"

        Write-Host ''
        Write-Host '=== Deploying Azure infrastructure ===' -ForegroundColor Cyan
        if ($kept) {
            Write-Host 'The whole template is re-applied: the existing VM is updated in place (not recreated).' -ForegroundColor Yellow
        }
        az bicep install 2>$null | Out-Null

        # Per-run values go into a temp parameters file instead of the command line, which
        # sidesteps native-argument quoting of the SSH key / JSON arrays on every OS.
        $runParams = [ordered]@{
            prefix              = @{ value = $Prefix }
            environment         = @{ value = $Identifier }
            primaryNodeSuffix   = @{ value = $PrimaryNodeSuffix }
            secondaryNodeSuffix = @{ value = $SecondaryNodeSuffix }
            resourceGroupName   = @{ value = $ResourceGroup }
            location            = @{ value = $Location }
            addressSpace        = @{ value = $Cidr }
            primaryZone         = @{ value = $Place.PrimaryZone }
            secondaryZone       = @{ value = $Place.SecondaryZone }
            useAvailabilitySet  = @{ value = ($Place.Mode -eq 'availability-set') }
            vmSize              = @{ value = $VmSize }
            sshPublicKey        = @{ value = $SshPublicKey }
        }
        if ($SourceCidrs.Count -gt 0) { $runParams.allowedSourceIps = @{ value = @($SourceCidrs) } }
        $RunParamsFile = Join-Path ([System.IO.Path]::GetTempPath()) "$StackName.parameters.json"
        @{
            '$schema'      = 'https://schema.management.azure.com/schemas/2019-04-01/deploymentParameters.json#'
            contentVersion = '1.0.0.0'
            parameters     = $runParams
        } | ConvertTo-Json -Depth 5 | Set-Content -Path $RunParamsFile

        # stdout (result JSON) only; az progress/errors stream straight to the console + log.
        $jsonOut = az deployment sub create `
            --name (Get-DeploymentName $Location) `
            --location $Location `
            --template-file $MainBicep `
            --parameters "@$ParamsFile" `
            --parameters "@$RunParamsFile" `
            --output json
        $deployExit = $LASTEXITCODE
        Remove-Item $RunParamsFile -Force -ErrorAction SilentlyContinue
        if ($deployExit -ne 0) {
            Write-Error 'Bicep deployment failed - see the az error output above.'
            exit 1
        }
        $pri = Get-NodeInfo $PrimaryNodeSuffix
        $sec = Get-NodeInfo $SecondaryNodeSuffix
        if (-not ($pri -and $pri.healthy -and $sec -and $sec.healthy)) {
            Write-Error 'Deployment reported success but the VMs are not both healthy - check the portal.'
            exit 1
        }
    }

    Write-Host ''
    Write-Host '=== Infrastructure ready ===' -ForegroundColor Green
    Write-Host "Primary-suffix node   ($($pri.nodeName), $(Format-Placement $pri)): $($pri.publicIP) (private $($pri.privateIP))"
    Write-Host "Secondary-suffix node ($($sec.nodeName), $(Format-Placement $sec)): $($sec.publicIP) (private $($sec.privateIP))"

    # 6. SSH reachability
    if (-not (Wait-ForSSH -IP $pri.publicIP)) { exit 1 }
    if (-not (Wait-ForSSH -IP $sec.publicIP)) { exit 1 }

    # 7. Which nodes need SQL Server? install-sqlserver.sh wipes /var/opt/mssql/data, so a
    #    node that already answers to $SaPassword must be left alone.
    Write-Host ''
    Write-Host '=== Checking whether SQL Server is already installed on each node ===' -ForegroundColor Cyan
    $NodeList = @(
        @{ Name = $pri.nodeName; IP = $pri.publicIP; Label = "$PrimaryNodeSuffix ($($pri.nodeName))" },
        @{ Name = $sec.nodeName; IP = $sec.publicIP; Label = "$SecondaryNodeSuffix ($($sec.nodeName))" }
    )
    foreach ($n in $NodeList) {
        Write-Host "  $($n.Label) - $($n.IP): " -NoNewline
        $n.NeedsInstall = -not (Test-SqlServerReady -IP $n.IP)
        if ($n.NeedsInstall) { Write-Host 'not ready - will install.' -ForegroundColor Yellow }
        else { Write-Host 'already installed and responding - will skip.' -ForegroundColor Green }
    }
    $NodesToInstall = @($NodeList | Where-Object { $_.NeedsInstall })

    # 8. Install SQL Server from the local RPM zip
    if ($NodesToInstall.Count -eq 0) {
        Write-Host 'Both nodes already have SQL Server installed - skipping install.' -ForegroundColor Green
    } else {
        if (-not $RhelZipPath) {
            $RhelZipPath = @(
                (Join-Path $ScriptDir 'Rhel9.zip'),
                (Join-Path (Split-Path $ScriptDir -Parent) 'sqlvm-linux-ao-ag-dag-01' 'Rhel9.zip'),
                (Join-Path $HOME 'Downloads' 'Rhel9.zip')
            ) | Where-Object { Test-Path $_ } | Select-Object -First 1
        }
        while (-not $RhelZipPath -or -not (Test-Path $RhelZipPath)) {
            if ($AutoApprove) {
                Write-Error 'Rhel9.zip not found next to sqlvm-linux-ag.ps1, in ../sqlvm-linux-ao-ag-dag-01 or in ~/Downloads - pass -RhelZipPath.'
                exit 1
            }
            $RhelZipPath = (Read-Line 'Path to Rhel9.zip (SQL Server RPMs)').Trim('"').Trim("'")
        }

        Write-Host ''
        Write-Host "=== Extracting $RhelZipPath ===" -ForegroundColor Cyan
        $ExtractDir = Join-Path ([System.IO.Path]::GetTempPath()) 'sqlvm-rhel9-rpms'
        Expand-Archive -Path $RhelZipPath -DestinationPath $ExtractDir -Force
        $EngineRpm = Get-ChildItem $ExtractDir -Recurse -Filter 'mssql-server-*.rpm' |
                     Where-Object { $_.Name -notmatch '-(ha|extensibility|polybase)-' } |
                     Select-Object -First 1
        if (-not $EngineRpm) { Write-Error "No mssql-server-*.rpm (engine) found in $RhelZipPath"; exit 1 }
        Write-Host "Engine RPM: $($EngineRpm.Name)  (HA/extensibility/polybase RPMs are not needed for CLUSTER_TYPE=NONE)"

        foreach ($n in $NodesToInstall) {
            Write-Host ''
            Write-Host "=== Installing SQL Server on $($n.Label) - $($n.IP) ===" -ForegroundColor Cyan
            Copy-ToRemote $n.IP $EngineRpm.FullName "/tmp/$($EngineRpm.Name)"
            Invoke-NodeScript $n.IP 'install-sqlserver.sh' @($SaPassword, $EngineRpm.Name)
        }
    }

    # 9. Which node holds the AG primary role? Normally the primary-suffix node; after a failover
    #    (and when rebuilding a removed node) it can be the secondary-suffix node. The AG phases
    #    run on whichever node is primary, with the other node as the secondary.
    $priRole = Get-AgRoleSsh $pri.publicIP
    $secRole = Get-AgRoleSsh $sec.publicIP
    Write-Host ''
    Write-Host "AG role: $($pri.nodeName) = $priRole, $($sec.nodeName) = $secRole"
    if ($priRole -eq 'PRIMARY' -and $secRole -eq 'PRIMARY') {
        Write-Error 'Both nodes claim the PRIMARY role - run -Action reinstate first, then deploy again.'
        exit 1
    }
    if ($secRole -eq 'PRIMARY') {
        $agPri = $sec; $agSec = $pri
    } elseif ($priRole -eq 'PRIMARY' -or ($priRole -eq 'NONE' -and $secRole -eq 'NONE')) {
        $agPri = $pri; $agSec = $sec
    } else {
        $holder = if ($priRole -ne 'NONE') { $pri.nodeName } else { $sec.nodeName }
        Write-Error @"
AG '$AgName' exists on $holder but has no PRIMARY replica (roles: $priRole / $secRole).
Promote $holder first, then run deploy again:
  ./sqlvm-linux-ag.ps1 -Action force-failover -Identifier $Identifier -PrimaryNodeSuffix $PrimaryNodeSuffix -SecondaryNodeSuffix $SecondaryNodeSuffix
"@
        exit 1
    }
    $PriName = $agPri.nodeName; $PriIP = $agPri.publicIP; $PriPrivateIP = $agPri.privateIP
    $SecName = $agSec.nodeName; $SecIP = $agSec.publicIP; $SecPrivateIP = $agSec.privateIP

    # 10-16. AG phases. Every ag-*.sh guards its work against the live server state, so re-running
    #        only does what's missing - including re-adding a rebuilt node (ag-02 replaces its
    #        changed certificate, ag-03 re-adds its replica / refreshes its endpoint URL).
    Write-Host ''
    Write-Host '=== Configuring Always On endpoints (both nodes) ===' -ForegroundColor Cyan
    foreach ($ip in @($PriIP, $SecIP)) {
        Invoke-NodeScript $ip 'ag-01-endpoint.sh' @($SaPassword, $CertPassword)
    }

    Write-Host ''
    Write-Host '=== Exchanging AG certificates between nodes ===' -ForegroundColor Cyan
    $CertDir = Join-Path ([System.IO.Path]::GetTempPath()) "$StackName-certs"
    New-Item -ItemType Directory -Force -Path $CertDir | Out-Null
    $PriCert = Join-Path $CertDir 'agprimary.cer'
    $SecCert = Join-Path $CertDir 'agsecondary.cer'
    Copy-FromRemote $PriIP '/tmp/dbm_certificate.cer' $PriCert
    Copy-FromRemote $SecIP '/tmp/dbm_certificate.cer' $SecCert
    Copy-ToRemote $PriIP $SecCert '/tmp/peer_dbm_certificate.cer'
    Copy-ToRemote $SecIP $PriCert '/tmp/peer_dbm_certificate.cer'
    Remove-Item $CertDir -Recurse -Force -ErrorAction SilentlyContinue

    Invoke-NodeScript $PriIP 'ag-02-trust-peer.sh' @($SaPassword, $SecName, $AgLoginPassword)
    Invoke-NodeScript $SecIP 'ag-02-trust-peer.sh' @($SaPassword, $PriName, $AgLoginPassword)

    Write-Host ''
    Write-Host "=== Creating Availability Group '$AgName' on $PriName (primary) ===" -ForegroundColor Cyan
    Invoke-NodeScript $PriIP 'ag-03-create-primary.sh' @($SaPassword, $AgName, $PriName, $PriPrivateIP, $SecName, $SecPrivateIP)

    Write-Host "=== Joining $SecName to the Availability Group ===" -ForegroundColor Cyan
    Invoke-NodeScript $SecIP 'ag-04-join-secondary.sh' @($SaPassword, $AgName)

    Write-Host '=== Creating demo database and adding it to the AG ===' -ForegroundColor Cyan
    Invoke-NodeScript $PriIP 'ag-05-create-demo-db.sh' @($SaPassword, $AgName, $DemoDbName)

    Write-Host '=== Restoring WideWorldImporters and adding it to the AG (takes a few minutes) ===' -ForegroundColor Cyan
    Invoke-NodeScript $PriIP 'ag-06-restore-wideworldimporters.sh' @($SaPassword, $AgName)

    Write-Host ''
    Write-Host '=== Verifying Availability Group health ===' -ForegroundColor Cyan
    Invoke-NodeScript $PriIP 'ag-07-verify.sh' @($SaPassword, $AgName, $DemoDbName, 'WideWorldImporters')

    Write-Host ''
    Write-Host '================================================================' -ForegroundColor Green
    Write-Host '  ALL DONE - 2-node Always On Availability Group is live'
    Write-Host '================================================================'
    Write-Host "  Resource group   : $ResourceGroup"
    Write-Host "  Region           : $Location"
    Write-Host "  AG name          : $AgName  (both replicas SYNCHRONOUS_COMMIT)"
    Write-Host "  VM size          : $VmSize"
    Write-Host "  Databases in AG  : $DemoDbName, WideWorldImporters"
    Write-Host ''
    Write-Host "  PRIMARY   $PriName ($(Format-Placement $agPri))"
    Write-Host "    SSH  : ssh -i `"$SshKeyPath`" $AdminUser@$PriIP"
    Write-Host "    SSMS : $PriIP,1433  (Login SA, readable+writable)"
    Write-Host ''
    Write-Host "  SECONDARY $SecName ($(Format-Placement $agSec))"
    Write-Host "    SSH  : ssh -i `"$SshKeyPath`" $AdminUser@$SecIP"
    Write-Host "    SSMS : $SecIP,1433  (Login SA, readable secondary once seeding completes)"
    Write-Host ''
    Write-Host "  SA password            : $SaPassword"
    Write-Host "  Certificate password   : $CertPassword"
    Write-Host "  AG peer-login password : $AgLoginPassword"
    Write-Host "  (saved in $CredsFile)"
    Write-Host ''
    Write-Host '  SSMS -> Connection Properties -> Trust server certificate: ON'
    Write-Host '================================================================'
}

# ── REMOVE ─────────────────────────────────────────────────────────────────────
elseif ($Action -eq 'remove') {
    if (-not $RgExists) {
        Write-Host "Resource group '$ResourceGroup' does not exist - nothing to remove." -ForegroundColor Yellow
        $others = @(az group list --query "[?starts_with(name, '$Prefix-')].name" -o tsv 2>$null)
        if ($others.Count -gt 0) {
            Write-Host "Existing '$Prefix-*' stacks in this subscription (<prefix>-<identifier>-<primary>-<secondary>-rg):"
            $others | ForEach-Object { Write-Host "  $_" }
        }
        exit 0
    }

    if (-not $RemoveScope) {
        $RemoveScope = Read-Choice -Prompt 'What do you want to remove?' -Default 'stack' `
            -Options @('stack', 'primary', 'secondary') `
            -Descriptions @("the whole resource group (both nodes)",
                            "only the primary-suffix node's objects ($NamePrefix-$PrimaryNodeSuffix-*) - deploy can rebuild it",
                            "only the secondary-suffix node's objects ($NamePrefix-$SecondaryNodeSuffix-*) - deploy can rebuild it")
    }

    if ($RemoveScope -in @('primary', 'secondary')) {
        Remove-SingleNode -Role $RemoveScope
    } else {
        Write-Host ''
        Write-Host "Objects in $ResourceGroup that will be PERMANENTLY deleted:" -ForegroundColor Yellow
        az resource list --resource-group $ResourceGroup --query '[].{name:name, type:type, location:location}' -o table
        Write-Host ''
        Write-Host 'Both VMs, their disks, networking and all AG data will be gone.' -ForegroundColor Yellow
        Confirm-Yes "Type 'yes' to delete '$ResourceGroup'"

        Write-Host "Deleting $ResourceGroup (typically 5-10 minutes) ..."
        az group delete --name $ResourceGroup --yes
        if ($LASTEXITCODE -ne 0) { Write-Error 'Delete failed - see the az error output above.'; exit 1 }

        # Subscription-scope deployment record + local state for this stack.
        foreach ($d in @(az deployment sub list --query "[?starts_with(name, '$DeploymentPrefix')].name" -o tsv 2>$null)) {
            az deployment sub delete --name $d 2>$null | Out-Null
        }
        Remove-Item $CredsFile, $KnownHostsFile -Force -ErrorAction SilentlyContinue
        Write-Host "Removed $ResourceGroup and its saved credentials." -ForegroundColor Green
    }
}

# ── STATUS / OUTPUT / REFRESH-ACCESS / FAILOVERS (all read the live resources) ──
else {
    if (-not $RgExists) {
        Write-Error "Resource group '$ResourceGroup' not found. Deploy it first (or check the suffixes / -Identifier)."
        exit 1
    }

    switch ($Action) {
        'status' {
            foreach ($pair in @(@('primary', $PrimaryNodeSuffix, $PrimaryVmName), @('secondary', $SecondaryNodeSuffix, $SecondaryVmName))) {
                $n = Get-NodeInfo $pair[1]
                if ($n) {
                    Write-Host ("  {0,-9} {1,-40} {2,-15} {3,-17} {4,-15} {5}" -f $pair[0], $n.name, $n.location, (Format-Placement $n), $n.powerState, $n.publicIP)
                } else {
                    Write-Host ("  {0,-9} {1,-40} NOT FOUND" -f $pair[0], $pair[2]) -ForegroundColor Yellow
                }
            }
            Write-Host '  (AG roles: -Action status-ag)'
        }
        'status-ag' {
            Assert-SavedSaPassword
            $agNodes = @(Get-AgNodes)
            Update-AgStatus $agNodes
            Write-Host ''
            Write-Host "=== AG $AgName ===" -ForegroundColor Cyan
            Show-AgStatus $agNodes
        }
        'output' {
            foreach ($pair in @(@($PrimaryNodeSuffix, 'primary suffix'), @($SecondaryNodeSuffix, 'secondary suffix'))) {
                $n = Get-NodeInfo $pair[0]
                if (-not $n) { Write-Host "  $NamePrefix-$($pair[0]): not found" -ForegroundColor Yellow; continue }
                Write-Host ''
                Write-Host "  $($n.nodeName) ($($pair[1]), $($n.location), $(Format-Placement $n))"
                Write-Host "    SSH  : ssh -i `"$SshKeyPath`" $AdminUser@$($n.publicIP)"
                Write-Host "    SSMS : $($n.publicIP),1433   private IP: $($n.privateIP)"
            }
            Write-Host ''
            Write-Host "  AG name (default for this stack): $AgName  - current roles: -Action status-ag"
            if (Test-Path $CredsFile) { Write-Host "  Credentials: $CredsFile" }
        }
        'refresh-access' {
            # Default: this machine's current public IP. -AllowedSourceIps overrides (e.g. several CIDRs).
            $list = if ($AllowedSourceIps.Count -gt 0) { $AllowedSourceIps } else { @('auto') }
            $SourceCidrs = @(ConvertTo-SourceCidrs $list)
            Write-Host ''
            Write-Host "Setting SSH (22) / SQL (1433) sources to: $($SourceCidrs -join ', ')" -ForegroundColor Cyan
            Update-NsgAccess $SourceCidrs
        }
        'failover'       { Invoke-PlannedFailover }
        'force-failover' { Invoke-ForcedFailover }
        'reinstate'      { Invoke-Reinstate }
    }
}

} finally {
    Stop-Transcript | Out-Null
}
