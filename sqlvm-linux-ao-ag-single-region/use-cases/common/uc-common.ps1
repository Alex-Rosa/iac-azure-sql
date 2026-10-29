# Shared framework of the use cases (dot-source it from use-cases/uc-NN/uc-NN.ps1).
#
# Before dot-sourcing, the use case sets:
#   $UcId   'uc-01'   (the dashboard / runs identity)
#   $UcTag  'uc01'    (prefix of temp files on the VMs)
#   $UcDir  $PSScriptRoot
# and declares these parameters: Action, Identifier, PrimaryNodeSuffix, SecondaryNodeSuffix, Prefix, AgName,
# DemoDbName, WorkloadSeconds, AutoApprove, Dashboard, DashboardMode, DashboardRefreshSeconds.
#
# Then: Connect-UcAzure, ask for its -Action, Initialize-UcTopology, and Invoke-UcMain with its actions.
# Everything runs through 'az vm run-command' (Invoke-VmBatch), so neither SSH nor 1433 has to be
# reachable from this machine; every run writes evidence and dashboard events to runs/<rg>/<run-id>/.
#
# Single-region stack (../../sqlvm-linux-ag.ps1): two nodes, one AG, both replicas SYNCHRONOUS_COMMIT,
# CLUSTER_TYPE = NONE. The nodes' roles change with every failover, so the use cases work with
#   $Pri / $Sec   the AG primary / secondary when the drill run started (precheck), or right now
#   $NodeA / $NodeB   the primary-suffix / secondary-suffix nodes (fixed)
# Each node sits in its own failure domain - an availability zone (or a fault domain of the availability
# set) - and the dashboard draws one column per domain.

$ProjectDir    = (Resolve-Path (Join-Path $UcDir '..' '..')).Path
$ScriptsDir    = Join-Path $ProjectDir 'scripts'           # the project's node scripts (ag-08, ag-09)
$SqlDir        = Join-Path $UcDir 'sql'                     # the use case's own T-SQL
$CommonSqlDir  = Join-Path $PSScriptRoot 'sql'              # T-SQL shared by every use case
$StateDir      = Join-Path $ProjectDir 'state'

# Dashboard events (phases, nodes, links, metrics, samples) - see uc-events.ps1.
. (Join-Path $PSScriptRoot 'uc-events.ps1')
Set-UcEventSink { Get-RunDir }
$script:UcSessionStarted = $false
$script:UcCancelled      = $false
$script:UcSessionParams  = @{}   # extra narration placeholders for the dashboard
$script:RunId            = $null
$script:MonitorCursor    = $null # epoch second up to which writer samples were emitted

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
function ConvertFrom-EpochMs { param($Ms) [DateTimeOffset]::FromUnixTimeMilliseconds([int64]$Ms).UtcDateTime }
function ConvertTo-EpochMs { param([datetime]$T) [DateTimeOffset]::new($T.ToUniversalTime()).ToUnixTimeMilliseconds() }
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

function Get-RunIdOrNone { if ($script:RunId) { $script:RunId } else { 'none' } }

function Assert-Run {
    if (-not $script:RunId) { Write-Error "No drill run open - run '-Action precheck' (or 'drill') first."; exit 1 }
}

# ── Run Command transport ──────────────────────────────────────────────────────
# Runs bash bodies on several VMs in parallel. Each request: @{ Node; Body; Label }. The body sees
# SQLCMDPASSWORD (the stack's SA password) and a SQL() sqlcmd wrapper for the local instance. Returns
# results in request order with KEY=VALUE stdout lines parsed into .Values (Azure caps output at ~4 KB).
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
    param($Node, [string]$File, [hashtable]$Vars = @{}, [string]$Label = $File)
    return @{ Node = $Node; Label = $Label; Body = (Get-SqlBody -File $File -Vars $Vars) }
}

function Invoke-Sql {
    param($Node, [string]$File, [hashtable]$Vars = @{}, [string]$Label = $File, [switch]$AllowFail, [switch]$Quiet)
    $r = @(Invoke-VmBatch @(New-SqlRequest -Node $Node -File $File -Vars $Vars -Label $Label) -Quiet:$Quiet)[0]
    if (-not $AllowFail) { Assert-Ok $r }
    return $r
}

# Bash lines that write the project's scripts/<Script> to the VM and run it with single-quoted arguments.
function Get-ScriptBody {
    param([string]$Script, [string[]]$Arguments)
    $content = (Get-Content (Join-Path $ScriptsDir $Script) -Raw).Replace("`r`n", "`n")
    $argString = ($Arguments | ForEach-Object { "'$_'" }) -join ' '
    return "cat > /tmp/$UcTag-$Script <<'UCNODESCRIPT'`n$content`nUCNODESCRIPT`nchmod +x /tmp/$UcTag-$Script`n/tmp/$UcTag-$Script $argString"
}

# ag-08-status.sh: HOST, SQL_UP, LOCAL_ROLE, REQUIRED_SYNC, REPLICA, DB, DB_REPLICA (see the script).
function New-StatusRequest { param($Node) @{ Node = $Node; Label = 'AG status'; Body = (Get-ScriptBody 'ag-08-status.sh' @($Node.Sa, $AgName)) } }

# ag-09-failover-step.sh <step> [arg] on one node.
function Invoke-AgStep {
    param($Node, [string]$Step, [string]$Arg = '', [switch]$AllowFail)
    $a = @($Node.Sa, $AgName, $Step); if ($Arg) { $a += $Arg }
    $r = @(Invoke-VmBatch @(@{ Node = $Node; Label = $Step; Body = (Get-ScriptBody 'ag-09-failover-step.sh' $a) }))[0]
    if (-not $AllowFail) { Assert-Ok $r }
    foreach ($k in @('MADE_SYNC', 'PROMOTED', 'DEMOTED', 'DEMOTE_SKIPPED', 'RESUMED', 'RESUME_FAILED', 'REQUIRED_SYNC', 'REMOVED_REPLICA')) {
        foreach ($v in (Get-Vals $r $k)) { Write-Host "    $k = $v" }
    }
    return $r
}

# ── Topology ───────────────────────────────────────────────────────────────────
# One node of the stack: VM, NIC IP, NSG and its failure domain (availability zone, fault domain of the
# availability set, or the host itself).
function New-UcNode {
    param([string]$Suffix)
    $prefix = "$Prefix-$Identifier"
    $vm = "$prefix-$Suffix-vm"
    $info = az vm show -g $StackRg -n $vm --query '{l:location, z:zones[0], a:availabilitySet.id}' -o json 2>$null | ConvertFrom-Json
    if (-not $info) { Write-Error "VM $vm not found in $StackRg."; exit 1 }
    $ip = az network nic show -g $StackRg -n "$prefix-$Suffix-nic" --query 'ipConfigurations[0].privateIPAddress' -o tsv 2>$null
    if ($info.z) {
        $domain = @{ id = "zone-$($info.z)"; label = "Zone $($info.z)"; sub = $info.l; kind = 'zone' }
    } elseif ($info.a) {
        $fd = az vm get-instance-view -g $StackRg -n $vm --query 'instanceView.platformFaultDomain' -o tsv 2>$null
        $domain = @{ id = "fd-$fd"; label = "Fault domain $fd"; sub = $info.l; kind = 'fault-domain' }
    } else {
        $domain = @{ id = "host-$Suffix"; label = "Host $Suffix"; sub = $info.l; kind = 'host' }
    }
    return [pscustomobject]@{
        Suffix = $Suffix; Name = "$prefix-$Suffix"; Vm = $vm; Rg = $StackRg; Nsg = "$prefix-$Suffix-nsg"
        Region = $info.l; Zone = "$($info.z)"; Domain = $domain; PrivateIp = $ip; Sa = $script:StackSa; Power = 'unknown'
    }
}

