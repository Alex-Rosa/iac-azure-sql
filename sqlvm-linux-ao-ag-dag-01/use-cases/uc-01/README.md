# UC-01 — Region failure of the primary node

| | |
|---|---|
| **Failure scenario** | The Azure region that hosts the **primary** replica fails. Every node in that region is unavailable. |
| **Expected resolution** | **Fail all transactions over to the alternate region.** The DR replica becomes primary (and the Distributed AG's global primary), accepts reads and writes, and applications are redirected to it. |
| **Topology** | AG1 `agsqlvm-node-1`: `sqlvm-257672-node-1` (eastus, primary) → `sqlvm-257672-node-2` (westus2, async DR). Distributed AG `dagsqlvm-node-1-node-3`: AG1 → AG2 `agsqlvm-node-3` (forwarder `node-3` + `node-4`, both eastus). |
| **Failure domain (eastus)** | node-1 (AG1 primary), node-3 (AG2 forwarder), node-4 (AG2 secondary). Only **node-2 (westus2)** survives. |

## Topology

```
BEFORE (all healthy)
  eastus                                                          westus2
  ┌─────────────────────────┐   async (AG1)                       ┌─────────────────────────┐
  │ node-1  AG1 PRIMARY     │────────────────────────────────────►│ node-2  AG1 SECONDARY   │
  │ = DAG global primary    │                                      └─────────────────────────┘
  └───────────┬─────────────┘
              │ async (Distributed AG dagsqlvm-node-1-node-3)
  ┌───────────▼─────────────┐   async (AG2)   ┌─────────────────────────┐
  │ node-3  AG2 PRIMARY     │────────────────►│ node-4  AG2 SECONDARY   │
  │ = DAG forwarder         │                 └─────────────────────────┘
  └─────────────────────────┘

AFTER failover (eastus down)                   AFTER reinstate (eastus back)
  node-1, node-3, node-4: DOWN                   node-2  AG1 PRIMARY = DAG global primary (westus2)
  node-2  AG1 PRIMARY (westus2)                    ├─► node-1  AG1 SECONDARY (async, re-seeded)
          = DAG global primary                     └─► node-3  forwarder (repointed to node-2) ─► node-4
          node-1 removed from AG1                optional: failback (planned, no data loss) to node-1
```

- **`CLUSTER_TYPE = NONE`**, so failover is manual and there is **no listener**. The Distributed
  AG's `LISTENER_URL` for AG1 is the endpoint of AG1's current primary, and it has to follow
  every role change of AG1.
- **Asynchronous DR**: the transactions that hadn't reached westus2 are lost when eastus fails.
  **RPO > 0 is expected.** The drill measures it exactly.
- **The Distributed AG doesn't add a cross-region copy for this scenario.** The forwarder AG
  (node-3/node-4) is in the same region as the primary and goes down with it. node-2 in westus2
  is the only surviving copy.

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
- Both stacks deployed with `../../deploy.ps1` (credentials in `../../state/`), and the
  Distributed AG created with `../../deploy.ps1 -Action deploy-dag`.
- Every node running, all AGs healthy, and the forwarder SYNCHRONIZING. `precheck` verifies this
  (and offers to start deallocated VMs).

## Quick start

```bash
cd iac-azure-sql/sqlvm-linux-ao-ag-dag-01/use-cases/uc-01
N="-Identifier 257672 -PrimaryNodeSuffix node-1 -SecondaryNodeSuffix node-2 -ForwarderPrimarySuffix node-3 -ForwarderSecondarySuffix node-4"

# 1. Where are we? (read-only, all four nodes)
pwsh ./uc-01.ps1 -Action status $N

# 2. Full drill: precheck -> writer on node-1 -> 60 s warm-up -> hard power-off of node-1, node-3, node-4
#    -> 30 s detection window -> forced failover to node-2 (+ Distributed AG repoint) -> verification
pwsh ./uc-01.ps1 -Action drill $N

# 3. "eastus is back": fence node-1, start the region, measure the exact data loss, rejoin node-1,
#    re-attach the forwarder AG to node-2
pwsh ./uc-01.ps1 -Action reinstate $N

# 4. Optional: planned failback to eastus (no data loss), Distributed AG repointed back to node-1
pwsh ./uc-01.ps1 -Action failback $N
```

In zsh, write `${=N}` instead of `$N`. Run `pwsh ./uc-01.ps1` with no parameters to get prompts
for everything. Use `-ForwarderPrimarySuffix none` for a stack without a Distributed AG.

## Actions

| Action | Where it runs | What it does |
|---|---|---|
| `status` | all nodes | Power state, local role, replicas, databases, Distributed AG members and forwarder sync, and fence rules. |
| `precheck` | all nodes | Starts deallocated VMs (asks first). Requires node-1 PRIMARY, node-2 SECONDARY and CONNECTED, all AG databases ONLINE and not suspended, and the Distributed AG present with the forwarder CONNECTED and SYNCHRONIZING. Opens a new **drill run** and creates the ledger table `AGDemoDB.dbo.UC01_Tx`, which replicates to node-2 and to the forwarder. |
| `start-workload` | node-1 | Detached writer: one committed ledger row (`run_id`, `seq`, `phase='pre-failure'`) about every 0.2 s for `-WorkloadSeconds` (default 900). |
| `simulate-failure` | eastus | `az vm stop --skip-shutdown` on **every node in the primary's region** (node-1, node-3, node-4), all at once: a hard power-off, like losing the region. |
| `failover` | **westus2 only** | See below. Never touches eastus resources. |
| `verify` | node-2 | PRIMARY role, AG databases ONLINE, a write test, and node-2 as the Distributed AG's global primary. |
| `drill` | — | `precheck` → `start-workload` → warm-up → `simulate-failure` → detection window → `failover` → `verify`, with one confirmation. |
| `reinstate` | all nodes | See below. |
| `failback` | node-1, node-2, node-3 | Planned role swap back to node-1 with no data loss, then repoints the Distributed AG. |

### Failover (the resolution)

Runs on node-2 only:

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
3. **Repoint the Distributed AG.** Uses [`13-dag-repoint.sql`](sql/13-dag-repoint.sql) on node-2:
   `MODIFY AVAILABILITY GROUP ON N'agsqlvm-node-1' WITH (LISTENER_URL = N'tcp://10.20.1.4:5022')`.
   node-2 is now the global primary. The Distributed AG definition already exists on node-2,
   because it's replicated to every replica of AG1.
4. **Prove transactions are accepted.** Uses [`12-write-test.sql`](sql/12-write-test.sql) to insert
   `-WriteTestRows` rows (`phase='post-failover'`) on node-2.
5. **Redirect clients.** Sets the optional Private DNS record (see
   [Redirecting transactions](#redirecting-transactions)).
6. **Evidence.** Writes `failover.json`, including the **RTO** from node-1's power-off to the
   first committed write in westus2.

### Reinstate (eastus recovered)

1. **Fence node-1 before powering it on.** Three NSG rules go on `sqlvm-257672-node-1-nsg`: deny
   inbound 1433 (`uc01-fence-deny-sql`), deny inbound 5022 (`uc01-fence-deny-hadr-in`) and deny
   outbound 5022 (`uc01-fence-deny-hadr-out`). node-1 boots believing it's still AG1's primary
   **and** the Distributed AG's global primary. The forwarder (node-3) boots still pointing at
   node-1, so without the 5022 fence it could receive log from the stale primary.
2. Starts node-1, node-3 and node-4.
3. [`20-old-primary-inspect.sql`](sql/20-old-primary-inspect.sql) on node-1 and node-3 measures the
   **exact RPO**: the rows node-1 committed that never reached node-2, and how far the forwarder
   got. Saved to `rpo.json`.
4. [`21-old-primary-preserve-and-drop.sql`](sql/21-old-primary-preserve-and-drop.sql) on node-1:
   - takes `COPY_ONLY` backups of the stale databases (skip with `-SkipOrphanBackup`);
   - drops the stale **Distributed AG** definition;
   - `AG OFFLINE`, then `DROP AVAILABILITY GROUP`, then drops the databases.
5. Lifts the 5022 fence and keeps 1433 fenced.
   [`22-add-replica.sql`](sql/22-add-replica.sql) on node-2 and
   [`23-join-secondary.sql`](sql/23-join-secondary.sql) on node-1 rejoin node-1 as an
   **ASYNCHRONOUS** secondary, and the script waits for automatic seeding.
6. **Re-attaches the forwarder.** Runs [`13-dag-repoint.sql`](sql/13-dag-repoint.sql) on node-2
   and on node-3 (AG1's URL → node-2), resumes data movement on node-3 and node-4
   ([`33`](sql/33-demote-and-resume.sql)), and waits up to `-ForwarderResyncMinutes` (default 15)
   for the forwarder to be SYNCHRONIZING ([`14-dag-status.sql`](sql/14-dag-status.sql)).
   - If the forwarder had received transactions from node-1 that node-2 never got, it may not be
     able to resume. With `-ReseedForwarder`, the script then rebuilds the Distributed AG
     (`deploy.ps1 -Action remove-dag` + `deploy-dag`), which re-seeds the forwarder from node-2.
     Without the switch, it reports the problem and the commands to run.
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
7. [`13`](sql/13-dag-repoint.sql) on node-1 and node-3: AG1's `LISTENER_URL` → node-1, then waits
   for the forwarder to resynchronize. Repoints DNS and runs a write test.

Commits wait for the secondary during steps 1–5, and writes pause during the offline/promote
window. Schedule it.

## Redirecting transactions

With `CLUSTER_TYPE = NONE` there's **no AG listener**, so nothing moves client connections
automatically. "Fail all transactions over" therefore needs one of these:

| Option | How |
|---|---|
| **Private DNS record (recommended)** | Applications connect to a name such as `sqlprimary.sqlag.internal`. Pass `-PrivateDnsZone sqlag.internal -PrivateDnsRecord sqlprimary [-PrivateDnsResourceGroup <rg>]`. `failover` points the A record to node-2 and `failback` points it back. Azure Private DNS is a global service, so it keeps working during a regional outage. Keep the TTL low (10–30 s). |
| **Connection-string switch** | Change the application's server from node-1 (`10.10.1.4`) to node-2 (`10.20.1.4`), then recycle connection pools. |

Read-only consumers of the forwarder (node-3/node-4) are in the failed region and are down
until `reinstate`.

## Evidence (`runs/<rg>/<run-id>/`)

| File | Content |
|---|---|
| `events.jsonl` | Timeline (UTC): precheck, workload, failure injected, failover, Distributed AG repoint, first write on DR, fence, region started, rejoin, forwarder re-attached, … |
| `precheck.json` | Nodes, regions, IPs and the AG/Distributed AG state of all nodes before the drill |
| `failure.json` | VMs powered off and when |
| `failover.json` | DR snapshot, failover timestamps, Distributed AG repoint, write test, **`rtoSecondsFromPowerOff`** |
| `verify.json` | PASS/FAIL, status and write test on the new primary |
| `rpo.json` | **Exact data loss**: last ledger row on the old primary vs the DR replica (`lostTransactions`, `lostWindowSeconds`), and on the forwarder (`forwarderLastSeq`) |
| `reinstate.json`, `failback.json` | Recovery evidence, including the forwarder outcome |

Each action's transcript is saved next to the run folders. Passwords are never written to
evidence or transcripts.

### Success criteria

- [ ] `verify` reports **PASS**: node-2 PRIMARY in westus2, AG databases ONLINE and writable, and node-2 the Distributed AG's global primary.
- [ ] RTO recorded, from power-off to the first committed write in westus2.
- [ ] RPO recorded by `reinstate`, within the agreed RPO.
- [ ] node-1 rejoined as a secondary, fenced until its stale AG and Distributed AG copy were dropped (no split-brain).
- [ ] The forwarder AG is SYNCHRONIZING from the new global primary.
- [ ] Applications reconnect to the new primary (DNS or configuration).

**Measured RTO** includes the drill's detection window (`-DetectSeconds`, default 30 s) and about
20–40 s per `az vm run-command` call. In a real incident, detection and decision time usually
dominate.

## Manual runbook (without the script)

Every step is a standalone `sqlcmd` script with scripting variables. You can run them from a
session on the node (Bastion, or the portal's Run Command):

```bash
# node-2 (westus2) - failover
sqlcmd -S localhost -U SA -C -v AgName="agsqlvm-node-1" DbName="AGDemoDB" RunId="manual" -i 10-dr-snapshot.sql
#   -> continue only if PRIMARY_STATE=...|DISCONNECTED
sqlcmd -S localhost -U SA -C -v AgName="agsqlvm-node-1" OldPrimary="sqlvm-257672-node-1" -i 11-force-failover.sql
sqlcmd -S localhost -U SA -C -v DagName="dagsqlvm-node-1-node-3" MemberAg="agsqlvm-node-1" ListenerUrl="tcp://10.20.1.4:5022" -i 13-dag-repoint.sql
sqlcmd -S localhost -U SA -C -v DbName="AGDemoDB" RunId="manual" Rows="10" -i 12-write-test.sql

# eastus back - FIRST deny 1433 in, 5022 in and 5022 out on node-1's NSG, then start node-1/3/4
# node-1
sqlcmd -S localhost -U SA -C -v AgName="agsqlvm-node-1" DbName="AGDemoDB" RunId="manual" -i 20-old-primary-inspect.sql
sqlcmd -S localhost -U SA -C -v AgName="agsqlvm-node-1" DagName="dagsqlvm-node-1-node-3" BackupDir="/var/opt/mssql/backup" RunId="manual" SkipBackup="0" -i 21-old-primary-preserve-and-drop.sql
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
  `failback`) was exercised against a stateful stand-in for `az` and `sqlcmd`. That run checked
  the ordering (fence before start; 5022 fence lifted only after the stale copy is dropped;
  Distributed AG repointed on both sides), the variables passed to each step, and the evidence and
  RPO/RTO math.

Live validation caught and fixed two defects:

1. **Collation conflict.** Concatenating AG DMV columns (`Latin1_General_CI_AS_KS_WS`) with catalog
   columns (`SQL_Latin1_General_CP1_CI_AS`) fails on these servers with Msg 451. Every DMV
   `*_desc` column now uses `COLLATE DATABASE_DEFAULT`.
2. **Failover detection.** The first version looked for the primary's state on the secondary,
   where it's always NULL. A healthy primary read as `UNKNOWN`, which the old logic treated as
   "primary lost". The check now uses the secondary's own `connected_state_desc`, and only an
   explicit `DISCONNECTED` allows a forced failover.

**Still to do:** a real drill. The destructive steps (forced failover, reinstate, failback)
haven't run against SQL Server yet.

## Gaps and recommendations

1. **The forwarder AG shares the primary's failure domain.** node-3 and node-4 are in eastus, so
   an eastus outage takes them down together with node-1, and the Distributed AG adds no
   surviving copy for this scenario. To make it contribute to DR, place the forwarder AG in
   another region. It can also be the global primary with AG1 as the forwarder.
2. **The forwarder may need a re-seed after a forced failover.** If node-3 received transactions
   from node-1 that node-2 never got, it can't simply resume from node-2. `-ReseedForwarder`
   automates the rebuild. For large databases, plan for the re-seed time and traffic.
3. **The control plane depends on the failed region.** The AG1 stack's resource group is homed
   in **eastus**. During a real eastus outage, Azure Resource Manager operations on that group
   (including `az vm run-command` against node-2) can be impaired. Keep a break-glass path that
   doesn't depend on eastus, such as Bastion or a jump host in the westus2 VNet with the
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
