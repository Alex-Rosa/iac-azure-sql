# Shared framework of the use cases (dot-source it from use-cases/uc-NN/uc-NN.ps1).
#
# Before dot-sourcing, the use case sets:
#   $UcId   'uc-02'   (the dashboard / runs identity)
#   $UcTag  'uc02'    (prefix of temp files on the VMs)
#   $UcDir  $PSScriptRoot
# and declares these parameters: Action, Identifier, PrimaryNodeSuffix, SecondaryNodeSuffix, Forwarders,
# ForwarderPrimarySuffix, ForwarderSecondarySuffix, Prefix, AgName, DagName, AutoApprove, Dashboard,
# DashboardMode, DashboardRefreshSeconds.
#
# Then: Connect-UcAzure, ask for its -Action, Initialize-UcTopology, and Invoke-UcMain with its actions.
# Everything runs through 'az vm run-command' (Invoke-VmBatch), in parallel across VMs; every run writes
# evidence and dashboard events to runs/<rg>/<run-id>/.

$ProjectDir    = (Resolve-Path (Join-Path $UcDir '..' '..')).Path
$SqlDir        = Join-Path $UcDir 'sql'                 # the use case's own T-SQL
$CommonSqlDir  = Join-Path $PSScriptRoot 'sql'          # T-SQL shared by every use case
$StateDir      = Join-Path $ProjectDir 'state'
$SuffixPattern = '^[a-z0-9]([a-z0-9-]{0,18}[a-z0-9])?$'

# Dashboard events (phases, nodes, links, metrics, samples) - see uc-events.ps1.
. (Join-Path $PSScriptRoot 'uc-events.ps1')
Set-UcEventSink { Get-RunDir }
$script:UcSessionStarted = $false
$script:UcCancelled      = $false
$script:UcSessionParams  = @{}   # extra narration placeholders for the dashboard ({workload}, ...)
$script:RunId            = $null

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
    if ((Read-Host $Prompt) -ne 'yes') { Write-Host 'Cancelled.'; $script:UcCancelled = $true; exit 0 }
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
    param([string]$Name, [string]$Detail = '', [string]$Level = 'info')
    Write-UcEvent -Event $Name -Detail $Detail -Level $Level
}

# Opens the dashboard session of this process: topology (merged by the dashboard - a later session,
# e.g. reinstate, keeps the roles/links the previous actions left) + 'action started'.
function Start-UcSession {
    if ($script:UcSessionStarted -or -not $script:RunId) { return }
    $script:UcSessionStarted = $true
    $initialRole = @{ $Orig.Name = 'PRIMARY'; $Dr.Name = 'SECONDARY' }
    $groups = @(@{ id = $AgName; label = 'AG1'; kind = 'global' })
    $links  = @(@{ id = "ag-$AgName"; kind = 'ag'; from = $Orig.Name; to = $Dr.Name; label = 'AG1'; state = 'healthy' })
    for ($i = 0; $i -lt $ForwarderList.Count; $i++) {
        $f = $ForwarderList[$i]
        $initialRole[$f.Primary.Name] = 'FORWARDER'; $initialRole[$f.Secondary.Name] = 'SECONDARY'
        $groups += @{ id = $f.Ag; label = "AG$($i + 2)"; kind = 'forwarder'; dag = $f.Dag }
        $links  += @{ id = "ag-$($f.Ag)"; kind = 'ag'; from = $f.Primary.Name; to = $f.Secondary.Name; label = "AG$($i + 2)"; state = 'healthy' }
        $links  += @{ id = $f.Dag; kind = 'dag'; from = $Orig.Name; to = $f.Primary.Name; label = "DAG -> AG$($i + 2)"; state = 'healthy' }
    }
    $nodes = @($AllNodes | ForEach-Object {
        @{ id = $_.Name; label = $_.Suffix; name = $_.Name; vm = $_.Vm; rg = $_.Rg; region = $_.Region; ip = $_.PrivateIp
           group = $_.Ag; stack = $_.Identifier; role = $initialRole[$_.Name]; global = ($_.Name -eq $Orig.Name) }
    })
    $regions = @(@($Orig.Region, $Dr.Region) + @($AllNodes | ForEach-Object { $_.Region }) | Select-Object -Unique)
    $params = @{ primaryRegion = $Orig.Region; drRegion = $Dr.Region; failedRegion = $FailedRegion
                 primary = $Orig.Suffix; dr = $Dr.Suffix; ag = $AgName }
    foreach ($k in $script:UcSessionParams.Keys) { $params[$k] = $script:UcSessionParams[$k] }
    Write-UcTopology -UseCase $UcId -Nodes $nodes -Groups $groups -Links $links -Regions $regions -Params $params
    Set-UcAction -Action $Action -Status started
}