function Get-PowerState {
    param($Node)
    $state = az vm get-instance-view -g $Node.Rg -n $Node.Vm `
        --query "instanceView.statuses[?starts_with(code, 'PowerState/')].code | [0]" -o tsv 2>$null
    if (-not $state) { return 'unknown' }
    return ($state -replace '^PowerState/', '')
}

function Update-PowerStates { foreach ($n in $AllNodes) { $n.Power = Get-PowerState $n } }

function Start-UcVms {
    param([object[]]$Nodes)
    foreach ($n in $Nodes) { Write-Host "  Starting $($n.Vm) ..."; az vm start -g $n.Rg -n $n.Vm --no-wait -o none }
    foreach ($n in $Nodes) {
        az vm wait -g $n.Rg -n $n.Vm --custom "instanceView.statuses[?code=='PowerState/running']" --timeout 900 -o none 2>$null
        if ((Get-PowerState $n) -ne 'running') { Write-Error "$($n.Vm) did not start."; exit 1 }
        $n.Power = 'running'
        Write-Host "  $($n.Vm) running."
    }
}

# ag-08-status.sh on every running node; returns @{ <vm> = result }.
function Get-StatusAll {
    param([object[]]$Nodes)
    $running = @($Nodes | Where-Object { $_.Power -eq 'running' })
    $result = @{}
    if ($running.Count -eq 0) { return $result }
    $batch = @(Invoke-VmBatch @($running | ForEach-Object { New-StatusRequest $_ }))
    foreach ($r in $batch) { $result[$r.Vm] = $r }
    return $result
}

# PRIMARY / SECONDARY / RESOLVING / NONE, or SQL-DOWN / UNREACHABLE / <power state>.
function Get-UcRole {
    param($Node, $Result)
    if ($Node.Power -ne 'running') { return $Node.Power.ToUpper() }
    if (-not $Result -or $Result.Exit -ne 0) { return 'UNREACHABLE' }
    if ((Get-Val $Result 'SQL_UP') -ne '1') { return 'SQL-DOWN' }
    $role = Get-Val $Result 'LOCAL_ROLE'
    if ($role) { return $role }
    return 'NONE'
}

function Show-NodeStatus {
    param($Node, $Result)
    Write-Host ''
    Write-Host ("  {0} ({1}, {2}) - VM {3} - AG role {4}" -f $Node.Name, $Node.Domain.label, $Node.Region, $Node.Power, (Get-UcRole $Node $Result)) -ForegroundColor White
    if (-not $Result) { return }
    foreach ($k in @('REQUIRED_SYNC', 'REPLICA', 'DB', 'DB_REPLICA')) {
        foreach ($v in (Get-Vals $Result $k)) { Write-Host ("    {0,-13} {1}" -f $k, $v) }
    }
}

function Get-OtherNode { param($Node) if ($Node.Vm -eq $NodeA.Vm) { $NodeB } else { $NodeA } }

# Sets $Pri / $Sec: from the open drill run (the roles when it started), or from the live AG.
function Resolve-UcRoles {
    param([switch]$Live)
    $pre = if (-not $Live) { Read-Evidence 'precheck' } else { $null }
    if ($pre -and $pre.primary) {
        $script:Pri = if ($pre.primary -eq $NodeA.Name) { $NodeA } else { $NodeB }
        $script:Sec = Get-OtherNode $script:Pri
        return
    }
    Update-PowerStates
    $st = Get-StatusAll $AllNodes
    $primaries = @($AllNodes | Where-Object { (Get-UcRole $_ $st[$_.Vm]) -eq 'PRIMARY' })
    if ($primaries.Count -ne 1) {
        foreach ($n in $AllNodes) { Show-NodeStatus $n $st[$n.Vm] }
        Write-Error "Expected exactly one PRIMARY replica, found $($primaries.Count). Fix the AG first (../../sqlvm-linux-ag.ps1 -Action status-ag / reinstate)."
        exit 1
    }
    $script:Pri = $primaries[0]
    $script:Sec = Get-OtherNode $script:Pri
}

# Opens the dashboard session of this process: topology (merged by the dashboard - a later session,
# e.g. reinstate, keeps the roles/links the previous actions left) + 'action started'.
function Start-UcSession {
    if ($script:UcSessionStarted -or -not $script:RunId) { return }
    $script:UcSessionStarted = $true
    # A use case that takes the primary down sets $UcFailsPrimary before dot-sourcing this file.
    $script:FailedDomain = if ((Get-Variable UcFailsPrimary -ValueOnly -ErrorAction SilentlyContinue)) { $Pri.Domain.id } else { '' }
    $nodes = @($AllNodes | ForEach-Object {
        $isPri = $_.Vm -eq $Pri.Vm
        @{ id = $_.Name; label = $_.Suffix; name = $_.Name; vm = $_.Vm; rg = $_.Rg; region = $_.Domain.id; ip = $_.PrivateIp
           group = $AgName; stack = $Identifier; role = $(if ($isPri) { 'PRIMARY' } else { 'SECONDARY' }); global = $isPri }
    })
    $domains = @($AllNodes | ForEach-Object { $_.Domain } | Group-Object { $_.id } | ForEach-Object { $_.Group[0] })
    $links = @(@{ id = "ag-$AgName"; kind = 'ag'; from = $Pri.Name; to = $Sec.Name; label = 'AG (sync)'; state = 'healthy' })
    $params = @{ region = $Pri.Region; primary = $Pri.Suffix; secondary = $Sec.Suffix; ag = $AgName
                 primaryDomain = $Pri.Domain.label; secondaryDomain = $Sec.Domain.label; failedDomain = $script:FailedDomain }
    foreach ($k in $script:UcSessionParams.Keys) { $params[$k] = $script:UcSessionParams[$k] }
    Write-UcTopology -UseCase $UcId -Nodes $nodes -Groups @(@{ id = $AgName; label = 'AG'; kind = 'global' }) -Links $links -Regions $domains -Params $params
    Set-UcAction -Action $Action -Status started
}

# ── Application writer (the workload) ──────────────────────────────────────────
# A stand-in for the application: a loop on the SECONDARY's VM (it survives the primary's failure)
# that commits one ledger row every ~0.2 s to whichever node accepts it. It tries the last node that
# worked and, on any error (offline, read-only secondary, node down), switches to the other one -
# exactly what an application with two server addresses does. Every attempt is logged with its time:
#   <epoch ms> ok <seq> <ip> <ms>  |  <epoch ms> fail <seq> <ip>
# The log gives the application's view: throughput, failed attempts and the write interruption.
# A row is only acknowledged (seq advances) when the commit returned, so 'acknowledged seq N' + the
# ledger on the primary measure the transactions lost (RPO).
function Start-UcWriter {
    param($AppHost, [int]$Seconds, [string]$LedgerRun = $script:RunId)
    $body = @'
cat > /var/tmp/__TAG__-writer.sh <<'WRITER'
#!/bin/bash
# Ledger writer: RUN_ID DB DURATION IP_1 IP_2 LOG. SQLCMDPASSWORD comes from the environment.
RUN_ID="$1"; DB="$2"; DURATION="$3"; IPS=("$4" "$5"); LOG="$6"
cur=0; seq=0; end=$((SECONDS + DURATION))
while [ "$SECONDS" -lt "$end" ]; do
  n=$((seq + 1)); ip="${IPS[$cur]}"; t0=$(date +%s%3N)
  if /opt/mssql-tools18/bin/sqlcmd -S "$ip" -U SA -No -C -b -l 2 -t 10 -d "$DB" \
       -Q "SET NOCOUNT ON; IF NOT EXISTS (SELECT 1 FROM dbo.UC_Tx WHERE run_id = '$RUN_ID' AND seq = $n) INSERT dbo.UC_Tx (run_id, seq, host_ip) VALUES ('$RUN_ID', $n, '$ip');" >/dev/null 2>&1; then
    t1=$(date +%s%3N); seq=$n
    echo "$t1 ok $n $ip $((t1 - t0))" >> "$LOG"
    sleep 0.2
  else
    echo "$(date +%s%3N) fail $n $ip" >> "$LOG"
    cur=$((1 - cur))
    sleep 0.3
  fi
done
WRITER
chmod 700 /var/tmp/__TAG__-writer.sh
pkill -f /var/tmp/__TAG__-writer.sh || true
rm -f /var/tmp/__TAG__-writer.log
nohup setsid /var/tmp/__TAG__-writer.sh '__RUN_ID__' '__DB__' '__SECONDS__' '__IP1__' '__IP2__' /var/tmp/__TAG__-writer.log >/dev/null 2>&1 < /dev/null &
sleep 6
echo "WRITER_PID=$(pgrep -f /var/tmp/__TAG__-writer.sh | head -1)"
echo "WRITER_OK=$(grep -c ' ok ' /var/tmp/__TAG__-writer.log || true)"
echo "WRITER_START=$(head -1 /var/tmp/__TAG__-writer.log | cut -d' ' -f1)"
'@
    # The current primary first: the writer starts where the application would.
    $body = $body.Replace('__TAG__', $UcTag).Replace('__RUN_ID__', $LedgerRun).Replace('__DB__', $DemoDbName).Replace('__SECONDS__', "$Seconds").
        Replace('__IP1__', $Pri.PrivateIp).Replace('__IP2__', $Sec.PrivateIp)
    $r = @(Invoke-VmBatch @(@{ Node = $AppHost; Label = 'start the application writer'; Body = $body }))[0]
    Assert-Ok $r
    $ok = [int](Get-Val $r 'WRITER_OK')
    if (-not (Get-Val $r 'WRITER_PID') -or $ok -le 0) { Write-Error "The writer didn't start committing (ok=$ok)."; exit 1 }
    $start = Get-Val $r 'WRITER_START'
    $script:MonitorCursor = if ($start) { [int64]([int64]$start / 1000) - 1 } else { [DateTimeOffset]::UtcNow.ToUnixTimeSeconds() - 7 }
    return $ok
}

function Stop-UcWriter {
    param($AppHost)
    $r = @(Invoke-VmBatch @(@{ Node = $AppHost; Label = 'stop the writer'; Body = "pkill -f /var/tmp/$UcTag-writer.sh || true`necho WRITER_STOPPED=1" }))[0]
    return ($r.Exit -eq 0)
}

