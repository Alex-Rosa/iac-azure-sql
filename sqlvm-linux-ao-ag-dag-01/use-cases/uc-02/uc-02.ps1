#Requires -Version 7.0
<#
.SYNOPSIS
    UC-02 - Region failure of the SECONDARY (DR) node: keep running on the primary, then recover the
    secondary region in place and let it catch up.

.DESCRIPTION
    Same topology as UC-01 (built by ../../sqlvm-linux-ag.ps1): AG1 = primary node in region A +
    DR replica in region B, global primary of one distributed AG per forwarder stack.
    All AGs use CLUSTER_TYPE = NONE.

    A failure of region B takes down AG1's DR replica and every forwarder node in region B. The
    primary keeps serving - no failover. The resolution is IN PLACE: when region B is back, its
    replicas reconnect and catch up from the primary's log.

    What makes that harder, and what this use case measures:
      - Load on the primary: every transaction committed during the outage is log the DR replica
        doesn't have yet; the heavier the load, the bigger the backlog and the longer the catch-up.
      - The primary's log can't be truncated while a replica is missing (log_reuse_wait
        AVAILABILITY_REPLICA), even with log backups: it grows until the replica is back or the volume
        is full. The writer stops itself below -MinFreeDiskPercent free; -ProtectPrimaryAtFreePercent
        removes the missing replicas first (they are then re-seeded instead of caught up).
      - Catch-up only converges if the replica replays faster than the primary generates new log; the
        drill compares its ETA with an estimated reseed.

    Variants: -FailureMode poweroff (default) | partition (NSG rules cut the region off, VMs stay up);
    -DrCommitMode async (default) | sync (commits wait for the DR replica until it is lost).
    Monitoring: a sampler on the primary records the key metrics every -SampleSeconds; a reader on the
    DR replica measures how fresh the data a reporting query sees is (off with -NoReadWorkload).

    Actions (asked for when not passed):
      status            Power state + AG / distributed AG health + the primary's key metrics.
      precheck          Starts deallocated VMs (after confirmation), checks every AG and distributed AG
                        is healthy, opens a drill run (runs/<rg>/<run-id>/) and starts the sampler.
      start-workload    Writer sessions + log backups on the primary, reader on the DR replica.
      monitor           Collects samples for -MonitorMinutes: the baseline before the failure, the
                        outage after it.
      simulate-failure  Power-off (or network partition) of every node in the DR region.
      protect-primary   Removes the missing DR replica (and drops the missing forwarders' distributed AGs)
                        so the primary's log can be truncated. They are re-seeded by 'recover'.
      recover           Brings the region back (starts its VMs or lifts the partition), waits for the
                        replicas to reconnect - or re-seeds them after protect-primary - and tracks the
                        catch-up (backlog, rate, ETA, reseed estimate).
      verify            Stops the workload, waits until everything is replicated, compares the rows on the
                        primary, the DR replica and every forwarder.
      stop-workload     Stops the writer, the log backups and the reader.
      cleanup           Stops everything, empties the load table, backs up and shrinks the log.
      report            Writes a static HTML report of the current run (runs/<rg>/<run-id>/report.html).
      drill             precheck -> start-workload -> baseline -> simulate-failure -> outage -> recover
                        -> verify -> report.

.EXAMPLE
    ./uc-02.ps1                                   # interactive
.EXAMPLE
    ./uc-02.ps1 -Action drill -Dashboard -Identifier ag01 -PrimaryNodeSuffix node-1 -SecondaryNodeSuffix node-2 -Forwarders ag02:node-3:node-4,ag03:node-5:node-6
.EXAMPLE
    ./uc-02.ps1 -Action drill -FailureMode partition -DrCommitMode sync -Identifier ag01 -PrimaryNodeSuffix node-1 -SecondaryNodeSuffix node-2 -Forwarders ag02:node-3:node-4,ag03:node-5:node-6
.EXAMPLE
    ./uc-02.ps1 -Action drill -OutageMinutes 15 -ProtectPrimaryAtFreePercent 20 -Identifier ag01 -PrimaryNodeSuffix node-1 -SecondaryNodeSuffix node-2 -Forwarders ag02:node-3:node-4,ag03:node-5:node-6
#>
param(
    [ValidateSet('', 'status', 'precheck', 'start-workload', 'monitor', 'simulate-failure', 'protect-primary', 'recover', 'verify', 'stop-workload', 'cleanup', 'report', 'drill')]
    [string]$Action = '',

    # Same values used with ../../sqlvm-linux-ag.ps1.
    [string]$Identifier          = '',
    [string]$PrimaryNodeSuffix   = '',   # AG1 primary - stays up
    [string]$SecondaryNodeSuffix = '',   # AG1 DR replica - in the region that FAILS
    # Forwarder stacks of AG1's distributed AGs: '<identifier>:<primary>:<secondary>' entries
    # (e.g. ag02:node-3:node-4,ag03:node-5:node-6), or 'none'. Asked for when not passed.
    [string[]]$Forwarders        = @(),
    [string]$ForwarderPrimarySuffix   = '',
    [string]$ForwarderSecondarySuffix = '',
    [string]$Prefix              = 'sqlvm',
    [string]$AgName              = '',   # default agsqlvm-<PrimaryNodeSuffix>
    [string]$DagName             = '',   # single forwarder only
    [string]$DemoDbName          = 'AGDemoDB',

    # Failure variants.
    [ValidateSet('poweroff', 'partition')]
    [string]$FailureMode = 'poweroff',    # partition: NSG rules cut the DR region off, its VMs keep running
    [ValidateSet('async', 'sync')]
    [string]$DrCommitMode = 'async',      # sync: the DR replica is SYNCHRONOUS_COMMIT for the drill (restored by verify)
    [ValidateRange(0, 90)]
    [int]$ProtectPrimaryAtFreePercent = 0,   # > 0: below this % free on the log volume while DR is down, protect the primary

    # Workload on the primary. 'light' ~5 tx/s of small rows; 'heavy' several sessions of large
    # transactions (MB/s of log). Any of the four values below overrides the profile.
    [ValidateSet('light', 'heavy')]
    [string]$WorkloadProfile = 'heavy',
    [int]$WriterSessions = 0,
    [int]$RowsPerTx      = 0,
    [ValidateRange(0, 8000)]
    [int]$RowBytes       = 0,
    [int]$ThinkMs        = -1,
    [int]$WorkloadMinutes = 120,          # writer lifetime cap
    [int]$LogBackupSeconds = 60,          # BACKUP LOG every N s while the writer runs (0 = off)
    [ValidateRange(5, 90)]
    [int]$MinFreeDiskPercent = 15,        # the writer stops below this % free on the log volume
    [ValidateRange(5, 95)]
    [int]$LowDiskWarnPercent = 25,        # warning on the dashboard below this % free
    [switch]$NoReadWorkload,              # no reader on the DR replica

    # Timing.
    [int]$WarmupSeconds = 120,            # drill: baseline before the failure
    [double]$OutageMinutes = 5,           # drill: how long region B stays down
    [double]$MonitorMinutes = 5,          # monitor action
    [ValidateRange(1, 60)]
    [int]$SampleSeconds = 5,              # the sampler on the primary takes one sample every N s
    [ValidateRange(5, 300)]
    [int]$FetchSeconds = 20,              # the script collects the samples every N s (one Run Command)
    [int]$CatchUpTimeoutMinutes = 60,
    [int]$ReconnectTimeoutMinutes = 20,
    [int]$SeedTimeoutMinutes = 120,
    # "Caught up" = every DR database SYNCHRONIZING, queue (send + redo) and lag back to normal:
    # at most max(these, twice what the baseline measured).
    [double]$CaughtUpQueueMB = 20,
    [double]$CaughtUpLagSeconds = 10,
    [double]$SeedingMBps = 0,             # reseed estimate: seeding throughput (0 = the send rate observed)

    [int]$CleanupLogMB = 1024,            # cleanup: shrink the log to this size
    [switch]$KeepWorkload,                # verify: leave the writer running (rows aren't compared then)
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
# Shared framework: console input, evidence, Run Command transport, SQL + distributed AG helpers,
# topology, dashboard events and the main runner (../common/uc-common.ps1).
. (Join-Path $PSScriptRoot '..' 'common' 'uc-common.ps1')

$Profiles = @{
    light = @{ Sessions = 1; Rows = 1;  RowBytes = 200;  ThinkMs = 200 }
    heavy = @{ Sessions = 4; Rows = 20; RowBytes = 2000; ThinkMs = 20 }
}
$Load = $Profiles[$WorkloadProfile].Clone()
if ($WriterSessions -gt 0) { $Load.Sessions = $WriterSessions }
if ($RowsPerTx -gt 0)      { $Load.Rows = $RowsPerTx }
if ($RowBytes -gt 0)       { $Load.RowBytes = $RowBytes }
if ($ThinkMs -ge 0)        { $Load.ThinkMs = $ThinkMs }
$Load.Label = "$WorkloadProfile - $($Load.Sessions) session(s) x $($Load.Rows) row(s) x $($Load.RowBytes) B per transaction, $($Load.ThinkMs) ms pause"
$WorkDir = '/var/tmp/uc02'   # writer, sampler, reader and log-backup scripts on the VMs
$PartitionRules = @('uc02-partition-in', 'uc02-partition-out')

# ── Small helpers ──────────────────────────────────────────────────────────────
function ConvertTo-Number { param($S) if ($null -eq $S -or "$S" -eq '') { $null } else { [double]$S } }
# A value from evidence read back from JSON (object) or still in memory (dictionary); $null when absent.
function Get-EvidenceValue {
    param($Obj, [string]$Name)
    if ($null -eq $Obj) { return $null }
    if ($Obj -is [System.Collections.IDictionary]) { return $(if ($Obj.Contains($Name)) { $Obj[$Name] }) }
    if ($Obj.PSObject.Properties[$Name]) { return $Obj.$Name }
    return $null
}
function Format-MB {
    param($MB)
    if ($null -eq $MB) { return '?' }
    if ($MB -ge 1024) { return '{0:N1} GB' -f ($MB / 1024) }
    return '{0:N0} MB' -f $MB
}
function Format-Duration {
    param($Seconds)
    if ($null -eq $Seconds -or $Seconds -lt 0) { return '?' }
    $ts = [timespan]::FromSeconds([double]$Seconds)
    if ($ts.TotalHours -ge 1) { return '{0}h{1:mm}m' -f [int][math]::Floor($ts.TotalHours), $ts }
    return '{0}:{1:ss}' -f [int][math]::Floor($ts.TotalMinutes), $ts
}
function Expand-GzBase64 {
    param([string]$B64)
    if (-not $B64) { return '' }
    $ms = [System.IO.MemoryStream]::new([Convert]::FromBase64String($B64))
    $gz = [System.IO.Compression.GZipStream]::new($ms, [System.IO.Compression.CompressionMode]::Decompress)
    $sr = [System.IO.StreamReader]::new($gz)
    try { return $sr.ReadToEnd() } finally { $sr.Dispose() }
}
function Get-BackupDirBash {
    # The data disk (/sqldata) when it's mounted, else next to SQL Server's default backup folder.
    return "if mountpoint -q /sqldata; then BK=/sqldata/uc02-backup; else BK=/var/opt/mssql/backup/uc02; fi; mkdir -p `$BK && chown mssql:mssql `$BK"
}
# Bash that writes $Content to $Path atomically (a running script keeps reading its old copy).
function Get-WriteFileBash {
    param([string]$Path, [string]$Content, [string]$Mode = '')
    $marker = 'UCFILE' + ([guid]::NewGuid().ToString('N').Substring(0, 8))
    $chmod = if ($Mode) { "`nchmod $Mode $Path.tmp" } else { '' }
    return "cat > $Path.tmp <<'$marker'`n$($Content.Replace("`r`n", "`n").TrimEnd("`n"))`n$marker$chmod`nmv -f $Path.tmp $Path"
}

# ── Sampler on the primary / reader on the DR replica ──────────────────────────
# The sampler runs 40-primary-sample.sql every -SampleSeconds and appends one line per sample to
# samples-<run>.log; the script collects new lines in batches (gzip + base64 to stay under the ~4 KB
# Run Command output limit). The reader does the same on the DR replica with 43-read-freshness.sql.
function Get-SamplerBash {
    $sampleSql = Get-Content (Join-Path $SqlDir '40-primary-sample.sql') -Raw
    $sampler = @"
#!/bin/bash
# UC-02 sampler: one line of key metrics every EVERY s until the stop file exists.
EVERY="`$1"; DB="`$2"; RUN="`$3"
while [ ! -f $WorkDir/sampler.stop ]; do
  /opt/mssql-tools18/bin/sqlcmd -S localhost -U SA -No -C -b -W -h -1 -v DbName="`$DB" RunId="`$RUN" -i $WorkDir/sample.sql 2>/dev/null | grep '^S1=' >> $WorkDir/samples-`$RUN.log
  sleep "`$EVERY"
done
"@
    return @"
mkdir -p $WorkDir
$(Get-WriteFileBash "$WorkDir/sample.sql" $sampleSql)
$(Get-WriteFileBash "$WorkDir/sampler.sh" $sampler '700')
if ! pgrep -f $WorkDir/sampler.sh >/dev/null || [ "`$(cat $WorkDir/sampler.run 2>/dev/null)" != "$($script:RunId)" ]; then
  pkill -f $WorkDir/sampler.sh || true
  rm -f $WorkDir/sampler.stop
  echo "$($script:RunId)" > $WorkDir/sampler.run
  nohup setsid $WorkDir/sampler.sh $SampleSeconds "$DemoDbName" "$($script:RunId)" > /dev/null 2>&1 < /dev/null &
  echo "SAMPLER_STARTED=1"
fi
"@
}

function Get-ReaderBash {
    $readSql = Get-Content (Join-Path $SqlDir '43-read-freshness.sql') -Raw
    $reader = @"
#!/bin/bash
# UC-02 reader: what a reporting query on this readable secondary sees, every 2 s.
DB="`$1"; RUN="`$2"
while [ ! -f $WorkDir/reader.stop ]; do
  out=`$(/opt/mssql-tools18/bin/sqlcmd -S localhost -U SA -No -C -b -W -h -1 -l 5 -v DbName="`$DB" -i $WorkDir/read.sql 2>/dev/null | grep '^R1=')
  if [ -n "`$out" ]; then echo "`$out"; else echo "R1=`$(date -u +%Y-%m-%dT%H:%M:%S.%3N)|ERR"; fi >> $WorkDir/reads-`$RUN.log
  sleep 2
done
"@
    return @"
mkdir -p $WorkDir
$(Get-WriteFileBash "$WorkDir/read.sql" $readSql)
$(Get-WriteFileBash "$WorkDir/reader.sh" $reader '700')
if ! pgrep -f $WorkDir/reader.sh >/dev/null || [ "`$(cat $WorkDir/reader.run 2>/dev/null)" != "$($script:RunId)" ]; then
  pkill -f $WorkDir/reader.sh || true
  rm -f $WorkDir/reader.stop
  echo "$($script:RunId)" > $WorkDir/reader.run
  nohup setsid $WorkDir/reader.sh "$DemoDbName" "$($script:RunId)" > /dev/null 2>&1 < /dev/null &
  echo "READER_STARTED=1"
fi
"@
}

# Bash that returns up to 40 new lines of a log (after line $Next) as FETCH_GZ, FETCH_COUNT.
function Get-FetchBash {
    param([string]$File, [int]$Next)
    return @"
touch $File
sed -n "$($Next + 1),$($Next + 40)p" $File > $WorkDir/fetch.txt
echo "FETCH_TOTAL=`$(wc -l < $File | tr -d ' ')"
echo "FETCH_COUNT=`$(wc -l < $WorkDir/fetch.txt | tr -d ' ')"
echo "FETCH_GZ=`$(gzip -c $WorkDir/fetch.txt | base64 -w0)"
"@
}

$script:DrReachable = $true   # false while the DR VM is powered off (no Run Command on it then)
function Get-Offset { param([string]$Name) $f = Join-Path (Get-RunDir) "$Name-offset.txt"; if (Test-Path $f) { [int](Get-Content $f -Raw) } else { 0 } }
function Set-Offset { param([string]$Name, [int]$Value) Set-Content -Path (Join-Path (Get-RunDir) "$Name-offset.txt") -Value $Value }

# One collection round: new sampler lines from the primary (+ reader lines from the DR replica).
# Keeps the sampler (and the reader) running. Returns @{ Samples = S1 lines; Reads = R1 lines }.
function Receive-Samples {
    $sNext = Get-Offset 'sampler'
    $reqs = @(@{ Node = $Orig; Label = 'collect samples'; Body = (Get-SamplerBash) + "`n" + (Get-FetchBash "$WorkDir/samples-$($script:RunId).log" $sNext) })
    $withReader = -not $NoReadWorkload -and $script:DrReachable -and (Read-Evidence 'workload')
    $rNext = 0
    if ($withReader) {
        $rNext = Get-Offset 'reader'
        $reqs += @{ Node = $Dr; Label = 'collect reads'; Body = (Get-ReaderBash) + "`n" + (Get-FetchBash "$WorkDir/reads-$($script:RunId).log" $rNext) }
    }
    $res = @(Invoke-VmBatch $reqs -Quiet)
    $out = @{ Samples = @(); Reads = @() }
    if ($res[0].Exit -eq 0) {
        $out.Samples = @((Expand-GzBase64 (Get-Val $res[0] 'FETCH_GZ')) -split "`n" | Where-Object { $_ -like 'S1=*' })
        Set-Offset 'sampler' ($sNext + [int](Get-Val $res[0] 'FETCH_COUNT'))
    } else {
        Write-Host "  (collecting samples failed on $($Orig.Vm): $($res[0].Stderr))" -ForegroundColor DarkYellow
    }
    if ($withReader -and $res.Count -gt 1 -and $res[1].Exit -eq 0) {
        $out.Reads = @((Expand-GzBase64 (Get-Val $res[1] 'FETCH_GZ')) -split "`n" | Where-Object { $_ -like 'R1=*' })
        Set-Offset 'reader' ($rNext + [int](Get-Val $res[1] 'FETCH_COUNT'))
    }
    return $out
}

function Stop-Monitoring {
    param([switch]$Sampler, [switch]$Reader)
    $reqs = @()
    if ($Sampler) { $reqs += @{ Node = $Orig; Label = 'stop sampler'; Body = "touch $WorkDir/sampler.stop; pkill -f $WorkDir/sampler.sh || true" } }
    if ($Reader -and -not $NoReadWorkload -and $script:DrReachable) { $reqs += @{ Node = $Dr; Label = 'stop reader'; Body = "mkdir -p $WorkDir; touch $WorkDir/reader.stop; pkill -f $WorkDir/reader.sh || true" } }
    if ($reqs.Count) { Invoke-VmBatch $reqs -Quiet | Out-Null }
}

# ── Parsing a sample ───────────────────────────────────────────────────────────
function ConvertFrom-SampleLine {
    param([string]$Line)
    $f = $Line.Substring(3).Split('|')
    if ($f.Count -lt 17) { return $null }
    $reps = @(if ($f[16]) { $f[16].Split('#') | ForEach-Object {
        $p = $_.Split(',')
        if ($p.Count -ge 11) {
            [pscustomobject]@{ Ag = $p[0]; Replica = $p[1]; Conn = $p[2]; Sync = $p[3]; Suspended = ($p[4] -eq '1')
                               SendQKB = (ConvertTo-Number $p[5]); SendRateKB = (ConvertTo-Number $p[6]); RedoQKB = (ConvertTo-Number $p[7])
                               RedoRateKB = (ConvertTo-Number $p[8]); DmvLag = (ConvertTo-Number $p[9])
                               LastCommit = $(if ($p[10]) { ConvertTo-Utc $p[10] }) }
        } } })
    return [pscustomobject]@{
        T = (ConvertTo-Utc $f[0]); TxCounter = (ConvertTo-Number $f[1]); LogBytes = (ConvertTo-Number $f[2])
        WriterTx = (ConvertTo-Number $f[3]); WriterErr = (ConvertTo-Number $f[4]); WritersRunning = (ConvertTo-Number $f[5]); WriterStop = $f[6]
        SlowMs = (ConvertTo-Number $f[7])
        Log = $(if ($f[8]) { [pscustomobject]@{ Db = $DemoDbName; SizeMB = [double]$f[8]; UsedPct = (ConvertTo-Number $f[9]); ReuseWait = $f[10] } })
        DiskMount = $f[11]; DiskTotalMB = (ConvertTo-Number $f[12]); DiskFreeMB = (ConvertTo-Number $f[13]); DataMB = (ConvertTo-Number $f[14])
        LastCommit = $(if ($f[15]) { ConvertTo-Utc $f[15] }); Reps = $reps
    }
}

# One sample of the primary right now (status, pre-check).
function Read-PrimarySample {
    $r = Invoke-Sql -Node $Orig -File '40-primary-sample.sql' -Vars @{ DbName = $DemoDbName; RunId = (Get-RunIdOrNone) } -Label 'sample' -Quiet -AllowFail
    $line = Get-Val $r 'S1'
    if ($r.Exit -ne 0 -or -not $line) { Write-Host "  (sample failed on $($Orig.Vm): $($r.Stderr))" -ForegroundColor DarkYellow; return $null }
    return ConvertFrom-SampleLine "S1=$line"
}

# Replication state of one remote replica, as the primary sees it. Lag = the primary's newest commit
# minus the newest commit that replica has (last_commit_time: millisecond precision, and still known
# while the replica is down - it is the span of committed transactions the replica doesn't have).
function Measure-Replica {
    param($Sample, [string]$Ag, [string]$Replica)
    $rows = @($Sample.Reps | Where-Object { $_.Ag -eq $Ag -and $_.Replica -eq $Replica })
    $conn = $rows.Count -gt 0 -and -not @($rows | Where-Object { $_.Conn -ne 'CONNECTED' }).Count
    $sum = { param($prop) $v = 0.0; foreach ($x in $rows) { if ($null -ne $x.$prop) { $v += $x.$prop } }; $v }
    $dmv = @($rows | Where-Object { $null -ne $_.DmvLag } | ForEach-Object { $_.DmvLag })
    $lag = $null
    $commits = @($rows | Where-Object { $null -ne $_.LastCommit } | ForEach-Object { $_.LastCommit })
    if ($Sample.LastCommit -and $commits.Count) {
        $oldest = ($commits | Measure-Object -Minimum).Minimum
        $lag = [math]::Max(0.0, ($Sample.LastCommit - $oldest).TotalSeconds)
    }
    return [pscustomobject]@{
        Rows = $rows.Count; Connected = $conn
        Synchronizing = $rows.Count -gt 0 -and -not @($rows | Where-Object { $_.Sync -notin @('SYNCHRONIZING', 'SYNCHRONIZED') }).Count
        Suspended = [bool]@($rows | Where-Object { $_.Suspended }).Count
        SendQMB = (& $sum 'SendQKB') / 1024; RedoQMB = (& $sum 'RedoQKB') / 1024
        QueueMB = ((& $sum 'SendQKB') + (& $sum 'RedoQKB')) / 1024
        SendRateMBps = (& $sum 'SendRateKB') / 1024; RedoRateMBps = (& $sum 'RedoRateKB') / 1024
        Lag = $lag; DmvLag = $(if ($dmv.Count) { ($dmv | Measure-Object -Maximum).Maximum } else { $null })
    }
}

# Derived dashboard values of one sample: throughput, log rate, log size, disk, and how far behind the
# DR replica is (while it's down: log generated since the failure; once it's back: its queues).
$script:PrevSample = $null
$script:Track = @{ MinDiskFreePct = $null; PeakLogSizeMB = $null; ReuseWait = $null; LowDiskWarned = $false; WriterStopped = $false }
function Convert-MonitorSample {
    param($S)
    $prev = $script:PrevSample
    $script:PrevSample = $S
    $v = [ordered]@{}
    if ($prev) {
        $dt = ($S.T - $prev.T).TotalSeconds
        if ($dt -gt 0) {
            if ($null -ne $S.WriterTx -and $null -ne $prev.WriterTx -and $S.WriterTx -ge $prev.WriterTx) { $v.txPerSec = ($S.WriterTx - $prev.WriterTx) / $dt }
            if ($null -ne $S.LogBytes -and $null -ne $prev.LogBytes) { $v.logMBps = [math]::Max(0.0, ($S.LogBytes - $prev.LogBytes) / $dt / 1MB) }
        }
    }
    if ($S.Log) { $v.logSizeMB = $S.Log.SizeMB; if ($null -ne $S.Log.UsedPct) { $v.logUsedPct = $S.Log.UsedPct } }
    if ($S.DiskTotalMB) { $v.diskFreePct = $S.DiskFreeMB * 100 / $S.DiskTotalMB }
    if ($null -ne $S.SlowMs) { $v.slowCommitMs = $S.SlowMs }

    $drState = Measure-Replica $S $AgName $Dr.Name
    $failure = Read-Evidence 'failure'
    $txPerMB = Get-EvidenceValue (Read-Evidence 'baseline') 'txPerMB'
    if ($null -ne $drState.Lag) { $v.lagSeconds = $drState.Lag }
    if ($null -ne $drState.DmvLag) { $v.dmvLagSeconds = $drState.DmvLag }
    if ($drState.Connected) {
        $v.behindMB = $drState.QueueMB; $v.sendQueueMB = $drState.SendQMB; $v.redoQueueMB = $drState.RedoQMB
        if ($txPerMB) { $v.txBehind = $drState.QueueMB * $txPerMB }
    } elseif ($failure -and $null -ne $S.LogBytes -and $null -ne (Get-EvidenceValue $failure 'logBytes')) {
        # Down: everything the primary logged since the failure (+ what was queued then) is missing on DR.
        $v.behindMB = [math]::Max(0.0, ($S.LogBytes - [double]$failure.logBytes) / 1MB) + [double](Get-EvidenceValue $failure 'queueMB')
        $ftx = Get-EvidenceValue $failure 'writerTx'
        if ($null -ne $S.WriterTx -and $null -ne $ftx) { $v.txBehind = [math]::Max(0.0, $S.WriterTx - [double]$ftx) }
    }
    $fwDown = @($ForwarderList | Where-Object { $_.InFailedRegion })
    if ($fwDown.Count) {
        $fwMB = 0.0; $allConn = $true; $fwLag = $null
        foreach ($f in $fwDown) {
            $m = Measure-Replica $S $f.Dag $f.Ag
            if ($m.Connected) { $fwMB += $m.QueueMB } else { $allConn = $false }
            if ($null -ne $m.Lag -and ($null -eq $fwLag -or $m.Lag -gt $fwLag)) { $fwLag = $m.Lag }
        }
        if ($allConn) { $v.fwBehindMB = $fwMB } elseif ($v.Contains('behindMB')) { $v.fwBehindMB = $v.behindMB }
        if ($null -ne $fwLag) { $v.fwLagSeconds = $fwLag }
    }
    return [pscustomobject]@{ Sample = $S; Values = $v; Dr = $drState }
}

# Warnings, extremes, the log-truncation reason and the automatic protection of the primary.
function Invoke-SampleGuards {
    param($M)
    $s = $M.Sample; $v = $M.Values
    if ($v.Contains('diskFreePct')) {
        if ($null -eq $script:Track.MinDiskFreePct -or $v.diskFreePct -lt $script:Track.MinDiskFreePct) { $script:Track.MinDiskFreePct = $v.diskFreePct }
        if ($v.diskFreePct -lt $LowDiskWarnPercent -and -not $script:Track.LowDiskWarned) {
            $script:Track.LowDiskWarned = $true
            Add-Event 'low-disk' ("log volume {0} at {1:N1}% free - the writer stops below {2}%" -f $s.DiskMount, $v.diskFreePct, $MinFreeDiskPercent) -Level 'warn'
        }
        if ($ProtectPrimaryAtFreePercent -gt 0 -and $v.diskFreePct -lt $ProtectPrimaryAtFreePercent -and -not $M.Dr.Connected -and -not (Read-Evidence 'protect') -and (Read-Evidence 'failure')) {
            Invoke-ProtectPrimary -Why ("log volume at {0:N1}% free (< {1}%) while {2} is down" -f $v.diskFreePct, $ProtectPrimaryAtFreePercent, $Dr.Name)
        }
    }
    if ($v.Contains('logSizeMB') -and ($null -eq $script:Track.PeakLogSizeMB -or $v.logSizeMB -gt $script:Track.PeakLogSizeMB)) { $script:Track.PeakLogSizeMB = $v.logSizeMB }
    if ($s.Log -and $s.Log.ReuseWait -ne $script:Track.ReuseWait) {
        $script:Track.ReuseWait = $s.Log.ReuseWait
        Set-UcMetric logReuseWait $s.Log.ReuseWait -Detail "why $DemoDbName's log can't be truncated now"
    }
    if ($s.WriterStop -and $s.WritersRunning -eq 0 -and -not $script:Track.WriterStopped -and (Read-Evidence 'workload')) {
        $script:Track.WriterStopped = $true
        Add-Event 'writer-stopped' "every writer session stopped: $($s.WriterStop)" -Level $(if ($s.WriterStop -like 'disk guard*') { 'warn' } else { 'info' })
        if ($s.WriterStop -like 'disk guard*') { Set-UcMetric writerStopReason $s.WriterStop -Detail 'the workload stopped itself: the primary log volume was nearly full' }
    }
}

function Publish-MonitorSample {
    param($M, [switch]$Print, [string]$Tag = '')
    Set-UcSample -Data $M.Values -At $M.Sample.T
    if (-not $Print) { return }
    $v = $M.Values
    $parts = @($M.Sample.T.ToString('HH:mm:ss'))
    if ($v.Contains('txPerSec')) { $parts += '{0:N0} tx/s' -f $v.txPerSec }
    if ($v.Contains('logMBps')) { $parts += '{0:N1} MB/s log' -f $v.logMBps }
    if ($v.Contains('logSizeMB')) { $parts += "log $(Format-MB $v.logSizeMB) ($($M.Sample.Log.ReuseWait))" }
    if ($v.Contains('diskFreePct')) { $parts += '{0:N0}% free' -f $v.diskFreePct }
    $parts += "DR $(if ($M.Dr.Connected) { 'connected' } else { 'DISCONNECTED' })"
    if ($v.Contains('behindMB')) { $parts += "behind $(Format-MB $v.behindMB)$(if ($v.Contains('txBehind')) { ' (~{0:N0} tx)' -f $v.txBehind })" }
    if ($v.Contains('lagSeconds')) { $parts += 'lag {0:N1} s' -f $v.lagSeconds }
    if ($v.Contains('etaSeconds') -and $v.etaSeconds -ge 0) { $parts += "ETA $(Format-Duration $v.etaSeconds)" }
    Write-Host "  $Tag$($parts -join '  ')"
}

# Reader lines -> readFreshnessSec (now - newest readable row) and readOk samples.
function Publish-Reads {
    param([string[]]$Lines)
    foreach ($l in $Lines) {
        $p = $l.Substring(3).Split('|')
        if ($p.Count -lt 2) { continue }
        $t = ConvertTo-Utc $p[0]
        if ($p[1] -eq 'ERR' -or -not $p[1]) { Set-UcSample -Data ([ordered]@{ readOk = 0 }) -At $t -Detail 'read'; continue }
        $fresh = [math]::Max(0.0, ($t - (ConvertTo-Utc $p[1])).TotalSeconds)
        Set-UcSample -Data ([ordered]@{ readOk = 1; readFreshnessSec = $fresh }) -At $t -Detail 'read'
    }
}

# One collection round, every sample through $OnSample (which stops the round by returning $true).
# Returns the processed samples; the last one is printed.
function Invoke-CollectRound {
    param([scriptblock]$OnSample)
    $batch = Receive-Samples
    Publish-Reads $batch.Reads
    $done = [System.Collections.Generic.List[object]]::new()
    $lines = @($batch.Samples)
    for ($i = 0; $i -lt $lines.Count; $i++) {
        $s = ConvertFrom-SampleLine $lines[$i]
        if (-not $s) { continue }
        $m = Convert-MonitorSample $s
        $stop = $false
        if ($OnSample) { $stop = [bool](& $OnSample $m) }
        Invoke-SampleGuards $m
        Publish-MonitorSample $m -Print:($i -eq $lines.Count - 1 -or $stop)
        $done.Add($m)
        if ($stop) { break }
    }
    return , $done
}

# Collects every -FetchSeconds for $Seconds (the sampler keeps its own -SampleSeconds cadence).
function Invoke-MonitorWindow {
    param([double]$Seconds, [scriptblock]$OnSample)
    $end = (Get-UtcNow).AddSeconds($Seconds)
    $all = [System.Collections.Generic.List[object]]::new()
    while ($true) {
        $t = Get-UtcNow
        foreach ($m in (Invoke-CollectRound -OnSample $OnSample)) { $all.Add($m) }
        $left = ($end - (Get-UtcNow)).TotalSeconds
        if ($left -le 0) { break }
        $wait = [math]::Min($FetchSeconds - ((Get-UtcNow) - $t).TotalSeconds, $left)
        if ($wait -gt 0) { Start-Sleep -Seconds $wait }
    }
    return , $all
}

function Get-Average {
    param([object[]]$Samples, [string]$Key)
    $vals = @($Samples | Where-Object { $_.Values.Contains($Key) } | ForEach-Object { [double]$_.Values[$Key] })
    if ($vals.Count -eq 0) { return $null }
    return [math]::Round(($vals | Measure-Object -Average).Average, 2)
}

# ── Status + pre-check ─────────────────────────────────────────────────────────
function Get-HealthProblems {
    param($St)
    $problems = @()
    $o = $St[$Orig.Vm]; $d = $St[$Dr.Vm]
    if ((Get-Val $o 'LOCAL_ROLE') -ne 'PRIMARY')  { $problems += "$($Orig.Name) is '$(Get-Val $o 'LOCAL_ROLE')' in $AgName, expected PRIMARY" }
    if ((Get-Val $d 'LOCAL_ROLE') -ne 'SECONDARY') { $problems += "$($Dr.Name) is '$(Get-Val $d 'LOCAL_ROLE')' in $AgName, expected SECONDARY" }
    $drSeen = @(Get-Vals $o 'REPLICA' | Where-Object { $_ -like "$($Dr.Name)|*" })
    if (-not $drSeen -or $drSeen[0] -notmatch '\|CONNECTED\|') { $problems += "$($Dr.Name) is not CONNECTED to the primary" }
    $agDbs = @(Get-Vals $o 'DB' | Where-Object { $_ -notmatch '\|NOT_IN_AG\|' })
    if ($agDbs.Count -eq 0) { $problems += "no database is in $AgName" }
    foreach ($db in $agDbs) { if ($db -notmatch '\|ONLINE\|' -or $db -match 'suspended=1') { $problems += "AG database not healthy: $db" } }
    $declared = @($ForwarderList | ForEach-Object { $_.Dag })
    foreach ($dag in (Get-Vals $o 'DISTRIBUTED_AG')) {
        if ($declared -notcontains $dag) { $problems += "distributed AG $dag exists on $($Orig.Name) but wasn't declared with -Forwarders" }
    }
    foreach ($f in $ForwarderList) {
        if (@(Get-Vals $o 'DAG_EXISTS') -notcontains "$($f.Dag)|1") { $problems += "distributed AG $($f.Dag) not found on $($Orig.Name)"; continue }
        $member = Get-DagMember $o $f.Dag $f.Ag
        if (-not $member -or $member -notmatch '\|CONNECTED\|') { $problems += "$($f.Dag): forwarder $($f.Ag) is not CONNECTED to the global primary" }
        foreach ($r in @(Get-DagDbRows $o $f.Dag $f.Ag)) { if ($r.Split('|')[3] -notin @('SYNCHRONIZING', 'SYNCHRONIZED') -or $r -match 'suspended=1') { $problems += "$($f.Dag): forwarder database not healthy: $r" } }
    }
    return , $problems
}

function Show-PrimaryMetrics {
    param($S)
    if (-not $S) { return }
    Write-Host ''
    Write-Host "  Primary $($Orig.Name) - key metrics" -ForegroundColor White
    if ($S.Log) { Write-Host ("    log   {0,-20} {1,10}  used {2,5:N1}%  reuse wait {3}" -f $DemoDbName, (Format-MB $S.Log.SizeMB), $S.Log.UsedPct, $S.Log.ReuseWait) }
    if ($S.DiskTotalMB) { Write-Host ("    disk  {0,-20} {1,10} free of {2} ({3:N0}%)" -f $S.DiskMount, (Format-MB $S.DiskFreeMB), (Format-MB $S.DiskTotalMB), ($S.DiskFreeMB * 100 / $S.DiskTotalMB)) }
    if ($S.DataMB) { Write-Host ("    data  {0,-20} {1,10} in AG databases (what a reseed copies)" -f '', (Format-MB $S.DataMB)) }
    foreach ($r in $S.Reps) {
        $lag = if ($S.LastCommit -and $r.LastCommit) { '{0:N3}' -f [math]::Max(0.0, ($S.LastCommit - $r.LastCommit).TotalSeconds) } else { '?' }
        Write-Host ("    repl  {0} -> {1}: {2} {3}, send queue {4} KB, redo queue {5} KB, lag {6} s (secondary_lag_seconds {7})" -f $r.Ag, $r.Replica, $r.Conn, $r.Sync, $r.SendQKB, $r.RedoQKB, $lag, $r.DmvLag)
    }
}

function Invoke-Status {
    Write-Step 'Status'
    Update-PowerStates
    $st = Get-StatusAll $AllNodes
    foreach ($n in $AllNodes) { Show-NodeStatus $n $st[$n.Vm] }
    if ($Orig.Power -eq 'running') { Show-PrimaryMetrics (Read-PrimarySample) }
}

function Invoke-Precheck {
    Write-Step 'Pre-check: every node running, AGs and distributed AGs healthy'
    # A new run starts here (current-run.txt only moves to it once the pre-check passes).
    $script:RunId = (Get-UtcNow).ToString('yyyyMMdd-HHmmss')
    Start-UcSession
    Set-UcPhase precheck running
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
    foreach ($n in $AllNodes) {
        $localRole = Get-Val $st[$n.Vm] 'LOCAL_ROLE'
        if ($localRole -eq 'PRIMARY' -and $n.Ag -ne $AgName) { $localRole = 'FORWARDER' }
        Set-UcNode -Node $n.Name -Power $n.Power -Role $(if ($localRole) { $localRole } else { 'UNKNOWN' }) -Global ($n.Name -eq $Orig.Name -and $localRole -eq 'PRIMARY') -Partitioned $false
    }
    $problems = Get-HealthProblems $st
    # Leftovers of an interrupted partition drill would keep the DR region cut off.
    foreach ($n in $RegionNodes) {
        $left = @(az network nsg rule list -g $n.Rg --nsg-name $n.Nsg --query "[?starts_with(name, 'uc02-partition')].name" -o tsv 2>$null)
        if ($left.Count) { $problems += "$($n.Nsg) still has partition rules ($($left -join ', ')) - run -Action recover -FailureMode partition" }
    }
    $s = Read-PrimarySample
    Show-PrimaryMetrics $s
    if ($s -and $s.DiskTotalMB) {
        $free = $s.DiskFreeMB * 100 / $s.DiskTotalMB
        if ($free -lt $LowDiskWarnPercent) { $problems += ("log volume {0} has only {1:N0}% free ({2} of {3}) - a long outage under load will fill it (../../sqlvm-linux-ag.ps1 -Action relocate-data moves SQL Server's files to the data disk)" -f $s.DiskMount, $free, (Format-MB $s.DiskFreeMB), (Format-MB $s.DiskTotalMB)) }
        if ($s.DiskMount -notlike '/sqldata*') {
            Add-Event 'log-not-on-data-disk' "$DemoDbName's log is on $($s.DiskMount) ($(Format-MB $s.DiskTotalMB)), not on the data disk" -Level 'warn'
            Write-Host "  NOTE: $DemoDbName's log is on $($s.DiskMount) ($(Format-MB $s.DiskTotalMB)), not on the data disk." -ForegroundColor Yellow
        }
    }
    if ($ProtectPrimaryAtFreePercent -gt 0 -and $ProtectPrimaryAtFreePercent -le $MinFreeDiskPercent) {
        $problems += "-ProtectPrimaryAtFreePercent ($ProtectPrimaryAtFreePercent) must be above -MinFreeDiskPercent ($MinFreeDiskPercent), or the writer stops first"
    }
    if ($problems.Count -gt 0) {
        Write-Host ''
        $problems | ForEach-Object { Write-Host "  PROBLEM: $_" -ForegroundColor Red; Add-Event 'precheck-problem' $_ -Level 'error' }
        Write-Error 'Pre-check failed - fix the problems above before running the drill.'
        exit 1
    }
    Set-Content -Path $CurrentRunFile -Value $script:RunId
    Add-Event 'precheck-passed'
    foreach ($l in (@("ag-$AgName") + @($ForwarderList | ForEach-Object { "ag-$($_.Ag)"; $_.Dag }))) { Set-UcLink -Link $l -State 'healthy' }
    Save-Evidence 'precheck' ([ordered]@{
        runId = $script:RunId; utc = (Format-Utc (Get-UtcNow)); ag = $AgName; failedRegion = $FailedRegion; primaryRegion = $Orig.Region
        workload = $Load; failureMode = $FailureMode; drCommitMode = $DrCommitMode; protectAtFreePercent = $ProtectPrimaryAtFreePercent
        distributedAgs = @($ForwarderList | ForEach-Object { [ordered]@{ name = $_.Dag; forwarderAg = $_.Ag; region = $_.Primary.Region; inFailedRegion = $_.InFailedRegion } })
        nodes = @($AllNodes | ForEach-Object { [ordered]@{ name = $_.Name; role = $_.Role; region = $_.Region; ip = $_.PrivateIp } })
        primary = $(if ($s) { [ordered]@{ logVolume = $s.DiskMount; logVolumeMB = $s.DiskTotalMB; logVolumeFreeMB = $s.DiskFreeMB; agDataMB = $s.DataMB; log = $s.Log } })
        status = @($AllNodes | ForEach-Object { [ordered]@{ node = $_.Name; output = $st[$_.Vm].Stdout } })
    })
    # The sampler starts now: the baseline and everything after it is recorded every -SampleSeconds.
    Invoke-CollectRound | Out-Null
    Write-Host ''
    Write-Host "  Pre-check passed. Drill run id: $($script:RunId)  (evidence: $(Get-RunDir))" -ForegroundColor Green
    Set-UcPhase precheck done "every AG and distributed AG healthy - run $($script:RunId)"
}

# ── Workload ───────────────────────────────────────────────────────────────────
function Set-DrCommitMode {
    param([ValidateSet('SYNCHRONOUS_COMMIT', 'ASYNCHRONOUS_COMMIT')][string]$Mode)
    $r = Invoke-Sql -Node $Orig -File '62-set-dr-commit-mode.sql' -Label "DR replica $Mode" -Vars @{ AgName = $AgName; Replica = $Dr.Name; Mode = $Mode }
    foreach ($v in (Get-Vals $r 'COMMIT_MODE')) { Write-Host "  COMMIT_MODE = $v" }
    Add-Event 'commit-mode' "$($Dr.Name) is now $Mode"
}

function Invoke-StartWorkload {
    Assert-Run
    Write-Step "Starting the workload on $($Orig.Name): $($Load.Label)"
    Set-UcPhase workload running $Load.Label
    if ($DrCommitMode -eq 'sync') { Set-DrCommitMode SYNCHRONOUS_COMMIT }
    Invoke-Sql -Node $Orig -File '01-prepare-load.sql' -Vars @{ DbName = $DemoDbName; RunId = $script:RunId } -Label 'create workload tables' | Out-Null
    $writerSql = Get-Content (Join-Path $SqlDir '02-writer.sql') -Raw
    $seconds = $WorkloadMinutes * 60
    $backup = @"
#!/bin/bash
# UC-02: BACKUP LOG every EVERY s until UNTIL (epoch) or the stop file; keeps the last 30 minutes.
# Lab only: deleting old log backups breaks point-in-time restore.
DB="`$1"; EVERY="`$2"; UNTIL="`$3"; DIR="`$4"
while [ "`$(date +%s)" -lt "`$UNTIL" ] && [ ! -f $WorkDir/stop ]; do
  f="`$DIR/`$DB-`$(date -u +%Y%m%d%H%M%S).trn"
  /opt/mssql-tools18/bin/sqlcmd -S localhost -U SA -No -C -b -Q "BACKUP LOG [`$DB] TO DISK = N'`$f' WITH COMPRESSION" >/dev/null 2>&1 || echo "`$(date -u +%FT%TZ) log backup failed" >> $WorkDir/logbackup.err
  find "`$DIR" -name "`$DB-*.trn" -mmin +30 -delete 2>/dev/null
  sleep "`$EVERY"
done
"@
    $body = @"
mkdir -p $WorkDir && rm -f $WorkDir/stop
$(Get-WriteFileBash "$WorkDir/writer.sql" $writerSql)
$(Get-WriteFileBash "$WorkDir/logbackup.sh" $backup '700')
pkill -f $WorkDir/writer.sql || true
pkill -f $WorkDir/logbackup.sh || true
for s in `$(seq 1 $($Load.Sessions)); do
  nohup setsid /opt/mssql-tools18/bin/sqlcmd -S localhost -U SA -No -C -b -h -1 \
    -v DbName="$DemoDbName" RunId="$($script:RunId)" Session="`$s" Rows="$($Load.Rows)" RowBytes="$($Load.RowBytes)" ThinkMs="$($Load.ThinkMs)" Seconds="$seconds" MinFreePct="$MinFreeDiskPercent" \
    -i $WorkDir/writer.sql > $WorkDir/writer-`$s.log 2>&1 < /dev/null &
done
$(Get-BackupDirBash)
echo "BACKUP_DIR=`$BK"
if [ $LogBackupSeconds -gt 0 ]; then
  nohup setsid $WorkDir/logbackup.sh "$DemoDbName" $LogBackupSeconds `$((`$(date +%s) + $seconds)) "`$BK" > /dev/null 2>&1 < /dev/null &
fi
sleep 10
echo "WRITER_SESSIONS=`$(pgrep -fc $WorkDir/writer.sql)"
SQL -d "$DemoDbName" -Q "SET NOCOUNT ON; SELECT 'WRITER_TX=' + CAST(ISNULL(SUM(tx_ok), 0) AS varchar(20)) + '|' + CAST(ISNULL(SUM(tx_err), 0) AS varchar(20)) FROM dbo.UC02_Writer WHERE run_id = '$($script:RunId)'"
"@
    $r = @(Invoke-VmBatch @(@{ Node = $Orig; Label = 'start writer sessions + log backups'; Body = $body }))[0]
    Assert-Ok $r
    $sessions = [int](Get-Val $r 'WRITER_SESSIONS')
    if ($sessions -lt $Load.Sessions) { Write-Error "Only $sessions of $($Load.Sessions) writer session(s) are running (see $WorkDir/writer-*.log on $($Orig.Vm))."; exit 1 }
    Add-Event 'workload-started' "$sessions session(s); after 10 s: $(Get-Val $r 'WRITER_TX') (committed|failed tx); log backups every $LogBackupSeconds s to $(Get-Val $r 'BACKUP_DIR')"
    Save-Evidence 'workload' ([ordered]@{ utc = (Format-Utc (Get-UtcNow)); profile = $WorkloadProfile; load = $Load; logBackupSeconds = $LogBackupSeconds
                                          backupDir = (Get-Val $r 'BACKUP_DIR'); drCommitMode = $DrCommitMode; reader = (-not $NoReadWorkload) })
    Write-Host "  $sessions writer session(s) running; log backups every $LogBackupSeconds s to $(Get-Val $r 'BACKUP_DIR')." -ForegroundColor Green
    if (-not $NoReadWorkload) { Write-Host "  Reader on $($Dr.Name): what a reporting query sees, every 2 s." -ForegroundColor Green }
    Invoke-CollectRound | Out-Null   # starts the reader
    Set-UcPhase workload done "$sessions session(s) running on $($Orig.Name)$(if ($DrCommitMode -eq 'sync') { ', DR replica SYNCHRONOUS' })"
}

