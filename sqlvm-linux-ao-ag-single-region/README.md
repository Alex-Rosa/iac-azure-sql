# sqlvm-ag — Single-Region SQL Server Always On AG on RHEL 9 (Bicep, suffix-driven)

A 2-node SQL Server **Always On Availability Group** on **RHEL 9** (SQL Server installed from a
**local RPM**), with **both VMs in the same Azure region**, spread across **availability zones**.
One interactive script, **`sqlvm-linux-ag.ps1`**, drives everything. It asks for:

1. **What to do**, from a sectioned menu: **Deploy**, **Remove**, **Check**, **Operate**, **Use cases** or
   **Dashboard** (see [The menu](#the-menu))
2. **Unique identifier** for the object names, for example `257672` (any 1–15 lowercase letters, digits or hyphens)
3. **Primary node suffix**, for example `node-1`
4. **Secondary node suffix**, for example `node-2`
5. **Region** of both nodes (only asked on `deploy` of a new stack)
6. **VM size**, picked from a list of the sizes available in the region (new stacks only)
7. **SSH/SQL access** on `deploy`: your current public IP (the default), `parameters.json`, or your own list
8. **What to remove** on `remove`: the whole stack, only the primary node, or only the secondary node

Every Azure object is named from the identifier and the suffixes, so each identifier + suffix
pair is an independent stack. You can run `node-1`/`node-2` and `node-3`/`node-4` side by side
in the same subscription, and remove either one without touching the other.

This project is the single-region sibling of
[`sqlvm-linux-ao-ag-dag-01`](../sqlvm-linux-ao-ag-dag-01) (cross-region AG + Distributed AG). It uses the same
SQL Server install, certificate handling, naming, credentials and logging, and differs in these ways:

| | `sqlvm-linux-ao-ag-dag-01` | this project |
|---|---|---|
| Regions | two (primary + secondary) | **one** |
| Network | one VNet per node + global peering | **one VNet / subnet** for both nodes, no peering |
| Resilience | region failure (DR) | **zone failure** (availability zones) or host failure (availability set) |
| Commit mode | primary sync, secondary **async** | **both SYNCHRONOUS_COMMIT** |
| Failover | forced only (`FORCE_FAILOVER_ALLOW_DATA_LOSS`) | **planned, no data loss** (`failover`), forced (`force-failover`), `reinstate` |
| Distributed AG | yes | no |
| Use cases (drills) | region failure of the primary / of the secondary | **UC-01 planned failover**, **UC-02 zone failure of the primary (forced failover)** |
| Dashboard (live / replay, web / terminal) | yes, one column per region | yes, **one column per availability zone** |

## Architecture

```
  Region: <region>          RG: sqlvm-<id>-<pri>-<sec>-rg
  ┌───────────────────────────────────────────────────────────────────────────┐
  │ VNet sqlvm-<id>-<pri>-<sec>-vnet   10.<n>.0.0/16 (auto-picked)            │
  │ subnet default 10.<n>.1.0/24 + subnet NSG sqlvm-<id>-<pri>-<sec>-subnet-nsg │
  │                                                                           │
  │   Zone 1                                  Zone 2                          │
  │  ┌──────────────────────────┐            ┌──────────────────────────┐     │
  │  │ sqlvm-<id>-<pri>-vm      │◄─ AG 5022 ─►│ sqlvm-<id>-<sec>-vm      │     │
  │  │ RHEL 9 + SQL Server      │  (sync)    │ RHEL 9 + SQL Server      │     │
  │  │ PRIMARY  SYNCHRONOUS     │            │ SECONDARY (readable)     │     │
  │  │                          │            │ SYNCHRONOUS              │     │
  │  └──────────────────────────┘            └──────────────────────────┘     │
  └───────────────────────────────────────────────────────────────────────────┘
```

- **`CLUSTER_TYPE = NONE`**: no Pacemaker, no WSFC. A failover is a deliberate manual action:
  run `failover` or `force-failover`.
- **Both replicas run `SYNCHRONOUS_COMMIT`**: a commit is hardened on the secondary before it is
  acknowledged. Inside one region the latency cost is small, and a planned failover loses no data.
  `REQUIRED_SYNCHRONIZED_SECONDARIES_TO_COMMIT` stays `0`, so the primary keeps accepting writes
  while the secondary is down. It is raised to `1` only during a planned failover.
- **Placement**: when the VM size can be deployed in at least two zones of the region, the
  primary gets the first zone and the secondary the second. A zone outage takes out one replica
  only. Otherwise both VMs go in one **availability set**, which puts them on separate fault and
  update domains. You can override this with `-Placement zones|availability-set|none`.
- **Certificate-based endpoint authentication**: the nodes are not domain-joined.
  `sqlvm-linux-ag.ps1` exchanges the certificates between them.
- **Automatic seeding**: databases added on the primary are copied to the secondary by SQL Server.
- **SQL Server Developer edition**: dev/test licence only. For production, change `MSSQL_PID` in
  `scripts/install-sqlserver.sh`.
- **No listener**: with `CLUSTER_TYPE = NONE` there's no automatic listener. After a failover,
  applications reconnect to the new primary's IP.

## Object naming

With prefix `sqlvm`, identifier `257672` and suffixes `node-1` / `node-2`:

| Object | Name |
|---|---|
| Resource group | `sqlvm-257672-node-1-node-2-rg` |
| VNet / subnet NSG | `sqlvm-257672-node-1-node-2-vnet` / `sqlvm-257672-node-1-node-2-subnet-nsg` |
| Availability set (only without zones) | `sqlvm-257672-node-1-node-2-avset` |
| VM / hostname / AG replica | `sqlvm-257672-node-1-vm` / `sqlvm-257672-node-1` |
| NIC, NSG, public IP | `sqlvm-257672-node-1-nic`, `-nsg`, `-pip` |
| Disks | `sqlvm-257672-node-1-osdisk`, `sqlvm-257672-node-1-sqldata` |
| Availability Group | `agsqlvm-node-1` (override with `-AgName`) |
| ARM deployment record | `sqlvm-257672-node-1-node-2-sr-<region>` (subscription scope; `-sr-` keeps it apart from the cross-region project's records) |

The identifier is 1–15 characters: lowercase letters, digits and hyphens. It can't start or end
with a hyphen. A suffix is 1–20 characters with the same rules, and the two suffixes must be
different. Use the same identifier and suffixes on every later run to reach the same stack.

## Repo layout

```
sqlvm-linux-ao-ag-single-region/
├── README.md
├── sqlvm-linux-ag.ps1      # entry point: menu with Deploy / Remove / Check / Operate / Use cases / Dashboard
├── bicep/
│   ├── main.bicep          # subscription scope: resource group + resources module
│   ├── resources.bicep     # stack VNet + subnet NSG, availability set (optional), the two nodes
│   ├── node.bicep          # one node: NSG, PIP, NIC, data disk, VM (used twice), zonal when asked
│   └── parameters.json     # shared settings: admin user, allowedSourceIps, disk size, tags
└── scripts/                # run on the VMs (install + ag-01..07: over SSH; ag-08/09: through az vm run-command)
    ├── install-sqlserver.sh
    ├── ag-01-endpoint.sh               # both nodes: master key, certificate, HADR endpoint
    ├── ag-02-trust-peer.sh             # both nodes: trust the peer's certificate
    ├── ag-03-create-primary.sh         # AG primary: CREATE AVAILABILITY GROUP (both replicas synchronous)
    ├── ag-04-join-secondary.sh         # AG secondary: JOIN
    ├── ag-05-create-demo-db.sh         # AG primary: AGDemoDB added to the AG
    ├── ag-06-restore-wideworldimporters.sh  # AG primary: WideWorldImporters added to the AG
    ├── ag-07-verify.sh                 # AG primary: replica health + expected DBs present
    ├── ag-08-status.sh                 # any node: AG role, replicas, database sync state (KEY=VALUE)
    └── ag-09-failover-step.sh          # one failover step: prepare / offline / promote / demote / resume / ...
├── dashboard/              # live / replay dashboard of a use-case run (see dashboard/README.md)
│   ├── dashboard.ps1       # web server (localhost) + terminal view + replay + static report / compare
│   └── web/                # index.html (the page), compare.html (runs side by side) - self-contained
└── use-cases/              # failure drills: uc-NN/uc-NN.ps1 + README + dashboard.json, listed in the menu automatically
    ├── common/
    │   ├── uc-common.ps1   # framework: prompts, Run Command transport, zone topology, application writer +
    │   │                   # monitoring, planned role swap, verification, evidence, main runner
    │   ├── uc-events.ps1   # dashboard events (phases, nodes, links, metrics, samples, clocks)
    │   └── sql/            # ledger table + ledger check (lost-transaction measurement)
    ├── uc-01/              # planned failover to the other zone (no data loss) + failback
    └── uc-02/              # zone failure of the primary: forced failover, reinstate, failback
```

Generated at runtime (git-ignored): `logs/` holds the transcripts, `state/` holds the
credentials and a known_hosts file for each stack, and `use-cases/uc-NN/runs/` holds each drill's
evidence, event log and report.

## Prerequisites

1. **PowerShell 7+** (`pwsh`). Works on macOS, Linux and Windows.
2. **Azure CLI**. On macOS run `brew install azure-cli`; on Windows run `winget install Microsoft.AzureCLI`.
   Bicep is installed automatically.
3. **ssh / scp** (built into macOS, Linux and Windows 10/11).
4. **SSH key pair** at `~/.ssh/id_rsa` (or pass `-SshKeyPath`):
   `ssh-keygen -t rsa -b 4096 -f ~/.ssh/id_rsa -N ""`
5. **`Rhel9.zip`** with the SQL Server RPMs. It is not in git. `sqlvm-linux-ag.ps1` looks for it
   next to itself, then in `../sqlvm-linux-ao-ag-dag-01/`, then in `~/Downloads`. If it finds
   none, it asks for the path. You can also pass `-RhelZipPath`. The zip needs at least
   `mssql-server-<version>-1.x86_64.rpm`. The `-ha-`, `-extensibility-` and `-polybase-` RPMs are ignored.
6. An Azure subscription with `Contributor` access.

## Quick start

```bash
az login
az account set --subscription "<name or id>"
cd sqlvm-linux-ao-ag-single-region
pwsh ./sqlvm-linux-ag.ps1
```

Every prompt can also be passed as a parameter. Nothing is asked for a parameter you pass:

```powershell
./sqlvm-linux-ag.ps1 -Action deploy -Identifier 257672 -PrimaryNodeSuffix node-1 -SecondaryNodeSuffix node-2 `
             -Location westus2 -VmSize Standard_D4as_v7 -AllowedSourceIps auto

./sqlvm-linux-ag.ps1 -Action failover  -Identifier 257672 -PrimaryNodeSuffix node-1 -SecondaryNodeSuffix node-2
./sqlvm-linux-ag.ps1 -Action status-ag -Identifier 257672 -PrimaryNodeSuffix node-1 -SecondaryNodeSuffix node-2
./sqlvm-linux-ag.ps1 -Action remove    -Identifier 257672 -PrimaryNodeSuffix node-1 -SecondaryNodeSuffix node-2 -RemoveScope stack
```

A full deploy takes about 15–20 minutes. The credentials are printed before any remote work
starts. They are also saved to `state/<resource-group>.credentials.json`, so a rerun reuses them.

### Choosing the VM size and placement

For a new stack, the script reads the VM sizes offered in the region and lists those that pass
these checks. The lookup takes 30–60 seconds.

- The size isn't restricted for your subscription in that region.
- It fits this deployment: x64 (the SQL Server RPM is x86_64), Hyper-V Gen2 (the RHEL 9 image is
  gen2), Premium SSD support, at least 2 vCPUs and at least 8 GB RAM.
- There's enough free vCPU quota, for the **VM family** and for the **total regional vCPUs**,
  to hold both VMs.

The list has a **Zones** column showing the zones in which you may deploy that size. A size with two or
more gets one node per zone. A size with fewer gets an availability set. You can filter the list
(`D4`, `E8s`, `v7`, …), pick a number or type a size name. Press Enter to take
`Standard_D4as_v7` when it's shown.

**Other cases:**
- **`-VmSize` given:** the list is skipped. The size is checked in the region (restrictions and
  quota). If the check fails, the script asks for another region, or you can type `force` or `quit`.
- **`-AutoApprove` without `-VmSize`:** uses `Standard_D4as_v7`.
- **Existing stack:** the region, size and placement of the existing VMs are kept.
- **Rebuilt node:** uses the existing node's size, and goes to another zone (or to the same
  availability set).

## The menu

Run `pwsh ./sqlvm-linux-ag.ps1` with no `-Action`. Pick a section, then an option (`0` goes back):

| Section | Options (`-Action` name) |
|---|---|
| **1) Deploy** | Stack (`deploy`): create, resume, or rebuild a removed node |
| **2) Remove** | Stack or one node (`remove`) |
| **3) Check** | VM status (`status`), AG status (`status-ag`), connection info (`output`) |
| **4) Operate** | Refresh SSH/SQL access (`refresh-access`), planned failover (`failover`), forced failover (`force-failover`), `reinstate` |
| **5) Use cases** | Every `use-cases/uc-NN/` folder with a `uc-NN.ps1`, titled from its README's first line |
| **6) Dashboard** | Live progress or replay of a use-case run, as a web page and/or in the terminal (`dashboard`) |

**Use cases.** The identifier is asked once here and passed on; the use case asks for everything
else with its own prompts. `-PrimaryNodeSuffix`, `-SecondaryNodeSuffix`, `-Prefix`, `-AgName` and
`-AutoApprove` are passed through when you give them on the command line. To run one directly:

```powershell
./sqlvm-linux-ag.ps1 -UseCase uc-02 -UseCaseAction drill -Identifier 257672   # or -UseCase 2
./use-cases/uc-02/uc-02.ps1 -Action drill -Identifier 257672 ...              # same thing, called directly
```

## Actions

| Action | What it does |
|---|---|
| `deploy` | Creates the resource group, VNet, both nodes. Installs SQL Server, builds the AG, adds `AGDemoDB` and `WideWorldImporters`, then verifies. Safe to re-run: existing healthy VMs skip Bicep, nodes that already answer to the SA password skip the install, and every `ag-*.sh` step is idempotent. The AG phases run on whichever node is the AG primary right now, so a deploy also works after a failover. |
| `remove` | Asks what to remove (`-RemoveScope stack\|primary\|secondary`). **stack**: lists every object, then deletes the resource group, the ARM deployment record and the saved credentials. **primary / secondary**: deletes only that node's objects (see "Removing and rebuilding a node"). |
| `status` | Power state, region, zone and public IP of both VMs. |
| `status-ag` | On each running node: its AG role, the replicas (mode, connection, health), its databases' sync state, and on the primary, each database's state on every replica. Runs through `az vm run-command`. |
| `output` | SSH and SSMS connection strings, and where the credentials file is. |
| `refresh-access` | Detects this machine's current public IP and makes it the only source on the SSH (22) and SQL (1433) rules of the node NSGs **and** the subnet NSG. Nothing is redeployed. `-AllowedSourceIps` overrides the detected IP. |
| `failover` | **Planned failover without data loss** to the node that is secondary right now. Run it again to fail back (see below). |
| `force-failover` | **Forced failover** when the primary is lost: promotes the secondary with `FORCE_FAILOVER_ALLOW_DATA_LOSS`. |
| `reinstate` | After a forced failover: demotes the node that came back to SECONDARY and resumes replication. |

`status-ag`, `failover`, `force-failover`, `reinstate` and single-node `remove` all run through
`az vm run-command` (the Azure control plane). They need neither SSH nor port 1433, so they work
even where a policy blocks inbound internet traffic.

## Failover and failback

The SSMS failover wizard does not support `CLUSTER_TYPE = NONE`, and there's no cluster manager to
coordinate the replicas. The script runs Microsoft's T-SQL procedure across the two nodes.

### Planned failover (no data loss): `-Action failover`

```powershell
./sqlvm-linux-ag.ps1 -Action failover -Identifier 257672 -PrimaryNodeSuffix node-1 -SecondaryNodeSuffix node-2
```

It finds the current primary (P) and the target (T, the current secondary), then:

1. **Prepare** on P: makes sure both replicas are `SYNCHRONOUS_COMMIT` and sets
   `REQUIRED_SYNCHRONIZED_SECONDARIES_TO_COMMIT = 1`.
2. **Waits** until every AG database is `SYNCHRONIZED` on T (up to 10 minutes; if T doesn't get
   there, it cancels the failover and P stays primary).
3. **Offline** on P: `ALTER AVAILABILITY GROUP … OFFLINE` stops writes.
4. **Promote** T: `FORCE_FAILOVER_ALLOW_DATA_LOSS`. Despite its name, this loses nothing: T is
   synchronized and P is offline. If the promotion fails, P is brought back as primary.
5. **Demote** P: `SET (ROLE = SECONDARY)`, then `SET HADR RESUME` on both nodes.
6. Sets `REQUIRED_SYNCHRONIZED_SECONDARIES_TO_COMMIT` back to `0` and waits for P to be
   `SYNCHRONIZED` as the new secondary.

Writes stop for the few seconds of the role change. **Failback** is the same action run again:
it always fails over to whichever node is secondary at that moment.

### Forced failover (primary lost): `-Action force-failover`

Promotes the secondary with `FORCE_FAILOVER_ALLOW_DATA_LOSS`. Before you confirm, the script
lists any database on the target that isn't `SYNCHRONIZED`. Transactions not yet hardened there
are lost. With both replicas synchronous and the secondary healthy beforehand, that is normally
nothing.

- **The old primary is still reachable:** its AG is taken offline first. After the promotion it's
  demoted to SECONDARY and replication resumes.
- **The old primary is down (VM stopped, zone outage…):** when it comes back, its SQL Server may
  still consider itself PRIMARY. Run `reinstate`.

### Reinstate: `-Action reinstate`

```powershell
./sqlvm-linux-ag.ps1 -Action reinstate -Identifier 257672 -PrimaryNodeSuffix node-1 -SecondaryNodeSuffix node-2 -KeepPrimary node-2
```

Use it once both nodes are up again. It demotes the node that must not be primary and resumes
data movement on both. If both nodes claim the PRIMARY role, it asks which one stays (or takes
`-KeepPrimary <suffix>`). Changes made on the demoted node that never reached the other one are
discarded. If its databases still can't resume because the copies diverged, rebuild that node:
`remove -RemoveScope <primary|secondary>` and then `deploy` re-seeds it from the primary.

## Drills and dashboard

Two use cases rehearse the failovers with an application writing throughout. They run everything
through `az vm run-command`, record evidence and dashboard events, and finish with a static report.

| Use case | Scenario | Proves |
|---|---|---|
| [UC-01](use-cases/uc-01/README.md) | **Planned failover** to the node in the other zone (maintenance), and failback | No acknowledged transaction lost; write interruption of a few seconds, measured by the application; the old primary resynchronizes |
| [UC-02](use-cases/uc-02/README.md) | **Zone failure of the primary**: hard power-off, forced failover, reinstate behind a network fence, failback | RPO 0 thanks to synchronous commit; RTO measured from the application's side; no split-brain when the node comes back |

```powershell
./use-cases/uc-01/uc-01.ps1 -Action drill -Dashboard -Identifier 257672 -PrimaryNodeSuffix node-1 -SecondaryNodeSuffix node-2
./use-cases/uc-02/uc-02.ps1 -Action drill -Dashboard -DashboardMode both -Identifier 257672 -PrimaryNodeSuffix node-1 -SecondaryNodeSuffix node-2
./dashboard/dashboard.ps1 -UseCase uc-02 -Replay latest -Speed 5        # replay a recorded drill
```

**The application writer.** It runs on the secondary's VM and commits a ledger row every ~0.2 s to
whichever node accepts it: both private IPs are configured, and it switches on any error. Its log
gives the application's view: throughput, failed attempts, the exact write interruption, and every
acknowledged commit, which the ledger on the new primary must contain.

**The dashboard** ([dashboard/README.md](dashboard/README.md)) shows a run live or replays it, as
a web page (localhost) and/or in the terminal, in an executive or technical view:
- **Topology:** one column per availability zone; the failed zone turns red.
- **Status:** the running phase in plain language, the outage or interruption clock, RTO and lost
  transactions.
- **Charts:** live throughput, failed-attempt and replication-queue charts.
- **Outcome:** the success criteria.

It only reads the run's event log, so it never interferes with a drill.

## Removing and rebuilding a node

```powershell
./sqlvm-linux-ag.ps1 -Action remove -Identifier 257672 -PrimaryNodeSuffix node-1 -SecondaryNodeSuffix node-2 -RemoveScope secondary
```

This deletes the node's VM, NIC, public IP, NSG, and OS and data disks. The stack's VNet, subnet
NSG and availability set stay, and so does the other node. Before deleting, the script checks the
kept node through run-command:

- **The kept node is the AG primary:** the removed node's replica is first taken out of the AG
  (`ALTER AVAILABILITY GROUP … REMOVE REPLICA`).
- **The node being removed is the current AG primary:** the script warns you and suggests running
  `failover` first.

**Rebuilding.** Run `deploy` again with the same suffixes. **Either** node can be rebuilt, as
long as the node that's left is the AG primary (fail over first if needed). The script then:

1. Re-applies the template. The existing VM is updated in place, not recreated. The new VM
   goes into another zone (or the same availability set).
2. Installs SQL Server on the new node.
3. Replaces the old node's stored certificate with the new one (`ag-02` compares thumbprints).
4. Adds the replica back to the AG with its new IP (`ag-03`, run on the current primary).
5. Joins the new node, which gets the databases through automatic seeding.

## SSH/SQL access

On `deploy`, the script asks who may reach SSH (22) and SQL Server (1433):

```
Who may reach SSH (22) and SQL Server (1433) on the node public IPs?
  1) my-ip (default) - only this machine's current public IP (x.x.x.x/32) - recommended
  2) parameters-file - bicep/parameters.json (0.0.0.0/0)
  3) custom - enter IPs/CIDRs