# One monitoring poll on the application host: per-second commits / failed attempts since the last
# poll (from the writer's log), the last acknowledged commit, and the replication queues as seen by
# whichever node is primary. Emits dashboard samples; returns the parsed result.
function Update-UcMonitor {
    param($AppHost, [switch]$Quiet)
    $since = if ($null -ne $script:MonitorCursor) { $script:MonitorCursor } else { [DateTimeOffset]::UtcNow.ToUnixTimeSeconds() - 30 }
    $body = @'
LOG=/var/tmp/__TAG__-writer.log; SINCE=__SINCE__; NOW=$(date +%s)
echo "W_NOW=$NOW"
if pgrep -f /var/tmp/__TAG__-writer.sh >/dev/null; then echo "W_RUNNING=1"; else echo "W_RUNNING=0"; fi
if [ -f "$LOG" ]; then
  awk -v s="$SINCE" -v e="$NOW" '
    { t = int($1 / 1000) }
    $2 == "ok"   { lastok = $1; lastseq = $3; lastip = $4; tot++; if (t > s && t < e) ok[t]++; if ($5 > slow[t]) slow[t] = $5 }
    $2 == "fail" { fails++; if (t > s && t < e) fl[t]++ }
    END {
      span = e - 1 - s; step = 1; if (span > 100) step = int((span + 99) / 100)
      for (b = s + 1; b < e; b += step) {
        o = 0; f = 0; m = 0
        for (x = b; x < b + step && x < e; x++) { o += ok[x]; f += fl[x]; if (slow[x] > m) m = slow[x] }
        printf "S=%d|%.2f|%.2f|%d\n", b, o / step, f / step, m
      }
      printf "W_LAST_OK=%s|%s|%s\n", lastok, lastseq, lastip
      printf "W_TOTAL=%d|%d\n", tot, fails
    }' "$LOG"
fi
for ip in __IPS__; do
  out=$(/opt/mssql-tools18/bin/sqlcmd -S "$ip" -U SA -No -C -W -h -1 -l 2 -t 5 -Q "SET NOCOUNT ON; SELECT 'Q=' + ar.replica_server_name + '|' + CAST(SUM(ISNULL(drs.log_send_queue_size, 0)) AS varchar(20)) + '|' + CAST(SUM(ISNULL(drs.redo_queue_size, 0)) AS varchar(20)) + '|' + CAST(SUM(CASE WHEN drs.synchronization_state_desc = 'SYNCHRONIZED' THEN 1 ELSE 0 END) AS varchar(10)) + '/' + CAST(COUNT(*) AS varchar(10)) FROM sys.dm_hadr_database_replica_states drs JOIN sys.availability_replicas ar ON ar.replica_id = drs.replica_id WHERE drs.is_local = 0 GROUP BY ar.replica_server_name" 2>/dev/null | grep '^Q=' || true)
  if [ -n "$out" ]; then echo "$out"; echo "Q_FROM=$ip"; break; fi
done
'@
    $body = $body.Replace('__TAG__', $UcTag).Replace('__SINCE__', "$since").Replace('__IPS__', "$($NodeA.PrivateIp) $($NodeB.PrivateIp)")
    $r = @(Invoke-VmBatch @(@{ Node = $AppHost; Label = 'monitor'; Body = $body }) -Quiet:$Quiet)[0]
    if ($r.Exit -ne 0) { return $r }
    $last = 0
    foreach ($s in (Get-Vals $r 'S')) {
        $p = $s.Split('|')
        $t = [DateTimeOffset]::FromUnixTimeSeconds([int64]$p[0]).UtcDateTime
        Set-UcSample -Data ([ordered]@{ txPerSec = [double]$p[1]; failPerSec = [double]$p[2]; slowCommitMs = [double]$p[3] }) -At $t -Detail 'writer'
        $last = [int64]$p[0]
    }
    $now = Get-Val $r 'W_NOW'
    if ($now) { $script:MonitorCursor = [math]::Max($last, [int64]$now - 1) }
    $q = @(Get-Vals $r 'Q')
    if ($q.Count) {
        $p = $q[0].Split('|')
        $sendKB = [double]$p[1]; $redoKB = [double]$p[2]
        Set-UcSample -Data ([ordered]@{ sendQueueKB = $sendKB; redoQueueKB = $redoKB }) -Detail 'queues'
        Set-UcLink -Link "ag-$AgName" -State $(if ($p[3] -match '^(\d+)/\1$') { 'synchronized' } else { 'synchronizing' }) -Note "send $sendKB KB · redo $redoKB KB" -Quiet
    }
    if (-not $Quiet) {
        $lo = Get-Val $r 'W_LAST_OK'; $tot = Get-Val $r 'W_TOTAL'
        Write-Host "  writer: last commit $lo | ok|failed $tot$(if ($q.Count) { " | queues $($q -join ', ')" })" -ForegroundColor DarkGray
    }
    return $r
}

