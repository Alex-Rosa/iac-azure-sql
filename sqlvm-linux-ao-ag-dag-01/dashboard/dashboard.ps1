#Requires -Version 7.5
<#
.SYNOPSIS
    Use-case dashboard: live progress or replay of a use-case run, as a web page and/or in a terminal.

.DESCRIPTION
    Reads the events a use case writes to use-cases/<uc>/runs/<rg>/<run-id>/events.jsonl (see
    use-cases/common/uc-events.ps1) and the use case's dashboard.json (phases, metrics, success
    criteria). It never runs anything on the VMs, so it can't collide with the use case's own
    Run Command calls. In live mode it only polls the VMs' power state (az vm list -d, control plane).

    Modes:
      web       Local web server (http://localhost:<port>, this machine only) + browser page that
                refreshes every -RefreshSeconds. Replay controls on the page.
      terminal  Text dashboard redrawn every -RefreshSeconds.
                Keys: t view, space pause, r restart, n/p next/previous phase, +/- speed, q quit.
      both      Web server here + the terminal dashboard in a new Terminal window.

    Live (default) follows the newest run of the stack, so a new drill shows up by itself.
    Replay (-Replay <run-id>|latest) plays a recorded run back at -Speed x; idle periods longer than
    -MaxGapSeconds are fast-forwarded (clocks and values always show the real recorded times).

.EXAMPLE
    ./dashboard.ps1                                             # asks for everything
.EXAMPLE
    ./dashboard.ps1 -UseCase uc-01 -Mode web -RefreshSeconds 3  # live, newest stack/run
.EXAMPLE
    ./dashboard.ps1 -UseCase uc-01 -Replay 20260925-015339 -Speed 5 -Mode both
#>
param(
    [string]$UseCase = '',
    # Folder under use-cases/<uc>/runs (the use case's resource group). Default: the most recently used.
    [string]$Stack = '',
    # Live: 'latest' follows the newest run; or a fixed run id.
    [string]$Run = 'latest',
    # Replay a recorded run ('latest' = newest).
    [string]$Replay = '',
    [ValidateSet('web', 'terminal', 'both')]
    [string]$Mode = 'web',
    [ValidateRange(1, 60)]
    [int]$RefreshSeconds = 3,
    [ValidateRange(0.25, 100)]
    [double]$Speed = 5,
    [ValidateRange(0, 3600)]
    [int]$MaxGapSeconds = 30,
    [ValidateSet('executive', 'technical')]
    [string]$View = 'executive',
    [ValidateRange(1024, 65535)]
    [int]$Port = 8765,
    # Live mode: seconds between VM power-state polls (0 = off).
    [ValidateRange(0, 3600)]
    [int]$PowerPollSeconds = 30,
    # Terminal mode as a client of a running web dashboard (used by -Mode both).
    [string]$Server = '',
    [switch]$NoBrowser,
    # Open the dashboard in a new Terminal window and return (used by the use cases' -Dashboard).
    [switch]$Detach
)

# Version 1 (unset variables): the state is built from JSON hashtables whose keys are optional.
Set-StrictMode -Version 1
$ErrorActionPreference = 'Stop'

$DashDir      = $PSScriptRoot
$ProjectDir   = (Resolve-Path (Join-Path $DashDir '..')).Path
$UseCasesDir  = Join-Path $ProjectDir 'use-cases'
$WebDir       = Join-Path $DashDir 'web'
$RunIdPattern = '^\d{8}-\d{6}$'
$Interactive  = $PSBoundParameters.Count -eq 0

$RegionNames = @{
    eastus = 'East US'; eastus2 = 'East US 2'; centralus = 'Central US'; northcentralus = 'North Central US'
    southcentralus = 'South Central US'; westcentralus = 'West Central US'; westus = 'West US'; westus2 = 'West US 2'
    westus3 = 'West US 3'; canadacentral = 'Canada Central'; canadaeast = 'Canada East'; brazilsouth = 'Brazil South'
    northeurope = 'North Europe'; westeurope = 'West Europe'; uksouth = 'UK South'; ukwest = 'UK West'
    francecentral = 'France Central'; germanywestcentral = 'Germany West Central'; swedencentral = 'Sweden Central'
    switzerlandnorth = 'Switzerland North'; norwayeast = 'Norway East'; italynorth = 'Italy North'; polandcentral = 'Poland Central'
    eastasia = 'East Asia'; southeastasia = 'Southeast Asia'; japaneast = 'Japan East'; japanwest = 'Japan West'
    koreacentral = 'Korea Central'; centralindia = 'Central India'; australiaeast = 'Australia East'
    australiasoutheast = 'Australia Southeast'; southafricanorth = 'South Africa North'; uaenorth = 'UAE North'
}

# ── Small helpers ──────────────────────────────────────────────────────────────
function ConvertTo-UtcDate {
    param($Value)
    if ($null -eq $Value -or "$Value" -eq '') { return $null }
    if ($Value -is [datetime]) { return $Value.ToUniversalTime() }
    return [datetime]::Parse("$Value", [cultureinfo]::InvariantCulture,
        [System.Globalization.DateTimeStyles]::AssumeUniversal -bor [System.Globalization.DateTimeStyles]::AdjustToUniversal)
}
function Format-UtcIso { param($T) if ($null -eq $T) { $null } else { $T.ToString('yyyy-MM-ddTHH:mm:ss.fffZ') } }

function Expand-Text {
    param([string]$Text, [hashtable]$Params)
    if (-not $Text) { return $Text }
    return [regex]::Replace($Text, '\{(\w+)\}', {
        param($m)
        $v = $Params[$m.Groups[1].Value]
        if ($null -eq $v) { return $m.Value }
        if ($m.Groups[1].Value -match 'Region$' -and $RegionNames.ContainsKey("$v")) { return $RegionNames["$v"] }
        return "$v"
    })
}

function Read-Line {
    param([string]$Prompt)
    $value = Read-Host $Prompt
    if ($null -eq $value) { Write-Error "No input available for: $Prompt" }
    return $value.Trim()
}

function Read-Pick {
    param([string]$Prompt, [object[]]$Items, [string[]]$Labels, [int]$Default = 1)
    Write-Host ''
    Write-Host $Prompt -ForegroundColor Cyan
    for ($i = 0; $i -lt $Labels.Count; $i++) {
        Write-Host ("  {0}) {1}{2}" -f ($i + 1), $Labels[$i], $(if ($i + 1 -eq $Default) { ' (default)' } else { '' }))
    }
    while ($true) {
        $a = Read-Line 'Select a number'
        if (-not $a) { return $Items[$Default - 1] }
        if ($a -match '^\d+$' -and [int]$a -ge 1 -and [int]$a -le $Items.Count) { return $Items[[int]$a - 1] }
        Write-Host "  '$a' is not an option." -ForegroundColor Yellow
    }
}

# ── Use cases, stacks, runs ────────────────────────────────────────────────────
function Get-DashUseCases {
    return @(Get-ChildItem $UseCasesDir -Directory -ErrorAction SilentlyContinue |
        Where-Object { $_.Name -match '^uc-\d+$' -and (Test-Path (Join-Path $_.FullName 'dashboard.json')) } |
        Sort-Object Name | ForEach-Object {
            $m = Get-Content (Join-Path $_.FullName 'dashboard.json') -Raw | ConvertFrom-Json -AsHashtable
            @{ Id = $_.Name; Dir = $_.FullName; Title = $m.title }
        })
}

function Get-RunIds {
    param([string]$StackDir)
    return @(Get-ChildItem $StackDir -Directory -ErrorAction SilentlyContinue |
        Where-Object { $_.Name -match $RunIdPattern -and (Test-Path (Join-Path $_.FullName 'events.jsonl')) } |
        Sort-Object Name | ForEach-Object { $_.Name })
}

function Get-Stacks {
    param([string]$UcDir)
    return @(Get-ChildItem (Join-Path $UcDir 'runs') -Directory -ErrorAction SilentlyContinue |
        ForEach-Object { @{ Name = $_.Name; Dir = $_.FullName; Runs = @(Get-RunIds $_.FullName) } } |
        Where-Object { $_.Runs.Count -gt 0 } | Sort-Object { $_.Runs[-1] } -Descending)
}

# One-line summary of a run for pickers: actions, RTO, RPO.
function Get-RunSummary {
    param([string]$RunDir)
    $ev = @(Read-Events (Join-Path $RunDir 'events.jsonl'))
    $actions = @($ev | Where-Object { $_.kind -eq 'action' -and $_.status -ne 'started' } | ForEach-Object { "$($_.action) $($_.status)" })
    $m = @{}
    foreach ($e in $ev) { if ($e.kind -eq 'metric') { $m[$e.metric] = $e.value } }
    $parts = @()
    if ($actions.Count) { $parts += ($actions -join ', ') } else { $parts += "$($ev.Count) events" }
    if ($m.ContainsKey('rto')) { $parts += "RTO $($m.rto) s" }
    if ($m.ContainsKey('rpoTx')) { $parts += "RPO $($m.rpoTx) tx" }
    return $parts -join ' · '
}

# ── Events ─────────────────────────────────────────────────────────────────────
$script:EventCache = @{}
function Read-Events {
    param([string]$File)
    if (-not (Test-Path $File)) { return @() }
    $info = Get-Item $File
    $key = "$($info.Length)|$($info.LastWriteTimeUtc.Ticks)"
    $c = $script:EventCache[$File]
    if ($c -and $c.Key -eq $key) { return $c.Events }
    $events = [System.Collections.Generic.List[object]]::new()
    $i = 0
    foreach ($line in [System.IO.File]::ReadAllLines($File)) {
        if (-not $line.Trim()) { continue }
        try { $e = $line | ConvertFrom-Json -AsHashtable -DateKind String } catch { continue }   # a line being written
        if (-not $e.ContainsKey('kind')) { $e.kind = 'log' }
        $e.t = ConvertTo-UtcDate $e.utc
        $e.i = $i++
        $events.Add($e)
    }
    # Same timestamp: keep file order.
    $sorted = @($events | Sort-Object { $_.t }, { $_.i })
    $script:EventCache[$File] = @{ Key = $key; Events = $sorted }
    return $sorted
}

# ── Reducer: events (up to $Now) -> dashboard state ───────────────────────────
function Get-DashState {
    param([hashtable]$Manifest, [object[]]$Events, [datetime]$Now, [hashtable]$Meta, [hashtable]$Power)

    $nodes = [ordered]@{}; $groups = [ordered]@{}; $links = [ordered]@{}; $params = @{}; $regions = @()
    $phases = @{}; $metrics = @{}; $clocks = @{}; $log = [System.Collections.Generic.List[object]]::new()
    $action = $null; $lastT = $null

    $phaseLabel = @{}
    foreach ($s in $Manifest.stages) { foreach ($p in $s.phases) { $phaseLabel[$p.id] = $p.label } }
    $execMetric = @{}; $metricLabel = @{}; $clockLabel = @{}
    foreach ($m in $Manifest.metrics) { $execMetric[$m.id] = [bool]$m.exec; $metricLabel[$m.id] = $m.label }
    foreach ($c in @($Manifest.clocks)) { $clockLabel[$c.id] = $c.label }

    foreach ($e in $Events) {
        if ($e.t -gt $Now) { break }
        $lastT = $e.t
        $tech = $false; $text = $e.detail; $icon = ''
        switch ($e.kind) {
            'topology' {
                $tech = $true
                foreach ($n in $e.nodes) {
                    if ($nodes.Contains($n.id)) { foreach ($k in @('label', 'name', 'vm', 'rg', 'region', 'ip', 'group', 'stack')) { $nodes[$n.id][$k] = $n[$k] } }
                    else { $nodes[$n.id] = @{ id = $n.id; label = $n.label; name = $n.name; vm = $n.vm; rg = $n.rg; region = $n.region; ip = $n.ip
                                              group = $n.group; stack = $n.stack; role = $n.role; global = [bool]$n.global; power = 'unknown'; powerT = $null; fenced = $false } }
                }
                foreach ($g in $e.groups) { $groups[$g.id] = $g }
                foreach ($l in $e.links) {
                    if ($links.Contains($l.id)) { $links[$l.id].label = $l.label; $links[$l.id].kind = $l.kind }
                    else { $links[$l.id] = @{ id = $l.id; kind = $l.kind; from = $l.from; to = $l.to; label = $l.label; state = $l.state } }
                }
                if ($e.params) { foreach ($k in $e.params.Keys) { $params[$k] = $e.params[$k] } }
                if ($e.regions) { $regions = @($e.regions) }
            }
            'action' {
                $action = @{ name = $e.action; status = $e.status; t = $e.t; detail = $e.detail }
                $icon = @{ started = '▶'; completed = '✔'; failed = '✖' }[$e.status]
                $text = "Action $($e.action) $($e.status)$(if ($e.status -eq 'failed' -and $e.detail) { ": $($e.detail)" })"
            }
            'phase' {
                $p = $phases[$e.phase]
                if (-not $p) { $p = @{ status = 'pending'; start = $null; end = $null; detail = '' }; $phases[$e.phase] = $p }
                $p.status = $e.status
                if ($e.status -eq 'running') { $p.start = $e.t; $p.end = $null } else { if (-not $p.start) { $p.start = $e.t }; $p.end = $e.t }
                $defaultDetail = "$($e.phase) $($e.status)"
                if ($e.detail -and $e.detail -ne $defaultDetail) { $p.detail = $e.detail }
                $label = if ($phaseLabel.ContainsKey($e.phase)) { $phaseLabel[$e.phase] } else { $e.phase }
                $icon = @{ running = '▶'; done = '✔'; failed = '✖'; skipped = '↷' }[$e.status]
                $text = switch ($e.status) {
                    'running' { "$label started$(if ($e.detail -and $e.detail -ne $defaultDetail) { " - $($e.detail)" })" }
                    'skipped' { "$label skipped$(if ($e.detail -ne $defaultDetail) { " - $($e.detail)" })" }
                    default   { "$label$(if ($e.detail -and $e.detail -ne $defaultDetail) { ": $($e.detail)" } else { " $($e.status)" })" }
                }
            }
            'node' {
                $tech = $true
                $n = $nodes[$e.node]
                if ($n) {
                    if ($e.ContainsKey('power')) { $n.power = $e.power; $n.powerT = $e.t }
                    if ($e.ContainsKey('role')) { $n.role = $e.role }
                    if ($e.ContainsKey('global')) { $n.global = [bool]$e.global }
                    if ($e.ContainsKey('fenced')) { $n.fenced = [bool]$e.fenced }
                }
            }
            'link' {
                $tech = $true
                $l = $links[$e.link]
                if ($l) {
                    $l.state = $e.state
                    if ($e.ContainsKey('from')) { $l.from = $e.from }
                    if ($e.ContainsKey('to')) { $l.to = $e.to }
                }
            }
            'metric' {
                $metrics[$e.metric] = @{ value = $e.value; unit = $e.unit; detail = $e.detail; t = $e.t }
                $tech = -not $execMetric[$e.metric]
                $icon = '■'
                $label = if ($metricLabel.ContainsKey($e.metric)) { $metricLabel[$e.metric] } else { $e.metric }
                $val = if ($e.value -is [bool]) { if ($e.value) { 'yes' } else { 'no' } } else { "$($e.value)$(if ($e.unit) { " $($e.unit)" })" }
                $text = "$($label): $val$(if ($e.detail -and $e.detail -notlike "$($e.metric) = *") { " - $($e.detail)" })"
            }
            'clock' {
                $c = $clocks[$e.clock]
                if (-not $c) { $c = @{ start = $null; stop = $null }; $clocks[$e.clock] = $c }
                $at = ConvertTo-UtcDate $e.at
                if ($e.status -eq 'start') { $c.start = $at; $c.stop = $null } else { $c.stop = $at }
                $icon = '⏱'
                $label = if ($clockLabel.ContainsKey($e.clock)) { $clockLabel[$e.clock] } else { $e.clock }
                $text = "$label $(if ($e.status -eq 'start') { 'started' } else { 'stopped' })$(if ($e.detail) { " - $($e.detail)" })"
            }
            default {
                $tech = -not ($e.ContainsKey('level') -and $e.level -eq 'error')
            }
        }
        $level = if ($e.ContainsKey('level')) { $e.level } else { 'info' }
        $log.Add(@{ utc = $e.utc; event = $e.event; kind = $e.kind; text = $text; icon = $icon; level = $level; tech = $tech })
    }

    # Live power state (az vm list -d) wins when it is newer than the last event about that node.
    if ($Power) {
        foreach ($n in $nodes.Values) {
            $p = $Power.vms[$n.vm]
            if ($p -and (-not $n.powerT -or $Power.t -gt $n.powerT)) { $n.power = $p; $n.powerLive = $true }
        }
    }

    $running = $null
    $stages = foreach ($s in $Manifest.stages) {
        $ps = foreach ($p in $s.phases) {
            $st = $phases[$p.id]
            $status = if ($st) { $st.status } else { 'pending' }
            if ($status -eq 'running') { $running = @{ phase = $p; stage = $s } }
            $dur = $null
            if ($st -and $st.start) { $end = if ($st.end) { $st.end } else { $Now }; $dur = [math]::Round(($end - $st.start).TotalSeconds, 1) }
            [ordered]@{ id = $p.id; label = $p.label; explain = (Expand-Text $p.explain $params); status = $status
                        startUtc = $(if ($st) { Format-UtcIso $st.start }); endUtc = $(if ($st) { Format-UtcIso $st.end }); seconds = $dur
                        detail = $(if ($st) { $st.detail } else { '' }) }
        }
        $ps = @($ps)
        $statuses = @($ps | ForEach-Object { $_.status })
        $stageStatus = if ($statuses -contains 'running') { 'running' } elseif ($statuses -contains 'failed') { 'failed' }
            elseif (@($statuses | Where-Object { $_ -ne 'pending' }).Count -eq 0) { 'pending' }
            elseif (@($statuses | Where-Object { $_ -eq 'pending' }).Count -eq 0) { 'done' } else { 'partial' }
        [ordered]@{ id = $s.id; label = (Expand-Text $s.label $params); status = $stageStatus; phases = $ps }
    }

    $actionActive = $action -and $action.status -eq 'started'
    $narration = @{ text = ''; tone = 'idle' }
    if ($running) {
        $narration = @{ text = (Expand-Text $running.phase.explain $params); tone = 'running'; phase = $running.phase.label; stage = (Expand-Text $running.stage.label $params) }
    } elseif ($action) {
        $narration = switch ($action.status) {
            'failed'    { @{ text = "$($action.name) stopped: $($action.detail)"; tone = 'failed' } }
            'completed' { @{ text = "$($action.name) completed"; tone = 'done' } }
            default     { @{ text = "$($action.name) in progress"; tone = 'running' } }
        }
    } elseif (-not $Events.Count) {
        $narration = @{ text = 'Waiting for the first run of this use case'; tone = 'idle' }
    }

    $metricList = foreach ($m in $Manifest.metrics) {
        $v = $metrics[$m.id]
        $status = 'pending'
        if ($v) {
            $status = 'info'
            if ($m.ContainsKey('target') -and $null -ne $m.target -and $v.value -is [ValueType] -and $v.value -isnot [bool]) {
                $status = if ([double]$v.value -le [double]$m.target) { 'pass' } else { 'fail' }
            }
        }
        # Set-UcMetric's default detail ("<id> = <value>") adds nothing next to the value.
        $detail = if ($v -and $v.detail -and $v.detail -notlike "$($m.id) = *") { $v.detail }
        [ordered]@{ id = $m.id; label = $m.label; unit = $m.unit; exec = [bool]$m.exec; explain = (Expand-Text $m.explain $params)
                    target = $m.target; value = $(if ($v) { $v.value }); detail = $detail; status = $status }
    }

    $criteria = foreach ($c in $Manifest.criteria) {
        $v = $metrics[$c.metric]
        $status = 'pending'
        if ($v) {
            if ("$($v.value)" -eq 'n/a') { $status = 'n/a' }
            else {
                $ok = switch ($c.op) {
                    'exists' { $true }
                    'eq'     { "$($v.value)" -eq "$($c.value)" }
                    'le'     { [double]$v.value -le [double]$c.value }
                    'ge'     { [double]$v.value -ge [double]$c.value }
                    default  { $false }
                }
                $status = if ($ok) { 'pass' } else { 'fail' }
            }
        }
        [ordered]@{ id = $c.id; label = (Expand-Text $c.label $params); status = $status; detail = $(if ($v) { $v.detail }) }
    }

    $clockList = foreach ($c in @($Manifest.clocks)) {
        $v = $clocks[$c.id]
        $secs = $null; $state = 'idle'
        if ($v -and $v.start -and $v.start -le $Now) {
            $end = if ($v.stop) { $v.stop } else { $Now }
            $secs = [math]::Max(0.0, [math]::Round(($end - $v.start).TotalSeconds, 1))
            $state = if ($v.stop) { 'stopped' } else { 'running' }
        }
        [ordered]@{ id = $c.id; label = $c.label; explain = (Expand-Text $c.explain $params); state = $state; seconds = $secs
                    startUtc = $(if ($v) { Format-UtcIso $v.start }); stopUtc = $(if ($v) { Format-UtcIso $v.stop }) }
    }

    # Regions: down when every node there is off, recovering while one is starting.
    $regionList = foreach ($r in $regions) {
        $rn = @($nodes.Values | Where-Object { $_.region -eq $r })
        $off = @($rn | Where-Object { $_.power -in @('stopped', 'stopping', 'deallocated', 'deallocating') })
        $state = if ($rn.Count -and $off.Count -eq $rn.Count) { 'down' } elseif (@($rn | Where-Object { $_.power -eq 'starting' }).Count) { 'recovering' } else { 'up' }
        $role = if ($r -eq $params.failedRegion) { 'primary region' } elseif ($r -eq $params.drRegion) { 'DR region' } else { '' }
        [ordered]@{ id = $r; label = $(if ($RegionNames.ContainsKey($r)) { $RegionNames[$r] } else { $r }); role = $role; state = $state }
    }

    $nodeList = foreach ($n in $nodes.Values) {
        [ordered]@{ id = $n.id; label = $n.label; name = $n.name; vm = $n.vm; region = $n.region; ip = $n.ip; group = $n.group
                    groupLabel = $(if ($groups.Contains($n.group)) { $groups[$n.group].label } else { $n.group }); stack = $n.stack
                    role = $n.role; global = $n.global; power = $n.power; fenced = $n.fenced; powerLive = [bool]($n.ContainsKey('powerLive') -and $n.powerLive) }
    }
    # Where the application's transactions can go: the running global primary.
    $writer = @($nodes.Values | Where-Object { $_.global -and $_.role -eq 'PRIMARY' -and $_.power -eq 'running' }) | Select-Object -First 1

    $logArr = $log.ToArray()
    $Meta.lastEventUtc = Format-UtcIso $lastT
    $Meta.nowUtc = Format-UtcIso $Now
    $Meta.actionActive = [bool]$actionActive
    $Meta.action = $(if ($action) { @{ name = $action.name; status = $action.status } })
    return [ordered]@{
        meta = $Meta; title = $Manifest.title; subtitle = $Manifest.subtitle; params = $params
        narration = $narration; regions = @($regionList); groups = @($groups.Values); nodes = @($nodeList); links = @($links.Values)
        writer = $(if ($writer) { $writer.id }); stages = @($stages); metrics = @($metricList); clocks = @($clockList); criteria = @($criteria)
        log = @($logArr | Select-Object -Last 60)
    }
}

# ── Replay clock ───────────────────────────────────────────────────────────────
# Playback position is in "compressed seconds": every gap between events longer than MaxGap is
# shortened to MaxGap. Values and clocks keep the real recorded times.
function New-ReplayClock {
    param([object[]]$Events, [double]$Speed, [int]$MaxGap)
    $times = @($Events | ForEach-Object { $_.t } | Sort-Object -Unique)
    $times = @($times[0].AddSeconds(-3)) + $times + @($times[-1].AddSeconds(3))
    $cum = [System.Collections.Generic.List[double]]::new(); $cum.Add(0)
    $gaps = [System.Collections.Generic.List[double]]::new(); $comp = [System.Collections.Generic.List[double]]::new()
    for ($i = 0; $i -lt $times.Count - 1; $i++) {
        $g = ($times[$i + 1] - $times[$i]).TotalSeconds
        $c = if ($MaxGap -gt 0) { [math]::Min($g, [double]$MaxGap) } else { $g }
        $gaps.Add($g); $comp.Add($c); $cum.Add($cum[$cum.Count - 1] + $c)
    }
    $phaseTimes = @($Events | Where-Object { $_.kind -eq 'phase' -and $_.status -eq 'running' })
    return @{ Times = $times; Cum = $cum; Gaps = $gaps; Comp = $comp; Total = $cum[$cum.Count - 1]; Pos = 0.0
              Speed = $Speed; Paused = $false; Watch = [System.Diagnostics.Stopwatch]::StartNew(); PhaseStarts = $phaseTimes }
}

function Update-Replay {
    param($R)
    $elapsed = $R.Watch.Elapsed.TotalSeconds; $R.Watch.Restart()
    if (-not $R.Paused) { $R.Pos = [math]::Min($R.Total, $R.Pos + $elapsed * $R.Speed) }
}

function Get-ReplayTime {
    param($R, [double]$Pos)
    for ($i = 0; $i -lt $R.Comp.Count; $i++) {
        if ($Pos -le $R.Cum[$i + 1] -or $i -eq $R.Comp.Count - 1) {
            $ratio = if ($R.Comp[$i] -gt 0) { $R.Gaps[$i] / $R.Comp[$i] } else { 1 }
            return @{ T = $R.Times[$i].AddSeconds([math]::Min($R.Gaps[$i], ($Pos - $R.Cum[$i]) * $ratio)); FastForward = [math]::Round($ratio, 1) }
        }
    }
}

function Get-ReplayPos {
    param($R, [datetime]$T)
    for ($i = 0; $i -lt $R.Comp.Count; $i++) {
        if ($T -le $R.Times[$i + 1]) {
            $ratio = if ($R.Gaps[$i] -gt 0) { $R.Comp[$i] / $R.Gaps[$i] } else { 0 }
            return $R.Cum[$i] + [math]::Max(0.0, ($T - $R.Times[$i]).TotalSeconds) * $ratio
        }
    }
    return $R.Total
}

function Invoke-ReplayCommand {
    param($R, [string]$Cmd, [string]$Value)
    Update-Replay $R
    $now = (Get-ReplayTime $R $R.Pos).T
    switch ($Cmd) {
        'toggle'  { $R.Paused = -not $R.Paused; if (-not $R.Paused -and $R.Pos -ge $R.Total) { $R.Pos = 0 } }
        'pause'   { $R.Paused = $true }
        'play'    { $R.Paused = $false; if ($R.Pos -ge $R.Total) { $R.Pos = 0 } }
        'restart' { $R.Pos = 0 }
        'speed'   { $v = $Value -as [double]; if ($null -ne $v) { $R.Speed = [math]::Min(100.0, [math]::Max(0.25, $v)) } }
        'faster'  { $R.Speed = [math]::Min(100.0, $R.Speed * 2) }
        'slower'  { $R.Speed = [math]::Max(0.25, $R.Speed / 2) }
        'seek'    { $v = $Value -as [double]; if ($null -ne $v) { $R.Pos = [math]::Min(1.0, [math]::Max(0.0, $v)) * $R.Total } }
        'next'    {
            $next = @($R.PhaseStarts | Where-Object { $_.t -gt $now.AddSeconds(0.5) }) | Select-Object -First 1
            $R.Pos = if ($next) { Get-ReplayPos $R $next.t.AddSeconds(-0.5) } else { $R.Total }
        }
        'prev'    {
            $prev = @($R.PhaseStarts | Where-Object { $_.t -lt $now.AddSeconds(-2) }) | Select-Object -Last 1
            $R.Pos = if ($prev) { Get-ReplayPos $R $prev.t.AddSeconds(-0.5) } else { 0 }
        }
    }
}

# ── Dashboard context: what is shown (live run or replay) ─────────────────────
function New-DashContext {
    $uc = Get-DashUseCases | Where-Object { $_.Id -eq $UseCase } | Select-Object -First 1
    if (-not $uc) { Write-Error "Use case '$UseCase' has no dashboard.json under $UseCasesDir." }
    $manifest = Get-Content (Join-Path $uc.Dir 'dashboard.json') -Raw | ConvertFrom-Json -AsHashtable
    $ctx = @{ UseCase = $uc; Manifest = $manifest; StackDir = (Join-Path $uc.Dir 'runs' $Stack); Mode = 'live'
              FixedRun = $(if ($Run -ne 'latest') { $Run }); Replay = $null; ReplayRun = $null; Power = $null; PowerJob = $null; PowerNext = [datetime]::MinValue }
    if ($Replay) {
        $runId = if ($Replay -eq 'latest') { @(Get-RunIds $ctx.StackDir)[-1] } else { $Replay }
        $file = Join-Path $ctx.StackDir $runId 'events.jsonl'
        if (-not $runId -or -not (Test-Path $file)) { Write-Error "Run '$Replay' not found in $($ctx.StackDir)." }
        $events = @(Read-Events $file)
        if ($events.Count -eq 0) { Write-Error "Run $runId has no events." }
        $ctx.Mode = 'replay'; $ctx.ReplayRun = $runId; $ctx.ReplayEvents = $events
        $ctx.Replay = New-ReplayClock -Events $events -Speed $Speed -MaxGap $MaxGapSeconds
    }
    return $ctx
}

function Get-CurrentRunId {
    param($Ctx)
    if ($Ctx.Mode -eq 'replay') { return $Ctx.ReplayRun }
    if ($Ctx.FixedRun) { return $Ctx.FixedRun }
    return @(Get-RunIds $Ctx.StackDir)[-1]
}

# Live power state: az vm list -d per resource group, in a background thread (never blocks rendering).
function Update-PowerPoll {
    param($Ctx, [object[]]$Nodes)
    if ($Ctx.Mode -ne 'live' -or $PowerPollSeconds -le 0) { return }
    if ($Ctx.PowerJob) {
        if ($Ctx.PowerJob.State -notin @('Completed', 'Failed', 'Stopped')) { return }
        $res = @(Receive-Job $Ctx.PowerJob -ErrorAction SilentlyContinue)
        Remove-Job $Ctx.PowerJob -Force
        $Ctx.PowerJob = $null
        $vms = @{}
        foreach ($r in $res) { if ($r -and $r.vm) { $vms[$r.vm] = ("$($r.power)" -replace '^VM ', '') } }
        if ($vms.Count) { $Ctx.Power = @{ t = [datetime]::UtcNow; vms = $vms } }
    }
    if (-not $Nodes -or [datetime]::UtcNow -lt $Ctx.PowerNext) { return }
    $Ctx.PowerNext = [datetime]::UtcNow.AddSeconds($PowerPollSeconds)
    $rgs = @($Nodes | ForEach-Object { $_.rg } | Where-Object { $_ } | Select-Object -Unique)
    if (-not $rgs.Count -or -not (Get-Command az -ErrorAction SilentlyContinue)) { return }
    $Ctx.PowerJob = Start-ThreadJob -ArgumentList (, $rgs) -ScriptBlock {
        param($rgs)
        foreach ($rg in $rgs) {
            $json = az vm list -d -g $rg --query '[].{vm:name, power:powerState}' -o json 2>$null
            if ($LASTEXITCODE -eq 0 -and $json) { ($json | ConvertFrom-Json) | ForEach-Object { @{ vm = $_.vm; power = $_.power } } }
        }
    }
}

function Get-ContextState {
    param($Ctx)
    $meta = [ordered]@{ useCase = $Ctx.UseCase.Id; stack = $Stack; mode = $Ctx.Mode; refreshSeconds = $RefreshSeconds; view = $View }
    if ($Ctx.Mode -eq 'replay') {
        $R = $Ctx.Replay
        Update-Replay $R
        $rt = Get-ReplayTime $R $R.Pos
        $events = $Ctx.ReplayEvents
        $markers = @(foreach ($p in $R.PhaseStarts) { @{ frac = [math]::Round((Get-ReplayPos $R $p.t) / [math]::Max(1.0, $R.Total), 4); phase = $p.phase } })
        $meta.runId = $Ctx.ReplayRun
        $meta.replay = [ordered]@{ speed = $R.Speed; paused = $R.Paused; finished = ($R.Pos -ge $R.Total)
            progress = [math]::Round($R.Pos / [math]::Max(1.0, $R.Total), 4); positionSeconds = [math]::Round($R.Pos, 1); totalSeconds = [math]::Round($R.Total, 1)
            fastForward = $(if (-not $R.Paused -and $R.Pos -lt $R.Total) { $rt.FastForward } else { 1 })
            recordedSeconds = [math]::Round(($R.Times[-1] - $R.Times[0]).TotalSeconds); startUtc = (Format-UtcIso $R.Times[1]); markers = $markers }
        return Get-DashState -Manifest $Ctx.Manifest -Events $events -Now $rt.T -Meta $meta -Power $null
    }
    $runId = Get-CurrentRunId $Ctx
    $meta.runId = $runId
    $events = if ($runId) { @(Read-Events (Join-Path $Ctx.StackDir $runId 'events.jsonl')) } else { @() }
    $state = Get-DashState -Manifest $Ctx.Manifest -Events $events -Now ([datetime]::UtcNow) -Meta $meta -Power $Ctx.Power
    $topo = @($events | Where-Object { $_.kind -eq 'topology' }) | Select-Object -Last 1
    Update-PowerPoll $Ctx $(if ($topo) { @($topo.nodes) } else { @() })
    if ($Ctx.Power) { $state.meta.powerPolledUtc = Format-UtcIso $Ctx.Power.t }
    return $state
}

# ── Terminal renderer ──────────────────────────────────────────────────────────
$AnsiEsc = [char]27
$Ansi = @{
    reset = "$AnsiEsc[0m"; bold = "$AnsiEsc[1m"; dim = "$AnsiEsc[2m"; red = "$AnsiEsc[31m"; green = "$AnsiEsc[32m"; yellow = "$AnsiEsc[33m"; blue = "$AnsiEsc[34m"
    magenta = "$AnsiEsc[35m"; cyan = "$AnsiEsc[36m"; white = "$AnsiEsc[97m"; gray = "$AnsiEsc[90m"; bgRed = "$AnsiEsc[41m"; bgBlue = "$AnsiEsc[44m"; bgGreen = "$AnsiEsc[42m"; bgYellow = "$AnsiEsc[43m"
}
function Get-VisibleLength { param([string]$S) ($S -replace "$AnsiEsc\[[0-9;]*m", '').Length }
function Format-Pad {
    param([string]$S, [int]$Width)
    $len = Get-VisibleLength $S
    if ($len -le $Width) { return $S + (' ' * ($Width - $len)) }
    $plain = $S -replace "$AnsiEsc\[[0-9;]*m", ''
    return $plain.Substring(0, [math]::Max(0, $Width - 1)) + '…'
}
function Format-Seconds {
    param($S)
    if ($null -eq $S) { return '--:--' }
    $ts = [timespan]::FromSeconds([double]$S)
    if ($ts.TotalHours -ge 1) { return '{0}:{1:mm\:ss}' -f [int][math]::Floor($ts.TotalHours), $ts }
    return $ts.ToString('mm\:ss')
}
function Get-StatusColor {
    param([string]$Status)
    switch ($Status) { 'done' { $Ansi.green } 'pass' { $Ansi.green } 'running' { $Ansi.cyan } 'failed' { $Ansi.red } 'fail' { $Ansi.red } 'skipped' { $Ansi.gray } 'n/a' { $Ansi.gray } default { $Ansi.gray } }
}
function Get-StatusIcon {
    param([string]$Status)
    switch ($Status) { 'done' { '✔' } 'pass' { '✔' } 'running' { '▶' } 'failed' { '✖' } 'fail' { '✖' } 'skipped' { '↷' } 'n/a' { '–' } default { '○' } }
}
function Get-LinkStyle {
    param([string]$State)
    switch ($State) {
        'healthy'           { @{ c = $Ansi.green;  t = '━━━' } }
        'synchronizing'     { @{ c = $Ansi.green;  t = '━▶━' } }
        'synchronized'      { @{ c = $Ansi.green;  t = '━▶━' } }
        'seeding'           { @{ c = $Ansi.yellow; t = '╍▶╍' } }
        'suspended'         { @{ c = $Ansi.yellow; t = '╍ ╍' } }
        'not-synchronizing' { @{ c = $Ansi.red;    t = '╳╳╳' } }
        'down'              { @{ c = $Ansi.red;    t = '╳ ╳' } }
        'removed'           { @{ c = $Ansi.gray;   t = '   ' } }
        default             { @{ c = $Ansi.gray;   t = '···' } }
    }
}

function Get-TerminalFrame {
    param($S, [string]$ViewMode, [int]$Width, [int]$Height)
    $tech = $ViewMode -eq 'technical'
    $frameLines = [System.Collections.Generic.List[string]]::new()
    $W = [math]::Max(80, $Width)
    $rule = "$($Ansi.gray)$('─' * $W)$($Ansi.reset)"

    # Header
    $badge = if ($S.meta.mode -eq 'replay') {
        $r = $S.meta.replay
        "$($Ansi.bgBlue)$($Ansi.white) REPLAY ×$($r.speed)$(if ($r.paused) { ' ❚❚' } elseif ($r.finished) { ' ■' }) $($Ansi.reset)"
    } else { "$($Ansi.bgRed)$($Ansi.white) ● LIVE $($Ansi.reset)" }
    $time = if ($S.meta.nowUtc) { ([datetime]::Parse($S.meta.nowUtc, [cultureinfo]::InvariantCulture, [System.Globalization.DateTimeStyles]::AdjustToUniversal)).ToString('HH:mm:ss') + 'Z' } else { '' }
    $left = "$($Ansi.bold)$($S.title)$($Ansi.reset)"
    $right = "$badge  run $($S.meta.runId)  $time  $($Ansi.gray)[$ViewMode]$($Ansi.reset)"
    $frameLines.Add((Format-Pad $left ($W - (Get-VisibleLength $right))) + $right)
    $frameLines.Add("$($Ansi.gray)$($S.subtitle)$(if ($tech) { "  ·  stack $($S.meta.stack)" })$($Ansi.reset)")
    $frameLines.Add($rule)

    # Narration
    $tone = @{ running = $Ansi.cyan; done = $Ansi.green; failed = $Ansi.red; idle = $Ansi.gray }[$S.narration.tone]
    $prefix = if ($S.narration.ContainsKey('phase') -and $S.narration.phase) { "$($S.narration.phase): " } else { '' }
    $frameLines.Add("$tone$($Ansi.bold) ▶ $prefix$($Ansi.reset)$tone$($S.narration.text)$($Ansi.reset)")
    $frameLines.Add('')

    # Topology: one column per region
    $regions = @($S.regions)
    if ($regions.Count) {
        $colW = [math]::Floor(($W - 2) / $regions.Count)
        $cols = foreach ($r in $regions) {
            $lines = [System.Collections.Generic.List[string]]::new()
            $rc = switch ($r.state) { 'down' { $Ansi.red } 'recovering' { $Ansi.yellow } default { $Ansi.green } }
            $lines.Add("$($Ansi.bold)$($r.label.ToUpper())$($Ansi.reset) $($Ansi.gray)$($r.role)$($Ansi.reset) $rc$(switch ($r.state) { 'down' { '■ DOWN' } 'recovering' { '▲ RECOVERING' } default { '● UP' } })$($Ansi.reset)")
            foreach ($n in @($S.nodes | Where-Object { $_.region -eq $r.id })) {
                $pc = switch ($n.power) { 'running' { $Ansi.green } 'starting' { $Ansi.yellow } 'stopping' { $Ansi.yellow } 'unknown' { $Ansi.gray } default { $Ansi.red } }
                $roleC = switch -Regex ($n.role) { '^PRIMARY$' { $Ansi.cyan } 'FORWARDER' { $Ansi.magenta } 'STALE|REMOVED|OUT OF AG' { $Ansi.red } 'SEEDING' { $Ansi.yellow } default { $Ansi.white } }
                $star = if ($n.global -and $n.role -eq 'PRIMARY') { " $($Ansi.yellow)★$($Ansi.reset)" } else { '' }
                $fence = if ($n.fenced) { " $($Ansi.bgYellow)$(if ($tech) { ' FENCED ' } else { ' 🔒 ' })$($Ansi.reset)" } else { '' }
                $power = if ($n.power -ne 'running') { " $pc($($n.power))$($Ansi.reset)" } else { '' }
                $lines.Add("  $pc●$($Ansi.reset) $($Ansi.bold)$($n.label)$($Ansi.reset) $($Ansi.gray)$($n.groupLabel)$($Ansi.reset) $roleC$($n.role)$($Ansi.reset)$star$fence$power")
                if ($tech) { $lines.Add("    $($Ansi.gray)$($n.name) · $($n.ip)$($Ansi.reset)") }
            }
            , $lines
        }
        $rows = ($cols | ForEach-Object { $_.Count } | Measure-Object -Maximum).Maximum
        for ($i = 0; $i -lt $rows; $i++) {
            $line = ''
            foreach ($col in $cols) { $line += Format-Pad $(if ($i -lt $col.Count) { $col[$i] } else { '' }) $colW }
            $frameLines.Add(" $line")
        }
        $frameLines.Add('')
        $byId = @{}; foreach ($n in $S.nodes) { $byId[$n.id] = $n }
        $app = if ($S.writer) { "$($Ansi.green)App ━▶ $($byId[$S.writer].label)$($Ansi.reset)" } else { "$($Ansi.red)App ╳ no writable primary$($Ansi.reset)" }
        $linkParts = foreach ($l in $S.links) {
            $st = Get-LinkStyle $l.state
            $from = if ($byId.ContainsKey($l.from)) { $byId[$l.from].label } else { $l.from }
            $to = if ($byId.ContainsKey($l.to)) { $byId[$l.to].label } else { $l.to }
            "$($Ansi.gray)$($l.label)$($Ansi.reset) $from $($st.c)$($st.t)$($Ansi.reset) $to $($st.c)$($l.state)$($Ansi.reset)"
        }
        $frameLines.Add(" $app")
        $line = ' '
        foreach ($p in $linkParts) {
            if ((Get-VisibleLength ($line + $p)) -gt $W - 2) { $frameLines.Add($line); $line = ' ' }
            $line += $p + '   '
        }
        if ($line.Trim()) { $frameLines.Add($line) }
        $frameLines.Add($rule)
    }

    # KPIs
    $kpi = @()
    foreach ($c in $S.clocks) {
        $cc = switch ($c.state) { 'running' { $Ansi.red } 'stopped' { $Ansi.green } default { $Ansi.gray } }
        $kpi += "$($Ansi.bold)$($c.label.ToUpper())$($Ansi.reset) $cc$($Ansi.bold)$(Format-Seconds $c.seconds)$($Ansi.reset)$(if ($c.state -eq 'running') { " $($Ansi.red)●$($Ansi.reset)" })"
    }
    foreach ($m in @($S.metrics | Where-Object { $tech -or $_.exec })) {
        $mc = switch ($m.status) { 'pass' { $Ansi.green } 'fail' { $Ansi.red } 'info' { $Ansi.white } default { $Ansi.gray } }
        $val = if ($null -eq $m.value) { '—' } else { "$($m.value)$(if ($m.unit) { " $($m.unit)" })" }
        $kpi += "$($Ansi.gray)$($m.label)$($Ansi.reset) $mc$($Ansi.bold)$val$($Ansi.reset)"
    }
    $line = ' '
    foreach ($k in $kpi) {
        if ((Get-VisibleLength ($line + $k)) -gt $W - 2) { $frameLines.Add($line); $line = ' ' }
        $line += $k + '    '
    }
    $frameLines.Add($line)
    $frameLines.Add($rule)

    # Stages
    $labelW = [math]::Max(12, (@($S.stages | ForEach-Object { $_.label.Length }) | Measure-Object -Maximum).Maximum + 1)
    foreach ($st in $S.stages) {
        $sc = Get-StatusColor $st.status
        $line = " $sc$($Ansi.bold)$(Format-Pad $st.label $labelW)$($Ansi.reset)"
        $indent = ' ' * ($labelW + 1)
        foreach ($p in $st.phases) {
            $pc = Get-StatusColor $p.status
            $dur = if ($tech -and $null -ne $p.seconds) { " $($Ansi.gray)$([math]::Round($p.seconds))s$($Ansi.reset)" } else { '' }
            $item = "$pc$(Get-StatusIcon $p.status) $($p.label)$($Ansi.reset)$dur  "
            if ((Get-VisibleLength ($line + $item)) -gt $W - 1) { $frameLines.Add($line); $line = " $indent" }
            $line += $item
        }
        $frameLines.Add($line)
    }
    $frameLines.Add($rule)

    # Success criteria
    $frameLines.Add(" $($Ansi.bold)Success criteria$($Ansi.reset)")
    foreach ($c in $S.criteria) { $frameLines.Add("  $(Get-StatusColor $c.status)$(Get-StatusIcon $c.status)$($Ansi.reset) $($c.label)$(if ($tech -and $c.detail) { " $($Ansi.gray)- $($c.detail)$($Ansi.reset)" })") }
    $frameLines.Add($rule)

    # Footer (replay bar + keys) is kept; the log fills what's left.
    $footer = [System.Collections.Generic.List[string]]::new()
    if ($S.meta.mode -eq 'replay') {
        $r = $S.meta.replay
        $barW = $W - 30
        $filled = [int][math]::Round($barW * $r.progress)
        $ff = if ($r.fastForward -gt 1.05) { " $($Ansi.yellow)⏩ ×$($r.fastForward)$($Ansi.reset)" } else { '' }
        $footer.Add(" $($Ansi.cyan)$('█' * $filled)$($Ansi.gray)$('░' * ($barW - $filled))$($Ansi.reset) $([math]::Round($r.progress * 100))%$ff")
    }
    $keys = if ($S.meta.mode -eq 'replay') { 't view · space pause · r restart · n/p next/prev phase · +/- speed · q quit' } else { 't view · q quit' }
    $footer.Add(" $($Ansi.gray)$keys$($Ansi.reset)")

    $logRoom = [math]::Max(3, $Height - $frameLines.Count - $footer.Count - 1)
    $frameLines.Add(" $($Ansi.bold)Events$($Ansi.reset)")
    $entries = @($S.log | Where-Object { $tech -or -not $_.tech }) | Select-Object -Last ($logRoom - 1)
    foreach ($e in $entries) {
        $t = if ($e.utc) { ([datetime]::Parse($e.utc, [cultureinfo]::InvariantCulture, [System.Globalization.DateTimeStyles]::AdjustToUniversal)).ToString('HH:mm:ss') } else { '' }
        $ec = if ($e.level -eq 'error') { $Ansi.red } elseif ($e.kind -eq 'phase') { $Ansi.white } else { $Ansi.gray }
        $frameLines.Add((Format-Pad "  $($Ansi.gray)$t$($Ansi.reset) $ec$(if ($e.icon) { "$($e.icon) " })$($e.text)$($Ansi.reset)" ($W - 1)))
    }
    foreach ($f in $footer) { $frameLines.Add($f) }
    return $frameLines
}

function Invoke-TerminalDashboard {
    param($Ctx, [string]$ServerUrl)
    $viewMode = $View
    $esc = [char]27
    [Console]::Write("$esc[?1049h$esc[?25l")   # alternate screen, hide cursor
    try {
        $nextDraw = [datetime]::MinValue
        while ($true) {
            $redraw = $false
            while ([Console]::KeyAvailable) {
                $k = [Console]::ReadKey($true)
                $cmd = switch ($k.KeyChar) { ' ' { 'toggle' } 'r' { 'restart' } 'n' { 'next' } 'p' { 'prev' } '+' { 'faster' } '=' { 'faster' } '-' { 'slower' } default { $null } }
                if ($k.KeyChar -eq 'q' -or ($k.Key -eq 'C' -and $k.Modifiers -band [ConsoleModifiers]::Control)) { return }
                if ($k.KeyChar -eq 't') { $viewMode = if ($viewMode -eq 'executive') { 'technical' } else { 'executive' } }
                elseif ($cmd) {
                    if ($ServerUrl) { try { Invoke-RestMethod -Method Post -Uri "$ServerUrl/api/replay?cmd=$cmd" | Out-Null } catch { } }
                    elseif ($Ctx.Mode -eq 'replay') { Invoke-ReplayCommand $Ctx.Replay $cmd '' }
                }
                $redraw = $true
            }
            # Replay redraws every second so the clocks move smoothly; live every -RefreshSeconds.
            if ($redraw -or [datetime]::UtcNow -ge $nextDraw) {
                $state = $null; $err = $null
                if ($ServerUrl) {
                    try { $state = Invoke-RestMethod -Uri "$ServerUrl/api/state" -TimeoutSec 5 | ConvertTo-Json -Depth 20 | ConvertFrom-Json -AsHashtable -DateKind String } catch { $err = $_.Exception.Message }
                } else { $state = Get-ContextState $Ctx }
                $w = try { [Console]::WindowWidth } catch { 0 }
                $h = try { [Console]::WindowHeight } catch { 0 }
                if ($w -lt 60) { $w = 120 }   # size unknown (no real terminal)
                if ($h -lt 20) { $h = 45 }
                $frame = if ($state) { Get-TerminalFrame $state $viewMode ($w - 1) $h } else { @("Dashboard server $ServerUrl not reachable: $err", 'Retrying ... (q to quit)') }
                $sb = [System.Text.StringBuilder]::new()
                [void]$sb.Append("$esc[H")
                foreach ($line in @($frame | Select-Object -First $h)) { [void]$sb.Append($line).Append("$esc[K`n") }
                [void]$sb.Append("$esc[J")
                [Console]::Write($sb.ToString().TrimEnd("`n"))
                $isReplay = $state -and $state.meta.mode -eq 'replay'
                $nextDraw = [datetime]::UtcNow.AddSeconds($(if ($isReplay) { 1 } else { $RefreshSeconds }))
            }
            Start-Sleep -Milliseconds 100
        }
    } finally {
        [Console]::Write("$esc[?25h$esc[?1049l")
    }
}

# ── Web server ─────────────────────────────────────────────────────────────────
function Send-Response {
    param($Ctx, [int]$Status, [string]$ContentType, [string]$Body)
    $bytes = [System.Text.Encoding]::UTF8.GetBytes($Body)
    $Ctx.Response.StatusCode = $Status
    $Ctx.Response.ContentType = $ContentType
    $Ctx.Response.Headers['Cache-Control'] = 'no-store'
    $Ctx.Response.ContentLength64 = $bytes.Length
    $Ctx.Response.OutputStream.Write($bytes, 0, $bytes.Length)
    $Ctx.Response.OutputStream.Close()
}

function Test-DashServer {
    param([int]$P)
    try { return Invoke-RestMethod -Uri "http://localhost:$P/api/ping" -TimeoutSec 2 } catch { return $null }
}

function Open-Url {
    param([string]$Url)
    if ($NoBrowser) { return }
    if ($IsMacOS) { & open $Url } elseif ($IsWindows) { Start-Process $Url } else { & xdg-open $Url 2>$null }
}

function Invoke-WebDashboard {
    param($Ctx, [switch]$WithTerminal)
    $listener = [System.Net.HttpListener]::new()
    $listener.Prefixes.Add("http://localhost:$Port/")
    try { $listener.Start() } catch { Write-Error "Can't listen on http://localhost:$Port ($($_.Exception.Message)) - use -Port." }
    $url = "http://localhost:$Port"
    $html = Get-Content (Join-Path $WebDir 'index.html') -Raw
    Write-Host ''
    Write-Host "Dashboard: $url  ($($Ctx.UseCase.Id), $(if ($Ctx.Mode -eq 'replay') { "replay of run $($Ctx.ReplayRun) at ×$($Ctx.Replay.Speed)" } else { "live, stack $Stack" }))" -ForegroundColor Green
    Write-Host 'Only this machine can reach it. Ctrl+C stops it.' -ForegroundColor DarkGray
    Open-Url $url
    if ($WithTerminal) { Start-DetachedTerminal @('-Mode', 'terminal', '-Server', $url, '-View', $View, '-RefreshSeconds', "$RefreshSeconds") }
    try {
        while ($listener.IsListening) {
            $task = $listener.GetContextAsync()
            while (-not $task.AsyncWaitHandle.WaitOne(250)) {
                if ($Ctx.Mode -eq 'live' -and $Ctx.PowerJob) { Update-PowerPoll $Ctx @() }
            }
            $hc = $task.GetAwaiter().GetResult()
            try {
                $path = $hc.Request.Url.AbsolutePath
                switch -Regex ($path) {
                    '^/$|^/index\.html$' { Send-Response $hc 200 'text/html; charset=utf-8' $html }
                    '^/api/ping$' { Send-Response $hc 200 'application/json' (@{ useCase = $Ctx.UseCase.Id; stack = $Stack; mode = $Ctx.Mode; run = $Ctx.ReplayRun } | ConvertTo-Json -Compress) }
                    '^/api/state$' { Send-Response $hc 200 'application/json; charset=utf-8' ((Get-ContextState $Ctx) | ConvertTo-Json -Depth 20 -Compress) }
                    '^/api/replay$' {
                        if ($hc.Request.HttpMethod -ne 'POST' -or $Ctx.Mode -ne 'replay') { Send-Response $hc 400 'text/plain' 'replay control needs POST in replay mode'; break }
                        Invoke-ReplayCommand $Ctx.Replay $hc.Request.QueryString['cmd'] $hc.Request.QueryString['value']
                        Send-Response $hc 200 'application/json' '{"ok":true}'
                    }
                    default { Send-Response $hc 404 'text/plain' 'not found' }
                }
            } catch {
                Write-Host "  request failed: $($_.Exception.Message)" -ForegroundColor Yellow
                try { Send-Response $hc 500 'text/plain' $_.Exception.Message } catch { }
            }
        }
    } finally {
        $listener.Stop(); $listener.Close()
        if ($Ctx.PowerJob) { Remove-Job $Ctx.PowerJob -Force -ErrorAction SilentlyContinue }
    }
}

# ── New window (use cases' -Dashboard, -Mode both) ─────────────────────────────
function Start-DetachedTerminal {
    param([string[]]$ExtraArgs)
    $argList = @('-NoProfile', '-File', (Join-Path $DashDir 'dashboard.ps1'), '-UseCase', $UseCase, '-Stack', $Stack) + $ExtraArgs
    if ($IsMacOS) {
        $cmd = 'pwsh ' + (($argList | ForEach-Object { "'" + ($_ -replace "'", "'\''") + "'" }) -join ' ')
        $as = $cmd.Replace('\', '\\').Replace('"', '\"')
        & osascript -e "tell application `"Terminal`" to do script `"$as`"" -e 'tell application "Terminal" to activate' | Out-Null
    } elseif ($IsWindows) {
        Start-Process pwsh -ArgumentList $argList
    } else {
        Write-Host 'Open another terminal and run:' -ForegroundColor Yellow
        Write-Host ('  pwsh ' + ($argList -join ' '))
    }
}

# ── Inputs ─────────────────────────────────────────────────────────────────────
$useCases = @(Get-DashUseCases)
if ($useCases.Count -eq 0) { Write-Error "No use case with a dashboard.json under $UseCasesDir." }
if (-not $UseCase) {
    $UseCase = if ($useCases.Count -eq 1) { $useCases[0].Id } else {
        (Read-Pick -Prompt 'Use case' -Items $useCases -Labels @($useCases | ForEach-Object { "$($_.Id)  $($_.Title)" })).Id
    }
}
$ucDir = ($useCases | Where-Object { $_.Id -eq $UseCase } | Select-Object -First 1)
if (-not $ucDir) { Write-Error "Use case '$UseCase' not found (with a dashboard.json): $(($useCases | ForEach-Object { $_.Id }) -join ', ')" }
if (-not $Stack) {
    $stacks = @(Get-Stacks $ucDir.Dir)
    if ($stacks.Count -eq 0) { Write-Error "No run of $UseCase yet (runs/<rg>/<run-id>/events.jsonl). Start one, e.g. ./use-cases/$UseCase/$UseCase.ps1 -Action drill -Dashboard" }
    $Stack = if ($stacks.Count -eq 1 -or -not $Interactive) { $stacks[0].Name } else {
        (Read-Pick -Prompt 'Stack (runs folder)' -Items $stacks -Labels @($stacks | ForEach-Object { "$($_.Name)  ($($_.Runs.Count) run(s), newest $($_.Runs[-1]))" })).Name
    }
}
if ($Interactive) {
    $stackDir = Join-Path $ucDir.Dir 'runs' $Stack
    $what = Read-Pick -Prompt 'Show' -Items @('live', 'replay') -Labels @('Live - follows the newest run (a new drill shows up by itself)', 'Replay a recorded run')
    if ($what -eq 'replay') {
        $runs = @(Get-RunIds $stackDir)
        [array]::Reverse($runs)
        $Replay = Read-Pick -Prompt 'Run to replay' -Items $runs -Labels @($runs | ForEach-Object { "$_  $(Get-RunSummary (Join-Path $stackDir $_))" })
        $s = Read-Line "Replay speed (x) [$Speed]"
        if ($s) { $Speed = [double]::Parse($s, [cultureinfo]::InvariantCulture) }
    }
    $Mode = Read-Pick -Prompt 'Dashboard' -Items @('web', 'terminal', 'both') -Labels @('Web page (browser)', 'Terminal (text)', 'Both')
    $r = Read-Line "Refresh every N seconds [$RefreshSeconds]"
    if ($r) { $RefreshSeconds = [int]$r }
}

# Detach: re-launch in a new window with the same choices (the use case keeps running here).
if ($Detach) {
    $extra = @('-Mode', $Mode, '-RefreshSeconds', "$RefreshSeconds", '-View', $View, '-Port', "$Port", '-PowerPollSeconds', "$PowerPollSeconds")
    if ($Replay) { $extra += @('-Replay', $Replay, '-Speed', "$Speed", '-MaxGapSeconds', "$MaxGapSeconds") } elseif ($Run -ne 'latest') { $extra += @('-Run', $Run) }
    if ($NoBrowser) { $extra += '-NoBrowser' }
    $running = if ($Mode -ne 'terminal') { Test-DashServer $Port } else { $null }
    if ($running -and $running.useCase -eq $UseCase -and $running.stack -eq $Stack -and $running.mode -eq 'live' -and -not $Replay) {
        Write-Host "Dashboard already running: http://localhost:$Port" -ForegroundColor Green
        Open-Url "http://localhost:$Port"
        if ($Mode -eq 'both') { Start-DetachedTerminal @('-Mode', 'terminal', '-Server', "http://localhost:$Port", '-View', $View) }
        exit 0
    }
    if ($running) { Write-Error "Port $Port is used by another dashboard ($($running.useCase) $($running.stack) $($running.mode)) - pass -Port or stop it." }
    Start-DetachedTerminal $extra
    Write-Host "Dashboard opened in a new window ($Mode$(if ($Mode -ne 'terminal') { ", http://localhost:$Port" }))." -ForegroundColor Green
    exit 0
}

if ($Server) {
    Invoke-TerminalDashboard -Ctx $null -ServerUrl $Server.TrimEnd('/')
    exit 0
}

$ctx = New-DashContext
switch ($Mode) {
    'terminal' { Invoke-TerminalDashboard -Ctx $ctx }
    'web'      { Invoke-WebDashboard -Ctx $ctx }
    'both'     { Invoke-WebDashboard -Ctx $ctx -WithTerminal }
}
