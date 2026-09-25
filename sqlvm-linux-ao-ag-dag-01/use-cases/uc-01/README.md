# UC-01 — Region failure of the primary node

| | |
|---|---|
| **Failure scenario** | The Azure region that hosts the **primary** replica fails. Every node in that region is unavailable. |
| **Expected resolution** | **Fail all transactions over to the alternate region.** The DR replica becomes primary (and the Distributed AG's global primary), accepts reads and writes, and applications are redirected to it. |
| **Topology** | AG1 `agsqlvm-node-1`: `sqlvm-257672-node-1` (eastus, primary) → `sqlvm-257672-node-2` (westus2, async DR). AG1 is the global primary of one Distributed AG per forwarder AG: `dagsqlvm-node-1-node-3` → AG2 `agsqlvm-node-3` (node-3/node-4, eastus) and `dagsqlvm-node-1-node-5` → AG3 `agsqlvm-node-5` (node-5/node-6, westus2). Use AG3's real suffixes if they differ. |
| **Failure domain (eastus)** | node-1 (AG1 primary), node-3 and node-4 (AG2). **node-2** (AG1 DR) and **AG3** (node-5/node-6) survive in westus2. |

## Topology

```
BEFORE (all healthy)
  eastus                                                        westus2
  ┌──────────────────────────┐  async (AG1)                     ┌──────────────────────────┐
  │ node-1  AG1 PRIMARY      │─────────────────────────────────►│ node-2  AG1 SECONDARY    │
  │ = global primary of both │                                  └──────────────────────────┘
  │   Distributed AGs        │  async (dagsqlvm-node-1-node-5)  ┌──────────────────────────┐
  │                          │─────────────────────────────────►│ node-5  AG3 forwarder    │─► node-6
  └────────────┬─────────────┘                                  └──────────────────────────┘
               │ async (dagsqlvm-node-1-node-3)
  ┌────────────▼─────────────┐
  │ node-3  AG2 forwarder    │─► node-4
  └──────────────────────────┘

AFTER failover (eastus down)                    AFTER reinstate (eastus back)
  node-1, node-3, node-4: DOWN                    node-2 = AG1 PRIMARY = global primary (westus2)
  node-2  AG1 PRIMARY (westus2)                     ├─► node-1  AG1 SECONDARY (async, re-seeded)
          = global primary of both DAGs             ├─► node-5  AG3 forwarder ─► node-6
    └─► node-5  AG3 forwarder (repointed at         └─► node-3  AG2 forwarder (repointed) ─► node-4
        failover, keeps replicating) ─► node-6    optional: failback (planned, no data loss) to node-1
```

- **`CLUSTER_TYPE = NONE`**, so failover is manual and there is **no listener**. In every
  Distributed AG, AG1's `LISTENER_URL` is the endpoint of AG1's current primary, so it has to
  follow every role change of AG1, on the global primary **and** on each forwarder.
- **Asynchronous replication.** Transactions that hadn't reached westus2 are lost when eastus
  fails. **RPO > 0 is expected**, and the drill measures it exactly.
- **AG3 is the second surviving copy.** While eastus is down, node-2 serves reads and writes and
  AG3 keeps a live read-only copy in westus2. AG2 goes down with eastus and is re-attached when
  the region recovers.

## What's in this folder

```
uc-01/
├── README.md       this runbook
├── uc-01.ps1       drill + runbook automation (status, precheck, drill, failover, reinstate, failback, ...)
├── sql/            every T-SQL step as a standalone sqlcmd script (runnable by hand)
└── runs/           evidence written by uc-01.ps1 - one folder per drill run (git-ignored)
```

`uc-01.ps1` runs all SQL through **`az vm run-command`** (the Azure control plane), in parallel
across nodes. It doesn't use SSH or port 1433, which the subscription's policy blocks from the
internet.

## Prerequisites

- PowerShell 7+, Azure CLI signed in (`az login`).
- Every stack deployed with `../../sqlvm-linux-ag.ps1` (credentials in `../../state/`), and one
  Distributed AG per forwarder created with `../../sqlvm-linux-ag.ps1 -Action deploy-dag`, with AG1's
  stack as the global primary each time.
- Every node running, all AGs healthy, and every forwarder SYNCHRONIZING. `precheck` verifies
  this (and offers to start deallocated VMs).
- **Declare every forwarder of AG1** with `-Forwarders`. `precheck` refuses to run if node-1 has a
  Distributed AG that wasn't declared: failover must repoint all of them, or that forwarder
  silently stops receiving changes.

## Quick start

```bash
cd iac-azure-sql/sqlvm-linux-ao-ag-dag-01/use-cases/uc-01
N="-Identifier 257672 -PrimaryNodeSuffix node-1 -SecondaryNodeSuffix node-2 -Forwarders node-3:node-4,node-5:node-6"

# 1. Where are we? (read-only, every node)
pwsh ./uc-01.ps1 -Action status $N

# 2. Full drill: precheck -> writer on node-1 -> 60 s warm-up -> hard power-off of node-1, node-3, node-4
#    -> 30 s detection window -> forced failover to node-2 (+ repoint of every Distributed AG,
#    AG3 re-attached right away) -> verification
pwsh ./uc-01.ps1 -Action drill $N

# 3. "eastus is back": fence node-1, start the region, measure the exact data loss, rejoin node-1,
#    re-attach AG2 (and re-check AG3) to node-2
pwsh ./uc-01.ps1 -Action reinstate $N

# 4. Optional: planned failback to eastus (no data loss), every Distributed AG repointed back to node-1
pwsh ./uc-01.ps1 -Action failback $N
```

In zsh, write `${=N}` instead of `$N`. Run `pwsh ./uc-01.ps1` with no parameters to get prompts
for everything. `-Forwarders` takes one `<primary suffix>:<secondary suffix>` pair per forwarder
stack. Use `-Forwarders none` for an AG without Distributed AGs.
`-ForwarderPrimarySuffix`/`-ForwarderSecondarySuffix` still work as a shorthand for one pair.

## Actions

| Action | Where it runs | What it does |
|---|---|---|
| `status` | all nodes | Power state, local role, replicas, databases, every Distributed AG's members and forwarder sync, and fence rules. |
| `precheck` | all nodes | Starts deallocated VMs (asks first). Requires node-1 PRIMARY, node-2 SECONDARY and CONNECTED, all AG databases ONLINE and not suspended, every declared Distributed AG present with its forwarder CONNECTED and SYNCHRONIZING, and no undeclared Distributed AG on node-1. Opens a new **drill run** and creates the ledger table `AGDemoDB.dbo.UC01_Tx`, which replicates to node-2 and to every forwarder. |
| `start-workload` | node-1 | Detached writer: one committed ledger row (`run_id`, `seq`, `phase='pre-failure'`) about every 0.2 s for `-WorkloadSeconds` (default 900). |
| `simulate-failure` | eastus | `az vm stop --skip-shutdown` on **every node in the primary's region** (node-1, node-3, node-4; not AG3), all at once: a hard power-off, like losing the region. |
| `failover` | **westus2 only** | See below. Never touches eastus resources. |
| `verify` | node-2 | PRIMARY role, AG databases ONLINE, a write test, node-2 as the global primary of every Distributed AG, and the surviving forwarders' sync state. |
| `drill` | — | `precheck` → `start-workload` → warm-up → `simulate-failure` → detection window → `failover` → `verify`, with one confirmation. |
| `reinstate` | all nodes | See below. |
| `failback` | node-1, node-2, forwarder primaries | Planned role swap back to node-1 with no data loss, then repoints every Distributed AG. |

### Failover (the resolution)

Runs in westus2 only (node-2, plus the surviving forwarders' nodes):

1. **Detect.** Uses [`10-dr-snapshot.sql`](sql/10-dr-snapshot.sql). node-2's **own** replica state
   must report `DISCONNECTED` from the primary; the check retries for about 60 s. A secondary has
   no state row for the other replicas, so a healthy primary would otherwise look `UNKNOWN`. If the
   state is `CONNECTED` or `UNKNOWN`, the script **refuses** to fail over (`-Force` overrides),
   because forcing a failover while the primary is alive creates two primaries. The snapshot also
   records the last replicated commit and ledger row, which feed the RPO.
2. **Promote and remove the lost replica.** Uses [`11-force-failover.sql`](sql/11-force-failover.sql):
   `FORCE_FAILOVER_ALLOW_DATA_LOSS`, then `REMOVE REPLICA ON N'sqlvm-257672-node-1'`, then resumes
   any suspended database. This is Microsoft's procedure for `CLUSTER_TYPE = NONE`: after a forced
   failover the old primary **comes back as PRIMARY**, and removing it prevents a split-brain.
3. **Prove transactions are accepted.** Uses [`12-write-test.sql`](sql/12-write-test.sql) to insert
   `-WriteTestRows` rows (`phase='post-failover'`) on node-2. This runs before the repoint below,
   which applications don't need in order to write. It also reads what node-2 really has after
   recovery, which is the RPO baseline.
4. **Repoint every Distributed AG.** Uses [`13-dag-repoint.sql`](sql/13-dag-repoint.sql) on
   node-2, once per Distributed AG in a single call:
   `MODIFY AVAILABILITY GROUP ON N'agsqlvm-node-1' WITH (LISTENER_URL = N'tcp://10.20.1.4:5022')`.
   node-2 is now the global primary of all of them. The Distributed AG definitions already exist
   on node-2, because they're replicated to every replica of AG1.
5. **Redirect clients.** Sets the optional Private DNS record (see
   [Redirecting transactions](#redirecting-transactions)).
6. **Re-attach the surviving forwarders (AG3).** This runs after the RTO is measured. The step
   repoints AG1's URL on AG3's side too, resumes data movement on node-5/node-6, and waits up to
   `-ForwarderResyncMinutes` (default 15) for AG3 to be SYNCHRONIZING from node-2.
   - AG3 may have received transactions from node-1 that node-2 never got; replication was async to
     both. In that case it can't resume. It keeps serving its read-only data, and it's reported for
     a re-seed with `reinstate -ReseedForwarder`. The re-seed isn't done during the outage, because
     rebuilding a Distributed AG touches node-1's stack in eastus.
7. **Evidence.** Writes `failover.json` with each Distributed AG repointed, each forwarder's
   state, and the **RTO**. RTO runs from the moment the failure is injected (the power-off request;
   the VMs stop within about 2 s) to the first write committed on node-2, by SQL Server's own
   clock. `rtoSecondsToolObserved` adds the Run Command round trip that reports that write.

### Reinstate (eastus recovered)

1. **Fence node-1 before powering it on.** Three NSG rules go on `sqlvm-257672-node-1-nsg`: deny
   inbound 1433 (`uc01-fence-deny-sql`), deny inbound 5022 (`uc01-fence-deny-hadr-in`) and deny
   outbound 5022 (`uc01-fence-deny-hadr-out`). node-1 boots believing it's still AG1's primary
   **and** the global primary of every Distributed AG. AG2's node-3 boots still pointing at node-1,
   so without the 5022 fence it could receive log from the stale primary.
2. Starts node-1, node-3 and node-4.
3. [`20-old-primary-inspect.sql`](sql/20-old-primary-inspect.sql) on node-1 and node-3 measures the
   **exact RPO**: the rows node-1 committed that never reached node-2, and how far AG2 got. Saved
   to `rpo.json`.
4. [`21-old-primary-preserve-and-drop.sql`](sql/21-old-primary-preserve-and-drop.sql) on node-1:
   - takes `COPY_ONLY` backups of the stale databases (skip with `-SkipOrphanBackup`);
   - drops **every** stale Distributed AG definition (`DropDistributed=1`);
   - `AG OFFLINE`, then `DROP AVAILABILITY GROUP`, then drops the databases.
5. Lifts the 5022 fence and keeps 1433 fenced.
   [`22-add-replica.sql`](sql/22-add-replica.sql) on node-2 and
   [`23-join-secondary.sql`](sql/23-join-secondary.sql) on node-1 rejoin node-1 as an
   **ASYNCHRONOUS** secondary, and the script waits for automatic seeding.
6. **Re-attaches every forwarder.** Runs [`13-dag-repoint.sql`](sql/13-dag-repoint.sql) on node-2
   and on each forwarder's primary (AG1's URL → node-2; idempotent for AG3, which failover already
   re-attached). Resumes data movement on all forwarder nodes
   ([`33`](sql/33-demote-and-resume.sql)), then waits up to `-ForwarderResyncMinutes` for every
   forwarder to be SYNCHRONIZING ([`14-dag-status.sql`](sql/14-dag-status.sql)).
   - A forwarder that received transactions from node-1 that node-2 never got can't resume.
     With `-ReseedForwarder`, the script rebuilds that forwarder's Distributed AG
     (`sqlvm-linux-ag.ps1 -Action remove-dag` + `deploy-dag`), which re-seeds it from node-2. Without the
     switch, it reports which forwarder is affected.
7. Lifts the 1433 fence. node-1 is a readable secondary, and the primary stays in westus2.

### Failback (optional, planned, no data loss)

Follows Microsoft's "manual failover without data loss" for `CLUSTER_TYPE = NONE`:

1. [`30`](sql/30-failback-prepare.sql): both replicas become SYNCHRONOUS, and
   `REQUIRED_SYNCHRONIZED_SECONDARIES_TO_COMMIT = 1` is set.
2. Waits for node-1 to be SYNCHRONIZED.
3. [`31`](sql/31-offline.sql): AG OFFLINE on node-2.
4. [`32`](sql/32-promote.sql): promote node-1.
5. [`33`](sql/33-demote-and-resume.sql): `SET (ROLE = SECONDARY)` on node-2, and resume data movement.
6. [`34`](sql/34-restore-original-modes.sql): restores the original modes (node-1 SYNC primary,
   node-2 ASYNC, commit gating off).
7. [`13`](sql/13-dag-repoint.sql) on node-1 and every forwarder's primary: AG1's `LISTENER_URL` →
   node-1 in every Distributed AG, then waits for the forwarders to resynchronize. Repoints DNS
   and runs a write test.

Commits wait for the secondary during steps 1–5, and writes pause during the offline/promote
window. Schedule it.

## Redirecting transactions

With `CLUSTER_TYPE = NONE` there's **no AG listener**, so nothing moves client connections
automatically. "Fail all transactions over" therefore needs one of these:

| Option | How |
|---|---|
| **Private DNS record (recommended)** | Applications connect to a name such as `sqlprimary.sqlag.internal`. Pass `-PrivateDnsZone sqlag.internal -PrivateDnsRecord sqlprimary [-PrivateDnsResourceGroup <rg>]`. `failover` points the A record to node-2 and `failback` points it back. Azure Private DNS is a global service, so it keeps working during a regional outage. Keep the TTL low (10–30 s). |
| **Connection-string switch** | Change the application's server from node-1 (`10.10.1.4`) to node-2 (`10.20.1.4`), then recycle connection pools. |

Read-only consumers of AG3 (node-5/node-6, westus2) keep working throughout. Consumers of AG2
(node-3/node-4) are in the failed region and are down until `reinstate`.

## Evidence (`runs/<rg>/<run-id>/`)

| File | Content |
|---|---|
| `events.jsonl` | Timeline (UTC): precheck, workload, failure injected, failover, Distributed AG repoint, first write on DR, fence, region started, rejoin, forwarder re-attached, … |
| `precheck.json` | Nodes, regions, IPs and the AG/Distributed AG state of all nodes before the drill |
| `failure.json` | VMs powered off and when |
| `failover.json` | DR snapshot, the DR's last pre-failure row before and after recovery, failover timestamps, Distributed AGs repointed, each forwarder's state, write test, **`rtoSeconds`** (failure injected → first write committed on DR) |
| `verify.json` | PASS/FAIL, status and write test on the new primary |
| `rpo.json` | **Exact data loss**: last ledger row on the old primary vs the DR replica (`lostTransactions`, `lostWindowSeconds`), and on each forwarder in the failed region (`forwarderLastSeq`) |
| `reinstate.json`, `failback.json` | Recovery evidence, including each forwarder's outcome |

Each action's transcript is saved next to the run folders. Passwords are never written to
evidence or transcripts.

### Success criteria

- [ ] `verify` reports **PASS**: node-2 PRIMARY in westus2, AG databases ONLINE and writable, and node-2 the global primary of every Distributed AG.
- [ ] AG3 (westus2) is SYNCHRONIZING from node-2 during the outage.
- [ ] RTO recorded, from failure injection to the first write committed in westus2.
- [ ] RPO recorded by `reinstate`, within the agreed RPO.
- [ ] node-1 rejoined as a secondary, fenced until its stale AG and Distributed AG copies were dropped (no split-brain).
- [ ] Every forwarder is SYNCHRONIZING from the new global primary after `reinstate`.
- [ ] Applications reconnect to the new primary (DNS or configuration).

**Measured RTO** includes the drill's detection window (`-DetectSeconds`, default 30 s) and about
20–40 s per `az vm run-command` call. In a real incident, detection and decision time usually
dominate.

## Example drill results (run `20260925-015339`)

A real `drill` followed by `reinstate` on 2026-09-25, against the topology above: AG1
(node-1 eastus → node-2 westus2), AG2 (node-3/node-4, eastus) and AG3 (node-5/node-6, westus2),
with SQL Server 18.0.110.3 on `Standard_D4as_v7`. `failback` was not part of this run. The
evidence is in `runs/sqlvm-257672-node-1-node-2-rg/20260925-015339/` on the machine that ran the
drill; `runs/` is git-ignored, so these tables are the committed record.

### Outcome

| Criterion | Result |
|---|---|
| `verify` | **PASS**: node-2 PRIMARY in westus2, `AGDemoDB` and `WideWorldImporters` ONLINE and writable, node-2 the global primary of both Distributed AGs |
| Detection | node-2 reported node-1 `DISCONNECTED` on the first check, so no `-Force` was needed |
| **RTO** | **170.4 s** from failure injection to the first write committed on node-2 (SQL Server clock). Tool-observed: 198.7 s |
| **RPO** | **0 transactions**: node-1's last committed ledger row (321, 01:55:45.872) had reached node-2 |
| AG3 (westus2) during the outage | repointed to node-2 and **SYNCHRONIZING**, with no re-seed |
| No split-brain | node-1 booted as `PRIMARY` with ONLINE databases (as Microsoft documents), and stayed fenced until its stale copy was dropped |
| node-1 rejoined | ASYNC secondary of node-2, re-seeded automatically |
| AG2 (eastus) after reinstate | repointed and **resynchronized**, with no re-seed |
| Applications redirected | not exercised: no Private DNS zone configured (manual repoint to `10.20.1.4`) |

The workload committed 321 ledger rows on node-1 at about 4.6 transactions/s before the outage.

### Failover timeline (UTC)

| Time | Step | Duration |
|---|---|---|
| 01:53:39 | pre-check passed (6 nodes, 2 Distributed AGs) | |
| 01:54:43 | writer started on node-1 | 60 s warm-up |
| **01:55:43.9** | **failure injected**: hard power-off of node-1, node-3, node-4 | |
| 01:55:45.9 | last write from node-1 received by node-2 (the VMs stop within ~2 s) | |
| 01:56:22 | `az vm wait` confirms all three VMs stopped | 38 s tool latency |
| 01:56:52 | end of the drill's detection window | 30 s (configured) |
| 01:57:25 | DR snapshot: node-2 sees node-1 `DISCONNECTED` | 1 Run Command, ~33 s |
| 01:57:58 | `FORCE_FAILOVER_ALLOW_DATA_LOSS` + `REMOVE REPLICA` done | 1 Run Command, ~32 s |
| 01:58:30 | both Distributed AGs repointed to `tcp://10.20.1.4:5022` | 1 Run Command, ~32 s |
| **01:58:34.3** | **first write committed on node-2** → **RTO 170.4 s** | |
| 02:00:40 | AG3 repointed, resumed and SYNCHRONIZING from node-2 | |

About 100 s of the RTO is three `az vm run-command` round trips (~32 s each). The SQL work
itself is sub-second. The script now repoints the Distributed AGs *after* the write test, which
removes one round trip (~32 s) from the next run's RTO. An operator running `sqlcmd` directly
(e.g. from a jump host in the VNet) would be faster still. In a real incident, detection and the decision to
fail over usually dominate.

### Reinstate timeline (UTC)

| Time | Step |
|---|---|
| 02:36:34 | fence applied on node-1's NSG (1433 in, 5022 in and out) |
| 02:37:20 | node-1, node-3, node-4 running |
| 02:37:42 | inspection done: node-1 booted as `PRIMARY`; **RPO = 0** |
| 02:37:42 → 02:49:35 | waiting at the `Type 'yes'` confirmation (operator), not script time |
| 02:49:43 | stale copy preserved (COPY_ONLY backups, 3 s), both Distributed AG definitions, the AG and the databases dropped on node-1 |
| 02:50:13 | 5022 fence lifted |
| 02:51:17 | node-1 rejoined as ASYNC secondary; seeding started |
| 02:54:45 | both forwarders SYNCHRONIZING from node-2 |
| 02:54:49 | 1433 fence lifted |

The script's own run time was **about 6 minutes**. The remaining 12 minutes was the
confirmation prompt before node-1's stale databases were dropped; `-AutoApprove` skips it.

### Findings from this run (fixed in `uc-01.ps1`)

1. **RTO used the wrong start and end points.** It ran from `az vm wait` confirming the VM off
   (~35 s after the outage began) to the Run Command returning (~28 s after the commit). It
   reported 163.2 s, close to the real 170.4 s only because the two errors cancelled out. It now
   runs from the failure injection to SQL Server's commit time, and `rtoSecondsToolObserved` is
   kept separately.
2. **The RPO baseline was off by one row.** The pre-failover snapshot read node-2's last row as
   320, but after recovery node-2 had 321: the row was hardened but not yet readable on the
   secondary. With the old baseline, `reinstate` would have reported 1 lost transaction instead
   of 0. The baseline is now read after recovery (`drLastSeqAfterFailover`).
3. **Repoint order.** The Distributed AG repoint moved after the write test. Applications don't
   need it in order to write.
4. **Display.** Repoint lines now name their Distributed AG. Seeding lines show only seeding still
   in progress. A forwarder whose database is still recovering after the power-off is reported
   as such, instead of being left out of `rpo.json`.

## Manual runbook (without the script)

Every step is a standalone `sqlcmd` script with scripting variables. You can run them from a
session on the node (a jump host in the VNet, or the portal's Run Command):

```bash
# node-2 (westus2) - failover
sqlcmd -S localhost -U SA -C -v AgName="agsqlvm-node-1" DbName="AGDemoDB" RunId="manual" -i 10-dr-snapshot.sql
#   -> continue only if PRIMARY_STATE=...|DISCONNECTED
sqlcmd -S localhost -U SA -C -v AgName="agsqlvm-node-1" OldPrimary="sqlvm-257672-node-1" -i 11-force-failover.sql
#   repeat 13-dag-repoint.sql for EVERY Distributed AG of AG1 (DagName=dagsqlvm-node-1-node-3, dagsqlvm-node-1-node-5, ...)
sqlcmd -S localhost -U SA -C -v DagName="dagsqlvm-node-1-node-3" MemberAg="agsqlvm-node-1" ListenerUrl="tcp://10.20.1.4:5022" -i 13-dag-repoint.sql
sqlcmd -S localhost -U SA -C -v DagName="dagsqlvm-node-1-node-5" MemberAg="agsqlvm-node-1" ListenerUrl="tcp://10.20.1.4:5022" -i 13-dag-repoint.sql
sqlcmd -S localhost -U SA -C -v DbName="AGDemoDB" RunId="manual" Rows="10" -i 12-write-test.sql
# node-5 (AG3 forwarder, still up), then node-5 and node-6
sqlcmd -S localhost -U SA -C -v DagName="dagsqlvm-node-1-node-5" MemberAg="agsqlvm-node-1" ListenerUrl="tcp://10.20.1.4:5022" -i 13-dag-repoint.sql
sqlcmd -S localhost -U SA -C -v AgName="agsqlvm-node-5" Demote="0" -i 33-demote-and-resume.sql

# eastus back - FIRST deny 1433 in, 5022 in and 5022 out on node-1's NSG, then start node-1/3/4
# node-1
sqlcmd -S localhost -U SA -C -v AgName="agsqlvm-node-1" DbName="AGDemoDB" RunId="manual" -i 20-old-primary-inspect.sql
sqlcmd -S localhost -U SA -C -v AgName="agsqlvm-node-1" DropDistributed="1" BackupDir="/var/opt/mssql/backup" RunId="manual" SkipBackup="0" -i 21-old-primary-preserve-and-drop.sql
# remove the 5022 fence rules, then on node-2:
sqlcmd -S localhost -U SA -C -v AgName="agsqlvm-node-1" ReplicaName="sqlvm-257672-node-1" EndpointUrl="tcp://10.10.1.4:5022" -i 22-add-replica.sql
# node-1
sqlcmd -S localhost -U SA -C -v AgName="agsqlvm-node-1" -i 23-join-secondary.sql
# node-3 (forwarder), then node-3 and node-4
sqlcmd -S localhost -U SA -C -v DagName="dagsqlvm-node-1-node-3" MemberAg="agsqlvm-node-1" ListenerUrl="tcp://10.20.1.4:5022" -i 13-dag-repoint.sql
sqlcmd -S localhost -U SA -C -v AgName="agsqlvm-node-3" Demote="0" -i 33-demote-and-resume.sql
# remove the 1433 fence rule
```

## Validation done while building this use case

The steps that don't change anything were run against the live environment:

- `status` on all four nodes, `10-dr-snapshot.sql` on node-2, `24-replica-sync-state.sql` on
  node-1 and `20-old-primary-inspect.sql` on node-3 all ran for real.
- **All 17 SQL files were compiled on node-1 with `SET NOEXEC ON`** (parsed and compiled, not
  executed).
- The full flow (`precheck` → `simulate-failure` → `failover` → `verify` → `reinstate` →
  `failback`) was exercised against a stateful stand-in for `az` and `sqlcmd`, with two forwarders
  (AG2 in eastus, AG3 in westus2). That run checked:
  - the undeclared-Distributed-AG guard;
  - that only eastus nodes are powered off;
  - that every Distributed AG is repointed and AG3 is re-attached during failover;
  - fence before start, and the 5022 fence lifted only after the stale copies are dropped;
  - a forwarder that can't resynchronize is reported without blocking the others;
  - the variables passed to each step, and the evidence and RPO/RTO math.

Live validation caught and fixed two defects:

1. **Collation conflict.** Concatenating AG DMV columns (`Latin1_General_CI_AS_KS_WS`) with catalog
   columns (`SQL_Latin1_General_CP1_CI_AS`) fails on these servers with Msg 451. Every DMV
   `*_desc` column now uses `COLLATE DATABASE_DEFAULT`.
2. **Failover detection.** The first version looked for the primary's state on the secondary,
   where it's always NULL. A healthy primary read as `UNKNOWN`, which the old logic treated as
   "primary lost". The check now uses the secondary's own `connected_state_desc`, and only an
   explicit `DISCONNECTED` allows a forced failover.

**Real drill:** `drill` and `reinstate` then ran against SQL Server; see
[Example drill results](#example-drill-results-run-20260925-015339). `failback` hasn't run for
real yet.

## Gaps and recommendations

1. **Only AG3 adds a surviving copy.** AG2 (node-3/node-4) is in eastus and goes down with
   node-1. AG3 in westus2 keeps a second, read-only copy alive during the outage. Keep AG3 out of
   AG1's primary region.
2. **Forwarders may need a re-seed after a forced failover.** Replication to node-2 and to every
   forwarder is asynchronous, so a forwarder can hold transactions from node-1 that node-2 never
   got. It can't resume from node-2 until it's re-seeded (`reinstate -ReseedForwarder`). For large
   databases, plan for the re-seed time and cross-region traffic.
3. **The control plane depends on the failed region.** The AG1 stack's resource group is homed
   in **eastus**. During a real eastus outage, Azure Resource Manager operations on that group
   (including `az vm run-command` against node-2) can be impaired. Keep a break-glass path that
   doesn't depend on eastus, such as a jump host in the westus2 VNet with the
   [manual runbook](#manual-runbook-without-the-script). For production, home DR resources in a
   resource group in the DR region.
4. **No automatic failover.** `CLUSTER_TYPE = NONE` needs a person to detect and decide, and
   Microsoft positions it for read-scale and migrations rather than high availability.
5. **Asynchronous DR means RPO > 0 by design.** Confirm the measured RPO is acceptable to the business.
6. **Instance names are longer than 15 characters.** Microsoft's Linux AG docs require SQL Server
   instance names of 15 characters or fewer (e.g. `sqlvm-257672-node-1` is 19). It works in this
   lab, but shorter identifiers or suffixes would stay inside the documented limits.

## Cost and cleanup

- `simulate-failure` uses *stop*, not *deallocate*: the three eastus VMs **keep billing compute**
  until `reinstate` starts them. If you pause in between, deallocate them; `reinstate` starts them.
- The ledger table `AGDemoDB.dbo.UC01_Tx` stays for later drills. It replicates everywhere; drop
  it on the primary with `DROP TABLE dbo.UC01_Tx`. Preserved backups are in
  `/var/opt/mssql/backup/uc01-*` on node-1.

## References

- [Configure a SQL Server AG for read-scale on Linux: fail over the primary replica](https://learn.microsoft.com/sql/linux/business-continuity/availability-groups/configure-read-scale#fail-over-the-primary-replica-on-a-read-scale-ag), covering forced failover and planned failover without data loss for `CLUSTER_TYPE = NONE`.
- [Configure a distributed availability group](https://learn.microsoft.com/sql/database-engine/availability-groups/windows/configure-distributed-availability-groups), covering creation, failover, and updating `LISTENER_URL` after a local failover.
- [Availability groups on Linux: the listener with cluster type NONE](https://learn.microsoft.com/sql/linux/business-continuity/availability-groups/overview#the-listener-under-linux), which says to use the primary replica's IP address.