# Keeps sampling for $Seconds (a poll every ~$Every s - each Run Command round trip takes 10-30 s).
function Invoke-UcObserve {
    param($AppHost, [int]$Seconds, [int]$Every = 10)
    $end = (Get-UtcNow).AddSeconds($Seconds)
    while ((Get-UtcNow) -lt $end) {
        Update-UcMonitor $AppHost | Out-Null
        $left = ($end - (Get-UtcNow)).TotalSeconds
        if ($left -gt 1) { Start-Sleep ([math]::Min($Every, [int]$left)) }
    }
}

# The writer's view around an event at $AtMs: the last acknowledged commit before it, the first one after
# it (and on which node), the longest gap between two commits after $AtMs - 60 s, and the totals.
# -TargetIp: AFTER is the first commit after $AtMs on THAT node, and BEFORE the last commit before it (on
# any node) - so a commit that was in flight on the old primary when it went offline doesn't count as the
# reconnect, and the gap BEFORE -> AFTER is exactly the interruption the application saw.
function Get-WriterTimeline {
    param($AppHost, [int64]$AtMs, [string]$TargetIp = '')
    $body = @'
LOG=/var/tmp/__TAG__-writer.log
[ -f "$LOG" ] || { echo "NO_LOG=1"; exit 0; }
awk -v at="__AT__" -v tip="__TIP__" '
  $2 == "ok" {
    if (!after && $1 > at && (tip == "" || $4 == tip)) { after = $1; afterSeq = $3; afterIp = $4 }
    else if (!after && (tip != "" || $1 <= at)) { before = $1; beforeSeq = $3; beforeIp = $4 }
    if (prev && $1 > at - 60000 && $1 - prev > gap) { gap = $1 - prev; gapFrom = prev; gapTo = $1 }
    prev = $1; lastSeq = $3; lastIp = $4; ok++
  }
  $2 == "fail" { if ($1 > at) failAfter++; fails++ }
  END {
    printf "BEFORE=%s|%s|%s\n", before, beforeSeq, beforeIp
    printf "AFTER=%s|%s|%s\n", after, afterSeq, afterIp
    printf "GAP=%s|%s|%s\n", gap, gapFrom, gapTo
    printf "LAST=%s|%s\n", lastSeq, lastIp
    printf "TOTALS=%d|%d|%d\n", ok, fails, failAfter
  }' "$LOG"
'@
    $r = @(Invoke-VmBatch @(@{ Node = $AppHost; Label = 'writer timeline'; Body = $body.Replace('__TAG__', $UcTag).Replace('__AT__', "$AtMs").Replace('__TIP__', $TargetIp) }) -Quiet)[0]
    Assert-Ok $r
    $split = { param($k) "$(Get-Val $r $k)".Split('|') }
    $before = & $split 'BEFORE'; $after = & $split 'AFTER'; $gap = & $split 'GAP'; $last = & $split 'LAST'; $tot = & $split 'TOTALS'
    return [pscustomobject]@{
        BeforeMs = $(if ($before[0]) { [int64]$before[0] }); BeforeSeq = $(if ($before[1]) { [int64]$before[1] }); BeforeIp = $before[2]
        AfterMs  = $(if ($after[0])  { [int64]$after[0] });  AfterSeq  = $(if ($after[1])  { [int64]$after[1] });  AfterIp  = $after[2]
        GapMs    = $(if ($gap[0])    { [int64]$gap[0] });    GapFromMs = $(if ($gap[1])    { [int64]$gap[1] });    GapToMs  = $(if ($gap[2]) { [int64]$gap[2] })
        LastSeq  = $(if ($last[0])   { [int64]$last[0] });   LastIp    = $last[1]
        Ok = [int]$tot[0]; Failed = [int]$tot[1]; FailedAfter = [int]$tot[2]
    }
}

# Waits until the writer has committed on $Target after $AtMs. Returns the timeline (AfterMs = the first
# commit there) or $null at timeout.
function Wait-WriterOn {
    param($AppHost, $Target, [int64]$AtMs, [int]$TimeoutSeconds = 180)
    $deadline = (Get-UtcNow).AddSeconds($TimeoutSeconds)
    while ($true) {
        Update-UcMonitor $AppHost -Quiet | Out-Null
        $tl = Get-WriterTimeline $AppHost $AtMs -TargetIp $Target.PrivateIp
        if ($tl.AfterMs) { return $tl }
        Write-Host "  waiting for the application's first commit on $($Target.Name) ..." -ForegroundColor DarkGray
        if ((Get-UtcNow) -gt $deadline) { return $null }
        Start-Sleep 5
    }
}

