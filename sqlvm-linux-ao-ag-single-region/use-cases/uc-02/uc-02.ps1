#Requires -Version 7.0
<#
.SYNOPSIS
    UC-02 - Zone failure of the primary: force the AG over to the synchronous secondary in the other zone,
    then bring the failed node back as a secondary (and optionally fail back).

.DESCRIPTION
    Drill + runbook automation for the single-region stack built by ../../sqlvm-linux-ag.ps1: two nodes in
    different availability zones (or fault domains), one AG, both replicas SYNCHRONOUS_COMMIT,
    CLUSTER_TYPE = NONE (no cluster manager: the failover is a decision, then one command).

    An application writer on the secondary's VM commits a ledger row every ~0.2 s to whichever node accepts
    it. The primary's VM is powered off hard (no guest shutdown - like losing its zone), the secondary
    detects it, is promoted with FORCE_FAILOVER_ALLOW_DATA_LOSS, and the application reconnects to it by
    itself. Because commits are synchronous, no acknowledged transaction should be lost: the ledger proves it.

    Every action of a drill run appends dashboard events to runs/<rg>/<run-id>/events.jsonl: watch it live
    or replay it later with ../../dashboard/dashboard.ps1 (-Dashboard opens it for you).

    Actions (asked for when not passed):
      status            Power state + AG health of both nodes.
      precheck          Starts deallocated VMs (after confirmation), checks the AG is healthy, opens a drill
                        run (runs/<rg>/<run-id>/), creates the ledger table.
      start-workload    Starts the application writer on the secondary's VM.
      simulate-failure  Hard power-off of the primary's VM (az vm stop --skip-shutdown).
      failover          Detection on the secondary, FORCE_FAILOVER_ALLOW_DATA_LOSS, wait for the
                        application's first commit on it (stops the outage clock).
      verify            New primary writable, every commit acknowledged before the failure in its ledger.
      drill             precheck -> start-workload -> warm-up -> simulate-failure -> failover -> verify.
      reinstate         The zone is back: fence the old primary (1433 + 5022), start it, measure what only
                        it has, demote it to SECONDARY, resume, wait for SYNCHRONIZED, lift the fence.
      failback          Planned, no-data-loss failover back to the original primary.
      stop-workload     Stops the application writer.

    All SQL runs through 'az vm run-command' (Azure control plane): SSH and port 1433 don't need to be
    reachable from this machine.

.EXAMPLE
    ./uc-02.ps1                                   # interactive
.EXAMPLE
    ./uc-02.ps1 -Action drill -Dashboard -DashboardMode both -Identifier 257672 -PrimaryNodeSuffix node-1 -SecondaryNodeSuffix node-2
.EXAMPLE
    ./uc-02.ps1 -Action reinstate -Identifier 257672 -PrimaryNodeSuffix node-1 -SecondaryNodeSuffix node-2
