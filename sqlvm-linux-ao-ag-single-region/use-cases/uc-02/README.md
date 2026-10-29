# UC-02 · Zone failure of the primary (forced failover)

The primary's availability zone is lost. The drill powers off the primary's VM hard, with no guest
shutdown. The secondary in the other zone detects the loss and is promoted with
`FORCE_FAILOVER_ALLOW_DATA_LOSS`, and the application reconnects to it by itself. Because both
replicas are `SYNCHRONOUS_COMMIT`, **every commit the application got acknowledged is already on the
secondary**. The drill proves it with a ledger, and measures the RTO from the application's side.
Later, `reinstate` brings the failed node back safely as the new secondary.

```
  Zone 1  ■ DOWN                           Zone 2
 ┌────────────────────────┐               ┌────────────────────────┐
 │ node-1  (powered off)  │      ╳        │ node-2  PRIMARY ★      │
 │                        │               │  + application writer  │
 └────────────────────────┘               └────────────────────────┘
```

## Run it

```powershell
./uc-02.ps1 -Action drill -Dashboard -Identifier 257672 -PrimaryNodeSuffix node-1 -SecondaryNodeSuffix node-2
./uc-02.ps1 -Action reinstate -Identifier 257672 -PrimaryNodeSuffix node-1 -SecondaryNodeSuffix node-2
./uc-02.ps1 -Action failback  -Identifier 257672 -PrimaryNodeSuffix node-1 -SecondaryNodeSuffix node-2
```

You can also reach it from the main menu: `pwsh ./sqlvm-linux-ag.ps1` → **5) Use cases**.
`-Dashboard` opens the live dashboard in its own window.

| Action | What it does |
|---|---|
| `status` | Power state, AG role and health of both nodes, plus any fence rules left in place. |
| `precheck` | Starts deallocated VMs (asks first). Checks that the secondary is `SYNCHRONOUS_COMMIT`, connected, and every database `SYNCHRONIZED`. Opens a drill run and creates the ledger table. |
| `start-workload` | Starts the application writer on the secondary's VM, the node that survives (see [UC-01](../uc-01/README.md#the-application-writer)). |
| `simulate-failure` | `az vm stop --skip-shutdown` on the primary's VM, which loses the zone's only member of the stack. Starts the outage clock. |
| `failover` | **Detection**: the secondary's own replica row must report `DISCONNECTED` (rechecked for ~30 s; `-Force` overrides). **Forced failover**: `FORCE_FAILOVER_ALLOW_DATA_LOSS`, resume, commit gate 0. **App reconnects**: waits for the writer's first commit on the new primary, which stops the outage clock (RTO). |
| `verify` | The new primary's databases are `ONLINE`, and every commit acknowledged **before the failure** is in its ledger (lost = 0). The application writes to it. |
| `drill` | `precheck` → `start-workload` → warm-up → `simulate-failure` → detection window (`-DetectSeconds`, 15) → `failover` → `verify` → stop the writer (`-KeepWorkload` keeps it). |
| `reinstate` | The zone is back (see below). |
| `failback` | Planned, no-data-loss failover back to the original primary ([UC-01's procedure](../uc-01/README.md#the-planned-failover)), plus verification. |
| `stop-workload` | Stops the writer. |

The old primary is **not** removed from the AG: with `CLUSTER_TYPE = NONE` it would have to be
re-seeded, and with synchronous commit there is nothing to rescue from it. `reinstate` demotes it
instead.

## Reinstate

When the old primary boots, it may still believe it is PRIMARY. Nothing may reach it before it is
demoted.

1. **Fence**: deny rules on its NIC NSG (inbound 1433, inbound and outbound 5022), applied
   **before** it is powered on. Criterion: *fenced before power-on*.
2. **Node back**: `az vm start`, then wait for SQL Server.
3. **Inspect**: reads its ledger, while still fenced, to count the rows only it has. These are
   commits that were in flight at the failure and whose acknowledgement never reached the
   application. They are discarded by the demotion, and that's correct, because the application
   never saw them succeed.
4. **Demote**: if it booted as PRIMARY, `OFFLINE` and then `SET (ROLE = SECONDARY)`.
5. **Resynchronize**: lifts the 5022 fence, resumes data movement on both nodes, and waits until
   every database is `SYNCHRONIZED`. If its copy diverged and can't resume, rebuild the node:
   `../../sqlvm-linux-ag.ps1 -Action remove -RemoveScope <primary|secondary>`, then `-Action deploy`.
   It is re-seeded from the new primary.
6. **Lift fence**: removes the 1433 rule. It is a readable secondary again.

## Dashboard

[`dashboard.json`](dashboard.json) defines what the dashboard shows:

- **Topology:** one column per zone. The failed zone turns red (**ZONE DOWN**) when its node is off.
- **Clocks:** the outage clock, and the failback clock.
- **Key numbers:** RTO, lost transactions (target 0), throughput, and rows only on the old primary.
- **Charts:** throughput dropping to 0 and recovering, failed attempts, and the replication queues
  during the resync.
- **Success criteria:** verified new primary, RPO 0, RTO measured, the application reconnected by
  itself, fenced before power-on, the old primary resynchronized.

Evidence and the event log of every run are in `runs/<resource-group>/<run-id>/` (git-ignored).
A static `report.html` is written at the end of a drill.