# Ledger on a node (the primary, or a fenced old primary): rows of this run, rows up to the writer's
# acknowledged seq, and the newest row a given node (host IP) committed.
function Get-UcLedger {
    param($Node, [int64]$UpTo = 0, [string]$HostIp = '', [string]$LedgerRun = (Get-RunIdOrNone), [switch]$AllowFail)
    $r = Invoke-Sql -Node $Node -File '40-ledger-check.sql' -Label 'ledger' -AllowFail:$AllowFail `
        -Vars @{ DbName = $DemoDbName; RunId = $LedgerRun; UpTo = $UpTo; HostIp = $(if ($HostIp) { $HostIp } else { '-' }) }
    $l = "$(Get-Val $r 'LEDGER')".Split('|'); $h = "$(Get-Val $r 'LEDGER_HOST')".Split('|')
    return [pscustomobject]@{
        Ok = ($r.Exit -eq 0 -and [bool](Get-Val $r 'LEDGER')); Rows = $(if ($l[0]) { [int64]$l[0] }); MaxSeq = $(if ($l[1]) { [int64]$l[1] })
        RowsUpTo = $(if (Get-Val $r 'LEDGER_UPTO') { [int64](Get-Val $r 'LEDGER_UPTO') }); HostRows = $(if ($h[0]) { [int64]$h[0] }); HostMaxSeq = $(if ($h[1]) { [int64]$h[1] })
        Raw = $r.Stdout
    }
}

# ── Synchronization / planned role swap ────────────────────────────────────────
# Polls $Primary until every AG database is SYNCHRONIZED on $Target (DB_REPLICA rows of ag-08-status.sh).
# A database left suspended on $Target (a role change suspends it "from partner", sometimes seconds
# later) is resumed there, so the wait can't hang on it.
function Wait-UcSynchronized {
    param($Primary, $Target, [int]$TimeoutMinutes = 10, $AppHost = $null)
    $deadline = (Get-UtcNow).AddMinutes($TimeoutMinutes)
    while ($true) {
        $s = @(Invoke-VmBatch @(New-StatusRequest $Primary) -Quiet)[0]
        $dbs  = @(Get-Vals $s 'DB' | Where-Object { $_ -notmatch '\|NOT_IN_AG\|' })
        $rows = @(Get-Vals $s 'DB_REPLICA' | Where-Object { $_.Split('|')[1] -eq $Target.Name })
        $sync = @($rows | Where-Object { $_.Split('|')[2] -eq 'SYNCHRONIZED' })
        Write-Host "  $($Target.Name): $($sync.Count)/$($dbs.Count) database(s) SYNCHRONIZED"
        if ($dbs.Count -gt 0 -and $sync.Count -eq $dbs.Count) { return $true }
        if (@($rows | Where-Object { $_ -match 'suspended=1' }).Count) {
            Write-Host "  $($Target.Name) has suspended database(s) - resuming them there." -ForegroundColor Yellow
            Invoke-AgStep $Target 'resume' -AllowFail | Out-Null
            Add-Event 'resumed-suspended' "$($Target.Name): data movement resumed (databases were suspended)" -Level 'warn'
        }
        if ((Get-UtcNow) -gt $deadline) { return $false }
        if ($AppHost) { Update-UcMonitor $AppHost -Quiet | Out-Null } else { Start-Sleep 10 }
    }
}

$ResumeSql = @'
SET NOCOUNT ON;
DECLARE @db sysname, @sql nvarchar(400);
DECLARE c CURSOR LOCAL FAST_FORWARD FOR
  SELECT d.name FROM sys.dm_hadr_database_replica_states drs
  JOIN sys.databases d ON d.database_id = drs.database_id
  WHERE drs.is_local = 1 AND drs.is_suspended = 1;
OPEN c; FETCH NEXT FROM c INTO @db;
WHILE @@FETCH_STATUS = 0
BEGIN
  SET @sql = N'ALTER DATABASE ' + QUOTENAME(@db) + N' SET HADR RESUME;';
  BEGIN TRY EXEC (@sql); SELECT 'RESUMED=' + @@SERVERNAME + '|' + @db; END TRY
  BEGIN CATCH SELECT 'RESUME_FAILED=' + @@SERVERNAME + '|' + @db + '|' + LEFT(ERROR_MESSAGE(), 150); END CATCH
  FETCH NEXT FROM c INTO @db;
END
CLOSE c; DEALLOCATE c;
'@

# Planned failover without data loss, Microsoft's procedure for CLUSTER_TYPE = NONE, in two Run Command
# calls so that the write interruption is seconds, not Run Command round trips:
#   1. $From: both replicas SYNCHRONOUS_COMMIT + REQUIRED_SYNCHRONIZED_SECONDARIES_TO_COMMIT = 1, then
#      wait until $To reports every database SYNCHRONIZED;
#   2. one body on $From: re-check SYNCHRONIZED, AG OFFLINE, promote $To over the VNet (sqlcmd to its
#      private IP), demote $From, resume both, commit gate back to 0. If the promotion fails, $From
#      takes the primary role back.
# $Phases: @{ sync; offline; promote; demote } = the dashboard phase ids. Returns the step times.
function Invoke-UcPlannedSwap {
    param($From, $To, [hashtable]$Phases, $AppHost = $null)
    Set-UcPhase $Phases.sync running "both replicas synchronous, commits wait for $($To.Name)"
    Invoke-AgStep $From 'prepare' | Out-Null
    if (-not (Wait-UcSynchronized -Primary $From -Target $To -TimeoutMinutes 10 -AppHost $AppHost)) {
        Invoke-AgStep $From 'commit-gate' '0' -AllowFail | Out-Null
        Set-UcPhase $Phases.sync failed "$($To.Name) not SYNCHRONIZED within 10 min - nothing changed"
        Write-Error "$($To.Name) did not reach SYNCHRONIZED - swap cancelled, $($From.Name) stays PRIMARY."
        exit 1
    }
    Set-UcLink -Link "ag-$AgName" -State 'synchronized'
    Set-UcPhase $Phases.sync done "$($To.Name) SYNCHRONIZED"

    $body = @'
TARGET_IP='__TARGET_IP__'; TARGET='__TARGET__'; AG='__AG__'
RSQL() { /opt/mssql-tools18/bin/sqlcmd -S "$TARGET_IP" -U SA -No -C -b -W -h -1 -l 5 "$@"; }
now() { date +%s%3N; }
cat > /tmp/__TAG__-resume.sql <<'UCSQL'
__RESUME__
UCSQL
NOT=$(SQL -Q "SET NOCOUNT ON; SELECT COUNT(*) FROM sys.dm_hadr_database_replica_states drs JOIN sys.availability_replicas ar ON ar.replica_id = drs.replica_id JOIN sys.availability_groups ag ON ag.group_id = drs.group_id WHERE ag.name = N'$AG' AND ar.replica_server_name = N'$TARGET' AND drs.synchronization_state_desc <> 'SYNCHRONIZED'" | tr -d '[:space:]')
if [ "$NOT" != "0" ]; then echo "SWAP_ABORTED=$NOT database(s) not SYNCHRONIZED on $TARGET"; exit 3; fi
echo "T_OFFLINE=$(now)"
SQL -Q "ALTER AVAILABILITY GROUP [$AG] OFFLINE;"
if RSQL -Q "ALTER AVAILABILITY GROUP [$AG] FORCE_FAILOVER_ALLOW_DATA_LOSS;"; then
  echo "T_PROMOTED=$(now)"
else
  echo "PROMOTE_FAILED=1"
  SQL -Q "ALTER AVAILABILITY GROUP [$AG] FORCE_FAILOVER_ALLOW_DATA_LOSS;" && echo "ROLLED_BACK=1"
  SQL -Q "ALTER AVAILABILITY GROUP [$AG] SET (REQUIRED_SYNCHRONIZED_SECONDARIES_TO_COMMIT = 0);" || true
  exit 4
fi
SQL -Q "ALTER AVAILABILITY GROUP [$AG] SET (ROLE = SECONDARY);"
echo "T_DEMOTED=$(now)"
RSQL -i /tmp/__TAG__-resume.sql || true
RSQL -Q "ALTER AVAILABILITY GROUP [$AG] SET (REQUIRED_SYNCHRONIZED_SECONDARIES_TO_COMMIT = 0);"
echo "T_DONE=$(now)"
# The demoted node's databases are suspended ("from partner") by SQL Server itself, asynchronously - up to
# a few seconds AFTER the role change. Resume until every local AG database is SYNCHRONIZING/SYNCHRONIZED.
EXPECTED=$(SQL -Q "SET NOCOUNT ON; SELECT COUNT(*) FROM sys.availability_databases_cluster adc JOIN sys.availability_groups ag ON ag.group_id = adc.group_id WHERE ag.name = N'$AG'" | tr -d '[:space:]')
for i in $(seq 1 45); do
  SQL -i /tmp/__TAG__-resume.sql || true
  MOVING=$(SQL -Q "SET NOCOUNT ON; SELECT COUNT(*) FROM sys.dm_hadr_database_replica_states WHERE is_local = 1 AND is_suspended = 0 AND synchronization_state_desc IN ('SYNCHRONIZING', 'SYNCHRONIZED')" | tr -d '[:space:]')
  if [ "$MOVING" = "$EXPECTED" ] && [ "$i" -ge 3 ]; then echo "RESUME_SETTLED=$i"; break; fi
  sleep 2
done
[ "$MOVING" = "$EXPECTED" ] || echo "RESUME_PENDING=$MOVING/$EXPECTED database(s) moving on the old primary"
'@
    $body = $body.Replace('__RESUME__', $ResumeSql).Replace('__TARGET_IP__', $To.PrivateIp).Replace('__TARGET__', $To.Name).Replace('__AG__', $AgName).Replace('__TAG__', $UcTag)
    Set-UcPhase $Phases.offline running "AG offline on $($From.Name): writes stop"
    $r = @(Invoke-VmBatch @(@{ Node = $From; Label = 'role swap (offline, promote, demote, resume)'; Body = $body }))[0]
    foreach ($k in @('SWAP_ABORTED', 'PROMOTE_FAILED', 'ROLLED_BACK', 'RESUMED', 'RESUME_FAILED', 'RESUME_SETTLED', 'RESUME_PENDING')) { foreach ($v in (Get-Vals $r $k)) { Write-Host "    $k = $v" } }
    $t = @{}
    foreach ($k in @('T_OFFLINE', 'T_PROMOTED', 'T_DEMOTED', 'T_DONE')) { $v = Get-Val $r $k; if ($v) { $t[$k] = ConvertFrom-EpochMs $v } }
    if ($r.Exit -ne 0) {
        $why = if (Get-Val $r 'SWAP_ABORTED') { "aborted: $(Get-Val $r 'SWAP_ABORTED')" } elseif (Get-Val $r 'ROLLED_BACK') { "promotion of $($To.Name) failed - $($From.Name) took the primary role back" } else { $r.Stderr }
        Set-UcPhase $Phases.offline failed $why
        if ($r.Stderr) { Write-Host $r.Stderr -ForegroundColor Red }
        Write-Error "Role swap failed: $why"
        exit 1
    }
    Set-UcPhase $Phases.offline done "AG offline on $($From.Name)" -At $t.T_OFFLINE
    Set-UcPhase $Phases.promote running "$($To.Name): FORCE_FAILOVER_ALLOW_DATA_LOSS (no loss: SYNCHRONIZED, old primary offline)" -At $t.T_OFFLINE
    Set-UcPhase $Phases.promote done "$($To.Name) is PRIMARY" -At $t.T_PROMOTED
    Set-UcNode -Node $To.Name -Role 'PRIMARY' -Global $true
    Set-UcNode -Node $From.Name -Role 'SECONDARY' -Global $false
    Set-UcLink -Link "ag-$AgName" -From $To.Name -To $From.Name -State 'synchronizing'
    Set-UcPhase $Phases.demote running "$($From.Name) -> SECONDARY, data movement resumed" -At $t.T_PROMOTED
    Set-UcPhase $Phases.demote done "$($From.Name) is SECONDARY; commit gate back to 0" -At $t.T_DONE
    return $t
}

# ── Drill steps shared by the use cases ────────────────────────────────────────
# The node the application writer runs on (the secondary when the workload started - it survives the
# primary's failure), and the ledger run it writes to.
function Get-AppHost {
    $w = Read-Evidence 'workload'
    if ($w -and $w.appHost) { return $(if ($w.appHost -eq $NodeA.Name) { $NodeA } else { $NodeB }) }
    return $Sec
}
function Get-LedgerRun { $w = Read-Evidence 'workload'; if ($w -and $w.ledgerRun) { "$($w.ledgerRun)" } else { Get-RunIdOrNone } }

function Invoke-UcStartWorkload {
    param([string]$Phase = 'workload', [string]$LedgerRun = $script:RunId, [string]$Evidence = 'workload')
    Assert-Run
    $appHost = $Sec
    Write-Step "Starting the application writer on $($appHost.Name) (commits to $($Pri.Name), follows the primary)"
    Set-UcPhase $Phase running
    $ok = Start-UcWriter -AppHost $appHost -Seconds $WorkloadSeconds -LedgerRun $LedgerRun
    Save-Evidence $Evidence ([ordered]@{ appHost = $appHost.Name; ledgerRun = $LedgerRun; startedUtc = (Format-Utc (Get-UtcNow)); seconds = $WorkloadSeconds })
    Add-Event 'workload-started' "$ok commit(s) in the first 6 s, ledger run $LedgerRun"
    Set-UcPhase $Phase done "~5 commits/s from $($appHost.Name) to $($Pri.Name) (both private IPs known, switches on error)"
    Write-Host "  Writer running on $($appHost.Name): $ok commits in 6 s, lifetime $WorkloadSeconds s." -ForegroundColor Green
}

function Invoke-UcWarmup {
    param([int]$Seconds)
    Write-Host "  Warm-up: $Seconds s of commits before anything changes ..."
    Set-UcPhase warmup running "$Seconds s of commits, sampled for the charts"
    Invoke-UcObserve -AppHost (Get-AppHost) -Seconds $Seconds
    Set-UcPhase warmup done
}

function Invoke-UcStopWorkload {
    $appHost = Get-AppHost
    Write-Step "Stopping the application writer on $($appHost.Name)"
    Update-UcMonitor $appHost | Out-Null
    if (Stop-UcWriter $appHost) { Add-Event 'workload-stopped'; Write-Host '  Writer stopped.' -ForegroundColor Green }
}

# Planned failover $From -> $To (Invoke-UcPlannedSwap), then waits for the application's first commit on
# $To. $Phases: @{ sync; offline; promote; demote; reconnect }. $Clock: the dashboard clock that runs from
# the AG going offline to that first commit. Metrics are prefixed with $MetricPrefix (e.g. 'failback':
# failbackRto). Returns @{ Swap = step times; Timeline = writer view; OfflineMs }.
function Invoke-UcPlannedFailover {
    param($From, $To, [hashtable]$Phases, [string]$Clock, [string]$MetricPrefix = '')
    $id = { param($n) if ($MetricPrefix) { $MetricPrefix + $n.Substring(0, 1).ToUpper() + $n.Substring(1) } else { $n } }
    $appHost = Get-AppHost
    $t = Invoke-UcPlannedSwap -From $From -To $To -Phases $Phases -AppHost $appHost
    $offlineMs = ConvertTo-EpochMs $t.T_OFFLINE
    Set-UcClock $Clock start -At $t.T_OFFLINE -Detail "AG offline on $($From.Name): writes stop"
    Set-UcMetric (& $id 'swapSeconds') ([math]::Round(($t.T_DONE - $t.T_OFFLINE).TotalSeconds, 1)) 's' `
        -Detail "offline -> promoted $([math]::Round(($t.T_PROMOTED - $t.T_OFFLINE).TotalSeconds, 1)) s -> demoted + resumed $([math]::Round(($t.T_DONE - $t.T_PROMOTED).TotalSeconds, 1)) s"

    # The application reconnects by itself: its next attempt on $To succeeds.
    Set-UcPhase $Phases.reconnect running "the application retries until $($To.Name) accepts its commits" -At $t.T_DONE
    $tl = Wait-WriterOn -AppHost $appHost -Target $To -AtMs $offlineMs -TimeoutSeconds 180
    if (-not $tl) {
        Set-UcPhase $Phases.reconnect failed "no commit on $($To.Name) within 3 min (writer running? -Action start-workload)"
        Set-UcMetric (& $id 'appReconnected') $false
        Write-Host "  The application didn't commit on $($To.Name) within 3 min - is the writer running?" -ForegroundColor Yellow
        return @{ Swap = $t; Timeline = $null; OfflineMs = $offlineMs }
    }
    $first = ConvertFrom-EpochMs $tl.AfterMs
    Set-UcClock $Clock stop -At $first -Detail "first commit on $($To.Name)"
    $gap = if ($tl.BeforeMs) { [math]::Round(($tl.AfterMs - $tl.BeforeMs) / 1000, 1) } else { $null }
    $lastOn = if ($tl.BeforeMs) { (ConvertFrom-EpochMs $tl.BeforeMs).ToString('HH:mm:ss.fff') } else { 'n/a' }
    Set-UcMetric (& $id 'rto') $gap 's' -Detail "application view: last commit on $($From.Name) at $lastOn, first on $($To.Name) at $($first.ToString('HH:mm:ss.fff')) UTC; $($tl.FailedAfter) failed attempt(s) in between"
    Set-UcMetric (& $id 'appReconnected') $true -Detail "first commit on $($To.Name) (seq $($tl.AfterSeq)) without any change to the application"
    Set-UcPhase $Phases.reconnect done "first commit on $($To.Name) $gap s after the last one on $($From.Name)" -At $first
    Write-Host "  Write interruption seen by the application: $gap s ($($tl.FailedAfter) failed attempt(s))." -ForegroundColor Green
    return @{ Swap = $t; Timeline = $tl; OfflineMs = $offlineMs }
}

