#Requires -Version 7.0
<#
.SYNOPSIS
    UC-01 - Planned failover: move the primary role to the other zone (e.g. to patch the primary's VM)
    without losing a single acknowledged transaction, while an application keeps writing.

.DESCRIPTION
    Drill + runbook automation for the single-region stack built by ../../sqlvm-linux-ag.ps1: two nodes in
    different availability zones (or fault domains), one AG, both replicas SYNCHRONOUS_COMMIT,
    CLUSTER_TYPE = NONE (no cluster manager, no listener).

    An application writer on the secondary's VM commits a ledger row every ~0.2 s to whichever node accepts
    it (both private IPs configured, switches on error). The drill swaps the roles with Microsoft's
    procedure for CLUSTER_TYPE = NONE and measures, from the application's side, how long writes were
    interrupted and whether any acknowledged commit went missing.

    Every action of a drill run appends dashboard events to runs/<rg>/<run-id>/events.jsonl (phases,
    roles, links, throughput, queues, the write-interruption clock): watch it live or replay it later with
    ../../dashboard/dashboard.ps1 (-Dashboard opens it for you).

    Actions (asked for when not passed):
      status          Power state + AG health of both nodes.
      precheck        Starts deallocated VMs (after confirmation), checks the AG is healthy and every
                      database SYNCHRONIZED, opens a drill run (runs/<rg>/<run-id>/), creates the ledger.
      start-workload  Starts the application writer on the secondary's VM.
      failover        Planned failover: synchronize, AG offline, promote the secondary, demote the old
                      primary, resume - then wait for the application's first commit on the new primary.
      verify          New primary writable, old primary SYNCHRONIZED, no acknowledged commit lost.
      drill           precheck -> start-workload -> warm-up -> failover -> observe -> verify.
      failback        The same planned failover back to the original primary (+ verification).
      stop-workload   Stops the application writer.

    All SQL runs through 'az vm run-command' (Azure control plane): SSH and port 1433 don't need to be
    reachable from this machine.

.EXAMPLE
    ./uc-01.ps1                                   # interactive
.EXAMPLE
    ./uc-01.ps1 -Action drill -Dashboard -DashboardMode both -Identifier 257672 -PrimaryNodeSuffix node-1 -SecondaryNodeSuffix node-2
.EXAMPLE
    ./uc-01.ps1 -Action failback -Identifier 257672 -PrimaryNodeSuffix node-1 -SecondaryNodeSuffix node-2
#>
param(
    [ValidateSet('', 'status', 'precheck', 'start-workload', 'failover', 'verify', 'drill', 'failback', 'stop-workload')]
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
    [int]$WarmupSeconds   = 60,    # drill: commits before the failover
    [int]$ObserveSeconds  = 60,    # drill: commits watched after the failover
    [switch]$KeepWorkload,         # drill: leave the writer running at the end (e.g. to run failback next)
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

$UcId  = 'uc-01'
$UcTag = 'uc01'
$UcDir = $PSScriptRoot
# Shared framework: console input, evidence, Run Command transport, topology, application writer,
# monitoring, planned role swap, dashboard events and the main runner (../common/uc-common.ps1).
. (Join-Path $PSScriptRoot '..' 'common' 'uc-common.ps1')

$DrillPhases    = @{ sync = 'sync'; offline = 'offline'; promote = 'promote'; demote = 'demote'; reconnect = 'reconnect' }
$FailbackPhases = @{ sync = 'fbsync'; offline = 'fboffline'; promote = 'fbpromote'; demote = 'fbdemote'; reconnect = 'fbreconnect' }

# ── Actions ────────────────────────────────────────────────────────────────────
function Invoke-Status {
    Write-Step 'Status'
    Update-PowerStates
    $st = Get-StatusAll $AllNodes
    foreach ($n in $AllNodes) { Show-NodeStatus $n $st[$n.Vm] }
}

# The roles right now (live): the planned failover always goes from the current primary to the other node.
function Get-LiveRoles {
    Update-PowerStates
    $st = Get-StatusAll $AllNodes
    $p = @($AllNodes | Where-Object { (Get-UcRole $_ $st[$_.Vm]) -eq 'PRIMARY' })
    if ($p.Count -ne 1) {
        foreach ($n in $AllNodes) { Show-NodeStatus $n $st[$n.Vm] }
        Write-Error "Expected exactly one PRIMARY, found $($p.Count) - check ../../sqlvm-linux-ag.ps1 -Action status-ag."
        exit 1
    }
    $other = Get-OtherNode $p[0]
    if ((Get-UcRole $other $st[$other.Vm]) -ne 'SECONDARY') { Write-Error "$($other.Name) is '$(Get-UcRole $other $st[$other.Vm])' - a planned failover needs a healthy SECONDARY."; exit 1 }
    return @{ Primary = $p[0]; Secondary = $other }
}

function Invoke-Failover {
    $live = Get-LiveRoles
    if ($live.Primary.Vm -ne $Pri.Vm) {
        Write-Host "  $($live.Primary.Name) is already PRIMARY - the planned failover of this run already happened (use -Action failback)." -ForegroundColor Yellow
        foreach ($p in $DrillPhases.Values) { Set-UcPhase $p skipped "$($live.Primary.Name) already PRIMARY" }
        return
    }
    Write-Step "Planned failover: $($Pri.Name) ($($Pri.Domain.label)) -> $($Sec.Name) ($($Sec.Domain.label))"
    Write-Host '  No acknowledged commit is lost. Writes pause for the role change (a few seconds); the application' -ForegroundColor Yellow
    Write-Host "  reconnects to $($Sec.Name) by itself." -ForegroundColor Yellow
    Confirm-Yes "  Type 'yes' to fail over to $($Sec.Name)"
    $res = Invoke-UcPlannedFailover -From $Pri -To $Sec -Phases $DrillPhases -Clock 'interruption'
    Save-Evidence 'failover' ([ordered]@{
        from = $Pri.Name; to = $Sec.Name
        offlineUtc = (Format-Utc $res.Swap.T_OFFLINE); promotedUtc = (Format-Utc $res.Swap.T_PROMOTED); doneUtc = (Format-Utc $res.Swap.T_DONE)
        writer = $res.Timeline
    })
}

function Invoke-Failback {
    $live = Get-LiveRoles
    if ($live.Primary.Vm -eq $Pri.Vm) {
        Write-Host "  $($Pri.Name) is PRIMARY already - nothing to fail back." -ForegroundColor Yellow
        foreach ($p in @($FailbackPhases.Values) + @('fbverify')) { Set-UcPhase $p skipped "$($Pri.Name) already PRIMARY" }
        return
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
Write-Host 'UC-01 - Planned failover: move the primary to the other zone without losing a transaction' -ForegroundColor White
if (-not $Action) {
    $Action = Read-Choice -Prompt 'What do you want to do?' -Default 'status' `
        -Options @('status', 'precheck', 'start-workload', 'failover', 'verify', 'drill', 'failback', 'stop-workload') `
        -Descriptions @('roles, health, power state', 'healthy AG? open a new drill run', 'start the application writer',
                        'planned failover to the secondary', 'new primary writable, nothing lost, old primary synchronized',
                        'precheck -> workload -> warm-up -> failover -> observe -> verify', 'planned failover back to the original primary',
                        'stop the application writer')
}
Initialize-UcTopology

Invoke-UcMain -Banner {
    Write-Host "AG $AgName : $($NodeA.Name) ($($NodeA.Domain.label)) + $($NodeB.Name) ($($NodeB.Domain.label)), region $($NodeA.Region)"
} -Actions @{
    'status'         = { Invoke-Status }
    'precheck'       = { Invoke-UcPrecheck | Out-Null }
    'start-workload' = { Invoke-UcStartWorkload }
    'failover'       = { Invoke-Failover }
    'verify'         = { Invoke-UcVerify -NewPrimary $Sec -OldPrimary $Pri }
    'failback'       = { Invoke-Failback }
    'stop-workload'  = { Invoke-UcStopWorkload }
    'drill'          = {
        Write-Host ''
        Write-Host 'Drill: an application writer starts, then the primary role moves to the other node with a planned' -ForegroundColor Yellow
        Write-Host 'failover (no data loss). Writes pause for a few seconds while the roles change.' -ForegroundColor Yellow
        Confirm-Yes "Type 'yes' to run the full drill"
        $script:AutoApprove = $true   # one confirmation for the whole drill
        Invoke-UcPrecheck | Out-Null
        Invoke-UcStartWorkload
        Invoke-UcWarmup -Seconds $WarmupSeconds
        Invoke-Failover
        Write-Host "  Observing the application on the new primary for $ObserveSeconds s ..."
        Set-UcPhase observe running "$ObserveSeconds s of commits on $($Sec.Name)"
        Invoke-UcObserve -AppHost (Get-AppHost) -Seconds $ObserveSeconds
        Set-UcPhase observe done
        Invoke-UcVerify -NewPrimary $Sec -OldPrimary $Pri
        if (-not $KeepWorkload) { Invoke-UcStopWorkload }
        Write-Host ''
        Write-Host "Drill complete. Evidence: $(Get-RunDir)" -ForegroundColor Green
        Export-UcReport
        Write-Host "Fail back when you're ready: ./uc-01.ps1 -Action failback -Identifier $Identifier -PrimaryNodeSuffix $PrimaryNodeSuffix -SecondaryNodeSuffix $SecondaryNodeSuffix"
    }
}
