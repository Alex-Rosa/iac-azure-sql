# Use-case dashboard

A visual view of a use-case run, for presentations: what's happening now, the topology (regions,
nodes, roles, replication links), the outage clock, RTO/RPO, the success criteria and an event
log. It can show a run **live** or **replay** a recorded one.

```
pwsh ./dashboard/dashboard.ps1                     # asks: stack, live or replay, web or terminal, refresh
pwsh ./sqlvm-linux-ag.ps1 -Action dashboard        # same, from the menu (6) Dashboard)
```

## Two views of the same data

| | Web page | Terminal |
|---|---|---|
| Start | `-Mode web` (default) | `-Mode terminal` |
| Where | `http://localhost:8765` (this machine only), opened in your browser | the current console, redrawn in place |
| Refresh | every `-RefreshSeconds` (default 3); clocks tick smoothly in between | every `-RefreshSeconds`; replay every second |
| Keys | `space` pause · `n`/`p` next/previous phase · `r` restart · `+`/`-` speed · `t` view | same, plus `q` quit |

`-Mode both` runs the web page and opens the terminal view in a new Terminal window. Both then
show the same replay position, and either one can control it.

**Executive / Technical.** The executive view (default) shows region, node and role, the outage
clock, RTO/RPO and the success criteria. It also shows a one-line explanation of the running
phase. The technical view adds VM names, IPs, AG and distributed AG names, link states, every
metric, phase durations and the full event log (node, link and metric changes). Switch with the
button on the page or `t` in either view. `-View technical` starts in it, and so does
`?view=technical` in the page URL.

The page has no external dependencies: no CDN and no web fonts. It works offline on a projector,
and in light or dark mode (the ◐ button).

## Reading the dashboard

The page has six areas, from top to bottom:
- **Narration banner:** what is happening now.
- **Topology:** the regions, nodes and replication links.
- **Key numbers** and **Success criteria**, on the right.
- **Monitoring:** progress bars and charts, for use cases that sample metrics (UC-02).
- **Progress:** every phase of the use case.
- **Events:** the log, newest first.

The banner, topology, monitoring and events work the same for every use case. The key numbers,
success criteria and phases come from each use case's `dashboard.json`. UC-01's and UC-02's are
described below.

### Narration banner

| Colour | Meaning |
|---|---|
| Blue bar, spinner | A phase is running. The small labels show the stage and phase, and the large text explains it in plain language. |
| Green bar | The last action completed (e.g. "failback completed"). |
| Red bar and background | The action stopped: the error, or "cancelled by the operator". |
| Grey bar | Nothing recorded yet. |

Between two phases of a running action (for example while the operator is asked to confirm), it
reads "*<action>* in progress".

### Topology

The topology has one column per region, with the failed region first. Nodes are grouped by AG:
AG1 (the global primary AG) at the top, then the forwarder AGs (AG2, AG3, ...).

**Regions**

| Badge | Meaning |
|---|---|
| ● UP (green) | At least one node in the region is running. |
| ■ REGION DOWN (red, dashed red outline, tinted) | Every node in the region is stopped, stopping or deallocated. |
| ✂ PARTITIONED (red, dotted outline, tinted) | Every node in the region is running but cut off from the other region by the network (UC-02 `-FailureMode partition`). |
| ▲ RECOVERING (amber) | A node in the region is starting. |

The line under the region name is its role in the use case: *primary region* (the one that
fails) or *DR region* (the one that takes over).

**Node cards**

| Element | Meaning |
|---|---|
| Dot ● green / amber / red / grey | Power state: running / starting or stopping / stopped or deallocated / unknown. In live mode this comes from Azure every `-PowerPollSeconds`; the tooltip says "(live)". |
| **★ AG1** (gold) with a gold border | The **global primary**: primary replica of AG1, and so the source of every distributed AG. |
| Blue border | Primary replica of its own AG. |
| Red dashed border, greyed text | The VM is off. |
| Amber dashed border, 🔒 FENCED | NSG deny rules isolate the node (1433 in, 5022 in and out), so a stale primary can't take clients or talk to other replicas. |
| Red dotted border, ✂ CUT OFF | The node runs, but its AG traffic with the other region is blocked (network partition). |
| AG label (AG1, AG2, ...) | The AG the node belongs to. The technical view adds the VM name and private IP. |

**Role pills**

