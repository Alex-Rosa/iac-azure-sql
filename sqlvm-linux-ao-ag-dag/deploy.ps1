#Requires -Version 7.0
<#
.SYNOPSIS
    Deploys or removes a 2-node SQL Server Always On AG (RHEL 9, CLUSTER_TYPE = NONE) whose
    Azure objects are named by a per-node suffix, in regions you choose.

.DESCRIPTION
    Anything not passed on the command line is asked for interactively:
      1. Action                 - deploy | remove | status | output | refresh-access | failover-to-secondary
      2. Unique identifier      - part of every object name, e.g. 257672
      3. Primary node suffix    - e.g. node-1
      4. Secondary node suffix  - e.g. node-2
      5. Primary region         - deploy only (skipped when the node already exists)
      6. Secondary region       - deploy only (skipped when the node already exists)
      7. VM size                - new stack only: pick from the sizes available in the chosen regions
      8. SSH/SQL access         - deploy only: your current public IP, parameters.json, or a CIDR list
      9. Remove scope           - remove only: whole stack, primary node only, secondary node only

    Object naming (prefix defaults to 'sqlvm'; <id> is the unique identifier you're asked for):
      Resource group : <prefix>-<id>-<primarySuffix>-<secondarySuffix>-rg
      Per node       : <prefix>-<id>-<suffix>-{vm,nic,nsg,pip,vnet,sqldata,osdisk}
      AG replica     : <prefix>-<id>-<suffix>   (the VM hostname)

    Each suffix pair is its own independent stack, so node-1/node-2 and node-3/node-4 can
    run side by side in the same subscription. VNet address spaces are picked automatically so
    they don't overlap any other VNet in the subscription (required to peer stacks later, e.g.
    for a Distributed AG).

.EXAMPLE
    ./deploy.ps1
    # fully interactive

.EXAMPLE
    ./deploy.ps1 -Action deploy -Identifier 257672 -PrimaryNodeSuffix node-1 -SecondaryNodeSuffix node-2 -PrimaryLocation eastus -SecondaryLocation westus2 -AllowedSourceIps auto

.EXAMPLE
    ./deploy.ps1 -Action remove -Identifier 257672 -PrimaryNodeSuffix node-1 -SecondaryNodeSuffix node-2 -RemoveScope secondary
    # removes only node-2's objects; a later -Action deploy recreates it and re-adds it to the AG
#>
param(
    [ValidateSet('', 'deploy', 'remove', 'status', 'output', 'refresh-access', 'failover-to-secondary')]
    [string]$Action = '',

    [string]$PrimaryNodeSuffix   = '',
    [string]$SecondaryNodeSuffix = '',
    [string]$PrimaryLocation     = '',
    [string]$SecondaryLocation   = '',

    # remove only: 'stack' = whole resource group, 'primary' / 'secondary' = that node's objects only.
    [ValidateSet('', 'stack', 'primary', 'secondary')]
    [string]$RemoveScope = '',

    [string]$Prefix      = 'sqlvm',
    # Unique identifier that is part of every object name (e.g. 257672). Asked for when not passed.
    # -Environment still works as an alias.
    [Alias('Environment')]
    [string]$Identifier = '',
    # Empty = on a new stack, list the sizes that pass the checks in the chosen region(s) and let
    # you pick one. An existing node always keeps its current size.
    [string]$VmSize      = '',
    # Empty = pick the first free 10.<n>.0.0/16 (n = 10, 20, ... 250) that overlaps no VNet in
    # the subscription. An existing node's VNet always keeps its current address space.
    [string]$PrimaryVnetCidr   = '',
    [string]$SecondaryVnetCidr = '',
    # Sources allowed on SSH 22 + SQL 1433. 'auto' = this machine's current public IP (/32).
    # Empty = ask during deploy (or use bicep/parameters.json with -AutoApprove).
    [string[]]$AllowedSourceIps = @(),

    [string]$RhelZipPath = '',
    [string]$SshKeyPath  = (Join-Path $HOME '.ssh' 'id_rsa'),
    [string]$SaPassword      = '',
    [string]$CertPassword    = '',
    [string]$AgLoginPassword = '',
    # Defaults to 'agsqlvm-<primary suffix>' so that two stacks never share an AG name (a
    # Distributed AG between them requires distinct names).
    [string]$AgName     = '',
    [string]$DemoDbName = 'AGDemoDB',
    [switch]$AutoApprove
)

Set-StrictMode -Version Latest
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

# ── Network helpers (access allow-list + VNet address spaces) ──────────────────
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

