# PowerCLI

PowerShell and PowerCLI scripts for vSphere and VMware Cloud Foundation (VCF). Each script has its own folder with a README and a sample config file.

| Folder | What it does | Changes anything? |
|---|---|---|
| [Get-VCFPrimaryDatastore](Get-VCFPrimaryDatastore/) | VCF 9.x: lists the primary (principal) datastore of every cluster through the SDDC Manager API. | No |
| [Get-LunMultipathReport](Get-LunMultipathReport/) | Lists every LUN of one or more ESXi hosts with multipath policy, PSP, SATP and working paths. | No |
| [Get-TpmRecoveryKey](Get-TpmRecoveryKey/) | Reports the TPM recovery key of every ESXi host in a cluster. | No |
| [Set-EsxiNtpServer](Set-EsxiNtpServer/) | Sets the NTP servers and the ntpd service directly on ESXi hosts. Supports `-WhatIf`. | **Yes** |

## Common conventions

- **PowerShell 7 or Windows PowerShell 5.1.** The PowerCLI scripts need `Install-Module VCF.PowerCLI -Scope CurrentUser`.
- **Config file.** Every script takes an optional `-ConfigFile` (JSON). Copy the `*.config.sample.json` from its folder to `*.config.json`; real config files are in `.gitignore`. The command line wins over the file.
- **No passwords in files.** A config key with `password`, `secret` or `token` in its name stops the script. Use `<X>User` (the script asks) or `<X>CredentialFile` (`Get-Credential | Export-Clixml <file>`).
- **VCF credentials.** The vCenter and ESXi scripts accept `-UseSddcCredentials`: they then read the password from the SDDC Manager vault, so only the SDDC Manager login needs a password.
- **Certificates are validated.** `-SkipCertificateCheck` is for labs with self-signed certificates only.
- **Help.** Every script has comment-based help: `Get-Help .\Get-TpmRecoveryKey.ps1 -Full`.

## Moved scripts

The scripts used to be in the root of this repository and were renamed to PowerShell verb-noun names:

| Old name | New location |
|---|---|
| `Get-VCFPrimaryDatastore.ps1` | [Get-VCFPrimaryDatastore/Get-VCFPrimaryDatastore.ps1](Get-VCFPrimaryDatastore/Get-VCFPrimaryDatastore.ps1) |
| `Configure-NTP-Directly-ESXhost.ps1` | [Set-EsxiNtpServer/Set-EsxiNtpServer.ps1](Set-EsxiNtpServer/Set-EsxiNtpServer.ps1) |
| `Report-LUN-Info.ps1` | [Get-LunMultipathReport/Get-LunMultipathReport.ps1](Get-LunMultipathReport/Get-LunMultipathReport.ps1) |
| `Report-TPM-RecoveryKey.ps1` | [Get-TpmRecoveryKey/Get-TpmRecoveryKey.ps1](Get-TpmRecoveryKey/Get-TpmRecoveryKey.ps1) |

`Get-VCFPrimaryDatastore.ps1` in the root is only a pointer to the new location, so older links keep working.