function Stop-Workload {
    $body = (Get-SqlBody -File '03-stop-writer.sql' -Vars @{ DbName = $DemoDbName; RunId = (Get-RunIdOrNone) }) +
        "`ntouch $WorkDir/stop 2>/dev/null || true`npkill -f $WorkDir/writer.sql || true`npkill -f $WorkDir/logbackup.sh || true"
    $r = @(Invoke-VmBatch @(@{ Node = $Orig; Label = 'stop writer sessions + log backups'; Body = $body }))[0]
    Assert-Ok $r
    foreach ($w in (Get-Vals $r 'WRITER')) { Write-Host "  WRITER = $w" }
    $t = "$(Get-Val $r 'TOTAL')".Split('|')
    $totals = [ordered]@{ txOk = (ConvertTo-Number $t[0]); txErr = $(if ($t.Count -ge 2) { ConvertTo-Number $t[1] }); rows = $(if ($t.Count -ge 3) { ConvertTo-Number $t[2] }) }
    Add-Event 'workload-stopped' "committed $($totals.txOk) tx ($($totals.rows) rows), failed $($totals.txErr)"
    return $totals
}

function Invoke-StopWorkload {
    Write-Step "Stopping the workload on $($Orig.Name)"
    Set-UcPhase stopload running
    $t = Stop-Workload
    Stop-Monitoring -Sampler -Reader
    Set-UcPhase stopload done "committed $($t.txOk) tx, failed $($t.txErr)"
}

