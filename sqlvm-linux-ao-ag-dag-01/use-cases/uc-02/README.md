# UC-02 — Region failure of the secondary node

| | |
|---|---|
| **Failure scenario** | The secondary (DR) region fails: AG1's DR replica and every forwarder node in that region go down, or are cut off. |
| **Resolution** | In-place recovery. The primary keeps serving and there is **no failover**. When the region is back, every replica reconnects and catches up from the primary's log. If the primary had to be protected meanwhile, they are re-seeded instead. |
| **What this drill proves** | The primary is unaffected, the backlog that builds up during the outage is replayed, and no committed transaction is missing on any replica afterwards. It also measures how long the system ran without a DR copy, and whether catching up or re-seeding is faster. |

## Topology

It is the same as UC-01, with the other region failing:

```
            eastus (stays up)                              westus2 (FAILS)
  ┌──────────────────────────────────┐              ┌──────────────────────────────────┐
  │ AG1 agsqlvm-node-1               │   async      │                                  │
  │   node-1 PRIMARY  ★ global  ─────┼─────────────►│   node-2 SECONDARY (DR)    ✖     │
  │ AG2 agsqlvm-node-3 (forwarder)   │              │ AG3 agsqlvm-node-5 (forwarder)   │
  │   node-3 ◄── DAG from node-1     │    DAG       │   node-5 ◄── DAG from node-1  ✖  │
  │   node-4                         │  ──────────► │   node-6                     ✖   │
  └──────────────────────────────────┘              └──────────────────────────────────┘
```

A westus2 outage takes down node-2, node-5 and node-6. node-1 stays PRIMARY and applications keep
writing to it, while AG2 in eastus keeps receiving changes. Everything that is committed on node-1
while westus2 is down is **log that node-2 and AG3 don't have yet**.

## What makes the recovery harder

A quiet primary recovers in seconds. A busy one is where the risks are, and they are what this use
case measures:

1. **The backlog grows with the load.** Every transaction committed during the outage has to be
   sent to and replayed on the DR replica (and the forwarders) after it comes back.
