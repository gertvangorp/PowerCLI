# Set-EsxiNtpServer

Sets the NTP servers on one or more ESXi hosts by connecting to **each host directly** (not through vCenter), so it also works for hosts that are not in a vCenter yet, for example while you prepare VCF bring-up.

Per host it replaces the NTP server list, sets the `ntpd` service to start and stop with the host, and restarts (or starts) it. A host that already has exactly the requested list is left as is, apart from the service check. One host failing does not stop the others.

> On hosts that VCF already manages, set NTP through SDDC Manager where you can. Use this script for hosts outside VCF, before bring-up, or to repair a single host.

**This script changes configuration.** Run it with `-WhatIf` first.

## Requirements

- PowerShell 7 or Windows PowerShell 5.1
- `Install-Module VCF.PowerCLI -Scope CurrentUser` (VMware.PowerCLI also works)
- HTTPS (443) from your machine to every ESXi host

## Parameters

| Parameter | Required | Description |
|---|---|---|
| `-VMHost` | Yes, or in the config file | ESXi host names (FQDN) |
| `-NtpServer` | Yes, or in the config file | NTP servers, in order |
| `-Credential` | No | ESXi account (root), used for every host. Config: `EsxiUser` / `EsxiCredentialFile` |
| `-Environment` | No | Environment config name: reads `config\<name>.config.json` |
| `-ConfigFile` | No | Path to an environment config file |
| `-UseSddcCredentials` | No | Read the password from the SDDC Manager vault |
| `-SddcManager` | With `-UseSddcCredentials` | SDDC Manager FQDN |
| `-SddcCredential` | No | SDDC Manager account (ADMIN role). Config: `SddcUser` / `SddcCredentialFile` |
| `-SkipCertificateCheck` | No | **Lab only.** Skips TLS validation of SDDC Manager. For vCenter/ESXi, PowerCLI's own `Set-PowerCLIConfiguration -InvalidCertificateAction` applies |
| `-WhatIf` / `-Confirm` | No | Show what would change / ask per change |

## Usage

```powershell
# See what would change
.\Set-EsxiNtpServer.ps1 -VMHost esx01.corp.local, esx02.corp.local -NtpServer 0.be.pool.ntp.org, 1.be.pool.ntp.org -WhatIf

# Apply, hosts and NTP servers from the config file
.\Set-EsxiNtpServer.ps1 -Environment lab1

# VCF: take each host's root password from the SDDC Manager vault
.\Set-EsxiNtpServer.ps1 -Environment lab1 -UseSddcCredentials -SddcManager sddc01.corp.local
```

## Credentials

The script never stores or prints a password. It takes the account from the first of these that is set:

1. `-Credential` on the command line.
2. The environment config: `EsxiUser` makes the script ask for that user's password, `EsxiCredentialFile` points to a file made with `Get-Credential | Export-Clixml <file>` (encrypted for your Windows account, on that machine).
3. `-UseSddcCredentials` with `-SddcManager`: the password is read from the SDDC Manager vault (`GET /v1/credentials`, the API counterpart of `lookup_passwords`). Only the SDDC Manager login needs a password; that account needs the SDDC Manager **ADMIN** role. With the vault, each host gets its own `root` password (resource type `ESXI`).
4. Otherwise `Get-Credential` asks.

## Config file

This script uses the shared **environment config**: one JSON file per environment (lab, customer, ...) for all scripts in this repository. See [config/README.md](../config/README.md). Run with `-Environment lab1` (reads `config\lab1.config.json`) or `-ConfigFile <path>`. The script reads the top-level keys, then `Common`, then its own section **`EsxiNtpServer`**. Values on the command line win over the file.

## Output

One object per host:

```
VMHost           NtpServers                             ServicePolicy ServiceRunning Status Message
------           ----------                             ------------- -------------- ------ -------
esx01.corp.local 0.be.pool.ntp.org, 1.be.pool.ntp.org   on            True           OK     NTP servers changed (were: 10.0.0.1)
esx02.corp.local 0.be.pool.ntp.org, 1.be.pool.ntp.org   on            True           OK     NTP servers already correct
esx03.corp.local                                                                     Failed Could not connect ...
```