# ── Baseline / outage ──────────────────────────────────────────────────────────
function Invoke-Baseline {
    param([double]$Seconds)
    Write-Step "Baseline: $([math]::Round($Seconds)) s of normal operation (throughput, log rate, replication lag)"
    Set-UcPhase baseline running "$([math]::Round($Seconds)) s of normal operation"
    $samples = Invoke-MonitorWindow -Seconds $Seconds
    $tps = Get-Average $samples 'txPerSec'; $mbps = Get-Average $samples 'logMBps'
    $queues = @($samples | Where-Object { $_.Values.Contains('behindMB') } | ForEach-Object { $_.Values.behindMB })
    $lags = @($samples | Where-Object { $_.Values.Contains('lagSeconds') } | ForEach-Object { $_.Values.lagSeconds })
    $slow = @($samples | Where-Object { $_.Values.Contains('slowCommitMs') } | ForEach-Object { $_.Values.slowCommitMs })
    $base = [ordered]@{
        utc = (Format-Utc (Get-UtcNow)); samples = $samples.Count; tps = $tps; logMBps = $mbps
        queueMB = $(if ($queues.Count) { [math]::Round(($queues | Measure-Object -Maximum).Maximum, 2) } else { 0 })
        lagSeconds = $(if ($lags.Count) { [math]::Round(($lags | Measure-Object -Maximum).Maximum, 3) } else { 0 })
        avgLagSeconds = $(if ($lags.Count) { [math]::Round(($lags | Measure-Object -Average).Average, 3) } else { 0 })
        slowCommitMs = $(if ($slow.Count) { ($slow | Measure-Object -Maximum).Maximum } else { $null })
        txPerMB = $(if ($tps -and $mbps) { [math]::Round($tps / $mbps, 2) } else { $null })
    }
    Save-Evidence 'baseline' $base
    if ($null -ne $tps) { Set-UcMetric baselineTps $tps 'tx/s' -Detail "average of $($samples.Count) samples before the failure" }
    if ($null -ne $mbps) { Set-UcMetric baselineLogMBps $mbps 'MB/s' }
    Set-UcMetric baselineLagSeconds $base.lagSeconds 's' -Detail "highest DR lag before the failure (average $($base.avgLagSeconds) s; queue up to $(Format-MB $base.queueMB))"
    Write-Host ("  Baseline: {0} tx/s, {1} MB/s of log, DR queue up to {2}, lag {3} s on average (up to {4} s)." -f $tps, $mbps, (Format-MB $base.queueMB), $base.avgLagSeconds, $base.lagSeconds) -ForegroundColor Green
    Set-UcPhase baseline done ("{0} tx/s, {1} MB/s of log, DR lag {2} s" -f $tps, $mbps, $base.avgLagSeconds)
}