| Role | Meaning |
|---|---|
| PRIMARY (blue) | Primary replica of its AG, accepting writes (for AG1, only when it is also the global primary and running). |
| SECONDARY (grey) | Secondary replica, receiving changes from its AG's primary. |
| FORWARDER (purple) | Primary of a forwarder AG: it receives the changes from the global primary over the distributed AG and forwards them to its own secondary. It is read-only for applications. |
| REMOVED (red) | The lost primary was removed from AG1 by the forced failover, so it can't come back as a second primary. |
| STALE PRIMARY (red) | The old primary after its region came back. It boots still believing it is PRIMARY with its old data, which is why it is fenced. |
| OUT OF AG (amber) | Its stale AG, distributed AG and databases were dropped (preserved as backups). It is waiting to rejoin. |
| SEEDING (amber) | Rejoined as a secondary and receiving a fresh copy of the databases (automatic seeding). |
| UNKNOWN | The pre-check couldn't read its role. |

A STOPPED / STOPPING / STARTING tag next to the role repeats a non-running power state.

**Links**

The arrow points in the direction data flows, from primary to secondary. Hover over a link for its
full description. The technical view writes the state next to every link.

| On the page | In the terminal | State | Meaning |
|---|---|---|---|
| Solid green | `━━━` | healthy | The link is connected and healthy (set by the pre-check). |
| Green dashes moving along the arrow | `━▶━` | synchronizing / synchronized | Changes are replicating. *synchronizing* is the normal state of an asynchronous link; *synchronized* is shown during the failback, when AG1 is temporarily synchronous. |
| Amber dashes moving | `╍▶╍` | seeding | A replica is being rebuilt from scratch (automatic seeding after a rejoin). |
| Thicker amber dashes moving fast | `━▶━` (amber) | catching-up | A replica is back and replaying the log it missed while it was down (UC-02). |
| Amber dotted | `╍ ╍` | suspended | The link points at the right primary but data movement is paused. This happens right after the distributed AGs are repointed, until the forwarder is resumed. |
| Red dotted | `╳ ╳` | down | The source or the target is gone, e.g. its region is powered off. |
| Red dotted | `╳╳╳` | not-synchronizing | Both ends are up, but the forwarder can't resynchronize: it holds transactions the new global primary never had, and needs a re-seed (`-ReseedForwarder`). |
| Faint grey dotted | (blank) | removed | The replica was removed from the AG (the lost primary after the forced failover). |

**Link notes.** A short text under a link gives its current figure, e.g. "812 MB behind · ETA 1:40"
while a replica catches up, or "not converging" when its backlog isn't shrinking. In the terminal
it is in brackets after the link.

**Application box**