# After a role change to $NewPrimary: $OldPrimary SYNCHRONIZED again, every acknowledged commit in the
# ledger of the new primary (lost = writer's acknowledged seq - ledger rows up to it), databases ONLINE.
# $AckedAtMs: if given, only commits acknowledged up to then are checked (a forced failover can't keep
# what came later on the lost node - those are counted separately).
function Invoke-UcVerify {
    param($NewPrimary, $OldPrimary, [string]$Phase = 'verify', [string]$MetricPrefix = '', [int64]$AckedAtMs = 0, [switch]$SkipSync)
    $id = { param($n) if ($MetricPrefix) { $MetricPrefix + $n.Substring(0, 1).ToUpper() + $n.Substring(1) } else { $n } }
    Write-Step "Verification: $($NewPrimary.Name) primary, nothing acknowledged lost$(if (-not $SkipSync) { ", $($OldPrimary.Name) SYNCHRONIZED" })"
    Set-UcPhase $Phase running
    $appHost = Get-AppHost
    $synced = $true
    if (-not $SkipSync) {
        $synced = Wait-UcSynchronized -Primary $NewPrimary -Target $OldPrimary -TimeoutMinutes 10 -AppHost $appHost
        Set-UcMetric (& $id 'resynced') $synced -Detail "$($OldPrimary.Name) $(if ($synced) { 'SYNCHRONIZED' } else { 'NOT synchronized after 10 min' }) as the secondary of $($NewPrimary.Name)"
        if ($synced) { Set-UcLink -Link "ag-$AgName" -From $NewPrimary.Name -To $OldPrimary.Name -State 'synchronized' }
    }
    Update-UcMonitor $appHost | Out-Null
    $tl = Get-WriterTimeline $appHost $(if ($AckedAtMs) { $AckedAtMs } else { [DateTimeOffset]::UtcNow.ToUnixTimeMilliseconds() })
    $upTo = if ($AckedAtMs) { $tl.BeforeSeq } else { $tl.LastSeq }
    $st = @(Invoke-VmBatch @(New-StatusRequest $NewPrimary))[0]
    $ledger = Get-UcLedger -Node $NewPrimary -UpTo ([int64]$upTo) -LedgerRun (Get-LedgerRun)
    $lost = if ($null -ne $upTo -and $null -ne $ledger.RowsUpTo) { [int64]$upTo - $ledger.RowsUpTo } else { $null }
    Show-NodeStatus $NewPrimary $st
    Write-Host "  Acknowledged commits checked: $upTo | in the ledger on $($NewPrimary.Name): $($ledger.RowsUpTo) | lost: $lost" -ForegroundColor $(if ($lost -eq 0) { 'Green' } else { 'Red' })
    Set-UcMetric (& $id 'rpoTx') $lost -Detail "$upTo commit(s) acknowledged to the application$(if ($AckedAtMs) { ' before the failure' }), $($ledger.RowsUpTo) in the ledger of $($NewPrimary.Name)"
    if (-not $MetricPrefix) {
        Set-UcMetric appCommits $tl.Ok -Detail "commits acknowledged to the application in this run"
        Set-UcMetric failedAttempts $tl.Failed -Detail 'attempts that returned an error (offline, read-only secondary, node down)'
    }
    $agDbs = @(Get-Vals $st 'DB' | Where-Object { $_ -notmatch '\|NOT_IN_AG\|' })
    $pass = (Get-UcRole $NewPrimary $st) -eq 'PRIMARY' -and $agDbs.Count -gt 0 -and -not @($agDbs | Where-Object { $_ -notmatch '\|ONLINE\|' }).Count -and
            $tl.LastIp -eq $NewPrimary.PrivateIp
    Set-UcMetric (& $id 'verifyPass') ([bool]$pass) -Detail "$($NewPrimary.Name) $(Get-UcRole $NewPrimary $st), $($agDbs.Count) AG database(s), last application commit on $($tl.LastIp)"
    Save-Evidence $(if ($MetricPrefix) { "$MetricPrefix-verify" } else { 'verify' }) ([ordered]@{
        utc = (Format-Utc (Get-UtcNow)); newPrimary = $NewPrimary.Name; pass = [bool]$pass; synchronized = $synced
        acknowledgedUpTo = $upTo; ledger = $ledger.Raw; lostTransactions = $lost; status = $st.Stdout
        writer = [ordered]@{ ok = $tl.Ok; failed = $tl.Failed; lastSeq = $tl.LastSeq; lastIp = $tl.LastIp }
    })
    $ok = $pass -and $synced -and $lost -eq 0
    Set-UcPhase $Phase $(if ($ok) { 'done' } else { 'failed' }) $(if ($ok) { "PASS - $($NewPrimary.Name) primary, $lost lost, $(if ($SkipSync) { 'writes flowing' } else { 'secondary SYNCHRONIZED' })" } else { "FAIL - primary ok: $pass, synchronized: $synced, lost: $lost" })
    Write-Host ''
    if ($ok) { Write-Host "  PASS - $($NewPrimary.Name) is PRIMARY, the application writes to it, no acknowledged transaction lost." -ForegroundColor Green }
    else { Write-Host '  FAIL - see above.' -ForegroundColor Red }
}

