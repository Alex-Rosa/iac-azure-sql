#Requires -Version 7.0
<#
.SYNOPSIS
    UC-01 - Region failure of the PRIMARY node: fail every transaction over to the alternate region.

.DESCRIPTION
    Drill + runbook automation for the topology built by ../../deploy.ps1:
      - AG1 (global primary of the distributed AG): primary node in region A, ASYNC secondary in region B
      - AG2 (forwarder of the distributed AG, optional): two nodes, typically also in region A
      - distributed AG AG1 -> AG2 (deploy.ps1 -Action deploy-dag)
    All AGs use CLUSTER_TYPE = NONE (manual failover, no listener).

    A failure of region A takes down AG1's primary AND every forwarder node in region A. The
    resolution promotes AG1's replica in region B, which also makes it the distributed AG's global
    primary. The forwarder AG is re-attached to it when region A recovers.

    Actions (asked for when not passed):
      status            Power state + AG / distributed AG health of every node.
      precheck          Starts deallocated VMs (after confirmation), checks every AG and the distributed
                        AG are healthy, opens a drill run (runs/<rg>/<run-id>/), creates the ledger table.
      start-workload    Background writer on AG1's primary: 1 ledger row every ~0.2 s.
      simulate-failure  Hard power-off of EVERY node in the primary's region (no guest shutdown).
      failover          DR node only: FORCE_FAILOVER_ALLOW_DATA_LOSS, remove the lost replica, repoint the
                        distributed AG to the new primary, prove writes, repoint DNS (optional).
      verify            New primary status + write test + distributed AG view.
      drill             precheck -> start-workload -> warm-up -> simulate-failure -> failover -> verify.
      reinstate         Region is back: fence the stale primary (1433 + 5022), start the region's VMs,
                        measure the exact data loss, preserve it, drop the stale AG/distributed AG copy,
                        rejoin it as an ASYNC secondary, re-attach the forwarder AG, lift the fence.
      failback          Planned, no-data-loss role swap back to the original primary (distributed AG
                        repointed on both sides).

    All SQL runs through 'az vm run-command' (Azure control plane), so it doesn't need SSH or port
    1433 to be reachable from this machine. Every step writes evidence to runs/<rg>/<run-id>/.

.EXAMPLE
    ./uc-01.ps1                                   # interactive
.EXAMPLE
    ./uc-01.ps1 -Action drill -Identifier 257672 -PrimaryNodeSuffix node-1 -SecondaryNodeSuffix node-2 -ForwarderPrimarySuffix node-3 -ForwarderSecondarySuffix node-4
.EXAMPLE
    ./uc-01.ps1 -Action reinstate -Identifier 257672 -PrimaryNodeSuffix node-1 -SecondaryNodeSuffix node-2 -ForwarderPrimarySuffix node-3 -ForwarderSecondarySuffix node-4