```

To skip the question, pass `-AllowedSourceIps auto` (your current IP) or a list, e.g.
`-AllowedSourceIps 203.0.113.7,198.51.100.0/24`. With `-AutoApprove` and no list, the script uses
the value in `parameters.json`. If your IP changes later (home ISP, VPN), run `refresh-access`.

**Subnet NSG.** Traffic has to pass two NSGs: the subnet's and the NIC's. The template creates its
own subnet NSG, `…-subnet-nsg`, with the same `allow-ssh` / `allow-sqlserver` rules. Some
subscriptions run a policy that attaches a deny-all NSG to any subnet that has none. That NSG blocks
SSH/1433 even when the NIC NSG allows them, and owning the subnet NSG prevents it.
`refresh-access` updates all three NSGs.

## VNet address space

By default, the stack VNet gets the first `10.<n>.0.0/16` (n = 10, 20, … 250) that overlaps **no
VNet in the subscription**, so it can be peered with any other stack later. The VM subnet is its
second /24 (e.g. `10.30.1.0/24`). A VNet that already exists keeps its range. You can force a
range with `-VnetCidr` (/22 or larger).

## Other parameters

| Parameter | Default | Notes |
|---|---|---|
| `-Identifier` | asked | Unique identifier in every name, e.g. `257672`. `-Environment` also works as an alias |
| `-Prefix` | `sqlvm` | Part of every name |
| `-Location` | asked (`westus2`) | Region of both nodes (new stacks only) |
| `-VmSize` | asked (list of sizes available in the region) | Skips the list; still checked for restrictions and quota. Existing nodes keep their size |
| `-Placement` | auto (`zones` when the size has 2+ zones, else `availability-set`) | `zones`, `availability-set` or `none`; existing nodes keep theirs |
| `-RemoveScope` | asked | `stack`, `primary` or `secondary` (remove only) |
| `-VnetCidr` | auto (first free `10.<n>.0.0/16`) | /22 or larger |
| `-AllowedSourceIps` | asked | `auto`, IPs or CIDRs for SSH 22 and SQL 1433 |
| `-AgName` / `-DemoDbName` | `agsqlvm-<primary suffix>` / `AGDemoDB` | |
| `-KeepPrimary` | asked when needed | `reinstate`: suffix of the node that stays PRIMARY |
| `-SshKeyPath` / `-RhelZipPath` | `~/.ssh/id_rsa` / auto-detected | |
| `-SaPassword`, `-CertPassword`, `-AgLoginPassword` | saved or generated | Explicit values take priority |
| `-AutoApprove` | off | Skips the confirmation prompts. Required inputs still have to be passed as parameters. |

## Security notes

- `deploy` recommends limiting SSH/SQL to your current public IP. The `parameters.json` fallback
  is `0.0.0.0/0`, which is open to everyone. Keep the list tight, and use `refresh-access` when
  your IP changes.
- Port 5022 (the AG endpoint) accepts traffic only from inside the stack VNet.
- The generated passwords avoid characters that break shell quoting. They are stored in plain
  text in `state/` and in the `logs/` transcripts. Both folders are git-ignored, so keep them
  off shared drives.
- `CertPassword` encrypts the database master key and the exported private key.
  `AgLoginPassword` is only needed because `CREATE LOGIN` requires a password. The endpoint
  itself authenticates with certificates.

## Verifying the AG

`deploy` already runs `scripts/ag-07-verify.sh` as its last step, and `status-ag` shows the live
state. To check by hand:

```sql
SELECT ar.replica_server_name, ar.availability_mode_desc, ars.role_desc, ars.connected_state_desc, ars.synchronization_health_desc
FROM sys.dm_hadr_availability_replica_states ars
JOIN sys.availability_replicas ar ON ar.replica_id = ars.replica_id;