function Invoke-Outage {
    param([double]$Seconds)
    Assert-Run
    $failure = Read-Evidence 'failure'
    Write-Step "Running without DR for $(Format-Duration $Seconds) (min:s): the primary keeps committing, the backlog grows"
    Set-UcPhase outage running "$(Format-Duration $Seconds) without the DR region"
    $samples = Invoke-MonitorWindow -Seconds $Seconds -OnSample {
        param($m)
        if ($m.Values.Contains('behindMB') -and -not (Read-Evidence 'protect')) {
            $span = if ($m.Values.Contains('lagSeconds')) { ' · {0:N0} s' -f $m.Values['lagSeconds'] } else { '' }
            Set-UcLink -Link "ag-$AgName" -State 'down' -Note "$(Format-MB $m.Values['behindMB'])$span behind" -Quiet
        }
        return $false
    }
    Save-OutageSummary $samples $failure
    $sum = Read-Evidence 'outage'
    Set-UcPhase outage done ("{0} tx/s on the primary, {1} of log the DR replica doesn't have" -f $sum.tps, (Format-MB $sum.logGeneratedMB))
}

function Save-OutageSummary {
    param([object[]]$Samples, $Failure)
    $last = $Samples | Select-Object -Last 1
    $sum = [ordered]@{ utc = (Format-Utc (Get-UtcNow)); samples = @($Samples).Count; tps = (Get-Average $Samples 'txPerSec') }
    if ($last) {
        $sum.logGeneratedMB = $(if ($last.Values.Contains('behindMB')) { [math]::Round($last.Values['behindMB'], 1) })
        $sum.txDuringOutage = $(if ($last.Values.Contains('txBehind')) { [math]::Round($last.Values['txBehind']) })
        $ferr = Get-EvidenceValue $Failure 'writerErr'
        $sum.writeErrors = $(if ($null -ne $last.Sample.WriterErr -and $null -ne $ferr) { $last.Sample.WriterErr - [double]$ferr })
        $sum.lagAtEndSeconds = $(if ($last.Values.Contains('lagSeconds')) { [math]::Round($last.Values['lagSeconds'], 1) })
    }
    # Commit stall right after the failure (a synchronous DR replica: until the session times out).
    $btps = Get-EvidenceValue (Read-Evidence 'baseline') 'tps'
    if ($btps -and $Failure) {
        $t0 = ConvertTo-Utc $Failure.requestedUtc
        $after = @($Samples | Where-Object { $_.Sample.T -gt $t0 -and $_.Values.Contains('txPerSec') })
        $firstOk = $after | Where-Object { $_.Values['txPerSec'] -ge 0.5 * $btps } | Select-Object -First 1
        if ($firstOk) { $sum.commitStallSeconds = [math]::Max(0.0, [math]::Round(($firstOk.Sample.T - $t0).TotalSeconds - $SampleSeconds, 1)) }
    }
    $slow = @($Samples | Where-Object { $_.Values.Contains('slowCommitMs') } | ForEach-Object { $_.Values['slowCommitMs'] })
    if ($slow.Count) { $sum.slowestCommitMs = ($slow | Measure-Object -Maximum).Maximum }
    $sum.minDiskFreePct = $(if ($null -ne $script:Track.MinDiskFreePct) { [math]::Round($script:Track.MinDiskFreePct, 1) })
    $sum.peakLogSizeMB = $script:Track.PeakLogSizeMB
    Save-Evidence 'outage' $sum
    Publish-OutageMetrics $sum
}