#>
param(
    [ValidateSet('', 'status', 'precheck', 'start-workload', 'simulate-failure', 'failover', 'verify', 'drill', 'reinstate', 'failback')]
    [string]$Action = '',

    # Same values used with ../../deploy.ps1.
    [Alias('Environment')]
    [string]$Identifier          = '',
    [string]$PrimaryNodeSuffix   = '',   # AG1 node in the region that FAILS
    [string]$SecondaryNodeSuffix = '',   # AG1 DR node in the alternate region
    [string]$ForwarderPrimarySuffix   = '',   # AG2 (forwarder) nodes; 'none' = no distributed AG
    [string]$ForwarderSecondarySuffix = '',
    [string]$Prefix              = 'sqlvm',
    [string]$AgName              = '',   # default agsqlvm-<PrimaryNodeSuffix>
    [string]$DagName             = '',   # default dagsqlvm-<PrimaryNodeSuffix>-<ForwarderPrimarySuffix>
    [string]$DemoDbName          = 'AGDemoDB',

    [int]$WorkloadSeconds = 900,   # writer lifetime (it dies with the VM anyway)
    [int]$WarmupSeconds   = 60,    # drill: writes before the failure is injected
    [int]$DetectSeconds   = 30,    # drill: pause between failure and failover (detection/decision time)
    [int]$WriteTestRows   = 10,
    [int]$ForwarderResyncMinutes = 15,   # reinstate: wait this long for the forwarder to resynchronize

    # Optional DNS redirection of the application endpoint (Azure Private DNS A record).
    [string]$PrivateDnsZone          = '',
    [string]$PrivateDnsRecord        = '',
    [string]$PrivateDnsResourceGroup = '',

    [switch]$SkipOrphanBackup,
    [switch]$ReseedForwarder,   # reinstate: if the forwarder can't resynchronize, drop + recreate the distributed AG
    [switch]$Force,
    [switch]$AutoApprove
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Continue'

$UcDir      = $PSScriptRoot
$ProjectDir = (Resolve-Path (Join-Path $UcDir '..' '..')).Path
$SqlDir     = Join-Path $UcDir 'sql'
$StateDir   = Join-Path $ProjectDir 'state'
$FenceRules = @(
    @{ Name = 'uc01-fence-deny-sql';      Direction = 'Inbound';  Port = '1433'; Priority = 100 },
    @{ Name = 'uc01-fence-deny-hadr-in';  Direction = 'Inbound';  Port = '5022'; Priority = 101 },
    @{ Name = 'uc01-fence-deny-hadr-out'; Direction = 'Outbound'; Port = '5022'; Priority = 100 })

# ── Console input ──────────────────────────────────────────────────────────────
function Read-Line {
    param([string]$Prompt)
    $value = Read-Host $Prompt
    if ($null -eq $value) { Write-Error "No input available for: $Prompt"; exit 1 }
    return $value.Trim()
}

function Read-Choice {
    param([string]$Prompt, [string[]]$Options, [string[]]$Descriptions, [string]$Default)
    Write-Host ''
    Write-Host $Prompt -ForegroundColor Cyan
    for ($i = 0; $i -lt $Options.Count; $i++) {
        $marker = if ($Options[$i] -eq $Default) { ' (default)' } else { '' }
        Write-Host ("  {0}) {1}{2} - {3}" -f ($i + 1), $Options[$i], $marker, $Descriptions[$i])
    }
    while ($true) {
        $answer = (Read-Line 'Select a number or type the value').ToLower()
        if (-not $answer -and $Default) { return $Default }
        if ($answer -match '^\d+$' -and [int]$answer -ge 1 -and [int]$answer -le $Options.Count) { return $Options[[int]$answer - 1] }
        if ($Options -contains $answer) { return $answer }
        Write-Host "  '$answer' is not one of: $($Options -join ', ')" -ForegroundColor Yellow
    }
}

function Read-Name {
    param([string]$Prompt, [string]$Default, [int]$MaxLength)
    $pattern = "^[a-z0-9]([a-z0-9-]{0,$($MaxLength - 2)}[a-z0-9])?$"
    while ($true) {
        $label = if ($Default) { "$Prompt [$Default]" } else { $Prompt }
        $answer = (Read-Line $label).ToLower()
        if (-not $answer) { $answer = $Default }
        if ($answer -cmatch $pattern) { return $answer }
        Write-Host "  Invalid value '$answer' (1-$MaxLength lowercase letters, digits or hyphens)." -ForegroundColor Yellow
    }
}

function Confirm-Yes {
    param([string]$Prompt)
    if ($AutoApprove) { return }
    if ((Read-Host $Prompt) -ne 'yes') { Write-Host 'Cancelled.'; exit 0 }
}

function Write-Step { param([string]$Text) Write-Host ''; Write-Host "=== $Text ===" -ForegroundColor Cyan }
function Get-UtcNow { [DateTime]::UtcNow }
function Format-Utc { param([datetime]$T) $T.ToString('yyyy-MM-ddTHH:mm:ss.fffZ') }
# Evidence timestamps come back from ConvertFrom-Json either as strings or as DateTime objects
# already converted to local time - normalize both to UTC.
function ConvertTo-Utc {
    param($Value)
    if ($Value -is [datetime]) { return $Value.ToUniversalTime() }
    return [datetime]::Parse("$Value", [cultureinfo]::InvariantCulture,
        [System.Globalization.DateTimeStyles]::AssumeUniversal -bor [System.Globalization.DateTimeStyles]::AdjustToUniversal)
}

# ── Evidence ───────────────────────────────────────────────────────────────────
function Get-RunDir {
    if (-not $script:RunId) { return $null }
    $dir = Join-Path $RunsRoot $script:RunId
    New-Item -ItemType Directory -Force -Path $dir | Out-Null
    return $dir
}

function Save-Evidence {
    param([string]$Name, [object]$Data)
    $dir = Get-RunDir
    if (-not $dir) { return }
    $Data | ConvertTo-Json -Depth 6 | Set-Content -Path (Join-Path $dir "$Name.json")
}

function Read-Evidence {
    param([string]$Name)
    $dir = Get-RunDir
    if (-not $dir) { return $null }
    $file = Join-Path $dir "$Name.json"
    if (Test-Path $file) { return (Get-Content $file -Raw | ConvertFrom-Json) }
    return $null
}

function Add-Event {
    param([string]$Name, [string]$Detail = '')
    $line = [ordered]@{ utc = (Format-Utc (Get-UtcNow)); event = $Name; detail = $Detail } | ConvertTo-Json -Compress
    $dir = Get-RunDir
    if ($dir) { Add-Content -Path (Join-Path $dir 'events.jsonl') -Value $line }
}

function Get-RunIdOrNone { if ($script:RunId) { $script:RunId } else { 'none' } }

# ── Topology ───────────────────────────────────────────────────────────────────
function New-UcNode {
    param([string]$Role, [string]$Suffix, [string]$StackPrimary, [string]$StackSecondary, [string]$Ag)
    $rg = "$NamePrefix-$StackPrimary-$StackSecondary-rg"
    $credsFile = Join-Path $StateDir "$rg.credentials.json"
    if (-not (Test-Path $credsFile)) { Write-Error "No saved credentials for $rg ($credsFile)."; exit 1 }
    $vm = "$NamePrefix-$Suffix-vm"
    $info = az vm show -g $rg -n $vm --query '{l:location}' -o json 2>$null | ConvertFrom-Json
    if (-not $info) { Write-Error "VM $vm not found in $rg."; exit 1 }
    $ip = az network nic show -g $rg -n "$NamePrefix-$Suffix-nic" --query 'ipConfigurations[0].privateIPAddress' -o tsv 2>$null
    return [pscustomobject]@{
        Role = $Role; Suffix = $Suffix; Name = "$NamePrefix-$Suffix"; Vm = $vm; Rg = $rg; Nsg = "$NamePrefix-$Suffix-nsg"
        Region = $info.l; PrivateIp = $ip; Ag = $Ag; Sa = (Get-Content $credsFile -Raw | ConvertFrom-Json).SaPassword
    }
}

function Get-PowerState {
    param($Node)
    $state = az vm get-instance-view -g $Node.Rg -n $Node.Vm `
        --query "instanceView.statuses[?starts_with(code, 'PowerState/')].code | [0]" -o tsv 2>$null
    if (-not $state) { return 'unknown' }
    return ($state -replace '^PowerState/', '')
}

function Start-UcVms {
    param([object[]]$Nodes)
    foreach ($n in $Nodes) { Write-Host "  Starting $($n.Vm) ..."; az vm start -g $n.Rg -n $n.Vm --no-wait -o none }
    foreach ($n in $Nodes) {
        az vm wait -g $n.Rg -n $n.Vm --custom "instanceView.statuses[?code=='PowerState/running']" --timeout 900 -o none 2>$null
        if ((Get-PowerState $n) -ne 'running') { Write-Error "$($n.Vm) did not start."; exit 1 }
        Write-Host "  $($n.Vm) running."
    }
}

# ── Run Command transport ──────────────────────────────────────────────────────
# Runs bash bodies on several VMs in parallel. Each request: @{ Node; Body; Label }. The body sees
# SQLCMDPASSWORD (that node's SA password) and a SQL() sqlcmd wrapper. Returns results in request
# order with KEY=VALUE stdout lines parsed into .Values (Azure caps output at ~4 KB per call).
function Invoke-VmBatch {
    param([object[]]$Requests)
    $template = @'
#!/bin/bash
export SQLCMDPASSWORD='__PASSWORD__'
SQL() { /opt/mssql-tools18/bin/sqlcmd -S localhost -U SA -No -C -b -W -h -1 "$@"; }
(
set -euo pipefail
__BODY__
)
echo "UC01_EXIT=$?"
'@
    $jobs = @(foreach ($r in $Requests) {
        [pscustomobject]@{
            Rg = $r.Node.Rg; Vm = $r.Node.Vm; Label = $r.Label
            Script = $template.Replace('__PASSWORD__', $r.Node.Sa).Replace('__BODY__', $r.Body).Replace("`r`n", "`n")
        }
    })
    foreach ($j in $jobs) { Write-Host "  [$($j.Vm)] $($j.Label) ..." -ForegroundColor DarkGray }
    $raw = @($jobs | ForEach-Object -ThrottleLimit 4 -Parallel {
        $j = $_
        $tmp = Join-Path ([System.IO.Path]::GetTempPath()) ('uc01-' + [guid]::NewGuid().ToString('N') + '.sh')
        [System.IO.File]::WriteAllText($tmp, $j.Script)
        $json = $null
        try {
            for ($attempt = 1; $attempt -le 3; $attempt++) {
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
        $exit = if ($values.ContainsKey('UC01_EXIT')) { [int]$values['UC01_EXIT'][-1] } else { -1 }
        [pscustomobject]@{ Vm = $j.Vm; Label = $j.Label; Exit = $exit; Stdout = $stdout; Stderr = $stderr; Values = $values }
    }
}

function Get-Val  { param($Result, [string]$Key) if ($Result -and $Result.Values.ContainsKey($Key)) { $Result.Values[$Key][0] } else { $null } }
function Get-Vals { param($Result, [string]$Key) if ($Result -and $Result.Values.ContainsKey($Key)) { @($Result.Values[$Key]) } else { @() } }

function Assert-Ok {
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

# Bash lines that materialize sql/<File> on the VM and run it with sqlcmd scripting variables.
function Get-SqlBody {
    param([string]$File, [hashtable]$Vars = @{})
    $content = (Get-Content (Join-Path $SqlDir $File) -Raw).Replace("`r`n", "`n")
    $varArgs = ($Vars.GetEnumerator() | Sort-Object Key | ForEach-Object { "$($_.Key)=`"$($_.Value)`"" }) -join ' '
    $vFlag   = if ($varArgs) { "-v $varArgs " } else { '' }
    return "cat > /tmp/uc01-$File <<'UC01SQL'`n$content`nUC01SQL`nSQL $vFlag-i /tmp/uc01-$File"
}

function New-SqlRequest {
    param($Node, [string]$File, [hashtable]$Vars = @{}, [string]$Label = $File, [string]$Prefix = '')
    return @{ Node = $Node; Label = $Label; Body = $Prefix + (Get-SqlBody -File $File -Vars $Vars) }
}

function Invoke-Sql {
    param($Node, [string]$File, [hashtable]$Vars = @{}, [string]$Label = $File, [string]$Prefix = '', [switch]$AllowFail)
    $r = @(Invoke-VmBatch @(New-SqlRequest -Node $Node -File $File -Vars $Vars -Label $Label -Prefix $Prefix))[0]
    if (-not $AllowFail) { Assert-Ok $r }
    return $r
}

# ── Status helpers ─────────────────────────────────────────────────────────────
function Get-StatusAll {
    param([object[]]$Nodes)
    $running = @($Nodes | Where-Object { $_.Power -eq 'running' })
    $result = @{}
    if ($running.Count -eq 0) { return $result }
    $requests = foreach ($n in $running) {
        $body = Get-SqlBody -File '00-status.sql' -Vars @{ AgName = $n.Ag }
        if ($HasDag) { $body += "`n" + (Get-SqlBody -File '14-dag-status.sql' -Vars @{ DagName = $DagName }) }
        @{ Node = $n; Label = 'AG status'; Body = $body }
    }
    $batch = @(Invoke-VmBatch @($requests))
    Assert-Ok $batch
    foreach ($r in $batch) { $result[$r.Vm] = $r }
    return $result
}

function Show-NodeStatus {
    param($Node, $Result)
    Write-Host ''
    Write-Host ("  {0} [{1}] {2} - {3}" -f $Node.Name, $Node.Role, $Node.Region, $Node.Power) -ForegroundColor White
    if (-not $Result) { return }
    foreach ($k in @('LOCAL_ROLE', 'REPLICA', 'DB', 'DAG_MEMBER', 'DAG_DB')) {
        foreach ($v in (Get-Vals $Result $k)) { Write-Host ("    {0,-10} {1}" -f $k, $v) }
    }
}

function Update-PowerStates { foreach ($n in $AllNodes) { $n | Add-Member -NotePropertyName Power -NotePropertyValue (Get-PowerState $n) -Force } }

function Set-DnsToIp {
    param([string]$Ip, [string]$Why)
    if (-not $PrivateDnsZone) {
        Write-Host "  (No -PrivateDnsZone given: repoint applications to $Ip yourself - see README 'Redirecting transactions'.)" -ForegroundColor Yellow
        return
    }
    $dnsRg = if ($PrivateDnsResourceGroup) { $PrivateDnsResourceGroup } else { $Orig.Rg }
    $current = @(az network private-dns record-set a show -g $dnsRg -z $PrivateDnsZone -n $PrivateDnsRecord --query 'aRecords[].ipv4Address' -o tsv 2>$null)
    foreach ($old in $current) {
        if ($old -and $old -ne $Ip) { az network private-dns record-set a remove-record -g $dnsRg -z $PrivateDnsZone -n $PrivateDnsRecord -a $old --keep-empty-record-set -o none }
    }
    if ($current -notcontains $Ip) {
        az network private-dns record-set a add-record -g $dnsRg -z $PrivateDnsZone -n $PrivateDnsRecord -a $Ip -o none
        if ($LASTEXITCODE -ne 0) { Write-Error "Failed to update $PrivateDnsRecord.$PrivateDnsZone"; exit 1 }
    }
    Write-Host "  DNS $PrivateDnsRecord.$PrivateDnsZone -> $Ip ($Why)" -ForegroundColor Green
    Add-Event 'dns-updated' "$PrivateDnsRecord.$PrivateDnsZone -> $Ip"
}

# Waits until the forwarder AG's databases are SYNCHRONIZING/SYNCHRONIZED in the distributed AG, as
# seen from the global primary ($From). Returns $true / $false (timeout).
function Wait-ForwarderSync {
    param($From, [int]$TimeoutMinutes)
    $deadline = (Get-UtcNow).AddMinutes($TimeoutMinutes)
    while ($true) {
        $s = Invoke-Sql -Node $From -File '14-dag-status.sql' -Vars @{ DagName = $DagName } -Label 'distributed AG state'
        $rows = @(Get-Vals $s 'DAG_DB' | Where-Object { $_ -like "$FwAg|*" })
        $ok = @($rows | Where-Object { $_.Split('|')[2] -in @('SYNCHRONIZING', 'SYNCHRONIZED') -and $_ -notmatch 'suspended=1' })
        Write-Host "  forwarder $FwAg : $($ok.Count)/$($rows.Count) database(s) synchronizing"
        foreach ($r in (Get-Vals $s 'DAG_MEMBER')) { Write-Host "    DAG_MEMBER $r" }
        foreach ($r in $rows) { Write-Host "    DAG_DB     $r" }
        if ($rows.Count -gt 0 -and $ok.Count -eq $rows.Count) { return $true }
        if ((Get-UtcNow) -gt $deadline) { return $false }
        Start-Sleep 30
    }
}

function Wait-ReplicaState {
    param($On, [string]$Replica, [string[]]$Accept, [int]$TimeoutMinutes, [string]$What)
    $deadline = (Get-UtcNow).AddMinutes($TimeoutMinutes)
    while ($true) {
        $s = Invoke-Sql -Node $On -File '24-replica-sync-state.sql' -Vars @{ AgName = $AgName; ReplicaName = $Replica } -Label "$What state"
        $expected = [int](Get-Val $s 'EXPECTED_DBS')
        $rows = @(Get-Vals $s 'SYNC')
        $ready = @($rows | Where-Object { $Accept -contains $_.Split('|')[1] })
        Write-Host "  $What : $($ready.Count)/$expected database(s) in $($Accept -join '/')"
        foreach ($r in $rows) { Write-Host "    $r" }
        foreach ($r in (Get-Vals $s 'SEEDING')) { Write-Host "    seeding $r" }
        if ($expected -gt 0 -and $ready.Count -ge $expected) { return }
        if ((Get-UtcNow) -gt $deadline) { Write-Error "$What didn't complete within $TimeoutMinutes min."; exit 1 }
        Start-Sleep 45
    }
}

# ── Actions ────────────────────────────────────────────────────────────────────
function Invoke-Status {
    Write-Step 'Status'
    Update-PowerStates
    $st = Get-StatusAll $AllNodes
    foreach ($n in $AllNodes) { Show-NodeStatus $n $st[$n.Vm] }
    $fences = @(az network nsg rule list -g $Orig.Rg --nsg-name $Orig.Nsg --query "[?starts_with(name, 'uc01-fence')].name" -o tsv 2>$null)
    if ($fences.Count -gt 0) { Write-Host ''; Write-Host "  Fence rules on $($Orig.Nsg): $($fences -join ', ')" -ForegroundColor Yellow }
}

function Invoke-Precheck {
    Write-Step 'Pre-check: every node running, AGs and distributed AG healthy'
    Update-PowerStates
    $down = @($AllNodes | Where-Object { $_.Power -ne 'running' })
    if ($down.Count -gt 0) {
        $down | ForEach-Object { Write-Host "  $($_.Vm) is '$($_.Power)'" -ForegroundColor Yellow }
        Confirm-Yes "  Type 'yes' to start them"
        Start-UcVms $down
        Update-PowerStates
    }
    $st = Get-StatusAll $AllNodes
    foreach ($n in $AllNodes) { Show-NodeStatus $n $st[$n.Vm] }

    $problems = @()
    $o = $st[$Orig.Vm]; $d = $st[$Dr.Vm]
    if ((Get-Val $o 'LOCAL_ROLE') -ne 'PRIMARY')  { $problems += "$($Orig.Name) is '$(Get-Val $o 'LOCAL_ROLE')' in $AgName, expected PRIMARY (already failed over? run reinstate/failback first)" }
    if ((Get-Val $d 'LOCAL_ROLE') -ne 'SECONDARY') { $problems += "$($Dr.Name) is '$(Get-Val $d 'LOCAL_ROLE')' in $AgName, expected SECONDARY" }
    $drSeen = @(Get-Vals $o 'REPLICA' | Where-Object { $_ -like "$($Dr.Name)|*" })
    if (-not $drSeen -or $drSeen[0] -notmatch '\|CONNECTED\|') { $problems += "$($Dr.Name) is not CONNECTED to the primary" }
    $agDbs = @(Get-Vals $o 'DB' | Where-Object { $_ -notmatch '\|NOT_IN_AG\|' })
    if ($agDbs.Count -eq 0) { $problems += "no database is in $AgName" }
    foreach ($db in $agDbs) { if ($db -notmatch '\|ONLINE\|' -or $db -match 'suspended=1') { $problems += "AG database not healthy: $db" } }
    if ($HasDag) {
        if ((Get-Val $o 'DAG_EXISTS') -ne '1') { $problems += "distributed AG $DagName not found on $($Orig.Name)" }
        $fwMember = @(Get-Vals $o 'DAG_MEMBER' | Where-Object { $_ -like "$FwAg|*" })
        if (-not $fwMember -or $fwMember[0] -notmatch '\|CONNECTED\|') { $problems += "forwarder $FwAg is not CONNECTED to the global primary" }
        $fwDbs = @(Get-Vals $o 'DAG_DB' | Where-Object { $_ -like "$FwAg|*" })
        if ($fwDbs.Count -eq 0) { $problems += "forwarder $FwAg reports no databases" }
        foreach ($r in $fwDbs) { if ($r.Split('|')[2] -notin @('SYNCHRONIZING', 'SYNCHRONIZED') -or $r -match 'suspended=1') { $problems += "forwarder database not healthy: $r" } }
    }
    if ($problems.Count -gt 0) {
        Write-Host ''
        $problems | ForEach-Object { Write-Host "  PROBLEM: $_" -ForegroundColor Red }
        Write-Error 'Pre-check failed - fix the AGs before running the drill.'
        exit 1
    }

    $script:RunId = (Get-UtcNow).ToString('yyyyMMdd-HHmmss')
    Set-Content -Path $CurrentRunFile -Value $script:RunId
    Add-Event 'precheck-passed'
    Invoke-Sql -Node $Orig -File '01-prepare-workload.sql' -Vars @{ DbName = $DemoDbName } -Label 'create ledger table' | Out-Null
    Save-Evidence 'precheck' ([ordered]@{
        runId = $script:RunId; utc = (Format-Utc (Get-UtcNow)); ag = $AgName; distributedAg = $(if ($HasDag) { $DagName } else { $null })
        failedRegion = $Orig.Region; drRegion = $Dr.Region
        nodes = @($AllNodes | ForEach-Object { [ordered]@{ name = $_.Name; role = $_.Role; region = $_.Region; ip = $_.PrivateIp } })
        status = @($AllNodes | ForEach-Object { [ordered]@{ node = $_.Name; output = $st[$_.Vm].Stdout } })
    })
    Write-Host ''
    Write-Host "  Pre-check passed. Drill run id: $($script:RunId)  (evidence: $(Get-RunDir))" -ForegroundColor Green
}

function Invoke-StartWorkload {
    Assert-Run
    Write-Step "Starting the transaction writer on $($Orig.Name)"
    $body = @'
cat > /var/tmp/uc01-writer.sh <<'WRITER'
#!/bin/bash
# UC-01 ledger writer: one committed row every ~0.2 s until DURATION elapses (or the VM dies).
RUN_ID="$1"; DB="$2"; DURATION="$3"
seq=0; end=$((SECONDS + DURATION))
while [ "$SECONDS" -lt "$end" ]; do
  n=$((seq + 1))
  if /opt/mssql-tools18/bin/sqlcmd -S localhost -U SA -No -C -b -d "$DB" \
       -Q "SET NOCOUNT ON; INSERT dbo.UC01_Tx (run_id, seq, phase) VALUES ('$RUN_ID', $n, 'pre-failure');" >/dev/null 2>&1; then
    seq=$n
  fi
  sleep 0.2
done
WRITER
chmod 700 /var/tmp/uc01-writer.sh
pkill -f /var/tmp/uc01-writer.sh || true
nohup setsid /var/tmp/uc01-writer.sh '__RUN_ID__' '__DB__' '__SECONDS__' >/var/tmp/uc01-writer.log 2>&1 < /dev/null &
sleep 8
echo "WRITER_PID=$(pgrep -f /var/tmp/uc01-writer.sh | head -1)"
SQL -d '__DB__' -Q "SET NOCOUNT ON; SELECT 'LEDGER_ROWS=' + CAST(COUNT(*) AS varchar(20)) FROM dbo.UC01_Tx WHERE run_id = '__RUN_ID__'"
'@
    $body = $body.Replace('__RUN_ID__', $script:RunId).Replace('__DB__', $DemoDbName).Replace('__SECONDS__', "$WorkloadSeconds")
    $r = @(Invoke-VmBatch @(@{ Node = $Orig; Label = 'start writer'; Body = $body }))[0]
    Assert-Ok $r
    $rows = Get-Val $r 'LEDGER_ROWS'
    if (-not (Get-Val $r 'WRITER_PID') -or [int]$rows -le 0) { Write-Error "Writer didn't start (rows=$rows)."; exit 1 }
    Add-Event 'workload-started' "rows after 8 s: $rows"
    Write-Host "  Writer running (pid $(Get-Val $r 'WRITER_PID')), $rows rows committed so far, lifetime $WorkloadSeconds s." -ForegroundColor Green
}

function Invoke-SimulateFailure {
    Assert-Run
    Write-Step "Simulating a failure of region $($Orig.Region): hard power-off of every node there"
    $victims = @($RegionNodes)
    $victims | ForEach-Object { Write-Host "  $($_.Vm) [$($_.Role)]" }
    Write-Host '  No guest shutdown: SQL Server stops mid-transaction, exactly like losing the region.' -ForegroundColor Yellow
    Confirm-Yes "  Type 'yes' to power them off now"
    $t0 = Get-UtcNow
    Add-Event 'failure-injected' ("az vm stop --skip-shutdown " + (($victims | ForEach-Object { $_.Vm }) -join ', '))
    foreach ($n in $victims) { az vm stop -g $n.Rg -n $n.Vm --skip-shutdown --no-wait -o none }
    $offAt = [ordered]@{}
    foreach ($n in $victims) {
        az vm wait -g $n.Rg -n $n.Vm --custom "instanceView.statuses[?code=='PowerState/stopped']" --timeout 600 -o none 2>$null
        if ((Get-PowerState $n) -ne 'stopped') { Write-Error "$($n.Vm) did not power off."; exit 1 }
        $offAt[$n.Name] = Format-Utc (Get-UtcNow)
        Write-Host "  $($n.Vm) powered off."
    }
    Save-Evidence 'failure' ([ordered]@{
        method = 'az vm stop --skip-shutdown (hard power-off, VMs stay allocated)'; region = $Orig.Region
        vms = @($victims | ForEach-Object { $_.Vm }); requestedUtc = (Format-Utc $t0)
        # All power-offs are requested at once; the primary's confirmation time is the RTO reference.
        poweredOffUtc = $offAt[$Orig.Name]; poweredOff = $offAt
    })
}

function Invoke-Failover {
    Write-Step "Failover to $($Dr.Name) ($($Dr.Region))"
    if ((Get-PowerState $Dr) -ne 'running') { Write-Error "DR node $($Dr.Vm) is not running - it must be to take over."; exit 1 }

    # 1. Detection: the DR replica must have lost the primary (retries ~60 s - AG session timeout is ~10 s).
    $snap = $null; $role = $null; $primaryState = $null
    for ($i = 1; $i -le 3; $i++) {
        $snap = Invoke-Sql -Node $Dr -File '10-dr-snapshot.sql' -Label 'DR snapshot' -Vars @{ AgName = $AgName; DbName = $DemoDbName; RunId = (Get-RunIdOrNone) }
        $role = Get-Val $snap 'LOCAL_ROLE'
        $primaryState = "$(Get-Val $snap 'PRIMARY_STATE')".Split('|')[-1]
        if ($role -eq 'PRIMARY' -or $primaryState -eq 'DISCONNECTED') { break }
        if ($i -lt 3) { Write-Host "  DR replica reports '$primaryState' to the primary - re-checking in 20 s ..." -ForegroundColor Yellow; Start-Sleep 20 }
    }
    Write-Host "  DR role: $role | primary as seen from DR: $(Get-Val $snap 'PRIMARY_STATE')"
    foreach ($l in (Get-Vals $snap 'DB_LAST_COMMIT')) { Write-Host "  last replicated commit: $l" }
    $drLastSeq = Get-Val $snap 'DR_LAST_SEQ'
    if ($drLastSeq) { Write-Host "  last ledger row on DR: $drLastSeq" }

    $times = $null
    if ($role -eq 'PRIMARY') {
        Write-Host "  $($Dr.Name) is already PRIMARY - skipping to the distributed AG + verification steps." -ForegroundColor Yellow
    } else {
        # Only an explicit DISCONNECTED (the DR replica's own connection to the primary) counts as a
        # lost primary - CONNECTED or UNKNOWN never trigger a forced failover without -Force.
        if ($primaryState -ne 'DISCONNECTED' -and -not $Force) {
            Write-Error @"
The DR replica reports '$primaryState' for its connection to the primary - not a lost primary.
Forcing a failover now would leave two primaries (split-brain). Use a planned failover instead,
or pass -Force if the primary is truly unusable although still connected.
"@
            exit 1
        }
        Write-Host ''
        Write-Host "  FORCE_FAILOVER_ALLOW_DATA_LOSS: transactions not yet replicated to $($Dr.Name) are lost" -ForegroundColor Yellow
        Write-Host "  (asynchronous commit). $($Orig.Name) is then removed from $AgName so it can't come back" -ForegroundColor Yellow
        Write-Host '  as a second primary; use -Action reinstate once its region recovers.' -ForegroundColor Yellow
        Confirm-Yes "  Type 'yes' to fail over to $($Dr.Name)"

        # 2. Promote + remove the lost replica.
        $t0 = Get-UtcNow
        Add-Event 'failover-started'
        $fo = Invoke-Sql -Node $Dr -File '11-force-failover.sql' -Vars @{ AgName = $AgName; OldPrimary = $Orig.Name } -Label 'force failover'
        $t1 = Get-UtcNow
        Add-Event 'failover-completed' (Get-Val $fo 'LOCAL_ROLE')
        foreach ($k in @('FORCED_FAILOVER', 'REMOVED_REPLICA', 'RESUMED', 'LOCAL_ROLE')) { foreach ($v in (Get-Vals $fo $k)) { Write-Host "  $k = $v" } }
        if ((Get-Val $fo 'LOCAL_ROLE') -ne 'PRIMARY') { Write-Error "$($Dr.Name) did not become PRIMARY."; exit 1 }
        $times = @{ started = $t0; completed = $t1 }
    }

    # 3. The new primary of AG1 is the distributed AG's global primary: point AG1's LISTENER_URL at it.
    #    The forwarder (down with the region) is repointed by 'reinstate'.
    $dagRepoint = $null
    if ($HasDag) {
        $rp = Invoke-Sql -Node $Dr -File '13-dag-repoint.sql' -Label 'repoint distributed AG' `
            -Vars @{ DagName = $DagName; MemberAg = $AgName; ListenerUrl = "tcp://$($Dr.PrivateIp):5022" }
        $dagRepoint = Get-Val $rp 'DAG_REPOINTED'
        Write-Host "  DAG_REPOINTED = $dagRepoint"
        Add-Event 'dag-repointed' $dagRepoint
    }

    # 4. Prove the alternate region accepts transactions (retries while databases finish recovery).
    $write = $null
    for ($i = 1; $i -le 6; $i++) {
        $write = Invoke-Sql -Node $Dr -File '12-write-test.sql' -Label 'write test' -AllowFail `
            -Vars @{ DbName = $DemoDbName; RunId = (Get-RunIdOrNone); Rows = $WriteTestRows }
        if ($write.Exit -eq 0 -and (Get-Val $write 'WRITE_OK')) { break }
        Write-Host '  Databases not writable yet - retrying in 10 s ...' -ForegroundColor Yellow
        Start-Sleep 10
    }
    Assert-Ok $write
    $tWrite = Get-UtcNow
    Add-Event 'first-write-on-dr' (Get-Val $write 'WRITE_OK')
    Write-Host "  WRITE_OK = $(Get-Val $write 'WRITE_OK')" -ForegroundColor Green
    foreach ($l in (Get-Vals $write 'LEDGER')) { Write-Host "  LEDGER   = $l" }

    # 5. Redirect clients.
    Set-DnsToIp -Ip $Dr.PrivateIp -Why 'failover'

    # 6. Evidence + RTO. A rerun (already PRIMARY) keeps the original failover evidence intact.
    $failure = Read-Evidence 'failure'
    $rto = $null
    if ($failure -and $failure.poweredOffUtc) { $rto = [math]::Round(($tWrite - (ConvertTo-Utc $failure.poweredOffUtc)).TotalSeconds, 1) }
    $evidenceName = if (-not $times -and (Read-Evidence 'failover')) { 'failover-rerun' } else { 'failover' }
    Save-Evidence $evidenceName ([ordered]@{
        newPrimary = $Dr.Name; newPrimaryPrivateIp = $Dr.PrivateIp
        drSnapshot = $snap.Stdout; drLastSeqBeforeFailover = $drLastSeq
        failoverStartedUtc   = $(if ($times) { Format-Utc $times.started } else { $null })
        failoverCompletedUtc = $(if ($times) { Format-Utc $times.completed } else { $null })
        distributedAgRepointed = $dagRepoint
        firstWriteUtc = (Format-Utc $tWrite); writeTest = $write.Stdout
        rtoSecondsFromPowerOff = $rto
    })
    Write-Host ''
    Write-Host "  Transactions now go to $($Dr.Name) ($($Dr.Region)), private IP $($Dr.PrivateIp)." -ForegroundColor Green
    if ($null -ne $rto) { Write-Host "  RTO (primary powered off -> first committed write on DR): $rto s" -ForegroundColor Green }
}

function Invoke-Verify {
    Write-Step "Verification on $($Dr.Name)"
    $body = (Get-SqlBody -File '00-status.sql' -Vars @{ AgName = $AgName })
    if ($HasDag) { $body += "`n" + (Get-SqlBody -File '14-dag-status.sql' -Vars @{ DagName = $DagName }) }
    $st = @(Invoke-VmBatch @(@{ Node = $Dr; Label = 'AG status'; Body = $body }))[0]
    Assert-Ok $st
    $Dr | Add-Member -NotePropertyName Power -NotePropertyValue 'running' -Force
    Show-NodeStatus $Dr $st
    $write = Invoke-Sql -Node $Dr -File '12-write-test.sql' -Label 'write test' -Vars @{ DbName = $DemoDbName; RunId = (Get-RunIdOrNone); Rows = $WriteTestRows }
    Write-Host "  WRITE_OK = $(Get-Val $write 'WRITE_OK')" -ForegroundColor Green
    foreach ($l in (Get-Vals $write 'LEDGER')) { Write-Host "  LEDGER   = $l" }

    $agDbs = @(Get-Vals $st 'DB' | Where-Object { $_ -notmatch '\|NOT_IN_AG\|' })
    $pass = (Get-Val $st 'LOCAL_ROLE') -eq 'PRIMARY' -and $agDbs.Count -gt 0 -and -not @($agDbs | Where-Object { $_ -notmatch '\|ONLINE\|' }).Count
    $dagOk = $true
    if ($HasDag) {
        $gpMember = @(Get-Vals $st 'DAG_MEMBER' | Where-Object { $_ -like "$AgName|*" })
        $dagOk = $gpMember.Count -gt 0 -and $gpMember[0] -like "*tcp://$($Dr.PrivateIp):5022|PRIMARY|*"
        if (-not $dagOk) { Write-Host "  Distributed AG: $AgName is not PRIMARY at tcp://$($Dr.PrivateIp):5022 yet." -ForegroundColor Red }
        else { Write-Host "  Distributed AG: $($Dr.Name) is the global primary (forwarder $FwAg re-attaches on 'reinstate')." -ForegroundColor Green }
    }
    Save-Evidence 'verify' ([ordered]@{ utc = (Format-Utc (Get-UtcNow)); pass = ($pass -and $dagOk); status = $st.Stdout; writeTest = $write.Stdout })
    Write-Host ''
    if ($pass -and $dagOk) { Write-Host "  PASS - $($Dr.Name) is PRIMARY in $($Dr.Region), all AG databases ONLINE and writable." -ForegroundColor Green }
    else { Write-Host '  FAIL - see the status above.' -ForegroundColor Red }
    $fo = Read-Evidence 'failover'
    if ($fo -and $fo.drLastSeqBeforeFailover) {
        Write-Host "  Last pre-failure ledger row that reached DR: $($fo.drLastSeqBeforeFailover)."
        Write-Host '  The exact number of lost transactions is measured by -Action reinstate (it reads the old primary).'
    }
}

function Set-Fence {
    param([switch]$Remove, [string[]]$Only)
    foreach ($f in $FenceRules) {
        if ($Only -and $Only -notcontains $f.Name) { continue }
        if ($Remove) {
            az network nsg rule delete -g $Orig.Rg --nsg-name $Orig.Nsg -n $f.Name -o none 2>$null
            Add-Event 'fence-removed' $f.Name
            continue
        }
        az network nsg rule create -g $Orig.Rg --nsg-name $Orig.Nsg -n $f.Name --priority $f.Priority `
            --direction $f.Direction --access Deny --protocol Tcp --destination-port-ranges $f.Port `
            --source-address-prefixes '*' --destination-address-prefixes '*' `
            --description 'UC-01 fence: stale primary after forced failover' -o none
        if ($LASTEXITCODE -ne 0) { Write-Error "Could not create fence rule $($f.Name) - not starting the old primary."; exit 1 }
        Add-Event 'fence-applied' $f.Name
    }
}

function Invoke-Reinstate {
    Write-Step "Reinstate region $($Orig.Region): $($Orig.Name) back as a secondary$(if ($HasDag) { ", forwarder $FwAg re-attached" })"
    # (PowerShell names are case-insensitive: never name a local $dr - it would replace the $Dr node.)
    $drStatus = Invoke-Sql -Node $Dr -File '00-status.sql' -Vars @{ AgName = $AgName } -Label 'AG status'
    if ((Get-Val $drStatus 'LOCAL_ROLE') -ne 'PRIMARY') { Write-Error "$($Dr.Name) is not PRIMARY - nothing to reinstate."; exit 1 }
    if (@(Get-Vals $drStatus 'REPLICA' | Where-Object { $_ -like "$($Orig.Name)|*" }).Count -gt 0) {
        Write-Error "$($Orig.Name) is still a replica of $AgName on $($Dr.Name) - reinstate expects it removed (failover does that)."
        exit 1
    }

    # 1. Fence before power-on: the stale primary boots believing it is PRIMARY of AG1 AND the global
    #    primary of the distributed AG. Block clients (1433) and every AG endpoint connection (5022
    #    in/out) so neither applications nor the forwarder can talk to it.
    Write-Host "  Fencing $($Orig.Nsg): deny inbound 1433, inbound 5022, outbound 5022."
    Set-Fence

    # 2. Bring the region back.
    Update-PowerStates
    $toStart = @($RegionNodes | Where-Object { $_.Power -ne 'running' })
    if ($toStart.Count -gt 0) { Start-UcVms $toStart }
    Add-Event 'region-started' (($RegionNodes | ForEach-Object { $_.Vm }) -join ', ')

    # 3. Exact data loss: rows the old primary committed that never reached DR (and what the
    #    forwarder received from it before the outage).
    $inspect = @(New-SqlRequest -Node $Orig -File '20-old-primary-inspect.sql' -Label 'inspect old primary' -Vars @{ AgName = $AgName; DbName = $DemoDbName; RunId = (Get-RunIdOrNone) })
    if ($HasDag) { $inspect += New-SqlRequest -Node $FwPrimary -File '20-old-primary-inspect.sql' -Label 'inspect forwarder' -Vars @{ AgName = $FwAg; DbName = $DemoDbName; RunId = (Get-RunIdOrNone) } }
    $insp = @(Invoke-VmBatch $inspect)
    Assert-Ok $insp[0]
    Write-Host "  Old primary role on boot: $(Get-Val $insp[0] 'LOCAL_ROLE')"
    foreach ($l in (Get-Vals $insp[0] 'AG_DB')) { Write-Host "  AG_DB = $l" }
    $fwLastSeq = if ($HasDag -and $insp.Count -gt 1 -and $insp[1].Exit -eq 0) { Get-Val $insp[1] 'OLD_LAST_SEQ' } else { $null }
    $fo = Read-Evidence 'failover'
    $rpo = [ordered]@{ oldLastSeq = (Get-Val $insp[0] 'OLD_LAST_SEQ'); drLastSeq = $(if ($fo) { $fo.drLastSeqBeforeFailover } else { $null }); forwarderLastSeq = $fwLastSeq }
    if ($rpo.oldLastSeq -and $rpo.drLastSeq) {
        $o = $rpo.oldLastSeq.Split('|'); $d = $rpo.drLastSeq.Split('|')
        $rpo.lostTransactions = [int64]$o[0] - [int64]$d[0]
        if ($o[1] -ne '-' -and $d[1] -ne '-') { $rpo.lostWindowSeconds = [math]::Round(((ConvertTo-Utc $o[1]) - (ConvertTo-Utc $d[1])).TotalSeconds, 3) }
        Write-Host "  RPO: $($rpo.lostTransactions) committed transaction(s) lost, window $($rpo.lostWindowSeconds) s" -ForegroundColor Yellow
    }
    if ($fwLastSeq) { Write-Host "  Forwarder had received up to ledger row $fwLastSeq before the outage." }
    Save-Evidence 'rpo' $rpo

    # 4. Preserve + drop the stale copy (distributed AG definition first).
    $keep = if ($SkipOrphanBackup) { 'NOT preserved (-SkipOrphanBackup)' } else { 'preserved as COPY_ONLY backups in /var/opt/mssql/backup' }
    Write-Host "  Next: $(if ($HasDag) { "$DagName and " })$AgName and its databases on $($Orig.Name) are dropped (unsynchronized data $keep)," -ForegroundColor Yellow
    Write-Host "  then it is re-added as an ASYNC secondary and re-seeded from $($Dr.Name)." -ForegroundColor Yellow
    Confirm-Yes "  Type 'yes' to continue"
    $prep = "mkdir -p /var/opt/mssql/backup && chown mssql:mssql /var/opt/mssql/backup`n"
    $drop = Invoke-Sql -Node $Orig -File '21-old-primary-preserve-and-drop.sql' -Label 'preserve + drop stale AG' -Prefix $prep -Vars @{
        AgName = $AgName; DagName = $(if ($HasDag) { $DagName } else { 'none' }); BackupDir = '/var/opt/mssql/backup'
        RunId = (Get-RunIdOrNone); SkipBackup = $(if ($SkipOrphanBackup) { 1 } else { 0 }) }
    foreach ($k in @('PRESERVED', 'DAG_DROPPED', 'AG_OFFLINE', 'AG_DROPPED', 'DB_DROPPED')) { foreach ($v in (Get-Vals $drop $k)) { Write-Host "  $k = $v" } }

    # 5. Stale copy is gone: node-1's endpoint may talk to the AG again (keep 1433 fenced until rejoined).
    Set-Fence -Remove -Only @('uc01-fence-deny-hadr-in', 'uc01-fence-deny-hadr-out')

    # 6. Re-add + join + seed.
    $add = Invoke-Sql -Node $Dr -File '22-add-replica.sql' -Label 'add replica' -Vars @{ AgName = $AgName; ReplicaName = $Orig.Name; EndpointUrl = "tcp://$($Orig.PrivateIp):5022" }
    Write-Host "  REPLICA_ADDED = $(Get-Val $add 'REPLICA_ADDED')"
    $join = Invoke-Sql -Node $Orig -File '23-join-secondary.sql' -Vars @{ AgName = $AgName } -Label 'join AG'
    Write-Host "  JOINED = $(Get-Val $join 'JOINED')"
    Add-Event 'rejoined'
    Wait-ReplicaState -On $Dr -Replica $Orig.Name -Accept @('SYNCHRONIZING', 'SYNCHRONIZED') -TimeoutMinutes 60 -What 'seeding'

    # 7. Re-attach the forwarder AG to the new global primary.
    $forwarderResult = 'n/a'
    if ($HasDag) {
        Write-Step "Re-attaching forwarder $FwAg to the global primary $($Dr.Name)"
        $url = "tcp://$($Dr.PrivateIp):5022"
        $req = @(New-SqlRequest -Node $Dr -File '13-dag-repoint.sql' -Label 'repoint (global primary)' -Vars @{ DagName = $DagName; MemberAg = $AgName; ListenerUrl = $url })
        $req += New-SqlRequest -Node $FwPrimary -File '13-dag-repoint.sql' -Label 'repoint (forwarder)' -Vars @{ DagName = $DagName; MemberAg = $AgName; ListenerUrl = $url }
        $rp = @(Invoke-VmBatch $req); Assert-Ok $rp
        foreach ($r in $rp) { Write-Host "  DAG_REPOINTED = $(Get-Val $r 'DAG_REPOINTED')" }
        # Resume data movement on the forwarder side (suspended by the forced failover upstream).
        $res = @(Invoke-VmBatch @($ForwarderNodes | ForEach-Object { New-SqlRequest -Node $_ -File '33-demote-and-resume.sql' -Label 'resume' -Vars @{ AgName = $FwAg; Demote = 0 } }))
        Assert-Ok $res
        foreach ($r in $res) { foreach ($k in @('RESUMED', 'RESUME_SKIPPED')) { foreach ($v in (Get-Vals $r $k)) { Write-Host "  [$($r.Vm)] $k = $v" } } }

        if (Wait-ForwarderSync -From $Dr -TimeoutMinutes $ForwarderResyncMinutes) {
            $forwarderResult = 'resynchronized'
            Write-Host "  Forwarder $FwAg is synchronizing from $($Dr.Name)." -ForegroundColor Green
        } elseif ($ReseedForwarder) {
            # The forwarder kept log the new global primary never had (it received it from the stale
            # primary): rebuild the distributed AG, re-seeding the forwarder from the new global primary.
            Write-Host "  Forwarder can't resynchronize - re-seeding it (-ReseedForwarder)." -ForegroundColor Yellow
            $deployArgs = @('-Identifier', $Identifier, '-PrimaryNodeSuffix', $PrimaryNodeSuffix, '-SecondaryNodeSuffix', $SecondaryNodeSuffix,
                            '-DagForwarderPrimarySuffix', $ForwarderPrimarySuffix, '-DagForwarderSecondarySuffix', $ForwarderSecondarySuffix,
                            '-DagName', $DagName, '-AutoApprove')
            & pwsh -NoProfile -File (Join-Path $ProjectDir 'deploy.ps1') -Action remove-dag @deployArgs
            & pwsh -NoProfile -File (Join-Path $ProjectDir 'deploy.ps1') -Action deploy-dag @deployArgs
            if ($LASTEXITCODE -ne 0) { Write-Error 'deploy-dag failed while re-seeding the forwarder.'; exit 1 }
            $forwarderResult = 're-seeded'
        } else {
            $forwarderResult = 'NOT synchronizing'
            Write-Host ''
            Write-Host "  Forwarder $FwAg did not resynchronize within $ForwarderResyncMinutes min. It most likely holds" -ForegroundColor Red
            Write-Host '  transactions the new global primary never received. Re-run with -ReseedForwarder, or run' -ForegroundColor Red
            Write-Host '  ../../deploy.ps1 -Action remove-dag, then -Action deploy-dag.' -ForegroundColor Red
        }
        Add-Event 'forwarder-reattached' $forwarderResult
    }

    # 8. Lift the client fence: node-1 is now a readable secondary.
    Set-Fence -Remove -Only @('uc01-fence-deny-sql')
    Save-Evidence 'reinstate' ([ordered]@{ utc = (Format-Utc (Get-UtcNow)); inspect = $insp[0].Stdout; drop = $drop.Stdout; rpo = $rpo; forwarder = $forwarderResult })
    Write-Host ''
    Write-Host "  $($Orig.Name) is back as an ASYNCHRONOUS secondary of $($Dr.Name) (primary stays in $($Dr.Region))." -ForegroundColor Green
    if ($HasDag) { Write-Host "  Forwarder $FwAg : $forwarderResult." -ForegroundColor $(if ($forwarderResult -eq 'NOT synchronizing') { 'Red' } else { 'Green' }) }
    Write-Host "  Optional: -Action failback to make $($Orig.Name) primary again (planned, no data loss)."
}

function Invoke-Failback {
    Write-Step "Planned failback: $($Dr.Name) -> $($Orig.Name) (no data loss)"
    $b = @(Invoke-VmBatch @(
        (New-SqlRequest -Node $Dr   -File '00-status.sql' -Vars @{ AgName = $AgName } -Label 'AG status'),
        (New-SqlRequest -Node $Orig -File '00-status.sql' -Vars @{ AgName = $AgName } -Label 'AG status')))
    Assert-Ok $b
    if ((Get-Val $b[0] 'LOCAL_ROLE') -ne 'PRIMARY' -or (Get-Val $b[1] 'LOCAL_ROLE') -ne 'SECONDARY') {
        Write-Error "Failback expects $($Dr.Name) PRIMARY and $($Orig.Name) SECONDARY (got $(Get-Val $b[0] 'LOCAL_ROLE') / $(Get-Val $b[1] 'LOCAL_ROLE'))."
        exit 1
    }
    Write-Host '  Both replicas become SYNCHRONOUS and commits wait for the secondary until the swap completes;' -ForegroundColor Yellow
    Write-Host '  writes pause briefly while the AG is taken offline on the current primary.' -ForegroundColor Yellow
    Confirm-Yes "  Type 'yes' to fail back to $($Orig.Name)"

    $t0 = Get-UtcNow
    Invoke-Sql -Node $Dr -File '30-failback-prepare.sql' -Label 'sync + commit gating' -Vars @{ AgName = $AgName; CurrentPrimary = $Dr.Name; Target = $Orig.Name } | Out-Null
    Wait-ReplicaState -On $Dr -Replica $Orig.Name -Accept @('SYNCHRONIZED') -TimeoutMinutes 20 -What 'synchronization'
    Invoke-Sql -Node $Dr   -File '31-offline.sql' -Vars @{ AgName = $AgName } -Label 'AG offline' | Out-Null
    Invoke-Sql -Node $Orig -File '32-promote.sql' -Vars @{ AgName = $AgName } -Label 'promote' | Out-Null
    Invoke-Sql -Node $Dr   -File '33-demote-and-resume.sql' -Vars @{ AgName = $AgName; Demote = 1 } -Label 'demote + resume' | Out-Null
    Invoke-Sql -Node $Orig -File '33-demote-and-resume.sql' -Vars @{ AgName = $AgName; Demote = 0 } -Label 'resume' | Out-Null
    Invoke-Sql -Node $Orig -File '34-restore-original-modes.sql' -Label 'restore modes' -Vars @{ AgName = $AgName; Primary = $Orig.Name; Remote = $Dr.Name } | Out-Null
    $t1 = Get-UtcNow

    if ($HasDag) {
        # The global primary moved with AG1's primary: repoint on the global primary and the forwarder.
        $url = "tcp://$($Orig.PrivateIp):5022"
        $req = @(New-SqlRequest -Node $Orig -File '13-dag-repoint.sql' -Label 'repoint (global primary)' -Vars @{ DagName = $DagName; MemberAg = $AgName; ListenerUrl = $url })
        $req += New-SqlRequest -Node $FwPrimary -File '13-dag-repoint.sql' -Label 'repoint (forwarder)' -Vars @{ DagName = $DagName; MemberAg = $AgName; ListenerUrl = $url }
        $rp = @(Invoke-VmBatch $req); Assert-Ok $rp
        foreach ($r in $rp) { Write-Host "  DAG_REPOINTED = $(Get-Val $r 'DAG_REPOINTED')" }
        if (-not (Wait-ForwarderSync -From $Orig -TimeoutMinutes $ForwarderResyncMinutes)) {
            Write-Host "  WARNING: forwarder $FwAg is not synchronizing from $($Orig.Name) yet - check status." -ForegroundColor Yellow
        }
    }
    Set-DnsToIp -Ip $Orig.PrivateIp -Why 'failback'
    $w = Invoke-Sql -Node $Orig -File '12-write-test.sql' -Label 'write test' -Vars @{ DbName = $DemoDbName; RunId = (Get-RunIdOrNone); Rows = $WriteTestRows }
    Add-Event 'failback-completed'
    Save-Evidence 'failback' ([ordered]@{ startedUtc = (Format-Utc $t0); completedUtc = (Format-Utc $t1); writeTest = $w.Stdout })
    Write-Host ''
    Write-Host "  $($Orig.Name) is PRIMARY again ($($Orig.Region)); $($Dr.Name) is its ASYNC secondary. Role swap took $([math]::Round(($t1 - $t0).TotalSeconds)) s." -ForegroundColor Green
}

function Assert-Run {
    if (-not $script:RunId) { Write-Error "No drill run open - run '-Action precheck' first."; exit 1 }
}

# ── Inputs ─────────────────────────────────────────────────────────────────────
if (-not (Get-Command az -ErrorAction SilentlyContinue)) { Write-Error 'Azure CLI (az) not found.'; exit 1 }
$account = az account show 2>$null | ConvertFrom-Json
if (-not $account) { az login | Out-Null; $account = az account show 2>$null | ConvertFrom-Json }
if (-not $account) { Write-Error 'Azure login failed.'; exit 1 }
Write-Host "Using Azure subscription: $($account.name) ($($account.id))"

Write-Host ''
Write-Host 'UC-01 - Region failure of the primary node -> fail all transactions over to the alternate region' -ForegroundColor White
if (-not $Action) {
    $Action = Read-Choice -Prompt 'What do you want to do?' -Default 'status' `
        -Options @('status', 'precheck', 'start-workload', 'simulate-failure', 'failover', 'verify', 'drill', 'reinstate', 'failback') `
        -Descriptions @('roles, health, power state', 'healthy AGs? open a new drill run', 'start the ledger writer on the primary',
                        'hard power-off of the primary region', 'force failover to the DR node', 'check new primary + write test',
                        'precheck -> workload -> failure -> failover -> verify', 'bring the region back, rejoin, re-attach forwarder',
                        'planned failback to the original primary')
}
if (-not $Identifier) {
    $known = @(Get-ChildItem $StateDir -Filter '*.credentials.json' -ErrorAction SilentlyContinue | ForEach-Object { $_.Name -replace '\.credentials\.json$', '' })
    if ($known.Count) { Write-Host "Known stacks: $($known -join ', ')" -ForegroundColor DarkGray }
    $Identifier = Read-Name -Prompt 'Unique identifier used for the object names (e.g. 257672)' -Default '' -MaxLength 15
}
if (-not $PrimaryNodeSuffix)   { $PrimaryNodeSuffix   = Read-Name -Prompt 'AG1 primary node suffix - the node in the region that FAILS' -Default 'node-1' -MaxLength 20 }
if (-not $SecondaryNodeSuffix) { $SecondaryNodeSuffix = Read-Name -Prompt 'AG1 DR node suffix - the node in the alternate region' -Default 'node-2' -MaxLength 20 }
if (-not $ForwarderPrimarySuffix) {
    $ForwarderPrimarySuffix = Read-Name -Prompt "Distributed AG forwarder stack - primary node suffix ('none' if there's no distributed AG)" -Default 'node-3' -MaxLength 20
}
if ($ForwarderPrimarySuffix -ne 'none' -and -not $ForwarderSecondarySuffix) {
    $ForwarderSecondarySuffix = Read-Name -Prompt 'Distributed AG forwarder stack - secondary node suffix' -Default 'node-4' -MaxLength 20
}
$Identifier = $Identifier.ToLower(); $PrimaryNodeSuffix = $PrimaryNodeSuffix.ToLower(); $SecondaryNodeSuffix = $SecondaryNodeSuffix.ToLower()
$ForwarderPrimarySuffix = $ForwarderPrimarySuffix.ToLower(); $ForwarderSecondarySuffix = $ForwarderSecondarySuffix.ToLower()

$NamePrefix = "$Prefix-$Identifier"
if (-not $AgName) { $AgName = "agsqlvm-$PrimaryNodeSuffix" }
$HasDag = $ForwarderPrimarySuffix -ne 'none'
$FwAg   = if ($HasDag) { "agsqlvm-$ForwarderPrimarySuffix" } else { $null }
if ($HasDag -and -not $DagName) { $DagName = "dagsqlvm-$PrimaryNodeSuffix-$ForwarderPrimarySuffix" }

$Orig = New-UcNode -Role 'AG1 primary' -Suffix $PrimaryNodeSuffix   -StackPrimary $PrimaryNodeSuffix -StackSecondary $SecondaryNodeSuffix -Ag $AgName
$Dr   = New-UcNode -Role 'AG1 DR'      -Suffix $SecondaryNodeSuffix -StackPrimary $PrimaryNodeSuffix -StackSecondary $SecondaryNodeSuffix -Ag $AgName
$ForwarderNodes = @()
if ($HasDag) {
    $ForwarderNodes = @(
        (New-UcNode -Role 'AG2 forwarder' -Suffix $ForwarderPrimarySuffix   -StackPrimary $ForwarderPrimarySuffix -StackSecondary $ForwarderSecondarySuffix -Ag $FwAg),
        (New-UcNode -Role 'AG2 secondary' -Suffix $ForwarderSecondarySuffix -StackPrimary $ForwarderPrimarySuffix -StackSecondary $ForwarderSecondarySuffix -Ag $FwAg))
}
$FwPrimary = if ($HasDag) { $ForwarderNodes[0] } else { $null }
$AllNodes  = @($Orig, $Dr) + @($ForwarderNodes)
# A region failure takes down every node in the primary's region - AG1's primary and any forwarder node there.
$RegionNodes = @($AllNodes | Where-Object { $_.Region -eq $Orig.Region -and $_.Vm -ne $Dr.Vm })

if ($Orig.Region -eq $Dr.Region) {
    Write-Host ''
    Write-Host "WARNING: $($Orig.Name) and $($Dr.Name) are both in $($Orig.Region). A region failure takes BOTH down -" -ForegroundColor Red
    Write-Host 'UC-01 cannot be satisfied by this AG (no replica in an alternate region). The drill still exercises the mechanics.' -ForegroundColor Red
    Confirm-Yes "Type 'yes' to continue anyway"
}
if ($PrivateDnsZone -and -not $PrivateDnsRecord) { Write-Error '-PrivateDnsRecord is required with -PrivateDnsZone.'; exit 1 }

$RunsRoot       = Join-Path $UcDir 'runs' $Orig.Rg
$CurrentRunFile = Join-Path $RunsRoot 'current-run.txt'
New-Item -ItemType Directory -Force -Path $RunsRoot | Out-Null
$script:RunId = if (Test-Path $CurrentRunFile) { (Get-Content $CurrentRunFile -Raw).Trim() } else { $null }

$LogFile = Join-Path $RunsRoot "$Action-$((Get-UtcNow).ToString('yyyyMMdd-HHmmss')).log"
Start-Transcript -Path $LogFile | Out-Null
try {
    Write-Host "AG1 $AgName : $($Orig.Name) ($($Orig.Region), primary) -> $($Dr.Name) ($($Dr.Region), DR)"
    if ($HasDag) { Write-Host "Distributed AG $DagName : $AgName -> $FwAg ($(($ForwarderNodes | ForEach-Object { "$($_.Name) $($_.Region)" }) -join ', '))" }
    Write-Host "Failure domain (region $($Orig.Region)): $(($RegionNodes | ForEach-Object { $_.Name }) -join ', ')"
    if ($script:RunId) { Write-Host "Current drill run: $($script:RunId)" }

    switch ($Action) {
        'status'           { Invoke-Status }
        'precheck'         { Invoke-Precheck }
        'start-workload'   { Invoke-StartWorkload }
        'simulate-failure' { Invoke-SimulateFailure }
        'failover'         { Invoke-Failover }
        'verify'           { Invoke-Verify }
        'reinstate'        { Invoke-Reinstate }
        'failback'         { Invoke-Failback }
        'drill' {
            Write-Host ''
            Write-Host "Drill: every node in $($Orig.Region) ($(($RegionNodes | ForEach-Object { $_.Name }) -join ', ')) will be POWERED OFF" -ForegroundColor Yellow
            Write-Host "and $AgName FORCED over to $($Dr.Name) ($($Dr.Region)). Transactions not yet replicated are lost by design." -ForegroundColor Yellow
            Confirm-Yes "Type 'yes' to run the full drill"
            $AutoApprove = $true   # one confirmation for the whole drill
            Invoke-Precheck
            Invoke-StartWorkload
            Write-Host "  Warm-up: $WarmupSeconds s of writes before the outage ..."
            Start-Sleep $WarmupSeconds
            Invoke-SimulateFailure
            Write-Host "  Detection/decision window: $DetectSeconds s ..."
            Start-Sleep $DetectSeconds
            Invoke-Failover
            Invoke-Verify
            Write-Host ''
            Write-Host "Drill complete. Evidence: $(Get-RunDir)" -ForegroundColor Green
            Write-Host "When region $($Orig.Region) is 'back': ./uc-01.ps1 -Action reinstate -Identifier $Identifier -PrimaryNodeSuffix $PrimaryNodeSuffix -SecondaryNodeSuffix $SecondaryNodeSuffix -ForwarderPrimarySuffix $ForwarderPrimarySuffix -ForwarderSecondarySuffix $ForwarderSecondarySuffix"
        }
    }
} finally {
    Stop-Transcript | Out-Null
}
