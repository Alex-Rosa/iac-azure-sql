# sqlvm-ag — Cross-Region SQL Server Always On AG on RHEL 9 (Bicep, suffix-driven)

A 2-node SQL Server **Always On Availability Group** on **RHEL 9**, SQL Server installed from a
**local RPM**, deployed by one interactive script. It asks for:

1. **Action**: `deploy` / `remove` (also `status`, `output`, `refresh-access`, `failover-to-secondary`)
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
- **Certificate-based endpoint authentication**: the nodes are not domain-joined. `deploy.ps1`
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
| Bastion (optional) | `sqlvm-257672-node-1-bastion`, `-bastion-pip` |
| Availability Group | `agsqlvm-node-1` (override with `-AgName`) |
| ARM deployment record | `sqlvm-257672-node-1-node-2` (subscription scope) |

The identifier is 1–15 characters: lowercase letters, digits and hyphens. It can't start or
end with a hyphen. Use the same identifier on every later run (`remove`, `status`, Bastion…) to
reach the same stack.

A suffix is 1–20 characters: lowercase letters, digits and hyphens. It can't start or end with a
hyphen. The two suffixes must be different.

## Repo layout

```
sqlvm-linux-ao-ag-dag/
├── README.md
├── deploy.ps1              # interactive entry point: deploy / remove / status / output / refresh-access / failover
├── deploy-bastion.ps1      # optional Bastion: deploy / remove / tunnel-sql / ssh / status
├── bicep/
│   ├── main.bicep          # subscription scope: resource group + resources module
│   ├── resources.bicep     # the two nodes + VNet peering
│   ├── node.bicep          # one node: VNet, NSG, PIP, NIC, data disk, VM (used twice)
│   ├── bastion.bicep       # optional Bastion per node VNet
│   └── parameters.json     # shared settings: admin user, allowedSourceIps, disk size, tags
└── scripts/                # run on the VMs over SSH, in order, by deploy.ps1
    ├── install-sqlserver.sh
    ├── ag-01-endpoint.sh               # both nodes: master key, certificate, HADR endpoint
    ├── ag-02-trust-peer.sh             # both nodes: trust the peer's certificate
    ├── ag-03-create-primary.sh         # primary: CREATE AVAILABILITY GROUP
    ├── ag-04-join-secondary.sh         # secondary: JOIN
    ├── ag-05-create-demo-db.sh         # primary: AGDemoDB added to the AG
    ├── ag-06-restore-wideworldimporters.sh  # primary: WideWorldImporters added to the AG
    └── ag-07-verify.sh                 # primary: replica health + expected DBs present
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
5. **`Rhel9.zip`** with the SQL Server RPMs. It is not in git. `deploy.ps1` looks for it next to
   `deploy.ps1`, then in `~/Downloads`. If it finds neither, it asks for the path. You can also
   pass `-RhelZipPath`. The zip needs at least `mssql-server-<version>-1.x86_64.rpm`; the
   `-ha-`, `-extensibility-` and `-polybase-` RPMs are ignored.
6. An Azure subscription with `Contributor` access.

## Quick start

```bash
az login
az account set --subscription "<name or id>"
cd sqlvm-linux-ao-ag-dag
pwsh ./deploy.ps1
```

Sample session:

```
What do you want to do?
  1) deploy (default) - create or resume a stack
  2) remove - delete a whole stack or one node
  3) status - VM power state
  4) output - connection info
  5) refresh-access - allow your current IP on SSH/SQL
  6) failover-to-secondary - force failover to the secondary
