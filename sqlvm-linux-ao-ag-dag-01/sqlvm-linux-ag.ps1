#Requires -Version 7.0
<#
.SYNOPSIS
    SQL Server on Linux Always On lab: deploy, remove, check and operate 2-node AG stacks (RHEL 9,
    CLUSTER_TYPE = NONE) and the Distributed AGs that link them, and run the failure use cases.

.DESCRIPTION
    Run it without -Action / -UseCase for the menu:
      1) Deploy     - stack (2-node AG), Distributed AG link
      2) Remove     - stack or one node, Distributed AG link
      3) Check      - stack status, connection info, Distributed AG status
      4) Operate    - refresh SSH/SQL access, failover to secondary
      5) Use cases  - failure drills and runbooks, discovered from use-cases/uc-NN/uc-NN.ps1

    Then anything not passed on the command line is asked for:
      Unique identifier      - part of every object name, e.g. 257672 (asked once, also passed to use cases)
      Primary node suffix    - e.g. node-1
      Secondary node suffix  - e.g. node-2
      Regions / VM size      - deploy of a new stack only
      SSH/SQL access         - deploy only: your current public IP, parameters.json, or a CIDR list
      Remove scope           - remove only: whole stack, primary node only, secondary node only
      Forwarder suffixes     - Distributed AG actions only

    Object naming (prefix defaults to 'sqlvm'; <id> is the unique identifier you're asked for):
      Resource group : <prefix>-<id>-<primarySuffix>-<secondarySuffix>-rg
      Per node       : <prefix>-<id>-<suffix>-{vm,nic,nsg,pip,vnet,sqldata,osdisk}
      AG replica     : <prefix>-<id>-<suffix>   (the VM hostname)

    Each suffix pair is its own independent stack, so node-1/node-2 and node-3/node-4 can
    run side by side in the same subscription. VNet address spaces are picked automatically so
    they don't overlap any other VNet in the subscription (required to peer stacks later, e.g.
    for a Distributed AG).

.EXAMPLE
    ./sqlvm-linux-ag.ps1
    # menu

.EXAMPLE
    ./sqlvm-linux-ag.ps1 -Action deploy -Identifier 257672 -PrimaryNodeSuffix node-1 -SecondaryNodeSuffix node-2 -PrimaryLocation eastus -SecondaryLocation westus2 -AllowedSourceIps auto

.EXAMPLE
    ./sqlvm-linux-ag.ps1 -Action deploy-dag -Identifier ag01 -PrimaryNodeSuffix node-1 -SecondaryNodeSuffix node-2 -DagForwarderIdentifier ag02 -DagForwarderPrimarySuffix node-3 -DagForwarderSecondarySuffix node-4
    # Distributed AG: AG of ag01 node-1/node-2 = global primary, AG of ag02 node-3/node-4 = forwarder

.EXAMPLE
    ./sqlvm-linux-ag.ps1 -Action remove -Identifier 257672 -PrimaryNodeSuffix node-1 -SecondaryNodeSuffix node-2 -RemoveScope secondary
    # removes only node-2's objects; a later -Action deploy recreates it and re-adds it to the AG

.EXAMPLE
    ./sqlvm-linux-ag.ps1 -UseCase uc-01 -UseCaseAction status -Identifier 257672
    # runs use-cases/uc-01/uc-01.ps1 -Action status (it asks for its own remaining inputs)
#>
param(
    [ValidateSet('', 'deploy', 'remove', 'status', 'output', 'refresh-access', 'failover-to-secondary', 'deploy-dag', 'status-dag', 'remove-dag')]
    [string]$Action = '',

    # Use cases: use-cases/<id>/<id>.ps1, e.g. -UseCase uc-01 (or 1). -UseCaseAction is passed to it
    # as its -Action; anything it still needs, it asks for itself.
    [string]$UseCase       = '',
    [string]$UseCaseAction = '',

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
    # Distributed AG (deploy-dag / status-dag / remove-dag): -Identifier/-PrimaryNodeSuffix/
    # -SecondaryNodeSuffix name the GLOBAL PRIMARY stack, the DagForwarder* ones the FORWARDER stack.
    # -DagForwarderIdentifier defaults to -Identifier (both stacks deployed with the same identifier).
    [string]$DagForwarderIdentifier      = '',
    [string]$DagForwarderPrimarySuffix   = '',
    [string]$DagForwarderSecondarySuffix = '',
    # Defaults to 'dagsqlvm-<global primary suffix>-<forwarder primary suffix>'.
    [string]$DagName = '',
    # deploy-dag drops the forwarder AG's existing databases; by default it backs them up first.
    [switch]$SkipForwarderBackup,
    [string]$DemoDbName = 'AGDemoDB',
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
# Deletes one node's objects (VM, NIC, PIP, NSG, disks, its VNet and the peer's
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
        Write-Host 'Note: sqlvm-linux-ag.ps1 can rebuild a removed SECONDARY node in place. A removed primary node' -ForegroundColor Yellow
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
        Write-Host "  ./sqlvm-linux-ag.ps1 -Action deploy -Identifier $Identifier -PrimaryNodeSuffix $PrimaryNodeSuffix -SecondaryNodeSuffix $SecondaryNodeSuffix"
    }
}