2. **The primary's log can't be truncated.** While a replica is missing, SQL Server keeps every log
   record that replica hasn't received (`log_reuse_wait_desc = AVAILABILITY_REPLICA`), **even with
   regular log backups**. The log file grows until the replica is back or its volume is full. A
   full log stops *every* write on the primary, turning a DR outage into a production outage.
   `-ProtectPrimaryAtFreePercent` protects the primary first (see [Variants](#variants)).
3. **Catch-up has to outrun new work.** The DR replica only catches up if it replays log faster
   than the primary generates it. If it doesn't, the backlog never shrinks ("not converging"). The
   drill compares the catch-up ETA with an estimated reseed and recommends the faster one.
4. **Everything is exposed while catching up.** Until the DR replica is back in sync, a second
   failure (of the primary this time) would lose everything it hasn't received. This is the **time
   without DR**.

The workload (`-WorkloadProfile heavy` by default) creates this pressure deliberately. The writer
stops on its own before the log volume drops below `-MinFreeDiskPercent` (15 %) free, so the drill
can't fill the primary's disk.

> **Where the log lives matters.** In the stacks deployed so far, SQL Server's files are in
> `/var/opt/mssql/data` on the OS disk's **10 GB `/var` volume**. The 256 GB data disk isn't
> even mounted: cloud-init looked for `/dev/sdb`, and on NVMe VM sizes the data disk is
> `/dev/nvme0n2`. Your first drill filled `/var` in under 4 minutes of outage (see
> [Your first drill](#your-first-drill-20260926-012935)). Fix existing stacks with
> `pwsh ../../sqlvm-linux-ag.ps1 -Action relocate-data` (Operate menu). New deployments put the files
> on the data disk.

## Variants

| Parameter | Values | What changes |
|---|---|---|
| `-FailureMode` | `poweroff` (default) | Every VM in the DR region is powered off hard. Recovery starts them. |
| | `partition` | The region is **cut off by the network**: NSG rules deny port 5022 with the other region (and the region's AG endpoints are restarted so the current connections drop). The VMs keep running, so reports on the DR replica keep working, on older and older data. Recovery removes the rules. |
| `-DrCommitMode` | `async` (default) | The DR replica is asynchronous, as in the lab: the primary never waits for it. |
| | `sync` | The DR replica is made **synchronous** for the drill, and restored by `verify`/`cleanup`. Commits wait for it, so when it is lost the primary's commits **stall until the session times out** (10 s by default). The drill measures that stall. |
| `-ProtectPrimaryAtFreePercent` | `0` (off, default), or e.g. `20` | When the log volume drops below this % free while the DR replica is down, the primary is **protected**: the DR replica is removed from AG1 and the distributed AGs of the missing forwarders are dropped, so the log can be truncated. `recover` then **re-seeds** them instead of catching up. It must be above `-MinFreeDiskPercent`. `-Action protect-primary` does the same on demand. |
| `-NoReadWorkload` | | Turns off the reader on the DR replica (see [Monitoring](#monitoring)). |

## What's in this folder

```
uc-02/
├── README.md       this runbook
├── uc-02.ps1       drill + runbook automation
├── dashboard.json  phases, key numbers, charts, catch-up progress and success criteria for the dashboard
├── sql/            the T-SQL steps specific to UC-02 (runnable by hand); shared ones are in ../common/sql/
└── runs/           evidence written by uc-02.ps1 - one folder per drill run, with report.html (git-ignored)
```

`uc-02.ps1` uses the same framework as every use case ([`../common/uc-common.ps1`](../common/uc-common.ps1)):
the same prompts and parameters (`-Identifier`, the node suffixes, `-Forwarders`), SQL through
`az vm run-command`, evidence and dashboard events in `runs/<rg>/<run-id>/`, and the same
`-Dashboard` switch.

## Quick start

```bash
cd iac-azure-sql/sqlvm-linux-ao-ag-dag-01/use-cases/uc-02
N="-Identifier ag01 -PrimaryNodeSuffix node-1 -SecondaryNodeSuffix node-2 -Forwarders ag02:node-3:node-4,ag03:node-5:node-6"

# 1. Where are we? (read-only: AG health + the primary's key metrics, where its log is)
pwsh ./uc-02.ps1 -Action status $N

# 2. Full drill, with the dashboard: precheck -> heavy workload on node-1 (+ reader on node-2)
#    -> 2 min baseline -> power-off of node-2, node-5, node-6 -> 5 min outage -> in-place recovery
#    -> catch-up (backlog, rate, ETA, reseed estimate) -> verify every row on every replica -> report
pwsh ./uc-02.ps1 -Action drill -Dashboard $N

# 3. The variants
pwsh ./uc-02.ps1 -Action drill -FailureMode partition -DrCommitMode sync $N
pwsh ./uc-02.ps1 -Action drill -OutageMinutes 15 -ProtectPrimaryAtFreePercent 20 $N

# 4. Reclaim the space the workload used (load table emptied, log backed up and shrunk)
pwsh ./uc-02.ps1 -Action cleanup $N

# 5. Compare two runs (e.g. light vs heavy, async vs sync) - a static page next to the runs
pwsh ../../dashboard/dashboard.ps1 -UseCase uc-02 -Compare <run-id-A>,<run-id-B>
```

In zsh, write `${=N}` instead of `$N`. Run `pwsh ./uc-02.ps1` with no parameters to get prompts
for everything, or pick it from the menu (`pwsh ../../sqlvm-linux-ag.ps1`, **5) Use cases**).
Make it harder or easier with `-OutageMinutes`, `-WorkloadProfile light`, or
`-WriterSessions 8 -RowBytes 4000`.

## Actions

| Action | What it does |
|---|---|
| `status` | Power state and AG / distributed AG health of every node, plus the primary's key metrics: log size and why it can't be truncated, the log volume and its free space, the AG data size, and per remote replica the queues, the lag from commit times and `secondary_lag_seconds`. |
| `precheck` | Starts deallocated VMs (after confirmation), checks every AG and distributed AG is healthy, that no partition rule is left over, and that the log volume has room. It opens a new drill run and starts the **sampler**. |
| `start-workload` | Makes the DR replica synchronous if `-DrCommitMode sync`, starts `-WriterSessions` writer sessions and a `BACKUP LOG` every `-LogBackupSeconds` on the primary, and the **reader** on the DR replica. |
| `monitor` | Collects samples for `-MonitorMinutes`: the **baseline** before the failure, the **outage** after it. |
| `simulate-failure` | Power-off (or network partition) of every node in the DR region. The sample just before is where the backlog is measured from. |
| `protect-primary` | Removes the missing DR replica from AG1 and drops the missing forwarders' distributed AGs, then backs up the log so it can be truncated. `recover` re-seeds them. |
| `recover` | Brings the region back (starts its VMs, or removes the partition rules). Then it waits for the DR replica to reconnect (resuming data movement if suspended), or **re-seeds** it and the forwarders after `protect-primary`. It then tracks the **catch-up**: backlog in MB, net drain rate, % done, ETA and a reseed estimate, for the DR replica and then the forwarders in the region. |
| `verify` | Stops the reader and the writer, waits until nothing is queued for any replica, counts the run's rows on the primary, the DR replica and every forwarder, and restores asynchronous commit if it was changed. |
| `stop-workload` | Stops the writer sessions, the log backups, the sampler and the reader. |
| `cleanup` | Stops everything, empties `dbo.UC02_Load` (`TRUNCATE`), takes a log backup and shrinks the log to `-CleanupLogMB`. It also deletes the drill's periodic log backups and sampler files. |
| `report` | Writes a static HTML report of the current run: `runs/<rg>/<run-id>/report.html`. |
| `drill` | precheck → start-workload → baseline (`-WarmupSeconds`) → simulate-failure → outage (`-OutageMinutes`) → recover → verify → report. Asks for one confirmation. |

## Workload

Each writer session is [`02-writer.sql`](sql/02-writer.sql), running in its own `sqlcmd` on the
primary. It is a loop of transactions, each inserting `RowsPerTx` rows of `RowBytes` bytes into
`dbo.UC02_Load` and then pausing `ThinkMs`. Every 20 transactions it records its progress in
`dbo.UC02_Writer`: committed and failed transactions, and its **slowest commit** since the last
update. It then checks the stop flag and the disk guard.

| Profile | Sessions | Rows / tx | Bytes / row | Pause | Your drill measured |
|---|---|---|---|---|---|
| `light` | 1 | 1 | 200 | 200 ms | — |
| `heavy` (default) | 4 | 20 | 2,000 | 20 ms | ~88 tx/s, ~5.3 MB/s of log |

`-WriterSessions`, `-RowsPerTx`, `-RowBytes` and `-ThinkMs` override the profile. Log backups go to
`/sqldata/uc02-backup` when the data disk is mounted, otherwise to `/var/opt/mssql/backup/uc02`.
Backups older than 30 minutes are deleted, a lab shortcut that breaks point-in-time restore.

## Monitoring

**Sampler (on the primary).** From the pre-check on, `sampler.sh` runs
[`40-primary-sample.sql`](sql/40-primary-sample.sql) every `-SampleSeconds` (5 s) and appends one
line per sample to `/var/tmp/uc02/samples-<run>.log`. Every `-FetchSeconds` (20 s), one Run Command
collects the new lines, compressed to stay under Run Command's ~4 KB output limit, and each sample
is recorded at **its own time**. The charts therefore have a point every 5 s, and nothing is lost
while the script is busy elsewhere (e.g. waiting for VMs to start): the lines are collected
afterwards.

**Reader (on the DR replica).** `reader.sh` runs [`43-read-freshness.sql`](sql/43-read-freshness.sql)
every 2 s, the way a reporting query would. It reads the newest workload row visible on the
readable secondary. **Read freshness** = now − that row's commit time on the primary. It is measured
from the application's side, independently of SQL Server's own DMVs. During a power-off there are no
reads (the VM is off). During a partition the reads keep working, and freshness grows every second.

**What each sample reads:**

| Reading | Source |
|---|---|
| Throughput (tx/s) | Committed transactions of the writer (`dbo.UC02_Writer`), difference between samples |
| Log generated (MB/s) | `Log Bytes Flushed/sec` of the database (a cumulative counter), difference between samples |
| Log size, log used %, why the log can't be truncated | `DBCC SQLPERF(LOGSPACE)`, `sys.databases.log_reuse_wait_desc` |
| Log volume, free % | `sys.dm_os_volume_stats` of the log file (`volume_mount_point` is NULL on Linux: the log's folder is shown) |
| AG data size | Data files of every AG database: what a reseed would copy |
| Slowest commit | The writer sessions' slowest commit since their previous update |
| Per remote replica | `sys.dm_hadr_database_replica_states` on the primary: send queue, redo queue, send and redo rates, `last_commit_time`, `secondary_lag_seconds` |

### Replication lag: how it is calculated

**DR lag (commits)** = the primary's `last_commit_time` − the DR replica's `last_commit_time`, both
read on the primary from `sys.dm_hadr_database_replica_states`. (On the primary, a replica's row
shows the time of the last commit that replica has.) It is the span of committed transactions the
DR copy doesn't have, with millisecond precision. This is the method in Microsoft's guidance for
estimating potential data loss.

- **While the DR replica is connected and keeping up**, it is a fraction of a second: the DR
  replica is at most a few MB behind at several MB/s.
- **While it is down or partitioned**, its row keeps its last commit time, so the lag **grows with
  every commit** on the primary. It is the data a failover at that moment would lose.
- **During the catch-up** it falls back to normal.
- If the writer stops, the primary's last commit stops too, so the lag stays at the gap that is
  still missing.

**`secondary_lag_seconds`** (technical view) is SQL Server's own column. It is in **whole seconds**
and only reported while the replica is connected, so it reads 0 whenever the replica is less than a
second behind, and nothing at all while it is down.

**How far behind** (MB):
- **While the DR replica is down:** the log the primary generated since the failure, plus what was
  already queued.
- **Once it's back:** its send + redo queue.
- **In transactions:** counted exactly while it's down, then estimated from the queue and the
  baseline's transactions per MB.

**Catch-up:**
- **Progress:** % = 1 − queue / largest queue since the replica came back.
- **Net drain rate:** how fast the queue shrinks over the last 6 samples, including the new log
  still arriving.
- **ETA:** queue / net drain rate. If the queue isn't shrinking, it shows *not converging* (a
  warning after 4 samples).
- **Caught up:** every DR database is SYNCHRONIZING, the queue is ≤ max(`-CaughtUpQueueMB`, 2 ×
  the baseline queue), and the lag is ≤ max(`-CaughtUpLagSeconds`, 2 × the baseline lag).

**Reseed estimate:** the AG data size / the seeding throughput. That is `-SeedingMBps`, or the best
send rate observed so far. It is shown next to the catch-up ETA. When catching up would take more
than 1.5× the reseed, or isn't converging, a warning recommends a reseed. The **Catch-up or reseed?**
tile records which one was faster.

**Commit stall:** after the failure, the time until throughput is back to at least half the
baseline. With `-DrCommitMode sync` it is about the session timeout. The **Slowest commit** chart
shows the same stall per transaction.

**Clocks:**
- **Time without DR:** from the failure until the DR replica has caught up.
- **Catch-up:** from the reconnect until caught up.

## Your first drill (`20260926-012935`)

The drill passed its row check: no failed transactions, and all 669,600 rows on node-1, node-2,
node-3 and node-5. Three results need explaining, and the fixes are in this version:

- **The workload stopped itself 3 min 49 s into the outage** ("disk guard 14.9 % free"). The log
  grew from 456 MB to 1.4 GB (it can't be truncated while node-2 is down) on the **10 GB `/var`
  volume**, which was already 86 % full. That's also why the throughput dropped 52 % on average, and
  why that criterion failed. It was a real **full-log** risk, caught by the guard; `relocate-data`
  and `-ProtectPrimaryAtFreePercent` address it.
- **The log volume's free space was never shown** (and the pre-check didn't warn you).
  `volume_mount_point` is NULL on Linux, which blanked the whole disk reading. The sample now uses
  the log file's folder.
- **Replication lag read 0 the whole time**, and the catch-up looked instant (peak backlog 0.1 MB):
  - The old version used `secondary_lag_seconds`, which rounds down to whole seconds while the
    replica keeps up. In the baseline, node-2 was only 1–3 MB behind at 5.3 MB/s, so it was
    really about 0.3 s behind.
  - The column isn't reported at all while the replica is down, so the outage never showed up in it.
  - The catch-up itself was fast: the writer had already stopped, so node-2 only had to replay the
    fixed 1.2 GB backlog, and it did so between two samples taken ~50 s apart.
  - Lag now comes from `last_commit_time`, which grows through the outage, and samples are every
    5 s.

## Evidence (`runs/<rg>/<run-id>/`)

| File | Content |
|---|---|
| `events.jsonl` | Timeline + dashboard events: phases, node/link changes, every sample and read, metrics |
| `report.html` | Static report of the run: the dashboard at the end of the run, with every chart, key number, criterion and event |
| `precheck.json` | Nodes, regions, the variant (failure mode, commit mode, protect threshold), the workload, the primary's log volume and AG data size, AG status of every node |
| `workload.json` | Profile, sessions, log backup interval and folder, commit mode, reader |
| `baseline.json` | Normal throughput, log rate, DR queue and lag (max and average), slowest commit, transactions per MB of log |
| `failure.json` | Mode, VMs, when, and the primary's counters just before the failure |
| `outage.json` | Throughput, backlog, lag at the end, write errors, commit stall, lowest free space, peak log size |
| `protect.json` | When and why the primary was protected (only with `protect-primary`) |
| `recover.json` | When the DR replica and the forwarders caught up, the peak backlog, and the time without DR |
| `verify.json` | Rows on every replica, the writer's totals, health problems (none = PASS) |
| `cleanup.json` | Log size before and after the cleanup |
| `sampler-offset.txt`, `reader-offset.txt` | How many sampler and reader lines were already collected |

### Success criteria

- [ ] node-1 kept committing throughout the outage: no failed transactions.
- [ ] Throughput during the outage within 20 % of the baseline (asynchronous commit doesn't wait
      for DR; with `sync`, look at the commit stall instead).
- [ ] The primary's log volume never ran low (the writer's disk guard never triggered).
- [ ] westus2 recovered in place: no failover, no reseed. With `-ProtectPrimaryAtFreePercent` this
      fails by design once the primary had to be protected.
- [ ] node-2 caught up: queue and lag back to normal.
- [ ] The forwarders in westus2 caught up.
- [ ] Every committed transaction is on every replica (row counts match after the writer stops).
- [ ] Time without DR recorded.

The dashboard shows all of them live. See
[../../dashboard/README.md](../../dashboard/README.md#uc-02-key-numbers).

## Manual runbook (without the script)

```bash
# node-1 (primary) - key metrics, one line (S1=...; see the header of the file for the fields)
sqlcmd -S localhost -U SA -C -W -h -1 -v DbName="AGDemoDB" RunId="manual" -i sql/40-primary-sample.sql

# node-2 (DR) - what a report sees
sqlcmd -S localhost -U SA -C -W -h -1 -v DbName="AGDemoDB" -i sql/43-read-freshness.sql

# westus2 is back: start node-2, node-5, node-6 (portal or az vm start), or remove the partition rules.
# The replicas reconnect on their own. Only if a database stays suspended (node-2; node-5, node-6 for AG3):
sqlcmd -S localhost -U SA -C -v AgName="agsqlvm-node-1" Demote="0" -i ../common/sql/33-demote-and-resume.sql

# Protect the primary (node-1), then later re-seed node-2:
sqlcmd -S localhost -U SA -C -v AgName="agsqlvm-node-1" Replica="sqlvm-ag01-node-2" Dags="dagsqlvm-node-1-node-5" DbName="AGDemoDB" BackupFile="/var/opt/mssql/backup/uc02/protect.trn" -i sql/60-protect-primary.sql
sqlcmd ... -v AgName="agsqlvm-node-1" Dbs="AGDemoDB,WideWorldImporters" -i sql/61-drop-stale-secondary.sql       # on node-2
sqlcmd ... -v AgName="agsqlvm-node-1" ReplicaName="sqlvm-ag01-node-2" EndpointUrl="tcp://<node-2 IP>:5022" -i ../common/sql/22-add-replica.sql   # on node-1
sqlcmd ... -v AgName="agsqlvm-node-1" -i ../common/sql/23-join-secondary.sql                                    # on node-2
```

## Gaps and recommendations

- **Clock skew.** Read freshness compares the DR VM's clock with the commit time on the primary.
  Azure VMs are NTP-synchronized (typically within milliseconds), which is fine for seconds-scale
  staleness.
- **Transactions behind (estimate).** Once the replica is back, the number of transactions still
  missing is estimated from the queue in MB and the baseline's transactions per MB.
- **Reseed estimate.** It assumes seeding runs at the best send rate observed. Pass `-SeedingMBps`
  if you have measured seeding throughput.
- **Partition.** It cuts only AG traffic (port 5022) between the regions. SQL clients and Run
  Command still reach the region, which is what lets the reader and the monitoring keep working.
- **Cleanup is lab-only.** It truncates the load table and deletes the periodic log backups.

## Cost and cleanup

- **Compute:** the drill only uses the existing VMs. Powered-off VMs stay allocated and keep
  billing for compute.
- **Disk:** the heavy workload writes rows and log to the primary, which then replicate everywhere.
  Run `-Action cleanup` afterwards to empty the table and shrink the log.

## References

- [Monitor performance for availability groups](https://learn.microsoft.com/sql/database-engine/availability-groups/windows/monitor-performance-for-always-on-availability-groups): send and redo queues, and estimating data loss from `last_commit_time`.
- [sys.dm_hadr_database_replica_states](https://learn.microsoft.com/sql/relational-databases/system-dynamic-management-views/sys-dm-hadr-database-replica-states-transact-sql): `log_send_queue_size`, `redo_queue_size`, `last_commit_time`, `secondary_lag_seconds`.
- [The transaction log: factors that can delay log truncation](https://learn.microsoft.com/sql/relational-databases/logs/the-transaction-log-sql-server#FactorsThatDelayTruncation): `AVAILABILITY_REPLICA`.
- [Availability modes](https://learn.microsoft.com/sql/database-engine/availability-groups/windows/availability-modes-always-on-availability-groups): synchronous commit and the session timeout.