Select a number or type the value: 1
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
./deploy.ps1 -Action deploy -Identifier 257672 -PrimaryNodeSuffix node-1 -SecondaryNodeSuffix node-2 `
             -PrimaryLocation eastus -SecondaryLocation westus2 -VmSize Standard_D4as_v7 -AllowedSourceIps auto

./deploy.ps1 -Action remove -Identifier 257672 -PrimaryNodeSuffix node-1 -SecondaryNodeSuffix node-2 -RemoveScope stack
./deploy.ps1 -Action remove -Identifier 257672 -PrimaryNodeSuffix node-1 -SecondaryNodeSuffix node-2 -RemoveScope secondary
./deploy.ps1 -Action remove -Identifier 257672 -PrimaryNodeSuffix node-1 -SecondaryNodeSuffix node-2 -RemoveScope stack -AutoApprove   # no confirmation
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

## Actions

| Action | What it does |
|---|---|
| `deploy` | Creates the resource group, both nodes and the peering. Installs SQL Server, builds the AG, adds `AGDemoDB` and `WideWorldImporters`, then verifies. Safe to re-run: existing healthy VMs skip Bicep, nodes that already answer to the SA password skip the install, and every `ag-*.sh` step is idempotent. |
| `remove` | Asks what to remove (`-RemoveScope stack\|primary\|secondary`). **stack**: lists every object, then deletes the resource group, the ARM deployment record and the saved credentials. **primary / secondary**: deletes only that node's objects (see "Removing a single node"). If the group doesn't exist, it lists the other `sqlvm-*` stacks so you can check your suffixes. |
| `status` | Shows the power state, region and public IP of both VMs. |
| `refresh-access` | Detects this machine's current public IP and sets it as the only source on the SSH (22) and SQL (1433) rules of both NSGs. Nothing is redeployed. `-AllowedSourceIps` overrides the detected IP. |
| `output` | Shows the SSH and SSMS connection strings and where the credentials file is. |
| `failover-to-secondary` | Runs `FORCE_FAILOVER_ALLOW_DATA_LOSS` on the secondary. It uses the saved SA password, or `-SaPassword`. |

## Removing a single node

```powershell
./deploy.ps1 -Action remove -Identifier 257672 -PrimaryNodeSuffix node-1 -SecondaryNodeSuffix node-2 -RemoveScope secondary
```

This deletes the node's VM, NIC, public IP, NSG, OS and data disks, its Bastion (if any) and its
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
./deploy.ps1 -Action refresh-access -Identifier 257672 -PrimaryNodeSuffix node-1 -SecondaryNodeSuffix node-2
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

## Other parameters

| Parameter | Default | Notes |
|---|---|---|
| `-Identifier` | asked | Unique identifier in every name, e.g. `257672`. `-Environment` also works as an alias |
| `-Prefix` | `sqlvm` | Part of every name |
| `-VmSize` | asked (list of sizes available in both regions) | Skips the list; still checked for restrictions and quota. Existing nodes keep their size |
| `-RemoveScope` | asked | `stack`, `primary` or `secondary` (remove only) |
| `-PrimaryVnetCidr` / `-SecondaryVnetCidr` | auto (first free `10.<n>.0.0/16`) | /22 or larger. VM subnet = 2nd /24, Bastion = 9th /26 (e.g. `10.30.1.0/24`, `10.30.2.0/26`) |
| `-AllowedSourceIps` | asked | `auto`, IPs or CIDRs for SSH 22 and SQL 1433 |
| `-AgName` / `-DemoDbName` | `agsqlvm-<primary suffix>` / `AGDemoDB` | |
| `-SshKeyPath` / `-RhelZipPath` | `~/.ssh/id_rsa` / auto-detected | |
| `-SaPassword`, `-CertPassword`, `-AgLoginPassword` | saved or generated | Explicit values take priority |
| `-AutoApprove` | off | Skips the confirmation prompts. Required inputs still have to be passed as parameters. |

## Security notes

- `deploy` recommends limiting SSH/SQL to your current public IP. The `parameters.json` fallback
  is `0.0.0.0/0`, which is open to everyone. Keep the list tight, and use `refresh-access` when
  your IP changes.
- Port 5022 (the AG endpoint) accepts traffic only from the peer VNet.
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

`./deploy.ps1 -Action failover-to-secondary` runs this command on the secondary. To fail back,
run the same statement on the original primary. The pair is asynchronous in both directions, so
data loss is possible either way.

If a database shows `NOT SYNCHRONIZING` / `SUSPEND_FROM_PARTNER` after repeated failovers, run
this on the current secondary:

```sql
ALTER DATABASE [AGDemoDB] SET HADR RESUME;
ALTER DATABASE [WideWorldImporters] SET HADR RESUME;
```

## Optional: Azure Bastion

Use Bastion when direct SSH or SQL access fails because your source IP changes (VPN, corporate
egress). It deploys one Standard-SKU Bastion into each node's VNet. The script reads the regions
and address spaces from the live VNets, so the only inputs are the action and the suffixes.

```powershell
./deploy-bastion.ps1                                   # interactive
./deploy-bastion.ps1 -Action deploy -Identifier 257672 -PrimaryNodeSuffix node-1 -SecondaryNodeSuffix node-2

# SSMS tunnels (leave each window open); connect SSMS to 127.0.0.1,11433 / 127.0.0.1,12433
./deploy-bastion.ps1 -Action tunnel-sql -Identifier 257672 -PrimaryNodeSuffix node-1 -SecondaryNodeSuffix node-2 -Node primary   -LocalPort 11433
./deploy-bastion.ps1 -Action tunnel-sql -Identifier 257672 -PrimaryNodeSuffix node-1 -SecondaryNodeSuffix node-2 -Node secondary -LocalPort 12433

# SSH through Bastion
./deploy-bastion.ps1 -Action ssh -Identifier 257672 -PrimaryNodeSuffix node-1 -SecondaryNodeSuffix node-2 -Node primary

# Remove only the Bastion hosts, their PIPs and subnets (VMs/AG untouched)
./deploy-bastion.ps1 -Action remove -Identifier 257672 -PrimaryNodeSuffix node-1 -SecondaryNodeSuffix node-2
```

Standard Bastion bills continuously while it is deployed, and this setup runs two of them.
`deploy.ps1 -Action remove` also deletes the Bastion hosts along with the resource group.

## Troubleshooting

- **SSH timeouts while waiting for the nodes.** Your public IP is almost certainly not in the
  NSG allow-list. Run `./deploy.ps1 -Action refresh-access ...`, then re-run `deploy`. If your
  IP keeps changing, use Bastion.
- **A deploy fails partway.** Run the same command again. It reuses the saved credentials and
  existing VMs, and resumes from the step that failed.
- **Only one VM exists.** If it's the primary, `deploy` rebuilds the secondary and adds it back
  to the AG. If it's the secondary, `deploy` stops and explains the options.
- To debug a single phase, `scp` the `scripts/ag-0N-*.sh` file to the node and run it with the
  arguments shown in its header comment.

## Cost (per stack, PAYG, approximate)

Two VMs of the size you pick (e.g. `Standard_D4as_v7`, 4 vCPUs each), 2 × 128 GB + 2 × 256 GB Premium SSD, two Standard public IPs, and global
peering egress billed per GB. Stop costs with `./deploy.ps1 -Action remove`.