# ── Distributed AG (deploy-dag / status-dag / remove-dag) ──────────────────────
# Links the AG of one stack (GLOBAL PRIMARY: source of the databases) to the AG of another stack
# (FORWARDER: receives them) with a distributed AG. Direct SSH/1433 can be blocked by subscription
# policy, so every step runs through 'az vm run-command' (Azure control plane) instead of ssh/scp.

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

function Get-RcVal  { param($Result, [string]$Key) if ($Result.Values.ContainsKey($Key)) { $Result.Values[$Key][0] } else { $null } }
function Get-RcVals { param($Result, [string]$Key) if ($Result.Values.ContainsKey($Key)) { @($Result.Values[$Key]) } else { @() } }

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
    param($Node, [string]$Script, [string[]]$Arguments, [string]$Label = $Script, [string]$Prefix = '')
    return @{ Rg = $Node.Rg; Vm = $Node.Vm; Label = $Label; Body = $Prefix + (Get-NodeScriptBody -Script $Script -Arguments $Arguments) }
}

function Invoke-NodeScriptRc {
    param($Node, [string]$Script, [string[]]$Arguments, [string]$Label = $Script, [string]$Prefix = '')
    $r = @(Invoke-RunCommandBatch @(New-NodeScriptRequest -Node $Node -Script $Script -Arguments $Arguments -Label $Label -Prefix $Prefix))[0]
    Assert-RcOk $r
    return $r
}

# One node of either stack, with everything the DAG steps need.
function New-DagNode {
    param([string]$StackIdentifier, [string]$Suffix, [string]$StackPrimary, [string]$StackSecondary, [string]$Stack, [string]$AgName)
    $prefix = "$Prefix-$StackIdentifier"
    $rg = "$prefix-$StackPrimary-$StackSecondary-rg"
    $credsFile = Join-Path $StateDir "$rg.credentials.json"
    if (-not (Test-Path $credsFile)) { Write-Error "No saved credentials for $rg ($credsFile) - was it deployed with this script?"; exit 1 }
    $creds = Get-Content $credsFile -Raw | ConvertFrom-Json
    $ip = az network nic show -g $rg -n "$prefix-$Suffix-nic" --query 'ipConfigurations[0].privateIPAddress' -o tsv 2>$null
    if (-not $ip) { Write-Error "NIC of '$prefix-$Suffix' not found in $rg."; exit 1 }
    return [pscustomobject]@{
        Identifier = $StackIdentifier; Suffix = $Suffix; Name = "$prefix-$Suffix"; Vm = "$prefix-$Suffix-vm"; Nsg = "$prefix-$Suffix-nsg"
        Vnet = "$prefix-$Suffix-vnet"; Rg = $rg; Stack = $Stack; Ag = $AgName; PrivateIp = $ip
        Sa = $creds.SaPassword; AgLoginPassword = $creds.AgLoginPassword
    }
}

function Get-DagPowerStates {
    param([object[]]$AllNodes)
    foreach ($n in $AllNodes) {
        $state = az vm get-instance-view -g $n.Rg -n $n.Vm --query "instanceView.statuses[?starts_with(code, 'PowerState/')].code | [0]" -o tsv 2>$null
        $n | Add-Member -NotePropertyName Power -NotePropertyValue ($(if ($state) { $state -replace '^PowerState/', '' } else { 'unknown' })) -Force
    }
}

# dag-06-status.sh on every running node; returns @{ <vm> = result }.
function Get-DagStatus {
    param([object[]]$Nodes)
    $running = @($Nodes | Where-Object { $_.Power -eq 'running' })
    $results = @{}
    if ($running.Count -eq 0) { return $results }
    $batch = @(Invoke-RunCommandBatch @($running | ForEach-Object { New-NodeScriptRequest -Node $_ -Script 'dag-06-status.sh' -Arguments @($_.Sa, $DagName) -Label 'DAG status' }))
    Assert-RcOk $batch
    foreach ($r in $batch) { $results[$r.Vm] = $r }
    return $results
}

function Get-LocalAgRole {
    param($Result, [string]$Ag)
    foreach ($l in (Get-RcVals $Result 'LOCAL_AG')) { $p = $l.Split('|'); if ($p[0] -eq $Ag) { return $p[1] } }
    return 'NONE'
}

function Show-DagStatus {
    param([object[]]$Nodes, [hashtable]$Status)
    foreach ($n in $Nodes) {
        Write-Host ''
        Write-Host ("  {0} ({1}, {2}) - {3}" -f $n.Name, $n.Stack, $n.Ag, $n.Power) -ForegroundColor White
        $r = $Status[$n.Vm]
        if (-not $r) { continue }
        foreach ($k in @('LOCAL_AG', 'DAG_EXISTS', 'DAG_MEMBER', 'DAG_DB', 'LOCAL_DB')) {
            foreach ($v in (Get-RcVals $r $k)) { Write-Host ("    {0,-10} {1}" -f $k, $v) }
        }
    }
}