function Get-RunIdOrNone { if ($script:RunId) { $script:RunId } else { 'none' } }

# ── Topology ───────────────────────────────────────────────────────────────────
function New-UcNode {
    param([string]$Role, [string]$StackIdentifier, [string]$Suffix, [string]$StackPrimary, [string]$StackSecondary, [string]$Ag)
    $prefix = "$Prefix-$StackIdentifier"
    $rg = "$prefix-$StackPrimary-$StackSecondary-rg"
    $credsFile = Join-Path $StateDir "$rg.credentials.json"
    if (-not (Test-Path $credsFile)) { Write-Error "No saved credentials for $rg ($credsFile)."; exit 1 }
    $vm = "$prefix-$Suffix-vm"
    $info = az vm show -g $rg -n $vm --query '{l:location}' -o json 2>$null | ConvertFrom-Json
    if (-not $info) { Write-Error "VM $vm not found in $rg."; exit 1 }
    $ip = az network nic show -g $rg -n "$prefix-$Suffix-nic" --query 'ipConfigurations[0].privateIPAddress' -o tsv 2>$null
    return [pscustomobject]@{
        Role = $Role; Identifier = $StackIdentifier; Suffix = $Suffix; Name = "$prefix-$Suffix"; Vm = $vm; Rg = $rg; Nsg = "$prefix-$Suffix-nsg"
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
# Azure runs one Run Command per VM at a time: never put two requests for the same VM in one batch.
function Invoke-VmBatch {
    param([object[]]$Requests, [switch]$Quiet)
    $template = @'
#!/bin/bash
export SQLCMDPASSWORD='__PASSWORD__'
SQL() { /opt/mssql-tools18/bin/sqlcmd -S localhost -U SA -No -C -b -W -h -1 "$@"; }
(
set -euo pipefail
__BODY__
)
echo "UC_EXIT=$?"
'@
    $jobs = @(foreach ($r in $Requests) {
        [pscustomobject]@{
            Rg = $r.Node.Rg; Vm = $r.Node.Vm; Label = $r.Label
            Script = $template.Replace('__PASSWORD__', $r.Node.Sa).Replace('__BODY__', $r.Body).Replace("`r`n", "`n")
        }
    })
    if (-not $Quiet) { foreach ($j in $jobs) { Write-Host "  [$($j.Vm)] $($j.Label) ..." -ForegroundColor DarkGray } }
    $raw = @($jobs | ForEach-Object -ThrottleLimit 6 -Parallel {
        $j = $_
        $tmp = Join-Path ([System.IO.Path]::GetTempPath()) ('uc-' + [guid]::NewGuid().ToString('N') + '.sh')
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
        $exit = if ($values.ContainsKey('UC_EXIT')) { [int]$values['UC_EXIT'][-1] } else { -1 }
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
# The file is looked up in the use case's sql/ folder first, then in use-cases/common/sql/.
function Get-SqlBody {
    param([string]$File, [hashtable]$Vars = @{})
    $path = Join-Path $SqlDir $File
    if (-not (Test-Path $path)) { $path = Join-Path $CommonSqlDir $File }
    $content = (Get-Content $path -Raw).Replace("`r`n", "`n")
    $varArgs = ($Vars.GetEnumerator() | Sort-Object Key | ForEach-Object { "$($_.Key)=`"$($_.Value)`"" }) -join ' '
    $vFlag   = if ($varArgs) { "-v $varArgs " } else { '' }
    return "cat > /tmp/$UcTag-$File <<'UCSQL'`n$content`nUCSQL`nSQL $vFlag-i /tmp/$UcTag-$File"
}

function New-SqlRequest {
    param($Node, [string]$File, [hashtable]$Vars = @{}, [string]$Label = $File, [string]$Prefix = '')
    return @{ Node = $Node; Label = $Label; Body = $Prefix + (Get-SqlBody -File $File -Vars $Vars) }
}

function Invoke-Sql {
    param($Node, [string]$File, [hashtable]$Vars = @{}, [string]$Label = $File, [string]$Prefix = '', [switch]$AllowFail, [switch]$Quiet)
    $r = @(Invoke-VmBatch @(New-SqlRequest -Node $Node -File $File -Vars $Vars -Label $Label -Prefix $Prefix) -Quiet:$Quiet)[0]
    if (-not $AllowFail) { Assert-Ok $r }
    return $r
}

# ── Distributed AG helpers ─────────────────────────────────────────────────────
# 14-dag-status.sql for every listed distributed AG, in one body (every line is prefixed with the
# distributed AG's name: DAG_EXISTS=<dag>|0/1, DAG_MEMBER=<dag>|<ag>|<url>|<role>|<conn>|<health>,
# DAG_DB=<dag>|<ag>|<db>|<state>|suspended=0/1).
function Get-DagStatusBody {
    param([object[]]$Fws)
    return ((@($Fws) | ForEach-Object { Get-SqlBody -File '14-dag-status.sql' -Vars @{ DagName = $_.Dag } }) -join "`n")
}

function Get-DagMember {
    param($Result, [string]$Dag, [string]$MemberAg)
    return (@(Get-Vals $Result 'DAG_MEMBER' | Where-Object { $_ -like "$Dag|$MemberAg|*" }) | Select-Object -First 1)
}

function Get-DagDbRows {
    param($Result, [string]$Dag, [string]$MemberAg)
    return @(Get-Vals $Result 'DAG_DB' | Where-Object { $_ -like "$Dag|$MemberAg|*" })
}

# Points AG1's LISTENER_URL at $Url in every listed distributed AG: on the global primary node (all
# distributed AGs in ONE call) and, unless -GlobalSideOnly, on each forwarder's primary replica.
function Invoke-DagRepoint {
    param($GlobalPrimary, [object[]]$Fws, [string]$Url, [switch]$GlobalSideOnly)
    $body = (@($Fws) | ForEach-Object { Get-SqlBody -File '13-dag-repoint.sql' -Vars @{ DagName = $_.Dag; MemberAg = $AgName; ListenerUrl = $Url } }) -join "`n"
    $requests = @(@{ Node = $GlobalPrimary; Label = 'repoint distributed AG(s) (global primary)'; Body = $body })
    if (-not $GlobalSideOnly) {
        foreach ($f in $Fws) {
            $requests += New-SqlRequest -Node $f.Primary -File '13-dag-repoint.sql' -Label "repoint $($f.Dag) (forwarder)" `
                -Vars @{ DagName = $f.Dag; MemberAg = $AgName; ListenerUrl = $Url }
        }
    }
    $rp = @(Invoke-VmBatch $requests)
    Assert-Ok $rp
    $out = @()
    foreach ($r in $rp) { foreach ($v in (Get-Vals $r 'DAG_REPOINTED')) { Write-Host "  DAG_REPOINTED = $v"; $out += $v } }
    return $out
}

# Resumes data movement on every node of the listed forwarder AGs (suspended by the forced failover upstream).
function Resume-Forwarders {
    param([object[]]$Fws)
    $requests = foreach ($f in $Fws) { foreach ($n in $f.Nodes) { New-SqlRequest -Node $n -File '33-demote-and-resume.sql' -Label 'resume' -Vars @{ AgName = $f.Ag; Demote = 0 } } }
    $res = @(Invoke-VmBatch @($requests))
    Assert-Ok $res
    foreach ($r in $res) { foreach ($k in @('RESUMED', 'RESUME_SKIPPED')) { foreach ($v in (Get-Vals $r $k)) { Write-Host "  [$($r.Vm)] $k = $v" } } }
}

# Waits until every listed forwarder AG's databases are SYNCHRONIZING/SYNCHRONIZED in its distributed
# AG, as seen from the global primary ($From). Returns the forwarders still NOT synchronizing at timeout.
function Wait-ForwardersSync {
    param($From, [object[]]$Fws, [int]$TimeoutMinutes)
    $deadline = (Get-UtcNow).AddMinutes($TimeoutMinutes)
    while ($true) {
        $s = @(Invoke-VmBatch @(@{ Node = $From; Label = 'distributed AG state'; Body = (Get-DagStatusBody $Fws) }))[0]
        Assert-Ok $s
        $pending = @()
        foreach ($f in $Fws) {
            $rows = @(Get-DagDbRows $s $f.Dag $f.Ag)
            $ok = @($rows | Where-Object { $_.Split('|')[3] -in @('SYNCHRONIZING', 'SYNCHRONIZED') -and $_ -notmatch 'suspended=1' })
            Write-Host "  $($f.Dag): forwarder $($f.Ag) $($ok.Count)/$($rows.Count) database(s) synchronizing  [$(Get-DagMember $s $f.Dag $f.Ag)]"
            if ($rows.Count -eq 0 -or $ok.Count -lt $rows.Count) { $pending += $f }
        }
        if ($pending.Count -eq 0) { return @() }
        if ((Get-UtcNow) -gt $deadline) { return $pending }
        Start-Sleep 30
    }
}

# Rebuilds one forwarder's distributed AG (drop + deploy-dag), which re-seeds the forwarder from the
# CURRENT global primary. Only valid while every node of both stacks is up and AG1 is healthy.
function Invoke-ReseedForwarder {
    param($F)
    Write-Host "  Re-seeding $($F.Ag): rebuilding $($F.Dag) with ../../sqlvm-linux-ag.ps1 (remove-dag, deploy-dag) ..." -ForegroundColor Yellow
    $deployArgs = @('-Identifier', $Identifier, '-PrimaryNodeSuffix', $PrimaryNodeSuffix, '-SecondaryNodeSuffix', $SecondaryNodeSuffix,
                    '-DagForwarderIdentifier', $F.Identifier, '-DagForwarderPrimarySuffix', $F.PrimarySuffix, '-DagForwarderSecondarySuffix', $F.SecondarySuffix,
                    '-DagName', $F.Dag, '-AutoApprove')
    & pwsh -NoProfile -File (Join-Path $ProjectDir 'sqlvm-linux-ag.ps1') -Action remove-dag @deployArgs
    & pwsh -NoProfile -File (Join-Path $ProjectDir 'sqlvm-linux-ag.ps1') -Action deploy-dag @deployArgs
    if ($LASTEXITCODE -ne 0) { Write-Error "deploy-dag failed while re-seeding $($F.Ag)."; exit 1 }
}

# ── Status helpers ─────────────────────────────────────────────────────────────
function Get-StatusAll {
    param([object[]]$Nodes)
    $running = @($Nodes | Where-Object { $_.Power -eq 'running' })
    $result = @{}
    if ($running.Count -eq 0) { return $result }
    $requests = foreach ($n in $running) {
        $body = Get-SqlBody -File '00-status.sql' -Vars @{ AgName = $n.Ag }
        if ($HasDag) { $body += "`n" + (Get-DagStatusBody $ForwarderList) }
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

function Assert-Run {
    if (-not $script:RunId) { Write-Error "No drill run open - run '-Action precheck' first."; exit 1 }
}
# ── Azure login + topology ─────────────────────────────────────────────────────
function Connect-UcAzure {
    if (-not (Get-Command az -ErrorAction SilentlyContinue)) { Write-Error 'Azure CLI (az) not found.'; exit 1 }
    $account = az account show 2>$null | ConvertFrom-Json
    if (-not $account) { az login | Out-Null; $account = az account show 2>$null | ConvertFrom-Json }
    if (-not $account) { Write-Error 'Azure login failed.'; exit 1 }
    Write-Host "Using Azure subscription: $($account.name) ($($account.id))"
}

# Asks for what wasn't passed (identifier, AG1 suffixes, forwarder stacks), then builds the topology:
#   $Orig (AG1 primary), $Dr (AG1 DR replica), $ForwarderList (one per distributed AG of AG1),
#   $AllNodes, $HasDag, $FailedRegion, $RegionNodes (every node that goes down with $FailedRegion),
#   $RunsRoot / $CurrentRunFile / $script:RunId.
# -FailingSide: which of AG1's regions the use case takes down.
function Initialize-UcTopology {
    param([ValidateSet('primary', 'secondary')][string]$FailingSide, [string]$PrimaryPrompt, [string]$SecondaryPrompt)
    if (-not $script:Identifier) {
        $known = @(Get-ChildItem $StateDir -Filter '*.credentials.json' -ErrorAction SilentlyContinue | ForEach-Object { $_.Name -replace '\.credentials\.json$', '' })
        if ($known.Count) { Write-Host "Known stacks: $($known -join ', ')" -ForegroundColor DarkGray }
        $script:Identifier = Read-Name -Prompt 'Unique identifier used for the object names (e.g. 257672)' -Default '' -MaxLength 15
    }
    if (-not $script:PrimaryNodeSuffix)   { $script:PrimaryNodeSuffix   = Read-Name -Prompt $PrimaryPrompt -Default 'node-1' -MaxLength 20 }
    if (-not $script:SecondaryNodeSuffix) { $script:SecondaryNodeSuffix = Read-Name -Prompt $SecondaryPrompt -Default 'node-2' -MaxLength 20 }
    $script:Identifier = $script:Identifier.ToLower()
    $script:PrimaryNodeSuffix = $script:PrimaryNodeSuffix.ToLower()
    $script:SecondaryNodeSuffix = $script:SecondaryNodeSuffix.ToLower()
    $id = $script:Identifier; $pSuffix = $script:PrimaryNodeSuffix; $sSuffix = $script:SecondaryNodeSuffix

    # Forwarder stacks: -Forwarders entries, the single-pair shorthand, or asked for.
    $fwPairs = @($script:Forwarders | ForEach-Object { $_ -split '[,\s]+' } | Where-Object { $_ })
    if ($script:ForwarderPrimarySuffix) {
        if ($script:ForwarderPrimarySuffix -eq 'none') { $fwPairs += 'none' }
        else {
            if (-not $script:ForwarderSecondarySuffix) { $script:ForwarderSecondarySuffix = Read-Name -Prompt "Forwarder stack $($script:ForwarderPrimarySuffix) - secondary node suffix" -Default '' -MaxLength 20 }
            $fwPairs += "$($script:ForwarderPrimarySuffix):$($script:ForwarderSecondarySuffix)"
        }
    }
    if ($fwPairs.Count -eq 0) {
        Write-Host ''
        Write-Host "Distributed AGs: AG1's forwarder stacks, comma-separated, each as" -ForegroundColor Cyan
        Write-Host "  <identifier>:<primary suffix>:<secondary suffix>   (e.g. ag02:node-3:node-4,ag03:node-5:node-6)" -ForegroundColor Cyan
        Write-Host "  <primary suffix>:<secondary suffix>                (same identifier as AG1: $id)" -ForegroundColor Cyan
        Write-Host "or 'none'. Declare every forwarder of AG1." -ForegroundColor Cyan
        $answer = (Read-Line 'Forwarder stacks [node-3:node-4]').ToLower()
        if (-not $answer) { $answer = 'node-3:node-4' }
        $fwPairs = @($answer -split '[,\s]+' | Where-Object { $_ })
    }
    $fwPairs = @($fwPairs | ForEach-Object { $_.ToLower() } | Where-Object { $_ -ne 'none' } | Select-Object -Unique)

    if (-not $script:AgName) { $script:AgName = "agsqlvm-$pSuffix" }
    if ($script:DagName -and $fwPairs.Count -ne 1) { Write-Error '-DagName can only be used with exactly one forwarder stack.'; exit 1 }

    $script:Orig = New-UcNode -Role 'AG1 primary' -StackIdentifier $id -Suffix $pSuffix -StackPrimary $pSuffix -StackSecondary $sSuffix -Ag $script:AgName
    $script:Dr   = New-UcNode -Role 'AG1 DR'      -StackIdentifier $id -Suffix $sSuffix -StackPrimary $pSuffix -StackSecondary $sSuffix -Ag $script:AgName
    $script:FailedRegion = if ($FailingSide -eq 'primary') { $script:Orig.Region } else { $script:Dr.Region }

    $fwList = @()
    # Nodes are identified by identifier + suffix (ag01/node-1 and ag02/node-1 are different nodes).
    $usedNodes = @("$id/$pSuffix", "$id/$sSuffix")
    $usedAgs   = @($script:AgName)
    foreach ($pair in $fwPairs) {
        $parts = @($pair.Split(':'))
        if ($parts.Count -eq 2) { $parts = @($id) + $parts }
        if ($parts.Count -ne 3 -or $parts[0] -cnotmatch '^[a-z0-9]([a-z0-9-]{0,13}[a-z0-9])?$' -or
            $parts[1] -cnotmatch $SuffixPattern -or $parts[2] -cnotmatch $SuffixPattern) {
            Write-Error "Invalid forwarder '$pair' - use <identifier>:<primary suffix>:<secondary suffix> (e.g. ag02:node-3:node-4) or <primary suffix>:<secondary suffix>."; exit 1
        }
        $fwId = $parts[0]; $fwP = $parts[1]; $fwS = $parts[2]
        $nodes = @("$fwId/$fwP", "$fwId/$fwS")
        if ($fwP -eq $fwS -or @($nodes | Where-Object { $usedNodes -contains $_ }).Count -gt 0) {
            Write-Error "Forwarder '$pair' reuses a node ($($nodes -join ', '))."; exit 1
        }
        $usedNodes += $nodes
        $fwAg = "agsqlvm-$fwP"
        # A distributed AG joins AGs by name: every AG involved needs its own name.
        if ($usedAgs -contains $fwAg) { Write-Error "Forwarder '$pair': AG name '$fwAg' is already used by another stack in this set - distributed AGs need distinct AG names."; exit 1 }
        $usedAgs += $fwAg
        $pn = New-UcNode -Role "$fwAg forwarder" -StackIdentifier $fwId -Suffix $fwP -StackPrimary $fwP -StackSecondary $fwS -Ag $fwAg
        $sn = New-UcNode -Role "$fwAg secondary" -StackIdentifier $fwId -Suffix $fwS -StackPrimary $fwP -StackSecondary $fwS -Ag $fwAg
        $fwList += [pscustomobject]@{
            Identifier = $fwId; PrimarySuffix = $fwP; SecondarySuffix = $fwS; Ag = $fwAg
            Dag = $(if ($script:DagName) { $script:DagName } else { "dagsqlvm-$pSuffix-$fwP" })
            Primary = $pn; Secondary = $sn; Nodes = @($pn, $sn); InFailedRegion = ($pn.Region -eq $script:FailedRegion)
        }
    }
    $script:ForwarderList  = $fwList
    $script:HasDag         = $fwList.Count -gt 0
    $script:ForwarderNodes = @($fwList | ForEach-Object { $_.Nodes })
    $script:AllNodes       = @($script:Orig, $script:Dr) + @($script:ForwarderNodes)
    # Every node that goes down with the failed region (AG1's surviving node never does).
    $survivor = if ($FailingSide -eq 'primary') { $script:Dr } else { $script:Orig }
    $script:RegionNodes = @($script:AllNodes | Where-Object { $_.Region -eq $script:FailedRegion -and $_.Vm -ne $survivor.Vm })

    $script:RunsRoot       = Join-Path $UcDir 'runs' $script:Orig.Rg
    $script:CurrentRunFile = Join-Path $script:RunsRoot 'current-run.txt'
    New-Item -ItemType Directory -Force -Path $script:RunsRoot | Out-Null
    $script:RunId = if (Test-Path $script:CurrentRunFile) { (Get-Content $script:CurrentRunFile -Raw).Trim() } else { $null }
}

# The '-Forwarders' value that recreates the current forwarder list (for "next step" hints).
function Get-UcForwardersArg {
    if (-not $HasDag) { return ' -Forwarders none' }
    return " -Forwarders $(($ForwarderList | ForEach-Object { "$($_.Identifier):$($_.PrimarySuffix):$($_.SecondarySuffix)" }) -join ',')"
}

# ── Report ─────────────────────────────────────────────────────────────────────
# Static HTML report of the current run (the dashboard's page at the end of the run, with every chart,
# key number, criterion and event): runs/<rg>/<run-id>/report.html.
function Export-UcReport {
    if (-not $script:RunId) { Write-Host '  No drill run to report on.' -ForegroundColor Yellow; return }
    $out = Join-Path (Get-RunDir) 'report.html'
    & pwsh -NoProfile -File (Join-Path $ProjectDir 'dashboard' 'dashboard.ps1') -UseCase $UcId -Stack $Orig.Rg -Report $script:RunId -Out $out -NoBrowser
    if ($LASTEXITCODE -eq 0 -and (Test-Path $out)) { Write-Host "Report: $out" -ForegroundColor Green }
    else { Write-Host "  The report couldn't be written (see above)." -ForegroundColor Yellow }
}

# ── Main runner ────────────────────────────────────────────────────────────────
# Opens the dashboard (-Dashboard), records a transcript, opens the dashboard session (except for
# -ReadOnly actions and the -OpensRun actions, which open a new run themselves), runs $Actions[$Action]
# and closes the session - also on 'exit': the phase that was running is marked failed.
function Invoke-UcMain {
    param([hashtable]$Actions, [string[]]$OpensRun = @('precheck', 'drill'), [string[]]$ReadOnly = @('status'), [scriptblock]$Banner)
    if ($Dashboard) {
        & pwsh -NoProfile -File (Join-Path $ProjectDir 'dashboard' 'dashboard.ps1') -UseCase $UcId -Stack $Orig.Rg `
            -Mode $DashboardMode -RefreshSeconds $DashboardRefreshSeconds -Detach
    }
    $logFile = Join-Path $RunsRoot "$Action-$((Get-UtcNow).ToString('yyyyMMdd-HHmmss')).log"
    Start-Transcript -Path $logFile | Out-Null
    $script:UcActionOk = $false
    try {
        if ($Banner) { & $Banner }
        if ($script:RunId) { Write-Host "Current drill run: $($script:RunId)" }
        if ($Action -notin ($ReadOnly + $OpensRun)) { Start-UcSession }
        & $Actions[$Action]
        $script:UcActionOk = $true
    } catch {
        # An unexpected error (a bug, not one of the use case's own checks): report it and fail.
        Write-Host "  ERROR: $($_.Exception.Message)" -ForegroundColor Red
        Write-Host "  $($_.InvocationInfo.PositionMessage)" -ForegroundColor DarkGray
        Add-Event 'unexpected-error' $_.Exception.Message -Level 'error'
        exit 1
    } finally {
        if ($script:UcSessionStarted) {
            $why = if ($script:UcCancelled) { 'cancelled by the operator' } else { 'stopped with an error - see the log' }
            if (-not $script:UcActionOk -and (Get-UcRunningPhase)) { Set-UcPhase (Get-UcRunningPhase) failed $why }
            Set-UcAction -Action $Action -Status $(if ($script:UcActionOk) { 'completed' } else { 'failed' }) -Detail $(if ($script:UcActionOk) { "$Action completed" } else { "$Action $why" })
        }
        Stop-Transcript | Out-Null
    }
}