# ── Azure login + topology ─────────────────────────────────────────────────────
function Connect-UcAzure {
    if (-not (Get-Command az -ErrorAction SilentlyContinue)) { Write-Error 'Azure CLI (az) not found.'; exit 1 }
    $account = az account show 2>$null | ConvertFrom-Json
    if (-not $account) { az login | Out-Null; $account = az account show 2>$null | ConvertFrom-Json }
    if (-not $account) { Write-Error 'Azure login failed.'; exit 1 }
    Write-Host "Using Azure subscription: $($account.name) ($($account.id))"
}

# Asks for what wasn't passed (identifier, node suffixes), then builds the topology:
#   $NodeA / $NodeB, $AllNodes, $StackRg, $RunsRoot / $CurrentRunFile / $script:RunId.
function Initialize-UcTopology {
    if (-not $script:Identifier) {
        $known = @(Get-ChildItem $StateDir -Filter '*.credentials.json' -ErrorAction SilentlyContinue | ForEach-Object { $_.Name -replace '\.credentials\.json$', '' })
        if ($known.Count) { Write-Host "Known stacks: $($known -join ', ')" -ForegroundColor DarkGray }
        $script:Identifier = Read-Name -Prompt 'Unique identifier used for the object names (e.g. 257672)' -Default '' -MaxLength 15
    }
    if (-not $script:PrimaryNodeSuffix)   { $script:PrimaryNodeSuffix   = Read-Name -Prompt 'Primary node objects suffix (e.g. node-1)' -Default 'node-1' -MaxLength 20 }
    if (-not $script:SecondaryNodeSuffix) { $script:SecondaryNodeSuffix = Read-Name -Prompt 'Secondary node objects suffix (e.g. node-2)' -Default 'node-2' -MaxLength 20 }
    $script:Identifier = $script:Identifier.ToLower()
    $script:PrimaryNodeSuffix = $script:PrimaryNodeSuffix.ToLower()
    $script:SecondaryNodeSuffix = $script:SecondaryNodeSuffix.ToLower()
    if (-not $script:AgName) { $script:AgName = "agsqlvm-$($script:PrimaryNodeSuffix)" }

    $script:StackRg = "$Prefix-$($script:Identifier)-$($script:PrimaryNodeSuffix)-$($script:SecondaryNodeSuffix)-rg"
    $credsFile = Join-Path $StateDir "$($script:StackRg).credentials.json"
    if (-not (Test-Path $credsFile)) { Write-Error "No saved credentials for $($script:StackRg) ($credsFile) - deploy it with ../../sqlvm-linux-ag.ps1 first."; exit 1 }
    $script:StackSa = (Get-Content $credsFile -Raw | ConvertFrom-Json).SaPassword

    $script:NodeA    = New-UcNode $script:PrimaryNodeSuffix
    $script:NodeB    = New-UcNode $script:SecondaryNodeSuffix
    $script:AllNodes = @($script:NodeA, $script:NodeB)

    $script:RunsRoot       = Join-Path $UcDir 'runs' $script:StackRg
    $script:CurrentRunFile = Join-Path $script:RunsRoot 'current-run.txt'
    New-Item -ItemType Directory -Force -Path $script:RunsRoot | Out-Null
    $script:RunId = if (Test-Path $script:CurrentRunFile) { (Get-Content $script:CurrentRunFile -Raw).Trim() } else { $null }
}