function Add-DagPeering {
    param($From, $To)
    # Same identifier: 'to-<suffix>'. Different identifiers: 'to-<identifier>-<suffix>' - a VNet may
    # already have a 'to-<suffix>' peering to a same-suffix node of another stack.
    $name = if ($From.Identifier -eq $To.Identifier) { "to-$($To.Suffix)" } else { "to-$($To.Identifier)-$($To.Suffix)" }
    # An existing peering is found by its REMOTE VNet, whatever its name (Azure allows only one per
    # remote VNet, and earlier runs may have used another naming).
    $existing = @(az network vnet peering list -g $From.Rg --vnet-name $From.Vnet `
        --query "[].{n:name, s:peeringState, r:remoteVirtualNetwork.id}" -o json 2>$null | ConvertFrom-Json) |
        Where-Object { $_.r -and $_.r.ToLower() -eq $To.VnetId.ToLower() } | Select-Object -First 1
    $state = if ($existing) { "$($existing.s) ($($existing.n))" } else { $null }
    if (-not $state) {
        az network vnet peering create -g $From.Rg --vnet-name $From.Vnet -n $name --remote-vnet $To.VnetId --allow-vnet-access -o none
        if ($LASTEXITCODE -ne 0) { Write-Error "Failed to peer $($From.Vnet) -> $($To.Vnet)."; exit 1 }
        $state = 'created'
    }
    Write-Host "  peering $($From.Vnet) -> $($To.Vnet): $state"
}

# NSG rule on one node allowing the AG endpoint (5022) from the other stack's VNets. One rule PER
# LINKED STACK ('allow-ag-endpoint-from-dag-<peer primary suffix>'): a global primary AG can be in
# several distributed AGs (one per forwarder), and a shared rule name would make each deploy-dag
# overwrite the previous link's sources.
function Set-DagNsgRule {
    param($Node, [string]$PeerSuffix, [string[]]$Sources, [string]$PeerIdentifier = '')
    $name  = if ($PeerIdentifier -and $PeerIdentifier -ne $Node.Identifier) { "allow-ag-endpoint-from-dag-$PeerIdentifier-$PeerSuffix" } else { "allow-ag-endpoint-from-dag-$PeerSuffix" }
    $rules = @(az network nsg rule list -g $Node.Rg --nsg-name $Node.Nsg `
        --query "[?direction=='Inbound'].{n:name, p:priority, s:sourceAddressPrefixes}" -o json 2>$null | ConvertFrom-Json)
    $existing = $rules | Where-Object { $_.n -eq $name } | Select-Object -First 1
    $priority = if ($existing) { $existing.p } else {
        $used = @($rules | ForEach-Object { [int]$_.p })
        130..199 | Where-Object { $used -notcontains $_ } | Select-Object -First 1
    }
    if (-not $priority) { Write-Error "No free NSG priority (130-199) on $($Node.Nsg)."; exit 1 }
    az network nsg rule create -g $Node.Rg --nsg-name $Node.Nsg -n $name --priority $priority `
        --direction Inbound --access Allow --protocol Tcp --destination-port-ranges 5022 `
        --source-address-prefixes @Sources --description "Distributed AG: AG endpoint from stack $PeerSuffix" -o none
    if ($LASTEXITCODE -ne 0) { Write-Error "Failed to update NSG $($Node.Nsg)."; exit 1 }
    Write-Host "  $($Node.Nsg): $name (priority $priority) - 5022 from $($Sources -join ', ')"
    # Earlier versions used one shared rule name for every link: drop it once this link has its own rule.
    $legacy = $rules | Where-Object { $_.n -eq 'allow-ag-endpoint-from-dag' } | Select-Object -First 1
    if ($legacy -and -not (Compare-Object @($legacy.s | Sort-Object) @($Sources | Sort-Object))) {
        az network nsg rule delete -g $Node.Rg --nsg-name $Node.Nsg -n 'allow-ag-endpoint-from-dag' -o none 2>$null
        Write-Host "  $($Node.Nsg): replaced legacy rule allow-ag-endpoint-from-dag"
    }
}