# Updates the SSH/SQL rules on whichever of this stack's NSGs exist - no VM/Bicep redeploy.
function Update-NsgAccess {
    param([string[]]$Cidrs)
    foreach ($suffix in $Nodes.Values) {
        $nsg = "$NamePrefix-$suffix-nsg"
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

# Decides the address space for each node's VNet:
#  - an existing VNet keeps its address space (it can't change under attached NICs/peering);
#  - an explicit -PrimaryVnetCidr/-SecondaryVnetCidr is used as given (warns on overlap);
#  - otherwise the first 10.<n>.0.0/16 (n = 10, 20, ... 250) overlapping no VNet in the
#    subscription - so any two stacks can be peered later, e.g. for a Distributed AG.
function Resolve-VnetCidrs {
    $taken = @(az network vnet list --query '[].addressSpace.addressPrefixes[]' -o tsv 2>$null |
               Where-Object { $_ -and $_ -notmatch ':' })
    $explicit = @{ primary = $PrimaryVnetCidr; secondary = $SecondaryVnetCidr }
    $result = @{}
    foreach ($role in $Nodes.Keys) {
        $vnetName = "$NamePrefix-$($Nodes[$role])-vnet"
        $current = az network vnet show -g $ResourceGroup -n $vnetName --query 'addressSpace.addressPrefixes[0]' -o tsv 2>$null
        if ($current) {
            if ($explicit[$role] -and $explicit[$role] -ne $current) {
                Write-Host "  $vnetName already exists with $current - ignoring -$((Get-Culture).TextInfo.ToTitleCase($role))VnetCidr $($explicit[$role])." -ForegroundColor Yellow
            }
            $result[$role] = $current
            continue
        }
        if ($explicit[$role]) {
            if (-not (Test-Cidr $explicit[$role] -MaxPrefix 22)) {
                Write-Error "Invalid VNet CIDR '$($explicit[$role])' - use an IPv4 range of /22 or larger, e.g. 10.30.0.0/16."
                exit 1
            }
            $overlaps = @($taken | Where-Object { Test-CidrOverlap $explicit[$role] $_ })
            if ($overlaps.Count -gt 0) {
                Write-Host "  WARNING: $($explicit[$role]) overlaps existing VNet range(s) $($overlaps -join ', ') - those VNets can never be peered with this one." -ForegroundColor Yellow
            }
            $result[$role] = $explicit[$role]
        } else {
            $pick = $null
            for ($o = 10; $o -le 250; $o += 10) {
                $candidate = "10.$o.0.0/16"
                if (-not @($taken | Where-Object { Test-CidrOverlap $candidate $_ }).Count) { $pick = $candidate; break }
            }
            if (-not $pick) {
                Write-Error 'No free 10.<n>.0.0/16 range left in this subscription - pass -PrimaryVnetCidr/-SecondaryVnetCidr.'
                exit 1
            }
            $result[$role] = $pick
        }
        $taken += $result[$role]
    }
    if (Test-CidrOverlap $result.primary $result.secondary) {
        Write-Error "Primary ($($result.primary)) and secondary ($($result.secondary)) VNet ranges overlap - VNet peering would fail."
        exit 1
    }
    return $result
}

# ── Remote helpers ─────────────────────────────────────────────────────────────
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
  ./deploy.ps1 -Action refresh-access -Identifier $Identifier -PrimaryNodeSuffix $PrimaryNodeSuffix -SecondaryNodeSuffix $SecondaryNodeSuffix
Or use deploy-bastion.ps1 if your egress IP keeps changing.
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
        --query "{name:name, location:location, vmSize:hardwareProfile.vmSize, provisioningState:provisioningState, powerState:powerState, publicIP:publicIps, privateIP:privateIps}" -o json 2>$null
    if (-not $json) { return $null }
    $info = $json | ConvertFrom-Json
    $info | Add-Member -NotePropertyName nodeName -NotePropertyValue "$NamePrefix-$Suffix"
    $info | Add-Member -NotePropertyName healthy -NotePropertyValue (
        $info.provisioningState -eq 'Succeeded' -and [bool]$info.publicIP -and [bool]$info.privateIP)
    return $info
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

# Checks both things that can block a deploy, since Azure reports them differently:
#  1. Offer/location restrictions on the SKU (zone-only restrictions ignored - no zones pinned).
#  2. Core quota headroom for the SKU's family - a SKU can be unrestricted and still fail with
#     QuotaExceeded when the family's approved quota in that region is too low.
function Test-RegionCapacity {
    param([string]$Location, [string]$Size, [int]$VmCount = 1)

    $json = az vm list-skus --location $Location --size $Size --resource-type virtualMachines --output json 2>$null
    $skus = @(if ($json) { $json | ConvertFrom-Json | Where-Object { $_.name -eq $Size } })
    if ($skus.Count -eq 0) {
        Write-Host " not offered here" -NoNewline
        return $false
    }
    $sku = $skus[0]

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

# ── VM size discovery / selection ──────────────────────────────────────────────
# az vm list-skus for a whole region is slow (tens of seconds), so results are cached per region.
$script:SkuCache   = @{}
$script:QuotaCache = @{}

# Every VM size offered to this subscription in $Location (location restrictions removed;
# zone-only restrictions ignored since no zone is pinned), with the capabilities this
# deployment cares about.
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

# Lists the sizes usable in every chosen region and lets the user pick one. A size qualifies when
# it is offered without restriction, fits this deployment (x64 for the x86_64 SQL Server RPM, Gen2
# for the RHEL 9 gen2 image, Premium SSD support, >= 2 vCPUs and >= 8 GB RAM) and the family +
# total regional vCPU quota can hold the VMs going there (2 when both nodes share a region).
# Returns the chosen size, or $null when nothing qualifies.
function Select-VmSize {
    param([string]$PrimaryRegion, [string]$SecondaryRegion)
    $regions = @(@($PrimaryRegion, $SecondaryRegion) | Select-Object -Unique)
    $vmCount = if ($regions.Count -eq 1) { 2 } else { 1 }

    Write-Host ''
    Write-Host "=== Checking VM sizes available in $($regions -join ' and ') ===" -ForegroundColor Cyan
    $candidates = $null
    foreach ($r in $regions) {
        $sizes = Get-RegionVmSizes $r
        $free  = Get-RegionQuota $r
        $ok = @{}
        foreach ($sz in $sizes.Values) {
            if ($sz.VCpus -lt 2 -or $sz.MemoryGB -lt 8 -or -not $sz.PremiumIO -or -not $sz.Gen2 -or -not $sz.X64) { continue }
            $needed = $sz.VCpus * $vmCount
            $familyFree = if ($free.ContainsKey($sz.Family)) { $free[$sz.Family] } else { [int]::MaxValue }
            $totalFree  = if ($free.ContainsKey('cores'))    { $free['cores'] }    else { [int]::MaxValue }
            if ($familyFree -lt $needed -or $totalFree -lt $needed) { continue }
            $ok[$sz.Name] = [math]::Min($familyFree, $totalFree)
        }
        if ($null -eq $candidates) {
            $candidates = @{}
            foreach ($name in $ok.Keys) {
                $candidates[$name] = [pscustomobject]@{ Name = $name; VCpus = $sizes[$name].VCpus; MemoryGB = $sizes[$name].MemoryGB; Family = $sizes[$name].Family; QuotaFree = $ok[$name] }
            }
        } else {
            foreach ($name in @($candidates.Keys)) {
                if (-not $ok.ContainsKey($name)) { $candidates.Remove($name) }
                else { $candidates[$name].QuotaFree = [math]::Min($candidates[$name].QuotaFree, $ok[$name]) }
            }
        }
        Write-Host "  $r : $($ok.Count) usable size(s)"
    }

    $all = @($candidates.Values | Sort-Object VCpus, MemoryGB, Name)
    if ($all.Count -eq 0) { return $null }

    $where = if ($regions.Count -eq 1) { "in $($regions[0])" } else { 'in both regions' }
    while ($true) {
        Write-Host ''
        $filter = Read-Line "$($all.Count) VM sizes are available $where. Filter by text (e.g. D4, E8s, v5) or press Enter to list all"
        $shown = @($all | Where-Object { -not $filter -or $_.Name -like "*$filter*" })
        if ($shown.Count -eq 0) { Write-Host "  No size matches '$filter'." -ForegroundColor Yellow; continue }

        Write-Host ''
        Write-Host ('  {0,4}  {1,-30} {2,6} {3,11} {4,14}' -f '#', 'Size', 'vCPUs', 'Memory GB', 'vCPUs free*')
        for ($i = 0; $i -lt $shown.Count; $i++) {
            $q = if ($shown[$i].QuotaFree -eq [int]::MaxValue) { 'n/a' } else { $shown[$i].QuotaFree }
            Write-Host ('  {0,4}  {1,-30} {2,6} {3,11} {4,14}' -f ($i + 1), $shown[$i].Name, $shown[$i].VCpus, $shown[$i].MemoryGB, $q)
        }
        Write-Host "  * lowest free vCPU quota (family or regional total) across the chosen region(s); this deploy needs vCPUs x $vmCount per region."
        $default = if ($shown.Name -contains 'Standard_D4as_v7') { 'Standard_D4as_v7' } else { '' }

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

# Validates that $Size can be deployed in the chosen region; if not, asks for another region
# (or lets the user deploy anyway) instead of silently switching to a region they didn't pick.
function Confirm-RegionCapacity {
    param([string]$Role, [string]$Location, [int]$VmCount)
    while ($true) {
        Write-Host "  Checking $VmSize in $Location ($Role) ..." -NoNewline
        if (Test-RegionCapacity -Location $Location -Size $VmSize -VmCount $VmCount) {
            Write-Host ' available' -ForegroundColor Green
            return $Location
        }
        Write-Host ''
        if ($AutoApprove) {
            Write-Error "'$VmSize' is not deployable in '$Location' for this subscription. Pick another region or -VmSize."
            exit 1
        }
        $answer = (Read-Line "  Enter a different $Role region, 'force' to deploy to '$Location' anyway, or 'quit'").ToLower()
        if ($answer -eq 'quit') { Write-Host 'Cancelled.'; exit 0 }
        if ($answer -eq 'force') { return $Location }
        if ($answer -and (Test-RegionName $answer)) { $Location = $answer }
        else { Write-Host "  '$answer' is not a valid Azure region name." -ForegroundColor Yellow }
    }
}

function Read-Region {
    param([string]$Role, [string]$Default)
    $hint = 'Use an Azure region name such as eastus, westus2, koreacentral (az account list-locations -o table).'
    return (Read-Value -Prompt "$((Get-Culture).TextInfo.ToTitleCase($Role)) node region" -Default $Default -Hint $hint -Validate { param($v) Test-RegionName $v })
}

# ── Single-node removal ────────────────────────────────────────────────────────
# Deletes one node's objects (VM, NIC, PIP, NSG, disks, its Bastion, its VNet and the peer's
# peering to it) and, when the kept node is the AG primary, first removes the node's replica
# from the AG so the kept node keeps running cleanly. deploy recreates the node later.
function Remove-SingleNode {
    param([string]$Role)
    $keptRole   = if ($Role -eq 'primary') { 'secondary' } else { 'primary' }
    $suffix     = $Nodes[$Role]
    $keptSuffix = $Nodes[$keptRole]
    $base       = "$NamePrefix-$suffix"
    $keptVnet   = "$NamePrefix-$keptSuffix-vnet"

    $present = @(az resource list -g $ResourceGroup --query '[].name' -o tsv 2>$null)
    $targets = @(@(
        @{ Name = "$base-vm";          Kind = 'vm' },
        @{ Name = "$base-nic";         Kind = 'nic' },
        @{ Name = "$base-pip";         Kind = 'public-ip' },
        @{ Name = "$base-nsg";         Kind = 'nsg' },
        @{ Name = "$base-osdisk";      Kind = 'disk' },
        @{ Name = "$base-sqldata";     Kind = 'disk' },
        @{ Name = "$base-bastion";     Kind = 'bastion' },
        @{ Name = "$base-bastion-pip"; Kind = 'public-ip' },
        @{ Name = "$base-vnet";        Kind = 'vnet' }
    ) | Where-Object { $present -contains $_.Name })

    if ($targets.Count -eq 0) {
        Write-Host "No objects for the $Role node '$base' exist in $ResourceGroup - nothing to remove." -ForegroundColor Yellow
        return
    }

    Write-Host ''
    Write-Host "Objects of the $Role node '$base' that will be PERMANENTLY deleted:" -ForegroundColor Yellow
    $targets | ForEach-Object { Write-Host "  $($_.Name)  ($($_.Kind))" }
    Write-Host "  peering '$keptVnet/to-$suffix' (if present)"
    Write-Host "The $keptRole node '$NamePrefix-$keptSuffix' and its data are kept." -ForegroundColor Yellow

    # AG housekeeping on the node that stays.
    $kept = Get-NodeInfo $keptSuffix
    $removeReplica = $false
    Import-SavedCredentials
    if ($kept -and $kept.healthy -and $SaPassword) {
        $keptRoleDesc = "$(Invoke-RemoteSql $kept.publicIP "SELECT rs.role_desc FROM sys.dm_hadr_availability_replica_states rs JOIN sys.availability_groups ag ON ag.group_id = rs.group_id WHERE ag.name = N'$AgName' AND rs.is_local = 1")".Trim()
        if ($keptRoleDesc -eq 'PRIMARY') {
            $removeReplica = $true
            Write-Host "Replica '$base' will first be removed from AG '$AgName' on '$($kept.nodeName)' (current primary)."
        } elseif ($keptRoleDesc -eq 'SECONDARY') {
            Write-Host ''
            Write-Host "WARNING: '$base' is the CURRENT AG PRIMARY. Removing it leaves '$($kept.nodeName)' as a" -ForegroundColor Red
            Write-Host "secondary whose databases are not writable. Fail over first by running this on '$($kept.nodeName)':" -ForegroundColor Red
            Write-Host "  ALTER AVAILABILITY GROUP [$AgName] FORCE_FAILOVER_ALLOW_DATA_LOSS;" -ForegroundColor Red
        } else {
            Write-Host "AG '$AgName' not found on '$($kept.nodeName)' - no AG cleanup needed." -ForegroundColor Yellow
        }
    } elseif ($kept) {
        Write-Host "Can't reach SQL Server on '$($kept.nodeName)' (no saved SA password or VM not healthy) - skipping AG cleanup." -ForegroundColor Yellow
    }
    if ($Role -eq 'primary') {
        Write-Host ''
        Write-Host 'Note: deploy.ps1 can rebuild a removed SECONDARY node in place. A removed primary node' -ForegroundColor Yellow
        Write-Host "can't be rebuilt into this stack - the AG then lives only on '$NamePrefix-$keptSuffix'." -ForegroundColor Yellow
    }

    Confirm-Yes "Type 'yes' to delete the $Role node '$base'"

    if ($removeReplica) {
        Assert-Tool 'ssh'
        Invoke-RemoteSql $kept.publicIP "IF EXISTS (SELECT 1 FROM sys.availability_replicas ar JOIN sys.availability_groups ag ON ag.group_id = ar.group_id WHERE ag.name = N'$AgName' AND ar.replica_server_name = N'$base') ALTER AVAILABILITY GROUP [$AgName] REMOVE REPLICA ON N'$base'; SELECT 'removed'" | Out-Null
        if ($LASTEXITCODE -eq 0) { Write-Host "Removed replica '$base' from AG '$AgName'." -ForegroundColor Green }
        else { Write-Host "Could not remove replica '$base' from the AG - continuing; remove it manually later." -ForegroundColor Yellow }
    }

    foreach ($t in $targets) {
        Write-Host "Deleting $($t.Kind) $($t.Name) ..."
        switch ($t.Kind) {
            'vm'        { az vm delete -g $ResourceGroup -n $t.Name --yes --output none }
            'nic'       { az network nic delete -g $ResourceGroup -n $t.Name --output none }
            'public-ip' { az network public-ip delete -g $ResourceGroup -n $t.Name --output none }
            'nsg'       { az network nsg delete -g $ResourceGroup -n $t.Name --output none }
            'disk'      { az disk delete -g $ResourceGroup -n $t.Name --yes --output none }
            'bastion'   { az network bastion delete -g $ResourceGroup -n $t.Name --output none }
            'vnet'      {
                # Peering on the kept VNet would otherwise sit in 'Disconnected' state and block re-peering.
                az network vnet peering delete -g $ResourceGroup --vnet-name $keptVnet -n "to-$suffix" --output none 2>$null
                az network vnet delete -g $ResourceGroup -n $t.Name --output none
            }
        }
        if ($LASTEXITCODE -ne 0) { Write-Error "Failed to delete $($t.Name) - see the az error above. Re-run remove to retry."; exit 1 }
    }
    Remove-Item $KnownHostsFile -Force -ErrorAction SilentlyContinue
    Write-Host ''
    Write-Host "Removed the $Role node '$base'. '$NamePrefix-$keptSuffix' is untouched." -ForegroundColor Green
    if ($Role -eq 'secondary') {
        Write-Host "Rebuild it and re-add it to the AG with:"
        Write-Host "  ./deploy.ps1 -Action deploy -Identifier $Identifier -PrimaryNodeSuffix $PrimaryNodeSuffix -SecondaryNodeSuffix $SecondaryNodeSuffix"
    }
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

if (-not $Action) {
    $Action = Read-Choice -Prompt 'What do you want to do?' -Default 'deploy' `
        -Options @('deploy', 'remove', 'status', 'output', 'refresh-access', 'failover-to-secondary') `
        -Descriptions @('create or resume a stack', 'delete a whole stack or one node', 'VM power state',
                        'connection info', 'allow your current IP on SSH/SQL', 'force failover to the secondary')
}

$idHint = 'Use 1-15 lowercase letters, digits or hyphens (no leading/trailing hyphen), e.g. 257672.'
if (-not $Identifier) {
    $Identifier = Read-Value -Prompt 'Unique identifier for the object names (e.g. 257672)' -Default '' -Hint $idHint -Validate { param($v) Test-Identifier $v }
}
$Identifier = $Identifier.ToLower()
if (-not (Test-Identifier $Identifier)) { Write-Error "Invalid identifier '$Identifier'. $idHint"; exit 1 }

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
$DeploymentName = if ($StackName.Length -gt 64) { $StackName.Substring(0, 64) } else { $StackName }
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

$RgExists = (az group exists --name $ResourceGroup) -eq 'true'

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

    # 2. What already exists? An existing node's region is fixed, so it isn't asked for.
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

    $RebuildSecondary = $false
    if ($pri -and $sec) {
        $PrimaryLocation   = $pri.location
        $SecondaryLocation = $sec.location
        $VmSize = $pri.vmSize
        Write-Host "Existing stack - using its regions (primary=$PrimaryLocation, secondary=$SecondaryLocation) and VM size ($VmSize)" -ForegroundColor Yellow
    } elseif ($sec) {
        # The AG was created on the primary-suffix node; rebuilding that node in place would
        # create a second, unrelated AG next to the one the secondary still holds.
        Write-Error @"
The primary node '$PrimaryVmName' is missing but the secondary '$SecondaryVmName' exists.
A primary node can't be rebuilt into an existing AG in place. Options:
  - keep '$SecondaryVmName' as a standalone server (fail over to it if you haven't), or
  - start over: ./deploy.ps1 -Action remove -RemoveScope stack -Identifier $Identifier -PrimaryNodeSuffix $PrimaryNodeSuffix -SecondaryNodeSuffix $SecondaryNodeSuffix
"@
        exit 1
    } elseif ($pri) {
        # Secondary was removed (./deploy.ps1 -Action remove -RemoveScope secondary): rebuild it
        # and re-add it to the AG that lives on the primary.
        $RebuildSecondary = $true
        $PrimaryLocation  = $pri.location
        # Both nodes are deployed from one template with one size - the rebuilt secondary must
        # match the live primary, or the redeploy would resize the primary.
        if ($VmSize -and $VmSize -ne $pri.vmSize) {
            Write-Host "Ignoring -VmSize $VmSize - the rebuilt secondary uses the primary's size ($($pri.vmSize))." -ForegroundColor Yellow
        }
        $VmSize = $pri.vmSize
        Write-Host ''
        Write-Host "Only the primary exists - the secondary '$SecondaryVmName' will be rebuilt and re-added to AG '$AgName'." -ForegroundColor Yellow
        Write-Host "Primary region (existing): $PrimaryLocation"
        if (-not $SecondaryLocation) { $SecondaryLocation = Read-Region -Role 'secondary' -Default $PrimaryLocation }
        $SecondaryLocation = $SecondaryLocation.ToLower()
        if (-not (Test-RegionName $SecondaryLocation)) { Write-Error "Unknown Azure region '$SecondaryLocation'."; exit 1 }
        Write-Host ''
        Write-Host "=== Validating '$VmSize' availability ===" -ForegroundColor Cyan
        $SecondaryLocation = Confirm-RegionCapacity -Role 'secondary' -Location $SecondaryLocation -VmCount 1
    } else {
        if (-not $PrimaryLocation)   { $PrimaryLocation   = Read-Region -Role 'primary'   -Default 'eastus' }
        if (-not $SecondaryLocation) { $SecondaryLocation = Read-Region -Role 'secondary' -Default 'westus2' }
        $PrimaryLocation   = $PrimaryLocation.ToLower()
        $SecondaryLocation = $SecondaryLocation.ToLower()
        foreach ($r in @($PrimaryLocation, $SecondaryLocation)) {
            if (-not (Test-RegionName $r)) { Write-Error "Unknown Azure region '$r'."; exit 1 }
        }

        if (-not $VmSize -and $AutoApprove) {
            $VmSize = 'Standard_D4as_v7'
            Write-Host "No -VmSize given with -AutoApprove - using $VmSize." -ForegroundColor Yellow
        }
        if ($VmSize) {
            # Size given up front: pre-validate SKU restrictions + quota before committing to a
            # 15-20 minute deployment.
            Write-Host ''
            Write-Host "=== Validating '$VmSize' availability ===" -ForegroundColor Cyan
            $sameRegion = $PrimaryLocation -eq $SecondaryLocation
            $PrimaryLocation = Confirm-RegionCapacity -Role 'primary' -Location $PrimaryLocation -VmCount $(if ($sameRegion) { 2 } else { 1 })
            if ($sameRegion) { $SecondaryLocation = $PrimaryLocation }
            else { $SecondaryLocation = Confirm-RegionCapacity -Role 'secondary' -Location $SecondaryLocation -VmCount 1 }
        } else {
            # List what's actually usable in the chosen regions and let the user pick.
            while (-not $VmSize) {
                $VmSize = Select-VmSize -PrimaryRegion $PrimaryLocation -SecondaryRegion $SecondaryLocation
                if ($VmSize) { break }
                Write-Host ''
                Write-Host "No VM size passes the checks in $PrimaryLocation / $SecondaryLocation (usually vCPU quota)." -ForegroundColor Yellow
                $answer = (Read-Line "Enter other regions as 'primary,secondary' (e.g. eastus,westus2), or 'quit'").ToLower()
                if ($answer -eq 'quit') { Write-Host 'Cancelled.'; exit 0 }
                $parts = @($answer -split '[,\s]+' | Where-Object { $_ })
                if ($parts.Count -eq 2 -and (Test-RegionName $parts[0]) -and (Test-RegionName $parts[1])) {
                    $PrimaryLocation = $parts[0]; $SecondaryLocation = $parts[1]
                } else {
                    Write-Host "  '$answer' is not two valid Azure region names." -ForegroundColor Yellow
                }
            }
        }
    }
    Write-Host "Primary region   : $PrimaryLocation" -ForegroundColor Green
    Write-Host "Secondary region : $SecondaryLocation" -ForegroundColor Green
    Write-Host "VM size          : $VmSize" -ForegroundColor Green
    if ($PrimaryLocation -eq $SecondaryLocation) {
        Write-Host 'Both nodes are in the same region (regional VNet peering, no cross-region DR).' -ForegroundColor Yellow
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
        Write-Host '=== Choosing VNet address spaces ===' -ForegroundColor Cyan
        $Cidrs = Resolve-VnetCidrs
        Write-Host "  Primary VNet   : $($Cidrs.primary)"
        Write-Host "  Secondary VNet : $($Cidrs.secondary)"

        Write-Host ''
        Write-Host '=== Deploying Azure infrastructure ===' -ForegroundColor Cyan
        if ($RebuildSecondary) {
            Write-Host 'The whole template is re-applied: the primary VM is updated in place (not recreated).' -ForegroundColor Yellow
        }
        az bicep install 2>$null | Out-Null

        # Per-run values go into a temp parameters file instead of the command line, which
        # sidesteps native-argument quoting of the SSH key / JSON arrays on every OS.
        $runParams = [ordered]@{
            prefix                = @{ value = $Prefix }
            environment           = @{ value = $Identifier }
            primaryNodeSuffix     = @{ value = $PrimaryNodeSuffix }
            secondaryNodeSuffix   = @{ value = $SecondaryNodeSuffix }
            resourceGroupName     = @{ value = $ResourceGroup }
            primaryLocation       = @{ value = $PrimaryLocation }
            secondaryLocation     = @{ value = $SecondaryLocation }
            primaryAddressSpace   = @{ value = $Cidrs.primary }
            secondaryAddressSpace = @{ value = $Cidrs.secondary }
            vmSize                = @{ value = $VmSize }
            sshPublicKey          = @{ value = $SshPublicKey }
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
            --name $DeploymentName `
            --location $PrimaryLocation `
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

    $PriName = $pri.nodeName; $PriIP = $pri.publicIP; $PriPrivateIP = $pri.privateIP
    $SecName = $sec.nodeName; $SecIP = $sec.publicIP; $SecPrivateIP = $sec.privateIP

    Write-Host ''
    Write-Host '=== Infrastructure ready ===' -ForegroundColor Green
    Write-Host "Primary   ($PriName, $PrimaryLocation): $PriIP (private $PriPrivateIP)"
    Write-Host "Secondary ($SecName, $SecondaryLocation): $SecIP (private $SecPrivateIP)"

    # 6. SSH reachability
    if (-not (Wait-ForSSH -IP $PriIP)) { exit 1 }
    if (-not (Wait-ForSSH -IP $SecIP)) { exit 1 }

    # 7. Which nodes need SQL Server? install-sqlserver.sh wipes /var/opt/mssql/data, so a
    #    node that already answers to $SaPassword must be left alone.
    Write-Host ''
    Write-Host '=== Checking whether SQL Server is already installed on each node ===' -ForegroundColor Cyan
    $NodeList = @(
        @{ Name = $PriName; IP = $PriIP; Label = "primary ($PriName)" },
        @{ Name = $SecName; IP = $SecIP; Label = "secondary ($SecName)" }
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
                (Join-Path $HOME 'Downloads' 'Rhel9.zip')
            ) | Where-Object { Test-Path $_ } | Select-Object -First 1
        }
        while (-not $RhelZipPath -or -not (Test-Path $RhelZipPath)) {
            if ($AutoApprove) {
                Write-Error 'Rhel9.zip not found next to deploy.ps1 or in ~/Downloads - pass -RhelZipPath.'
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

    # 9-15. AG phases. Every ag-*.sh guards its work against the live server state, so re-running
    #       only does what's missing - including re-adding a rebuilt secondary (ag-02 replaces
    #       its changed certificate, ag-03 re-adds its replica / refreshes its endpoint URL).
    Write-Host ''
    Write-Host '=== Configuring Always On endpoints (both nodes) ===' -ForegroundColor Cyan
    foreach ($ip in @($PriIP, $SecIP)) {
        Invoke-NodeScript $ip 'ag-01-endpoint.sh' @($SaPassword, $CertPassword)
    }

    Write-Host ''
    Write-Host '=== Exchanging AG certificates between nodes ===' -ForegroundColor Cyan
    $CertDir = Join-Path ([System.IO.Path]::GetTempPath()) "$StackName-certs"
    New-Item -ItemType Directory -Force -Path $CertDir | Out-Null
    $PriCert = Join-Path $CertDir "$PrimaryNodeSuffix.cer"
    $SecCert = Join-Path $CertDir "$SecondaryNodeSuffix.cer"
    Copy-FromRemote $PriIP '/tmp/dbm_certificate.cer' $PriCert
    Copy-FromRemote $SecIP '/tmp/dbm_certificate.cer' $SecCert
    Copy-ToRemote $PriIP $SecCert '/tmp/peer_dbm_certificate.cer'
    Copy-ToRemote $SecIP $PriCert '/tmp/peer_dbm_certificate.cer'
    Remove-Item $CertDir -Recurse -Force -ErrorAction SilentlyContinue

    Invoke-NodeScript $PriIP 'ag-02-trust-peer.sh' @($SaPassword, $SecName, $AgLoginPassword)
    Invoke-NodeScript $SecIP 'ag-02-trust-peer.sh' @($SaPassword, $PriName, $AgLoginPassword)

    Write-Host ''
    Write-Host "=== Creating Availability Group '$AgName' on the primary ===" -ForegroundColor Cyan
    Invoke-NodeScript $PriIP 'ag-03-create-primary.sh' @($SaPassword, $AgName, $PriName, $PriPrivateIP, $SecName, $SecPrivateIP)

    Write-Host '=== Joining the secondary to the Availability Group ===' -ForegroundColor Cyan
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
    Write-Host "  AG name          : $AgName"
    Write-Host "  VM size          : $VmSize"
    Write-Host "  Databases in AG  : $DemoDbName, WideWorldImporters"
    Write-Host ''
    Write-Host "  PRIMARY   $PriName ($PrimaryLocation)"
    Write-Host "    SSH  : ssh -i `"$SshKeyPath`" $AdminUser@$PriIP"
    Write-Host "    SSMS : $PriIP,1433  (Login SA, readable+writable)"
    Write-Host ''
    Write-Host "  SECONDARY $SecName ($SecondaryLocation)"
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
                            "only the primary node's objects ($NamePrefix-$PrimaryNodeSuffix-*)",
                            "only the secondary node's objects ($NamePrefix-$SecondaryNodeSuffix-*) - deploy can rebuild it")
    }

    if ($RemoveScope -in @('primary', 'secondary')) {
        Remove-SingleNode -Role $RemoveScope
    } else {
        Write-Host ''
        Write-Host "Objects in $ResourceGroup that will be PERMANENTLY deleted:" -ForegroundColor Yellow
        az resource list --resource-group $ResourceGroup --query '[].{name:name, type:type, location:location}' -o table
        Write-Host ''
        Write-Host 'Both VMs, their disks, networking, Bastion (if any) and all AG data will be gone.' -ForegroundColor Yellow
        Confirm-Yes "Type 'yes' to delete '$ResourceGroup'"

        Write-Host "Deleting $ResourceGroup (typically 5-10 minutes) ..."
        az group delete --name $ResourceGroup --yes
        if ($LASTEXITCODE -ne 0) { Write-Error 'Delete failed - see the az error output above.'; exit 1 }

        # Subscription-scope deployment record + local state for this stack.
        az deployment sub delete --name $DeploymentName 2>$null | Out-Null
        Remove-Item $CredsFile, $KnownHostsFile -Force -ErrorAction SilentlyContinue
        Write-Host "Removed $ResourceGroup and its saved credentials." -ForegroundColor Green
    }
}

# ── STATUS / OUTPUT / REFRESH-ACCESS / FAILOVER (all read the live resources) ──
else {
    if (-not $RgExists) {
        Write-Error "Resource group '$ResourceGroup' not found. Deploy it first (or check the suffixes / -Identifier)."
        exit 1
    }
    $pri = Get-NodeInfo $PrimaryNodeSuffix
    $sec = Get-NodeInfo $SecondaryNodeSuffix

    if ($Action -eq 'status') {
        foreach ($pair in @(@('primary', $PrimaryVmName, $pri), @('secondary', $SecondaryVmName, $sec))) {
            $n = $pair[2]
            if ($n) {
                Write-Host ("  {0,-9} {1,-40} {2,-15} {3,-18} {4}" -f $pair[0], $n.name, $n.location, $n.powerState, $n.publicIP)
            } else {
                Write-Host ("  {0,-9} {1,-40} NOT FOUND" -f $pair[0], $pair[1]) -ForegroundColor Yellow
            }
        }
    }
    elseif ($Action -eq 'output') {
        foreach ($pair in @(@('PRIMARY', $pri), @('SECONDARY', $sec))) {
            $n = $pair[1]
            if (-not $n) { Write-Host "  $($pair[0]): not found" -ForegroundColor Yellow; continue }
            Write-Host ''
            Write-Host "  $($pair[0]) $($n.nodeName) ($($n.location))"
            Write-Host "    SSH  : ssh -i `"$SshKeyPath`" $AdminUser@$($n.publicIP)"
            Write-Host "    SSMS : $($n.publicIP),1433   private IP: $($n.privateIP)"
        }
        Write-Host ''
        Write-Host "  AG name (default for this stack): $AgName"
        if (Test-Path $CredsFile) { Write-Host "  Credentials: $CredsFile" }
    }
    elseif ($Action -eq 'refresh-access') {
        # Default: this machine's current public IP. -AllowedSourceIps overrides (e.g. several CIDRs).
        $list = if ($AllowedSourceIps.Count -gt 0) { $AllowedSourceIps } else { @('auto') }
        $SourceCidrs = @(ConvertTo-SourceCidrs $list)
        Write-Host ''
        Write-Host "Setting SSH (22) / SQL (1433) sources to: $($SourceCidrs -join ', ')" -ForegroundColor Cyan
        Update-NsgAccess $SourceCidrs
    }
    elseif ($Action -eq 'failover-to-secondary') {
        Assert-Tool 'ssh'
        Import-SavedCredentials
        if (-not $SaPassword) { Write-Error 'No saved credentials for this stack - pass -SaPassword.'; exit 1 }
        if (-not $sec) { Write-Error "Secondary VM '$SecondaryVmName' not found."; exit 1 }

        Write-Host "Failing over AG '$AgName' to $($sec.nodeName) ($($sec.publicIP))."
        Write-Host 'The secondary runs ASYNCHRONOUS_COMMIT, so this uses FORCE_FAILOVER_ALLOW_DATA_LOSS.' -ForegroundColor Yellow
        Confirm-Yes "Type 'yes' to confirm possible data loss"
        # FORCE_FAILOVER_ALLOW_DATA_LOSS is its own top-level ALTER AVAILABILITY GROUP option.
        Invoke-Remote $sec.publicIP "/opt/mssql-tools18/bin/sqlcmd -S localhost -U SA -P '$SaPassword' -No -C -b -Q `"ALTER AVAILABILITY GROUP [$AgName] FORCE_FAILOVER_ALLOW_DATA_LOSS;`""
        Write-Host 'Failover command issued. Verify roles with sys.dm_hadr_availability_replica_states on both nodes.'
    }
}

} finally {
    Stop-Transcript | Out-Null
}
