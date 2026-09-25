# Azure Database deployments

Infrastructure-as-code examples for deploying Azure Databases. This repository contains independent deployments; choose the guide that matches the scenario you want to try.

## Before you deploy

- Review the prerequisites and deployment options in the guide for your chosen example.
- You need an Azure subscription with permission to create the listed resources, plus Azure CLI. The Linux lab also requires PowerShell 7+, SSH tools, and SQL Server RPM files that are not included in this repository.
- Azure resources incur charges while they exist. Review the deployed resources and remove them when you are finished experimenting.
- Restrict inbound management and SQL access to trusted IP addresses. Do not expose credentials or private keys.

These templates deploy SQL Server on Azure virtual machines; they do not provision the Azure SQL Database or Azure SQL Managed Instance services.