# VNet peering between every node VNet of one stack and every node VNet of the other (any node can
# hold the global primary / forwarder role after a local failover), plus an NSG rule on every node
# allowing the AG endpoint (5022) from the other stack's VNets.
function Add-DagNetworking {
    param([object[]]$GpNodes, [object[]]$FwNodes)
    Write-Host ''
    Write-Host '=== Networking: cross-stack VNet peering + AG endpoint (5022) rules ===' -ForegroundColor Cyan
    foreach ($n in @($GpNodes) + @($FwNodes)) {
        $v = az network vnet show -g $n.Rg -n $n.Vnet --query '{id:id, space:addressSpace.addressPrefixes[0]}' -o json 2>$null | ConvertFrom-Json
        if (-not $v) { Write-Error "VNet $($n.Vnet) not found in $($n.Rg)."; exit 1 }
        $n | Add-Member -NotePropertyName VnetId -NotePropertyValue $v.id -Force
        $n | Add-Member -NotePropertyName Space  -NotePropertyValue $v.space -Force
    }
    foreach ($a in $GpNodes) {
        foreach ($b in $FwNodes) {
            if (Test-CidrOverlap $a.Space $b.Space) {
                Write-Error "$($a.Vnet) ($($a.Space)) overlaps $($b.Vnet) ($($b.Space)) - overlapping VNets can't be peered. Redeploy one stack with other ranges."
                exit 1
            }
        }
    }
    foreach ($a in $GpNodes) { foreach ($b in $FwNodes) { Add-DagPeering $a $b; Add-DagPeering $b $a } }
    # Rules are named after the OTHER stack's primary suffix (the stack's first node, as in its RG name).
    $gpSources = @($GpNodes | ForEach-Object { $_.Space }); $fwSources = @($FwNodes | ForEach-Object { $_.Space })
    foreach ($n in $GpNodes) { Set-DagNsgRule -Node $n -PeerSuffix $FwNodes[0].Suffix -PeerIdentifier $FwNodes[0].Identifier -Sources $fwSources }
    foreach ($n in $FwNodes) { Set-DagNsgRule -Node $n -PeerSuffix $GpNodes[0].Suffix -PeerIdentifier $GpNodes[0].Identifier -Sources $gpSources }
}

# Every node trusts the mirroring certificate of every node in the OTHER stack (login + certificate
# + CONNECT on the endpoint, via ag-02-trust-peer.sh, which also replaces a changed certificate).
function Set-DagCertificateTrust {
    param([object[]]$GpNodes, [object[]]$FwNodes)
    Write-Host ''
    Write-Host '=== Certificate trust between the two stacks ===' -ForegroundColor Cyan
    $all = @($GpNodes) + @($FwNodes)
    $export = @(Invoke-RunCommandBatch @($all | ForEach-Object { New-NodeScriptRequest -Node $_ -Script 'dag-01-export-cert.sh' -Arguments @($_.Sa) -Label 'export certificate' }))
    Assert-RcOk $export
    $certs = @{}
    foreach ($r in $export) { $certs[$r.Vm] = Get-RcVal $r 'CERT_B64' }

    $requests = foreach ($n in $all) {
        $peers = if ($n.Stack -eq 'global-primary') { $FwNodes } else { $GpNodes }
        $body = ''
        foreach ($p in $peers) {
            if (-not $certs[$p.Vm]) { Write-Error "No certificate exported from $($p.Vm)."; exit 1 }
            $body += "echo '$($certs[$p.Vm])' | base64 -d > /tmp/peer_dbm_certificate.cer`n"
            $body += (Get-NodeScriptBody -Script 'ag-02-trust-peer.sh' -Arguments @($n.Sa, $p.Name, $n.AgLoginPassword)) + "`n"
        }
        @{ Rg = $n.Rg; Vm = $n.Vm; Label = "trust $(@($peers | ForEach-Object { $_.Suffix }) -join ', ')"; Body = $body }
    }
    $trust = @(Invoke-RunCommandBatch @($requests))
    Assert-RcOk $trust
    Write-Host '  All four nodes trust the other stack''s endpoints.' -ForegroundColor Green
}

