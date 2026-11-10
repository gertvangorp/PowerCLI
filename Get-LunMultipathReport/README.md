# Get-LunMultipathReport

Lists every LUN of one or more ESXi hosts with its multipath details, so you can check that all LUNs of an array use the right path selection policy and have all their paths. It combines `Get-ScsiLun` with `esxcli storage core device list`, `storage core path list`, `storage nmp device list` and `storage hpp device list`, so devices claimed by NMP (typically SAN LUNs) and by HPP (local NVMe, SAS and SATA by default since ESXi 7, so most vSAN disks) both show up.

Per LUN: display name, canonical name, type, capacity, multipath plugin (`NMP` or `HPP`), multipath policy, path selection policy (PSP for NMP, path selection scheme for HPP) and its config, storage array type (SATP, NMP only) and its config, total and active paths, and whether the device is local, USB or the boot device.

The script only reads. It changes nothing.

## Requirements

- PowerShell 7 or Windows PowerShell 5.1
- `Install-Module VCF.PowerCLI -Scope CurrentUser` (VMware.PowerCLI also works)
- Network access to vCenter
- A vCenter account with read access to the hosts

## Parameters

| Parameter | Required | Description |
|---|---|---|
| `-VCenter` | Yes, or in the config file | vCenter FQDN |
| `-VMHost` | Yes, or in the config file | ESXi host names as known in vCenter. Wildcards work (`esx0*`) |
| `-CsvPath` | No | Also export to CSV. `{date}` becomes `yyyyMMdd-HHmm` |
| `-Credential` | No | vCenter account. Config: `VcUser` / `VcCredentialFile` |
| `-Environment` | No | Environment config name: reads `config\<name>.config.json` |
| `-ConfigFile` | No | Path to an environment config file |
| `-UseSddcCredentials` | No | Read the password from the SDDC Manager vault |
| `-SddcManager` | With `-UseSddcCredentials` | SDDC Manager FQDN |
| `-SddcCredential` | No | SDDC Manager account (ADMIN role). Config: `SddcUser` / `SddcCredentialFile` |
| `-SkipCertificateCheck` | No | **Lab only.** Skips TLS validation of SDDC Manager. For vCenter/ESXi, PowerCLI's own `Set-PowerCLIConfiguration -InvalidCertificateAction` applies |

## Usage

```powershell
.\Get-LunMultipathReport.ps1 -VCenter vc01.corp.local -VMHost esx01.corp.local | Format-Table

# All hosts that match, to CSV
.\Get-LunMultipathReport.ps1 -VCenter vc01.corp.local -VMHost esx0* -CsvPath C:\Reports\luns-{date}.csv

# Only the LUNs that do not use Round Robin
.\Get-LunMultipathReport.ps1 -Environment lab1 | Where-Object PathSelectionPolicy -ne 'VMW_PSP_RR'
```

## Credentials

The script never stores or prints a password. It takes the account from the first of these that is set:

1. `-Credential` on the command line.
2. The environment config: `VcUser` makes the script ask for that user's password, `VcCredentialFile` points to a file made with `Get-Credential | Export-Clixml <file>` (encrypted for your Windows account, on that machine).
3. `-UseSddcCredentials` with `-SddcManager`: the password is read from the SDDC Manager vault (`GET /v1/credentials`, the API counterpart of `lookup_passwords`). Only the SDDC Manager login needs a password; that account needs the SDDC Manager **ADMIN** role. With the vault, the script uses the vCenter SSO account (credential type `SSO`).
4. Otherwise `Get-Credential` asks.

## Config file

This script uses the shared **environment config**: one JSON file per environment (lab, customer, ...) for all scripts in this repository. See [config/README.md](../config/README.md). Run with `-Environment lab1` (reads `config\lab1.config.json`) or `-ConfigFile <path>`. The script reads the top-level keys, then `Common`, then its own section **`LunMultipathReport`**. Values on the command line win over the file.

## Output

The results go to the pipeline as objects (not `Format-Table`), so you can filter, sort or export them yourself.