# Throughput impact, backlog, write errors, disk, commit stall - from outage.json (+ baseline.json).
function Publish-OutageMetrics {
    param($Sum)
    $btps = Get-EvidenceValue (Read-Evidence 'baseline') 'tps'
    $otps = Get-EvidenceValue $Sum 'tps'
    if ($null -ne $otps) { Set-UcMetric outageTps $otps 'tx/s' -Detail 'average while the DR region was down' }
    if ($btps -and $null -ne $otps) {
        $impact = [math]::Round([math]::Max(0.0, ($btps - $otps) * 100 / $btps), 1)
        $why = if ($script:Track.WriterStopped) { ' - the writer stopped itself (log volume nearly full)' } else { '' }
        Set-UcMetric throughputImpactPct $impact '%' -Detail "baseline $btps tx/s -> $otps tx/s during the outage$why"
    }
    foreach ($k in @('logGeneratedMB', 'txDuringOutage', 'writeErrors', 'minDiskFreePct', 'peakLogSizeMB', 'commitStallSeconds', 'slowestCommitMs')) {
        $val = Get-EvidenceValue $Sum $k
        if ($null -ne $val) { Set-UcMetric $k $val $(switch ($k) { 'logGeneratedMB' { 'MB' } 'peakLogSizeMB' { 'MB' } 'minDiskFreePct' { '%' } 'commitStallSeconds' { 's' } 'slowestCommitMs' { 'ms' } default { '' } }) }
    }
}

# ── Failure ────────────────────────────────────────────────────────────────────
# Private IPs of every node outside the failed region: their AG traffic with the region is cut.
function Get-PartitionPeers { return @($AllNodes | Where-Object { $_.Region -ne $FailedRegion -or $_.Vm -eq $Orig.Vm } | ForEach-Object { $_.PrivateIp } | Select-Object -Unique) }

function Set-Partition {
    param([switch]$Remove)
    $peers = Get-PartitionPeers
    foreach ($n in $RegionNodes) {
        if ($Remove) {
            foreach ($r in $PartitionRules) { az network nsg rule delete -g $n.Rg --nsg-name $n.Nsg -n $r -o none 2>$null }
            continue
        }
        az network nsg rule create -g $n.Rg --nsg-name $n.Nsg -n 'uc02-partition-in' --priority 105 --direction Inbound --access Deny `
            --protocol Tcp --destination-port-ranges 5022 --source-address-prefixes @peers --destination-address-prefixes '*' `
            --description 'UC-02 network partition: no AG traffic from the other region' -o none
        if ($LASTEXITCODE -ne 0) { Write-Error "Could not create the partition rule on $($n.Nsg)."; exit 1 }
        az network nsg rule create -g $n.Rg --nsg-name $n.Nsg -n 'uc02-partition-out' --priority 105 --direction Outbound --access Deny `
            --protocol Tcp --destination-port-ranges 5022 --source-address-prefixes '*' --destination-address-prefixes @peers `
            --description 'UC-02 network partition: no AG traffic to the other region' -o none
        if ($LASTEXITCODE -ne 0) { Write-Error "Could not create the partition rule on $($n.Nsg)."; exit 1 }
    }
}