function Invoke-DagAction {
    $fwId = $DagForwarderIdentifier
    $fwP  = $DagForwarderPrimarySuffix
    $fwS  = $DagForwarderSecondarySuffix
    if (-not $fwId) { $fwId = Read-Value -Prompt 'Forwarder stack - unique identifier (e.g. ag02)' -Default $Identifier -Hint $idHint -Validate { param($v) Test-Identifier $v } }
    $fwId = $fwId.ToLower()
    if (-not (Test-Identifier $fwId)) { Write-Error "Invalid forwarder identifier '$fwId'. $idHint"; exit 1 }
    if (-not $fwP) { $fwP = Read-Value -Prompt 'Forwarder stack - primary node suffix (e.g. node-3)' -Default 'node-3' -Hint $suffixHint -Validate { param($v) Test-Suffix $v } }
    if (-not $fwS) { $fwS = Read-Value -Prompt 'Forwarder stack - secondary node suffix (e.g. node-4)' -Default 'node-4' -Hint $suffixHint -Validate { param($v) Test-Suffix $v } }
    $fwP = $fwP.ToLower(); $fwS = $fwS.ToLower()
    # Nodes are identified by identifier + suffix: ag01/node-1 and ag02/node-1 are different nodes.
    $allNames = @("$Identifier/$PrimaryNodeSuffix", "$Identifier/$SecondaryNodeSuffix", "$fwId/$fwP", "$fwId/$fwS")
    if (@($allNames | Select-Object -Unique).Count -ne 4) { Write-Error "The four nodes must all be different ($($allNames -join ', '))."; exit 1 }

    $gpAg = $AgName
    $fwAg = "agsqlvm-$fwP"
    # A distributed AG joins two AGs BY NAME: they can't share one. AG names default to
    # agsqlvm-<primary suffix>, so same-suffix stacks from different identifiers would collide.
    if ($gpAg -eq $fwAg) {
        Write-Error "Both stacks' AGs are named '$gpAg' - a distributed AG needs two distinct AG names. Use stacks whose primary suffixes differ, or deploy one of them with -AgName."
        exit 1
    }
    if (-not $script:DagName) { $script:DagName = "dagsqlvm-$PrimaryNodeSuffix-$fwP" }

    foreach ($rg in @("$Prefix-$Identifier-$PrimaryNodeSuffix-$SecondaryNodeSuffix-rg", "$Prefix-$fwId-$fwP-$fwS-rg")) {
        if ((az group exists -n $rg) -ne 'true') { Write-Error "Resource group '$rg' not found - deploy both stacks first (check the identifiers and suffixes)."; exit 1 }
    }
    $gpNodes = @(
        (New-DagNode -StackIdentifier $Identifier -Suffix $PrimaryNodeSuffix   -StackPrimary $PrimaryNodeSuffix -StackSecondary $SecondaryNodeSuffix -Stack 'global-primary' -AgName $gpAg),
        (New-DagNode -StackIdentifier $Identifier -Suffix $SecondaryNodeSuffix -StackPrimary $PrimaryNodeSuffix -StackSecondary $SecondaryNodeSuffix -Stack 'global-primary' -AgName $gpAg))
    $fwNodes = @(
        (New-DagNode -StackIdentifier $fwId -Suffix $fwP -StackPrimary $fwP -StackSecondary $fwS -Stack 'forwarder' -AgName $fwAg),
        (New-DagNode -StackIdentifier $fwId -Suffix $fwS -StackPrimary $fwP -StackSecondary $fwS -Stack 'forwarder' -AgName $fwAg))
    $allNodes = @($gpNodes) + @($fwNodes)

    New-Item -ItemType Directory -Force -Path $LogDir | Out-Null
    $dagLog = Join-Path $LogDir "$Action-$NamePrefix-$DagName-$(Get-Date -Format 'yyyyMMdd-HHmmss').log"
    Start-Transcript -Path $dagLog -Append | Out-Null
    try {
        Write-Host ''
        Write-Host "Action           : $Action"
        Write-Host "Distributed AG   : $DagName"
        Write-Host "Global primary AG: $gpAg ($($gpNodes[0].Name), $($gpNodes[1].Name)) - identifier $Identifier"
        Write-Host "Forwarder AG     : $fwAg ($($fwNodes[0].Name), $($fwNodes[1].Name)) - identifier $fwId"
        Write-Host "Log              : $dagLog"

        Get-DagPowerStates $allNodes
        $down = @($allNodes | Where-Object { $_.Power -ne 'running' })
        if ($down.Count -gt 0 -and $Action -ne 'status-dag') {
            Write-Host ''
            $down | ForEach-Object { Write-Host "  $($_.Vm) is '$($_.Power)'" -ForegroundColor Yellow }
            Confirm-Yes "Type 'yes' to start the VM(s) above"
            foreach ($n in $down) {
                az vm start -g $n.Rg -n $n.Vm -o none
                if ($LASTEXITCODE -ne 0) { Write-Error "Failed to start $($n.Vm)."; exit 1 }
                $n.Power = 'running'
            }
        }

        switch ($Action) {
            'status-dag' {
                Write-Host ''
                Write-Host '=== Distributed AG status ===' -ForegroundColor Cyan
                Show-DagStatus -Nodes $allNodes -Status (Get-DagStatus $allNodes)
            }
            'remove-dag' { Invoke-RemoveDag -AllNodes $allNodes -GpAg $gpAg -FwAg $fwAg }
            'deploy-dag' { Invoke-DeployDag -GpNodes $gpNodes -FwNodes $fwNodes -GpAg $gpAg -FwAg $fwAg }
        }
    } finally {
        Stop-Transcript | Out-Null
    }
}

