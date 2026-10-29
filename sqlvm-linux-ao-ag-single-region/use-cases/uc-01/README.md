# UC-01 · Planned failover (no data loss)

Move the AG's primary role to the node in the other availability zone, for example to patch or resize
the primary's VM. An application keeps writing throughout. The drill proves two things:

- **No acknowledged transaction is lost.** Both replicas are `SYNCHRONOUS_COMMIT`, and the role swap
  follows Microsoft's no-data-loss procedure for `CLUSTER_TYPE = NONE`.
- **The write interruption is a few seconds.** It is measured from the application's side, and the
  application reconnects by itself.

```
  Zone 1                                   Zone 2
 ┌────────────────────────┐   sync AG     ┌────────────────────────┐
 │ node-1  PRIMARY  ──────┼──────────────►│ node-2  SECONDARY      │
 │                        │               │  + application writer  │
 └────────────────────────┘               └────────────────────────┘
           planned failover:  node-2 PRIMARY, node-1 SECONDARY
```

## Run it

```powershell
./uc-01.ps1 -Action drill -Dashboard -Identifier 257672 -PrimaryNodeSuffix node-1 -SecondaryNodeSuffix node-2
./uc-01.ps1 -Action failback -Identifier 257672 -PrimaryNodeSuffix node-1 -SecondaryNodeSuffix node-2
```

You can also reach it from the main menu: `pwsh ./sqlvm-linux-ag.ps1` → **5) Use cases**.
`-Dashboard` opens the live dashboard in its own window (`-DashboardMode web|terminal|both`).
Pass the stack's suffixes, whichever node is primary right now. The drill always moves the role from
the current primary to the other node.

| Action | What it does |
|---|---|
| `status` | Power state, AG role, replicas and database sync state of both nodes. |
| `precheck` | Starts deallocated VMs (asks first). Checks that the secondary is `SYNCHRONOUS_COMMIT`, connected, and every database `SYNCHRONIZED`. Opens a drill run and creates the ledger table. |
| `start-workload` | Starts the application writer on the **secondary's** VM (see below). |
| `failover` | The planned failover (see below), then waits for the application's first commit on the new primary. |
| `verify` | Old primary `SYNCHRONIZED` as the new secondary. Every acknowledged commit is in the new primary's ledger. Databases `ONLINE`. The application writes to the new primary. |
| `drill` | `precheck` → `start-workload` → warm-up (`-WarmupSeconds`, 60) → `failover` → observe (`-ObserveSeconds`, 60) → `verify` → stop the writer (`-KeepWorkload` keeps it). |
| `failback` | The same planned failover back to the original primary, plus verification. If the writer is no longer running, it is restarted first. |
| `stop-workload` | Stops the writer. |

## The application writer

A small loop on the secondary's VM stands in for the application. It runs on that VM so that it
survives a failure of the primary's (in UC-02). Every ~0.2 s it commits one ledger row
(`dbo.UC_Tx` in `AGDemoDB`) to one of the two nodes' private IPs. On any error (AG offline,
read-only secondary, node down) it switches to the other IP, just like an application configured
with both server addresses. It logs every attempt with its time:

- **Write interruption (RTO):** the gap between the last commit on the old primary and the first one
  on the new primary.
- **Lost transactions (RPO):** the writer's sequence number only advances when a commit returns. Any
  number up to the last acknowledged one that is missing from the new primary's ledger was lost.
  It must be 0.
- **Throughput, failed attempts and slowest commit**, per second, for the charts.

## The planned failover

1. **Synchronize**: on the primary, both replicas are made `SYNCHRONOUS_COMMIT` and
   `REQUIRED_SYNCHRONIZED_SECONDARIES_TO_COMMIT = 1` is set. Then the drill waits until every
   database is `SYNCHRONIZED` on the target.
2. **One Run Command on the primary** does the rest, so the interruption isn't stretched by
   Run Command round trips (10–30 s each):
   - it re-checks that every database is `SYNCHRONIZED` (if not, it aborts and nothing changes);
   - `ALTER AVAILABILITY GROUP … OFFLINE` stops writes;
   - it promotes the target over the VNet (`sqlcmd -S <target private IP>`, `FORCE_FAILOVER_ALLOW_DATA_LOSS`);
     nothing is lost, because the target is synchronized and the old primary is offline;
   - `SET (ROLE = SECONDARY)` demotes the old primary, data movement resumes on both sides, and
     the commit gate goes back to 0.

   If the promotion fails, the old primary takes the primary role back.
3. **App reconnects**: the drill waits for the writer's first commit on the new primary. That stops
   the *Write interruption* clock.

## Dashboard

[`dashboard.json`](dashboard.json) defines what the dashboard shows:

- **Topology:** one column per zone.
- **Clocks:** the *Write interruption* clock, and the failback clock.
- **Key numbers:** write interruption (target ≤ 30 s), lost transactions (target 0), throughput and
  role-swap time.
- **Charts:** throughput, failed attempts, slowest commit, send and redo queues. Each chart has
  markers at warm-up, AG offline and reconnect.
- **Success criteria:** nothing lost, interruption measured, the application reconnected by itself,
  the old primary resynchronized, the new primary verified.

Evidence and the event log of every run are in `runs/<resource-group>/<run-id>/` (git-ignored).
A static `report.html` is written at the end of a drill.