The *Application* box at the top stands for the clients. A **blue moving arrow** ("writes →
node-2") points to the node that can accept transactions: the running global primary. From the
region failure until the forced failover, the box turns **red** ("no writable primary"). That is
the outage the clock measures. In UC-02 the arrow never moves: the primary is never lost.

### Monitoring

Use cases that sample the primary while they run (UC-02) add a **Monitoring** card.

**Progress bars** (e.g. *DR catch-up*):
- **The bar:** % done. It is **amber** while running, **green** when done and **red** if it failed.
- **On the right:** the **ETA**, which counts down between refreshes, then *MB left* and the
  **net rate**. The net rate is how fast the backlog shrinks, including the new log that keeps
  arriving.
- **"ETA unknown – not converging":** the backlog isn't shrinking. The replica can't keep up with
  the load.
- **"reseed instead ≈ m:ss":** how long copying the databases again would take (UC-02). When it
  beats the catch-up ETA by a wide margin, a warning recommends a reseed.

**Charts.** Each one shows one reading over time:
- The latest value is in the top right, with the lowest and highest values on the left axis and
  the start and end times below.
- **Dashed vertical lines** mark the start of the key phases (region failure, in-place recovery,
  catch-up, verify), so you can see what each change coincides with.
- **Dashed horizontal lines** are thresholds, e.g. the *warning* and *writer stops* levels of the
  log volume's free space.
- The executive view shows the main charts. The technical view adds the send and redo queues, the
  log used % and the forwarders' backlog.

The terminal shows the same data as **sparklines** (▁▂▃▅▇): one line per chart with the latest,
lowest and highest value, and a text progress bar with the ETA.

**Warnings.** Events such as *low disk*, *not converging* or *log on the OS disk* appear in amber
(⚠) in the event log, in both views.

### UC-01 key numbers

A tile is **green** when it meets its target, **red** when it misses it, **white** when it has
no target, and **grey (—)** until it's measured. Targets are set in `dashboard.json`
(`"target"`); UC-01 sets RPO = 0 and leaves the RTO target empty, so you can set your own.

| Number | View | Meaning |
|---|---|---|
| **Outage clock** | both | Starts when the failure is injected (the moment `az vm stop` is requested for the region) and stops at the moment SQL Server commits the first write on the DR node. **Red and ticking** while the outage lasts, **green** once stopped. In a replay it shows the recorded times, even while idle periods are fast-forwarded. |
| **RTO** | both | The final recovery time: failure injected → first write committed in the DR region, measured with SQL Server's own commit timestamp. It includes the drill's detection window (`-DetectSeconds`, 30 s by default) and every `az vm run-command` round trip (~20–40 s each). In the technical view, the detail also shows the time the tool itself observed. |
| **Lost transactions (RPO)** | both | Transactions committed on the old primary that never reached the DR node. Measured by *reinstate* once the old region is back: the old primary's last ledger row minus the last row the DR node had after recovery. Target 0; with asynchronous commit a few can be lost by design. |
| **RPO window** | both | The same loss in time: the seconds between those two last rows. `0 s` means nothing was lost. |
| Last ledger row on DR | technical | The last ledger row that had reached the DR node according to its snapshot *before* the forced failover. This can be slightly lower than the real value, because a readable secondary lags a little: reinstate uses the value read after recovery. |
| Rows at workload start | technical | Ledger rows committed 8 s after the writer started (~5 rows/s). It proves the workload is running. |
| Forced failover took | technical | Duration of `FORCE_FAILOVER_ALLOW_DATA_LOSS` + removing the lost replica on the DR node. |
| Failback role swap took | technical | Planned failback, from switching to synchronous commit until the original primary is PRIMARY again with the original modes restored. |

### UC-01 success criteria

These are UC-01's success criteria, from its README. Each one is evaluated on a metric the script
records:

| Icon | Meaning |
|---|---|
| ✓ green | Met |
| ✕ red | Not met |
| (empty) grey | Not evaluated yet (its phase hasn't run) |
| – (not applicable) | Doesn't apply to this run |

| Criterion | Passes when | Evaluated in |
|---|---|---|
| node-2 primary in West US 2, databases online and writable | *verify* reports PASS: the DR node is PRIMARY, every AG database is ONLINE, the write test commits, and the DR node is the global primary (at its own IP) of every distributed AG. | Verify |
| Surviving forwarders keep synchronizing during the outage | Every forwarder outside the failed region was repointed to the DR node, resumed, and is SYNCHRONIZING within `-ForwarderResyncMinutes`. Not applicable when every forwarder is in the failed region. | Surviving forwarders |
| RTO recorded | The RTO was measured (failure injection → first write in the DR region). | First write |
| RPO recorded (lost transactions measured) | Reinstate compared the old primary's ledger with the DR node's. Whether the loss is acceptable is shown by the RPO tile against its target. | Measure data loss |
| Old primary fenced before power-on (no split-brain) | The fence rules were in place while the old primary was still powered off, so it could never be reached as a second primary. | Region back |
| Every forwarder synchronizing after reinstate | After reinstate, every forwarder, including those that went down with the region, is SYNCHRONIZING from the new global primary. | Re-attach forwarders |
| Applications redirected (DNS) | The Private DNS record was pointed at the new primary. Not applicable without `-PrivateDnsZone` (clients are then repointed outside the drill). | Redirect clients |

### UC-01 progress phases

There is one row per stage, which runs as a separate action of the use case. Each phase shows
its status icon (✓ done, ▸ running, ✕ failed, ↷ skipped, empty = not started) and how long it
took. Hover over a phase for its explanation and result. The stage label reads *not started*,
*in progress*, *done*, *partial* or *failed*.

**Failover drill** (`-Action drill`; the single actions `precheck`, `start-workload`,
`simulate-failure`, `failover` and `verify` run the same phases)

| Phase | What happens |
|---|---|
| Pre-check | Every VM running (deallocated ones are started after confirmation), AG1 and every forwarder AG healthy, every distributed AG connected and synchronizing. A new run starts here. |
| Start workload | A writer on the primary commits a ledger row every ~0.2 s, so data loss can be measured exactly later. |
| Warm-up | Transactions flow for `-WarmupSeconds` (60 s) before the failure. |
| Region failure | Hard power-off (no guest shutdown) of every VM in the primary's region: AG1's primary and any forwarder there. **The outage clock starts.** |
| Detection | The detection/decision window (`-DetectSeconds`), then the DR node must report its connection to the primary as DISCONNECTED. Otherwise the failover is refused, to avoid a split-brain. |
| Forced failover | `FORCE_FAILOVER_ALLOW_DATA_LOSS` on the DR node, then the lost primary is removed from AG1. |
| First write | Rows are written on the new primary until the databases accept them. **The outage clock stops** at the first commit, and the RTO is recorded. |
| Redirect clients | The Private DNS A record is repointed to the new primary (skipped without `-PrivateDnsZone`). |
| Repoint DAGs | Every distributed AG's AG1 endpoint (LISTENER_URL) is pointed at the new primary, which makes it the global primary. |
| Surviving forwarders | Forwarders outside the failed region are repointed and resumed, and must resynchronize from the new global primary (skipped when there are none). |
| Verify | Final check of the new primary, write test, and distributed AG state. |

**Reinstate** (`-Action reinstate`, once the failed region is back)

| Phase | What happens |
|---|---|
| Fence old primary | NSG deny rules on the old primary (1433 in, 5022 in and out) **before** it is powered on. |
| Region back | Every VM in the failed region is started. The old primary boots as a STALE PRIMARY, fenced. |
| Measure data loss | The old primary's last ledger row is compared with the DR node's: the RPO tiles. |
| Drop stale copy | After confirmation, the stale databases are preserved as COPY_ONLY backups, then the stale distributed AGs, AG and databases are dropped on the old primary. The 5022 fence rules are lifted. |
| Rejoin + seed | The old primary rejoins as an asynchronous secondary of the new primary and is re-seeded. |
| Re-attach forwarders | Every forwarder is repointed to the new global primary and must resynchronize (re-seeded with `-ReseedForwarder` if it can't). |
| Lift fence | The last fence rule (1433) is removed: the node is a readable secondary again. |

**Failback** (`-Action failback`, optional, planned, no data loss)

| Phase | What happens |
|---|---|
| Synchronize | Both replicas switch to synchronous commit and wait until the original primary is SYNCHRONIZED. |
| Role swap | The AG is taken offline on the current primary, the original primary is promoted, the other is demoted, and the original commit modes are restored. |
| Repoint DAGs | Every distributed AG follows the primary back, on both sides, and the forwarders must resynchronize. |
| Redirect + verify | DNS back to the original primary (when `-PrivateDnsZone` is used), then a write test. |

### UC-02 key numbers

The tiles fed by samples are **live**: they show the newest reading and change while you watch.
These are primary throughput, DR behind by, transactions not yet on DR, DR lag, read freshness and
log volume free. The others are recorded once their phase has run. Tile colours work as for UC-01.

| Number | View | Meaning |
|---|---|---|
| **Time without DR** (clock) | both | Starts when the DR region fails and stops when the DR replica has caught up. **Red and ticking** while the system has no up-to-date DR copy; a second failure, of the primary, would lose what the DR replica hasn't received. |
| **Catch-up** (clock) | both | From the DR replica's reconnect to caught up. |
| **Primary throughput** | both | Transactions the workload commits per second, now. It should not drop during the outage: with asynchronous commit the primary never waits for the DR replica. |
| **DR behind by** | both | Log the DR replica doesn't have yet. While it is down: everything the primary logged since the failure. Once it is back: its send + redo queue. |
| **Transactions not yet on DR** | both | The same backlog in transactions: counted exactly while the DR replica is down, estimated from the queue (and the baseline's transactions per MB) once it's back. |
| **DR lag (commits)** | both | The primary's last commit time minus the DR replica's last commit time (`last_commit_time`, read on the primary). It is the span of committed transactions the DR copy doesn't have, in milliseconds. It is a fraction of a second while DR keeps up, **grows through the outage** (the replica's last commit stays where it was), and falls during the catch-up. It is the data a failover at that moment would lose. |
| **Read freshness on DR** | both | What a report on the DR replica sees: now minus the commit time of the newest row it can read (a reader queries it every 2 s). Measured from the application's side, independently of the DMVs. There is no value while the VM is off; during a partition it grows every second. |
| **Log volume free** | both | Free space on the volume holding the primary's log. Target ≥ 25 %: amber below it, and the writer stops itself below 15 %. |
| **Why the log can't be truncated** | both | `log_reuse_wait_desc` of the database. **AVAILABILITY_REPLICA** means the log is kept for a replica that hasn't received it yet: the log grows during the outage even with log backups. It is back to LOG_BACKUP or NOTHING once the replica has caught up. |
| **Throughput impact** | both | Drop of the average throughput during the outage compared with the baseline. Target ≤ 20 %. |
| **Failed transactions** | both | Transactions the writer couldn't commit over the whole run. Target 0. |
| **Commit stall after the failure** | both | Time until the primary's throughput was back to half its baseline after the failure. It is about 0 with an asynchronous DR replica, and about the session timeout (10 s) with `-DrCommitMode sync`. |
| **Primary protected** | both | Yes when the missing replicas were removed so the primary's log could be truncated (`-ProtectPrimaryAtFreePercent` or `-Action protect-primary`). They are then re-seeded instead of caught up. |
| **Catch-up or reseed?** | both | Which one was, or would have been, faster: *catch-up* when the replica caught up before the estimated reseed time; *reseed* when catching up was over 1.5× slower or not converging. |
| **Workload stopped** | both | Why the writer stopped by itself, e.g. *disk guard (14.9 % free)* when the log volume nearly filled. |
| **Backlog built up** | both | Log generated while the DR region was down: what the catch-up has to replay. |
| **Time without DR / Catch-up time** | both | The final values of the two clocks. |
| Primary log size, Log generated (MB/s), Send queue, Redo queue | technical | Live values behind the charts. The send queue is log not yet sent (on the primary); the redo queue is log received but not yet replayed (on the DR replica). |
| secondary_lag_seconds (DMV) | technical | SQL Server's own lag column, shown for comparison: whole seconds (it reads 0 while the replica is less than a second behind), and only while the replica is connected. |
| Forwarder lag (commits), Slowest commit, Re-seeded | technical | The same lag for the forwarders in the failed region; the writer's slowest commit; whether a reseed happened. |
| Baseline throughput / log rate / lag | technical | Measured before the failure; the catch-up threshold and the throughput impact are relative to them. |
| Throughput during outage, Transactions during outage | technical | Average and total while the DR region was down. |
| Peak log size, Lowest log volume free | technical | Extremes reached on the primary (lowest free target ≥ 15 %). |
| Region start → reconnect | technical | From the VM start request until the DR replica is CONNECTED again. |
| Peak backlog after reconnect, Average catch-up rate | technical | The largest queue after the reconnect, and that queue divided by the catch-up time (net of the log still arriving). |
| Rows on the primary / on DR | technical | Rows the workload committed, counted on each replica after the writer stopped. |

### UC-02 success criteria

| Criterion | Passes when | Evaluated in |
|---|---|---|
| node-1 kept committing throughout the outage | The writer's failed transactions = 0. | Running without DR, Verify |
| Throughput during the outage within 20 % of the baseline | The throughput impact is ≤ 20 %. | Running without DR |
| The primary's log volume never ran low | The lowest free space on the log volume stayed ≥ 15 % (the writer's disk guard never triggered). | Running without DR |
| West US 2 recovered in place - no failover, no reseed | The DR replica reconnected after its region restarted, as it was. | In-place recovery |
| node-2 caught up: queue and lag back to normal | Every DR database is SYNCHRONIZING, with its queue and lag back within max(threshold, 2 × baseline). | DR catch-up |
| Forwarders in West US 2 caught up | The distributed AGs of the forwarders in the failed region are SYNCHRONIZING with a normal queue. Not applicable when no forwarder is there. | Forwarders catch-up |
| Every committed transaction is on every replica | After the writer stopped and the queues drained, the primary, the DR replica and every forwarder hold the same number of rows. | Verify |
| Time without DR recorded | The time from the failure to caught up was measured. | DR catch-up |

### UC-02 progress phases

**Secondary region outage drill** (`-Action drill`; the single actions run the same phases)

| Phase | What happens |
|---|---|
| Pre-check | Every VM running, every AG and distributed AG healthy, and where the primary's log lives and how much room it has. A new run starts here. |
| Start workload | The writer sessions and the periodic log backups start on the primary (the profile is in the narration). |
| Baseline | `-WarmupSeconds` of normal operation: throughput, log rate, DR queue and lag. The catch-up threshold and the throughput impact are measured against it. |
| Region failure | Hard power-off of every VM in the DR region, or a network partition. **The "time without DR" clock starts.** node-1 stays PRIMARY. |
| Running without DR | `-OutageMinutes` of monitoring: the backlog, the lag and the primary's log grow, and the log volume's free space shrinks. Below `-ProtectPrimaryAtFreePercent`, the primary is protected here. |
| In-place recovery | The region's VMs start (or the partition rules are removed), and the DR replica reconnects (data movement is resumed if it was suspended). If the primary was protected, the DR replica and the forwarders are re-seeded instead. **The catch-up clock starts.** |
| DR catch-up | The DR replica replays the backlog: the progress bar shows % done, MB left, the net rate and the ETA. **Both clocks stop** when it is back to normal. |
| Forwarders catch-up | The same for the forwarders in the failed region (skipped when there are none). |
| Verify | The writer is stopped, the queues drain, and rows are counted on every replica. |

**Cleanup (optional)** (`-Action cleanup`)

| Phase | What happens |
|---|---|
| Stop workload | The writer sessions and the log backups stop. |
| Reclaim space | The load table is emptied, the log is backed up and shrunk. |

### Events

The newest events are at the top. The executive view lists phases, actions, clocks and the
executive key numbers. The technical view adds every node, link and metric change and the raw
use-case events (e.g. the distributed AG repoint output). Errors are red. A new event flashes
briefly when it arrives.

## Live

```
pwsh ./dashboard/dashboard.ps1 -UseCase uc-01 -Mode web -RefreshSeconds 3
pwsh ./use-cases/uc-01/uc-01.ps1 -Action drill -Dashboard -DashboardMode both ...   # opens it for the drill
```

Live mode follows the **newest run** of the stack (`-Stack`, the use case's `runs/<rg>` folder).
It defaults to the stack used most recently. A new drill shows up by itself as soon as its
pre-check starts. `-Run <run-id>` pins one run instead.

A use case's `-Dashboard` switch opens the dashboard in a new Terminal window, and the use case
keeps running in yours. If a live dashboard for the same stack is already running on the port,
it just opens the page again.

The dashboard never runs anything on the VMs, so it can't collide with the use case's own
`az vm run-command` calls (Azure allows one per VM at a time). Everything comes from the run's
`events.jsonl`. The only exception is the VMs' **power state**: in live mode it polls
`az vm list -d` every `-PowerPollSeconds` (default 30, `0` = off). That's a control-plane read,
so the page shows a VM the moment it is really up or down.

## Replay

```
pwsh ./dashboard/dashboard.ps1 -UseCase uc-01 -Stack sqlvm-257672-node-1-node-2-rg -Replay 20260925-015339 -Speed 5
pwsh ./dashboard/dashboard.ps1 -UseCase uc-01 -Replay latest -Speed 10 -Mode both
```

A replay plays a recorded run back at `-Speed` x (0.25–100, changeable on the page). Gaps
between events longer than `-MaxGapSeconds` (default 30, `0` = never) are fast-forwarded. The
page shows "⏩ skipping idle time" while that happens, and seeding or an operator's confirmation
then doesn't stall the presentation. Every clock, timestamp and value still shows the real
recorded time. The progress bar has a tick at each phase: click it to jump, or use `n`/`p`.

The recorded drill `20260925-015339` (RTO 170.4 s, RPO 0) is replayable. It was recorded before
dashboard events existed and was converted from its evidence files: timestamps of the recorded
events are exact, while a few phase boundaries that were never logged (marked `"approx": true` in
its `events.jsonl`) were inferred from the logs. The original is kept as `events.v1.jsonl`.

## Reports and comparisons

A **report** is the dashboard page at the end of a run, saved as one self-contained HTML file with
every chart, key number, criterion and event. It needs no server: open it, mail it, or put it next
to your slides. UC-01 and UC-02 write one at the end of every drill (`runs/<rg>/<run-id>/report.html`).

```
pwsh ./dashboard/dashboard.ps1 -UseCase uc-02 -Report latest                  # or a run id
pwsh ./use-cases/uc-02/uc-02.ps1 -Action report ...                            # the current run
```

A **comparison** puts two or more runs side by side. It is a static page with:
- **Key numbers:** one column per run, plus B − A when there are two.
- **Success criteria** and **phase durations** per run.
- **Every chart** with all the runs overlaid on a common time axis, **t = 0 at each run's failure**.
  This shows directly how, say, a heavy workload or a synchronous DR replica changes the backlog and
  the catch-up.

```
pwsh ./dashboard/dashboard.ps1 -UseCase uc-02 -Compare 20260926-012935,20260927-093000
pwsh ./dashboard/dashboard.ps1 -UseCase uc-02 -Compare stackA-rg/20260926-012935,stackB-rg/20260927-093000
```

It is written to `runs/<rg>/compare-<A>-vs-<B>.html`, or to `-Out`. Both are also in the wizard:
`./dashboard/dashboard.ps1` with no parameters → *Report* or *Compare two runs*.

## Options

| Parameter | Default | |
|---|---|---|
| `-UseCase` | asked (or the only one) | `uc-01`, ... - any `use-cases/uc-NN/` with a `dashboard.json` |
| `-Stack` | most recently used | `runs/<rg>` folder of the use case |
| `-Run` | `latest` | live: pin a run id instead of following the newest |
| `-Replay` | | run id or `latest`: replay instead of live |
| `-Mode` | `web` | `web`, `terminal`, `both` |
| `-RefreshSeconds` | 3 | 1–60 |
| `-Speed` / `-MaxGapSeconds` | 5 / 30 | replay speed, idle-gap fast-forward threshold |
| `-View` | `executive` | or `technical` |
| `-Port` | 8765 | web server port (localhost only) |
| `-PowerPollSeconds` | 30 | live VM power-state poll, `0` = off |
| `-NoBrowser` | | don't open the browser |
| `-Report` | | run id or `latest`: write a static HTML report instead of serving |
| `-Compare` | | two or more run ids (or `<stack>/<run id>`): write a static comparison |
| `-Out` | | output file of `-Report` / `-Compare` |

## Adding a use case to the dashboard

1. **`use-cases/uc-NN/dashboard.json`**:
   - The title, the stages and phases (with a plain-language `explain` per phase) and the clocks.
   - **Metrics:**
     - `exec: true` shows the metric in the executive view.
     - `target` with `targetOp` (`le`, the default, or `ge`) colours the tile.
     - `"sample": "<key>"` makes the tile live, showing the newest sample of that key.
     - `"format": "duration"` shows seconds as m:ss.
   - **Success criteria:** `metric` + `op` (`exists`, `eq`, `le`, `ge`).
   - **Monitoring (optional):**
     - `charts`: one `key` per chart, plus `unit`, `min`, `decimals` and `thresholds`.
     - `chartMarkers`: phase ids drawn as vertical lines on the charts.
     - `progress`: `phase`, `percentKey`, `etaKey`, `rateKey` and `remainingKey`, all keys of the
       samples.
   - `{placeholders}` are filled from the topology `params` (a `...Region` placeholder shows the
     region's display name).

   See `use-cases/uc-01/dashboard.json` and `use-cases/uc-02/dashboard.json`.
2. **The script**: build it on the shared framework, [`use-cases/common/uc-common.ps1`](../use-cases/common/uc-common.ps1).
   Its header says what to set before dot-sourcing it; after that, `Connect-UcAzure`,
   `Initialize-UcTopology` and `Invoke-UcMain` give the same prompts, topology, run folder,
   `-Dashboard` switch and session handling as every other use case. The events it writes come
   from `use-cases/common/uc-events.ps1`:
   - `Write-UcTopology` once per process (nodes, AG groups, links, params). Later calls merge,
     so roles and links survive across actions.
   - `Set-UcAction <action> started|completed|failed`
   - `Set-UcPhase <phase-id> running|done|failed|skipped`
   - `Set-UcNode` / `Set-UcLink` whenever a role, power state, fence or replication link changes
     (`Set-UcLink -Note` puts a figure on the link; `-Quiet` refreshes it without a log line)
   - `Set-UcSample @{ key = value; ... }` for each set of monitoring readings (charts, live tiles,
     progress bars)
   - `Set-UcMetric <id> <value>` for every measured value (criteria are evaluated on metrics)
   - `Set-UcClock <id> start|stop -At <utc>` for a live clock
   - `Write-UcEvent` for anything else worth showing in the log

   `uc-01.ps1` and `uc-02.ps1` are the references. `Invoke-UcMain` opens and closes the session:
   a failed or cancelled action marks its running phase as failed.
