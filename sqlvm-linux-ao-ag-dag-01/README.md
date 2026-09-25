# sqlvm-ag — Cross-Region SQL Server Always On AG on RHEL 9 (Bicep, suffix-driven)

2-node SQL Server **Always On Availability Groups** on **RHEL 9** (SQL Server installed from a
**local RPM**), the **Distributed AGs** that link them, and failure **use cases**, all driven by
one interactive script: **`sqlvm-linux-ag.ps1`**. It asks for:

1. **What to do**, from a sectioned menu: **Deploy**, **Remove**, **Check**, **Operate**, or
   **Use cases** (see [The menu](#the-menu))
2. **Unique identifier** for the object names, for example `257672` (any 1–15 lowercase letters, digits or hyphens)
3. **Primary node suffix**, for example `node-1`
4. **Secondary node suffix**, for example `node-2`
5. **Primary region** and **secondary region** (only asked on `deploy` for a node that doesn't exist yet)
6. **VM size**, picked from a list of the sizes available in both regions (new stacks only)
7. **SSH/SQL access** on `deploy`: your current public IP (the default), `parameters.json`, or your own list
8. **What to remove** on `remove`: the whole stack, only the primary node, or only the secondary node

Every Azure object is named from the identifier and the suffixes, so each identifier + suffix
pair is an independent stack.
You can run `node-1`/`node-2` and `node-3`/`node-4` side by side in the same subscription, and
remove either one without touching the other.

## Architecture

```
   Region: <primary region>                               Region: <secondary region>
   RG: sqlvm-<id>-<pri>-<sec>-rg                        (same resource group)
  ┌──────────────────────────────┐   VNet peering      ┌──────────────────────────────┐
  │ sqlvm-<id>-<pri>-vnet       │◄───────────────────►│ sqlvm-<id>-<sec>-vnet       │
  │ 10.<n>.0.0/16 (auto-picked)  │                     │ 10.<m>.0.0/16 (auto-picked)  │
  │                              │                     │                              │
  │ sqlvm-<id>-<pri>-vm         │◄── AG TCP 5022 ────►│ sqlvm-<id>-<sec>-vm         │
  │ RHEL 9 + SQL Server          │                     │ RHEL 9 + SQL Server          │
  │ PRIMARY, SYNCHRONOUS_COMMIT  │                     │ SECONDARY (readable), ASYNC  │
  └──────────────────────────────┘                     └──────────────────────────────┘
```

- **`CLUSTER_TYPE = NONE`**: no Pacemaker, no WSFC. Failover is a deliberate manual action.
- **Certificate-based endpoint authentication**: the nodes are not domain-joined. `sqlvm-linux-ag.ps1`
  exchanges the certificates between the nodes.
- **Automatic seeding**: databases added on the primary are copied to the secondary by SQL Server.
- **SQL Server Developer edition**: dev/test licence only. Change `MSSQL_PID` in
  `scripts/install-sqlserver.sh` for production.
- The two regions may be the same. You then get a single-region pair with regional peering.

## Object naming

With prefix `sqlvm`, identifier `257672` (whatever you enter at the prompt) and suffixes
`node-1` / `node-2`:

| Object | Name |
|---|---|
| Resource group | `sqlvm-257672-node-1-node-2-rg` |
| VM / hostname / AG replica | `sqlvm-257672-node-1-vm` / `sqlvm-257672-node-1` |
| NIC, NSG, public IP | `sqlvm-257672-node-1-nic`, `-nsg`, `-pip` |
| VNet | `sqlvm-257672-node-1-vnet` (peering `to-node-2`) |
| Disks | `sqlvm-257672-node-1-osdisk`, `sqlvm-257672-node-1-sqldata` |
| Availability Group | `agsqlvm-node-1` (override with `-AgName`) |
| ARM deployment record | `sqlvm-257672-node-1-node-2` (subscription scope) |

The identifier is 1–15 characters: lowercase letters, digits and hyphens. It can't start or
end with a hyphen. Use the same identifier on every later run (`remove`, `status`, use cases…) to
reach the same stack.

A suffix is 1–20 characters: lowercase letters, digits and hyphens. It can't start or end with a
hyphen. The two suffixes must be different.

## Repo layout

```
sqlvm-linux-ao-ag-dag-01/
├── README.md
├── sqlvm-linux-ag.ps1      # entry point: menu with Deploy / Remove / Check / Operate / Use cases / Dashboard
├── bicep/
│   ├── main.bicep          # subscription scope: resource group + resources module
│   ├── resources.bicep     # the two nodes + VNet peering
│   ├── node.bicep          # one node: VNet, NSG, PIP, NIC, data disk, VM (used twice)
│   └── parameters.json     # shared settings: admin user, allowedSourceIps, disk size, tags
├── scripts/                # run on the VMs by sqlvm-linux-ag.ps1 (ag-*: over SSH; dag-*: through az vm run-command)
│   ├── install-sqlserver.sh
│   ├── ag-01-endpoint.sh               # both nodes: master key, certificate, HADR endpoint
│   ├── ag-02-trust-peer.sh             # both nodes: trust the peer's certificate
│   ├── ag-03-create-primary.sh         # primary: CREATE AVAILABILITY GROUP
│   ├── ag-04-join-secondary.sh         # secondary: JOIN
│   ├── ag-05-create-demo-db.sh         # primary: AGDemoDB added to the AG
│   ├── ag-06-restore-wideworldimporters.sh  # primary: WideWorldImporters added to the AG
│   ├── ag-07-verify.sh                 # primary: replica health + expected DBs present
│   ├── dag-01-export-cert.sh           # every node: print its endpoint certificate (base64)
│   ├── dag-02-clear-forwarder.sh       # forwarder primary: back up + remove + drop its AG databases
│   ├── dag-03-drop-orphan-dbs.sh       # forwarder nodes: drop leftover RESTORING copies
│   ├── dag-04-create.sh                # global primary: CREATE AVAILABILITY GROUP ... WITH (DISTRIBUTED)
│   ├── dag-05-join.sh                  # forwarder primary: JOIN the distributed AG
│   ├── dag-06-status.sh                # any node: local AG + distributed AG state
│   └── dag-07-drop.sh                  # global primary / forwarder: DROP the distributed AG
├── dashboard/              # live / replay dashboard of a use-case run (see dashboard/README.md)
│   ├── dashboard.ps1       # web server (localhost) + terminal view + replay
│   └── web/index.html      # the page (self-contained, works offline)
└── use-cases/              # failure drills and runbooks: uc-NN/uc-NN.ps1 + README, listed in the menu automatically
    ├── common/uc-events.ps1    # dashboard events every use case writes (phases, nodes, links, metrics)
    └── uc-01/                  # region failure of the primary node (+ dashboard.json)
```

Generated at runtime (git-ignored): `logs/` holds the transcripts, and `state/` holds the
credentials and a known_hosts file for each stack.

## Prerequisites

1. **PowerShell 7+** (`pwsh`). Works on macOS, Linux and Windows.
2. **Azure CLI**. On macOS run `brew install azure-cli`; on Windows run `winget install Microsoft.AzureCLI`.
   Bicep is installed automatically.
3. **ssh / scp** (built into macOS, Linux and Windows 10/11).
4. **SSH key pair** at `~/.ssh/id_rsa` (or pass `-SshKeyPath`):
   `ssh-keygen -t rsa -b 4096 -f ~/.ssh/id_rsa -N ""`
5. **`Rhel9.zip`** with the SQL Server RPMs. It is not in git. `sqlvm-linux-ag.ps1` looks for it next to
   `sqlvm-linux-ag.ps1`, then in `~/Downloads`. If it finds neither, it asks for the path. You can also
   pass `-RhelZipPath`. The zip needs at least `mssql-server-<version>-1.x86_64.rpm`; the
   `-ha-`, `-extensibility-` and `-polybase-` RPMs are ignored.
6. An Azure subscription with `Contributor` access.

## Quick start

```bash
az login
az account set --subscription "<name or id>"
cd sqlvm-linux-ao-ag-dag-01
pwsh ./sqlvm-linux-ag.ps1
```

Sample session (deploying a stack):

```
What do you want to do?
  1) Deploy     - stack (2-node AG), Distributed AG link
  2) Remove     - stack or one node, Distributed AG link
  3) Check      - stack status, connection info, Distributed AG status
  4) Operate    - refresh SSH/SQL access, failover to secondary
  5) Use cases  - failure drills and runbooks (1 available)
Select a section: 1

Deploy
  1) deploy                 Stack - 2-node AG in the regions you choose (create or resume)
  2) deploy-dag             Distributed AG - link two stacks (global primary -> forwarder)
  0) back
Select an option: 1
Unique identifier for the object names (e.g. 257672): 257672
Primary node objects suffix (e.g. node-1) [node-1]: node-1
Secondary node objects suffix (e.g. node-2) [node-2]: node-2
Primary node region [eastus]: eastus
Secondary node region [westus2]: westus2
=== Checking VM sizes available in eastus and westus2 ===
  Reading VM sizes offered in eastus (can take up to a minute) ...
  eastus : 315 usable size(s)
  Reading VM sizes offered in westus2 (can take up to a minute) ...
  westus2 : 604 usable size(s)
245 VM sizes are available in both regions. Filter by text (e.g. D4, E8s, v5) or press Enter to list all: D4
     #  Size                            vCPUs   Memory GB    vCPUs free*
     ...
     5  Standard_D4ads_v7                   4          16             88
     6  Standard_D4as_v7                    4          16             88
     ...
Select a number or type a size name, 'f' to filter again [Standard_D4as_v7]: 6
VM size          : Standard_D4as_v7
Who may reach SSH (22) and SQL Server (1433) on the node public IPs?
  1) my-ip (default) - only this machine's current public IP (x.x.x.x/32) - recommended
  ...
=== Choosing VNet address spaces ===
  Primary VNet   : 10.10.0.0/16
  Secondary VNet : 10.20.0.0/16
...
```

Every prompt can also be passed as a parameter. Nothing is asked for a parameter you pass:

```powershell
./sqlvm-linux-ag.ps1 -Action deploy -Identifier 257672 -PrimaryNodeSuffix node-1 -SecondaryNodeSuffix node-2 `
             -PrimaryLocation eastus -SecondaryLocation westus2 -VmSize Standard_D4as_v7 -AllowedSourceIps auto

./sqlvm-linux-ag.ps1 -Action remove -Identifier 257672 -PrimaryNodeSuffix node-1 -SecondaryNodeSuffix node-2 -RemoveScope stack
./sqlvm-linux-ag.ps1 -Action remove -Identifier 257672 -PrimaryNodeSuffix node-1 -SecondaryNodeSuffix node-2 -RemoveScope secondary
./sqlvm-linux-ag.ps1 -Action remove -Identifier 257672 -PrimaryNodeSuffix node-1 -SecondaryNodeSuffix node-2 -RemoveScope stack -AutoApprove   # no confirmation
```

A full deploy takes about 15–20 minutes. The credentials are printed before any remote work starts.
They are also saved to `state/<resource-group>.credentials.json`, so a rerun reuses them.

### Choosing the VM size

For a new stack, the script reads the VM sizes offered in each region you chose and lists only the
sizes that work in **both** regions. The lookup takes 30–60 seconds per region. A size is listed
when all of these hold:

- It isn't restricted for your subscription in that region. Zone-only restrictions are ignored
  because no zone is pinned.
- It fits this deployment: x64 (the SQL Server RPM is x86_64), Hyper-V Gen2 (the RHEL 9 image is
  gen2), Premium SSD support, at least 2 vCPUs and at least 8 GB RAM.
- There's enough free vCPU quota for both its **VM family** and the **total regional vCPUs**. The
  check counts 2 VMs when both nodes share a region.

You can filter the list by text (`D4`, `E8s`, `v7`, …) and then pick a number or type a size name.
Type `f` to filter again, or press Enter to take the suggested `Standard_D4as_v7` when it's shown.
The *vCPUs free* column shows the smallest free quota across the regions. If no size qualifies
(usually because quota is 0), the script asks for another region pair.

**Other cases:**
- **`-VmSize` given:** the list is skipped. The size is checked in each region, and if a region
  fails, the script asks you for a different region. It never switches region on its own. You can
  also type `force` to deploy anyway, or `quit` to stop.
- **`-AutoApprove` without `-VmSize`:** uses `Standard_D4as_v7`. If it isn't deployable, the
  script stops.
- **Existing stack:** the script skips the region and size questions and uses the existing VMs'
  regions and size.
- **Rebuilt secondary:** always uses the primary's current size, so the redeploy doesn't resize the
  primary. The size is checked in the region you give for the secondary.

## The menu

Run `pwsh ./sqlvm-linux-ag.ps1` with no `-Action` / `-UseCase`. Pick a section, then an option
(`0` goes back):

| Section | Options (`-Action` name) |
|---|---|
| **1) Deploy** | Stack (`deploy`), Distributed AG link (`deploy-dag`) |
| **2) Remove** | Stack or one node (`remove`), Distributed AG link (`remove-dag`) |
| **3) Check** | Stack status (`status`), connection info (`output`), Distributed AG status (`status-dag`) |
| **4) Operate** | Refresh SSH/SQL access (`refresh-access`), failover to secondary (`failover-to-secondary`) |
| **5) Use cases** | Every `use-cases/uc-NN/` folder with a `uc-NN.ps1`, titled from its README's first line |
| **6) Dashboard** | Live progress or replay of a use-case run, as a web page and/or in the terminal (`dashboard`) |

**Use cases.** The identifier is asked once here and passed on. The use case then asks for
everything else (its action, node suffixes, forwarders) with its own scenario-specific prompts.
`-PrimaryNodeSuffix`, `-SecondaryNodeSuffix`, `-Prefix`, `-AgName` and `-AutoApprove` are passed
through when you give them on the command line. To run one directly:

```powershell
./sqlvm-linux-ag.ps1 -UseCase uc-01 -UseCaseAction status -Identifier 257672   # or -UseCase 1
./use-cases/uc-01/uc-01.ps1 -Action status -Identifier 257672 ...              # same thing, called directly
```

A new use case appears in the menu as soon as its folder exists: `use-cases/uc-02/uc-02.ps1`,
plus a `README.md` whose first line is its title. `uc-02.ps1` should accept `-Action` and
`-Identifier` (and `-AutoApprove` if it confirms anything). To show it on the dashboard, add a
`dashboard.json` and write events (see [dashboard/README.md](dashboard/README.md#adding-a-use-case-to-the-dashboard)).

**Dashboard.** It shows a use-case run for presentations: topology, the running phase in plain
language, the outage clock, RTO/RPO and the success criteria. It can show a run live or replay a
recorded one at any speed, as a web page (localhost) and/or in the terminal, in an executive or
technical view. It only reads the run's event log, so it never interferes with a drill. See
[dashboard/README.md](dashboard/README.md).

```powershell
./sqlvm-linux-ag.ps1 -Action dashboard                                           # asks for everything
./dashboard/dashboard.ps1 -UseCase uc-01 -Replay latest -Speed 5 -Mode both      # replay, web + terminal
./use-cases/uc-01/uc-01.ps1 -Action drill -Dashboard ...                         # live, opened for the drill
```

**Scripting.** Every option is also an `-Action`, so nothing is asked for a value you pass.

## Actions

| Action | What it does |
|---|---|
| `deploy` | Creates the resource group, both nodes and the peering. Installs SQL Server, builds the AG, adds `AGDemoDB` and `WideWorldImporters`, then verifies. Safe to re-run: existing healthy VMs skip Bicep, nodes that already answer to the SA password skip the install, and every `ag-*.sh` step is idempotent. |
| `remove` | Asks what to remove (`-RemoveScope stack\|primary\|secondary`). **stack**: lists every object, then deletes the resource group, the ARM deployment record and the saved credentials. **primary / secondary**: deletes only that node's objects (see "Removing a single node"). If the group doesn't exist, it lists the other `sqlvm-*` stacks so you can check your suffixes. |
| `status` | Shows the power state, region and public IP of both VMs. |
| `refresh-access` | Detects this machine's current public IP and sets it as the only source on the SSH (22) and SQL (1433) rules of both NSGs. Nothing is redeployed. `-AllowedSourceIps` overrides the detected IP. |
| `output` | Shows the SSH and SSMS connection strings and where the credentials file is. |
| `failover-to-secondary` | Runs `FORCE_FAILOVER_ALLOW_DATA_LOSS` on the secondary. It uses the saved SA password, or `-SaPassword`. |
| `deploy-dag` | Links two stacks with a **Distributed AG** (see below). |
| `status-dag` | Local AG + Distributed AG state of all four nodes. |
| `remove-dag` | Drops the Distributed AG; both AGs keep running. |

## Removing a single node

```powershell
./sqlvm-linux-ag.ps1 -Action remove -Identifier 257672 -PrimaryNodeSuffix node-1 -SecondaryNodeSuffix node-2 -RemoveScope secondary
```

This deletes the node's VM, NIC, public IP, NSG, OS and data disks, and its
VNet. It also deletes the other VNet's peering to it. The other node is not touched. Before
deleting, the script connects to the node that stays, using the saved SA password:

- **The kept node is the AG primary:** the removed node's replica is first taken out of the AG
  (`ALTER AVAILABILITY GROUP ... REMOVE REPLICA`), so the primary keeps running cleanly.
- **The node being removed is the current AG primary** (after a failover): the script warns you and
  shows the `FORCE_FAILOVER_ALLOW_DATA_LOSS` command to run on the kept node first.

**Rebuilding a removed secondary.** Run `deploy` again with the same suffixes. The script sees
that only the primary exists and asks for the secondary's region, which can differ from before.
It then:

1. Re-applies the template. The primary VM is updated in place, not recreated.
2. Installs SQL Server on the new node.
3. Replaces the old node's stored certificate with the new one (`ag-02` compares thumbprints).
4. Adds the replica back to the AG with its new IP (`ag-03`).
5. Joins the new node, which gets the databases through automatic seeding.

**A removed primary can't be rebuilt in place,** because the AG then lives only on the secondary.
`deploy` stops and explains your options. You can keep the secondary as a standalone server, or
remove the whole stack.

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
the value in `parameters.json`. On an existing stack, the choice is applied straight to the NSG
rules. If your IP changes later (home ISP, VPN), run:

```powershell
./sqlvm-linux-ag.ps1 -Action refresh-access -Identifier 257672 -PrimaryNodeSuffix node-1 -SecondaryNodeSuffix node-2
```

## VNet address spaces

By default each new VNet gets the first `10.<n>.0.0/16` (n = 10, 20, … 250) that overlaps **no
VNet in the subscription**. Any two stacks can therefore be peered later, for example for a
Distributed AG between the `node-1/node-2` AG and the `node-3/node-4` AG:

| Deployed in this order | Primary VNet | Secondary VNet |
|---|---|---|
| `node-1` / `node-2` | 10.10.0.0/16 | 10.20.0.0/16 |
| `node-3` / `node-4` | 10.30.0.0/16 | 10.40.0.0/16 |

A VNet that already exists keeps its range. You can still force a range with
`-PrimaryVnetCidr` / `-SecondaryVnetCidr` (/22 or larger). The script warns you if the range
overlaps an existing VNet. It only checks VNets in the current subscription.

## Distributed AG (linking two stacks)

A Distributed AG replicates the databases of one stack's AG (the **global primary**) to another
stack's AG (the **forwarder**), which then passes them on to its own secondary:

```
  AG1 agsqlvm-node-1 (global primary)                 AG2 agsqlvm-node-3 (forwarder)
  ┌──────────────────────────────────┐   dagsqlvm-    ┌──────────────────────────────────┐
  │ node-1 eastus  PRIMARY ──────────┼── node-1- ───►│ node-3 eastus  PRIMARY (forwarder) │
  │    │ async                       │   node-3       │    │ async                        │
  │    ▼                             │   (async)      │    ▼                              │
  │ node-2 westus2 SECONDARY         │                │ node-4 eastus  SECONDARY          │
  └──────────────────────────────────┘                └──────────────────────────────────┘
```

```powershell
./sqlvm-linux-ag.ps1 -Action deploy-dag -Identifier ag01 -PrimaryNodeSuffix node-1 -SecondaryNodeSuffix node-2 `
             -DagForwarderIdentifier ag02 -DagForwarderPrimarySuffix node-3 -DagForwarderSecondarySuffix node-4
./sqlvm-linux-ag.ps1 -Action status-dag -Identifier ag01 -PrimaryNodeSuffix node-1 -SecondaryNodeSuffix node-2 `
             -DagForwarderIdentifier ag02 -DagForwarderPrimarySuffix node-3 -DagForwarderSecondarySuffix node-4
```

`-PrimaryNodeSuffix` / `-SecondaryNodeSuffix` name the global primary's stack; the two
`-DagForwarder*` parameters name the forwarder's stack (asked for when not passed). Each stack
keeps the identifier it was deployed with: `-Identifier` is the global primary's,
`-DagForwarderIdentifier` the forwarder's (defaults to `-Identifier`). The two AGs need different
names, so the forwarder's primary suffix must differ from the global primary's. The Distributed AG is named
`dagsqlvm-<global primary suffix>-<forwarder primary suffix>` (override with `-DagName`).

`deploy-dag` runs everything through `az vm run-command`, so it doesn't need SSH or port 1433,
and it's idempotent. Its steps:

1. **Networking.** Peers every node VNet of one stack with every node VNet of the other (four
   peerings each way). It also adds an NSG rule `allow-ag-endpoint-from-dag-<other stack's primary
   suffix>` (5022 from the other stack's VNets) on all four nodes, at the first free priority from
   130. Any node can hold the global primary or forwarder role after
   a local failover, so all four pairings are needed. VNet ranges must not overlap; the automatic
   ranges already guarantee this.
2. **Certificate trust.** Each node trusts the endpoint certificates of both nodes in the other
   stack (login, certificate and `CONNECT` on the endpoint).
3. **Empty the forwarder.** The forwarder AG must have no databases, because they're seeded from
   the global primary. Its current databases are backed up (`COPY_ONLY`, to
   `/var/opt/mssql/backup/pre-dag-<db>.bak` on the forwarder primary; skip with
   `-SkipForwarderBackup`), removed from the AG and dropped on both forwarder nodes. The script
   asks for confirmation first.
4. **Create and join.** Creates the Distributed AG on the global primary and joins it on the
   forwarder (asynchronous, manual failover, automatic seeding).
5. **Seeding.** Waits until the forwarder is SYNCHRONIZING and its secondary has the databases,
   then prints the state of all four nodes.

**No listener.** With `CLUSTER_TYPE = NONE`, each member AG's `LISTENER_URL` is the endpoint of
its current primary replica (Microsoft's guidance for AGs without a cluster manager). After any
local failover inside a member AG, update that URL on **both** the global primary and the
forwarder:

```sql
ALTER AVAILABILITY GROUP [dagsqlvm-node-1-node-3]
    MODIFY AVAILABILITY GROUP ON N'agsqlvm-node-1' WITH (LISTENER_URL = N'tcp://<new primary IP>:5022');
```

The use-case scripts (`use-cases/uc-01`) do this automatically.

**Removing it.** `remove-dag` drops the Distributed AG on the forwarder, then on the global
primary. The forwarder's copies of the databases stay behind in RESTORING state; run
`deploy-dag` again to re-link and re-seed. Peering, NSG rules and certificate trust are left in
place.

**Several forwarders.** An AG can be the global primary of several Distributed AGs, one per
forwarder AG. Run `deploy-dag` once per forwarder stack with the same global primary suffixes:

```powershell
./sqlvm-linux-ag.ps1 -Action deploy-dag -Identifier ag01 -PrimaryNodeSuffix node-1 -SecondaryNodeSuffix node-2 `
             -DagForwarderIdentifier ag02 -DagForwarderPrimarySuffix node-3 -DagForwarderSecondarySuffix node-4   # dagsqlvm-node-1-node-3
./sqlvm-linux-ag.ps1 -Action deploy-dag -Identifier ag01 -PrimaryNodeSuffix node-1 -SecondaryNodeSuffix node-2 `
             -DagForwarderIdentifier ag03 -DagForwarderPrimarySuffix node-5 -DagForwarderSecondarySuffix node-6   # dagsqlvm-node-1-node-5
```

Each link gets its own peerings, NSG rule and certificate trust, so adding one never changes
another. Forwarders aren't linked to each other. The use-case scripts take every forwarder with
`-Forwarders ag02:node-3:node-4,ag03:node-5:node-6` (`<identifier>:<primary>:<secondary>`; the
identifier can be left out when the stack uses the same one as AG1).

**Redeploying a stack.** If Bicep is re-applied to a stack (e.g. rebuilding a removed secondary),
check `status-dag` afterwards. Re-run `deploy-dag` if any cross-stack peering or NSG rule is missing.

## Other parameters

| Parameter | Default | Notes |
|---|---|---|
| `-Identifier` | asked | Unique identifier in every name, e.g. `257672`. `-Environment` also works as an alias |
| `-Prefix` | `sqlvm` | Part of every name |
| `-VmSize` | asked (list of sizes available in both regions) | Skips the list; still checked for restrictions and quota. Existing nodes keep their size |
| `-RemoveScope` | asked | `stack`, `primary` or `secondary` (remove only) |
| `-PrimaryVnetCidr` / `-SecondaryVnetCidr` | auto (first free `10.<n>.0.0/16`) | /22 or larger. VM subnet = 2nd /24 (e.g. `10.30.1.0/24`) |
| `-AllowedSourceIps` | asked | `auto`, IPs or CIDRs for SSH 22 and SQL 1433 |
| `-AgName` / `-DemoDbName` | `agsqlvm-<primary suffix>` / `AGDemoDB` | |
| `-SshKeyPath` / `-RhelZipPath` | `~/.ssh/id_rsa` / auto-detected | |
| `-SaPassword`, `-CertPassword`, `-AgLoginPassword` | saved or generated | Explicit values take priority |
| `-DagForwarderPrimarySuffix` / `-DagForwarderSecondarySuffix` | asked (DAG actions) | The forwarder stack's node suffixes |
| `-DagName` | `dagsqlvm-<primary>-<forwarder primary>` | Distributed AG name |
| `-SkipForwarderBackup` | off | `deploy-dag` drops the forwarder's databases without backing them up first |
| `-AutoApprove` | off | Skips the confirmation prompts. Required inputs still have to be passed as parameters. |

## Security notes

- `deploy` recommends limiting SSH/SQL to your current public IP. The `parameters.json` fallback
  is `0.0.0.0/0`, which is open to everyone. Keep the list tight, and use `refresh-access` when
  your IP changes.
- Port 5022 (the AG endpoint) accepts traffic only from the peer VNet, plus the other stack's
  VNets once a Distributed AG links them (`allow-ag-endpoint-from-dag-<stack>`, one rule per link).
- The generated passwords avoid characters that break shell quoting. They are stored in plain
  text in `state/` and in the `logs/` transcripts. Both folders are git-ignored, so keep them
  off shared drives.
- `CertPassword` encrypts the database master key and the exported private key.
  `AgLoginPassword` is only needed because `CREATE LOGIN` requires a password. The endpoint
  itself authenticates with certificates.

## Verifying the AG

`deploy` already runs `scripts/ag-07-verify.sh` as its last step. To check by hand:

```sql
SELECT ar.replica_server_name, ars.role_desc, ars.connected_state_desc, ars.synchronization_health_desc
FROM sys.dm_hadr_availability_replica_states ars
JOIN sys.availability_replicas ar ON ar.replica_id = ars.replica_id;

SELECT d.name, drs.synchronization_state_desc, drs.is_suspended
FROM sys.dm_hadr_database_replica_states drs
JOIN sys.databases d ON d.database_id = drs.database_id;
```

## Failover and failback

The SSMS failover wizard does not support `CLUSTER_TYPE = NONE`. Use T-SQL on the replica that
is **becoming** primary:

```sql
ALTER AVAILABILITY GROUP [agsqlvm-node-1] FORCE_FAILOVER_ALLOW_DATA_LOSS;
```

`./sqlvm-linux-ag.ps1 -Action failover-to-secondary` runs this command on the secondary. To fail back,
run the same statement on the original primary. The pair is asynchronous in both directions, so
data loss is possible either way.

If a database shows `NOT SYNCHRONIZING` / `SUSPEND_FROM_PARTNER` after repeated failovers, run
this on the current secondary:

```sql
ALTER DATABASE [AGDemoDB] SET HADR RESUME;
ALTER DATABASE [WideWorldImporters] SET HADR RESUME;
```

## Troubleshooting

- **SSH timeouts while waiting for the nodes.** Your public IP is almost certainly not in the
  NSG allow-list. Run `./sqlvm-linux-ag.ps1 -Action refresh-access ...`, then re-run `deploy`.
- **A deploy fails partway.** Run the same command again. It reuses the saved credentials and
  existing VMs, and resumes from the step that failed.
- **Only one VM exists.** If it's the primary, `deploy` rebuilds the secondary and adds it back
  to the AG. If it's the secondary, `deploy` stops and explains the options.
- **SSH blocked by subscription policy.** In this subscription, an Azure policy removes the
  `allow-ssh` NSG rules and attaches subnet NSGs that deny inbound internet traffic. The
  `deploy` action's SQL phases (`install-sqlserver.sh`, `ag-*.sh`) use SSH/SCP and fail while
  that policy applies. Run the phases through `az vm run-command` instead. The DAG
  actions and the use-case scripts already use run-command.
- To debug a single phase, copy the `scripts/ag-0N-*.sh` / `dag-0N-*.sh` file to the node (or
  use `az vm run-command invoke`) and run it with the arguments shown in its header comment.

## Cost (per stack, PAYG, approximate)

Two VMs of the size you pick (e.g. `Standard_D4as_v7`, 4 vCPUs each), 2 × 128 GB + 2 × 256 GB Premium SSD, two Standard public IPs, and global
peering egress billed per GB. Stop costs with `./sqlvm-linux-ag.ps1 -Action remove`.