function Invoke-DeployDag {
    param([object[]]$GpNodes, [object[]]$FwNodes, [string]$GpAg, [string]$FwAg)
    $allNodes = @($GpNodes) + @($FwNodes)

    # 1. Who is primary in each AG right now, and does the DAG already exist?
    Write-Host ''
    Write-Host '=== Current state ===' -ForegroundColor Cyan
    $status = Get-DagStatus $allNodes
    $gpPrimary = $GpNodes | Where-Object { (Get-LocalAgRole $status[$_.Vm] $GpAg) -eq 'PRIMARY' } | Select-Object -First 1
    $fwPrimary = $FwNodes | Where-Object { (Get-LocalAgRole $status[$_.Vm] $FwAg) -eq 'PRIMARY' } | Select-Object -First 1
    if (-not $gpPrimary) { Write-Error "No PRIMARY replica found for $GpAg."; exit 1 }
    if (-not $fwPrimary) { Write-Error "No PRIMARY replica found for $FwAg."; exit 1 }
    $gpSecondaries = @($GpNodes | Where-Object { $_.Vm -ne $gpPrimary.Vm })
    $fwSecondaries = @($FwNodes | Where-Object { $_.Vm -ne $fwPrimary.Vm })
    $dagExists = (Get-RcVal $status[$gpPrimary.Vm] 'DAG_EXISTS') -eq '1'
    $gpDbs = @(Get-RcVals $status[$gpPrimary.Vm] 'LOCAL_DB' | Where-Object { $_ -notmatch '\|NOT_IN_AG$' } | ForEach-Object { $_.Split('|')[0] })
    if ($gpDbs.Count -eq 0) { Write-Error "$GpAg has no databases - nothing to distribute."; exit 1 }
    Write-Host "  Global primary : $($gpPrimary.Name) ($GpAg, $($gpPrimary.PrivateIp))"
    Write-Host "  Forwarder      : $($fwPrimary.Name) ($FwAg, $($fwPrimary.PrivateIp))"
    Write-Host "  Databases      : $($gpDbs -join ', ')"
    Write-Host "  $DagName exists: $dagExists"

    # 2. Network + 3. certificates (idempotent, re-applied on every run).
    Add-DagNetworking -GpNodes $GpNodes -FwNodes $FwNodes
    Set-DagCertificateTrust -GpNodes $GpNodes -FwNodes $FwNodes

    $gpUrl = "tcp://$($gpPrimary.PrivateIp):5022"
    $fwUrl = "tcp://$($fwPrimary.PrivateIp):5022"
    if (-not $dagExists) {
        # 4. The forwarder AG must be empty: its databases come from the global primary.
        $fwDbs = @(Get-RcVals $status[$fwPrimary.Vm] 'LOCAL_DB' | Where-Object { $_ -notmatch '\|NOT_IN_AG$' } | ForEach-Object { $_.Split('|')[0] })
        if ($fwDbs.Count -gt 0) {
            Write-Host ''
            Write-Host "=== Emptying the forwarder AG $FwAg ===" -ForegroundColor Cyan
            $keep = if ($SkipForwarderBackup) { 'NO backup (-SkipForwarderBackup)' } else { "COPY_ONLY backups in /var/opt/mssql/backup/pre-dag-<db>.bak on $($fwPrimary.Name)" }
            Write-Host "  $($fwDbs -join ', ') will be REMOVED from $FwAg and DROPPED on $($FwNodes.Name -join ' and ') ($keep)," -ForegroundColor Yellow
            Write-Host "  then re-seeded from $GpAg through the distributed AG." -ForegroundColor Yellow
            Confirm-Yes "Type 'yes' to continue"
            $clear = Invoke-NodeScriptRc -Node $fwPrimary -Script 'dag-02-clear-forwarder.sh' -Arguments @($fwPrimary.Sa, $FwAg, $DagName, $(if ($SkipForwarderBackup) { '1' } else { '0' }))
            foreach ($k in @('BACKED_UP', 'REMOVED_DB', 'FORWARDER_CLEARED')) { foreach ($v in (Get-RcVals $clear $k)) { Write-Host "  $k = $v" } }
        }
        # Leftover RESTORING copies of the global primary's databases on any forwarder node (the AG
        # removal above, or an earlier interrupted run) would block seeding - drop them. ONLINE
        # databases are never dropped; the check below stops the deploy for those.
        $drop = @(Invoke-RunCommandBatch @($FwNodes | ForEach-Object { New-NodeScriptRequest -Node $_ -Script 'dag-03-drop-orphan-dbs.sh' -Arguments @($_.Sa, ($gpDbs -join ',')) -Label 'drop orphan copies' }))
        Assert-RcOk $drop
        foreach ($r in $drop) { foreach ($k in @('DROPPED_DB', 'KEPT_DB', 'WAIT_DB')) { foreach ($v in (Get-RcVals $r $k)) { Write-Host "  [$($r.Vm)] $k = $v" } } }
        # A same-named database outside any AG on the forwarder side would block seeding.
        $check = Get-DagStatus $FwNodes
        foreach ($n in $FwNodes) {
            $clash = @(Get-RcVals $check[$n.Vm] 'LOCAL_DB' | Where-Object { $gpDbs -contains $_.Split('|')[0] })
            if ($clash.Count -gt 0) { Write-Error "$($n.Name) still has database(s) named like the global primary's: $($clash -join '; '). Drop them and re-run."; exit 1 }
        }

        # 5. Create on the global primary, join on the forwarder.
        Write-Host ''
        Write-Host "=== Creating distributed AG $DagName ===" -ForegroundColor Cyan
        $create = Invoke-NodeScriptRc -Node $gpPrimary -Script 'dag-04-create.sh' -Arguments @($gpPrimary.Sa, $DagName, $GpAg, $gpUrl, $FwAg, $fwUrl)
        Write-Host "  DAG_CREATED = $(Get-RcVal $create 'DAG_CREATED')"
        $join = Invoke-NodeScriptRc -Node $fwPrimary -Script 'dag-05-join.sh' -Arguments @($fwPrimary.Sa, $DagName, $GpAg, $gpUrl, $FwAg, $fwUrl)
        Write-Host "  DAG_JOINED  = $(Get-RcVal $join 'DAG_JOINED')"
    }

    # 6. Wait for seeding: global primary -> forwarder (DAG), forwarder -> its secondary (local AG).
    Write-Host ''
    Write-Host '=== Waiting for seeding (global primary -> forwarder -> forwarder secondary) ===' -ForegroundColor Cyan
    $deadline = (Get-Date).AddMinutes(60)
    while ($true) {
        $s = Get-DagStatus (@($gpPrimary) + @($fwSecondaries))
        $dagRows = @(Get-RcVals $s[$gpPrimary.Vm] 'DAG_DB' | Where-Object { $_ -like "$FwAg|*" })
        $toForwarder = @($gpDbs | Where-Object { $db = $_; @($dagRows | Where-Object { $p = $_.Split('|'); $p[1] -eq $db -and $p[2] -in @('SYNCHRONIZING', 'SYNCHRONIZED') }).Count -gt 0 })
        $onFwSecondaries = @($gpDbs | Where-Object {
            $db = $_
            @($fwSecondaries | Where-Object { @(Get-RcVals $s[$_.Vm] 'LOCAL_DB' | Where-Object { $p = $_.Split('|'); $p[0] -eq $db -and $p[2] -ne 'NOT_IN_AG' }).Count -gt 0 }).Count -eq $fwSecondaries.Count
        })
        Write-Host ("  forwarder {0}/{1} synchronizing | forwarder secondary {2}/{1} seeded" -f $toForwarder.Count, $gpDbs.Count, $onFwSecondaries.Count)
        foreach ($r in $dagRows) { Write-Host "    DAG_DB $r" }
        if ($toForwarder.Count -eq $gpDbs.Count -and $onFwSecondaries.Count -eq $gpDbs.Count) { break }
        if ((Get-Date) -gt $deadline) { Write-Error 'Seeding did not complete within 60 minutes - check status-dag.'; exit 1 }
        Start-Sleep 45
    }

    Write-Host ''
    Write-Host '=== Distributed AG status ===' -ForegroundColor Cyan
    Show-DagStatus -Nodes $allNodes -Status (Get-DagStatus $allNodes)
    Write-Host ''
    Write-Host '================================================================' -ForegroundColor Green
    Write-Host "  Distributed AG $DagName is live"
    Write-Host "  Global primary : $GpAg on $($gpPrimary.Name)  LISTENER_URL $gpUrl"
    Write-Host "  Forwarder      : $FwAg on $($fwPrimary.Name)  LISTENER_URL $fwUrl"
    Write-Host "  Databases      : $($gpDbs -join ', ')  (read-only on the forwarder side)"
    Write-Host '  No listener (CLUSTER_TYPE = NONE): after a local failover inside either AG, update that'
    Write-Host "  AG's LISTENER_URL on both sides: ALTER AVAILABILITY GROUP [$DagName] MODIFY AVAILABILITY GROUP ON"
    Write-Host "  N'<ag>' WITH (LISTENER_URL = N'tcp://<new primary IP>:5022');"
    Write-Host '================================================================' -ForegroundColor Green
}