# Opens a new drill run: checks both nodes and the AG, records the roles and creates the ledger table.
# Returns the status results. $Extra (scriptblock) adds use-case-specific checks: it gets the status
# hashtable and returns a list of problems.
function Invoke-UcPrecheck {
    param([scriptblock]$Extra)
    Write-Step 'Pre-check: both nodes running, AG healthy, every database SYNCHRONIZED'
    # A new run starts here (current-run.txt only moves to it once the pre-check passes), so the
    # dashboard can follow the pre-check itself.
    $script:RunId = (Get-UtcNow).ToString('yyyyMMdd-HHmmss')
    $script:MonitorCursor = $null
    Update-PowerStates
    $down = @($AllNodes | Where-Object { $_.Power -ne 'running' })
    if ($down.Count -gt 0) {
        $down | ForEach-Object { Write-Host "  $($_.Vm) is '$($_.Power)'" -ForegroundColor Yellow }
        Confirm-Yes "  Type 'yes' to start them"
        Start-UcVms $down
    }
    Resolve-UcRoles -Live
    Start-UcSession
    Set-UcPhase precheck running
    $st = Get-StatusAll $AllNodes
    foreach ($n in $AllNodes) { Show-NodeStatus $n $st[$n.Vm] }
    foreach ($n in $AllNodes) { Set-UcNode -Node $n.Name -Power $n.Power -Role (Get-UcRole $n $st[$n.Vm]) -Global ($n.Vm -eq $Pri.Vm) }

    $problems = @()
    $p = $st[$Pri.Vm]; $s = $st[$Sec.Vm]
    if ((Get-UcRole $Sec $s) -ne 'SECONDARY') { $problems += "$($Sec.Name) is '$(Get-UcRole $Sec $s)', expected SECONDARY" }
    $secRow = @(Get-Vals $p 'REPLICA' | Where-Object { $_ -like "$($Sec.Name)|*" }) | Select-Object -First 1
    if (-not $secRow) { $problems += "$($Sec.Name) is not a replica of $AgName" }
    elseif ($secRow -notmatch '\|CONNECTED\|') { $problems += "$($Sec.Name) is not CONNECTED to the primary ($secRow)" }
    elseif ($secRow -notmatch '\|SYNCHRONOUS_COMMIT\|') { $problems += "$($Sec.Name) is not SYNCHRONOUS_COMMIT ($secRow)" }
    $agDbs = @(Get-Vals $p 'DB' | Where-Object { $_ -notmatch '\|NOT_IN_AG\|' })
    if ($agDbs.Count -eq 0) { $problems += "no database is in $AgName" }
    foreach ($db in $agDbs) { if ($db -notmatch '\|ONLINE\|' -or $db -match 'suspended=1') { $problems += "AG database not healthy: $db" } }
    if (@($agDbs | Where-Object { $_.Split('|')[0] -eq $DemoDbName }).Count -eq 0) { $problems += "$DemoDbName (the ledger database) is not in $AgName" }
    foreach ($row in (Get-Vals $p 'DB_REPLICA')) { if ($row.Split('|')[2] -ne 'SYNCHRONIZED') { $problems += "not SYNCHRONIZED on the secondary: $row" } }
    if ($Extra) { $problems += @(& $Extra $st) }
    if ($problems.Count -gt 0) {
        Write-Host ''
        $problems | ForEach-Object { Write-Host "  PROBLEM: $_" -ForegroundColor Red; Add-Event 'precheck-problem' $_ -Level 'error' }
        Set-UcPhase precheck failed "$($problems.Count) problem(s): $($problems[0])"
        Write-Error 'Pre-check failed - fix the AG before running the drill (../../sqlvm-linux-ag.ps1 -Action status-ag).'
        exit 1
    }

    Set-Content -Path $CurrentRunFile -Value $script:RunId
    Add-Event 'precheck-passed'
    Set-UcLink -Link "ag-$AgName" -State 'synchronized'
    Invoke-Sql -Node $Pri -File '01-prepare-ledger.sql' -Vars @{ DbName = $DemoDbName } -Label 'create ledger table' | Out-Null
    Save-Evidence 'precheck' ([ordered]@{
        runId = $script:RunId; utc = (Format-Utc (Get-UtcNow)); ag = $AgName; region = $Pri.Region
        primary = $Pri.Name; secondary = $Sec.Name; failedDomain = $script:FailedDomain
        nodes = @($AllNodes | ForEach-Object { [ordered]@{ name = $_.Name; domain = $_.Domain.label; zone = $_.Zone; ip = $_.PrivateIp } })
        status = @($AllNodes | ForEach-Object { [ordered]@{ node = $_.Name; output = $st[$_.Vm].Stdout } })
    })
    Write-Host ''
    Write-Host "  Pre-check passed. Drill run id: $($script:RunId)  (evidence: $(Get-RunDir))" -ForegroundColor Green
    Set-UcPhase precheck done "$($Pri.Name) PRIMARY ($($Pri.Domain.label)), $($Sec.Name) SYNCHRONIZED ($($Sec.Domain.label)) - run $($script:RunId)"
    return $st
}

# ── Report ─────────────────────────────────────────────────────────────────────
# Static HTML report of the current run (the dashboard's page at the end of the run, with every chart,
# key number, criterion and event): runs/<rg>/<run-id>/report.html.
function Export-UcReport {
    if (-not $script:RunId) { Write-Host '  No drill run to report on.' -ForegroundColor Yellow; return }
    $out = Join-Path (Get-RunDir) 'report.html'
    & pwsh -NoProfile -File (Join-Path $ProjectDir 'dashboard' 'dashboard.ps1') -UseCase $UcId -Stack $StackRg -Report $script:RunId -Out $out -NoBrowser
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
        & pwsh -NoProfile -File (Join-Path $ProjectDir 'dashboard' 'dashboard.ps1') -UseCase $UcId -Stack $StackRg `
            -Mode $DashboardMode -RefreshSeconds $DashboardRefreshSeconds -Detach
    }
    $logFile = Join-Path $RunsRoot "$Action-$((Get-UtcNow).ToString('yyyyMMdd-HHmmss')).log"
    Start-Transcript -Path $logFile | Out-Null
    $script:UcActionOk = $false
    try {
        if ($Banner) { & $Banner }
        if ($script:RunId) { Write-Host "Current drill run: $($script:RunId)" }
        if ($Action -notin ($ReadOnly + $OpensRun)) {
            Assert-Run
            Resolve-UcRoles
            Start-UcSession
        }
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
