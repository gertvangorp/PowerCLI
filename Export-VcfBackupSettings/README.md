# Export-VcfBackupSettings

Exports the **backup configuration** (not the backups themselves) of a VCF environment to JSON files: the SDDC Manager backup configuration, the vCenter (VAMI) backup schedules and the VCF Operations fleet management backup settings. Use it to document an environment, or run it before and after [Set-VcfBackupSettings](../Set-VcfBackupSettings/) to keep a record of the change.

The script only reads. It does not start a backup and changes nothing.

## Requirements

- Windows PowerShell 5.1 or PowerShell 7+ (no PowerCLI modules needed)
- HTTPS (443) to SDDC Manager, every vCenter and the fleet management appliance
- Accounts: SDDC Manager (`administrator@vsphere.local`, ADMIN role for `-UseSddcCredentials`), vCenter SSO administrator, fleet management `admin@local`

## Parameters

| Parameter | Required | Description |
|---|---|---|
| `-SddcManager` | No | SDDC Manager FQDN. Config: `SddcManager` |
| `-SddcCredential` | No | SDDC Manager account. Config: `SddcUser` / `SddcCredentialFile` |
| `-VCenter` | No | One or more vCenter FQDNs. Config: `VCenter` |
| `-VCenterCredential` | No | vCenter account, used for every vCenter. Config: `VcUser` / `VcCredentialFile` |
| `-UseSddcCredentials` | No | Read each vCenter's SSO administrator password from the SDDC Manager vault |
| `-FleetManager` | No | Fleet management appliance FQDN. Config: `FleetManager` |
| `-FleetCredential` | No | Fleet management account (`admin@local`). Config: `FleetUser` / `FleetCredentialFile` |
| `-FleetEndpoints` | No | API paths read on fleet management. Check them in `https://<fleet-fqdn>/api/swagger-ui.html` if a call returns 404 |
| `-OutputPath` | No | Export folder; a timestamped subfolder is made per run. `{env}`, `{date}` and `%VARIABLES%` work. Default `.\vcf-backup-settings` |
| `-IncludeJobHistory` | No | Also export the recent vCenter backup jobs |
| `-NoRedact` | No | Do not mask secret-looking properties in the output |
| `-Environment` | No | Environment config name: reads `config\<name>.config.json` |
| `-ConfigFile` | No | Path to an environment config file |
| `-SkipCertificateCheck` | No | **Lab only.** Skips TLS certificate validation |

A component without a server name is skipped, so you can export only SDDC Manager, only the vCenters, or everything.

## Usage

```powershell
# Everything from the environment config (config\lab1.config.json)
.\Export-VcfBackupSettings\Export-VcfBackupSettings.ps1 -Environment lab1

# VCF: vCenter passwords from the SDDC Manager vault, only the SDDC Manager login is asked
.\Export-VcfBackupSettings\Export-VcfBackupSettings.ps1 -Environment lab1 -UseSddcCredentials

# Without a config file
$cred = Get-Credential administrator@vsphere.local
.\Export-VcfBackupSettings\Export-VcfBackupSettings.ps1 -SddcManager sddc01.corp.local -SddcCredential $cred `
    -VCenter vc01.corp.local, vc02.corp.local -VCenterCredential $cred `
    -FleetManager fleet01.corp.local -OutputPath D:\Exports\vcf-backup-settings

# Only the vCenters, with the recent backup jobs
.\Export-VcfBackupSettings\Export-VcfBackupSettings.ps1 -VCenter vc01.corp.local -IncludeJobHistory
```

## Config file

This script uses the shared **environment config**, see [config/README.md](../config/README.md). It reads the top-level keys, then `Common`, then the section **`VcfBackupSettings`**, which it shares with [Set-VcfBackupSettings](../Set-VcfBackupSettings/). It uses `SddcManager`, `VCenter`, `FleetManager`, `FleetEndpoints`, `OutputPath`, `IncludeJobHistory`, `UseSddcCredentials`, `SkipCertificateCheck` and the `Sddc`, `Vc` and `Fleet` accounts. Values on the command line win over the file.

## Output

One JSON file per endpoint, plus `summary.json`, in a folder per run:

```
vcf-backup-settings\20261118-151200\
    sddc_sddc01.corp.local_backup-configuration.json
    vcenter_vc01.corp.local_backup-schedules.json
    fleet_fleet01.corp.local_backup.json
    fleet_fleet01.corp.local_system-details.json
    summary.json
```

A failing endpoint is listed in `summary.json` with the error and does not stop the run. The exit code is 1 when something failed, so a scheduled task can alert on it.

## How it works

| Component | Calls |
|---|---|
| SDDC Manager | `POST /v1/tokens`, `GET /v1/system/backup-configuration` |
| vCenter (VAMI) | `POST /api/session`, `GET /api/appliance/recovery/backup/schedules`, optional `GET /api/appliance/recovery/backup/job/details` |
| Fleet management | Basic auth, `GET` on each path in `-FleetEndpoints` |
| Vault (`-UseSddcCredentials`) | `GET /v1/credentials`, SSO account of each vCenter (resource type `PSC` or `VCENTER`) |

The APIs normally mask passwords. The script also replaces every property whose name looks like a secret (`password`, `passphrase`, `secret`, `token`, `privateKey`) with `***REDACTED***` before writing.