function Invoke-RemoveDag {
    param([object[]]$AllNodes, [string]$GpAg, [string]$FwAg)
    $status = Get-DagStatus $AllNodes
    $targets = @($AllNodes | Where-Object { $status[$_.Vm] -and (Get-RcVal $status[$_.Vm] 'DAG_EXISTS') -eq '1' -and (Get-LocalAgRole $status[$_.Vm] $_.Ag) -eq 'PRIMARY' })
    if ($targets.Count -eq 0) { Write-Host "  $DagName isn't present on any primary replica - nothing to remove." -ForegroundColor Yellow; return }
    Write-Host ''
    Write-Host "  $DagName will be dropped on $($targets.Name -join ' and '). Both AGs keep running; the forwarder's" -ForegroundColor Yellow
    Write-Host '  copies of the databases stay behind in RESTORING state (run deploy-dag again to re-link).' -ForegroundColor Yellow
    Write-Host '  VNet peering, NSG rules and certificate trust between the stacks are left in place.' -ForegroundColor Yellow
    Confirm-Yes "Type 'yes' to drop $DagName"
    # Forwarder first, then the global primary.
    $ordered = @($targets | Sort-Object { if ($_.Stack -eq 'forwarder') { 0 } else { 1 } })
    foreach ($n in $ordered) {
        $r = Invoke-NodeScriptRc -Node $n -Script 'dag-07-drop.sh' -Arguments @($n.Sa, $DagName)
        Write-Host "  $(Get-RcVal $r 'DAG_DROPPED')"
    }
}


