# Azure SQL VM — Standalone Deployment

Deploys a single standalone SQL Server IaaS VM in Azure: new VNet/subnet, NSG,
optional public IP, the SQL Server VM, and registration with the
`Microsoft.SqlVirtualMachine` resource provider (enables automated patching,
backup, and management from the Azure Portal's "SQL virtual machines" blade).

## Files

- [main.bicep](main.bicep) — the IaC template
- [deploy.ps1](deploy.ps1) — interactive deployment via PowerShell (pwsh) + Azure CLI
- [deploy.sh](deploy.sh) — interactive deployment via bash + Azure CLI

Both scripts ask the same questions and deploy the same template; use whichever
shell you prefer.

## Prerequisites

- [Azure CLI](https://learn.microsoft.com/cli/azure/install-azure-cli) installed and on `PATH`
- An Azure subscription with permission to create resource groups and resources
- (For `deploy.ps1`) PowerShell 7+ (`pwsh`)

## Usage

```bash
# bash
./deploy.sh
```

```powershell
# PowerShell
./deploy.ps1
```

You'll be prompted for:

- Subscription (defaults to your current `az` context)
- Resource group name and region (created if it doesn't exist)
- VM name (max 15 chars) and size
- Admin username/password
- SQL Server edition (standard/enterprise/developer/express) and license type (PAYG/AHUB)
- Whether to deploy a public IP
- Whether to allow inbound SQL (port 1433) traffic
- The source IP/CIDR allowed for RDP (and SQL, if enabled) — the script tries
  to detect your public IP as a default

The script then runs `az deployment group create` against [main.bicep](main.bicep)
and prints the deployment outputs (VM name, public IP if deployed).

## Notes

- The default image is SQL Server 2022 on Windows Server 2022
  (`MicrosoftSQLServer:sql2022-ws2022`).
- A second (empty) 256 GB Premium SSD data disk is attached for SQL data files.
- Restricting `allowedSourceIpAddress` to your own IP/CIDR is strongly
  recommended; avoid leaving it as `*` in any real environment.
- Deployment typically takes 15–30 minutes (VM provisioning + SQL IaaS agent
  extension installation).