function Invoke-SimulateFailure {
    Assert-Run
    $how = if ($FailureMode -eq 'partition') { 'network partition (NSG deny on port 5022) of' } else { 'hard power-off of' }
    Write-Step "Simulating a failure of region $($FailedRegion): $how every node there"
    $victims = @($RegionNodes)
    $victims | ForEach-Object { Write-Host "  $($_.Vm) [$($_.Role)]" }
    Write-Host "  $($Orig.Name) ($($Orig.Region)) stays PRIMARY and keeps committing - no failover." -ForegroundColor Yellow
    Confirm-Yes "  Type 'yes' to fail region $FailedRegion now"
    Set-UcPhase failure running "$FailureMode of $FailedRegion"
    # The newest sample before the failure: the DR backlog is measured from here.
    $round = Invoke-CollectRound
    $pre = if ($round.Count) { $round[$round.Count - 1] } else { $null }
    if (-not $pre) { $s = Read-PrimarySample; if ($s) { $pre = Convert-MonitorSample $s } }
    $t0 = Get-UtcNow
    Set-UcClock unprotected start -At $t0 -Detail "region $FailedRegion lost - no DR copy"
    if ($FailureMode -eq 'partition') {
        Add-Event 'failure-injected' ("NSG deny 5022 between $FailedRegion and the other region: " + (($victims | ForEach-Object { $_.Nsg }) -join ', '))
        Set-Partition
        # NSG rules only stop NEW connections: restart the region's endpoints so the current ones drop.
        $res = @(Invoke-VmBatch @($victims | ForEach-Object { New-SqlRequest -Node $_ -File '63-restart-endpoint.sql' -Label 'restart endpoint' }))
        foreach ($r in $res) { Write-Host "  [$($r.Vm)] $(Get-Val $r 'ENDPOINT_RESTARTED')" }
        foreach ($n in $victims) { Set-UcNode -Node $n.Name -Partitioned $true -Detail "$($n.Name) cut off from the other region" }
    } else {
        Add-Event 'failure-injected' ("az vm stop --skip-shutdown " + (($victims | ForEach-Object { $_.Vm }) -join ', '))
        foreach ($n in $victims) { az vm stop -g $n.Rg -n $n.Vm --skip-shutdown --no-wait -o none }
        foreach ($n in $victims) { Set-UcNode -Node $n.Name -Power 'stopping' }
        $script:DrReachable = $false
    }
    Set-UcLink "ag-$AgName" down -Note $(if ($FailureMode -eq 'partition') { 'partitioned' } else { '' })
    foreach ($f in @($ForwarderList | Where-Object { $_.InFailedRegion })) {
        Set-UcLink $f.Dag down
        if ($FailureMode -ne 'partition') { Set-UcLink "ag-$($f.Ag)" down }   # a partition keeps the region's own traffic
    }
    Save-Evidence 'failure' ([ordered]@{
        method = $(if ($FailureMode -eq 'partition') { 'NSG deny 5022 in/out with the other region + endpoint restart' } else { 'az vm stop --skip-shutdown (hard power-off, VMs stay allocated)' })
        mode = $FailureMode; region = $FailedRegion; vms = @($victims | ForEach-Object { $_.Vm }); requestedUtc = (Format-Utc $t0)
        # Primary counters from the newest sample before the failure (the DR backlog starts here).
        logBytes = $(if ($pre) { $pre.Sample.LogBytes }); writerTx = $(if ($pre) { $pre.Sample.WriterTx }); writerErr = $(if ($pre) { $pre.Sample.WriterErr })
        queueMB = $(if ($pre) { [math]::Round($pre.Dr.QueueMB, 2) } else { 0 }); drCommitMode = $DrCommitMode
    })
    if ($FailureMode -ne 'partition') {
        foreach ($n in $victims) {
            az vm wait -g $n.Rg -n $n.Vm --custom "instanceView.statuses[?code=='PowerState/stopped']" --timeout 600 -o none 2>$null
            if ((Get-PowerState $n) -ne 'stopped') { Write-Error "$($n.Vm) did not power off."; exit 1 }
            Set-UcNode -Node $n.Name -Power 'stopped'
            Write-Host "  $($n.Vm) powered off."
        }
    }
    Set-UcPhase failure done "$($victims.Count) node(s) in $FailedRegion $(if ($FailureMode -eq 'partition') { 'cut off' } else { 'powered off' }) - $($Orig.Name) still PRIMARY"
}

# ── Protecting the primary ─────────────────────────────────────────────────────
function Invoke-ProtectPrimary {
    param([string]$Why = 'requested')
    Assert-Run
    if (Read-Evidence 'protect') { Write-Host '  The primary is already protected.'; return }
    $fwDown = @($ForwarderList | Where-Object { $_.InFailedRegion })
    Write-Host ''
    Write-Host "  PROTECTING THE PRIMARY ($Why): removing $($Dr.Name) from $AgName$(if ($fwDown.Count) { " and dropping $(($fwDown | ForEach-Object { $_.Dag }) -join ', ')" }) so the log can be truncated." -ForegroundColor Yellow
    Write-Host '  They will be re-seeded when their region is back (recover).' -ForegroundColor Yellow
    Add-Event 'protect-primary' "$Why - removing the missing replicas so $DemoDbName's log can be truncated" -Level 'warn'
    $prefix = (Get-BackupDirBash) + "`n"
    $r = Invoke-Sql -Node $Orig -File '60-protect-primary.sql' -Label 'remove missing replicas + log backup' -Prefix $prefix -Vars @{
        AgName = $AgName; Replica = $Dr.Name; Dags = (($fwDown | ForEach-Object { $_.Dag }) -join ','); DbName = $DemoDbName
        BackupFile = "`$BK/$DemoDbName-uc02-protect.trn" }
    foreach ($k in @('REPLICA_REMOVED', 'DAG_DROPPED', 'LOG_REUSE_WAIT')) { foreach ($v in (Get-Vals $r $k)) { Write-Host "  $k = $v" } }
    Set-UcNode -Node $Dr.Name -Role 'REMOVED' -Detail "$($Dr.Name) removed from $AgName to protect the primary"
    Set-UcLink "ag-$AgName" removed
    foreach ($f in $fwDown) { Set-UcLink $f.Dag removed }
    Set-UcMetric primaryProtected $true -Detail $Why
    Save-Evidence 'protect' ([ordered]@{ utc = (Format-Utc (Get-UtcNow)); why = $Why; removed = $Dr.Name; droppedDags = @($fwDown | ForEach-Object { $_.Dag }); reuseWait = (Get-Val $r 'LOG_REUSE_WAIT') })
}

# ── Recovery ───────────────────────────────────────────────────────────────────
function Invoke-Recover {
    Assert-Run
    $failure = Read-Evidence 'failure'
    $mode = if ($failure -and (Get-EvidenceValue $failure 'mode')) { $failure.mode } else { $FailureMode }
    $protected = Read-Evidence 'protect'
    Write-Step "Recovery of region $($FailedRegion): $(if ($mode -eq 'partition') { 'lift the partition' } else { 'start its VMs' }), $(if ($protected) { 're-seed the removed replicas' } else { 'reconnect, catch up' })"
    Set-UcPhase recover running
    $t0 = Get-UtcNow
    # What the outage cost, if 'monitor' didn't already record it.
    if (-not (Read-Evidence 'outage')) { Save-OutageSummary (Invoke-CollectRound) $failure }

    if ($mode -eq 'partition') {
        Set-Partition -Remove
        foreach ($n in $RegionNodes) { Set-UcNode -Node $n.Name -Partitioned $false }
        Add-Event 'partition-lifted' "NSG partition rules removed from $(($RegionNodes | ForEach-Object { $_.Nsg }) -join ', ')"
    } else {
        Update-PowerStates
        $toStart = @($RegionNodes | Where-Object { $_.Power -ne 'running' })
        foreach ($n in $toStart) { Set-UcNode -Node $n.Name -Power 'starting' }
        if ($toStart.Count -gt 0) { Start-UcVms $toStart }
        foreach ($n in $RegionNodes) { Set-UcNode -Node $n.Name -Power 'running' }
        Add-Event 'region-started' (($RegionNodes | ForEach-Object { $_.Vm }) -join ', ')
    }
    $script:DrReachable = $true
    $fwDown = @($ForwarderList | Where-Object { $_.InFailedRegion })

    if ($protected) {
        Invoke-Reseed -Since $t0 -FwDown $fwDown
        $tReconnect = Get-UtcNow
    } else {
        # SQL Server starts with the VM (or the partition is gone): the DR replica reconnects on its own.
        Write-Host "  Waiting for $($Dr.Name) to reconnect to $($Orig.Name) ..."
        $deadline = (Get-UtcNow).AddMinutes($ReconnectTimeoutMinutes)
        $script:Reconnected = $null
        while (-not $script:Reconnected) {
            Invoke-CollectRound -OnSample {
                param($m)
                if ($m.Dr.Connected) { $script:Reconnected = $m; return $true }
                return $false
            } | Out-Null
            if ($script:Reconnected) { break }
            if ((Get-UtcNow) -gt $deadline) { Write-Error "$($Dr.Name) didn't reconnect within $ReconnectTimeoutMinutes min."; exit 1 }
            Start-Sleep -Seconds $FetchSeconds
        }
        $m = $script:Reconnected
        $tReconnect = $m.Sample.T
        Set-UcMetric reconnectSeconds ([math]::Round(($tReconnect - $t0).TotalSeconds, 1)) 's' -Detail "$(if ($mode -eq 'partition') { 'partition lifted' } else { 'VM start requested' }) -> DR replica CONNECTED"
        # After a hard stop, data movement normally resumes on its own; resume anything left suspended.
        if ($m.Dr.Suspended) {
            Write-Host '  Data movement is suspended on the DR replica - resuming it.' -ForegroundColor Yellow
            $res = Invoke-Sql -Node $Dr -File '33-demote-and-resume.sql' -Vars @{ AgName = $AgName; Demote = 0 } -Label 'resume'
            foreach ($v in (Get-Vals $res 'RESUMED')) { Write-Host "  RESUMED = $v" }
        }
        if ($fwDown.Count) {
            Resume-Forwarders $fwDown
            foreach ($f in $fwDown) { Set-UcLink "ag-$($f.Ag)" healthy; Set-UcLink -Link $f.Dag -State 'catching-up' }
        }
        Set-UcMetric recoveredInPlace $true -Detail "region $(if ($mode -eq 'partition') { 'reconnected' } else { 'restarted' }) - no failover, no reseed"
        $behind = if ($m.Values.Contains('behindMB')) { $m.Values['behindMB'] }
        Set-UcLink -Link "ag-$AgName" -State 'catching-up' -Note "$(Format-MB $behind) behind"
        Set-UcPhase recover done "$($Dr.Name) reconnected $(Format-Duration ($tReconnect - $t0).TotalSeconds) (min:s) after the $(if ($mode -eq 'partition') { 'partition was lifted' } else { 'VMs were started' })"
    }
    Invoke-CatchUp -Since $tReconnect -Failure $failure
}

# After protect-primary: the DR replica and the forwarders in the region are re-seeded from scratch.
function Invoke-Reseed {
    param([datetime]$Since, [object[]]$FwDown)
    Write-Host "  $($Dr.Name) was removed from $AgName while it was down: re-seeding it." -ForegroundColor Yellow
    $dbs = @(Get-Vals (Invoke-Sql -Node $Orig -File '24-replica-sync-state.sql' -Vars @{ AgName = $AgName; ReplicaName = $Orig.Name } -Label 'AG databases') 'SYNC' |
        ForEach-Object { $_.Split('|')[0] })
    $drop = Invoke-Sql -Node $Dr -File '61-drop-stale-secondary.sql' -Label 'drop stale copy' -Vars @{ AgName = $AgName; Dbs = ($dbs -join ',') }
    foreach ($k in @('AG_DROPPED', 'DB_DROPPED', 'DB_DROP_FAILED')) { foreach ($v in (Get-Vals $drop $k)) { Write-Host "  $k = $v" } }
    Set-UcNode -Node $Dr.Name -Role 'OUT OF AG'
    $add = Invoke-Sql -Node $Orig -File '22-add-replica.sql' -Label 'add replica' -Vars @{ AgName = $AgName; ReplicaName = $Dr.Name; EndpointUrl = "tcp://$($Dr.PrivateIp):5022" }
    Write-Host "  REPLICA_ADDED = $(Get-Val $add 'REPLICA_ADDED')"
    $join = Invoke-Sql -Node $Dr -File '23-join-secondary.sql' -Vars @{ AgName = $AgName } -Label 'join AG'
    Write-Host "  JOINED = $(Get-Val $join 'JOINED')"
    Set-UcNode -Node $Dr.Name -Role 'SEEDING'
    Set-UcLink -Link "ag-$AgName" -State 'seeding'
    Add-Event 'reseed-started' "$($Dr.Name) re-added to $AgName, automatic seeding from $($Orig.Name)"
    Wait-ReplicaState -On $Orig -Replica $Dr.Name -Accept @('SYNCHRONIZING', 'SYNCHRONIZED') -TimeoutMinutes $SeedTimeoutMinutes -What 'seeding'
    Set-UcNode -Node $Dr.Name -Role 'SECONDARY'
    foreach ($f in $FwDown) {
        Invoke-ReseedForwarder $f
        Set-UcLink "ag-$($f.Ag)" healthy
        Set-UcLink -Link $f.Dag -State 'synchronizing'
    }
    Set-UcMetric recoveredInPlace $false -Detail 're-seeded: the primary was protected while the region was down'
    Set-UcMetric reseeded $true -Detail "$($Dr.Name)$(if ($FwDown.Count) { ' + ' + (($FwDown | ForEach-Object { $_.Ag }) -join ', ') }) re-seeded in $(Format-Duration ((Get-UtcNow) - $Since).TotalSeconds) (min:s)"
    Set-UcPhase recover done "re-seeded in $(Format-Duration ((Get-UtcNow) - $Since).TotalSeconds) (min:s)"
}