# ── Menu (sections) + use cases ────────────────────────────────────────────────
# Stack / Distributed AG actions grouped by section. Use cases are discovered, not listed here.
$MenuSections = [ordered]@{
    'Deploy'  = @(
        @('deploy',     'Stack - 2-node AG in the regions you choose (create or resume)'),
        @('deploy-dag', 'Distributed AG - link two stacks (global primary -> forwarder)'))
    'Remove'  = @(
        @('remove',     'Stack - the whole stack, or only one of its nodes'),
        @('remove-dag', 'Distributed AG - drop the link (both AGs keep running)'))
    'Check'   = @(
        @('status',     'Stack - VM power state'),
        @('output',     'Stack - connection info (SSH / SSMS)'),
        @('status-dag', 'Distributed AG - AG + distributed AG state of both stacks'))
    'Operate' = @(
        @('refresh-access',        'Allow your current public IP on SSH (22) / SQL (1433)'),
        @('failover-to-secondary', "Force failover of a stack's AG to its secondary"))
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
    $sections = @($MenuSections.Keys) + @('Use cases')
    $summaries = @(
        'stack (2-node AG), Distributed AG link',
        'stack or one node, Distributed AG link',
        'stack status, connection info, Distributed AG status',
        'refresh SSH/SQL access, failover to secondary',
        "failure drills and runbooks ($($useCases.Count) available)")
    while ($true) {
        Write-Host ''
        Write-Host 'What do you want to do?' -ForegroundColor Cyan
        for ($i = 0; $i -lt $sections.Count; $i++) { Write-Host ("  {0}) {1,-10} - {2}" -f ($i + 1), $sections[$i], $summaries[$i]) }
        $answer = (Read-Line 'Select a section').ToLower()
        $section = $null
        if ($answer -match '^\d+$' -and [int]$answer -ge 1 -and [int]$answer -le $sections.Count) { $section = $sections[[int]$answer - 1] }
        else { $section = $sections | Where-Object { $_.ToLower() -eq $answer } | Select-Object -First 1 }
        if (-not $section) { Write-Host "  '$answer' is not a section." -ForegroundColor Yellow; continue }

        if ($section -eq 'Use cases') {
            if ($useCases.Count -eq 0) { Write-Host '  No use cases found under use-cases/.' -ForegroundColor Yellow; continue }
            $labels = @($useCases | ForEach-Object { $_.Title })
        } else {
            $labels = @($MenuSections[$section] | ForEach-Object { "{0,-22} {1}" -f $_[0], $_[1] })
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
    foreach ($name in @('Prefix', 'PrimaryNodeSuffix', 'SecondaryNodeSuffix', 'AgName')) {
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

$idHint = 'Use 1-15 lowercase letters, digits or hyphens (no leading/trailing hyphen), e.g. 257672.'
$IsDagAction = $Action -in @('deploy-dag', 'status-dag', 'remove-dag')
if ($IsDagAction -and -not $Identifier) {
    Write-Host ''
    Write-Host 'Distributed AG: first the GLOBAL PRIMARY stack (its AG is the source of the databases),' -ForegroundColor Cyan
    Write-Host 'then the FORWARDER stack (its AG receives them). Each stack has its own identifier.' -ForegroundColor Cyan
}
if (-not $Identifier) {
    $idPrompt = if ($IsDagAction) { 'Global primary stack - unique identifier (e.g. ag01)' } else { 'Unique identifier for the object names (e.g. 257672)' }
    $Identifier = Read-Value -Prompt $idPrompt -Default '' -Hint $idHint -Validate { param($v) Test-Identifier $v }
}
$Identifier = $Identifier.ToLower()
if (-not (Test-Identifier $Identifier)) { Write-Error "Invalid identifier '$Identifier'. $idHint"; exit 1 }

if ($SelectedUseCase) {
    exit (Invoke-UseCase $SelectedUseCase)
}

$suffixHint = 'Use 1-20 lowercase letters, digits or hyphens, e.g. node-1.'
if (-not $PrimaryNodeSuffix) {
    $PrimaryNodeSuffix = Read-Value -Prompt $(if ($IsDagAction) { 'Global primary stack - primary node suffix (e.g. node-1)' } else { 'Primary node objects suffix (e.g. node-1)' }) -Default 'node-1' -Hint $suffixHint -Validate { param($v) Test-Suffix $v }
}
if (-not $SecondaryNodeSuffix) {
    $SecondaryNodeSuffix = Read-Value -Prompt $(if ($IsDagAction) { 'Global primary stack - secondary node suffix (e.g. node-2)' } else { 'Secondary node objects suffix (e.g. node-2)' }) -Default 'node-2' -Hint $suffixHint -Validate { param($v) Test-Suffix $v }
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

if ($IsDagAction) {
    Invoke-DagAction
    exit 0
}

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
  - start over: ./sqlvm-linux-ag.ps1 -Action remove -RemoveScope stack -Identifier $Identifier -PrimaryNodeSuffix $PrimaryNodeSuffix -SecondaryNodeSuffix $SecondaryNodeSuffix
"@
        exit 1
    } elseif ($pri) {
        # Secondary was removed (./sqlvm-linux-ag.ps1 -Action remove -RemoveScope secondary): rebuild it
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
                Write-Error 'Rhel9.zip not found next to sqlvm-linux-ag.ps1 or in ~/Downloads - pass -RhelZipPath.'
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
        Write-Host 'Both VMs, their disks, networking and all AG data will be gone.' -ForegroundColor Yellow
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