#>
param(
    [ValidateSet('', 'status', 'precheck', 'start-workload', 'simulate-failure', 'failover', 'verify', 'drill', 'reinstate', 'failback', 'stop-workload')]
    [string]$Action = '',

    # Same values used with ../../sqlvm-linux-ag.ps1 (the stack's suffixes, whichever node is primary now).
    [Alias('Environment')]
    [string]$Identifier          = '',
    [string]$PrimaryNodeSuffix   = '',
    [string]$SecondaryNodeSuffix = '',
    [string]$Prefix              = 'sqlvm',
    [string]$AgName              = '',   # default agsqlvm-<PrimaryNodeSuffix>
    [string]$DemoDbName          = 'AGDemoDB',

    [int]$WorkloadSeconds = 1800,  # writer lifetime
    [int]$WarmupSeconds   = 60,    # drill: commits before the failure
    [int]$DetectSeconds   = 15,    # drill: detection/decision window after the failure
    [switch]$Force,                # failover even if the secondary still reports the primary CONNECTED
    [switch]$KeepWorkload,         # drill: leave the writer running (e.g. to watch reinstate / failback)
    [switch]$AutoApprove,

    # Opens the live dashboard (../../dashboard/dashboard.ps1) in its own window before the action runs.
    [switch]$Dashboard,
    [ValidateSet('web', 'terminal', 'both')]
    [string]$DashboardMode = 'web',
    [ValidateRange(1, 60)]
    [int]$DashboardRefreshSeconds = 3
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Continue'

$UcId  = 'uc-02'
$UcTag = 'uc02'
$UcDir = $PSScriptRoot
$UcFailsPrimary = $true   # the dashboard marks the primary's zone as the failure domain
# Shared framework: console input, evidence, Run Command transport, topology, application writer,
# monitoring, planned role swap, dashboard events and the main runner (../common/uc-common.ps1).
. (Join-Path $PSScriptRoot '..' 'common' 'uc-common.ps1')

# Fence of the old primary while it comes back (its NIC NSG; priorities below the stack's allow rules).
$FenceRules = @(
    @{ Name = 'uc02-fence-deny-sql';      Direction = 'Inbound';  Port = '1433'; Priority = 90 },
    @{ Name = 'uc02-fence-deny-hadr-in';  Direction = 'Inbound';  Port = '5022'; Priority = 91 },
    @{ Name = 'uc02-fence-deny-hadr-out'; Direction = 'Outbound'; Port = '5022'; Priority = 90 })
$FailbackPhases = @{ sync = 'fbsync'; offline = 'fboffline'; promote = 'fbpromote'; demote = 'fbdemote'; reconnect = 'fbreconnect' }

# ── Actions ────────────────────────────────────────────────────────────────────
function Invoke-Status {
    Write-Step 'Status'
    Update-PowerStates
    $st = Get-StatusAll $AllNodes
    foreach ($n in $AllNodes) { Show-NodeStatus $n $st[$n.Vm] }
    $fences = @(foreach ($n in $AllNodes) { az network nsg rule list -g $n.Rg --nsg-name $n.Nsg --query "[?starts_with(name, 'uc02-fence')].name" -o tsv 2>$null })
    if ($fences.Count -gt 0) { Write-Host ''; Write-Host "  Fence rules still in place: $($fences -join ', ')" -ForegroundColor Yellow }
}

function Invoke-SimulateFailure {
    Assert-Run
    Write-Step "Simulating a failure of $($Pri.Domain.label): hard power-off of $($Pri.Vm)"
    Write-Host '  No guest shutdown: SQL Server stops mid-transaction, exactly like losing the zone.' -ForegroundColor Yellow
    Confirm-Yes "  Type 'yes' to power it off now"
    Set-UcPhase failure running
    $t0 = Get-UtcNow
    Add-Event 'failure-injected' "az vm stop --skip-shutdown $($Pri.Vm)"
    Set-UcClock outage start -At $t0 -Detail "$($Pri.Domain.label) lost"
    az vm stop -g $Pri.Rg -n $Pri.Vm --skip-shutdown --no-wait -o none
    Set-UcNode -Node $Pri.Name -Power 'stopping'
    Set-UcLink "ag-$AgName" down
    az vm wait -g $Pri.Rg -n $Pri.Vm --custom "instanceView.statuses[?code=='PowerState/stopped']" --timeout 600 -o none 2>$null
    if ((Get-PowerState $Pri) -ne 'stopped') { Write-Error "$($Pri.Vm) did not power off."; exit 1 }
    $off = Get-UtcNow
    Set-UcNode -Node $Pri.Name -Power 'stopped'
    Write-Host "  $($Pri.Vm) powered off."
    Set-UcPhase failure done "$($Pri.Name) powered off ($($Pri.Domain.label))"
    Save-Evidence 'failure' ([ordered]@{
        method = 'az vm stop --skip-shutdown (hard power-off, VM stays allocated)'; node = $Pri.Name; domain = $Pri.Domain.label
        requestedUtc = (Format-Utc $t0); poweredOffConfirmedUtc = (Format-Utc $off)
    })
}

function Invoke-Failover {
    Write-Step "Failover to $($Sec.Name) ($($Sec.Domain.label))"
    if ((Get-PowerState $Sec) -ne 'running') { Write-Error "$($Sec.Vm) is not running - it must be to take over."; exit 1 }

    # 1. Detection: the secondary's own replica row reports its connection to the primary.
    if ((Get-UcRunningPhase) -ne 'detect') { Set-UcPhase detect running }
    $role = $null; $conn = $null; $snap = $null
    for ($i = 1; $i -le 4; $i++) {
        $snap = @(Invoke-VmBatch @(New-StatusRequest $Sec))[0]
        $role = Get-UcRole $Sec $snap
        $self = @(Get-Vals $snap 'REPLICA' | Where-Object { $_ -like "$($Sec.Name)|*" }) | Select-Object -First 1
        $conn = if ($self) { $self.Split('|')[3] } else { '?' }
        if ($role -in @('PRIMARY', 'RESOLVING') -or $conn -eq 'DISCONNECTED') { break }
        if ($i -lt 4) { Write-Host "  $($Sec.Name) still reports '$conn' to the primary - re-checking in 10 s ..." -ForegroundColor Yellow; Start-Sleep 10 }
    }
    Write-Host "  $($Sec.Name): role $role, connection to the primary $conn"
    $failure = Read-Evidence 'failure'
    $failMs = if ($failure) { ConvertTo-EpochMs (ConvertTo-Utc $failure.requestedUtc) } else { [DateTimeOffset]::UtcNow.ToUnixTimeMilliseconds() }
    $lost = $role -in @('PRIMARY', 'RESOLVING') -or $conn -eq 'DISCONNECTED'
    if ($failure) { Set-UcMetric detectSeconds ([math]::Round(((Get-UtcNow) - (ConvertTo-Utc $failure.requestedUtc)).TotalSeconds, 1)) 's' -Detail 'failure injected -> secondary reports the primary lost (includes the Run Command round trips)' }
    Set-UcPhase detect $(if ($lost -or $Force) { 'done' } else { 'failed' }) "$($Sec.Name): role $role, primary $conn"

    if ($role -eq 'PRIMARY') {
        Write-Host "  $($Sec.Name) is already PRIMARY - skipping the promotion." -ForegroundColor Yellow
        Set-UcPhase failover skipped "$($Sec.Name) already PRIMARY"
    } else {
        if (-not $lost -and -not $Force) {
            Write-Error @"
$($Sec.Name) still reports '$conn' for its connection to the primary - not a lost primary.
Forcing a failover now would leave two primaries. Use UC-01 (planned failover) instead, or pass -Force
if the primary is truly unusable although still connected.
"@
            exit 1
        }
        Write-Host ''
        Write-Host "  FORCE_FAILOVER_ALLOW_DATA_LOSS on $($Sec.Name). Both replicas are synchronous: every commit the application" -ForegroundColor Yellow
        Write-Host '  got acknowledged is already hardened there. The verification proves it with the ledger.' -ForegroundColor Yellow
        Confirm-Yes "  Type 'yes' to fail over to $($Sec.Name)"

        # 2. Promote, resume, keep accepting writes with the other replica down (one Run Command).
        Set-UcPhase failover running
        $body = @'
cat > /tmp/__TAG__-resume.sql <<'UCSQL'
__RESUME__
UCSQL
echo "T_START=$(date +%s%3N)"
SQL -Q "ALTER AVAILABILITY GROUP [__AG__] FORCE_FAILOVER_ALLOW_DATA_LOSS;"
echo "T_PROMOTED=$(date +%s%3N)"
SQL -i /tmp/__TAG__-resume.sql || true
SQL -Q "ALTER AVAILABILITY GROUP [__AG__] SET (REQUIRED_SYNCHRONIZED_SECONDARIES_TO_COMMIT = 0);"
SQL -Q "SET NOCOUNT ON; SELECT 'LOCAL_ROLE=' + rs.role_desc FROM sys.dm_hadr_availability_replica_states rs JOIN sys.availability_groups ag ON ag.group_id = rs.group_id WHERE ag.name = N'__AG__' AND rs.is_local = 1"
'@
        $fo = @(Invoke-VmBatch @(@{ Node = $Sec; Label = 'force failover'; Body = $body.Replace('__RESUME__', $ResumeSql).Replace('__AG__', $AgName).Replace('__TAG__', $UcTag) }))[0]
        Assert-Ok $fo
        foreach ($k in @('RESUMED', 'RESUME_FAILED', 'LOCAL_ROLE')) { foreach ($v in (Get-Vals $fo $k)) { Write-Host "  $k = $v" } }
        if ((Get-Val $fo 'LOCAL_ROLE') -ne 'PRIMARY') { Write-Error "$($Sec.Name) did not become PRIMARY."; exit 1 }
        $tP = ConvertFrom-EpochMs (Get-Val $fo 'T_PROMOTED')
        Set-UcMetric failoverSeconds ([math]::Round(($tP - (ConvertFrom-EpochMs (Get-Val $fo 'T_START'))).TotalSeconds, 1)) 's' -Detail 'FORCE_FAILOVER_ALLOW_DATA_LOSS on the secondary'
        Set-UcNode -Node $Sec.Name -Role 'PRIMARY' -Global $true
        Set-UcNode -Node $Pri.Name -Role 'LOST' -Global $false -Detail "$($Pri.Name) is gone with its zone - still a replica of $AgName, reinstated later"
        Set-UcPhase failover done "$($Sec.Name) is PRIMARY" -At $tP
    }

    # 3. The application reconnects by itself - its first commit on the new primary stops the outage clock.
    $appHost = Get-AppHost
    Set-UcPhase reconnect running "the application retries until $($Sec.Name) accepts its commits"
    $tl = Wait-WriterOn -AppHost $appHost -Target $Sec -AtMs $failMs -TimeoutSeconds 180
    if (-not $tl) {
        Set-UcMetric appReconnected $false
        Set-UcPhase reconnect failed "no application commit on $($Sec.Name) within 3 min (writer running?)"
        Write-Host '  No application commit on the new primary within 3 min - is the writer running (-Action start-workload)?' -ForegroundColor Yellow
        return
    }
    $first = ConvertFrom-EpochMs $tl.AfterMs
    Set-UcClock outage stop -At $first -Detail "first application commit on $($Sec.Name)"
    $rto = [math]::Round(($tl.AfterMs - $failMs) / 1000, 1)
    Set-UcMetric rto $rto 's' -Detail "failure injected -> first application commit on $($Sec.Name) at $($first.ToString('HH:mm:ss.fff')) UTC ($($tl.FailedAfter) failed attempts in between)"
    Set-UcMetric appReconnected $true -Detail "first commit on $($Sec.Name) (seq $($tl.AfterSeq)) without any change to the application"
    Set-UcPhase reconnect done "first commit on $($Sec.Name) $rto s after the failure" -At $first
    Write-Host "  RTO (failure -> first application commit on $($Sec.Name)): $rto s" -ForegroundColor Green
    Save-Evidence 'failover' ([ordered]@{ newPrimary = $Sec.Name; failureMs = $failMs; rtoSeconds = $rto; writer = $tl; status = $snap.Stdout })
}

function Invoke-Verify {
    $failure = Read-Evidence 'failure'
    $failMs = if ($failure) { ConvertTo-EpochMs (ConvertTo-Utc $failure.requestedUtc) } else { 0 }
    # The old primary is down: no synchronization to wait for; only commits acknowledged before the failure
    # are checked (later ones went to the new primary anyway).
    Invoke-UcVerify -NewPrimary $Sec -OldPrimary $Pri -AckedAtMs $failMs -SkipSync
}

function Set-Fence {
    param($Node, [switch]$Remove, [string[]]$Only)
    foreach ($f in $FenceRules) {
        if ($Only -and $Only -notcontains $f.Name) { continue }
        if ($Remove) {
            az network nsg rule delete -g $Node.Rg --nsg-name $Node.Nsg -n $f.Name -o none 2>$null
            Add-Event 'fence-removed' "$($Node.Nsg): $($f.Name)"
            continue
        }
        az network nsg rule create -g $Node.Rg --nsg-name $Node.Nsg -n $f.Name --priority $f.Priority `
            --direction $f.Direction --access Deny --protocol Tcp --destination-port-ranges $f.Port `
            --source-address-prefixes '*' --destination-address-prefixes '*' `
            --description 'UC-02 fence: stale primary after forced failover' -o none
        if ($LASTEXITCODE -ne 0) { Write-Error "Could not create fence rule $($f.Name) - not starting the old primary."; exit 1 }
        Add-Event 'fence-applied' "$($Node.Nsg): $($f.Name)"
    }
}

function Invoke-Reinstate {
    Write-Step "Reinstate $($Pri.Name) ($($Pri.Domain.label)) as the secondary of $($Sec.Name)"
    $cur = @(Invoke-VmBatch @(New-StatusRequest $Sec))[0]
    if ((Get-UcRole $Sec $cur) -ne 'PRIMARY') { Write-Error "$($Sec.Name) is not PRIMARY - nothing to reinstate (run failover first)."; exit 1 }

    # 1. Fence before power-on: the old primary may boot believing it is still PRIMARY. Block clients
    #    (1433) and the AG endpoint (5022 in/out) so nothing can write to it or replicate from it.
    Write-Host "  Fencing $($Pri.Nsg): deny inbound 1433, inbound 5022, outbound 5022."
    Set-UcPhase fence running
    Set-Fence $Pri
    Set-UcNode -Node $Pri.Name -Fenced $true -Detail "$($Pri.Nsg): 1433 in, 5022 in/out denied"
    Set-UcPhase fence done '1433 in, 5022 in and out denied'

    # 2. The zone is back.
    Set-UcPhase restart running
    $Pri.Power = Get-PowerState $Pri
    Set-UcMetric fencedBeforeStart ($Pri.Power -ne 'running') -Detail "$($Pri.Name) was '$($Pri.Power)' when the fence went up"
    if ($Pri.Power -ne 'running') { Set-UcNode -Node $Pri.Name -Power 'starting'; Start-UcVms @($Pri) }
    Set-UcNode -Node $Pri.Name -Power 'running'
    $old = $null
    for ($i = 1; $i -le 12; $i++) {
        $old = @(Invoke-VmBatch @(New-StatusRequest $Pri) -Quiet)[0]
        if ((Get-Val $old 'SQL_UP') -eq '1') { break }
        Write-Host '  waiting for SQL Server on the old primary ...' -ForegroundColor DarkGray
        Start-Sleep 10
    }
    $oldRole = Get-UcRole $Pri $old
    Write-Host "  $($Pri.Name) boots as: $oldRole"
    Set-UcNode -Node $Pri.Name -Role $(if ($oldRole -eq 'PRIMARY') { 'STALE PRIMARY' } else { $oldRole }) -Detail "$($Pri.Name) is back ($oldRole) - fenced"
    Set-UcPhase restart done "$($Pri.Name) running, SQL Server role $oldRole"

    # 3. What only the old primary has: rows it committed that never made it to the new primary. With
    #    synchronous commit these can only be commits whose acknowledgement never reached the application.
    Set-UcPhase inspect running
    $ledgerRun = Get-LedgerRun
    $mine = Get-UcLedger -Node $Pri -HostIp $Pri.PrivateIp -LedgerRun $ledgerRun -AllowFail
    $theirs = Get-UcLedger -Node $Sec -HostIp $Pri.PrivateIp -LedgerRun $ledgerRun
    $divergent = $null
    if ($mine.Ok -and $null -ne $mine.HostMaxSeq -and $null -ne $theirs.HostMaxSeq) {
        $divergent = [math]::Max(0, $mine.HostMaxSeq - $theirs.HostMaxSeq)
        Write-Host "  Newest row committed through $($Pri.Name): seq $($mine.HostMaxSeq) on it, seq $($theirs.HostMaxSeq) on $($Sec.Name) -> $divergent row(s) only on the old primary."
        Set-UcMetric divergentRows $divergent -Detail "rows $($Pri.Name) committed that never reached $($Sec.Name) - never acknowledged to the application (synchronous commit); discarded by the demotion"
        Set-UcPhase inspect done "$divergent unacknowledged row(s) only on $($Pri.Name)"
    } else {
        Write-Host "  The old primary's ledger isn't readable yet (database recovering / not ONLINE) - informational only." -ForegroundColor DarkGray
        Set-UcMetric divergentRows 'n/a' -Detail 'old primary database not readable while fenced'
        Set-UcPhase inspect done 'old primary ledger not readable (database not ONLINE) - informational'
    }

    # 4. Demote: the old primary becomes a SECONDARY of the new one; its unreplicated tail is discarded.
    Write-Host "  Next: $($Pri.Name) is demoted to SECONDARY of $($Sec.Name) and resumes replication." -ForegroundColor Yellow
    Confirm-Yes "  Type 'yes' to continue"
    Set-UcPhase demote running
    if ($oldRole -eq 'PRIMARY') { Invoke-AgStep $Pri 'offline' -AllowFail | Out-Null }
    Invoke-AgStep $Pri 'demote' | Out-Null
    Set-UcNode -Node $Pri.Name -Role 'SECONDARY'
    Set-UcPhase demote done "$($Pri.Name) SECONDARY"

    # 5. Let the endpoints talk again, resume both sides and wait for SYNCHRONIZED.
    Set-Fence $Pri -Remove -Only @('uc02-fence-deny-hadr-in', 'uc02-fence-deny-hadr-out')
    Set-UcPhase resync running "resuming data movement; $($Pri.Name) catches up from $($Sec.Name)"
    Set-UcLink -Link "ag-$AgName" -From $Sec.Name -To $Pri.Name -State 'catching-up'
    $resume = @(Invoke-VmBatch @($Pri, $Sec | ForEach-Object { @{ Node = $_; Label = 'resume'; Body = (Get-ScriptBody 'ag-09-failover-step.sh' @($_.Sa, $AgName, 'resume')) } }))
    $failedResume = @()
    foreach ($r in $resume) {
        foreach ($k in @('RESUMED', 'RESUME_FAILED')) { foreach ($v in (Get-Vals $r $k)) { Write-Host "  [$($r.Vm)] $k = $v" } }
        $failedResume += @(Get-Vals $r 'RESUME_FAILED')
    }
    $synced = Wait-UcSynchronized -Primary $Sec -Target $Pri -TimeoutMinutes 20 -AppHost (Get-AppHost)
    Set-UcMetric resynced $synced -Detail "$($Pri.Name) $(if ($synced) { 'SYNCHRONIZED' } else { 'NOT synchronized after 20 min' }) as the secondary of $($Sec.Name)"
    Set-UcLink -Link "ag-$AgName" -From $Sec.Name -To $Pri.Name -State $(if ($synced) { 'synchronized' } else { 'not-synchronizing' })
    Set-UcPhase resync $(if ($synced) { 'done' } else { 'failed' }) $(if ($synced) { "$($Pri.Name) SYNCHRONIZED" } else { "$($Pri.Name) not synchronized$(if ($failedResume.Count) { ": $($failedResume[0])" })" })

    # 6. Lift the client fence: the old primary is a healthy (readable) secondary again.
    Set-UcPhase unfence running
    Set-Fence $Pri -Remove -Only @('uc02-fence-deny-sql')
    Set-UcNode -Node $Pri.Name -Fenced $false
    Set-UcPhase unfence done "$($Pri.Name) accepts clients again (readable secondary)"
    Save-Evidence 'reinstate' ([ordered]@{ utc = (Format-Utc (Get-UtcNow)); bootRole = $oldRole; oldLedger = $mine.Raw; newLedger = $theirs.Raw; divergentRows = $divergent; synchronized = $synced })
    Write-Host ''
    if ($synced) {
        Write-Host "  $($Pri.Name) is back as the SYNCHRONOUS secondary of $($Sec.Name)." -ForegroundColor Green
        Write-Host '  Optional: -Action failback to make it primary again (planned, no data loss).'
    } else {
        Write-Host "  $($Pri.Name) did not synchronize - its copy diverged. Rebuild it (it is re-seeded from $($Sec.Name)):" -ForegroundColor Red
        Write-Host "    ../../sqlvm-linux-ag.ps1 -Action remove -RemoveScope $(if ($Pri.Vm -eq $NodeA.Vm) { 'primary' } else { 'secondary' }) -Identifier $Identifier -PrimaryNodeSuffix $PrimaryNodeSuffix -SecondaryNodeSuffix $SecondaryNodeSuffix" -ForegroundColor Red
        Write-Host "    ../../sqlvm-linux-ag.ps1 -Action deploy -Identifier $Identifier -PrimaryNodeSuffix $PrimaryNodeSuffix -SecondaryNodeSuffix $SecondaryNodeSuffix" -ForegroundColor Red
    }
}

function Invoke-Failback {
    $st = Get-StatusAll @($Pri, $Sec | ForEach-Object { $_.Power = Get-PowerState $_; $_ })
    if ((Get-UcRole $Pri $st[$Pri.Vm]) -eq 'PRIMARY') { Write-Host "  $($Pri.Name) is PRIMARY already - nothing to fail back." -ForegroundColor Yellow; return }
    if ((Get-UcRole $Sec $st[$Sec.Vm]) -ne 'PRIMARY' -or (Get-UcRole $Pri $st[$Pri.Vm]) -ne 'SECONDARY') {
        Write-Error "Failback expects $($Sec.Name) PRIMARY and $($Pri.Name) SECONDARY (run reinstate first)."
        exit 1
    }
    Write-Step "Planned failback: $($Sec.Name) -> $($Pri.Name) ($($Pri.Domain.label))"
    Confirm-Yes "  Type 'yes' to fail back to $($Pri.Name)"
    $appHost = Get-AppHost
    $probe = Update-UcMonitor $appHost -Quiet
    if ((Get-Val $probe 'W_RUNNING') -ne '1') {
        Write-Host '  The writer is not running - starting it for the failback (ledger run <run>-fb).' -ForegroundColor Yellow
        Start-UcWriter -AppHost $appHost -Seconds $WorkloadSeconds -LedgerRun "$($script:RunId)-fb" | Out-Null
        Save-Evidence 'workload' ([ordered]@{ appHost = $appHost.Name; ledgerRun = "$($script:RunId)-fb"; startedUtc = (Format-Utc (Get-UtcNow)); seconds = $WorkloadSeconds })
        Start-Sleep 10
    }
    Invoke-UcPlannedFailover -From $Sec -To $Pri -Phases $FailbackPhases -Clock 'fbinterruption' -MetricPrefix 'failback' | Out-Null
    Invoke-UcVerify -NewPrimary $Pri -OldPrimary $Sec -Phase 'fbverify' -MetricPrefix 'failback'
}

# ── Inputs ─────────────────────────────────────────────────────────────────────
Connect-UcAzure
Write-Host ''
Write-Host 'UC-02 - Zone failure of the primary: forced failover to the synchronous secondary' -ForegroundColor White
if (-not $Action) {
    $Action = Read-Choice -Prompt 'What do you want to do?' -Default 'status' `
        -Options @('status', 'precheck', 'start-workload', 'simulate-failure', 'failover', 'verify', 'drill', 'reinstate', 'failback', 'stop-workload') `
        -Descriptions @('roles, health, power state', 'healthy AG? open a new drill run', 'start the application writer',
                        "hard power-off of the primary's VM", 'force the AG over to the secondary', 'new primary writable, nothing acknowledged lost',
                        'precheck -> workload -> warm-up -> failure -> failover -> verify', 'zone back: fence, start, demote, resynchronize',
                        'planned failback to the original primary', 'stop the application writer')
}
Initialize-UcTopology

if ($NodeA.Domain.id -eq $NodeB.Domain.id) {
    Write-Host ''
    Write-Host "WARNING: $($NodeA.Name) and $($NodeB.Name) share $($NodeA.Domain.label): a real failure there would take BOTH down." -ForegroundColor Red
    Write-Host 'The drill still exercises the mechanics by powering off only the primary.' -ForegroundColor Red
    Confirm-Yes "Type 'yes' to continue anyway"
}

Invoke-UcMain -Banner {
    Write-Host "AG $AgName : $($NodeA.Name) ($($NodeA.Domain.label)) + $($NodeB.Name) ($($NodeB.Domain.label)), region $($NodeA.Region)"
} -Actions @{
    'status'           = { Invoke-Status }
    'precheck'         = { Invoke-UcPrecheck | Out-Null }
    'start-workload'   = { Invoke-UcStartWorkload }
    'simulate-failure' = { Invoke-SimulateFailure }
    'failover'         = { Invoke-Failover }
    'verify'           = { Invoke-Verify }
    'reinstate'        = { Invoke-Reinstate }
    'failback'         = { Invoke-Failback }
    'stop-workload'    = { Invoke-UcStopWorkload }
    'drill'            = {
        Write-Host ''
        Write-Host "Drill: the primary's VM will be POWERED OFF (no shutdown) and the AG FORCED over to the secondary in" -ForegroundColor Yellow
        Write-Host 'the other zone. With synchronous commit no acknowledged transaction should be lost - the ledger checks it.' -ForegroundColor Yellow
        Confirm-Yes "Type 'yes' to run the full drill"
        $script:AutoApprove = $true   # one confirmation for the whole drill
        Invoke-UcPrecheck | Out-Null
        Invoke-UcStartWorkload
        Invoke-UcWarmup -Seconds $WarmupSeconds
        Invoke-SimulateFailure
        Write-Host "  Detection/decision window: $DetectSeconds s ..."
        Set-UcPhase detect running "detection/decision window: $DetectSeconds s"
        Invoke-UcObserve -AppHost (Get-AppHost) -Seconds $DetectSeconds
        Invoke-Failover
        Invoke-Verify
        if (-not $KeepWorkload) { Invoke-UcStopWorkload }
        Write-Host ''
        Write-Host "Drill complete. Evidence: $(Get-RunDir)" -ForegroundColor Green
        Export-UcReport
        Write-Host "When the zone is 'back': ./uc-02.ps1 -Action reinstate -Identifier $Identifier -PrimaryNodeSuffix $PrimaryNodeSuffix -SecondaryNodeSuffix $SecondaryNodeSuffix"
    }
}