# Catch-up of the DR replica (then of the forwarders in the failed region): backlog, net drain rate,
# % done, ETA and a reseed estimate, until the queues and the lag are back to normal. Every sample is
# processed at its own time, so the catch-up is measured with the sampler's resolution.
function Invoke-CatchUp {
    param([datetime]$Since, $Failure)
    $base = Read-Evidence 'baseline'
    $qThr = [math]::Max($CaughtUpQueueMB, 2 * [double](Get-EvidenceValue $base 'queueMB'))
    $lagThr = [math]::Max($CaughtUpLagSeconds, 2 * [double](Get-EvidenceValue $base 'lagSeconds'))
    Write-Step ("Catch-up: until the DR queue is <= {0} and the lag <= {1} s" -f (Format-MB $qThr), $lagThr)
    Set-UcPhase catchup running
    Set-UcClock catchup start -At $Since -Detail "$($Dr.Name) back"
    $c = @{
        FwDown = @($ForwarderList | Where-Object { $_.InFailedRegion }); QThr = $qThr; LagThr = $lagThr; Since = $Since; Failure = $Failure
        Hist = [System.Collections.Generic.List[object]]::new(); FwHist = [System.Collections.Generic.List[object]]::new()
        Peak = 0.0; FwPeak = 0.0; DrDoneAt = $null; Stalled = 0; Warned = $false; ReseedWarned = $false; MaxSendMBps = 0.0
        Done = $false; Result = [ordered]@{}
    }
    $script:CatchUpState = $c
    $deadline = (Get-UtcNow).AddMinutes($CatchUpTimeoutMinutes)
    while (-not $c.Done) {
        $t = Get-UtcNow
        Invoke-CollectRound -OnSample { param($m) Step-CatchUp $m $script:CatchUpState } | Out-Null
        if ($c.Done) { break }
        if ((Get-UtcNow) -gt $deadline) {
            if (-not $c.DrDoneAt) {
                Set-UcMetric caughtUp $false -Detail "not caught up after $CatchUpTimeoutMinutes min"
                Set-UcPhase catchup failed "not caught up within $CatchUpTimeoutMinutes min"
            } else {
                Set-UcMetric forwardersCaughtUp $false -Detail "not caught up within $CatchUpTimeoutMinutes min"
                Set-UcPhase fwcatchup failed "not caught up within $CatchUpTimeoutMinutes min"
            }
            Save-Evidence 'recover' $c.Result
            Write-Error "Catch-up didn't complete within $CatchUpTimeoutMinutes min (-CatchUpTimeoutMinutes)."
            exit 1
        }
        $wait = $FetchSeconds - ((Get-UtcNow) - $t).TotalSeconds
        if ($wait -gt 0) { Start-Sleep -Seconds $wait }
    }
    Save-Evidence 'recover' $c.Result
}

# One sample of the catch-up. Returns $true once the DR replica and the forwarders have caught up.
function Step-CatchUp {
    param($M, $C)
    $v = $M.Values; $drState = $M.Dr; $at = $M.Sample.T
    if ($at -lt $C.Since) { return $false }   # samples from before the reconnect
    $behind = if ($v.Contains('behindMB')) { [double]$v['behindMB'] } else { 0.0 }
    if (-not $C.DrDoneAt) {
        $C.Peak = [math]::Max($C.Peak, $behind)
        $C.Hist.Add(@($at, $behind))
        $drain = $null
        if ($C.Hist.Count -ge 2) {
            $a = $C.Hist[[math]::Max(0, $C.Hist.Count - 6)]; $b = $C.Hist[$C.Hist.Count - 1]
            $dt = ($b[0] - $a[0]).TotalSeconds
            if ($dt -gt 0) { $drain = ($a[1] - $b[1]) / $dt }
        }
        $v.catchupPct = if ($C.Peak -gt 0) { [math]::Min(100.0, [math]::Max(0.0, 100 * (1 - $behind / $C.Peak))) } else { 100.0 }
        $v.etaSeconds = if ($null -ne $drain -and $drain -gt 0.01) { $behind / $drain } else { -1 }
        if ($null -ne $drain) { $v.drainMBps = $drain }
        # Reseed estimate: the AG data a reseed would copy / the seeding throughput (given, or the best
        # send rate seen so far).
        if ($drState.SendRateMBps -gt $C.MaxSendMBps) { $C.MaxSendMBps = $drState.SendRateMBps }
        $seedRate = if ($SeedingMBps -gt 0) { $SeedingMBps } elseif ($C.MaxSendMBps -gt 0) { $C.MaxSendMBps } else { 0 }
        if ($seedRate -gt 0 -and $M.Sample.DataMB) {
            $v.reseedEtaSeconds = $M.Sample.DataMB / $seedRate
            $slower = $v.etaSeconds -lt 0 -or $v.etaSeconds -gt 1.5 * $v.reseedEtaSeconds
            if ($slower -and $behind -gt $C.QThr -and $C.Hist.Count -ge 4 -and -not $C.ReseedWarned) {
                $C.ReseedWarned = $true
                Add-Event 'reseed-recommended' ("catch-up ETA {0} vs reseed ~{1} ({2} of data at {3:N1} MB/s): a reseed would be faster" -f $(if ($v.etaSeconds -ge 0) { Format-Duration $v.etaSeconds } else { 'unknown' }), (Format-Duration $v.reseedEtaSeconds), (Format-MB $M.Sample.DataMB), $seedRate) -Level 'warn'
                Set-UcMetric recommendation 'reseed' -Detail "catching up is slower than re-seeding ~$(Format-MB $M.Sample.DataMB)"
            }
        }
        $note = "$(Format-MB $behind) behind · $(if ($v.etaSeconds -ge 0) { "ETA $(Format-Duration $v.etaSeconds)" } else { 'not converging' })"
        Set-UcLink -Link "ag-$AgName" -State 'catching-up' -Note $note -Quiet
        if ($null -ne $drain -and $drain -le 0 -and $behind -gt $C.QThr) { $C.Stalled++ } else { $C.Stalled = 0 }
        if ($C.Stalled -ge 4 -and -not $C.Warned) {
            $C.Warned = $true
            $gen = if ($v.Contains('logMBps')) { '{0:N1}' -f $v['logMBps'] } else { '?' }
            Add-Event 'not-converging' "the backlog isn't shrinking: the primary generates $gen MB/s of log and the DR replica doesn't drain it faster - reduce the load, or reseed" -Level 'warn'
        }
        $lagOk = -not $v.Contains('lagSeconds') -or $v['lagSeconds'] -le $C.LagThr
        if ($drState.Connected -and $drState.Synchronizing -and $behind -le $C.QThr -and $lagOk) {
            $C.DrDoneAt = $at
            $v.catchupPct = 100.0; $v.etaSeconds = 0
            $catchUpS = [math]::Round(($at - $C.Since).TotalSeconds, 1)
            $unprot = if ($C.Failure) { [math]::Round(($at - (ConvertTo-Utc $C.Failure.requestedUtc)).TotalSeconds, 1) }
            Set-UcClock catchup stop -At $at -Detail "$($Dr.Name) caught up"
            Set-UcClock unprotected stop -At $at -Detail "$($Dr.Name) back in sync - DR protection restored"
            Set-UcMetric catchUpSeconds $catchUpS 's' -Detail 'DR replica back -> caught up'
            if ($null -ne $unprot) { Set-UcMetric timeUnprotectedSeconds $unprot 's' -Detail 'failure -> DR replica caught up' }
            Set-UcMetric peakBehindMB ([math]::Round($C.Peak, 1)) 'MB' -Detail 'largest DR queue after it came back'
            if ($catchUpS -gt 0) { Set-UcMetric avgCatchUpMBps ([math]::Round($C.Peak / $catchUpS, 2)) 'MB/s' -Detail 'peak queue / catch-up time (net of new log)' }
            Set-UcMetric caughtUp $true -Detail ("queue {0}, lag {1} s" -f (Format-MB $behind), $(if ($v.Contains('lagSeconds')) { '{0:N1}' -f $v['lagSeconds'] } else { '-' }))
            if (-not $C.ReseedWarned -and $v.Contains('reseedEtaSeconds')) { Set-UcMetric recommendation 'catch-up' -Detail "catching up ($(Format-Duration $catchUpS)) beat the estimated reseed (~$(Format-Duration $v['reseedEtaSeconds']))" }
            Set-UcLink -Link "ag-$AgName" -State 'synchronizing'
            $C.Result.dr = [ordered]@{ caughtUpUtc = (Format-Utc $at); catchUpSeconds = $catchUpS; timeUnprotectedSeconds = $unprot; peakBehindMB = [math]::Round($C.Peak, 1) }
            Set-UcPhase catchup done "caught up in $(Format-Duration $catchUpS) (min:s), peak backlog $(Format-MB $C.Peak)"
            Write-Host "  $($Dr.Name) caught up in $(Format-Duration $catchUpS) (min:s) (sample of $($at.ToString('HH:mm:ss')))." -ForegroundColor Green
            if ($C.FwDown.Count) { Set-UcPhase fwcatchup running } else {
                Set-UcMetric forwardersCaughtUp 'n/a' -Detail "no forwarder in $FailedRegion"
                Set-UcPhase fwcatchup skipped "no forwarder in $FailedRegion"
                $C.Done = $true
                return $true
            }
        }
    }
    if ($C.DrDoneAt -and $C.FwDown.Count) {
        $fwBehind = if ($v.Contains('fwBehindMB')) { [double]$v['fwBehindMB'] } else { 0.0 }
        $C.FwPeak = [math]::Max($C.FwPeak, $fwBehind)
        $C.FwHist.Add(@($at, $fwBehind))
        if ($C.FwHist.Count -ge 2) {
            $a = $C.FwHist[[math]::Max(0, $C.FwHist.Count - 6)]; $b = $C.FwHist[$C.FwHist.Count - 1]
            $dt = ($b[0] - $a[0]).TotalSeconds
            $drain = if ($dt -gt 0) { ($a[1] - $b[1]) / $dt } else { $null }
            $v.fwEtaSeconds = if ($null -ne $drain -and $drain -gt 0.01) { $fwBehind / $drain } else { -1 }
        }
        $v.fwCatchupPct = if ($C.FwPeak -gt 0) { [math]::Min(100.0, [math]::Max(0.0, 100 * (1 - $fwBehind / $C.FwPeak))) } else { 100.0 }
        $pending = 0
        foreach ($f in $C.FwDown) {
            $fm = Measure-Replica $M.Sample $f.Dag $f.Ag
            $ok = $fm.Connected -and $fm.Synchronizing -and $fm.QueueMB -le $C.QThr
            if (-not $ok) { $pending++; Set-UcLink -Link $f.Dag -State 'catching-up' -Note "$(Format-MB $fm.QueueMB) behind" -Quiet }
        }
        if ($pending -eq 0) {
            $v.fwCatchupPct = 100.0; $v.fwEtaSeconds = 0
            foreach ($f in $C.FwDown) { Set-UcLink -Link $f.Dag -State 'synchronizing' }
            $fwS = [math]::Round(($at - $C.Since).TotalSeconds, 1)
            Set-UcMetric forwardersCaughtUp $true -Detail "$(($C.FwDown | ForEach-Object { $_.Ag }) -join ', ') caught up $(Format-Duration $fwS) (min:s) after the region came back"
            $C.Result.forwarders = [ordered]@{ caughtUpSeconds = $fwS; peakBehindMB = [math]::Round($C.FwPeak, 1) }
            Set-UcPhase fwcatchup done "$(($C.FwDown | ForEach-Object { $_.Ag }) -join ', ') caught up"
            $C.Done = $true
            return $true
        }
    }
    return $false
}

