# Dashboard events, shared by every use case (dot-source it: . "$PSScriptRoot/../common/uc-events.ps1").
#
# A use case appends one JSON line per event to runs/<rg>/<run-id>/events.jsonl. The dashboard
# (../../dashboard/dashboard.ps1) only reads that file - it never talks to the VMs - so it can't
# collide with the use case's own Run Command calls, and a recorded run can be replayed later.
#
# Every line has: utc, event (short name), detail (human text), and a 'kind' that tells the
# dashboard what changed:
#   topology  nodes, AG groups and links to draw + params used in the phase narration
#   action    an action started / completed / failed
#   phase     a phase of the use case is running / done / failed / skipped (ids from dashboard.json)
#   node      power, role, global-primary flag or fence state of one node
#   link      state (and optionally direction) of an AG or distributed AG link
#   metric    a measured value (RTO, RPO, ...); criteria in dashboard.json are evaluated on metrics
#   clock     start / stop of a live clock (e.g. the outage clock); 'at' overrides the event time
#   log       anything else worth showing in the event log
#
# Call Set-UcEventSink once with a scriptblock that returns the current run folder (or $null while
# no run is open - events are then dropped).

$script:UcEventSink = $null

function Set-UcEventSink {
    param([scriptblock]$RunDir)
    $script:UcEventSink = $RunDir
}

function Write-UcEvent {
    param([string]$Event, [string]$Detail = '', [string]$Kind = 'log', [hashtable]$Fields = @{}, [string]$Level = 'info')
    if (-not $script:UcEventSink) { return }
    $dir = & $script:UcEventSink
    if (-not $dir) { return }
    $line = [ordered]@{ utc = [DateTime]::UtcNow.ToString('yyyy-MM-ddTHH:mm:ss.fffZ'); event = $Event; detail = $Detail; kind = $Kind }
    if ($Level -ne 'info') { $line.level = $Level }
    foreach ($k in $Fields.Keys) { $line[$k] = $Fields[$k] }
    Add-Content -Path (Join-Path $dir 'events.jsonl') -Value ($line | ConvertTo-Json -Compress -Depth 8)
}

# Nodes: @{ id; label; name; vm; rg; region; ip; group; role }  Groups: @{ id; label; kind }
# Links: @{ id; kind ('ag'|'dag'); from; to; label; state }  Params: narration placeholders.
function Write-UcTopology {
    param([string]$UseCase, [object[]]$Nodes, [object[]]$Groups, [object[]]$Links, [hashtable]$Params = @{}, [string[]]$Regions = @())
    Write-UcEvent -Event 'topology' -Kind 'topology' -Detail "$(@($Nodes).Count) node(s), $(@($Links).Count) link(s)" -Fields @{
        useCase = $UseCase; nodes = @($Nodes); groups = @($Groups); links = @($Links); params = $Params; regions = @($Regions) }
}

function Set-UcAction {
    param([string]$Action, [ValidateSet('started', 'completed', 'failed')][string]$Status, [string]$Detail = '')
    $level = if ($Status -eq 'failed') { 'error' } else { 'info' }
    Write-UcEvent -Event "action-$Status" -Kind 'action' -Detail $(if ($Detail) { $Detail } else { "$Action $Status" }) -Level $level -Fields @{ action = $Action; status = $Status }
}

$script:UcRunningPhase = $null
function Set-UcPhase {
    param([string]$Phase, [ValidateSet('running', 'done', 'failed', 'skipped')][string]$Status, [string]$Detail = '')
    $script:UcRunningPhase = if ($Status -eq 'running') { $Phase } elseif ($script:UcRunningPhase -eq $Phase) { $null } else { $script:UcRunningPhase }
    $level = if ($Status -eq 'failed') { 'error' } else { 'info' }
    Write-UcEvent -Event "phase-$Status" -Kind 'phase' -Detail $(if ($Detail) { $Detail } else { "$Phase $Status" }) -Level $level -Fields @{ phase = $Phase; status = $Status }
}
function Get-UcRunningPhase { $script:UcRunningPhase }

# Only the fields passed are changed. -Role: PRIMARY, SECONDARY, FORWARDER, STALE PRIMARY, REMOVED, SEEDING...
function Set-UcNode {
    param([string]$Node, [string]$Power, [string]$Role, [Nullable[bool]]$Global, [Nullable[bool]]$Fenced, [string]$Detail = '')
    $f = @{ node = $Node }
    if ($Power) { $f.power = $Power }
    if ($Role) { $f.role = $Role }
    if ($null -ne $Global) { $f.global = [bool]$Global }
    if ($null -ne $Fenced) { $f.fenced = [bool]$Fenced }
    Write-UcEvent -Event 'node' -Kind 'node' -Detail $(if ($Detail) { $Detail } else { "$Node $((@($Power, $Role) | Where-Object { $_ }) -join ' ')" }) -Fields $f
}

# -State: healthy, synchronizing, seeding, suspended, down, removed, not-synchronizing.
function Set-UcLink {
    param([string]$Link, [string]$State, [string]$From, [string]$To, [string]$Detail = '')
    $f = @{ link = $Link; state = $State }
    if ($From) { $f.from = $From }
    if ($To) { $f.to = $To }
    Write-UcEvent -Event 'link' -Kind 'link' -Detail $(if ($Detail) { $Detail } else { "$Link $State" }) -Fields $f
}

function Set-UcMetric {
    param([string]$Metric, $Value, [string]$Unit = '', [string]$Detail = '')
    Write-UcEvent -Event 'metric' -Kind 'metric' -Detail $(if ($Detail) { $Detail } else { "$Metric = $Value $Unit".Trim() }) -Fields @{ metric = $Metric; value = $Value; unit = $Unit }
}

function Set-UcClock {
    param([string]$Clock, [ValidateSet('start', 'stop')][string]$Status, [datetime]$At = [DateTime]::UtcNow, [string]$Detail = '')
    Write-UcEvent -Event "clock-$Status" -Kind 'clock' -Detail $(if ($Detail) { $Detail } else { "$Clock $Status" }) -Fields @{
        clock = $Clock; status = $Status; at = $At.ToUniversalTime().ToString('yyyy-MM-ddTHH:mm:ss.fffZ') }
}