SELECT d.name, drs.synchronization_state_desc, drs.is_suspended
FROM sys.dm_hadr_database_replica_states drs
JOIN sys.databases d ON d.database_id = drs.database_id;
```

## Troubleshooting

- **SSH timeouts while waiting for the nodes.** Your public IP is almost certainly not in the
  NSG allow-list. Run `./sqlvm-linux-ag.ps1 -Action refresh-access ...`, then re-run `deploy`.
  Don't test ports with `nc` from behind a VPN or security proxy that accepts every connection;
  use `az network watcher test-ip-flow` instead.
- **A deploy fails partway.** Run the same command again. It reuses the saved credentials and
  existing VMs, and resumes from the step that failed.
- **"Resource group … wasn't created by this project".** Both projects build the resource group
  name the same way, so the same identifier + suffixes point at the same group. The script only
  manages groups tagged `project: sqlvm-ag-single-region`. Use another `-Identifier` (or other
  suffixes) for the single-region stack, or manage that stack from `sqlvm-linux-ao-ag-dag-01`.
- **Only one VM exists.** `deploy` rebuilds the missing node, as long as the remaining node is
  the AG primary. If it isn't, `deploy` stops and tells you to run `force-failover` first.
- **"No VM size passes the checks".** The region may be restricted for your subscription
  (`az vm list-skus -l <region> --all` shows `NotAvailableForSubscription`), or the vCPU quota is
  used up. Pick another region.
- **SSH blocked by subscription policy.** The `deploy` action's SQL phases (`install-sqlserver.sh`,
  `ag-01`..`ag-07`) use SSH/SCP, because the RPM has to be uploaded, so they fail while such a policy applies.
  Everything after the deploy (`status-ag`, failovers, `reinstate`, single-node `remove`) uses
  run-command and keeps working.
- To debug a single phase, copy the `scripts/ag-0N-*.sh` file to the node (or use
  `az vm run-command invoke`) and run it with the arguments shown in its header comment.

## Cost (per stack, PAYG, approximate)

Two VMs of the size you pick (e.g. `Standard_D4as_v7`, 4 vCPUs each), 2 × 128 GB + 2 × 256 GB
Premium SSD and two Standard public IPs. Replication traffic between zones in the same region may
be billed per GB, but there is no global peering egress. Stop costs with
`./sqlvm-linux-ag.ps1 -Action remove`.