# ── Verification ───────────────────────────────────────────────────────────────
function Invoke-Verify {
    Assert-Run
    Write-Step 'Verification: every committed transaction on every replica'
    Set-UcPhase verify running
    $totals = $null
    if (-not $KeepWorkload) {
        Stop-Monitoring -Reader   # its freshness only means something while rows keep arriving
        $totals = Stop-Workload
    }
    # Wait until nothing meaningful is queued for any remote replica (the writer is stopped).
    $deadline = (Get-UtcNow).AddMinutes(10)
    $script:Drained = $false
    while (-not $script:Drained) {
        Invoke-CollectRound -OnSample {
            param($m)
            $queued = 0.0
            foreach ($r in $m.Sample.Reps) { $queued += [double]$(if ($r.SendQKB) { $r.SendQKB } else { 0 }) + [double]$(if ($r.RedoQKB) { $r.RedoQKB } else { 0 }) }
            if ($KeepWorkload -or $queued -lt 1024) { $script:Drained = $true; return $true }
            return $false
        } | Out-Null
        if ($script:Drained) { break }
        if ((Get-UtcNow) -gt $deadline) { Write-Host '  Queues still not empty after 10 min - comparing anyway.' -ForegroundColor Yellow; break }
        Start-Sleep -Seconds 10
    }
    $targets = @($Orig, $Dr) + @($ForwarderList | ForEach-Object { $_.Primary })
    $rows = [ordered]@{}
    for ($attempt = 1; $attempt -le 4; $attempt++) {   # redo can finish a few seconds after the queue reads 0
        $counts = @(Invoke-VmBatch @($targets | ForEach-Object { New-SqlRequest -Node $_ -File '41-row-count.sql' -Label 'row count' -Vars @{ DbName = $DemoDbName; RunId = (Get-RunIdOrNone) } }))
        for ($i = 0; $i -lt $targets.Count; $i++) { $rows[$targets[$i].Name] = if ($counts[$i].Exit -eq 0) { "$(Get-Val $counts[$i] 'ROWS')".Split('|')[0] } else { 'unreadable' } }
        if ($KeepWorkload -or -not @($rows.Values | Where-Object { $_ -ne $rows[$Orig.Name] }).Count) { break }
        Start-Sleep -Seconds 15
    }
    foreach ($k in $rows.Keys) { Write-Host "  rows on $k : $($rows[$k])" }
    $primaryRows = $rows[$Orig.Name]
    if ($primaryRows -eq 'unreadable') { Write-Error "Couldn't count the rows on $($Orig.Name)."; exit 1 }
    $match = -not @($rows.Values | Where-Object { $_ -ne $primaryRows }).Count
    Set-UcMetric rowsPrimary ([int64]$primaryRows) '' -Detail "rows the workload committed on $($Orig.Name)"
    if ($rows[$Dr.Name] -ne 'unreadable') { Set-UcMetric rowsDr ([int64]$rows[$Dr.Name]) '' -Detail "the same rows read on $($Dr.Name)" }
    if ($KeepWorkload) { Set-UcMetric rowsMatch 'n/a' -Detail 'writer still running (-KeepWorkload)' }
    else { Set-UcMetric rowsMatch $match -Detail (($rows.GetEnumerator() | ForEach-Object { "$($_.Key.Split('-')[-2])-$($_.Key.Split('-')[-1]) $($_.Value)" }) -join ', ') }
    if ($totals -and $null -ne $totals.txErr) { Set-UcMetric writeErrors $totals.txErr '' -Detail "failed transactions over the whole run ($($totals.txOk) committed)" }
    if ((Get-EvidenceValue (Read-Evidence 'workload') 'drCommitMode') -eq 'sync') { Set-DrCommitMode ASYNCHRONOUS_COMMIT }
    if (-not $KeepWorkload) { Stop-Monitoring -Sampler }

    Update-PowerStates
    $st = Get-StatusAll $AllNodes
    $problems = Get-HealthProblems $st
    foreach ($p in $problems) { Write-Host "  PROBLEM: $p" -ForegroundColor Red }
    Save-Evidence 'verify' ([ordered]@{ utc = (Format-Utc (Get-UtcNow)); rows = $rows; rowsMatch = $match; writer = $totals; problems = $problems })
    $pass = ($KeepWorkload -or $match) -and $problems.Count -eq 0
    Write-Host ''
    if ($pass) { Write-Host "  PASS - every replica is healthy$(if (-not $KeepWorkload) { " and has all $primaryRows rows" })." -ForegroundColor Green }
    else { Write-Host '  FAIL - see above.' -ForegroundColor Red }
    Set-UcPhase verify $(if ($pass) { 'done' } else { 'failed' }) $(if ($pass) { "PASS - $primaryRows rows on every replica" } else { "FAIL - $(@($problems) + @(if (-not $match) { 'row counts differ' }) -join '; ')" })
}

# ── Cleanup ────────────────────────────────────────────────────────────────────
function Invoke-Cleanup {
    Write-Step "Cleanup on $($Orig.Name): stop the workload, empty the load table, back up + shrink the log"
    Confirm-Yes "  Type 'yes' to delete the workload rows (dbo.UC02_Load) and shrink $DemoDbName's log to $CleanupLogMB MB"
    Set-UcPhase stopload running
    $t = Stop-Workload
    Stop-Monitoring -Sampler -Reader
    if ((Get-EvidenceValue (Read-Evidence 'workload') 'drCommitMode') -eq 'sync') { Set-DrCommitMode ASYNCHRONOUS_COMMIT }
    Set-UcPhase stopload done "committed $($t.txOk) tx, failed $($t.txErr)"
    Set-UcPhase reclaim running
    $prefix = (Get-BackupDirBash) + "`nrm -f `$BK/$DemoDbName-2*.trn`n"
    $r = Invoke-Sql -Node $Orig -File '50-cleanup.sql' -Label 'truncate + log backup + shrink' -Prefix $prefix -Vars @{ DbName = $DemoDbName; BackupFile = "`$BK/$DemoDbName-uc02-cleanup.trn"; TargetLogMB = $CleanupLogMB }
    $before = Get-Val $r 'LOG_BEFORE_MB'; $after = Get-Val $r 'LOG_AFTER_MB'
    Write-Host "  $DemoDbName log: $before MB -> $after MB (reuse wait now $(Get-Val $r 'LOG_REUSE_WAIT'))." -ForegroundColor Green
    Invoke-VmBatch @(@{ Node = $Orig; Label = 'remove sampler files'; Body = "rm -f $WorkDir/samples-*.log $WorkDir/fetch.txt" }) -Quiet | Out-Null
    Save-Evidence 'cleanup' ([ordered]@{ utc = (Format-Utc (Get-UtcNow)); logBeforeMB = $before; logAfterMB = $after; reuseWait = (Get-Val $r 'LOG_REUSE_WAIT') })
    Set-UcPhase reclaim done "log $before MB -> $after MB"
}

function Invoke-Monitor {
    Assert-Run
    $failure = Read-Evidence 'failure'
    $recovered = Read-Evidence 'recover'
    if (-not $failure) { Invoke-Baseline -Seconds ($MonitorMinutes * 60) }
    elseif (-not $recovered) { Invoke-Outage -Seconds ($MonitorMinutes * 60) }
    else { Write-Step "Monitoring the primary for $MonitorMinutes min"; Invoke-MonitorWindow -Seconds ($MonitorMinutes * 60) | Out-Null }
}

# ── Inputs ─────────────────────────────────────────────────────────────────────
Connect-UcAzure
Write-Host ''
Write-Host 'UC-02 - Region failure of the secondary node -> keep running on the primary, recover the region in place' -ForegroundColor White
if (-not $Action) {
    $Action = Read-Choice -Prompt 'What do you want to do?' -Default 'status' `
        -Options @('status', 'precheck', 'start-workload', 'monitor', 'simulate-failure', 'protect-primary', 'recover', 'verify', 'stop-workload', 'cleanup', 'report', 'drill') `
        -Descriptions @('roles, health, power state, primary key metrics', 'healthy AGs? open a new drill run, start the sampler', 'writer + log backups on the primary, reader on DR',
                        'collect samples (baseline before the failure, outage after it)', 'power-off (or -FailureMode partition) of the DR region',
                        'remove the missing replicas so the primary log can be truncated', 'bring the region back, reconnect or re-seed, track the catch-up',
                        'stop the writer, compare rows on every replica', 'stop the writer, the log backups and the reader',
                        'empty the load table, shrink the log', 'static HTML report of the current run',
                        'precheck -> workload -> baseline -> failure -> outage -> recover -> verify -> report')
}
Initialize-UcTopology -FailingSide secondary `
    -PrimaryPrompt 'AG1 primary node suffix - stays up' `
    -SecondaryPrompt 'AG1 DR node suffix - the node in the region that FAILS'
# A later action of the same run (e.g. monitor after simulate-failure): the DR VM may still be off.
if ($script:RunId -and $Action -notin @('precheck', 'drill', 'status', 'report')) {
    $f = Read-Evidence 'failure'
    if ($f -and $f.mode -ne 'partition' -and -not (Read-Evidence 'recover')) { $script:DrReachable = $false }
}
$script:UcSessionParams = @{ workload = $Load.Label; outage = "$OutageMinutes min"; secondaryRegion = $Dr.Region
                             failureMode = $(if ($FailureMode -eq 'partition') { 'network partition' } else { 'power-off' })
                             commitMode = $(if ($DrCommitMode -eq 'sync') { 'synchronous' } else { 'asynchronous' }) }

if ($Orig.Region -eq $Dr.Region) {
    Write-Host ''
    Write-Host "WARNING: $($Orig.Name) and $($Dr.Name) are both in $($Orig.Region): this can only fail the DR node," -ForegroundColor Red
    Write-Host 'a real region failure would take the primary too. The drill still exercises the recovery mechanics.' -ForegroundColor Red
    Confirm-Yes "Type 'yes' to continue anyway"
}

Invoke-UcMain -OpensRun @('precheck', 'drill') -ReadOnly @('status', 'report') -Banner {
    Write-Host "AG1 $AgName : $($Orig.Name) ($($Orig.Region), primary - stays up) -> $($Dr.Name) ($($Dr.Region), DR - fails)"
    foreach ($f in $ForwarderList) {
        Write-Host ("Distributed AG {0} : {1} -> {2} ({3}, {4}){5}" -f $f.Dag, $AgName, $f.Ag, $f.Primary.Region,
            (($f.Nodes | ForEach-Object { $_.Name }) -join ' + '), $(if ($f.InFailedRegion) { ' - fails with the region' } else { ' - keeps running' }))
    }
    Write-Host "Failure domain (region $FailedRegion): $(($RegionNodes | ForEach-Object { $_.Name }) -join ', ') - $FailureMode"
    Write-Host "Workload: $($Load.Label); DR replica $DrCommitMode$(if ($ProtectPrimaryAtFreePercent -gt 0) { "; protect the primary below $ProtectPrimaryAtFreePercent% free" })"
} -Actions @{
    'status'           = { Invoke-Status }
    'precheck'         = { Invoke-Precheck }
    'start-workload'   = { Invoke-StartWorkload }
    'monitor'          = { Invoke-Monitor }
    'simulate-failure' = { Invoke-SimulateFailure }
    'protect-primary'  = { Invoke-ProtectPrimary -Why 'requested (-Action protect-primary)' }
    'recover'          = { Invoke-Recover }
    'verify'           = { Invoke-Verify }
    'stop-workload'    = { Invoke-StopWorkload }
    'cleanup'          = { Invoke-Cleanup }
    'report'           = { Export-UcReport }
    'drill'            = {
        Write-Host ''
        Write-Host "Drill: a $WorkloadProfile workload on $($Orig.Name) (DR replica $DrCommitMode), then every node in $FailedRegion ($(($RegionNodes | ForEach-Object { $_.Name }) -join ', '))" -ForegroundColor Yellow
        Write-Host "fails ($FailureMode) for $OutageMinutes min and is recovered. $($Orig.Name) stays PRIMARY throughout." -ForegroundColor Yellow
        Confirm-Yes "Type 'yes' to run the full drill"
        $script:AutoApprove = $true   # one confirmation for the whole drill
        Invoke-Precheck
        Invoke-StartWorkload
        Invoke-Baseline -Seconds $WarmupSeconds
        Invoke-SimulateFailure
        Invoke-Outage -Seconds ($OutageMinutes * 60)
        Invoke-Recover
        Invoke-Verify
        Write-Host ''
        Write-Host "Drill complete. Evidence: $(Get-RunDir)" -ForegroundColor Green
        Export-UcReport
        Write-Host "Reclaim the space the workload used: ./uc-02.ps1 -Action cleanup -Identifier $Identifier -PrimaryNodeSuffix $PrimaryNodeSuffix -SecondaryNodeSuffix $SecondaryNodeSuffix$(Get-UcForwardersArg)"
    }
}
